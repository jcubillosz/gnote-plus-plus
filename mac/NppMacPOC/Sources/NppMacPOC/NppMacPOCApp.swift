import SwiftUI
import AppKit
import Scintilla
import UniformTypeIdentifiers

/// Recibe application(_:open:) de LaunchServices ("Abrir con" del Finder, doble clic
/// en un tipo registrado en CFBundleDocumentTypes) y lo traduce a tabs.open(url:).
/// Sin esto, registrar los tipos en Info.plist es una promesa vacía: la app aparecería
/// en "Abrir con" pero elegirla no abriría nada.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var tabs: TabsViewModel?
    /// URLs de "Abrir con" del Finder que llegan durante el arranque en frío: AppKit puede
    /// invocar application(_:open:) antes de que el restore de sesión (Task 13) corra, así
    /// que se guardan acá y se consumen una sola vez desde ese restore. Después de
    /// consumidas, cualquier "Abrir con" nuevo (app ya corriendo) se abre directo.
    private(set) var pendingLaunchURLs: [URL] = []
    private var didConsumeLaunchURLs = false

    func application(_ application: NSApplication, open urls: [URL]) {
        if didConsumeLaunchURLs {
            for url in urls {
                tabs?.open(url: url)
            }
        } else {
            pendingLaunchURLs.append(contentsOf: urls)
        }
        bringMainWindowToFront()
    }

    /// Llamado una sola vez desde el restore de sesión al arranque.
    func consumeLaunchURLs() -> [URL] {
        didConsumeLaunchURLs = true
        let urls = pendingLaunchURLs
        pendingLaunchURLs = []
        return urls
    }

    /// El "Abrir con" del Finder puede llegar con la app en background o con su ventana
    /// minimizada/oculta: sin esto el archivo se abre en una pestaña que nadie ve.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        bringMainWindowToFront()
        return true
    }

    private func bringMainWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        // La ventana About también es una escena: buscar por identifier, no tomar la primera.
        let main = NSApp.windows.first { $0.identifier?.rawValue.contains(mainWindowID) == true }
            ?? NSApp.windows.first { $0.identifier?.rawValue.contains(aboutWindowID) != true }
        main?.deminiaturize(nil)
        main?.makeKeyAndOrderFront(nil)
    }

    /// Referencia al árbol de archivos para poder guardar su raíz al terminar (Task 13).
    /// Igual que `tabs`, se setea desde el onAppear de la ventana principal.
    var fileTree: FileTreeViewModel?

    private var willTerminateObserver: NSObjectProtocol?

    private var didBecomeActiveObserver: NSObjectProtocol?

    /// Registra el guardado de sesión al cerrar la app. Se llama una sola vez desde el
    /// onAppear de la ventana principal, cuando ya existen `tabs` y `fileTree`.
    /// Al volver a la app se revisan todos los documentos abiertos contra disco: red de
    /// seguridad por si FSEvents no entregó algún evento (ver ExternalFileChanges.swift).
    func observeActivationForExternalChanges() {
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.tabs?.checkExternalChanges()
        }
    }

    func observeTerminationForSessionSave() {
        guard willTerminateObserver == nil else { return }
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let tabs = self.tabs, let fileTree = self.fileTree else { return }
            SessionStore.save(tabs: tabs, fileTree: fileTree)
        }
    }
}

let mainWindowID = "main"

@main
struct NppMacPOCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let editor: ScintillaView
    @StateObject private var preferences: EditorPreferences
    @StateObject private var tabs: TabsViewModel
    @StateObject private var fileTree = FileTreeViewModel()
    // Sin default: se construye en init() y se comparte con TabsViewModel. Un
    // `= RecentPathsViewModel.files()` acá crearía una segunda instancia que corre load()
    // y se descarta, y dejaría dos listas divergentes si alguien borra la línea del init.
    @StateObject private var recentFiles: RecentPathsViewModel
    @StateObject private var recentFolders: RecentPathsViewModel
    @State private var didRestoreSession = false

    init() {
        let editor = ContextMenuScintillaView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        self.editor = editor
        // Margen 1 = números de línea (margen 0 queda para markers/breakpoints a futuro).
        _ = ScintillaView.directCall(editor, message: SCI_SETMARGINTYPEN, wParam: 1, lParam: sptr_t(SC_MARGIN_NUMBER))
        // Padding real de Notepad++: el texto pegado al borde izquierdo sin esto se ve mal.
        _ = ScintillaView.directCall(editor, message: SCI_SETMARGINLEFT, wParam: 0, lParam: 4)
        configureBookmarkAndFoldMargins(editor)
        configureChangeHistoryMargin(editor)
        configureMultipleSelection(editor)
        AutoComplete.configure(editor)

        // Indicador dedicado para resaltar todas las coincidencias de Find (no se reconfigura
        // por tema/lenguaje — es independiente de los estilos de sintaxis). Color en formato
        // 0x00BBGGRR (BGR), misma convención que setStyle() en ScintillaMessages.swift.
        // 0x0080FF = naranja (RGB #FF8000), visible sobre fondos claros y oscuros.
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETSTYLE, wParam: uptr_t(INDICATOR_FIND_HIGHLIGHT), lParam: sptr_t(INDIC_STRAIGHTBOX))
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETFORE, wParam: uptr_t(INDICATOR_FIND_HIGHLIGHT), lParam: 0x0080FF)

        // Indicador para el match actual (el que selecciona findNext/findPrevious), separado del
        // 9 para que se distinga del resto de coincidencias. Rojo puro (BGR 0x0000FF = RGB #FF0000)
        // con alpha y SCI_INDICSETUNDER (dibuja bajo el texto) para no taparlo ni opacar la
        // selección nativa que ya marca el rango.
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETSTYLE, wParam: uptr_t(INDICATOR_FIND_CURRENT), lParam: sptr_t(INDIC_STRAIGHTBOX))
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETFORE, wParam: uptr_t(INDICATOR_FIND_CURRENT), lParam: 0x0000FF)
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETALPHA, wParam: uptr_t(INDICATOR_FIND_CURRENT), lParam: 120)
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETUNDER, wParam: uptr_t(INDICATOR_FIND_CURRENT), lParam: 1)

        // Smart highlight (SmartHighlight.swift): caja redondeada verde translúcida bajo el
        // texto, distinta del naranja de "resaltar todo" de Find.
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETSTYLE, wParam: uptr_t(INDICATOR_SMART_HIGHLIGHT), lParam: sptr_t(INDIC_ROUNDBOX))
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETFORE, wParam: uptr_t(INDICATOR_SMART_HIGHLIGHT), lParam: 0x00C000)
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETALPHA, wParam: uptr_t(INDICATOR_SMART_HIGHLIGHT), lParam: 80)
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETUNDER, wParam: uptr_t(INDICATOR_SMART_HIGHLIGHT), lParam: 1)

        // Tags XML/HTML pareados (BraceMatcher): misma caja translúcida que el smart
        // highlight pero en azul, para que no se confundan.
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETSTYLE, wParam: uptr_t(INDICATOR_TAG_MATCH), lParam: sptr_t(INDIC_ROUNDBOX))
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETFORE, wParam: uptr_t(INDICATOR_TAG_MATCH), lParam: 0xD07A2E)
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETALPHA, wParam: uptr_t(INDICATOR_TAG_MATCH), lParam: 90)
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETUNDER, wParam: uptr_t(INDICATOR_TAG_MATCH), lParam: 1)

        // Indicador de corrector ortográfico (Task 10): squiggle rojo bajo el texto, mismo
        // estilo visual que el corrector nativo de macOS en NSTextView. SCI_INDICSETUNDER lo
        // dibuja bajo el texto para no interferir con la selección ni otros indicadores.
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETSTYLE, wParam: uptr_t(INDICATOR_SPELL), lParam: sptr_t(INDIC_SQUIGGLEPIXMAP))
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETFORE, wParam: uptr_t(INDICATOR_SPELL), lParam: 0x0000E0)
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETUNDER, wParam: uptr_t(INDICATOR_SPELL), lParam: 1)

        let prefs = EditorPreferences()
        let recents = RecentPathsViewModel.files()
        let recentDirs = RecentPathsViewModel.folders()
        _preferences = StateObject(wrappedValue: prefs)
        _recentFiles = StateObject(wrappedValue: recents)
        _recentFolders = StateObject(wrappedValue: recentDirs)
        _tabs = StateObject(wrappedValue: TabsViewModel(editor: editor, preferences: prefs, recentFiles: recents))
        DonationPrompt.registerFirstLaunchIfNeeded()
    }

    var body: some Scene {
        // Window y no WindowGroup: el ScintillaView es UNA instancia compartida por toda
        // la app (ver ScintillaEditorView). Con WindowGroup, abrir un archivo desde el
        // Finder hacía que SwiftUI creara una segunda ventana, cuyo ScintillaEditorView
        // reparentaba el editor compartido fuera de la primera — texto invisible, solo
        // quedaba operando la preview de Markdown, y la selección se comportaba raro.
        Window(L("GNote++"), id: mainWindowID) {
            ContentView(tabs: tabs, fileTree: fileTree, recentFiles: recentFiles, recentFolders: recentFolders, preferences: preferences)
                .onAppear {
                    appDelegate.tabs = tabs
                    appDelegate.fileTree = fileTree
                    appDelegate.observeTerminationForSessionSave()
                    appDelegate.observeActivationForExternalChanges()
                    // Restauración de sesión (Task 13): solo la primera vez que aparece la
                    // ventana principal — un onAppear repetido (ej. reabrir tras minimizar)
                    // no debe reabrir todo de nuevo.
                    if !didRestoreSession {
                        didRestoreSession = true
                        let actions = DocumentActions(tabs: tabs, fileTree: fileTree, recentFiles: recentFiles, recentFolders: recentFolders, preferences: preferences)
                        SessionStore.restore(tabs: tabs, fileTree: fileTree, actions: actions, finderURLs: appDelegate.consumeLaunchURLs())
                    }
                }
        }
        .commands {
            AppCommands(tabs: tabs, fileTree: fileTree, recentFiles: recentFiles, recentFolders: recentFolders, preview: tabs.preview, spellCheck: tabs.spellCheck, preferences: preferences)
        }

        Settings {
            PreferencesView(preferences: preferences, tabs: tabs)
        }

        // Escena propia en vez del panel About por defecto: hace falta espacio para
        // los créditos, el aviso de GPL y el bloque de donación.
        Window(L("Acerca de GNote++"), id: aboutWindowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    @AppStorage(SmartHighlighter.enabledDefaultsKey) private var smartHighlightEnabled = true

    /// Hay documento activo y no está bloqueado — requisito de las operaciones que editan texto.
    private var canEditActive: Bool {
        tabs.activeIndex != nil && tabs.activeDocument?.isLocked != true
    }

    @ObservedObject var tabs: TabsViewModel
    @ObservedObject var fileTree: FileTreeViewModel
    // RecentPathsViewModel vive anidado dentro de TabsViewModel, pero un ObservableObject
    // anidado no reenvía objectWillChange al padre: hay que observarlo directo acá para
    // que el menú se refresque cuando cambian los recientes.
    @ObservedObject var recentFiles: RecentPathsViewModel
    // Las carpetas recientes son otra instancia y otro ObservableObject: necesita su
    // propia suscripción o el menú no se refresca al abrir una carpeta.
    @ObservedObject var recentFolders: RecentPathsViewModel
    // Mismo motivo: el check del toggle de la preview depende de preview.isVisible, que
    // vive en un ObservableObject anidado y no publica a través de `tabs`.
    @ObservedObject var preview: MarkdownPreviewViewModel
    // Idem: los checks del menú Ortografía (enabled/language) viven en otro
    // ObservableObject anidado.
    @ObservedObject var spellCheck: SpellCheckViewModel
    // Idem: los checks del menú Vista leen preferences.wordWrap/showLineNumbers/
    // showWhitespace, que viven en otro ObservableObject anidado.
    @ObservedObject var preferences: EditorPreferences

    private let commonEncodings = ["UTF-8", "UTF-16LE", "UTF-16BE", "ISO-8859-1", "Windows-1252"]

    private var actions: DocumentActions {
        DocumentActions(tabs: tabs, fileTree: fileTree, recentFiles: recentFiles, recentFolders: recentFolders, preferences: preferences)
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("Acerca de GNote++")) { openWindow(id: aboutWindowID) }
        }

        CommandGroup(replacing: .newItem) {
            Button(L("Nuevo")) { tabs.newDocument() }
                .keyboardShortcut("n", modifiers: .command)
            Button(L("Abrir archivo…")) { actions.openFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button(L("Abrir carpeta…")) { actions.openFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Menu(L("Abrir recientes")) {
                ForEach(recentFiles.urls, id: \.self) { url in
                    Button(url.lastPathComponent) { tabs.open(url: url) }
                        .help(url.path)
                }
                Divider()
                Button(L("Restaurar archivo cerrado")) { tabs.reopenLastClosed() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button(L("Vaciar lista de recientes")) { recentFiles.clear() }
            }
            .disabled(recentFiles.urls.isEmpty)
            Menu(L("Abrir carpetas recientes")) {
                ForEach(recentFolders.urls, id: \.self) { url in
                    // add() ademas de openFolder: sin esto, elegir una carpeta del menu
                    // no la sube al tope y la lista deja de reflejar el uso real.
                    Button(url.lastPathComponent) {
                        fileTree.openFolder(url)
                        recentFolders.add(url)
                    }
                    .help(url.path)
                }
                Divider()
                Button(L("Vaciar lista de carpetas")) { recentFolders.clear() }
            }
            .disabled(recentFolders.urls.isEmpty)
            Divider()
            Button(L("Cerrar pestaña")) {
                if let index = tabs.activeIndex { tabs.close(at: index) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(tabs.activeIndex == nil)
            Button(L("Guardar")) { tabs.saveActive() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(tabs.activeIndex == nil)
            Button(L("Guardar como…")) { tabs.saveActiveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(tabs.activeIndex == nil)
            Button(L("Renombrar…")) {
                tabs.renameActive()
                // renameActive() no refresca el árbol por sí solo; el watcher lo haría
                // igual en ~0.3s, pero el usuario espera ver el nombre nuevo al instante.
                fileTree.refresh()
            }
            .disabled(tabs.activeDocument?.url == nil)
            Divider()
            // Tamaño de papel (carta, legal, A4…): el PDF de Markdown se pagina con él.
            Button(L("Ajustar página…")) { NSPageLayout().runModal(with: NSPrintInfo.shared) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button(L("Imprimir…")) { actions.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(tabs.activeIndex == nil)
            if preview.isVisible, tabs.activeDocumentIsMarkdown {
                Button(L("Imprimir vista previa…")) { actions.printMarkdownPreview() }
            }
            Button(L("Exportar a HTML…")) { actions.export(asPDF: false) }
                .disabled(tabs.activeIndex == nil)
            Button(L("Exportar a PDF…")) { actions.export(asPDF: true) }
                .disabled(tabs.activeIndex == nil)
        }

        CommandGroup(after: .textEditing) {
            Button(L("Buscar…")) {
                tabs.find.isVisible = true
                tabs.find.showReplace = false
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(tabs.activeIndex == nil)

            Button(L("Buscar y reemplazar…")) {
                tabs.find.isVisible = true
                tabs.find.showReplace = true
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(tabs.activeIndex == nil)

            Button(L("Buscar siguiente")) {
                if tabs.find.isVisible || !tabs.find.findText.isEmpty {
                    findNext(editor: tabs.editor, find: tabs.find)
                }
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(tabs.activeIndex == nil)

            Button(L("Buscar anterior")) {
                if tabs.find.isVisible || !tabs.find.findText.isEmpty {
                    findPrevious(editor: tabs.editor, find: tabs.find)
                }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(tabs.activeIndex == nil)

            Button(L("Buscar en archivos…")) {
                tabs.outline.sidebarTab = .search
                tabs.outline.showRequestToken += 1
                tabs.findInFiles.focusRequestToken += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button(L("Ir a la línea…")) { goToLine(editor: tabs.editor) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(tabs.activeIndex == nil)

            Menu(L("Marcadores")) {
                Button(L("Alternar marcador")) { toggleBookmark(editor: tabs.editor) }
                    .keyboardShortcut(functionKey(2), modifiers: .command)
                Button(L("Siguiente marcador")) { goToBookmark(editor: tabs.editor, forward: true) }
                    .keyboardShortcut(functionKey(2), modifiers: [])
                Button(L("Marcador anterior")) { goToBookmark(editor: tabs.editor, forward: false) }
                    .keyboardShortcut(functionKey(2), modifiers: .shift)
                Divider()
                Button(L("Borrar todos los marcadores")) { clearBookmarks(editor: tabs.editor) }
            }
            .disabled(tabs.activeIndex == nil)

            Divider()
            Menu(L("Operaciones de línea")) {
                Button(L("Duplicar línea")) { duplicateSelectionOrLine(editor: tabs.editor) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button(L("Eliminar línea")) { deleteCurrentLine(editor: tabs.editor) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button(L("Mover línea arriba")) { moveSelectedLines(editor: tabs.editor, up: true) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button(L("Mover línea abajo")) { moveSelectedLines(editor: tabs.editor, up: false) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button(L("Unir líneas")) { joinLines(editor: tabs.editor) }
                    .keyboardShortcut("j", modifiers: [.command, .control])
                Divider()
                Button(L("Ordenar líneas (A→Z)")) { transformLines(editor: tabs.editor, .sortAscending) }
                Button(L("Ordenar líneas (Z→A)")) { transformLines(editor: tabs.editor, .sortDescending) }
                Button(L("Quitar duplicadas consecutivas")) { transformLines(editor: tabs.editor, .removeConsecutiveDuplicates) }
                Button(L("Quitar todas las duplicadas")) { transformLines(editor: tabs.editor, .removeAllDuplicates) }
                Button(L("Quitar líneas vacías")) { transformLines(editor: tabs.editor, .removeEmptyLines) }
            }
            .disabled(!canEditActive)
            Menu(L("Selección múltiple")) {
                Button(L("Agregar siguiente coincidencia")) { addNextOccurrence(editor: tabs.editor, all: false) }
                    .keyboardShortcut("d", modifiers: .command)
                Button(L("Seleccionar todas las coincidencias")) { addNextOccurrence(editor: tabs.editor, all: true) }
                    .keyboardShortcut("g", modifiers: [.command, .control])
                Button(L("Agregar cursor arriba")) { addCursorVertically(editor: tabs.editor, up: true) }
                    .keyboardShortcut(.upArrow, modifiers: [.control, .shift])
                Button(L("Agregar cursor abajo")) { addCursorVertically(editor: tabs.editor, up: false) }
                    .keyboardShortcut(.downArrow, modifiers: [.control, .shift])
            }
            .disabled(!canEditActive)
            Menu(L("Convertir mayúsculas/minúsculas")) {
                Button(L("MAYÚSCULAS")) { convertCase(editor: tabs.editor, upper: true) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button(L("minúsculas")) { convertCase(editor: tabs.editor, upper: false) }
                    .keyboardShortcut("u", modifiers: [.command, .control])
                Button(L("Tipo Título")) { convertToTitleCase(editor: tabs.editor) }
            }
            .disabled(!canEditActive)
            Button(L("Comentar/descomentar")) {
                if let syntax = tabs.activeDocument?.languageProfile.comment {
                    toggleComment(editor: tabs.editor, syntax: syntax)
                }
            }
            // ⌘K como el Ctrl+K de Notepad++: ⌘/ caía en la misma tecla física que ⌘− (zoom)
            // con teclado español.
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!canEditActive || tabs.activeDocument?.languageProfile.comment.isAvailable != true)
            Button(L("Formatear tabla Markdown")) {
                if !MarkdownEditing.formatTable(editor: tabs.editor) { NSSound.beep() }
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(!canEditActive || tabs.activeDocument?.languageProfile.lexerName != "markdown")

            Divider()
            Toggle(L("Bloquear edición"), isOn: Binding(
                get: { tabs.activeDocument?.isLocked ?? false },
                // El valor nuevo lo decide toggleLockActive() (invierte lo que ya tenía el
                // documento activo, no lo que llegó acá) — un Binding normal alcanza porque
                // Toggle en un menú solo necesita algo que asignar para mostrar el checkmark.
                set: { _ in tabs.toggleLockActive() }
            ))
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(tabs.activeIndex == nil)

            Divider()
            Menu(L("Ortografía")) {
                Toggle(L("Revisar ortografía"), isOn: $spellCheck.enabled)
                    .keyboardShortcut(";", modifiers: [.command, .shift])
                Divider()
                Toggle(L("Español"), isOn: Binding(
                    get: { spellCheck.language == "es" },
                    set: { if $0 { spellCheck.language = "es" } }
                ))
                Toggle(L("Inglés"), isOn: Binding(
                    get: { spellCheck.language == "en" },
                    set: { if $0 { spellCheck.language = "en" } }
                ))
                Toggle(L("Automático"), isOn: Binding(
                    get: { spellCheck.language == "auto" },
                    set: { if $0 { spellCheck.language = "auto" } }
                ))
            }
        }

        CommandMenu(L("Lenguaje")) {
            ForEach(languageMenuGroups(), id: \.label) { group in
                Menu(group.label) {
                    ForEach(group.names, id: \.self) { name in
                        Button(name) { tabs.forceLanguage(name) }
                            .disabled(tabs.activeIndex == nil)
                    }
                }
            }
        }

        CommandMenu(L("Codificación")) {
            ForEach(commonEncodings, id: \.self) { encoding in
                Button(L("Recargar como \(encoding)")) { tabs.reload(activeDocumentWithEncoding: encoding) }
                    .disabled(tabs.activeIndex == nil || tabs.activeDocument?.isLocked == true)
            }
            Divider()
            Button(L("Convertir fin de línea a Windows (CRLF)")) { tabs.convertActiveEOL(to: .crlf) }
                .disabled(tabs.activeIndex == nil || tabs.activeDocument?.isLocked == true)
            Button(L("Convertir fin de línea a Unix (LF)")) { tabs.convertActiveEOL(to: .lf) }
                .disabled(tabs.activeIndex == nil || tabs.activeDocument?.isLocked == true)
            Button(L("Convertir fin de línea a Mac clásico (CR)")) { tabs.convertActiveEOL(to: .cr) }
                .disabled(tabs.activeIndex == nil || tabs.activeDocument?.isLocked == true)
        }

        CommandMenu(L("Vista")) {
            Toggle(L("Ajuste de línea"), isOn: Binding(
                get: { preferences.wordWrap },
                set: { preferences.wordWrap = $0; preferences.applyEditingOptions(to: tabs.editor) }
            ))
            Toggle(L("Números de línea"), isOn: Binding(
                get: { preferences.showLineNumbers },
                set: { preferences.showLineNumbers = $0; preferences.applyEditingOptions(to: tabs.editor) }
            ))
            Toggle(L("Resaltar coincidencias de la selección"), isOn: Binding(
                get: { smartHighlightEnabled },
                set: { smartHighlightEnabled = $0; SmartHighlighter.update(editor: tabs.editor) }
            ))
            Button(L("Acercar")) { preferences.zoom = min(preferences.zoom + 1, 20); preferences.applyEditingOptions(to: tabs.editor) }
                .keyboardShortcut("+", modifiers: .command)
            Button(L("Alejar")) { preferences.zoom = max(preferences.zoom - 1, -10); preferences.applyEditingOptions(to: tabs.editor) }
                .keyboardShortcut("-", modifiers: .command)
            Button(L("Tamaño real")) { preferences.zoom = 0; preferences.applyEditingOptions(to: tabs.editor) }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Toggle(L("Autocompletar"), isOn: Binding(
                get: { preferences.autoComplete },
                set: { preferences.autoComplete = $0 }
            ))
            Toggle(L("Mostrar minimapa"), isOn: Binding(
                get: { preferences.showDocumentMap },
                set: { preferences.showDocumentMap = $0 }
            ))
            .keyboardShortcut("m", modifiers: [.command, .control])
            Toggle(L("Margen de plegado"), isOn: Binding(
                get: { preferences.showFoldMargin },
                set: { preferences.showFoldMargin = $0; preferences.applyEditingOptions(to: tabs.editor) }
            ))
            Button(L("Plegar todo")) { foldAll(editor: tabs.editor, expand: false) }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(tabs.activeIndex == nil)
            Button(L("Desplegar todo")) { foldAll(editor: tabs.editor, expand: true) }
                .keyboardShortcut("0", modifiers: [.command, .option, .shift])
                .disabled(tabs.activeIndex == nil)
            Toggle(L("Mostrar espacios en blanco"), isOn: Binding(
                get: { preferences.showWhitespace },
                set: { preferences.showWhitespace = $0; preferences.applyEditingOptions(to: tabs.editor) }
            ))
            Toggle(L("Historial de cambios en el margen"), isOn: Binding(
                get: { preferences.showChangeHistory },
                set: { preferences.showChangeHistory = $0; preferences.applyEditingOptions(to: tabs.editor) }
            ))
            Toggle(L("Autocerrar paréntesis y comillas"), isOn: Binding(
                get: { preferences.autoCloseBrackets },
                set: { preferences.autoCloseBrackets = $0 }
            ))
            Toggle(L("Recortar espacios finales al guardar"), isOn: Binding(
                get: { preferences.trimTrailingWhitespaceOnSave },
                set: { preferences.trimTrailingWhitespaceOnSave = $0 }
            ))
            Divider()
            Toggle(L("Solo editor"), isOn: Binding(
                get: { preview.mode == .editor },
                set: { if $0 { preview.mode = .editor } }
            ))
            .keyboardShortcut("1", modifiers: [.command, .option])
            .disabled(!tabs.activeDocumentIsMarkdown)
            Toggle(L("Dividida"), isOn: Binding(
                get: { preview.mode == .split },
                set: { if $0 { preview.mode = .split } }
            ))
            .keyboardShortcut("2", modifiers: [.command, .option])
            .disabled(!tabs.activeDocumentIsMarkdown)
            Toggle(L("Solo vista previa"), isOn: Binding(
                get: { preview.mode == .preview },
                set: { if $0 { preview.mode = .preview } }
            ))
            .keyboardShortcut("3", modifiers: [.command, .option])
            .disabled(!tabs.activeDocumentIsMarkdown)
            // ⌥⌘P conserva la función previa (Task 7 brief): alterna solo entre editor y
            // dividida, sin pasar nunca a solo-vista-previa desde el atajo histórico.
            Button(L("Alternar vista dividida")) {
                preview.mode = preview.mode == .split ? .editor : .split
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!tabs.activeDocumentIsMarkdown)
            Divider()
            Button(L("Mostrar esquema")) {
                tabs.outline.sidebarTab = .outline
                tabs.outline.showRequestToken += 1
            }
            .keyboardShortcut("o", modifiers: [.command, .control])
            Divider()
            Button(L("Pestaña siguiente")) { tabs.activateAdjacent(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(tabs.documents.count < 2)
            Button(L("Pestaña anterior")) { tabs.activateAdjacent(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(tabs.documents.count < 2)
        }
    }

}

/// Tecla de función como KeyEquivalent de SwiftUI (F1 = NSF1FunctionKey = 0xF704).
func functionKey(_ number: Int) -> KeyEquivalent {
    KeyEquivalent(Character(UnicodeScalar(0xF704 + number - 1)!))
}
