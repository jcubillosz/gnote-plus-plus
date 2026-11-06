import SwiftUI
import AppKit
import Scintilla

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let tabs else { return .terminateNow }
        let dirty = tabs.dirtyDocuments
        guard !dirty.isEmpty else { return .terminateNow }
        bringMainWindowToFront()
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? L("\(dirty[0].displayName) tiene cambios sin guardar.")
            : L("Hay \(dirty.count) documentos con cambios sin guardar.")
        alert.informativeText = L("Si sales sin guardar, los cambios se pierden.")
        alert.addButton(withTitle: L("Guardar todo"))
        let cancel = alert.addButton(withTitle: L("Cancelar"))
        // NSAlert solo asigna Escape a un botón titulado literalmente "Cancel".
        cancel.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: L("Descartar cambios"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return tabs.saveAll() ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
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

        configureIndicators(editor)

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
