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

struct FindInFilesFileResult: Identifiable {
    var id: URL { url }
    let url: URL
    let matches: [FindInFilesMatch]
}

/// Buscar en archivos de la carpeta abierta (Notepad++: "Find in Files" de FindReplaceDlg.cpp).
/// Solo busca; no reemplaza (decisión del usuario). Mismo patrón que FindViewModel:
/// ObservableObject anidado en TabsViewModel, observado directo por las vistas.
final class FindInFilesViewModel: ObservableObject {
    @Published var query = ""
    @Published var matchCase = false
    @Published var wholeWord = false
    @Published var useRegex = false
    @Published private(set) var results: [FindInFilesFileResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var summary = ""
    /// Se incrementa desde el menú (⌘⇧F) para enfocar el campo de búsqueda.
    @Published var focusRequestToken = 0

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
        let pattern = useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        let bounded = wholeWord ? "\\b(?:\(pattern))\\b" : pattern
        guard let regex = try? NSRegularExpression(pattern: bounded, options: matchCase ? [] : [.caseInsensitive]) else {
            results = []
            summary = L("Expresión regular no válida")
            return
        }

        isSearching = true
        summary = L("Buscando…")
        generation += 1
        let current = generation
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = FindInFilesViewModel.run(regex: regex, root: root, overrides: overrides)
            guard !Task.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.results = outcome.results
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

    func clear() {
        searchTask?.cancel()
        generation += 1
        results = []
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
            if let override = overridesByPath[canonicalFilePath(url)] {
                text = override
            } else {
                guard let data = try? Data(contentsOf: url), !data.isEmpty,
                      !data.prefix(8192).contains(0) else { continue }
                text = decodeWithDetectedEncoding(data).text
            }

            let matches = matchesIn(text, regex: regex, limit: maxMatches - total)
            guard !matches.isEmpty else { continue }
            results.append(FindInFilesFileResult(url: url, matches: matches))
            total += matches.count
            if total >= maxMatches {
                truncated = true
                break
            }
        }
        results.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        return (results, truncated)
    }

    private static func matchesIn(_ text: String, regex: NSRegularExpression, limit: Int) -> [FindInFilesMatch] {
        var matches: [FindInFilesMatch] = []
        // Split por Character.isNewline: "\r\n" es un solo Character, así que la numeración
        // coincide con la de Scintilla para archivos CRLF, LF y CR.
        for (lineIndex, lineSub) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            guard matches.count < limit else { break }
            let line = String(lineSub)
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
}

/// Pestaña "Buscar" del sidebar.
struct FindInFilesView: View {
    @ObservedObject var model: FindInFilesViewModel
    let root: URL?
    let overrides: () -> [URL: String]
    /// url, línea 0-based, inicio y largo de la coincidencia en bytes dentro de la línea.
    let onOpenMatch: (URL, Int, Int, Int) -> Void
    @FocusState private var fieldFocused: Bool
    @State private var collapsed: Set<URL> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
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

            HStack {
                if model.isSearching { ProgressView().controlSize(.small) }
                Text(root == nil ? L("Abre una carpeta para buscar en archivos") : model.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 8)

            List {
                ForEach(model.results) { file in
                    DisclosureGroup(isExpanded: Binding(
                        get: { !collapsed.contains(file.url) },
                        set: { expanded in
                            if expanded { collapsed.remove(file.url) } else { collapsed.insert(file.url) }
                        }
                    )) {
                        ForEach(file.matches) { match in
                            matchRow(match)
                                .contentShape(Rectangle())
                                .onTapGesture { onOpenMatch(file.url, match.line, match.byteStart, match.byteLength) }
                        }
                    } label: {
                        HStack {
                            Text(file.url.lastPathComponent).lineLimit(1)
                            Spacer()
                            Text("\(file.matches.count)").foregroundStyle(.secondary).font(.caption)
                        }
                        .help(relativePath(file.url))
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

    private func rerunIfNeeded() {
        guard !model.query.isEmpty else { return }
        runSearch()
    }

    private func relativePath(_ url: URL) -> String {
        guard let root else { return url.path }
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}
