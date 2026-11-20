import Foundation
import SwiftUI

/// Una coincidencia: línea 0-based (líneas de Scintilla) y posición de la coincidencia en
/// bytes UTF-8 dentro de la línea, que es lo que espera Scintilla para seleccionarla.
struct FindInFilesMatch: Identifiable {
    let id = UUID()
    let line: Int
    let byteStart: Int
    let byteLength: Int
    let previewPrefix: String
    let previewMatch: String
    let previewSuffix: String
}

/// Origen de un grupo de resultados: archivo en disco, o documento abierto (por su id, para
/// incluir los sin guardar y los sin ruta).
enum FindResultSource: Hashable {
    case file(URL)
    case document(UUID)
}

/// De dónde salen los resultados vigentes del panel.
enum FindScope {
    case folder, document, openDocuments
}

struct FindInFilesFileResult: Identifiable {
    var id: FindResultSource { source }
    let source: FindResultSource
    let title: String
    let matches: [FindInFilesMatch]
    /// Stamp del archivo al buscar: Reemplazar en archivos no escribe si cambió desde entonces.
    var stamp: FileStamp? = nil
    /// Casilla de Reemplazar en archivos.
    var isSelected = true
}

/// Buscar en archivos de la carpeta abierta (Notepad++: "Find in Files" de FindReplaceDlg.cpp).
/// Reemplazar en archivos: ReplaceInFiles.swift. Mismo patrón que FindViewModel:
/// ObservableObject anidado en TabsViewModel, observado directo por las vistas.
final class FindInFilesViewModel: ObservableObject {
    @Published var query = ""
    @Published var matchCase = false
    @Published var wholeWord = false
    @Published var useRegex = false
    @Published private(set) var results: [FindInFilesFileResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var summary = ""
    /// Encabezado sobre la lista: de dónde salen los resultados vigentes.
    @Published private(set) var scopeDescription = ""
    /// nil = todavía no se buscó nada.
    @Published private(set) var lastScope: FindScope?
    /// Se incrementa desde el menú (⌘⇧F) para enfocar el campo de búsqueda.
    @Published var focusRequestToken = 0
    @Published var replacement = ""
    @Published var showReplace = false
    /// Búsqueda que produjo `results` (ver SearchSnapshot).
    @Published private(set) var snapshot: SearchSnapshot?
    @Published private(set) var truncated = false
    /// Recuento o escritura de "Reemplazar todo" en curso (en una cola de fondo).
    @Published private(set) var isReplacing = false

    /// Los campos ya no coinciden con la búsqueda hecha: hay que volver a buscar antes de reemplazar.
    var snapshotIsStale: Bool {
        guard let snapshot else { return true }
        return !snapshot.matches(query: query, matchCase: matchCase, wholeWord: wholeWord, useRegex: useRegex)
    }

    private var searchTask: Task<Void, Never>?
    /// Identifica la búsqueda vigente: el resultado de una búsqueda ya reemplazada se descarta.
    private var generation = 0

    static let maxMatches = 5_000
    static let maxFileSize = 5 * 1024 * 1024
    static let skippedFolders: Set<String> = [".git", ".svn", ".hg", "node_modules", ".build", "DerivedData", "Pods"]

    /// `overrides`: texto actual de documentos abiertos con cambios sin guardar (se busca en lo
    /// que el usuario ve, no en la versión de disco).
    func search(in root: URL, overrides: [URL: String]) {
        searchTask?.cancel()
        let query = self.query
        guard !query.isEmpty else {
            results = []
            summary = ""
            return
        }
        guard let regex = FindInFilesViewModel.makeRegex(query: query, matchCase: matchCase, wholeWord: wholeWord, useRegex: useRegex) else {
            results = []
            summary = L("Expresión regular no válida")
            return
        }
        scopeDescription = L("Resultados en la carpeta")
        lastScope = .folder

        isSearching = true
        summary = L("Buscando…")
        generation += 1
        let current = generation
        let pending = SearchSnapshot(query: query, matchCase: matchCase, wholeWord: wholeWord, useRegex: useRegex, root: root)
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = FindInFilesViewModel.run(regex: regex, root: root, overrides: overrides)
            guard !Task.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.results = outcome.results
                self.snapshot = pending
                self.truncated = outcome.truncated
                self.isSearching = false
                let total = outcome.results.reduce(0) { $0 + $1.matches.count }
                if total == 0 {
                    self.summary = L("Sin resultados")
                } else {
                    self.summary = L("\(total) coincidencias en \(outcome.results.count) archivos")
                    if outcome.truncated { self.summary += " — " + L("se muestran las primeras \(FindInFilesViewModel.maxMatches)") }
                }
            }
        }
    }

    /// NSRegularExpression (no la regex de Scintilla): la sintaxis puede diferir levemente.
    static func makeRegex(query: String, matchCase: Bool, wholeWord: Bool, useRegex: Bool) -> NSRegularExpression? {
        let pattern = useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        let bounded = wholeWord ? "\\b(?:\(pattern))\\b" : pattern
        return try? NSRegularExpression(pattern: bounded, options: matchCase ? [] : [.caseInsensitive])
    }

    /// Resultados sobre texto ya en memoria (documento actual o abiertos), sin tocar disco.
    /// Copia texto y opciones al panel para que muestre lo que se buscó y una búsqueda en
    /// carpeta lanzada después desde ahí no use valores viejos.
    func showResults(forDocuments documents: [(id: UUID, title: String, text: String)], query: String,
                     matchCase: Bool, wholeWord: Bool, useRegex: Bool, scope: FindScope, scopeDescription: String) {
        searchTask?.cancel()
        generation += 1
        isSearching = false
        // El ámbito va antes que las opciones: sus .onChange en la vista no deben relanzar en
        // la carpeta y pisar estos resultados (ver rerunIfNeeded).
        lastScope = scope
        self.scopeDescription = scopeDescription
        self.query = query
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.useRegex = useRegex
        guard !query.isEmpty else {
            results = []
            summary = ""
            return
        }
        guard let regex = FindInFilesViewModel.makeRegex(query: query, matchCase: matchCase, wholeWord: wholeWord, useRegex: useRegex) else {
            results = []
            summary = L("Expresión regular no válida")
            return
        }
        var found: [FindInFilesFileResult] = []
        var total = 0
        var truncated = false
        for doc in documents {
            let matches = FindInFilesViewModel.matchesIn(doc.text, regex: regex, limit: FindInFilesViewModel.maxMatches - total)
            guard !matches.isEmpty else { continue }
            found.append(FindInFilesFileResult(source: .document(doc.id), title: doc.title, matches: matches))
            total += matches.count
            if total >= FindInFilesViewModel.maxMatches {
                truncated = true
                break
            }
        }
        results = found
        snapshot = SearchSnapshot(query: query, matchCase: matchCase, wholeWord: wholeWord, useRegex: useRegex, root: nil)
        self.truncated = truncated
        if total == 0 {
            summary = L("Sin resultados")
        } else {
            summary = L("\(total) coincidencias en \(found.count) archivos")
            if truncated { summary += " — " + L("se muestran las primeras \(FindInFilesViewModel.maxMatches)") }
        }
    }

    func setSelected(_ source: FindResultSource, _ selected: Bool) {
        guard let i = results.firstIndex(where: { $0.source == source }) else { return }
        results[i].isSelected = selected
    }

    func setSummary(_ text: String) { summary = text }
    func setReplacing(_ value: Bool) { isReplacing = value }

    func clear() {
        searchTask?.cancel()
        generation += 1
        results = []
        snapshot = nil
        truncated = false
        summary = ""
        isSearching = false
    }

    private static func run(regex: NSRegularExpression, root: URL, overrides: [URL: String]) -> (results: [FindInFilesFileResult], truncated: Bool) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], false) }

        let overridesByPath = Dictionary(overrides.map { (canonicalFilePath($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        var results: [FindInFilesFileResult] = []
        var total = 0
        var truncated = false

        for case let url as URL in enumerator {
            if Task.isCancelled { return ([], false) }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= maxFileSize else { continue }

            let text: String
            var stamp: FileStamp?
            if let override = overridesByPath[canonicalFilePath(url)] {
                text = override
            } else {
                guard let data = try? Data(contentsOf: url), !data.isEmpty,
                      !data.prefix(8192).contains(0) else { continue }
                stamp = FileStamp.of(url)
                text = decodeWithDetectedEncoding(data).text
            }

            let matches = matchesIn(text, regex: regex, limit: maxMatches - total)
            guard !matches.isEmpty else { continue }
            results.append(FindInFilesFileResult(source: .file(url), title: url.lastPathComponent, matches: matches, stamp: stamp))
            total += matches.count
            if total >= maxMatches {
                truncated = true
                break
            }
        }
        // Por ruta completa: archivos homónimos de carpetas distintas quedan agrupados por carpeta.
        results.sort { lhs, rhs in
            guard case .file(let a) = lhs.source, case .file(let b) = rhs.source else { return false }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
        return (results, truncated)
    }

    static func matchesIn(_ text: String, regex: NSRegularExpression, limit: Int) -> [FindInFilesMatch] {
        var matches: [FindInFilesMatch] = []
        for (lineIndex, line) in splitScintillaLines(text).enumerated() {
            guard matches.count < limit else { break }
            let nsLine = line as NSString
            for result in regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                guard result.range.length > 0, matches.count < limit,
                      let range = Range(result.range, in: line) else { continue }
                let byteStart = line.utf8.distance(from: line.startIndex, to: range.lowerBound)
                let byteLength = line.utf8.distance(from: range.lowerBound, to: range.upperBound)
                // Preview recortado alrededor de la coincidencia para que entre en el sidebar.
                var prefix = String(line[line.startIndex..<range.lowerBound])
                prefix = String(prefix.drop(while: { $0 == " " || $0 == "\t" }))
                if prefix.count > 40 { prefix = "…" + prefix.suffix(40) }
                var suffix = String(line[range.upperBound...])
                if suffix.count > 80 { suffix = suffix.prefix(80) + "…" }
                matches.append(FindInFilesMatch(
                    line: lineIndex, byteStart: byteStart, byteLength: byteLength,
                    previewPrefix: prefix, previewMatch: String(line[range]), previewSuffix: suffix
                ))
            }
        }
        return matches
    }

    /// Líneas como las cuenta Scintilla: solo CRLF, CR y LF terminan línea. Character.isNewline
    /// también corta en \u{0B}, \u{0C}, U+0085, U+2028 y U+2029, y corría la numeración.
    static func splitScintillaLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        var pending = iterator.next()
        while let scalar = pending {
            pending = iterator.next()
            switch scalar {
            case "\r":
                if pending == "\n" { pending = iterator.next() }
                fallthrough
            case "\n":
                lines.append(String(current))
                current = String.UnicodeScalarView()
            default:
                current.append(scalar)
            }
        }
        lines.append(String(current))
        return lines
    }
}

/// Pestaña "Buscar" del sidebar.
struct FindInFilesView: View {
    @ObservedObject var model: FindInFilesViewModel
    let root: URL?
    let overrides: () -> [URL: String]
    /// url, línea 0-based, inicio y largo de la coincidencia en bytes dentro de la línea.
    let onOpenMatch: (URL, Int, Int, Int) -> Void
    /// Id del documento, línea 0-based, inicio y largo en bytes (resultados de Buscar todo).
    let onOpenDocumentMatch: (UUID, Int, Int, Int) -> Void
    let onReplaceAll: () -> Void
    @FocusState private var fieldFocused: Bool
    @State private var collapsed: Set<FindResultSource> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button { model.showReplace.toggle() } label: {
                    Image(systemName: model.showReplace ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                .help(L("Reemplazar en archivos"))
                TextField(L("Buscar en archivos"), text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(runSearch)
                Toggle("Aa", isOn: $model.matchCase).help(L("Coincidir mayúsculas y minúsculas"))
                Toggle("ab", isOn: $model.wholeWord).help(L("Palabra completa"))
                Toggle(".*", isOn: $model.useRegex).help(L("Expresión regular"))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .disabled(root == nil)

            if model.showReplace {
                HStack(spacing: 4) {
                    TextField(L("Reemplazar"), text: $model.replacement)
                        .textFieldStyle(.roundedBorder)
                    Button(L("Reemplazar todo…"), action: onReplaceAll)
                        .disabled(model.isSearching || model.isReplacing || model.snapshotIsStale || !model.results.contains { $0.isSelected })
                        .help(model.snapshotIsStale ? L("Vuelve a buscar: la búsqueda cambió") : "")
                }
                .controlSize(.small)
                .padding(.horizontal, 8)
            }

            HStack {
                if model.isSearching || model.isReplacing { ProgressView().controlSize(.small) }
                // Sin carpeta, Buscar todo igual puede tener resultados (o "Sin resultados").
                Text(root == nil && (model.lastScope ?? .folder) == .folder
                     ? L("Abre una carpeta para buscar en archivos") : model.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 8)

            if !model.scopeDescription.isEmpty && !model.results.isEmpty {
                Text(model.scopeDescription)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
            }

            List {
                ForEach(model.results) { file in
                    DisclosureGroup(isExpanded: Binding(
                        get: { !collapsed.contains(file.source) },
                        set: { expanded in
                            if expanded { collapsed.remove(file.source) } else { collapsed.insert(file.source) }
                        }
                    )) {
                        ForEach(file.matches) { match in
                            matchRow(match)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    switch file.source {
                                    case .file(let url): onOpenMatch(url, match.line, match.byteStart, match.byteLength)
                                    case .document(let id): onOpenDocumentMatch(id, match.line, match.byteStart, match.byteLength)
                                    }
                                }
                        }
                    } label: {
                        HStack {
                            if model.showReplace {
                                Toggle("", isOn: Binding(get: { file.isSelected },
                                                         set: { model.setSelected(file.source, $0) }))
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                            }
                            Text(file.title).lineLimit(1)
                            Spacer()
                            Text("\(file.matches.count)").foregroundStyle(.secondary).font(.caption)
                        }
                        .help(helpText(file))
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .padding(.top, 2)
        .onChange(of: model.focusRequestToken) { _ in fieldFocused = true }
        .onChange(of: model.matchCase) { _ in rerunIfNeeded() }
        .onChange(of: model.wholeWord) { _ in rerunIfNeeded() }
        .onChange(of: model.useRegex) { _ in rerunIfNeeded() }
        .onAppear { if model.focusRequestToken > 0 { fieldFocused = true } }
    }

    private func matchRow(_ match: FindInFilesMatch) -> some View {
        (Text("\(match.line + 1): ").foregroundColor(.secondary)
            + Text(match.previewPrefix)
            + Text(match.previewMatch).bold()
            + Text(match.previewSuffix))
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func runSearch() {
        guard let root else { return }
        model.search(in: root, overrides: overrides())
    }

    /// Solo relanza búsquedas en carpeta: los resultados de Buscar todo vienen de la barra (que
    /// copia sus opciones acá) y una búsqueda en carpeta los reemplazaría.
    private func rerunIfNeeded() {
        guard !model.query.isEmpty, (model.lastScope ?? .folder) == .folder else { return }
        runSearch()
    }

    private func helpText(_ file: FindInFilesFileResult) -> String {
        if case .file(let url) = file.source { return relativePath(url) }
        return file.title
    }

    private func relativePath(_ url: URL) -> String {
        guard let root else { return url.path }
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}
