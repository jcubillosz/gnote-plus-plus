// "Abrir rápido" (⌘T): archivos de la carpeta abierta, `:línea[:columna]` y `@símbolo`.
import Foundation
import AppKit
import Combine
import Scintilla

// BEGIN-PURE
enum QuickOpenQuery: Equatable {
    case files(String), line(Int, Int?), symbol(String), projectSymbol(String), invalidLine

    static func parse(_ s: String) -> QuickOpenQuery {
        if s.hasPrefix("@") { return .symbol(String(s.dropFirst())) }
        if s.hasPrefix("#") { return .projectSymbol(String(s.dropFirst())) }
        guard s.hasPrefix(":") else { return .files(s) }
        let parts = s.dropFirst().split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line = Int(parts[0]), line >= 1 else { return .invalidLine }
        // ":12:" es la columna a medio tipear: todavía vale como línea sola.
        guard parts.count > 1, !parts[1].isEmpty else { return .line(line, nil) }
        guard let column = Int(parts[1]), column >= 1 else { return .invalidLine }
        return .line(line, column)
    }
}

/// Índice (en `Character`) donde empieza el último componente de la ruta.
func pathFileNameStart(_ chars: [Character]) -> Int {
    (chars.lastIndex(of: "/") ?? -1) + 1
}

/// Recorre `root` entregando rutas relativas de archivos. `finished == false` si se canceló.
func enumerateIndexableFiles(root: URL, skippedFolders: Set<String>, limit: Int,
                             isCancelled: () -> Bool, onFile: (String) -> Void) -> (finished: Bool, truncated: Bool) {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return (true, false) }
    // El enumerador puede devolver la raíz tal cual o resuelta (/var vs /private/var).
    let prefixes = Set([root.standardizedFileURL.path, root.resolvingSymlinksInPath().path])
        .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    var count = 0
    for case let url as URL in enumerator {
        if isCancelled() { return (false, false) }
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
        if values.isDirectory == true {
            if skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
            continue
        }
        if values.isSymbolicLink == true {
            // El enumerador no entra en symlinks a carpetas (un enlace a un ancestro sería un
            // ciclo). Ojo: NO llamar skipDescendants() acá: el enlace no es una carpeta y saltea
            // el resto de la carpeta que lo contiene (probado con el script del lote 11).
            let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
            guard target?.isRegularFile == true else { continue }
        } else if values.isRegularFile != true {
            continue
        }
        let path = url.standardizedFileURL.path
        guard let prefix = prefixes.first(where: { path.hasPrefix($0) }) else { continue }
        if count >= limit { return (true, true) }
        onFile(String(path.dropFirst(prefix.count)))
        count += 1
    }
    return (true, false)
}
// END-PURE

/// Contador de generación compartido con las tareas de fondo: una tarea vieja lo consulta
/// para abandonar en cuanto hay otra más nueva.
private final class Generation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func isCurrent(_ v: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == v }
}

/// Archivos de la carpeta raíz para "Abrir rápido", enumerados en segundo plano.
final class FileIndex: ObservableObject {
    static let limit = 50_000
    private static let batchSize = 2_000

    struct Entry {
        let path: String
        /// Plegado precalculado: replegar 50 000 rutas por pulsación tardaba ~0,8 s.
        let candidate: FoldedCandidate
        let fileNameStart: Int
    }

    /// Relativas a `root`.
    @Published private(set) var paths: [String] = []
    /// Mismo orden que `paths`.
    private(set) var entries: [Entry] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var truncated = false
    private(set) var root: URL?

    private let generation = Generation()
    private var pendingRefresh: DispatchWorkItem?
    private var running = false
    private var needsRerun = false
    /// Hay un índice completo de `root`: un refresco del watcher lo reemplaza al terminar
    /// en vez de vaciarlo y mostrar resultados parciales.
    private var isComplete = false

    /// `debounced` (desde el watcher): agrupa los eventos de 1 s y, si ya hay un recorrido en
    /// curso, lo deja terminar y repite después; cancelar y reiniciar con cada evento de una
    /// carpeta que cambia sin parar (un build escribiendo) no terminaría nunca.
    func reindex(root: URL?, debounced: Bool = false) {
        if debounced {
            guard pendingRefresh == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingRefresh = nil
                if self.running { self.needsRerun = true } else { self.start(root: self.root) }
            }
            pendingRefresh = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
            return
        }
        pendingRefresh?.cancel()
        pendingRefresh = nil
        needsRerun = false
        start(root: root)
    }

    private func start(root newRoot: URL?) {
        let gen = generation.next()
        let sameRoot = newRoot?.standardizedFileURL == root?.standardizedFileURL
        let incremental = sameRoot && isComplete
        root = newRoot
        if !sameRoot {
            publish([], [])
            truncated = false
            isComplete = false
        }
        guard let newRoot else {
            running = false
            isIndexing = false
            return
        }
        running = true
        if !incremental { isIndexing = true }
        let generation = self.generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var entries: [Entry] = []
            var paths: [String] = []
            let result = enumerateIndexableFiles(
                root: newRoot, skippedFolders: FindInFilesViewModel.skippedFolders, limit: Self.limit,
                isCancelled: { !generation.isCurrent(gen) }
            ) { path in
                let candidate = FoldedCandidate(path)
                entries.append(Entry(path: path, candidate: candidate,
                                     fileNameStart: pathFileNameStart(candidate.original)))
                paths.append(path)
                if !incremental, paths.count % Self.batchSize == 0 {
                    let (e, p) = (entries, paths)
                    DispatchQueue.main.async {
                        guard let self, generation.isCurrent(gen) else { return }
                        self.publish(e, p)
                    }
                }
            }
            guard result.finished else { return }
            let order = paths.indices.sorted { paths[$0] < paths[$1] }
            let sortedEntries = order.map { entries[$0] }
            let sortedPaths = order.map { paths[$0] }
            DispatchQueue.main.async {
                guard let self, generation.isCurrent(gen) else { return }
                self.publish(sortedEntries, sortedPaths)
                self.truncated = result.truncated
                self.isIndexing = false
                self.isComplete = true
                self.running = false
                if self.needsRerun {
                    self.needsRerun = false
                    self.reindex(root: self.root, debounced: true)
                }
            }
        }
    }

    /// `entries` antes que `paths`: quien observe `paths` lee ya las dos listas nuevas.
    private func publish(_ newEntries: [Entry], _ newPaths: [String]) {
        entries = newEntries
        paths = newPaths
    }
}

// MARK: - Panel

private let quickOpenRankQueue = DispatchQueue(label: "quickopen.rank", qos: .userInitiated)
/// Por encima de esto el ranking va a segundo plano para no trabar el tipeo.
private let quickOpenAsyncThreshold = 5_000

/// Vive mientras el panel muestra "Abrir rápido": la retiene el provider, que el panel suelta
/// al cerrarse o al abrir otro modo; con ella se va la suscripción al índice.
private final class QuickOpenSession {
    enum Target {
        case document(Document)
        case url(URL)
    }

    /// Documento abierto o reciente (pocos): se rankea siempre en el hilo principal.
    struct Candidate {
        let id: String
        let key: String
        let candidate: FoldedCandidate
        let fileNameStart: Int
        let label: String
        let target: Target
    }

    /// Tope del índice con el separador de miles del idioma ("50.000" / "50,000").
    private static let formattedLimit: String = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: FileIndex.limit)) ?? "\(FileIndex.limit)"
    }()

    let panel: QuickPanelViewModel
    let tabs: TabsViewModel
    let index: FileIndex
    let rootURL: URL?
    private let fixed: [Candidate]
    private let excludedRelative: Set<String>
    /// Entradas del índice sin las que ya están entre abiertos/recientes; se recalcula cuando el índice cambia.
    private var indexCandidates: [FileIndex.Entry]?
    private var indexCandidatesRoot: URL?
    private let rankGeneration = Generation()
    private var lastFilesQuery: String?
    private var subscription: AnyCancellable?
    private var refreshScheduled = false

    private var symbolSubscription: AnyCancellable?

    init(panel: QuickPanelViewModel, tabs: TabsViewModel, index: FileIndex, root: URL?) {
        self.panel = panel
        self.tabs = tabs
        self.index = index
        self.rootURL = root

        let canonicalRoot = root.map { canonicalFilePath($0) }
        func relative(_ canonical: String) -> String? {
            guard let r = canonicalRoot, canonical.hasPrefix(r + "/") else { return nil }
            return String(canonical.dropFirst(r.count + 1))
        }
        var seen = Set<String>()
        var excluded = Set<String>()
        var fixed: [Candidate] = []
        func add(_ url: URL, label: String, target: Target, id: String? = nil) {
            let canonical = canonicalFilePath(url)
            guard seen.insert(canonical).inserted else { return }
            let rel = relative(canonical)
            if let rel { excluded.insert(rel) }
            let key = rel ?? (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
            let folded = FoldedCandidate(key)
            fixed.append(Candidate(id: id ?? "file:\(canonical)", key: key, candidate: folded,
                                   fileNameStart: pathFileNameStart(folded.original), label: label, target: target))
        }
        for doc in tabs.documents {
            if let url = doc.url {
                add(url, label: L("Abierto"), target: .document(doc), id: "doc:\(doc.id)")
            } else {
                let folded = FoldedCandidate(doc.displayName)
                fixed.append(Candidate(id: "doc:\(doc.id)", key: doc.displayName, candidate: folded, fileNameStart: 0,
                                       label: L("Abierto"), target: .document(doc)))
            }
        }
        for url in tabs.recentFiles.urls { add(url, label: L("Reciente"), target: .url(url)) }
        self.fixed = fixed
        self.excludedRelative = excluded

        subscription = index.objectWillChange.sink { [weak self] _ in self?.indexWillChange() }
        symbolSubscription = tabs.projectSymbols.objectWillChange.sink { [weak self] _ in self?.indexWillChange() }
    }

    /// objectWillChange llega antes del cambio y varias veces por lote: un solo refresco, después.
    private func indexWillChange() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        let session = panel.session
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.indexCandidates = nil
            guard self.panel.isVisible, self.panel.session == session else { return }
            self.panel.refresh()
        }
    }

    func items(for query: String) -> [QuickPanelItem] {
        switch QuickOpenQuery.parse(query) {
        case .files(let q):
            panel.footer = index.isIndexing ? L("Indexando…")
                : index.truncated ? L("Mostrando los primeros \(Self.formattedLimit) archivos") : nil
            return fileItems(q)
        case .line(let n, let c):
            panel.footer = nil
            lastFilesQuery = nil
            let editor = tabs.editor
            let hasDocument = tabs.activeDocument != nil
            let lineCount = hasDocument
                ? Int(ScintillaView.directCall(editor, message: SCI_GETLINECOUNT, wParam: 0, lParam: 0)) : 0
            return [QuickPanelItem(id: "line", title: L("Ir a la línea \(n)"), subtitle: nil, shortcut: nil,
                                   isEnabled: hasDocument && n <= lineCount, isChecked: false, matched: []) {
                goTo(line: n - 1, column: c.map { $0 - 1 }, editor: editor)
            }]
        case .invalidLine:
            panel.footer = nil
            lastFilesQuery = nil
            return [QuickPanelItem(id: "line", title: L("Escribe un número de línea"), subtitle: nil, shortcut: nil,
                                   isEnabled: false, isChecked: false, matched: []) {}]
        case .projectSymbol(let q):
            lastFilesQuery = nil
            return projectSymbolItems(q)
        case .symbol(let q):
            panel.footer = nil
            lastFilesQuery = nil
            let symbols = tabs.outline.items
            guard !symbols.isEmpty else {
                return [QuickPanelItem(id: "symbol", title: L("No hay símbolos en este documento"), subtitle: nil,
                                       shortcut: nil, isEnabled: false, isChecked: false, matched: []) {}]
            }
            let editor = tabs.editor
            return fuzzyRank(symbols, query: q, key: { $0.title }, fileNameStart: { _ in nil },
                             limit: QuickPanelViewModel.maxRows).map { ranked in
                let item = ranked.item
                return QuickPanelItem(id: "sym:\(item.id)", title: item.title, subtitle: L("línea \(item.line + 1)"),
                                      shortcut: nil, isEnabled: true, isChecked: false,
                                      matched: ranked.result.matched) {
                    goTo(line: item.line, column: nil, editor: editor)
                }
            }
        }
    }

    private func projectSymbolItems(_ query: String) -> [QuickPanelItem] {
        let symbolIndex = tabs.projectSymbols
        symbolIndex.activate(fileIndex: index)
        panel.footer = symbolIndex.isIndexing || index.isIndexing
            ? L("Indexando símbolos… \(symbolIndex.indexedFiles) archivos") : nil
        guard let symbolRoot = index.root else {
            return [QuickPanelItem(id: "psym", title: L("Abre una carpeta para buscar símbolos del proyecto"),
                                   subtitle: nil, shortcut: nil, isEnabled: false, isChecked: false, matched: []) {}]
        }
        let symbols = symbolIndex.symbols
        let tabs = self.tabs
        let rank = { (all: [ProjectSymbol]) -> [QuickPanelItem] in
            fuzzyRankFolded(all, query: query, candidate: { $0.folded }, key: { $0.name },
                            fileNameStart: { _ in nil }, limit: QuickPanelViewModel.maxRows).enumerated().map { i, ranked in
                let s = ranked.item
                return QuickPanelItem(id: "psym:\(i):\(s.relativePath):\(s.line):\(s.name)", title: s.name,
                                      subtitle: "\(s.relativePath):\(s.line + 1)", shortcut: nil, isEnabled: true,
                                      isChecked: false, matched: ranked.result.matched) {
                    guard tabs.open(url: symbolRoot.appendingPathComponent(s.relativePath)) else { return }
                    // Un ciclo después, como openFindMatch: el editor recién cambió de documento.
                    DispatchQueue.main.async { goTo(line: s.line, column: nil, editor: tabs.editor) }
                }
            }
        }
        guard !foldQuery(query).isEmpty, symbols.count > quickOpenAsyncThreshold else { return rank(symbols) }
        let gen = rankGeneration.next()
        let generation = rankGeneration
        let session = panel.session
        quickOpenRankQueue.async { [weak self] in
            guard generation.isCurrent(gen) else { return }
            let items = rank(symbols)
            DispatchQueue.main.async {
                guard let self, generation.isCurrent(gen) else { return }
                self.panel.publish(items, session: session, query: "#" + query)
            }
        }
        return panel.items.first?.id.hasPrefix("psym:") == true ? panel.items : []
    }

    private func currentIndexCandidates() -> [FileIndex.Entry] {
        if let cached = indexCandidates, indexCandidatesRoot == index.root { return cached }
        let entries = index.entries
        // Las exclusiones son relativas a la raíz de la sesión: solo valen si el índice es de esa raíz.
        let sameRoot = index.root?.standardizedFileURL == rootURL?.standardizedFileURL
        let filtered = excludedRelative.isEmpty || !sameRoot
            ? entries : entries.filter { !excludedRelative.contains($0.path) }
        indexCandidates = filtered
        indexCandidatesRoot = index.root
        return filtered
    }

    private typealias Ranked = (fixed: [(item: Candidate, result: FuzzyResult)],
                                indexed: [(item: FileIndex.Entry, result: FuzzyResult)])

    private func fileItems(_ query: String) -> [QuickPanelItem] {
        let limit = QuickPanelViewModel.maxRows
        let indexed = currentIndexCandidates()
        let indexRoot = index.root
        let rankedFixed = fuzzyRankFolded(fixed, query: query, candidate: { $0.candidate }, key: { $0.key },
                                          fileNameStart: { $0.fileNameStart }, limit: limit)
        let rankIndexed = { (entries: [FileIndex.Entry]) in
            fuzzyRankFolded(entries, query: query, candidate: { $0.candidate }, key: { $0.path },
                            fileNameStart: { $0.fileNameStart }, limit: limit)
        }
        let previousQuery = lastFilesQuery
        lastFilesQuery = query
        if foldQuery(query).isEmpty || fixed.count + indexed.count <= quickOpenAsyncThreshold {
            return makeItems((rankedFixed, rankIndexed(indexed)), indexRoot: indexRoot)
        }
        // Asíncrono: se responde ya con lo que hay y el panel recibe el ranking completo al terminar.
        let gen = rankGeneration.next()
        let generation = rankGeneration
        let session = panel.session
        quickOpenRankQueue.async { [weak self] in
            guard generation.isCurrent(gen) else { return }
            let rankedIndexed = rankIndexed(indexed)
            DispatchQueue.main.async {
                guard let self, generation.isCurrent(gen) else { return }
                self.panel.publish(self.makeItems((rankedFixed, rankedIndexed), indexRoot: indexRoot),
                                   session: session, query: query)
            }
        }
        // Hasta que llegue el ranking se conserva la lista anterior de archivos (misma consulta tras
        // un cambio del índice, o la consulta previa al tipear): mostrar solo abiertos/recientes en
        // el intervalo hacía parpadear la lista en cada tecla. Viniendo de :línea/@símbolo no hay
        // lista de archivos que conservar.
        if previousQuery != nil, !panel.items.isEmpty { return panel.items }
        return makeItems((rankedFixed, []), indexRoot: indexRoot)
    }

    private func makeItems(_ ranked: Ranked, indexRoot: URL?) -> [QuickPanelItem] {
        enum Source { case fixed(Candidate), indexed(FileIndex.Entry) }
        // Empates: abiertos y recientes antes que el índice (orden estable de la concatenación).
        var all: [(source: Source, result: FuzzyResult, order: Int)] = []
        for (i, r) in ranked.fixed.enumerated() { all.append((.fixed(r.item), r.result, i)) }
        for (i, r) in ranked.indexed.enumerated() { all.append((.indexed(r.item), r.result, ranked.fixed.count + i)) }
        all.sort { $0.result.score != $1.result.score ? $0.result.score > $1.result.score : $0.order < $1.order }

        let tabs = self.tabs
        return all.prefix(QuickPanelViewModel.maxRows).map { entry in
            switch entry.source {
            case .fixed(let c):
                let (title, folder, matched) = split(c.candidate.original, c.fileNameStart, entry.result.matched)
                let subtitle = folder.isEmpty ? c.label : "\(c.label) · \(folder)"
                return QuickPanelItem(id: c.id, title: title, subtitle: subtitle, shortcut: nil, isEnabled: true,
                                      isChecked: false, matched: matched) {
                    switch c.target {
                    case .document(let doc):
                        if let i = tabs.documents.firstIndex(where: { $0 === doc }) { tabs.activate(at: i) }
                    case .url(let url):
                        tabs.open(url: url)
                    }
                }
            case .indexed(let e):
                let (title, folder, matched) = split(e.candidate.original, e.fileNameStart, entry.result.matched)
                return QuickPanelItem(id: "idx:\(e.path)", title: title, subtitle: folder.isEmpty ? nil : folder,
                                      shortcut: nil, isEnabled: true, isChecked: false, matched: matched) {
                    guard let indexRoot else { return }
                    tabs.open(url: indexRoot.appendingPathComponent(e.path))
                }
            }
        }
    }

    /// La fila muestra el nombre como título y la carpeta como subtítulo; solo se resaltan las
    /// letras que caen en el nombre.
    private func split(_ chars: [Character], _ start: Int, _ matched: [Int]) -> (String, String, [Int]) {
        let title = String(chars[start...])
        let folder = start > 0 ? String(chars[..<(start - 1)]) : ""
        return (title, folder, matched.filter { $0 >= start }.map { $0 - start })
    }
}

func showQuickOpen(_ panel: QuickPanelViewModel, tabs: TabsViewModel, index: FileIndex, root: URL?,
                   initialQuery: String = "") {
    // Red de seguridad: normalmente FileTree ya lo indexó al abrir la carpeta.
    if index.root?.standardizedFileURL != root?.standardizedFileURL { index.reindex(root: root) }
    let session = QuickOpenSession(panel: panel, tabs: tabs, index: index, root: root)
    panel.show(placeholder: L("Abrir archivo, :línea, @símbolo o #símbolo del proyecto…"), query: initialQuery) { query in
        session.items(for: query)
    }
}
