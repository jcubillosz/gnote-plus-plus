import AppKit
import Scintilla

/// Carpeta de datos de la app: Application Support/GNote++/<bundle id>/. Con el bundle id
/// en la ruta, una copia aislada (otro CFBundleIdentifier) no toca los datos del usuario.
func appDataDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let url = base
        .appendingPathComponent("GNote++", isDirectory: true)
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "GNote++", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Respaldo continuo del texto sin guardar (archivos modificados y documentos sin título),
/// para recuperarlo si la app se cierra de golpe.
///
/// Hilos: todo lo que toca Scintilla (leer el texto) corre en el principal; solo la escritura
/// a disco va a una cola serial de fondo. La cola es serial también para que un borrado
/// nunca adelante a la escritura pendiente del mismo archivo.
enum SessionBackup {
    private static let queue = DispatchQueue(label: "gnote.sessionbackup", qos: .utility)

    static var directory: URL {
        let url = appDataDirectory().appendingPathComponent("backup", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Nombres de respaldo que ya no referencia ninguna pestaña (se ignoran los ocultos).
    static func orphanFiles(inDirectory names: [String], referenced: Set<String>) -> [String] {
        names.filter { !$0.hasPrefix(".") && !referenced.contains($0) }
    }

    /// Cada 7 s desde el AppDelegate. Sin cambios (ningún `backupPending`, respaldo
    /// creado/borrado ni pestañas distintas) no lee ni escribe nada: es solo un recorrido del
    /// arreglo de documentos.
    @MainActor
    static func tick(tabs: TabsViewModel, fileTree: FileTreeViewModel) {
        guard tabs.preferences.backupEnabled else { return }
        for document in tabs.documents where document.backupPending {
            document.backupPending = false
            _ = process(document, tabs: tabs, synchronous: false)
        }
        // La sesión solo guarda el NOMBRE del respaldo: reescribir uno existente no la cambia.
        // Abrir, cerrar o reordenar pestañas (o cambiar la activa) sí, aunque no toque respaldos:
        // tras un cierre abrupto se restaurarían las pestañas de la última vez que cambiaron.
        let fingerprint = SessionFingerprint(ids: tabs.documents.map(\.id), active: tabs.activeDocument?.id)
        if backupSetChanged || fingerprint != lastSessionFingerprint {
            backupSetChanged = false
            lastSessionFingerprint = fingerprint
            SessionStore.save(tabs: tabs, fileTree: fileTree)
        }
    }

    /// Respaldo de TODOS los documentos, sincrónico (cierre de la app). false si falló alguna escritura.
    @MainActor
    static func flushSynchronously(tabs: TabsViewModel, fileTree: FileTreeViewModel) -> Bool {
        var ok = true
        for document in tabs.documents {
            document.backupPending = false
            if !process(document, tabs: tabs, synchronous: true) { ok = false }
        }
        // Espera también las escrituras asíncronas previas: un fallo de esas que nadie
        // reescribió después sigue en failedWrites.
        return queue.sync { ok && failedWrites.isEmpty }
    }

    /// Solo desde el hilo principal (toca `backupSetChanged`). Sin `@MainActor` porque sus
    /// llamadores (cerrar/guardar en TabsViewModel) no están aislados y el anotado se propaga
    /// en cadena por toda la clase.
    static func deleteBackup(of document: Document) {
        guard let name = document.backupFileName else { return }
        document.backupFileName = nil
        backupSetChanged = true
        let url = directory.appendingPathComponent(name)
        queue.async {
            failedWrites.remove(name)
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func deleteAll() {
        deleteOrphans(referenced: [])
        queue.sync { failedWrites.removeAll() }
    }

    /// Borra los respaldos que ninguna pestaña restaurada referencia (sesión vieja, pestaña
    /// cerrada antes de un cierre abrupto, etc.).
    static func deleteOrphans(referenced: Set<String>) {
        let dir = directory
        queue.sync {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in orphanFiles(inDirectory: names, referenced: referenced) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// Preferencia cambiada. Apagarla borra todo lo respaldado; encenderla respalda en el
    /// próximo tick lo que ya estaba sin guardar (si no, esperaría a la próxima edición).
    @MainActor
    static func preferenceChanged(enabled: Bool, tabs: TabsViewModel) {
        for document in tabs.documents {
            document.backupPending = enabled
            if !enabled { document.backupFileName = nil }
        }
        if !enabled { deleteAll() }
    }

    // MARK: - Interno

    /// Nombres cuya última escritura falló. Solo se toca desde `queue`; una escritura exitosa
    /// posterior del mismo archivo (o su borrado) lo saca.
    private static var failedWrites: Set<String> = []
    /// Se creó o borró algún respaldo desde el último guardado de sesión. Solo hilo principal.
    private static var backupSetChanged = false

    private struct SessionFingerprint: Equatable {
        let ids: [UUID]
        let active: UUID?
    }
    /// Pestañas y activa del último guardado de sesión desde el tick. Solo hilo principal.
    private static var lastSessionFingerprint: SessionFingerprint?

    /// Escribe o borra el respaldo de un documento. false solo si una escritura sincrónica falló.
    @MainActor
    private static func process(_ document: Document, tabs: TabsViewModel, synchronous: Bool) -> Bool {
        // Archivo: solo si tiene cambios sin guardar. Sin título: solo si tiene texto.
        let text: String? = (document.url != nil && !document.isDirty) ? nil : tabs.text(of: document)
        guard let text, document.url != nil || !text.isEmpty else {
            deleteBackup(of: document)
            return true
        }
        let name: String
        if let existing = document.backupFileName {
            name = existing
        } else {
            name = "\(document.id.uuidString).txt"
            document.backupFileName = name
            backupSetChanged = true
        }
        let url = directory.appendingPathComponent(name)
        let data = Data(text.utf8)
        let write = {
            do {
                try data.write(to: url, options: .atomic)
                failedWrites.remove(name)
                return true
            } catch {
                failedWrites.insert(name)
                return false
            }
        }
        if synchronous { return queue.sync(execute: write) }
        queue.async { _ = write() }
        return true
    }
}
