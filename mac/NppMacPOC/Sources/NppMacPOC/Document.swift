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
    /// Lenguaje elegido a mano en el menú (nil = el de la extensión). Hace falta recordarlo
    /// porque un cambio de tema re-perfila todos los documentos y lo perdería.
    var forcedLanguageName: String?
    /// Encoding con el que se leyó y con el que se vuelve a escribir. Guardar en
    /// otro encoding cambiaría el archivo sin que el usuario lo pida.
    var encoding: String.Encoding
    var encodingName: String
    var encodingNote: String?
    var eol: EOLMode
    var isDirty: Bool = false
    /// Solo lectura visible (tinte navy) e impuesto en Scintilla. Persistido por ruta en
    /// LockedFiles; un documento "Nuevo" sin URL se bloquea solo durante la sesión (no hay
    /// ruta que persistir). SCI_SETREADONLY se guarda por documento de Scintilla, pero esta
    /// propiedad es la fuente de verdad — attachToEditor la reaplica en cada activación.
    var isLocked: Bool = false
    /// Selección y scroll de la última vez que este documento estuvo activo. SCI_SETDOCPOINTER
    /// limpia ambos al cambiar de pestaña, así que sin esto volver a una pestaña siempre
    /// arrancaría con el caret al inicio. nil = documento recién creado, nunca desactivado.
    var viewState: ViewState?
    /// Tag único de NSSpellChecker para este documento (Task 10). Cada documento necesita
    /// el suyo: NSSpellChecker usa el tag para recordar "ignorar esta palabra" por
    /// documento, y compartir uno entre pestañas mezclaría esas decisiones.
    let spellDocumentTag: Int = NSSpellChecker.uniqueSpellDocumentTag()
    /// Idioma del corrector detectado para este documento en modo "auto" ("es"/"en") y el
    /// largo del documento al detectarlo — ver SpellChecker.resolvedLanguage.
    var detectedSpellLanguage: String?
    var detectedSpellLanguageLength = 0
    /// Stamp del archivo en disco al abrir/guardar/recargar (ver ExternalFileChanges.swift).
    var diskStamp: FileStamp?
    /// El archivo se borró o se movió desde afuera; guardar lo vuelve a crear.
    var missingOnDisk = false
    /// Cambió en disco mientras la pestaña estaba inactiva: se resuelve al activarla.
    var needsReload = false
    var pendingExternalConflict = false

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

/// Estado de vista (selección/scroll) de un documento, capturado justo antes de desactivarlo.
/// Codable porque una task futura (restauración de sesión) lo persiste a UserDefaults como JSON.
struct ViewState: Codable, Equatable {
    var selection: String
    var firstVisibleLine: Int
    var xOffset: Int
}

final class TabsViewModel: ObservableObject {
    @Published private(set) var documents: [Document] = [] {
        didSet { updateWatchedFolders() }
    }
    @Published private(set) var activeIndex: Int?

    /// Reordena pestañas (arrastrar). `destination` es el índice final del documento movido.
    /// No hay SETDOCPOINTER: el documento activo sigue siendo el mismo, solo cambia su índice.
    func moveDocument(from source: Int, to destination: Int) {
        guard documents.indices.contains(source), documents.indices.contains(destination),
              source != destination else { return }
        let active = activeIndex.map { documents[$0] }
        var reordered = documents
        reordered.insert(reordered.remove(at: source), at: destination)
        documents = reordered
        if let active { activeIndex = documents.firstIndex { $0 === active } }
    }

    let editor: ScintillaView
    let preferences: EditorPreferences
    let statusBar = StatusBarViewModel()
    let find = FindViewModel()
    let preview = MarkdownPreviewViewModel()
    let spellCheck = SpellCheckViewModel()
    let outline = OutlineViewModel()
    let findInFiles = FindInFilesViewModel()
    let recentFiles: RecentPathsViewModel
    private(set) var currentTheme: EditorTheme = .light
    private var untitledCounter = 0
    /// Observa las carpetas de los documentos abiertos (ExternalFileChanges.swift).
    var openFilesWatcher: OpenFilesWatcher?
    var watchedFolders: [String] = []
    /// Evita apilar alertas de "cambió en disco" mientras una ya está abierta.
    var isPresentingExternalChangeAlert = false

    /// Minimapa: un ScintillaView aparte que comparte el documento del editor.
    lazy var documentMap = DocumentMapView(editor: editor)

    init(editor: ScintillaView, preferences: EditorPreferences, recentFiles: RecentPathsViewModel) {
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
            eol: file.eol,
            locked: LockedFiles.isLocked(url)
        )
        activeDocument?.diskStamp = FileStamp.of(url)
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
        eol: EOLMode,
        locked: Bool = false
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
        document.isLocked = locked
        // El documento saliente (si lo hay) también pierde selección/scroll al hacer
        // SETDOCPOINTER más abajo, y este camino no pasa por activate(at:) — sin esto,
        // abrir un archivo nuevo dejaría la pestaña anterior sin su viewState guardado.
        syncDirtyFlagOfActiveDocument()
        saveViewStateOfActive()
        documents.append(document)
        activeIndex = documents.count - 1
        attachToEditor(document)
        // eolMode vive en el Document de Scintilla, no en la vista (Editor.cxx:7090
        // escribe pdoc->eolMode), así que viaja con SCI_SETDOCPOINTER y basta con
        // fijarlo acá. Sin esto las líneas nuevas usarían el EOL del default de la
        // plataforma y un archivo CRLF terminaría mezclado.
        _ = ScintillaView.directCall(editor, message: SCI_SETEOLMODE, wParam: uptr_t(eol.rawValue), lParam: 0)
        loadText(editor, text)
        // Sin esto, Cmd+Z justo después de abrir vacía el documento recién cargado: para
        // Scintilla, cargar texto es "una edición más" y queda en el buffer de undo.
        _ = ScintillaView.directCall(editor, message: SCI_EMPTYUNDOBUFFER, wParam: 0, lParam: 0)
        resetChangeHistory(editor)
        _ = ScintillaView.directCall(editor, message: SCI_SETSAVEPOINT, wParam: 0, lParam: 0)
    }

    // MARK: - Cambiar de pestaña / cerrar

    func activate(at index: Int) {
        guard documents.indices.contains(index), index != activeIndex else { return }
        syncDirtyFlagOfActiveDocument()
        saveViewStateOfActive()
        activeIndex = index
        attachToEditor(documents[index])
        resolveDeferredExternalChange(of: documents[index])
    }

    /// Pestaña siguiente (+1) o anterior (−1), con vuelta al principio/final.
    func activateAdjacent(_ offset: Int) {
        guard !documents.isEmpty else { return }
        let current = activeIndex ?? 0
        activate(at: ((current + offset) % documents.count + documents.count) % documents.count)
    }

    // close(at:) y applyTheme viven en la clase, no en TabsViewModel+Saving/+Theme: escriben
    // documents/activeIndex/currentTheme, que son private(set) y una extensión en otro archivo
    // no puede mutarlos.

    /// false si el usuario canceló (o el guardado falló).
    @discardableResult
    func close(at index: Int) -> Bool {
        guard documents.indices.contains(index) else { return true }
        syncDirtyFlagOfActiveDocument()
        let document = documents[index]
        let previouslyActive = activeDocument
        if document.isDirty {
            // Editor compartido: para ver y guardar lo que se cierra tiene que estar activo.
            if document !== activeDocument { activate(at: index) }
            switch askSaveBeforeClosing(document) {
            case .cancel: return false
            case .save: guard saveActive() else { return false }
            case .discard: break
            }
        }
        let editorShowsClosed = (document === activeDocument)
        guard let closingIndex = documents.firstIndex(where: { $0 === document }) else { return true }
        // Cualquier refresh de preview agendado apunta al documento que se va: cancelarlo
        // acá y no solo cuando la lista queda vacía, o correría con una carpeta base muerta.
        if editorShowsClosed { preview.cancelPendingRefresh() }
        _ = ScintillaView.directCall(editor, message: SCI_RELEASEDOCUMENT, wParam: 0, lParam: document.pointer)
        // Libera el estado de "ignorar palabra"/aprendizaje que NSSpellChecker guarda por
        // tag: sin esto, tags de pestañas cerradas se acumulan durante toda la sesión.
        NSSpellChecker.shared.closeSpellDocument(withTag: document.spellDocumentTag)
        documents.remove(at: closingIndex)
        if documents.isEmpty {
            activeIndex = nil
            statusBar.reset()
            find.reset()
            preview.cancelPendingRefresh()
            return true
        }
        if let previouslyActive, previouslyActive !== document,
           let i = documents.firstIndex(where: { $0 === previouslyActive }) {
            // B4: cerrar una pestaña inactiva no cambia la activa; solo se reactiva si el
            // editor había quedado mostrando la cerrada.
            if editorShowsClosed { activeIndex = nil; activate(at: i) } else { activeIndex = i }
        } else {
            activeIndex = nil // fuerza que activate(at:) no haga early-return por "index != activeIndex"
            activate(at: min(closingIndex, documents.count - 1))
        }
        return true
    }

    var dirtyDocuments: [Document] {
        syncDirtyFlagOfActiveDocument()
        return documents.filter { $0.isDirty }
    }

    private func attachToEditor(_ document: Document) {
        _ = ScintillaView.directCall(editor, message: SCI_SETDOCPOINTER, wParam: 0, lParam: document.pointer)
        // Scintilla guarda solo-lectura por documento, pero Document.isLocked es la fuente
        // de verdad: reaplicarlo en cada activación cubre tanto la primera apertura como
        // volver a una pestaña ya bloqueada.
        // SCI_SETREADONLY(bool readOnly): el booleano va en wParam, no en lParam (bug real
        // encontrado en QA manual: con lParam el mensaje no hacía nada y se podía seguir
        // editando y guardando un documento "bloqueado").
        _ = ScintillaView.directCall(editor, message: SCI_SETREADONLY, wParam: document.isLocked ? 1 : 0, lParam: 0)
        publishFileInfo(of: document)
        reapplyPreferencesAndTheme()
        restoreViewState(of: document)
        // SCI_SETDOCPOINTER puede disparar una notificación de savepoint espuria para el
        // documento recién adjuntado (el editor compara contra el estado del doc anterior).
        // Resincronizar acá contra SCI_GETMODIFY corrige cualquier isDirty que haya quedado
        // mal seteado por esa notificación falsa.
        let modified = ScintillaView.directCall(editor, message: SCI_GETMODIFY, wParam: 0, lParam: 0) != 0
        if document.isDirty != modified {
            document.isDirty = modified
            objectWillChange.send()
        }
    }

    func publishFileInfo(of document: Document) {
        statusBar.encoding = document.encodingName
        statusBar.encodingNote = document.encodingNote
        statusBar.eol = document.eol.displayName
    }

    func syncDirtyFlagOfActiveDocument() {
        guard let document = activeDocument else { return }
        document.isDirty = ScintillaView.directCall(editor, message: SCI_GETMODIFY, wParam: 0, lParam: 0) != 0
    }

    /// Captura selección y scroll del documento activo antes de desactivarlo (cambio de
    /// pestaña o apertura de una nueva). SCI_SETDOCPOINTER los limpia, así que si no se
    /// guardan acá se pierden para siempre.
    /// No-private: SessionStore (Task 13) la llama al terminar la app para volcar la
    /// selección/scroll vigente del documento activo antes de persistir la sesión.
    func saveViewStateOfActive() {
        guard let document = activeDocument else { return }
        document.viewState = ViewState(
            selection: selectionSerialized(editor),
            firstVisibleLine: Int(ScintillaView.directCall(editor, message: SCI_GETFIRSTVISIBLELINE, wParam: 0, lParam: 0)),
            xOffset: Int(ScintillaView.directCall(editor, message: SCI_GETXOFFSET, wParam: 0, lParam: 0))
        )
    }

    /// Reaplica selección y scroll guardados. Sin viewState (documento recién creado) no
    /// hace nada y el documento arranca como Scintilla lo deja por defecto (inicio, sin
    /// selección). Deliberadamente sin SCROLLCARET/GOTOPOS después: eso movería el scroll
    /// para asegurar que el caret sea visible, pisando el xOffset/firstVisibleLine exactos
    /// que se acaban de restaurar.
    /// No-private: SessionStore (Task 13) la reaplica explícitamente tras activar la
    /// pestaña restaurada como activa, para el caso en que activate(at:) hace early-return
    /// por ya estar en ese índice (última pestaña abierta == pestaña activa guardada).
    func restoreViewState(of document: Document) {
        guard let viewState = document.viewState else { return }
        setSelectionSerialized(editor, viewState.selection)
        _ = ScintillaView.directCall(editor, message: SCI_SETFIRSTVISIBLELINE, wParam: uptr_t(viewState.firstVisibleLine), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETXOFFSET, wParam: uptr_t(viewState.xOffset), lParam: 0)
    }

    /// Se llama desde los callbacks SCN_SAVEPOINTLEFT/SCN_SAVEPOINTREACHED de Scintilla (vía
    /// ContentView) cada vez que el documento se aleja o vuelve al savepoint. A diferencia de
    /// SC_UPDATE_CONTENT (que también se dispara al recolorear sin cambios reales), el
    /// savepoint solo cruza con ediciones/undo/redo genuinos.
    func setActiveDirty(_ dirty: Bool) {
        guard let document = activeDocument, document.isDirty != dirty else { return }
        document.isDirty = dirty
        // Document es una clase dentro de un array @Published: mutarle isDirty no
        // republica nada por sí solo, y el punto de la pestaña no aparecería.
        objectWillChange.send()
    }

    // MARK: - Bloqueo de edición

    /// Invierte el bloqueo del documento activo. Persiste por ruta si el documento tiene
    /// una (un "Nuevo" sin guardar se bloquea solo para esta sesión), aplica el read-only
    /// real en Scintilla y reaplica tema/estilos para que el tinte navy aparezca o
    /// desaparezca de inmediato.
    func toggleLockActive() {
        guard let document = activeDocument else { return }
        document.isLocked.toggle()
        if let url = document.url {
            LockedFiles.set(url, locked: document.isLocked)
        }
        // Ver el comentario en attachToEditor: el booleano de SCI_SETREADONLY va en wParam.
        _ = ScintillaView.directCall(editor, message: SCI_SETREADONLY, wParam: document.isLocked ? 1 : 0, lParam: 0)
        reapplyPreferencesAndTheme()
        // Document es una clase dentro de un array @Published: mutarle isLocked no
        // republica nada por sí solo, y el botón/menú de candado no se actualizarían.
        objectWillChange.send()
    }

    // MARK: - Renombrar

    /// Mueve el archivo activo en disco y reapunta la pestaña. Wrapper sobre `renameItem`
    /// que agrega el prompt: la lógica de validación/move/rebase vive ahí para que el rename
    /// inline del árbol (Sidebar) la reuse sin pasar por un diálogo modal.
    func renameActive() {
        guard let document = activeDocument, let current = document.url else { return }
        guard let newName = promptForText(
            message: L("Renombrar archivo"),
            detail: L("Escribe el nombre nuevo. El archivo se mueve en disco; los cambios sin guardar no se pierden."),
            initialValue: current.lastPathComponent
        ) else { return }
        renameItem(at: current, to: newName)
    }

    /// Mueve un archivo o carpeta en disco a un nombre nuevo dentro de la misma carpeta y
    /// reapunta cualquier pestaña abierta afectada. El buffer no se toca: las ediciones sin
    /// guardar siguen en la pestaña y se escriben en la ruta nueva al guardar, así que no
    /// hace falta forzar un guardado previo. Usado por `renameActive()` (documento activo,
    /// vía prompt) y por el rename inline del árbol de archivos.
    /// Devuelve la URL destino si el rename se hizo, o nil si se canceló o falló (ya se
    /// mostró el alert correspondiente).
    @discardableResult
    func renameItem(at url: URL, to newName: String) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return nil }

        // Renombrar cambia el nombre, no la ubicación. Sin esto, "sub/x.txt" movería el
        // archivo a otra carpeta y ".." lo subiría un nivel, con la pestaña reapuntada como
        // si todo hubiera salido bien. Notepad++ también rechaza separadores.
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentAlert(
                L("\(trimmed) no es un nombre de archivo válido."),
                detail: L("El nombre no puede contener «/» ni ser «.» o «..». Renombrar cambia el nombre, no la carpeta.")
            )
            return nil
        }

        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)

        // Nunca sobrescribir: es la única forma de que renombrar destruya datos. Pero en un
        // volumen case-insensitive (APFS por default) renombrar "a.txt" a "A.txt" hace que
        // fileExists matchee el archivo de origen — por eso se compara la identidad del
        // archivo y no solo la ruta, o un cambio de mayúsculas sería imposible.
        if FileManager.default.fileExists(atPath: destination.path), !isSameFile(url, destination) {
            presentAlert(
                L("Ya existe un archivo llamado \(trimmed)."),
                detail: L("Elige otro nombre; renombrar no sobrescribe archivos.")
            )
            return nil
        }

        var isDirectoryFlag: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectoryFlag)

        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            // El documento no se toca si el move falló: reapuntarlo dejaría la pestaña
            // creyendo que vive en un archivo que no existe.
            presentAlert(L("No se pudo renombrar \(url.lastPathComponent)."), detail: error.localizedDescription)
            return nil
        }

        rebaseOpenTabs(from: url, to: destination, isDirectory: isDirectoryFlag.boolValue)
        // Document es una clase dentro de un array @Published: mutarle displayName no
        // republica nada por sí solo y la pestaña seguiría con el nombre viejo.
        objectWillChange.send()
        return destination
    }

    /// Mueve un archivo o carpeta a otra carpeta (arrastrar en el árbol o "Mover a…"), con las
    /// mismas reglas que renameItem: nunca sobrescribe y reapunta las pestañas afectadas.
    /// Devuelve la URL destino, o nil si no se movió (ya se mostró el alert si correspondía).
    @discardableResult
    func moveItem(at url: URL, toFolder folder: URL) -> URL? {
        guard let destination = transferDestination(for: url, in: folder, verb: L("mover")) else { return nil }
        var isDirectoryFlag: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectoryFlag)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            presentAlert(L("No se pudo mover \(url.lastPathComponent)."), detail: error.localizedDescription)
            return nil
        }
        rebaseOpenTabs(from: url, to: destination, isDirectory: isDirectoryFlag.boolValue)
        objectWillChange.send()
        return destination
    }

    /// Copia un archivo o carpeta a otra carpeta (soltar desde Finder sobre el árbol, igual
    /// que Finder entre volúmenes). Nunca sobrescribe.
    @discardableResult
    func copyItem(at url: URL, toFolder folder: URL) -> URL? {
        guard let destination = transferDestination(for: url, in: folder, verb: L("copiar")) else { return nil }
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            presentAlert(L("No se pudo copiar \(url.lastPathComponent)."), detail: error.localizedDescription)
            return nil
        }
        return destination
    }

    /// Destino válido para mover/copiar `url` dentro de `folder`, o nil. Misma carpeta = no
    /// hacer nada en silencio; una carpeta dentro de sí misma o de un descendiente, o un
    /// nombre ya existente en el destino, se rechazan con alerta.
    private func transferDestination(for url: URL, in folder: URL, verb: String) -> URL? {
        let source = url.standardizedFileURL
        let target = folder.standardizedFileURL
        guard source.deletingLastPathComponent().path != target.path else { return nil }
        if target.path == source.path || target.path.hasPrefix(source.path + "/") {
            presentAlert(
                L("No se puede \(verb) \(source.lastPathComponent) dentro de sí misma."),
                detail: L("Elige una carpeta que no esté dentro de la carpeta que mueves.")
            )
            return nil
        }
        let destination = target.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            presentAlert(
                L("Ya existe \(source.lastPathComponent) en \(target.lastPathComponent)."),
                detail: L("No se sobrescriben archivos; renombra uno de los dos primero.")
            )
            return nil
        }
        return destination
    }

    /// Reapunta toda pestaña abierta afectada por un rename/move en disco. Archivo: solo la
    /// pestaña con esa URL exacta. Carpeta: toda pestaña cuya ruta viva bajo ella — se compara
    /// el prefijo sobre standardizedFileURL.path para no depender de cómo haya llegado la URL.
    private func rebaseOpenTabs(from old: URL, to new: URL, isDirectory: Bool) {
        defer { updateWatchedFolders() }
        if isDirectory {
            let oldPrefix = old.standardizedFileURL.path + "/"
            // Migra TODO path bloqueado bajo la carpeta vieja, no solo el de las pestañas
            // abiertas: un archivo bloqueado que no está abierto en este momento también
            // vive bajo `old` y perdería su bloqueo (ruta vieja huérfana) si solo se migraran
            // los de `documents`.
            LockedFiles.moveTree(from: old, to: new)
            for document in documents {
                guard let docURL = document.url else { continue }
                let docPath = docURL.standardizedFileURL.path
                guard docPath.hasPrefix(oldPrefix) else { continue }
                let suffix = String(docPath.dropFirst(oldPrefix.count))
                let newURL = new.standardizedFileURL.appendingPathComponent(suffix)

                recentFiles.remove(docURL)
                recentFiles.add(newURL)
                document.url = newURL
                document.displayName = newURL.lastPathComponent
            }
        } else {
            guard let document = documents.first(where: {
                $0.url?.standardizedFileURL.path == old.standardizedFileURL.path
            }) else { return }

            let previousExtension = old.pathExtension.lowercased()
            LockedFiles.move(from: old, to: new)
            recentFiles.remove(old)
            recentFiles.add(new)
            document.url = new
            document.displayName = new.lastPathComponent

            // Renombrar .txt a .py tiene que recolorear. Igual que en saveActiveAs, va por
            // reapplyPreferencesAndTheme y no por applyLanguage directo porque
            // SCI_STYLECLEARALL pisa STYLE_LINENUMBER, el caret y la selección. Solo si es
            // la pestaña activa: recolorear una inactiva pisaría el estilo del documento
            // que sí está en pantalla (ScintillaView es uno solo y compartido).
            if new.pathExtension.lowercased() != previousExtension {
                document.forcedLanguageName = nil
                document.languageProfile = languageProfile(forExtension: new.pathExtension, theme: currentTheme)
                if document === activeDocument {
                    reapplyPreferencesAndTheme()
                }
            }
        }
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

    private func confirmDiscard(message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: L("Descartar"))
        alert.addButton(withTitle: L("Cancelar"))
        return alert.runModal() == .alertFirstButtonReturn
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

    // MARK: - Tema (claro/oscuro, sigue al sistema)

    private func profile(for document: Document, theme: EditorTheme) -> LanguageProfile {
        if let name = document.forcedLanguageName {
            return languageProfile(byLanguageName: name, theme: theme)
        }
        return languageProfile(forExtension: document.url?.pathExtension ?? "", theme: theme)
    }

    func applyTheme(_ theme: EditorTheme) {
        currentTheme = theme
        // Los colores del tema van horneados en el perfil: hay que re-perfilar también los
        // documentos de fondo, o al activarlos conservarían los colores del tema anterior.
        for document in documents {
            document.languageProfile = profile(for: document, theme: theme)
        }
        // Ruta única: reapplyPreferencesAndTheme() ya hace, en orden, el reset de
        // STYLE_DEFAULT previo a STYLECLEARALL (ver su comentario) + applyLanguage +
        // applyGlobalStyle + applyLockTint si el documento activo está bloqueado. Antes,
        // este método duplicaba applyLanguage/applyGlobalStyle sin el reset ni el tinte:
        // un cambio de tema con el documento bloqueado dejaba estilo 0 navy del tema
        // VIEJO pisado por STYLECLEARALL sin corregir, y encima nunca reaplicaba el tinte
        // del tema nuevo. Iba por acá que un toggle de tema con un documento de texto
        // plano bloqueado (o recién desbloqueado) filtraba navy a otras pestañas.
        reapplyPreferencesAndTheme()
    }

    // MARK: - Convertir fin de línea

    /// Convierte todos los fines de línea del documento activo y fija el modo para las líneas
    /// nuevas (Notepad++: IDM_FORMAT_TODOS/TOUNIX/TOMAC). Una sola acción de undo; marca el
    /// documento como modificado por la vía normal (SCN_SAVEPOINTLEFT).
    func convertActiveEOL(to eol: EOLMode) {
        guard let document = activeDocument, !document.isLocked else { return }
        _ = ScintillaView.directCall(editor, message: SCI_BEGINUNDOACTION, wParam: 0, lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_CONVERTEOLS, wParam: uptr_t(eol.rawValue), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_ENDUNDOACTION, wParam: 0, lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETEOLMODE, wParam: uptr_t(eol.rawValue), lParam: 0)
        document.eol = eol
        publishFileInfo(of: document)
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
        // Se invalida en vez de dejar que Scintilla la acote: forzar un encoding puede cambiar
        // radicalmente el contenido decodificado (mojibake -> texto real), así que la posición
        // de scroll/selección vieja ya no tiene relación con lo que el usuario ve.
        document.viewState = nil
        loadText(editor, text)
        // Mismo motivo que en appendAndActivate: sin esto, Cmd+Z después de recargar
        // vaciaría el documento en vez de deshacer una edición real.
        _ = ScintillaView.directCall(editor, message: SCI_EMPTYUNDOBUFFER, wParam: 0, lParam: 0)
        resetChangeHistory(editor)
        document.diskStamp = FileStamp.of(url)
        document.isDirty = false
        _ = ScintillaView.directCall(editor, message: SCI_SETSAVEPOINT, wParam: 0, lParam: 0)
    }

}
