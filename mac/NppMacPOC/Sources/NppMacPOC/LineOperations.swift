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
        }
    }
}

/// Aplica `transform` a las líneas seleccionadas o, sin selección, al documento entero (igual
/// que Notepad++ al ordenar). Un solo REPLACETARGET dentro de una acción de undo: ⌘Z deshace
/// todo de una vez.
func transformLines(editor: ScintillaView, _ transform: LineTransform) {
    let hasSelection = selectionStart(editor) != selectionEnd(editor)
    let lineCount = Int(ScintillaView.directCall(editor, message: SCI_GETLINECOUNT, wParam: 0, lParam: 0))
    let range = hasSelection ? selectedLineRange(editor: editor) : (first: 0, last: max(0, lineCount - 1))
    let start = lineStart(editor, range.first)
    let end = lineEnd(editor, range.last)
    guard end > start, let text = SpellChecker.targetText(editor: editor, start: start, end: end) else { return }

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
private func replaceRange(editor: ScintillaView, start: Int, end: Int, with text: String, reselect: Bool) {
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
