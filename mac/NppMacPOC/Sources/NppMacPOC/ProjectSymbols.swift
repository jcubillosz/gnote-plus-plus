// Símbolos de todos los archivos de la carpeta abierta para "Abrir rápido" (`#símbolo`), con las
// mismas reglas functionList del Esquema.
import Foundation
import Combine

// BEGIN-PURE
struct ProjectSymbol {
    let name: String
    let relativePath: String
    /// Base 0, como `OutlineItem.line`.
    let line: Int
    let folded: FoldedCandidate
}

struct ProjectSymbolCacheEntry {
    let modified: Date
    let size: Int
    let symbols: [ProjectSymbol]
}

/// Parsea `paths` (relativas a `root`) con la regla de cada extensión. Solo cuentan para el tope
/// los archivos con regla; los que superan `maxBytes` se ignoran. `cache` se reutiliza por
/// (ruta, mtime, tamaño) y queda solo con los archivos vistos en esta pasada; si se cancela,
/// conserva además lo ya parseado para que la pasada siguiente no lo repita.
func scanProjectSymbols(root: URL, paths: [String], maxFiles: Int, maxBytes: Int,
                        cache: inout [String: ProjectSymbolCacheEntry],
                        rule: (String) -> FunctionListRule?, isCancelled: () -> Bool,
                        progress: (([ProjectSymbol], Int) -> Void)? = nil)
-> (symbols: [ProjectSymbol], indexedFiles: Int, finished: Bool) {
    var symbols: [ProjectSymbol] = []
    var newCache: [String: ProjectSymbolCacheEntry] = [:]
    var files = 0
    var parsed = 0
    for path in paths {
        if files >= maxFiles { break }
        if isCancelled() {
            cache.merge(newCache) { _, new in new }
            return (symbols, files, false)
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let fileRule = rule(ext) else { continue }
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath()
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let size = values.fileSize, size <= maxBytes else { continue }
        let modified = values.contentModificationDate ?? .distantPast
        files += 1
        if let cached = cache[path], cached.modified == modified, cached.size == size {
            newCache[path] = cached
            symbols += cached.symbols
        } else {
            guard let data = try? Data(contentsOf: url) else { continue }
            let found = fileRule.parse(data.map { CChar(bitPattern: $0) }).map {
                ProjectSymbol(name: $0.title, relativePath: path, line: $0.line, folded: FoldedCandidate($0.title))
            }
            newCache[path] = ProjectSymbolCacheEntry(modified: modified, size: size, symbols: found)
            symbols += found
            parsed += 1
            if parsed % 200 == 0 { progress?(symbols, files) }
        }
    }
    cache = newCache
    return (symbols, files, true)
}
// END-PURE

/// Índice en segundo plano; se arranca la primera vez que se usa `#` (no gasta CPU si nadie lo usa).
final class ProjectSymbolIndex: ObservableObject {
    static let maxFiles = 5_000
    static let maxBytes = 1_000_000

    @Published private(set) var symbols: [ProjectSymbol] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var indexedFiles = 0

    private let queue = DispatchQueue(label: "projectsymbols.index", qos: .utility)
    private let lock = NSLock()
    private var generation = 0
    /// Solo se toca desde `queue`.
    private var cache: [String: ProjectSymbolCacheEntry] = [:]
    private var cacheRoot: URL?
    private var languageByExtension: [String: String?] = [:]
    private var root: URL?
    private var paths: [String] = []
    private var subscription: AnyCancellable?
    private var hasIndexed = false

    /// Primer uso: indexa y sigue al `FileIndex` (que refresca con el watcher de la carpeta). Se
    /// llama en cada tecla con `#`: mientras el FileIndex publica lotes no se reindexa acá (cada
    /// lote cancelaría la pasada); lo hace el sink con debounce cuando se calma.
    func activate(fileIndex: FileIndex) {
        if subscription == nil {
            subscription = fileIndex.$paths.dropFirst()
                .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
                .sink { [weak self, weak fileIndex] paths in self?.reindex(root: fileIndex?.root, paths: paths) }
        }
        guard !fileIndex.isIndexing else { return }
        if !hasIndexed || fileIndex.root?.standardizedFileURL != root?.standardizedFileURL {
            reindex(root: fileIndex.root, paths: fileIndex.paths)
        }
    }

    func reindex(root newRoot: URL?, paths newPaths: [String]) {
        let keepsSymbols = newRoot?.standardizedFileURL == root?.standardizedFileURL && !symbols.isEmpty
        root = newRoot
        paths = newPaths
        hasIndexed = true
        let gen = nextGeneration()
        guard let newRoot else {
            symbols = []
            indexedFiles = 0
            isIndexing = false
            return
        }
        isIndexing = true
        queue.async { [weak self] in
            guard let self else { return }
            if self.cacheRoot?.standardizedFileURL != newRoot.standardizedFileURL {
                self.cache = [:]
                self.cacheRoot = newRoot
            }
            let result = scanProjectSymbols(
                root: newRoot, paths: newPaths, maxFiles: Self.maxFiles, maxBytes: Self.maxBytes,
                cache: &self.cache, rule: { self.rule(forExtension: $0) },
                isCancelled: { !self.isCurrent(gen) },
                progress: { partial, files in
                    // Re-pasada de la misma raíz: la lista anterior sigue visible hasta el final (sin parpadeo).
                    guard !keepsSymbols else { return }
                    DispatchQueue.main.async {
                        guard self.isCurrent(gen) else { return }
                        self.symbols = partial
                        self.indexedFiles = files
                    }
                })
            guard result.finished else { return }
            DispatchQueue.main.async {
                guard self.isCurrent(gen) else { return }
                self.symbols = result.symbols
                self.indexedFiles = result.indexedFiles
                self.isIndexing = false
            }
        }
    }

    /// Rutas relativas modificadas: se descarta su cache y se repasa (el resto sale de la cache).
    /// Para llamadores que sepan qué cambió; el refresco del watcher ya cubre el caso normal por mtime.
    func update(changed: [String]) {
        guard root != nil else { return }
        let (r, p) = (root, paths)
        queue.async { [weak self] in
            for path in changed { self?.cache[path] = nil }
            DispatchQueue.main.async { self?.reindex(root: r, paths: p) }
        }
    }

    /// Solo desde `queue`. `npp_lookup_language` relee langs.model.xml en cada llamada.
    private func rule(forExtension ext: String) -> FunctionListRule? {
        let name: String?
        if let cached = languageByExtension[ext] {
            name = cached
        } else {
            name = languageName(forExtension: ext)
            languageByExtension[ext] = .some(name)
        }
        return name.flatMap { FunctionList.rule(forLanguage: $0) }
    }

    private func nextGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == gen
    }
}
