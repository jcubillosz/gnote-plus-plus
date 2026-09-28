import Foundation

/// Observa una carpeta (y sus subcarpetas) en disco con FSEvents y llama a `onChange`
/// en el hilo principal cuando algo cambia. Usado por `FileTreeViewModel` para refrescar
/// el árbol automáticamente cuando se crean/borran archivos desde Finder u otra app.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange

        let path = url.path as CFString
        let pathsToWatch = [path] as CFArray

        // El callback de FSEvents es un puntero a función C, no puede capturar `self`
        // directamente — se pasa `self` como contexto opaco (Unmanaged) y se recupera
        // dentro del callback.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, contextInfo, _, _, _, _) in
                guard let contextInfo else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
                // Los eventos llegan en la cola donde se agendó el stream (.main, ver abajo),
                // así que no hace falta un dispatch extra a main aquí.
                watcher.onChange()
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, // latencia: agrupa ráfagas de eventos (p. ej. guardar = borrar+crear) en un solo refresh
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            return nil
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
