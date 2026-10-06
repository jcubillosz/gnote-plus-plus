import Foundation

// Extensiones sobre el HTML que genera cmark-gfm, sin JavaScript en la preview:
// - Alertas de GitHub ("> [!NOTE]"…): cmark-gfm no las conoce, las deja como cita.
// - Casillas de tareas clicables: el <input disabled> pasa a ser un link gnote-task:LÍNEA
//   que intercepta el WKNavigationDelegate (la navegación sí funciona sin JS).

/// Esquema de los links de casillas de la preview. Nunca se navega: decidePolicyFor lo
/// cancela y marca/desmarca la línea en el editor.
let markdownTaskScheme = "gnote-task"

enum MarkdownHTMLExtensions {
    private static let alert = try! NSRegularExpression(
        pattern: #"<blockquote([^>]*)>\n<p([^>]*)>\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*(?:<br />)?\n?"#,
        options: [.caseInsensitive]
    )

    private static let task = try! NSRegularExpression(
        pattern: #"<li( data-sourcepos="(\d+):[^"]*")><input type="checkbox"( checked="")? disabled="" /> "#
    )

    static func applyAlerts(_ html: String) -> String {
        replaceMatches(of: alert, in: html) { groups in
            let kind = groups[3].lowercased()
            let title: String
            switch kind {
            case "note": title = L("Nota")
            case "tip": title = L("Consejo")
            case "important": title = L("Importante")
            case "warning": title = L("Advertencia")
            default: title = L("Precaución")
            }
            return "<blockquote class=\"markdown-alert markdown-alert-\(kind)\"\(groups[1])>\n"
                + "<p class=\"markdown-alert-title\">\(escapeHTMLText(title))</p>\n<p\(groups[2])>"
        }
    }

    /// Solo con data-sourcepos (la preview): es lo que da la línea del fuente a marcar.
    static func clickableTasks(_ html: String) -> String {
        replaceMatches(of: task, in: html) { groups in
            let checked = !groups[3].isEmpty
            return "<li\(groups[1]) class=\"task-list-item\">"
                + "<a class=\"task-toggle\" href=\"\(markdownTaskScheme):\(groups[2])\">"
                + "<span class=\"task-box\(checked ? " checked" : "")\"></span></a> "
        }
    }

    private static func replaceMatches(
        of regex: NSRegularExpression, in html: String, _ transform: ([String]) -> String
    ) -> String {
        let ns = html as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += transform(groups)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
