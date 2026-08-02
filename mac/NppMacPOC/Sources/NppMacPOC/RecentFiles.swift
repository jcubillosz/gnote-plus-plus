import Foundation

/// Lista MRU de rutas, persistida en UserDefaults. Se usa dos veces con claves distintas:
/// archivos recientes y carpetas recientes. La app no está sandboxeada (decisión de P4),
/// así que no hace falta lidiar con security-scoped bookmarks.
final class RecentPathsViewModel: ObservableObject {
    @Published private(set) var urls: [URL] = []
    private let maxCount = 10
    private let defaultsKey: String

    init(defaultsKey: String) {
        self.defaultsKey = defaultsKey
        load()
    }

    /// Descarta rutas que ya no existen en disco: un archivo o carpeta borrado fuera
    /// de la app no debe quedar de fantasma en el menú.
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

// Las claves se conservan tal cual estaban para no perder la lista que el usuario
// ya tenía acumulada al actualizar.
extension RecentPathsViewModel {
    static func files() -> RecentPathsViewModel { RecentPathsViewModel(defaultsKey: "recentFiles") }
    static func folders() -> RecentPathsViewModel { RecentPathsViewModel(defaultsKey: "recentFolders") }
}
