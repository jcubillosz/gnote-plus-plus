import Foundation
import Scintilla

/// Un ítem del esquema (título de Markdown, o clase/función de código). `line` es 0-based
/// (línea de Scintilla). El id combina nivel, línea y título: en código puede haber varios
/// ítems en la misma línea (una clase y su primer método en una sola línea).
struct OutlineItem: Identifiable, Equatable {
    let level: Int
    let title: String
    let line: Int
    var id: String { "\(level)-\(line)-\(title)" }
}

enum SidebarTab: String {
    case files, outline, search
}

/// Esquema de secciones del documento Markdown activo, para la pestaña "Esquema" del sidebar.
/// Mismo patrón que FindViewModel/MarkdownPreviewViewModel: ObservableObject anidado en
/// TabsViewModel — las vistas que dependen de él lo observan directo (@ObservedObject).
final class OutlineViewModel: ObservableObject {
    @Published private(set) var items: [OutlineItem] = []
    enum Mode {
        case markdown
        /// Código con regla de functionList.
        case code
        /// Sin regla de esquema para el lenguaje (la pestaña muestra un aviso).
        case unsupported
    }
    @Published private(set) var mode: Mode = .unsupported
    /// Pestaña visible del sidebar, persistida entre lanzamientos.
    @Published var sidebarTab: SidebarTab {
        didSet { UserDefaults.standard.set(sidebarTab.rawValue, forKey: "sidebar.tab") }
    }
    /// Se incrementa desde el menú Vista → "Mostrar esquema": ContentView expande el sidebar.
    @Published var showRequestToken = 0

    private var pendingRefresh: DispatchWorkItem?
    /// Identifica el parseo vigente de código (en segundo plano); uno viejo se descarta.
    private var generation = 0

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "sidebar.tab").flatMap(SidebarTab.init(rawValue:)) {
            sidebarTab = saved
        } else {
            // Migración del Bool de la versión anterior (Archivos/Esquema).
            sidebarTab = defaults.bool(forKey: "sidebar.showsOutline") ? .outline : .files
        }
    }

    /// Debounce de 300ms, mismo patrón que MarkdownPreviewViewModel.scheduleRefresh: sin
    /// cancelar el pendiente, cada tecla re-parsearía el documento entero.
    func scheduleRefresh(editor: ScintillaView, profile: LanguageProfile?) {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refreshNow(editor: editor, profile: profile)
        }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Markdown: títulos (parseo síncrono, barato). Código: reglas de Notepad++ con el motor
    /// Boost, en segundo plano (un archivo grande con reglas complejas puede tardar).
    func refreshNow(editor: ScintillaView, profile: LanguageProfile?) {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        generation += 1
        guard let profile else {
            setResult(.unsupported, [])
            return
        }
        if profile.lexerName == "markdown" {
            setResult(.markdown, parseMarkdownOutline(currentText(editor)))
            return
        }
        guard let rule = FunctionList.rule(forLanguage: profile.languageName) else {
            setResult(.unsupported, [])
            return
        }
        let bytes = currentText(editor).utf8.map { CChar(bitPattern: $0) }
        let current = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let parsed = rule.parse(bytes)
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.setResult(.code, parsed)
            }
        }
    }

    private func setResult(_ mode: Mode, _ newItems: [OutlineItem]) {
        if self.mode != mode { self.mode = mode }
        if newItems != items { items = newItems }
    }

    /// Índice del título que contiene a `line` (0-based): el último que empieza en o antes de ella.
    func currentIndex(forLine line: Int) -> Int? {
        var low = 0, high = items.count - 1, result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if items[mid].line <= line {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

/// Extrae los títulos ATX (`# …`) y setext (`===`/`---` bajo un párrafo) de un documento
/// Markdown, ignorando bloques de código cercados (``` / ~~~) y el front-matter YAML inicial —
/// un `# comentario` dentro de un bloque de código no es un título.
func parseMarkdownOutline(_ text: String) -> [OutlineItem] {
    var items: [OutlineItem] = []
    var lines = text.components(separatedBy: "\n")
    for i in lines.indices where lines[i].hasSuffix("\r") {
        lines[i].removeLast()
    }

    var index = 0
    if lines.first == "---" {
        if let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) {
            index = end + 1
        }
    }

    var fence: (char: Character, length: Int)?
    // Línea anterior candidata a título setext: texto de párrafo no vacío.
    var paragraphLine: Int?

    while index < lines.count {
        let line = lines[index]
        defer { index += 1 }
        let indent = line.prefix(while: { $0 == " " }).count
        let body = line.dropFirst(min(indent, 3))

        if let open = fence {
            let run = body.prefix(while: { $0 == open.char })
            if indent <= 3, run.count >= open.length, body.dropFirst(run.count).allSatisfy({ $0 == " " || $0 == "\t" }) {
                fence = nil
            }
            continue
        }

        if indent <= 3, let first = body.first, first == "`" || first == "~" {
            let run = body.prefix(while: { $0 == first }).count
            // Un fence de backticks no admite backticks en el info string (CommonMark):
            // "```texto```" en una sola línea es código inline, no apertura de bloque.
            if run >= 3, first == "~" || !body.dropFirst(run).contains("`") {
                fence = (first, run)
                paragraphLine = nil
                continue
            }
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            paragraphLine = nil
            continue
        }

        if indent <= 3, body.first == "#" {
            let hashes = body.prefix(while: { $0 == "#" }).count
            let rest = body.dropFirst(hashes)
            if hashes <= 6, rest.isEmpty || rest.first == " " || rest.first == "\t" {
                items.append(OutlineItem(level: hashes, title: cleanHeadingTitle(atxTitle(rest)), line: index))
                paragraphLine = nil
                continue
            }
        }

        if indent <= 3, let paragraph = paragraphLine, let marker = trimmed.first,
           marker == "=" || marker == "-", trimmed.allSatisfy({ $0 == marker }) {
            let title = cleanHeadingTitle(lines[paragraph..<index]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " "))
            items.append(OutlineItem(level: marker == "=" ? 1 : 2, title: title, line: paragraph))
            paragraphLine = nil
            continue
        }

        // Regla horizontal (---, ***, ___): corta el párrafo, no es texto de un título.
        let compact = trimmed.filter { $0 != " " }
        if let marker = compact.first, "-*_".contains(marker), compact.count >= 3,
           compact.allSatisfy({ $0 == marker }) {
            paragraphLine = nil
            continue
        }

        // Solo una línea de párrafo "simple" puede volverse título setext: listas, citas,
        // tablas y código indentado no.
        let startsBlock = trimmed.hasPrefix(">") || trimmed.hasPrefix("|") || trimmed.hasPrefix("- ")
            || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
            || trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil
        paragraphLine = (indent <= 3 && !startsBlock) ? (paragraphLine ?? index) : nil
    }
    return items
}

/// Texto de un título ATX sin la secuencia de cierre opcional (`## Título ##`).
private func atxTitle(_ rest: Substring) -> String {
    var title = rest.trimmingCharacters(in: .whitespaces)
    if let range = title.range(of: #"(^|\s+)#+$"#, options: .regularExpression) {
        title.removeSubrange(range)
    }
    return title
}

/// Saca la sintaxis inline más común para que el esquema muestre el texto tal como se lee.
private func cleanHeadingTitle(_ raw: String) -> String {
    var title = raw
    title = title.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    for token in ["**", "__", "~~", "`"] {
        title = title.replacingOccurrences(of: token, with: "")
    }
    title = title.trimmingCharacters(in: .whitespaces)
    return title.isEmpty ? "—" : title
}
