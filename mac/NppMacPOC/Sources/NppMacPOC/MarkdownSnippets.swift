import AppKit
import Scintilla

/// Reemplaza la selección actual (o inserta en el caret si no hay selección) y
/// deja el caret visible. SCI_REPLACESEL toma bytes UTF-8, igual que loadText.
private func replaceSelection(_ editor: ScintillaView, with text: String) {
    text.withCString { cstr in
        _ = ScintillaView.directCall(editor, message: SCI_REPLACESEL, wParam: 0, lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
    }
    _ = ScintillaView.directCall(editor, message: SCI_SCROLLCARET, wParam: 0, lParam: 0)
}

/// Título: "## " al principio de la línea del caret, sin envolver la selección.
func insertMarkdownHeading(level: Int, editor: ScintillaView) {
    let pos = ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0)
    let line = ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(pos), lParam: 0)
    let lineStart = ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(line), lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_SETSEL, wParam: uptr_t(lineStart), lParam: sptr_t(lineStart))
    replaceSelection(editor, with: String(repeating: "#", count: max(1, min(level, 6))) + " ")
}

/// Plantilla de 3 columnas x 2 filas con fila de separadores.
func insertMarkdownTable(editor: ScintillaView) {
    let table = """
    | Columna 1 | Columna 2 | Columna 3 |
    | --- | --- | --- |
    | | | |

    """
    replaceSelection(editor, with: table)
}

/// `![](ruta)` — abre un NSOpenPanel filtrado a imágenes. Si el documento ya está
/// guardado, escribe la ruta relativa al .md (lo que MarkdownImageSource resuelve);
/// si no, la absoluta.
func insertMarkdownImage(editor: ScintillaView, document: Document?) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.image]
    guard panel.runModal() == .OK, let imageURL = panel.url else { return }

    let path: String
    if let docURL = document?.url {
        path = imageURL.path(relativeTo: docURL.deletingLastPathComponent()) ?? imageURL.path
    } else {
        path = imageURL.path
    }
    replaceSelection(editor, with: "![](\(path))")
}

/// Cerca ``` arriba y abajo; si hay selección, la envuelve.
func insertMarkdownCodeBlock(editor: ScintillaView) {
    let start = ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0)
    let end = ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0)
    if end > start {
        let selected = selectedText(editor, start: Int(start), end: Int(end))
        replaceSelection(editor, with: "```\n\(selected)\n```")
    } else {
        replaceSelection(editor, with: "```\n\n```")
    }
}

private func selectedText(_ editor: ScintillaView, start: Int, end: Int) -> String {
    let full = currentText(editor)
    let bytes = Array(full.utf8)
    guard start >= 0, end <= bytes.count, start <= end else { return "" }
    return String(decoding: bytes[start..<end], as: UTF8.self)
}

private extension URL {
    /// Ruta relativa de este archivo respecto de `base`, o nil si no comparten prefijo.
    func path(relativeTo base: URL) -> String? {
        let baseComponents = base.standardizedFileURL.pathComponents
        let selfComponents = self.standardizedFileURL.pathComponents
        var common = 0
        while common < baseComponents.count, common < selfComponents.count, baseComponents[common] == selfComponents[common] {
            common += 1
        }
        guard common > 0 else { return nil }
        let ups = Array(repeating: "..", count: baseComponents.count - common)
        let downs = selfComponents[common...]
        return (ups + downs).joined(separator: "/")
    }
}
