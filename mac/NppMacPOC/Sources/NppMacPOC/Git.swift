import Foundation

// Integración con git por línea de comandos. Si no hay git usable, todo lo de git simplemente
// no aparece: nunca se ofrece instalar nada.

enum GitTool {
    static let timeout: TimeInterval = 5
    /// Sin locks opcionales: un `git status` nuestro no debe chocar con un commit del usuario.
    static let environment = ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]

    /// nil hasta que `resolveExecutable` termina, o si no hay git usable.
    private(set) static var executable: URL?
    private static var resolved = false
    private static var waiting: [(URL?) -> Void] = []
    /// Por carpeta (ruta estándar): raíz del repo. Solo respuestas positivas: un "no es repo"
    /// cacheado ocultaría el repo tras un `git init` o clone hasta reiniciar la app.
    private static var rootCache: [String: URL] = [:]

    /// Se resuelve una vez. Llamar desde el hilo principal; `completion` también corre ahí.
    static func resolveExecutable(_ completion: @escaping (URL?) -> Void) {
        if resolved { completion(executable); return }
        waiting.append(completion)
        guard waiting.count == 1 else { return }
        func done(_ url: URL?) {
            executable = url
            resolved = true
            let callbacks = waiting
            waiting = []
            callbacks.forEach { $0(url) }
        }
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: path) {
            done(URL(fileURLWithPath: path))
            return
        }
        // /usr/bin/git es un shim: sin las herramientas de línea de comandos, ejecutarlo abre el
        // diálogo de instalación de macOS. `xcode-select -p` sale con 0 solo si están instaladas.
        ExternalProcess.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), args: ["-p"], stdin: nil, cwd: nil,
                            timeout: timeout) { result in
            if case .success(let output) = result, output.status == 0,
               fm.isExecutableFile(atPath: "/usr/bin/git") {
                done(URL(fileURLWithPath: "/usr/bin/git"))
            } else {
                done(nil)
            }
        }
    }

    /// Corre git con el entorno y el timeout comunes. nil = no hay git usable.
    static func run(_ args: [String], cwd: URL, stdin: Data? = nil, timeout: TimeInterval = GitTool.timeout,
                    completion: @escaping (Result<ExternalProcess.Output, ExternalProcessError>?) -> Void) {
        resolveExecutable { git in
            guard let git else { completion(nil); return }
            ExternalProcess.run(git, args: args, stdin: stdin, cwd: cwd, env: environment, timeout: timeout) {
                completion($0)
            }
        }
    }

    static func repoRoot(for dir: URL, completion: @escaping (URL?) -> Void) {
        let key = dir.standardizedFileURL.path
        if let cached = rootCache[key] { completion(cached); return }
        // Sin un `.git` en la carpeta o sus ancestros ni se lanza git: la mayoría de los archivos
        // no están en un repo y esto evita un proceso por pestaña.
        guard hasGitAncestor(key) else { completion(nil); return }
        run(["rev-parse", "--show-toplevel"], cwd: dir) { result in
            switch result {
            case .success(let output)?:
                let path = String(decoding: output.stdout, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let root: URL? = output.status == 0 && !path.isEmpty ? URL(fileURLWithPath: path, isDirectory: true) : nil
                if let root { rootCache[key] = root }
                completion(root)
            default:
                // Timeout o fallo al lanzar: no se cachea, el próximo intento vuelve a probar.
                completion(nil)
            }
        }
    }

    private static func hasGitAncestor(_ path: String) -> Bool {
        // `.git` puede ser una carpeta o, en worktrees y submódulos, un archivo.
        let standardized = (path as NSString).standardizingPath
        for dir in [standardized] + ancestorDirectoryPaths(of: standardized)
        where FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
            return true
        }
        return false
    }

    enum HeadBlob {
        case blob(Data)
        /// git respondió: el archivo no está en HEAD (sin rastrear, recién agregado o repo sin commits).
        case notInHead
        /// No se pudo preguntar (sin git, timeout): mejor no mostrar nada que todo "agregado".
        case unavailable
    }

    static func headBlob(repo: URL, relativePath: String, completion: @escaping (Data?) -> Void) {
        lookupHeadBlob(repo: repo, relativePath: relativePath) { result in
            if case .blob(let data) = result { completion(data) } else { completion(nil) }
        }
    }

    static func lookupHeadBlob(repo: URL, relativePath: String, completion: @escaping (HeadBlob) -> Void) {
        // --no-textconv: el contenido crudo, no lo que muestre un filtro de diff configurado.
        run(["show", "--no-textconv", "HEAD:\(relativePath)"], cwd: repo) { result in
            switch result {
            case .success(let output)?:
                completion(output.status == 0 ? .blob(output.stdout) : .notInHead)
            default:
                completion(.unavailable)
            }
        }
    }

    /// true si .gitignore excluye la ruta (o no se pudo preguntar): ahí no se marca nada.
    static func isIgnored(repo: URL, relativePath: String, completion: @escaping (Bool) -> Void) {
        run(["check-ignore", "-q", "--", relativePath], cwd: repo) { result in
            if case .success(let output)? = result {
                completion(output.status != 1)
            } else {
                completion(true)
            }
        }
    }

    /// Ruta de `file` relativa a `repo`, comparando rutas reales: git devuelve la raíz con
    /// `/private/...` y los symlinks resueltos, la pestaña puede tener otra forma de la misma ruta.
    static func relativePath(of file: URL, in repo: URL) -> String? {
        guard let filePath = realPath(file.path), let rootPath = realPath(repo.path) else { return nil }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - Estado de archivos (puro)

enum GitFileStatus: Equatable {
    case modified, added, untracked, conflicted, deleted
}

/// Salida de `git status --porcelain=v1 -z`: "XY ruta\0", y en renombres/copias
/// "XY nueva\0vieja\0". Con -z las rutas vienen sin comillas ni escapes.
func parsePorcelainZ(_ data: Data) -> [String: GitFileStatus] {
    var result: [String: GitFileStatus] = [:]
    let fields = data.split(separator: 0, omittingEmptySubsequences: false)
    var index = 0
    while index < fields.count {
        let field = Array(fields[index])
        index += 1
        guard field.count > 3 else { continue }
        let x = Character(UnicodeScalar(field[0])), y = Character(UnicodeScalar(field[1]))
        let path = String(decoding: field[3...], as: UTF8.self)
        let status: GitFileStatus?
        switch (x, y) {
        case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): status = .conflicted
        case ("?", "?"): status = .untracked
        case ("!", "!"): status = nil
        case ("R", _), ("C", _):
            index += 1 // la ruta vieja
            status = .added
        case ("A", _): status = .added
        case ("D", _), (_, "D"): status = .deleted
        default: status = .modified
        }
        if let status { result[path] = status }
    }
    return result
}

// MARK: - Estado de git en el árbol

final class GitStatusModel: ObservableObject {
    /// Rutas absolutas canónicas (realpath) → estado.
    @Published private(set) var statuses: [String: GitFileStatus] = [:]
    private var dirtyFolders: Set<String> = []
    /// `--untracked-files=normal` informa una carpeta nueva entera como "?? carpeta/".
    private var untrackedFolders: [String] = []
    private var folder: URL?
    /// Descarta respuestas de git que llegan después de cambiar de carpeta.
    private var generation = 0
    private var debounce: DispatchWorkItem?
    /// realpath por ruta: las filas se re-renderizan seguido y realpath es un syscall.
    private var canonicalCache: [String: String] = [:]

    func setFolder(_ url: URL?) {
        folder = url
        generation += 1
        debounce?.cancel()
        apply([:], root: nil)
        refreshNow()
    }

    func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.refreshNow()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func status(for url: URL) -> GitFileStatus? {
        guard !statuses.isEmpty else { return nil }
        let path = canonicalPath(url)
        if let status = statuses[path] { return status }
        return untrackedFolders.contains(where: { path.hasPrefix($0 + "/") }) ? .untracked : nil
    }

    func folderHasChanges(_ url: URL) -> Bool {
        guard !dirtyFolders.isEmpty else { return false }
        let path = canonicalPath(url)
        return dirtyFolders.contains(path) || untrackedFolders.contains(where: { path.hasPrefix($0 + "/") })
    }

    private func refreshNow() {
        guard let folder else { return }
        let current = generation
        GitTool.repoRoot(for: folder) { [weak self] root in
            guard let self, current == self.generation else { return }
            guard let root else { self.apply([:], root: nil); return }
            GitTool.run(["status", "--porcelain=v1", "-z", "--untracked-files=normal"], cwd: root) { [weak self] result in
                guard let self, current == self.generation else { return }
                // Si git falla o se cuelga se conserva lo último conocido en vez de borrar los colores.
                guard case .success(let output)? = result, output.status == 0 else { return }
                self.apply(parsePorcelainZ(output.stdout), root: root)
            }
        }
    }

    private func apply(_ relative: [String: GitFileStatus], root: URL?) {
        var absolute: [String: GitFileStatus] = [:]
        var folders: Set<String> = []
        var untrackedDirs: [String] = []
        if let root {
            let rootPath = Self.canonical(root)
            for (path, status) in relative {
                var full = rootPath + "/" + path
                if full.hasSuffix("/") {
                    full.removeLast()
                    untrackedDirs.append(full)
                    folders.insert(full)
                }
                absolute[full] = status
                // Un borrado no tiene fila en el árbol, pero su carpeta sí cambió.
                var parent = (full as NSString).deletingLastPathComponent
                while parent.count >= rootPath.count, folders.insert(parent).inserted {
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
        }
        if absolute != statuses { statuses = absolute }
        dirtyFolders = folders
        canonicalCache = [:]
        untrackedFolders = untrackedDirs
    }

    private func canonicalPath(_ url: URL) -> String {
        if let cached = canonicalCache[url.path] { return cached }
        let path = Self.canonical(url)
        canonicalCache[url.path] = path
        return path
    }

    private static func canonical(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
