import Foundation

/// Persistencia de sesión (Task 13): pestañas abiertas (URL, orden, viewState), índice
/// activo y carpeta raíz del árbol, para restaurar todo al relanzar la app.
///
/// Sandboxing: la app corre SIN App Sandbox. `AppResources/GNotePP.entitlements` es un
/// plist vacío (sin `com.apple.security.app-sandbox`) — el comentario del propio archivo
/// dice explícitamente que es "el mínimo que exige el hardened runtime para notarizar" y
/// que el sandboxing quedaría para el futuro. `scripts/make_app_bundle.sh` firma ad-hoc
/// (`codesign --sign -`, sin perfil de distribución) y `scripts/release_notarize.sh` es
/// notarización de app fuera de la Mac App Store, que no exige sandbox. Por eso acá se
/// usan bookmarks PLANOS (`bookmarkData()` sin `.withSecurityScope`): ese flag solo
/// aplica (y solo hace falta) bajo App Sandbox. Un bookmark plano ya resuelve lo que pide
/// la task — que el archivo siga encontrándose si se movió mientras la app no corría.
enum SessionStore {
    private static let defaultsKey = "session.v1"

    struct Snapshot: Codable {
        struct Tab: Codable {
            var bookmark: Data
            var viewState: ViewState?
        }
        var tabs: [Tab]
        var activeIndex: Int?
        var rootFolderBookmark: Data?
    }

    // MARK: - Guardar

    /// Se llama desde NSApplication.willTerminateNotification. Los documentos sin URL
    /// ("sin título N") no se guardan — no hay nada que reabrir.
    static func save(tabs: TabsViewModel, fileTree: FileTreeViewModel) {
        // Vuelca selección/scroll vigentes del documento activo a su Document.viewState
        // antes de leerlo: SCI_SETDOCPOINTER solo lo hace al cambiar de pestaña, y acá
        // la pestaña activa nunca se "cambió".
        tabs.saveViewStateOfActive()

        var sessionTabs: [Snapshot.Tab] = []
        var activeIndexInSnapshot: Int?
        for (index, document) in tabs.documents.enumerated() {
            guard let url = document.url, let bookmark = try? url.bookmarkData() else { continue }
            if index == tabs.activeIndex {
                activeIndexInSnapshot = sessionTabs.count
            }
            sessionTabs.append(Snapshot.Tab(bookmark: bookmark, viewState: document.viewState))
        }

        let rootBookmark = fileTree.root.flatMap { try? $0.url.bookmarkData() }

        let snapshot = Snapshot(tabs: sessionTabs, activeIndex: activeIndexInSnapshot, rootFolderBookmark: rootBookmark)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - Restaurar

    /// `finderURLs`: archivos pedidos por "Abrir con" del Finder al lanzar la app (pueden
    /// venir vacíos). Por brief: la sesión se restaura igual, y esos archivos se abren
    /// después, quedando como pestaña activa final (tabs.open(url:) siempre activa lo que
    /// abre). Si no hay sesión guardada ni finderURLs, se crea un documento "Nuevo" vacío
    /// — mismo comportamiento que la app tenía antes de esta task.
    static func restore(tabs: TabsViewModel, fileTree: FileTreeViewModel, actions: DocumentActions, finderURLs: [URL]) {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            for url in finderURLs { tabs.open(url: url) }
            if tabs.documents.isEmpty { tabs.newDocument() }
            return
        }

        if let rootBookmark = snapshot.rootFolderBookmark, let rootURL = resolvedURL(from: rootBookmark) {
            actions.openFolder(url: rootURL)
        }

        // El índice original del snapshot puede no corresponder ya a `documents` una vez
        // restaurado: pestañas cuyo bookmark no resuelve, o cuyo open() falla, se saltean, así
        // que `documents` queda más corto/reordenado que `snapshot.tabs`. Por eso se recuerda
        // la URL de la pestaña que estaba activa al guardar, y se activa ESA URL al final —
        // nunca la posición numérica original.
        let activeURL: URL? = snapshot.activeIndex.flatMap { index in
            snapshot.tabs.indices.contains(index) ? resolvedURL(from: snapshot.tabs[index].bookmark) : nil
        }

        for tab in snapshot.tabs {
            // Bookmark no resuelve (archivo borrado/movido a un volumen no montado): se
            // omite sin error, tal como pide la verificación manual de la task.
            guard let url = resolvedURL(from: tab.bookmark) else { continue }
            if tabs.open(url: url),
               let document = tabs.documents.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
                document.viewState = tab.viewState
                // tabs.open(url:) activa lo que abre vía appendAndActivate, y ESE camino llama
                // saveViewStateOfActive() sobre la pestaña saliente ANTES de agregar la nueva —
                // es decir, antes de que exista un "editor" apuntando al doc recién restaurado.
                // Si no se reaplica acá inmediatamente, la PRÓXIMA apertura pisaría el
                // viewState recién asignado (lo sobreescribiría con el (0,0) que el editor
                // tiene en este instante) al capturarlo de vuelta en su propio
                // saveViewStateOfActive(). Reaplicarlo ahora hace que ese saveViewStateOfActive
                // posterior capture el valor correcto en vez de perderlo.
                tabs.restoreViewState(of: document)
            }
        }

        if let activeURL, let activeDocument = tabs.documents.first(where: { $0.url?.standardizedFileURL == activeURL.standardizedFileURL }),
           let index = tabs.documents.firstIndex(where: { $0 === activeDocument }) {
            tabs.activate(at: index)
            // activate(at:) hace early-return si el índice pedido ya era el activo (caso
            // típico: la última pestaña abierta arriba también es la que estaba activa al
            // guardar la sesión) — reaplicar acá cubre ese caso; restoreViewState() es
            // idempotente.
            tabs.restoreViewState(of: activeDocument)
        }

        for url in finderURLs {
            tabs.open(url: url)
        }

        if tabs.documents.isEmpty {
            tabs.newDocument()
        }
    }

    private static func resolvedURL(from bookmark: Data) -> URL? {
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
}
