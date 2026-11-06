import Foundation
import Scintilla

// Operaciones de línea y de mayúsculas/minúsculas del menú Editar, equivalentes a los
// IDM_EDIT_* de Notepad++ (PowerEditor/src/menuCmdID.h). Mismo patrón que
// MarkdownSnippets.swift: funciones libres sobre el ScintillaView compartido.

func duplicateSelectionOrLine(editor: ScintillaView) {
    _ = ScintillaView.directCall(editor, message: SCI_SELECTIONDUPLICATE, wParam: 0, lParam: 0)
}

func moveSelectedLines(editor: ScintillaView, up: Bool) {
    _ = ScintillaView.directCall(editor, message: up ? SCI_MOVESELECTEDLINESUP : SCI_MOVESELECTEDLINESDOWN, wParam: 0, lParam: 0)
}

func deleteCurrentLine(editor: ScintillaView) {
    _ = ScintillaView.directCall(editor, message: SCI_LINEDELETE, wParam: 0, lParam: 0)
}

/// Une las líneas seleccionadas; sin selección, une la línea actual con la siguiente
/// (como Notepad++).
func joinLines(editor: ScintillaView) {
    let range = selectedLineRange(editor: editor)
    let lastLine = range.last == range.first ? range.first + 1 : range.last
    let lineCount = Int(ScintillaView.directCall(editor, message: SCI_GETLINECOUNT, wParam: 0, lParam: 0))
    guard lastLine < lineCount else { return }
    let start = lineStart(editor, range.first)
    let end = lineEnd(editor, lastLine)
    _ = ScintillaView.directCall(editor, message: SCI_SETTARGETRANGE, wParam: uptr_t(start), lParam: sptr_t(end))
    _ = ScintillaView.directCall(editor, message: SCI_LINESJOIN, wParam: 0, lParam: 0)
}

enum LineTransform {
    case sortAscending, sortDescending, removeConsecutiveDuplicates, removeAllDuplicates, removeEmptyLines
    case reverse, shuffle, sortCaseInsensitive, sortNumeric, sortByLength, trimLeading, trimTrailing, trimBoth

    func apply(_ lines: [String]) -> [String] {
        switch self {
        case .sortAscending:
            return lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        case .sortDescending:
            return lines.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        case .removeConsecutiveDuplicates:
            return lines.enumerated().filter { $0.offset == 0 || lines[$0.offset - 1] != $0.element }.map(\.element)
        case .removeAllDuplicates:
            var seen = Set<String>()
            return lines.filter { seen.insert($0).inserted }
        case .removeEmptyLines:
            return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        case .reverse:
            return lines.reversed()
        case .shuffle:
            return lines.shuffled()
        case .sortCaseInsensitive:
            return lines.enumerated().sorted {
                let r = $0.element.localizedCaseInsensitiveCompare($1.element)
                return r == .orderedSame ? $0.offset < $1.offset : r == .orderedAscending
            }.map(\.element)
        case .sortNumeric:
            // Sin número al final y en su orden original; estable entre iguales.
            let keyed = lines.enumerated().map { (offset: $0.offset, line: $0.element, key: leadingNumber($0.element)) }
            let numeric = keyed.filter { $0.key != nil }.sorted { $0.key! == $1.key! ? $0.offset < $1.offset : $0.key! < $1.key! }
            return numeric.map(\.line) + keyed.filter { $0.key == nil }.map(\.line)
        case .sortByLength:
            return lines.enumerated().sorted {
                $0.element.count == $1.element.count ? $0.offset < $1.offset : $0.element.count < $1.element.count
            }.map(\.element)
        case .trimLeading:
            return lines.map { String($0.drop(while: { $0 == " " || $0 == "\t" })) }
        case .trimTrailing:
            return lines.map(trimTrailingBlanks)
        case .trimBoth:
            return lines.map { trimTrailingBlanks(String($0.drop(while: { $0 == " " || $0 == "\t" }))) }
        }
    }
}

/// Espacios y tabs finales; un `\r` final (EOL mixto) queda donde está.
private func trimTrailingBlanks(_ line: String) -> String {
    var scalars = Array(line.unicodeScalars)
    var tail = [Unicode.Scalar]()
    while scalars.last == "\r" { tail.append(scalars.removeLast()) }
    while let l = scalars.last, l == " " || l == "\t" { scalars.removeLast() }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: scalars)
    out.append(contentsOf: tail.reversed())
    return String(out)
}

/// Número al inicio de la línea (tras espacios): signo opcional, dígitos y decimal con punto.
private func leadingNumber(_ line: String) -> Double? {
    let chars = Array(line.unicodeScalars)
    var i = 0
    while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
    let begin = i
    if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
    let digitsStart = i
    while i < chars.count, chars[i].value >= 48, chars[i].value <= 57 { i += 1 }
    var hasDigits = i > digitsStart
    if i + 1 < chars.count, chars[i] == ".", chars[i + 1].value >= 48, chars[i + 1].value <= 57 {
        i += 1
        while i < chars.count, chars[i].value >= 48, chars[i].value <= 57 { i += 1 }
        hasDigits = true
    }
    guard hasDigits else { return nil }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: chars[begin..<i])
    return Double(String(view))
}

/// Última línea del alcance "documento entero": excluye la línea vacía que queda tras el último EOL.
private func lastContentLine(_ editor: ScintillaView, _ lineCount: Int) -> Int {
    let last = max(0, lineCount - 1)
    return last > 0 && lineStart(editor, last) == lineEnd(editor, last) ? last - 1 : last
}

/// Aplica `transform` a las líneas seleccionadas o, sin selección, al documento entero (igual
/// que Notepad++ al ordenar). Un solo REPLACETARGET dentro de una acción de undo: ⌘Z deshace
/// todo de una vez.
func transformLines(editor: ScintillaView, _ transform: LineTransform) {
    let hasSelection = selectionStart(editor) != selectionEnd(editor)
    let lineCount = Int(ScintillaView.directCall(editor, message: SCI_GETLINECOUNT, wParam: 0, lParam: 0))
    let range = hasSelection ? selectedLineRange(editor: editor) : (first: 0, last: lastContentLine(editor, lineCount))
    let start = lineStart(editor, range.first)
    let end = lineEnd(editor, range.last)
    guard end > start, let text = SpellChecker.targetText(editor: editor, start: start, end: end) else { return }

    // components(separatedBy:) es de NSString (UTF-16): a diferencia de split sobre Character,
    // sí parte "\r\n" como secuencia.
    let eol = text.contains("\r\n") ? "\r\n" : (text.contains("\r") && !text.contains("\n") ? "\r" : "\n")
    let lines = text.components(separatedBy: eol)
    let result = transform.apply(lines).joined(separator: eol)
    guard result != text else { return }
    replaceRange(editor: editor, start: start, end: end, with: result, reselect: hasSelection)
}

func convertCase(editor: ScintillaView, upper: Bool) {
    _ = ScintillaView.directCall(editor, message: upper ? SCI_UPPERCASE : SCI_LOWERCASE, wParam: 0, lParam: 0)
}

/// "Tipo Título" sobre la selección (Notepad++: IDM_EDIT_PROPERCASE_FORCE).
func convertToTitleCase(editor: ScintillaView) {
    let start = selectionStart(editor), end = selectionEnd(editor)
    guard end > start, let text = SpellChecker.targetText(editor: editor, start: start, end: end) else { return }
    let result = text.capitalized(with: Locale.current)
    guard result != text else { return }
    replaceRange(editor: editor, start: start, end: end, with: result, reselect: true)
}

/// "Tipo oración" sobre la selección: minúsculas y mayúscula tras `.`, `!`, `?` + espacio/salto.
func convertToSentenceCase(editor: ScintillaView) {
    let start = selectionStart(editor), end = selectionEnd(editor)
    guard end > start, let text = SpellChecker.targetText(editor: editor, start: start, end: end) else { return }
    let result = sentenceCased(text)
    guard result != text else { return }
    replaceRange(editor: editor, start: start, end: end, with: result, reselect: true)
}

func sentenceCased(_ text: String) -> String {
    var out = "", capNext = true, pendingEnd = false
    for ch in text.lowercased() {
        if ch.isLetter {
            out += capNext ? String(ch).uppercased() : String(ch)
            capNext = false; pendingEnd = false
        } else {
            if ch == "." || ch == "!" || ch == "?" { pendingEnd = true }
            else if ch.isWhitespace { if pendingEnd { capNext = true }; pendingEnd = false }
            else if ch.isNumber { capNext = false; pendingEnd = false }
            else { pendingEnd = false }
            out.append(ch)
        }
    }
    return out
}

func invertedCase(_ text: String) -> String {
    var out = ""
    for ch in text {
        let s = String(ch)
        out += s.lowercased() != s ? s.lowercased() : s.uppercased()
    }
    return out
}

func invertCase(editor: ScintillaView) {
    let start = selectionStart(editor), end = selectionEnd(editor)
    guard end > start, let text = SpellChecker.targetText(editor: editor, start: start, end: end) else { return }
    let result = invertedCase(text)
    guard result != text else { return }
    replaceRange(editor: editor, start: start, end: end, with: result, reselect: true)
}

/// Une las líneas del alcance con un espacio, recortando los bordes de cada unión.
func joinLinesWithSpace(editor: ScintillaView) {
    let (start, end, hadSelection) = convertionRange(editor: editor)
    guard end > start, let text = SpellChecker.targetText(editor: editor, start: start, end: end) else { return }
    let result = joinedWithSpaces(text)
    guard result != text else { return }
    replaceRange(editor: editor, start: start, end: end, with: result, reselect: hadSelection)
}

func joinedWithSpaces(_ text: String) -> String {
    // "\r\n" primero, para que no cuente como dos saltos; "\r" suelto es EOL de Mac clásico.
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let lines = splitLines(normalized).map { String($0) }
    let pieces = lines.enumerated().map { i, l -> String in
        var s = l
        if i > 0 { s = String(s.drop(while: { $0 == " " || $0 == "\t" })) }
        if i < lines.count - 1 { s = trimTrailingBlanks(s) }
        return s
    }
    let nonEmpty = pieces.filter { !$0.isEmpty }
    return (nonEmpty.isEmpty ? pieces : nonEmpty).joined(separator: " ")
}

/// Inserta un EOL del documento arriba o abajo de la línea del caret y deja el caret en la nueva.
func insertBlankLine(editor: ScintillaView, above: Bool) {
    func call(_ m: UInt32, _ w: uptr_t = 0, _ l: sptr_t = 0) -> Int {
        Int(ScintillaView.directCall(editor, message: m, wParam: w, lParam: l))
    }
    let eol: String
    switch call(SCI_GETEOLMODE) {
    case 0: eol = "\r\n"
    case 1: eol = "\r"
    default: eol = "\n"
    }
    let line = lineFromPosition(editor, call(SCI_GETCURRENTPOS))
    let pos = above ? lineStart(editor, line) : lineEnd(editor, line)
    _ = call(SCI_BEGINUNDOACTION)
    eol.withCString { _ = call(SCI_INSERTTEXT, uptr_t(pos), sptr_t(bitPattern: UInt(bitPattern: $0))) }
    _ = call(SCI_ENDUNDOACTION)
    _ = call(SCI_GOTOPOS, uptr_t(above ? pos : pos + eol.utf8.count))
}

/// Comentar/descomentar las líneas seleccionadas (o la del caret). Con comentario de línea:
/// si todas las líneas no vacías ya empiezan con el prefijo, lo quita; si no, lo agrega tras
/// la indentación de cada una. Sin comentario de línea (p.ej. HTML/CSS): envuelve o
/// desenvuelve el bloque con commentStart/commentEnd.
func toggleComment(editor: ScintillaView, syntax: CommentSyntax) {
    let range = selectedLineRange(editor: editor)
    let start = lineStart(editor, range.first)
    let end = lineEnd(editor, range.last)
    let text = SpellChecker.targetText(editor: editor, start: start, end: end) ?? ""
    let hadSelection = selectionStart(editor) != selectionEnd(editor)

    if let prefix = syntax.line {
        let eol = text.contains("\r\n") ? "\r\n" : "\n"
        let lines = text.components(separatedBy: eol)
        let nonBlank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonBlank.isEmpty else { return }
        let allCommented = nonBlank.allSatisfy { $0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(prefix) }
        let result = lines.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            var body = String(line.dropFirst(indent.count))
            if allCommented {
                body.removeFirst(prefix.count)
                if body.hasPrefix(" ") { body.removeFirst() }
                return indent + body
            }
            return indent + prefix + " " + body
        }.joined(separator: eol)
        replaceRange(editor: editor, start: start, end: end, with: result, reselect: hadSelection)
    } else if let open = syntax.blockStart, let close = syntax.blockEnd {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: String
        if trimmed.hasPrefix(open), trimmed.hasSuffix(close), trimmed.count >= open.count + close.count {
            var inner = String(trimmed.dropFirst(open.count).dropLast(close.count))
            if inner.hasPrefix(" ") { inner.removeFirst() }
            if inner.hasSuffix(" ") { inner.removeLast() }
            let indent = String(text.prefix(while: { $0 == " " || $0 == "\t" }))
            result = indent + inner
        } else {
            let indent = String(text.prefix(while: { $0 == " " || $0 == "\t" }))
            result = indent + open + " " + text.dropFirst(indent.count) + " " + close
        }
        replaceRange(editor: editor, start: start, end: end, with: result, reselect: hadSelection)
    }
}

// MARK: - Helpers

/// Primera y última línea abarcadas por la selección. Si la selección termina justo al inicio
/// de una línea (selección de líneas completas con el teclado), esa línea no cuenta.
private func selectedLineRange(editor: ScintillaView) -> (first: Int, last: Int) {
    let start = selectionStart(editor), end = selectionEnd(editor)
    let first = lineFromPosition(editor, start)
    var last = lineFromPosition(editor, end)
    if end > start, last > first, lineStart(editor, last) == end {
        last -= 1
    }
    return (first, last)
}

/// Reemplaza [start, end) dentro de una sola acción de undo y, si `reselect`, deja
/// seleccionado el texto nuevo (para encadenar operaciones sobre el mismo bloque).
func replaceRange(editor: ScintillaView, start: Int, end: Int, with text: String, reselect: Bool) {
    _ = ScintillaView.directCall(editor, message: SCI_BEGINUNDOACTION, wParam: 0, lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_SETTARGETRANGE, wParam: uptr_t(start), lParam: sptr_t(end))
    text.withCString { cstr in
        _ = ScintillaView.directCall(
            editor, message: SCI_REPLACETARGET,
            wParam: uptr_t(text.utf8.count),
            lParam: sptr_t(bitPattern: UInt(bitPattern: cstr))
        )
    }
    _ = ScintillaView.directCall(editor, message: SCI_ENDUNDOACTION, wParam: 0, lParam: 0)
    let newEnd = start + text.utf8.count
    _ = ScintillaView.directCall(editor, message: SCI_SETSEL, wParam: uptr_t(reselect ? start : newEnd), lParam: sptr_t(newEnd))
}

private func selectionStart(_ editor: ScintillaView) -> Int {
    Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0))
}

private func selectionEnd(_ editor: ScintillaView) -> Int {
    Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0))
}

private func lineFromPosition(_ editor: ScintillaView, _ position: Int) -> Int {
    Int(ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(position), lParam: 0))
}

private func lineStart(_ editor: ScintillaView, _ line: Int) -> Int {
    Int(ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(line), lParam: 0))
}

private func lineEnd(_ editor: ScintillaView, _ line: Int) -> Int {
    Int(ScintillaView.directCall(editor, message: SCI_GETLINEENDPOSITION, wParam: uptr_t(line), lParam: 0))
}

// MARK: - Tabs <-> espacios

/// Reemplaza cada tab por los espacios que faltan hasta el próximo tab stop (columna visual,
/// contada en caracteres).
private func tabsToSpaces(_ text: String, tabWidth: Int) -> String {
    let width = max(1, tabWidth)
    return splitLines(text).map { line -> String in
        var out = String.UnicodeScalarView(), col = 0
        for ch in line {
            if ch == "\t" {
                let n = width - (col % width)
                out.append(contentsOf: String(repeating: " ", count: n).unicodeScalars)
                col += n
            } else {
                out.append(ch)
                col += 1
            }
        }
        return String(out)
    }.joined(separator: "\n")
}

/// Reemplaza la indentación inicial (espacios y tabs) por tabs + espacios sobrantes; el resto
/// de la línea queda intacto.
private func leadingSpacesToTabs(_ text: String, tabWidth: Int) -> String {
    let width = max(1, tabWidth)
    return splitLines(text).map { line -> String in
        var col = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            col += line[idx] == "\t" ? width - (col % width) : 1
            idx = line.index(after: idx)
        }
        if idx == line.startIndex { return String(line) }
        return String(repeating: "\t", count: col / width) + String(repeating: " ", count: col % width) + String(line[idx...])
    }.joined(separator: "\n")
}

/// Parte por "\n" sobre scalars: en Character "\r\n" es un solo elemento y no se partiría en CRLF.
private func splitLines(_ text: String) -> [Substring.UnicodeScalarView] {
    text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
}

/// Rango en bytes de las líneas de la selección, o de todo el documento sin selección.
private func convertionRange(editor: ScintillaView) -> (start: Int, end: Int, hadSelection: Bool) {
    if selectionEnd(editor) > selectionStart(editor) {
        let (first, last) = selectedLineRange(editor: editor)
        return (lineStart(editor, first), lineEnd(editor, last), true)
    }
    let lineCount = Int(ScintillaView.directCall(editor, message: SCI_GETLINECOUNT, wParam: 0, lParam: 0))
    return (0, lineEnd(editor, lastContentLine(editor, lineCount)), false)
}

private func transformWhitespace(editor: ScintillaView, _ transform: (String) -> String) {
    let (start, end, hadSelection) = convertionRange(editor: editor)
    guard end > start, let text = targetText(editor: editor, start: start, end: end) else { return }
    let result = transform(text)
    guard result != text else { return }
    func call(_ m: UInt32, _ w: uptr_t = 0, _ l: sptr_t = 0) -> Int {
        Int(ScintillaView.directCall(editor, message: m, wParam: w, lParam: l))
    }
    // Sin selección el reemplazo deja el cursor al final del documento: se restaura
    // línea/columna (columna recortada al fin de línea) y el scroll.
    let caret = call(SCI_GETCURRENTPOS)
    let caretLine = call(SCI_LINEFROMPOSITION, uptr_t(caret))
    let caretColumn = caret - call(SCI_POSITIONFROMLINE, uptr_t(caretLine))
    let firstVisible = call(SCI_GETFIRSTVISIBLELINE)
    replaceRange(editor: editor, start: start, end: end, with: result, reselect: hadSelection)
    guard !hadSelection else { return }
    let line = min(caretLine, call(SCI_GETLINECOUNT) - 1)
    let lineStart = call(SCI_POSITIONFROMLINE, uptr_t(line))
    let lineEnd = call(SCI_GETLINEENDPOSITION, uptr_t(line))
    var target = min(lineStart + caretColumn, lineEnd)
    // SCI_GOTOPOS no normaliza una posición a mitad de un carácter UTF-8 multibyte.
    if target > lineStart {
        target = min(call(SCI_POSITIONAFTER, uptr_t(call(SCI_POSITIONBEFORE, uptr_t(target)))), lineEnd)
    }
    _ = call(SCI_GOTOPOS, uptr_t(target))
    // Mismo valor de pantalla leído con SCI_GETFIRSTVISIBLELINE, como restoreViewState.
    _ = call(SCI_SETFIRSTVISIBLELINE, uptr_t(firstVisible))
}

private func targetText(editor: ScintillaView, start: Int, end: Int) -> String? {
    _ = ScintillaView.directCall(editor, message: SCI_SETTARGETRANGE, wParam: uptr_t(start), lParam: sptr_t(end))
    let length = Int(ScintillaView.directCall(editor, message: SCI_GETTARGETTEXT, wParam: 0, lParam: 0))
    guard length > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: length + 1)
    buffer.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        _ = ScintillaView.directCall(editor, message: SCI_GETTARGETTEXT, wParam: 0, lParam: sptr_t(bitPattern: UInt(bitPattern: base)))
    }
    return String(decoding: buffer.prefix(length), as: UTF8.self)
}

func convertTabsToSpaces(editor: ScintillaView, tabWidth: Int) {
    transformWhitespace(editor: editor) { tabsToSpaces($0, tabWidth: tabWidth) }
}

func convertLeadingSpacesToTabs(editor: ScintillaView, tabWidth: Int) {
    transformWhitespace(editor: editor) { leadingSpacesToTabs($0, tabWidth: tabWidth) }
}

// MARK: - Fecha y hora

enum DateTimeInsertStyle { case short, long, iso8601 }

func insertDateTime(editor: ScintillaView, style: DateTimeInsertStyle, now: Date = Date()) {
    let formatter = DateFormatter()
    switch style {
    case .short:
        formatter.dateStyle = .short; formatter.timeStyle = .short
    case .long:
        formatter.dateStyle = .full; formatter.timeStyle = .short
    case .iso8601:
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
    }
    let text = formatter.string(from: now)
    text.withCString { cstr in
        _ = ScintillaView.directCall(editor, message: SCI_REPLACESEL, wParam: 0, lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
    }
}
