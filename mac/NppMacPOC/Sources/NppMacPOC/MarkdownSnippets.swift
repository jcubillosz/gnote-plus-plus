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

/// Quita el prefijo de título ATX (hasta 3 espacios de sangría) y antepone el nivel pedido;
/// "#hashtag" sin espacio no es título, por eso exige espacio o fin de línea tras los '#'.
func markdownHeadingLine(_ line: String, level: Int) -> String {
    var body = Substring(line)
    var spaces = 0
    var i = body.startIndex
    while i < body.endIndex, body[i] == " ", spaces < 3 { spaces += 1; i = body.index(after: i) }
    var j = i
    var hashes = 0
    while j < body.endIndex, body[j] == "#", hashes < 7 { hashes += 1; j = body.index(after: j) }
    if (1...6).contains(hashes), j == body.endIndex || body[j] == " " || body[j] == "\t" {
        while j < body.endIndex, body[j] == " " || body[j] == "\t" { j = body.index(after: j) }
        body = body[j...]
    }
    guard (1...6).contains(level) else { return String(body) }
    return String(repeating: "#", count: level) + " " + body
}

/// Fija el nivel de título de la línea del caret (0 = texto normal) en una sola acción de deshacer.
func setMarkdownHeading(level: Int, editor: ScintillaView) {
    guard !mdReadOnly(editor) else { return }
    let pos = ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0)
    let line = ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(pos), lParam: 0)
    let start = Int(ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(line), lParam: 0))
    let end = Int(ScintillaView.directCall(editor, message: SCI_GETLINEENDPOSITION, wParam: uptr_t(line), lParam: 0))
    var text = ""
    if end > start {
        _ = ScintillaView.directCall(editor, message: SCI_SETTARGETRANGE, wParam: uptr_t(start), lParam: sptr_t(end))
        var buffer = [CChar](repeating: 0, count: end - start + 1)
        _ = buffer.withUnsafeMutableBufferPointer { p in
            ScintillaView.directCall(editor, message: SCI_GETTARGETTEXT, wParam: 0,
                                     lParam: sptr_t(bitPattern: UInt(bitPattern: p.baseAddress)))
        }
        text = String(cString: buffer)
    }
    let newText = markdownHeadingLine(text, level: level)
    // Sin cambio no se toca el documento: evitaría una acción de deshacer vacía y marcarlo "sin guardar".
    guard newText != text else { return }
    _ = ScintillaView.directCall(editor, message: SCI_BEGINUNDOACTION, wParam: 0, lParam: 0)
    defer { _ = ScintillaView.directCall(editor, message: SCI_ENDUNDOACTION, wParam: 0, lParam: 0) }
    mdSelect(editor, start, end)
    replaceSelection(editor, with: newText)
}

/// Tabla Markdown: encabezado, separador y `rows` filas con celdas vacías de dos espacios.
func markdownTable(columns: Int, rows: Int, eol: String) -> String {
    let n = max(1, columns)
    let header = "|" + (1...n).map { " " + String(format: L("Columna %lld"), $0) + " |" }.joined()
    let sep = "|" + String(repeating: " --- |", count: n)
    let row = "|" + String(repeating: "  |", count: n)
    return ([header, sep] + Array(repeating: row, count: max(0, rows))).joined(separator: eol) + eol
}

/// Inserta la tabla en línea propia y deja el caret en la primera celda de datos.
func insertMarkdownTable(columns: Int = 3, rows: Int = 1, editor: ScintillaView) {
    guard !mdReadOnly(editor) else { return }
    let eol = mdEOL(editor)
    let pos = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0))
    let line = ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(pos), lParam: 0)
    let lineStart = Int(ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(line), lParam: 0))
    let lineEnd = Int(ScintillaView.directCall(editor, message: SCI_GETLINEENDPOSITION, wParam: uptr_t(line), lParam: 0))
    let prefix = (pos == lineStart && lineEnd == lineStart) ? "" : eol
    let table = markdownTable(columns: columns, rows: rows, eol: eol)
    _ = ScintillaView.directCall(editor, message: SCI_BEGINUNDOACTION, wParam: 0, lParam: 0)
    defer { _ = ScintillaView.directCall(editor, message: SCI_ENDUNDOACTION, wParam: 0, lParam: 0) }
    replaceSelection(editor, with: prefix + table)
    // Primera celda de datos: tras "| " de la tercera línea de la tabla.
    let startLine = Int(line) + (prefix.isEmpty ? 0 : 1)
    let dataStart = Int(ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(startLine + 2), lParam: 0))
    if rows > 0 { mdSelect(editor, dataStart + 2, dataStart + 2) }
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

/// Envuelve la selección con `prefix`/`suffix`; sin selección inserta el par y deja el
/// caret entre medio. Una sola acción de deshacer; no hace nada en documentos de solo lectura.
private func wrapSelection(_ editor: ScintillaView, prefix: String, suffix: String) {
    guard !mdReadOnly(editor) else { return }
    let start = ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0)
    let end = ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_BEGINUNDOACTION, wParam: 0, lParam: 0)
    defer { _ = ScintillaView.directCall(editor, message: SCI_ENDUNDOACTION, wParam: 0, lParam: 0) }
    if end > start {
        let selected = selectedText(editor, start: Int(start), end: Int(end))
        replaceSelection(editor, with: "\(prefix)\(selected)\(suffix)")
    } else {
        replaceSelection(editor, with: "\(prefix)\(suffix)")
        let pos = ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0)
        let back = pos - sptr_t(suffix.utf8.count)
        _ = ScintillaView.directCall(editor, message: SCI_SETSEL, wParam: uptr_t(back), lParam: sptr_t(back))
    }
}

private func wrapSelection(_ editor: ScintillaView, marker: String) {
    wrapSelection(editor, prefix: marker, suffix: marker)
}

private func mdReadOnly(_ editor: ScintillaView) -> Bool {
    ScintillaView.directCall(editor, message: SCI_GETREADONLY, wParam: 0, lParam: 0) != 0
}

private func mdSelect(_ editor: ScintillaView, _ from: Int, _ to: Int) {
    _ = ScintillaView.directCall(editor, message: SCI_SETSEL, wParam: uptr_t(from), lParam: sptr_t(to))
}

/// `<tag>sel</tag>` (mark, kbd, sub, sup).
func insertMarkdownTag(_ tag: String, editor: ScintillaView) {
    wrapSelection(editor, prefix: "<\(tag)>", suffix: "</\(tag)>")
}

/// `[sel](url)` con `url` seleccionado; sin selección `[texto](url)` con `texto` seleccionado.
func insertMarkdownLink(editor: ScintillaView) {
    guard !mdReadOnly(editor) else { return }
    let start = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0))
    let end = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0))
    let selected = end > start ? selectedText(editor, start: start, end: end) : ""
    _ = ScintillaView.directCall(editor, message: SCI_BEGINUNDOACTION, wParam: 0, lParam: 0)
    defer { _ = ScintillaView.directCall(editor, message: SCI_ENDUNDOACTION, wParam: 0, lParam: 0) }
    if end > start {
        replaceSelection(editor, with: "[\(selected)](url)")
        let urlStart = start + 1 + selected.utf8.count + 2
        mdSelect(editor, urlStart, urlStart + 3)
    } else {
        replaceSelection(editor, with: "[texto](url)")
        mdSelect(editor, start + 1, start + 6)
    }
}

/// Fin de línea del documento según SCI_GETEOLMODE.
private func mdEOL(_ editor: ScintillaView) -> String {
    [0: "\r\n", 1: "\r", 2: "\n"][Int(ScintillaView.directCall(editor, message: SCI_GETEOLMODE, wParam: 0, lParam: 0))] ?? "\n"
}

/// Saltos de línea al final del texto; por unicodeScalars porque "\r\n" es un solo Character.
func trailingLineBreaks(_ text: String) -> Int {
    var n = 0
    var it = Array(text.unicodeScalars)
    while let last = it.last {
        if last == "\n" {
            it.removeLast()
            if it.last == "\r" { it.removeLast() }
        } else if last == "\r" {
            it.removeLast()
        } else { break }
        n += 1
    }
    return n
}

/// Separador para que lo que sigue quede tras una línea vacía (o nada si el texto está vacío).
func blankLineSeparator(for text: String, eol: String) -> String {
    text.isEmpty ? "" : String(repeating: eol, count: max(0, 2 - trailingLineBreaks(text)))
}

/// `---` en línea propia, precedido de línea vacía si la anterior tiene texto (si no, se
/// leería como título setext).
func insertMarkdownHorizontalRule(editor: ScintillaView) {
    guard !mdReadOnly(editor) else { return }
    let eol = mdEOL(editor)
    let pos = ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0)
    let col = ScintillaView.directCall(editor, message: SCI_GETCOLUMN, wParam: uptr_t(pos), lParam: 0)
    var prefix = ""
    if col != 0 {
        prefix = eol + eol
    } else {
        let line = Int(ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(pos), lParam: 0))
        if line > 0 {
            let ps = ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(line - 1), lParam: 0)
            let pe = ScintillaView.directCall(editor, message: SCI_GETLINEENDPOSITION, wParam: uptr_t(line - 1), lParam: 0)
            if pe > ps { prefix = eol }
        }
    }
    replaceSelection(editor, with: prefix + "---" + eol)
}

/// Sección plegable; deja seleccionado "Título".
func insertMarkdownDetails(editor: ScintillaView) {
    guard !mdReadOnly(editor) else { return }
    let start = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0))
    let end = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0))
    let selected = end > start ? selectedText(editor, start: start, end: end) : ""
    let eol = mdEOL(editor)
    let head = "<details>\(eol)<summary>"
    replaceSelection(editor, with: "\(head)Título</summary>\(eol)\(eol)\(selected)\(eol)\(eol)</details>\(eol)")
    mdSelect(editor, start + head.utf8.count, start + head.utf8.count + "Título".utf8.count)
}

/// Siguiente número libre de nota al pie: 1 + máximo `[^n]` numérico (1 si no hay).
func nextFootnoteNumber(in text: String) -> Int {
    guard let re = try? NSRegularExpression(pattern: "\\[\\^(\\d+)\\]") else { return 1 }
    let ns = text as NSString
    var maxN = 0
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        if let n = Int(ns.substring(with: m.range(at: 1))) { maxN = max(maxN, n) }
    }
    return maxN + 1
}

/// Inserta `[^n]` en el caret y agrega `[^n]: ` al final del documento; caret ahí.
func insertMarkdownFootnote(editor: ScintillaView) {
    guard !mdReadOnly(editor) else { return }
    let n = nextFootnoteNumber(in: currentText(editor))
    _ = ScintillaView.directCall(editor, message: SCI_BEGINUNDOACTION, wParam: 0, lParam: 0)
    defer { _ = ScintillaView.directCall(editor, message: SCI_ENDUNDOACTION, wParam: 0, lParam: 0) }
    replaceSelection(editor, with: "[^\(n)]")
    let full = currentText(editor)
    let sep = blankLineSeparator(for: full, eol: mdEOL(editor))
    let len = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
    mdSelect(editor, len, len)
    replaceSelection(editor, with: "\(sep)[^\(n)]: ")
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
/// mismo patrón que setMarkdownHeading.
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
