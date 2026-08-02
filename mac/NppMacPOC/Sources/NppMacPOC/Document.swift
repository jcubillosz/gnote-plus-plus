import AppKit
import Scintilla

/// Un documento abierto (una pestaña). Wrappea un puntero de documento Scintilla liviano
/// (SCI_CREATEDOCUMENT) — el ScintillaView es uno solo y compartido; cambiar de pestaña es
/// SCI_SETDOCPOINTER, no crear una vista nueva.
final class Document: Identifiable {
    let id = UUID()
    let pointer: sptr_t
    var url: URL?
    var displayName: String
    var languageProfile: LanguageProfile
    /// Encoding con el que se leyó y con el que se vuelve a escribir. Guardar en
    /// otro encoding cambiaría el archivo sin que el usuario lo pida.
    var encoding: String.Encoding
    var encodingName: String
    var encodingNote: String?
    var eol: EOLMode
    var isDirty: Bool = false

    init(
        pointer: sptr_t,
        url: URL?,
        displayName: String,
        languageProfile: LanguageProfile,
        encoding: String.Encoding,
        encodingName: String,
        encodingNote: String?,
        eol: EOLMode
    ) {
        self.pointer = pointer
        self.url = url
        self.displayName = displayName
        self.languageProfile = languageProfile
        self.encoding = encoding
        self.encodingName = encodingName
        self.encodingNote = encodingNote
        self.eol = eol
    }
}

final class TabsViewModel: ObservableObject {
    @Published private(set) var documents: [Document] = []
    @Published private(set) var activeIndex: Int?

    let editor: ScintillaView
    let preferences: EditorPreferences
    let statusBar = StatusBarViewModel()
    let find = FindViewModel()
    let preview = MarkdownPreviewViewModel()
    let recentFiles: RecentFilesViewModel
    private(set) var currentTheme: EditorTheme = .light
    private var untitledCounter = 0

    init(editor: ScintillaView, preferences: EditorPreferences, recentFiles: RecentFilesViewModel) {
        self.editor = editor
        self.preferences = preferences
        self.recentFiles = recentFiles
        self.statusBar.editorRef = editor
    }

    var activeDocument: Document? {
        guard let activeIndex, documents.indices.contains(activeIndex) else { return nil }
        return documents[activeIndex]
    }

    /// Mismo dato que usa el coloreado de sintaxis (M2): el panel de preview y el
    /// resaltado no pueden discrepar sobre qué cuenta como Markdown.
    var activeDocumentIsMarkdown: Bool {
        activeDocument?.languageProfile.lexerName == "markdown"
    }

    // MARK: - Abrir

    /// Devuelve true sólo si el archivo quedó abierto: lo usa reopenLastClosed() para
    /// saber si tiene que seguir probando con la siguiente entrada de recientes.
    @discardableResult
    func open(url: URL) -> Bool {
        // Un archivo ya abierto se activa, no se vuelve a abrir: dos pestañas del mismo
        // archivo serían dos documentos Scintilla distintos, con ediciones que no se ven
        // entre sí y el último guardado pisando al otro.
        let target = url.standardizedFileURL
        if let index = documents.firstIndex(where: { $0.url?.standardizedFileURL == target }) {
            if index != activeIndex { activate(at: index) }
            recentFiles.add(url)
            return true
        }

        guard let data = try? Data(contentsOf: url) else {
            presentAlert(
                L("No se pudo abrir \(url.lastPathComponent)."),
                detail: L("El archivo no se encontró o no se pudo leer. Puede que se haya movido o borrado.")
            )
            recentFiles.remove(url)
            return false
        }
        let file = decodeWithDetectedEncoding(data)
        // Un NUL en el texto ya decodificado casi siempre significa UTF-16 sin BOM
        // (uchardet sólo reconoce UTF-16 por el BOM, y como NUL es UTF-8 válido el
        // archivo se decodifica "bien" pero sale ilegible) o un binario. Avisamos
        // en vez de abrirlo callados: guardarlo después reescribiría el original.
        if file.text.utf8.contains(0) {
            presentAlert(
                L("\(url.lastPathComponent) puede no ser un archivo de texto."),
                detail: L("Contiene bytes nulos. Suele pasar con archivos UTF-16 sin BOM o binarios. Si conoces su codificación, recárgalo desde el menú Codificación antes de editarlo; guardar tal como está podría dañarlo.")
            )
        }
        let profile = languageProfile(forExtension: url.pathExtension, theme: currentTheme)
        appendAndActivate(
            text: file.text,
            url: url,
            displayName: url.lastPathComponent,
            profile: profile,
            encoding: file.encoding,
            encodingName: file.encodingName,
            encodingNote: file.note,
            eol: file.eol
        )
        recentFiles.add(url)
        return true
    }

    /// Notepad++ no mantiene una pila aparte de cerrados: reabre la entrada más reciente
    /// de la MRU que no esté ya abierta en una pestaña, evitando duplicar una ya abierta.
    func reopenLastClosed() {
        let openURLs = Set(documents.compactMap { $0.url?.standardizedFileURL })
        // Notepad++ no guarda una pila aparte: reabre la entrada más reciente de la MRU que
        // no esté ya abierta. Si esa entrada ya no existe en disco, open(url:) la purga de la
        // lista y acá se sigue con la siguiente — cada fallo achica recentFiles.urls, así que
        // el bucle termina. Sin esto, ⇧⌘T sobre un reciente borrado no reabriría nada.
        while let url = recentFiles.urls.first(where: { !openURLs.contains($0.standardizedFileURL) }) {
            if open(url: url) { return }
        }
    }

    /// Documento vacío sin respaldo en disco. Se numeran de forma monótona: reusar
    /// el hueco de una pestaña cerrada haría que dos documentos distintos de la
    /// misma sesión compartan nombre.
    func newDocument() {
        untitledCounter += 1
        appendAndActivate(
            text: "",
            url: nil,
            displayName: L("sin título \(untitledCounter)"),
            profile: languageProfile(forExtension: "", theme: currentTheme),
            encoding: .utf8,
            encodingName: "UTF-8",
            encodingNote: nil,
            eol: .lf
        )
    }

    private func appendAndActivate(
        text: String,
        url: URL?,
        displayName: String,
        profile: LanguageProfile,
        encoding: String.Encoding,
        encodingName: String,
        encodingNote: String?,
        eol: EOLMode
    ) {
        let docPtr = ScintillaView.directCall(editor, message: SCI_CREATEDOCUMENT, wParam: 0, lParam: 0)
        let document = Document(
            pointer: docPtr,
            url: url,
            displayName: displayName,
            languageProfile: profile,
            encoding: encoding,
            encodingName: encodingName,
            encodingNote: encodingNote,
            eol: eol
        )
        documents.append(document)
        activeIndex = documents.count - 1
        attachToEditor(document)
        // eolMode vive en el Document de Scintilla, no en la vista (Editor.cxx:7090
        // escribe pdoc->eolMode), así que viaja con SCI_SETDOCPOINTER y basta con
        // fijarlo acá. Sin esto las líneas nuevas usarían el EOL del default de la
        // plataforma y un archivo CRLF terminaría mezclado.
        _ = ScintillaView.directCall(editor, message: SCI_SETEOLMODE, wParam: uptr_t(eol.rawValue), lParam: 0)
        loadText(editor, text)
        _ = ScintillaView.directCall(editor, message: SCI_SETSAVEPOINT, wParam: 0, lParam: 0)
    }

    // MARK: - Cambiar de pestaña / cerrar

    func activate(at index: Int) {
        guard documents.indices.contains(index), index != activeIndex else { return }
        syncDirtyFlagOfActiveDocument()
        activeIndex = index
        attachToEditor(documents[index])
    }

    func close(at index: Int) {
        guard documents.indices.contains(index) else { return }
        syncDirtyFlagOfActiveDocument()
        let document = documents[index]
        // Cualquier refresh de preview agendado apunta al documento que se va: cancelarlo
        // acá y no solo cuando la lista queda vacía, o correría con una carpeta base muerta.
        preview.cancelPendingRefresh()
        if document.isDirty, !confirmDiscard(message: L("\(document.displayName) tiene cambios sin guardar. ¿Cerrar de todas formas?")) {
            return
        }
        _ = ScintillaView.directCall(editor, message: SCI_RELEASEDOCUMENT, wParam: 0, lParam: document.pointer)
        documents.remove(at: index)
        if documents.isEmpty {
            activeIndex = nil
            statusBar.reset()
            find.reset()
            preview.cancelPendingRefresh()
            return
        }
        let newIndex = min(index, documents.count - 1)
        activeIndex = nil // fuerza que activate(at:) no haga early-return por "index != activeIndex"
        activate(at: newIndex)
    }

    private func attachToEditor(_ document: Document) {
        _ = ScintillaView.directCall(editor, message: SCI_SETDOCPOINTER, wParam: 0, lParam: document.pointer)
        publishFileInfo(of: document)
        reapplyPreferencesAndTheme()
    }

    private func publishFileInfo(of document: Document) {
        statusBar.encoding = document.encodingName
        statusBar.encodingNote = document.encodingNote
        statusBar.eol = document.eol.displayName
    }

    /// Reaplica fuente/opciones de edición, el lenguaje del documento activo y los colores
    /// globales del tema. SCI_STYLECLEARALL (dentro de applyLanguage) propaga STYLE_DEFAULT
    /// a TODOS los estilos numerados, incluido STYLE_LINENUMBER — por eso el tema global debe
    /// reaplicarse después de applyLanguage en cada attach, o el número de línea/caret/selección
    /// quedan pisados por los colores de texto plano.
    func reapplyPreferencesAndTheme() {
        preferences.apply(to: editor) // fuente primero (ver nota en EditorPreferences.applyFont)
        if let profile = activeDocument?.languageProfile {
            applyLanguage(editor, profile: profile)
        }
        applyGlobalStyle(theme: currentTheme)
    }

    private func syncDirtyFlagOfActiveDocument() {
        guard let document = activeDocument else { return }
        document.isDirty = ScintillaView.directCall(editor, message: SCI_GETMODIFY, wParam: 0, lParam: 0) != 0
    }

    private func confirmDiscard(message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: L("Descartar"))
        alert.addButton(withTitle: L("Cancelar"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Guardar

    func saveActive() {
        guard let document = activeDocument else { return }
        guard let url = document.url else {
            saveActiveAs()
            return
        }
        write(document: document, to: url)
    }

    /// Siempre pregunta el destino, incluso si el documento ya tiene ruta.
    func saveActiveAs() {
        guard let document = activeDocument else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.displayName
        if let current = document.url {
            panel.directoryURL = current.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // El documento se reapunta al destino nuevo SÓLO si la escritura salió
        // bien: si falla, renombrar la pestaña dejaría al usuario creyendo que su
        // trabajo vive en un archivo que nunca se creó.
        let previousExtension = document.url?.pathExtension.lowercased()
        guard write(document: document, to: url) else { return }
        document.url = url
        document.displayName = url.lastPathComponent
        recentFiles.add(url)

        // Guardar como .py algo que era .txt tiene que recolorearlo. Va por
        // reapplyPreferencesAndTheme y no por applyLanguage directo porque
        // SCI_STYLECLEARALL pisa STYLE_LINENUMBER, el caret y la selección.
        if url.pathExtension.lowercased() != previousExtension {
            document.languageProfile = languageProfile(forExtension: url.pathExtension, theme: currentTheme)
            reapplyPreferencesAndTheme()
        }
        // `documents` es @Published, pero Document es una clase: mutarle displayName
        // no republica nada por sí solo y la pestaña seguiría con el nombre viejo.
        objectWillChange.send()
    }

    // MARK: - Renombrar

    /// Mueve el archivo en disco y reapunta la pestaña. El buffer no se toca: las
    /// ediciones sin guardar siguen en la pestaña y se escriben en la ruta nueva
    /// al guardar, así que no hace falta forzar un guardado previo.
    func renameActive() {
        guard let document = activeDocument, let current = document.url else { return }
        guard let newName = promptForText(
            message: L("Renombrar archivo"),
            detail: L("Escribe el nombre nuevo. El archivo se mueve en disco; los cambios sin guardar no se pierden."),
            initialValue: current.lastPathComponent
        ) else { return }

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current.lastPathComponent else { return }

        // Renombrar cambia el nombre, no la ubicación. Sin esto, "sub/x.txt" movería el
        // archivo a otra carpeta y ".." lo subiría un nivel, con la pestaña reapuntada como
        // si todo hubiera salido bien. Notepad++ también rechaza separadores.
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentAlert(
                L("\(trimmed) no es un nombre de archivo válido."),
                detail: L("El nombre no puede contener «/» ni ser «.» o «..». Renombrar cambia el nombre, no la carpeta.")
            )
            return
        }

        let destination = current.deletingLastPathComponent().appendingPathComponent(trimmed)

        // Nunca sobrescribir: es la única forma de que renombrar destruya datos. Pero en un
        // volumen case-insensitive (APFS por default) renombrar "a.txt" a "A.txt" hace que
        // fileExists matchee el archivo de origen — por eso se compara la identidad del
        // archivo y no solo la ruta, o un cambio de mayúsculas sería imposible.
        if FileManager.default.fileExists(atPath: destination.path), !isSameFile(current, destination) {
            presentAlert(
                L("Ya existe un archivo llamado \(trimmed)."),
                detail: L("Elige otro nombre; renombrar no sobrescribe archivos.")
            )
            return
        }

        do {
            try FileManager.default.moveItem(at: current, to: destination)
        } catch {
            // El documento no se toca si el move falló: reapuntarlo dejaría la pestaña
            // creyendo que vive en un archivo que no existe.
            presentAlert(L("No se pudo renombrar \(current.lastPathComponent)."), detail: error.localizedDescription)
            return
        }

        document.url = destination
        document.displayName = destination.lastPathComponent
        recentFiles.remove(current)
        recentFiles.add(destination)

        // Renombrar .txt a .py tiene que recolorear. Igual que en saveActiveAs, va por
        // reapplyPreferencesAndTheme y no por applyLanguage directo porque
        // SCI_STYLECLEARALL pisa STYLE_LINENUMBER, el caret y la selección.
        if destination.pathExtension.lowercased() != current.pathExtension.lowercased() {
            document.languageProfile = languageProfile(forExtension: destination.pathExtension, theme: currentTheme)
            reapplyPreferencesAndTheme()
        }
        // Document es una clase dentro de un array @Published: mutarle displayName no
        // republica nada por sí solo y la pestaña seguiría con el nombre viejo.
        objectWillChange.send()
    }

    /// Devuelve true sólo si el archivo quedó escrito en disco.
    @discardableResult
    private func write(document: Document, to url: URL) -> Bool {
        let text = currentText(editor)
        guard let data = encode(text, for: document) else { return false }
        do {
            // .atomic escribe a un temporal y renombra: sin esto, un disco lleno o
            // un error de I/O a mitad de camino deja el archivo original truncado y
            // su contenido anterior perdido.
            try data.write(to: url, options: .atomic)
            document.isDirty = false
            _ = ScintillaView.directCall(editor, message: SCI_SETSAVEPOINT, wParam: 0, lParam: 0)
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

    /// ¿Las dos URLs apuntan al mismo archivo en disco? Compara la identidad que reporta el
    /// sistema de archivos, no la ruta: en un volumen case-insensitive "a.txt" y "A.txt" son
    /// rutas distintas y el mismo archivo.
    private func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let key: URLResourceKey = .fileResourceIdentifierKey
        guard let a = try? lhs.resourceValues(forKeys: [key]).fileResourceIdentifier,
              let b = try? rhs.resourceValues(forKeys: [key]).fileResourceIdentifier else {
            return false
        }
        return a.isEqual(b)
    }

    /// Pide una línea de texto con un NSAlert modal. Devuelve nil si el usuario cancela.
    /// Mismo criterio que goToLine: un NSAlert con accessory view evita sumar estado
    /// publicado y un ViewModel más para un diálogo de un solo campo.
    private func promptForText(message: String, detail: String, initialValue: String) -> String? {
        let field = NSTextField(string: initialValue)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)

        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.accessoryView = field
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancelar"))
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func presentAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    // MARK: - Recargar con encoding forzado (relee del disco, no reinterpreta en memoria)

    func reload(activeDocumentWithEncoding encodingName: String) {
        guard let document = activeDocument, let url = document.url else { return }
        if document.isDirty, !confirmDiscard(message: L("\(document.displayName) tiene cambios sin guardar. ¿Recargar de todas formas?")) {
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        let encoding = String.Encoding(rawValue: nsEncoding)
        guard let text = String(data: data, encoding: encoding) else {
            presentAlert(
                L("No se pudo releer \(document.displayName) como \(encodingName)."),
                detail: L("El contenido del archivo no es válido en esa codificación. El documento quedó como estaba.")
            )
            return
        }
        document.encoding = encoding
        document.encodingName = encodingName
        document.encodingNote = L("Forzado manualmente desde el menú Codificación.")
        document.eol = detectEOL(text)
        _ = ScintillaView.directCall(editor, message: SCI_SETEOLMODE, wParam: uptr_t(document.eol.rawValue), lParam: 0)
        publishFileInfo(of: document)
        loadText(editor, text)
        document.isDirty = false
        _ = ScintillaView.directCall(editor, message: SCI_SETSAVEPOINT, wParam: 0, lParam: 0)
    }

    // MARK: - Forzar lenguaje manualmente (solo sesión, no persiste)

    func forceLanguage(_ langName: String) {
        guard let document = activeDocument else { return }
        let profile = languageProfile(byLanguageName: langName, theme: currentTheme)
        document.languageProfile = profile
        applyLanguage(editor, profile: profile)
    }

    // MARK: - Tema (claro/oscuro, sigue al sistema)

    func applyTheme(_ theme: EditorTheme) {
        currentTheme = theme
        if let document = activeDocument, let url = document.url {
            let profile = languageProfile(forExtension: url.pathExtension, theme: theme)
            document.languageProfile = profile
            applyLanguage(editor, profile: profile)
        }
        applyGlobalStyle(theme: theme)
    }

    /// Colores globales del tema (no ligados a un lenguaje): fondo/texto por defecto, número
    /// de línea, selección y caret. Nombres confirmados leyendo <GlobalStyles> real de
    /// stylers.model.xml/DarkModeDefault.xml.
    private func applyGlobalStyle(theme: EditorTheme) {
        if let defaultStyle = globalStyle(name: "Default Style", theme: theme) {
            setStyle(editor, STYLE_DEFAULT, fore: defaultStyle.fore, back: defaultStyle.back)
        }
        if let lineNumber = globalStyle(name: "Line number margin", theme: theme) {
            setStyle(editor, STYLE_LINENUMBER, fore: lineNumber.fore, back: lineNumber.back)
        }
        if let selection = globalStyle(name: "Selected text colour", theme: theme), let back = selection.back {
            _ = ScintillaView.directCall(editor, message: SCI_SETSELBACK, wParam: 1, lParam: back)
        }
        if let caret = globalStyle(name: "Caret colour", theme: theme) {
            // SetCaretFore=2069(colour fore,) — el color va en wParam, no en lParam (confirmado
            // contra scintilla/include/Scintilla.iface). Invertido pisaba el caret a negro.
            _ = ScintillaView.directCall(editor, message: SCI_SETCARETFORE, wParam: uptr_t(caret.fore), lParam: 0)
        }
    }
}
