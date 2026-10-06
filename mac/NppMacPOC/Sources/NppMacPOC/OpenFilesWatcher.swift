import Foundation

/// Fecha de modificación + tamaño de un archivo en disco, registrados al abrir/guardar/recargar
/// un documento. Si el archivo cambia por otro programa, el stamp de disco deja de coincidir.
struct FileStamp: Equatable {
    let modificationDate: Date
    let size: Int

    static func of(_ url: URL) -> FileStamp? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let date = values.contentModificationDate else { return nil }
        return FileStamp(modificationDate: date, size: values.fileSize ?? 0)
    }
}

/// Ruta canónica para comparar documentos con eventos de FSEvents: FSEvents reporta la ruta
/// real (`/private/tmp/...`) y un documento pudo abrirse vía symlink (`/tmp/...`). Ojo:
/// resolvingSymlinksInPath *quita* el prefijo /private, así que se normalizan ambos lados
/// sin él (canonicalFilePath(path:) se aplica también a las rutas de los eventos).
func canonicalFilePath(_ url: URL) -> String {
    canonicalFilePath(path: url.standardizedFileURL.resolvingSymlinksInPath().path)
}

func canonicalFilePath(path: String) -> String {
    path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
}

/// Observa con FSEvents (a nivel archivo) las carpetas que contienen documentos abiertos y
/// avisa qué rutas cambiaron. Se observan carpetas y no archivos sueltos: los editores que
/// guardan de forma atómica (escribir temporal + renombrar) reemplazan el archivo, y un
/// observador por descriptor de archivo dejaría de recibir eventos después del primer guardado.
/// Mismo patrón de contexto Unmanaged que DirectoryWatcher.
final class OpenFilesWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init?(folders: [String], onChange: @escaping ([String]) -> Void) {
        guard !folders.isEmpty else { return nil }
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, contextInfo, _, eventPaths, _, _) in
                guard let contextInfo else { return }
                let watcher = Unmanaged<OpenFilesWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
                // Con kFSEventStreamCreateFlagUseCFTypes, eventPaths es un CFArray de CFString.
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
                watcher.onChange(paths)
            },
            &context,
            folders as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            )
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
