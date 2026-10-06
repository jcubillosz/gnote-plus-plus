import AppKit
import Scintilla

/// Detección de cambios hechos por otros programas sobre archivos abiertos (Notepad++:
/// "Este archivo fue modificado por otro programa"). Política acordada con el usuario:
/// - sin cambios propios → recarga silenciosa, conservando cursor y scroll;
/// - con cambios sin guardar → pregunta (recargar y perder los propios, o mantenerlos);
/// - borrado/movido afuera → la pestaña queda marcada; guardar lo vuelve a crear.
/// Las pestañas inactivas no se tocan hasta activarlas (el editor es uno solo y compartido).
extension TabsViewModel {
    /// Recalcula qué carpetas observar a partir de los documentos abiertos. Barato si el
    /// conjunto no cambió (no recrea el stream).
    func updateWatchedFolders() {
        let folders = Set(documents.compactMap { $0.url.map { canonicalFilePath($0.deletingLastPathComponent()) } }).sorted()
        guard folders != watchedFolders else { return }
        watchedFolders = folders
        openFilesWatcher?.stop()
        openFilesWatcher = OpenFilesWatcher(folders: folders) { [weak self] paths in
            self?.checkExternalChanges(forPaths: Set(paths.map { canonicalFilePath(path: $0) }))
        }
    }

    /// Compara el stamp en disco con el registrado. `paths` nil = todos los documentos (al
    /// volver a la app, por si FSEvents perdió algún evento).
    func checkExternalChanges(forPaths paths: Set<String>? = nil) {
        guard !isPresentingExternalChangeAlert else { return }
        var changedAppearance = false
        for document in documents {
            guard let url = document.url else { continue }
            if let paths, !paths.contains(canonicalFilePath(url)) { continue }

            guard let current = FileStamp.of(url) else {
                if !document.missingOnDisk {
                    document.missingOnDisk = true
                    changedAppearance = true
                }
                continue
            }
            if document.missingOnDisk {
                document.missingOnDisk = false
                changedAppearance = true
            }
            // Igual al registrado: sin cambios externos (incluye los eventos que generan
            // nuestros propios guardados, que actualizan el stamp antes de que llegue el evento).
            guard current != document.diskStamp else { continue }

            let isActive = document === activeDocument
            if isActive { syncDirtyFlagOfActiveDocument() }
            if document.isDirty {
                if isActive {
                    resolveExternalConflict(of: document, stamp: current)
                } else {
                    document.pendingExternalConflict = true
                }
            } else if isActive {
                reloadFromDisk(document)
            } else {
                document.needsReload = true
            }
        }
        if changedAppearance { objectWillChange.send() }
    }

    /// Llamado al activar una pestaña: aplica la recarga o la pregunta que quedó pendiente
    /// mientras estaba inactiva. Diferido para no abrir una alerta modal en medio del cambio
    /// de pestaña (layout de SwiftUI en curso).
    func resolveDeferredExternalChange(of document: Document) {
        guard document.needsReload || document.pendingExternalConflict else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, document === self.activeDocument else { return }
            if document.pendingExternalConflict, let url = document.url, let stamp = FileStamp.of(url) {
                document.pendingExternalConflict = false
                self.resolveExternalConflict(of: document, stamp: stamp)
            } else if document.needsReload {
                self.reloadFromDisk(document)
            }
        }
    }

    private func resolveExternalConflict(of document: Document, stamp: FileStamp) {
        isPresentingExternalChangeAlert = true
        defer { isPresentingExternalChangeAlert = false }
        let reload = confirmAction(
            message: L("\(document.displayName) se modificó en disco."),
            detail: L("Otro programa cambió el archivo y tú tienes cambios sin guardar. ¿Recargarlo y perder tus cambios?"),
            confirmTitle: L("Recargar"),
            cancelTitle: L("Mantener los míos")
        )
        if reload {
            reloadFromDisk(document)
        } else {
            // Mantener los propios = aceptar que el próximo guardado reemplace la versión de
            // disco: se registra el stamp actual para no volver a preguntar por este cambio.
            document.diskStamp = stamp
        }
    }

    /// Relee el documento activo desde disco conservando selección y scroll. loadText ya
    /// suspende el solo-lectura, así que también funciona con documentos bloqueados.
    func reloadFromDisk(_ document: Document) {
        guard document === activeDocument, let url = document.url, let data = try? Data(contentsOf: url) else { return }
        let file = decodeWithDetectedEncoding(data)
        saveViewStateOfActive()
        document.encoding = file.encoding
        document.encodingName = file.encodingName
        document.encodingNote = file.note
        document.eol = file.eol
        _ = ScintillaView.directCall(editor, message: SCI_SETEOLMODE, wParam: uptr_t(file.eol.rawValue), lParam: 0)
        loadText(editor, file.text)
        _ = ScintillaView.directCall(editor, message: SCI_EMPTYUNDOBUFFER, wParam: 0, lParam: 0)
        resetChangeHistory(editor)
        _ = ScintillaView.directCall(editor, message: SCI_SETSAVEPOINT, wParam: 0, lParam: 0)
        restoreViewState(of: document)
        document.diskStamp = FileStamp.of(url)
        document.isDirty = false
        document.needsReload = false
        document.pendingExternalConflict = false
        document.missingOnDisk = false
        publishFileInfo(of: document)
        objectWillChange.send()
    }

    /// Alerta de dos botones con textos propios (confirmDiscard dice "Descartar", que no
    /// corresponde para sobrescribir o recargar).
    func confirmAction(message: String, detail: String, confirmTitle: String, cancelTitle: String = L("Cancelar")) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
