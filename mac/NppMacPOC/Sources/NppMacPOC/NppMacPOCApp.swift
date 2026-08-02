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

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            tabs?.open(url: url)
        }
    }
}

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
        let recents = RecentPathsViewModel.files()
        let recentDirs = RecentPathsViewModel.folders()
        _preferences = StateObject(wrappedValue: prefs)
        _recentFiles = StateObject(wrappedValue: recents)
        _recentFolders = StateObject(wrappedValue: recentDirs)
        _tabs = StateObject(wrappedValue: TabsViewModel(editor: editor, preferences: prefs, recentFiles: recents))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(tabs: tabs, fileTree: fileTree, recentFiles: recentFiles, recentFolders: recentFolders, preferences: preferences)
                .onAppear { appDelegate.tabs = tabs }
        }
        .commands {
            AppCommands(tabs: tabs, fileTree: fileTree, recentFiles: recentFiles, recentFolders: recentFolders, preview: tabs.preview, preferences: preferences)
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
            Button(L("Renombrar…")) { tabs.renameActive() }
                .disabled(tabs.activeDocument?.url == nil)
            Divider()
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

}
