import Foundation

/// Lista de archivos recientes (MRU), persistida en UserDefaults como rutas. La app no está
/// sandboxeada (decisión de P4), así que no hace falta lidiar con security-scoped bookmarks.
final class RecentFilesViewModel: ObservableObject {
    @Published private(set) var urls: [URL] = []
    private let maxCount = 10
    private let defaultsKey = "recentFiles"

    init() {
        load()
    }

    /// Descarta rutas que ya no existen en disco: un archivo borrado fuera de la app
    /// no debe quedar de fantasma en el menú.
    private func load() {
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        urls = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        persist()
    }

    func add(_ url: URL) {
        let standardized = url.standardizedFileURL
        urls.removeAll { $0.standardizedFileURL == standardized }
        urls.insert(standardized, at: 0)
        if urls.count > maxCount {
            urls.removeLast(urls.count - maxCount)
        }
        persist()
    }

    /// Para cuando abrir falla porque el archivo se movió o se borró.
    func remove(_ url: URL) {
        let standardized = url.standardizedFileURL
        urls.removeAll { $0.standardizedFileURL == standardized }
        persist()
    }

    func clear() {
        urls = []
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(urls.map { $0.path }, forKey: defaultsKey)
    }
}
