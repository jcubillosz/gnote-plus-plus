import Foundation

/// Un nodo del árbol de archivos. `children` se calcula bajo demanda (SwiftUI's OutlineGroup
/// solo lo pide cuando el nodo se expande/renderiza), no se escanea todo el árbol de una.
struct FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }

    var children: [FileNode]? {
        guard isDirectory else { return nil }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { child in
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return FileNode(url: child, isDirectory: isDir)
            }
    }
}

final class FileTreeViewModel: ObservableObject {
    @Published var root: FileNode?
    /// Cuando se setea, la fila con esta URL entra en modo rename inline en el Sidebar.
    /// Usado por Task 6 (crear archivo/carpeta nuevo) para arrancar directo en rename;
    /// el Sidebar lo limpia a nil una vez que arranca a editar esa fila.
    @Published var pendingRenameURL: URL?
    /// URL del archivo recién creado por "Nuevo archivo" (Task 6), en espera de que termine
    /// su rename inline (confirmado o cancelado) para abrirse en una pestaña. El Sidebar lo
    /// consume y limpia en ambos caminos; nil el resto del tiempo, y nunca se usa para
    /// carpetas (una carpeta no se "abre").
    @Published var createdFileAwaitingOpen: URL?
    /// Carpeta a mostrar en el árbol (ruta de navegación): el Sidebar la despliega y la limpia.
    @Published var revealRequest: URL?
    private var watcher: DirectoryWatcher?
    let gitStatus = GitStatusModel()
    /// Índice de "Abrir rápido" (vive en TabsViewModel); se conecta desde la ventana principal
    /// antes de restaurar la sesión, pero por las dudas se indexa la raíz que ya hubiera.
    weak var fileIndex: FileIndex? {
        didSet { if fileIndex !== oldValue, let root { fileIndex?.reindex(root: root.url) } }
    }

    func openFolder(_ url: URL) {
        root = FileNode(url: url, isDirectory: true)
        fileIndex?.reindex(root: url)
        watcher?.stop()
        gitStatus.setFolder(url)
        // `[weak self]` porque el watcher vive en una CFRunLoop/dispatch queue, no atado
        // al ciclo de vida normal de SwiftUI — sin esto, un refresh tardío podría llegar
        // después de que el view model ya no exista.
        watcher = DirectoryWatcher(url: url) { [weak self] in
            self?.refresh()
            // El watcher no informa rutas: cualquier evento (incluido .git/) refresca con debounce.
            self?.gitStatus.scheduleRefresh()
            self?.fileIndex?.reindex(root: url, debounced: true)
        }
    }

    /// `FileNode.children` relee el disco en cada acceso (ver comentario arriba), así que
    /// alcanza con forzar un re-render — no hay estado que recalcular acá.
    func refresh() {
        objectWillChange.send()
    }

    deinit {
        watcher?.stop()
    }
}
