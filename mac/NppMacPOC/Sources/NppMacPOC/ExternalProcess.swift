import Foundation

// Única puerta para correr programas externos (git, formateadores). Nunca por /bin/sh: los
// argumentos van como array, así una ruta con espacios o comillas no se interpreta.

enum ExternalProcessError: Error, Equatable {
    case timeout
    case launchFailed(String)
}

enum ExternalProcess {
    typealias Output = (status: Int32, stdout: Data, stderr: Data)

    /// Lanza el proceso fuera del hilo principal y llama `completion` una sola vez, en el hilo
    /// principal. Al vencer `timeout` se termina el proceso (SIGTERM y, si sigue vivo a los
    /// 0,5 s, SIGKILL) y el resultado es `.timeout` aunque haya llegado a escribir algo.
    static func run(_ executable: URL, args: [String], stdin: Data?, cwd: URL?, env: [String: String] = [:],
                    timeout: TimeInterval,
                    completion: @escaping (Result<Output, ExternalProcessError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            if let cwd { process.currentDirectoryURL = cwd }
            if !env.isEmpty {
                var environment = ProcessInfo.processInfo.environment
                for (key, value) in env { environment[key] = value }
                process.environment = environment
            }
            let outPipe = Pipe(), errPipe = Pipe()
            let inPipe: Pipe? = stdin == nil ? nil : Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            // Sin stdin explícito el hijo heredaría el de la app.
            process.standardInput = inPipe ?? FileHandle.nullDevice

            let state = RunState(completion: completion)
            let group = DispatchGroup()
            group.enter()
            process.terminationHandler = { _ in group.leave() }
            do {
                try process.run()
            } catch {
                state.finish(.failure(.launchFailed(error.localizedDescription)))
                return
            }

            // stdout y stderr se drenan cada uno en su hilo: leer uno hasta EOF mientras el hijo
            // se bloquea escribiendo el otro (buffer del pipe lleno, 64 KB) es un deadlock.
            var outData = Data(), errData = Data()
            for (pipe, assign) in [(outPipe, { outData = $0 }), (errPipe, { errData = $0 })] as [(Pipe, (Data) -> Void)] {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    assign(pipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
            }
            if let inPipe, let stdin {
                DispatchQueue.global(qos: .userInitiated).async {
                    let handle = inPipe.fileHandleForWriting
                    // Si el hijo sale sin leer todo, escribir daría SIGPIPE y mataría la app entera.
                    _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
                    try? handle.write(contentsOf: stdin)
                    try? handle.close()
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                state.markTimedOut()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                // Un nieto que herede los pipes los mantiene abiertos y el EOF no llega nunca: el
                // resultado no espera a los lectores más allá de esto.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                    state.finish(.failure(.timeout))
                }
            }

            group.notify(queue: .global()) {
                if state.timedOut {
                    state.finish(.failure(.timeout))
                } else {
                    state.finish(.success((process.terminationStatus, outData, errData)))
                }
            }
        }
    }

    /// Garantiza una sola llamada a `completion` entre el final normal y el del timeout.
    private final class RunState {
        private let lock = NSLock()
        private var finished = false
        private var _timedOut = false
        private let completion: (Result<Output, ExternalProcessError>) -> Void

        init(completion: @escaping (Result<Output, ExternalProcessError>) -> Void) {
            self.completion = completion
        }

        var timedOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return _timedOut
        }

        func markTimedOut() {
            lock.lock(); _timedOut = true; lock.unlock()
        }

        func finish(_ result: Result<Output, ExternalProcessError>) {
            lock.lock()
            let first = !finished
            finished = true
            lock.unlock()
            guard first else { return }
            let completion = self.completion
            DispatchQueue.main.async { completion(result) }
        }
    }
}
