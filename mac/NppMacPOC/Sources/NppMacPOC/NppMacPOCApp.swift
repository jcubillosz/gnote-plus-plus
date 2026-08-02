import SwiftUI
import AppKit
import Scintilla

@main
struct NppMacPOCApp: App {
    private let editor: ScintillaView
    @StateObject private var preferences: EditorPreferences
    @StateObject private var tabs: TabsViewModel
    @StateObject private var fileTree = FileTreeViewModel()
    // Sin default: se construye en init() y se comparte con TabsViewModel. Un
    // `= RecentFilesViewModel()` acá crearía una segunda instancia que corre load()
    // y se descarta, y dejaría dos listas divergentes si alguien borra la línea del init.
    @StateObject private var recentFiles: RecentFilesViewModel

    init() {
        let editor = ScintillaView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        self.editor = editor
        // Margen 1 = números de línea (margen 0 queda para markers/breakpoints a futuro).
        _ = ScintillaView.directCall(editor, message: SCI_SETMARGINTYPEN, wParam: 1, lParam: sptr_t(SC_MARGIN_NUMBER))
        // Padding real de Notepad++: el texto pegado al borde izquierdo sin esto se ve mal.
        _ = ScintillaView.directCall(editor, message: SCI_SETMARGINLEFT, wParam: 0, lParam: 4)

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

        let prefs = EditorPreferences()
        let recents = RecentFilesViewModel()
        _preferences = StateObject(wrappedValue: prefs)
        _recentFiles = StateObject(wrappedValue: recents)
        _tabs = StateObject(wrappedValue: TabsViewModel(editor: editor, preferences: prefs, recentFiles: recents))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(tabs: tabs, fileTree: fileTree)
        }
        .commands {
            AppCommands(tabs: tabs, fileTree: fileTree, recentFiles: recentFiles, preview: tabs.preview, preferences: preferences)
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

    @ObservedObject var tabs: TabsViewModel
    @ObservedObject var fileTree: FileTreeViewModel
    // RecentFilesViewModel vive anidado dentro de TabsViewModel, pero un ObservableObject
    // anidado no reenvía objectWillChange al padre: hay que observarlo directo acá para
    // que el menú se refresque cuando cambian los recientes.
    @ObservedObject var recentFiles: RecentFilesViewModel
    // Mismo motivo: el check del toggle de la preview depende de preview.isVisible, que
    // vive en un ObservableObject anidado y no publica a través de `tabs`.
    @ObservedObject var preview: MarkdownPreviewViewModel
    // Idem: los checks del menú Vista leen preferences.wordWrap/showLineNumbers/
    // showWhitespace, que viven en otro ObservableObject anidado.
    @ObservedObject var preferences: EditorPreferences

    private let commonEncodings = ["UTF-8", "UTF-16LE", "UTF-16BE", "ISO-8859-1", "Windows-1252"]

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("Acerca de GNote++")) { openWindow(id: aboutWindowID) }
        }

        CommandGroup(replacing: .newItem) {
            Button(L("Nuevo")) { tabs.newDocument() }
                .keyboardShortcut("n", modifiers: .command)
            Button(L("Abrir archivo…")) { openFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button(L("Abrir carpeta…")) { openFolder() }
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
            Button(L("Renombrar…")) { tabs.renameActive() }
                .disabled(tabs.activeDocument?.url == nil)
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

            Button(L("Ir a la línea…")) { goToLine(editor: tabs.editor) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(tabs.activeIndex == nil)
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
                    .disabled(tabs.activeIndex == nil)
            }
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
            Toggle(L("Mostrar espacios en blanco"), isOn: Binding(
                get: { preferences.showWhitespace },
                set: { preferences.showWhitespace = $0; preferences.applyEditingOptions(to: tabs.editor) }
            ))
            Divider()
            Toggle(L("Vista previa de Markdown"), isOn: $preview.isVisible)
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!tabs.activeDocumentIsMarkdown)
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            tabs.open(url: url)
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            fileTree.openFolder(url)
        }
    }
}
