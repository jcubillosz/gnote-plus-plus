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

    func openFolder(_ url: URL) {
        root = FileNode(url: url, isDirectory: true)
    }
}
