// Cerrar pestañas (con aviso de cambios sin guardar) y guardar a disco.
import AppKit
import Scintilla

extension TabsViewModel {
    // MARK: - Cerrar

    @discardableResult
    func saveAll() -> Bool {
        let original = activeDocument
        for document in dirtyDocuments {
            guard let i = documents.firstIndex(where: { $0 === document }) else { continue }
            activate(at: i)
            guard saveActive() else { return false }
        }
        if let original, let i = documents.firstIndex(where: { $0 === original }) { activate(at: i) }
        return true
    }

    @discardableResult
    func closeAll() -> Bool { closeBatch(documents) }

    @discardableResult
    func closeOthers(keeping index: Int) -> Bool {
        guard documents.indices.contains(index) else { return true }
        let kept = documents[index]
        guard closeBatch(documents.filter { $0 !== kept }) else { return false }
        if let i = documents.firstIndex(where: { $0 === kept }) { activate(at: i) }
        return true
    }

    @discardableResult
    func closeToTheRight(of index: Int) -> Bool {
        guard documents.indices.contains(index) else { return true }
        return closeBatch(Array(documents[(index + 1)...]))
    }

    /// Snapshot por identidad: los índices se corren al ir cerrando.
    private func closeBatch(_ targets: [Document]) -> Bool {
        for doc in targets {
            guard let i = documents.firstIndex(where: { $0 === doc }) else { continue }
            if !close(at: i) { return false }
        }
        return true
    }

    enum SaveChoice { case save, cancel, discard }

    func askSaveBeforeClosing(_ document: Document) -> SaveChoice {
        let alert = NSAlert()
        alert.messageText = L("\(document.displayName) tiene cambios sin guardar.")
        alert.informativeText = L("Si no los guardas, se pierden.")
        alert.addButton(withTitle: L("Guardar"))
        let cancelButton = alert.addButton(withTitle: L("Cancelar"))
        // NSAlert solo asigna Escape a un botón titulado "Cancel"; en español Esc caía en otro.
        cancelButton.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: L("No guardar"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    // MARK: - Guardar

    @discardableResult
    func saveActive() -> Bool {
        guard let document = activeDocument else { return false }
        guard let url = document.url else { return saveActiveAs() }
        return write(document: document, to: url)
    }

    /// Siempre pregunta el destino, incluso si el documento ya tiene ruta.
    @discardableResult
    func saveActiveAs() -> Bool {
        guard let document = activeDocument else { return false }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.displayName
        if let current = document.url {
            panel.directoryURL = current.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        // B10: dos pestañas apuntando al mismo archivo se pisarían entre sí.
        if documents.contains(where: { $0 !== document && $0.url?.standardizedFileURL == url.standardizedFileURL }) {
            presentAlert(L("\(url.lastPathComponent) ya está abierto en otra pestaña."), detail: L("Ciérralo antes de guardar con ese nombre."))
            return false
        }

        // El documento se reapunta al destino nuevo SÓLO si la escritura salió
        // bien: si falla, renombrar la pestaña dejaría al usuario creyendo que su
        // trabajo vive en un archivo que nunca se creó.
        let previousExtension = document.url?.pathExtension.lowercased()
        let previousURL = document.url
        guard write(document: document, to: url) else { return false }
        document.url = url
        document.displayName = url.lastPathComponent
        updateWatchedFolders()
        recentFiles.add(url)
        // Guardar-como un documento bloqueado tiene que persistir la ruta nueva: si ya
        // tenía una ruta bloqueada, la migra; si era un "Nuevo" bloqueado solo para la
        // sesión, ahora que tiene ruta el bloqueo pasa a sobrevivir a cerrar la app.
        if document.isLocked {
            if let previousURL {
                LockedFiles.move(from: previousURL, to: url)
            } else {
                LockedFiles.set(url, locked: true)
            }
        }

        // Guardar como .py algo que era .txt tiene que recolorearlo. Va por
        // reapplyPreferencesAndTheme y no por applyLanguage directo porque
        // SCI_STYLECLEARALL pisa STYLE_LINENUMBER, el caret y la selección.
        if url.pathExtension.lowercased() != previousExtension {
            document.forcedLanguageName = nil
            document.languageProfile = languageProfile(forExtension: url.pathExtension, theme: currentTheme)
            reapplyPreferencesAndTheme()
        }
        // `documents` es @Published, pero Document es una clase: mutarle displayName
        // no republica nada por sí solo y la pestaña seguiría con el nombre viejo.
        objectWillChange.send()
        return true
    }

    // MARK: - Escritura a disco

    /// Devuelve true sólo si el archivo quedó escrito en disco.
    @discardableResult
    private func write(document: Document, to url: URL) -> Bool {
        // Otro programa modificó el archivo desde que se abrió/guardó acá: sin esto, guardar
        // pisaba sus cambios sin aviso.
        if document.url == url, !document.missingOnDisk, let recorded = document.diskStamp,
           let current = FileStamp.of(url), current != recorded,
           !confirmAction(
               message: L("\(document.displayName) cambió en disco desde que lo abriste."),
               detail: L("Otro programa lo modificó. Si lo sobrescribes, esos cambios se pierden."),
               confirmTitle: L("Sobrescribir")
           ) {
            return false
        }
        // Markdown no: dos espacios al final de línea son un salto de línea.
        if preferences.trimTrailingWhitespaceOnSave, !document.isLocked,
           document.languageProfile.lexerName != "markdown" {
            trimTrailingWhitespace(editor)
        }
        let text = currentText(editor)
        guard let data = encode(text, for: document) else { return false }
        do {
            // .atomic escribe a un temporal y renombra: sin esto, un disco lleno o
            // un error de I/O a mitad de camino deja el archivo original truncado y
            // su contenido anterior perdido.
            // Escribir atómico sobre el symlink lo reemplazaría por un archivo normal: se escribe
            // en el destino real y la pestaña conserva la ruta del enlace.
            try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
            document.diskStamp = FileStamp.of(url)
            document.missingOnDisk = false
            // Guardar resuelve cualquier cambio externo pendiente.
            document.pendingExternalConflict = false
            document.needsReload = false
            document.isDirty = false
            _ = ScintillaView.directCall(editor, message: SCI_SETSAVEPOINT, wParam: 0, lParam: 0)
            // Mismo motivo que en setActiveDirty(): sin esto, el punto de la pestaña
            // seguiría visible después de guardar hasta el próximo cambio de pestaña.
            objectWillChange.send()
            return true
        } catch {
            presentAlert(
                L("No se pudo guardar \(document.displayName)."),
                detail: error.localizedDescription
            )
            return false
        }
    }

    /// Codifica con el encoding con el que se abrió el archivo, para no convertirlo
    /// sin que el usuario lo pida. Si el texto dejó de ser representable en ese
    /// encoding (pegar un emoji en un archivo Latin-1, por ejemplo) ofrece pasarlo
    /// a UTF-8 en vez de abortar en silencio, que era lo que pasaba antes: el
    /// guardado no hacía nada y el usuario creía que había guardado.
    private func encode(_ text: String, for document: Document) -> Data? {
        if let data = text.data(using: document.encoding) {
            return data
        }

        let previousName = document.encodingName
        let alert = NSAlert()
        alert.messageText = L("El texto no se puede guardar como \(previousName).")
        alert.informativeText = L("Tiene caracteres que ese encoding no representa. Guardarlo como UTF-8 los admite todos, pero cambia la codificación del archivo.")
        alert.addButton(withTitle: L("Guardar como UTF-8"))
        alert.addButton(withTitle: L("Cancelar"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        document.encoding = .utf8
        document.encodingName = "UTF-8"
        document.encodingNote = L("Convertido desde \(previousName) al guardar: el texto tenía caracteres que \(previousName) no representa.")
        publishFileInfo(of: document)
        // Data(_:) sobre la vista utf8 no es opcional — todo String es representable
        // en UTF-8, y devolver un Data? acá reintroduciría un fallo silencioso.
        return Data(text.utf8)
    }
}
