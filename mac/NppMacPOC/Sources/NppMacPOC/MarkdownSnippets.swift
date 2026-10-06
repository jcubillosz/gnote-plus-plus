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

/// `![](ruta)` — elige imágenes y las enlaza (ver MarkdownImages.chooseAndInsert).
func insertMarkdownImage(editor: ScintillaView, document: Document?) {
    MarkdownImages.chooseAndInsert(editor: editor, document: document)
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

/// Envuelve la selección con `marker` a ambos lados (ej. "**" para negrita); si no
/// hay selección, inserta el par vacío y el caret queda entre medio — mismo criterio
/// que insertMarkdownCodeBlock.
private func wrapSelection(_ editor: ScintillaView, marker: String) {
    let start = ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0)
    let end = ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0)
    if end > start {
        let selected = selectedText(editor, start: Int(start), end: Int(end))
        replaceSelection(editor, with: "\(marker)\(selected)\(marker)")
    } else {
        replaceSelection(editor, with: "\(marker)\(marker)")
    }
}

/// Envuelve la selección con "**...**".
func insertMarkdownBold(editor: ScintillaView) {
    wrapSelection(editor, marker: "**")
}

/// Envuelve la selección con "*...*".
func insertMarkdownItalic(editor: ScintillaView) {
    wrapSelection(editor, marker: "*")
}

/// Envuelve la selección con "~~...~~" (extensión GFM strikethrough, ya habilitada
/// en el renderer — ver Sources/CmarkShim/shim.c).
func insertMarkdownStrikethrough(editor: ScintillaView) {
    wrapSelection(editor, marker: "~~")
}

/// Envuelve la selección con backticks simples (código inline, no bloque).
func insertMarkdownInlineCode(editor: ScintillaView) {
    wrapSelection(editor, marker: "`")
}

/// Antepone `prefix` al inicio de la línea del caret, sin envolver selección —
/// mismo patrón que insertMarkdownHeading.
private func prefixLine(_ editor: ScintillaView, prefix: String) {
    let pos = ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0)
    let line = ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(pos), lParam: 0)
    let lineStart = ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(line), lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_SETSEL, wParam: uptr_t(lineStart), lParam: sptr_t(lineStart))
    replaceSelection(editor, with: prefix)
}

/// Lista con viñeta: "- " al inicio de línea.
func insertMarkdownBulletList(editor: ScintillaView) {
    prefixLine(editor, prefix: "- ")
}

/// Lista numerada: "1. " al inicio de línea.
func insertMarkdownNumberedList(editor: ScintillaView) {
    prefixLine(editor, prefix: "1. ")
}

/// Checklist GFM (tasklist): "- [ ] " al inicio de línea. Requiere texto después del
/// corchete para que cmark-gfm lo reconozca como ítem de lista con checkbox — un
/// "[ ]" o "[x]" suelto, sin guion de lista, no es sintaxis GFM válida.
func insertMarkdownChecklist(editor: ScintillaView) {
    prefixLine(editor, prefix: "- [ ] ")
}

/// Cita: "> " al inicio de línea.
func insertMarkdownBlockquote(editor: ScintillaView) {
    prefixLine(editor, prefix: "> ")
}

private func selectedText(_ editor: ScintillaView, start: Int, end: Int) -> String {
    let full = currentText(editor)
    let bytes = Array(full.utf8)
    guard start >= 0, end <= bytes.count, start <= end else { return "" }
    return String(decoding: bytes[start..<end], as: UTF8.self)
}


/// Alerta de GitHub ("> [!NOTE]"). Convierte las líneas seleccionadas (o la del caret) en
/// el cuerpo de la alerta; si están vacías, deja el caret en la primera línea del cuerpo.
func insertMarkdownAlert(_ kind: String, editor: ScintillaView) {
    let selStart = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0))
    let selEnd = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0))
    let firstLine = Int(ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(selStart), lParam: 0))
    let lastLine = Int(ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(selEnd), lParam: 0))
    let start = Int(ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(firstLine), lParam: 0))
    let end = Int(ScintillaView.directCall(editor, message: SCI_GETLINEENDPOSITION, wParam: uptr_t(lastLine), lParam: 0))
    let lines = selectedText(editor, start: start, end: end).components(separatedBy: "\n")
        .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    let body = lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        ? ["> "]
        : lines.map { "> " + $0 }
    let eol = [0: "\r\n", 1: "\r", 2: "\n"][Int(ScintillaView.directCall(editor, message: SCI_GETEOLMODE, wParam: 0, lParam: 0))] ?? "\n"
    _ = ScintillaView.directCall(editor, message: SCI_SETSEL, wParam: uptr_t(start), lParam: sptr_t(end))
    replaceSelection(editor, with: (["> [!\(kind)]"] + body).joined(separator: eol))
}

/// Marca/desmarca la casilla de la línea del caret.
func toggleMarkdownTaskAtCaret(editor: ScintillaView) {
    let pos = ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0)
    let line = Int(ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(pos), lParam: 0))
    if !MarkdownEditing.toggleTask(editor: editor, line: line) { NSSound.beep() }
}
