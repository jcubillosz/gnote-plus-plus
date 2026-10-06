import Foundation
import Scintilla

// Ayudas de edición de Markdown en el editor (no en el render): continuar listas con Enter y
// alinear tablas, como las extensiones de Markdown de VSCode.

let SCI_GETEOLMODE: UInt32 = 2030
private let SCE_MARKDOWN_CODE = 19
private let SCE_MARKDOWN_CODE2 = 20
private let SCE_MARKDOWN_CODEBK = 21

private func call(_ editor: ScintillaView, _ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
    Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
}

/// Texto de la línea sin el fin de línea.
private func lineText(_ editor: ScintillaView, _ line: Int) -> String {
    let start = call(editor, SCI_POSITIONFROMLINE, line)
    let end = call(editor, SCI_GETLINEENDPOSITION, line)
    guard start >= 0, end > start else { return "" }
    _ = call(editor, SCI_SETTARGETRANGE, start, end)
    var buffer = [CChar](repeating: 0, count: end - start + 1)
    _ = buffer.withUnsafeMutableBufferPointer { pointer in
        ScintillaView.directCall(editor, message: SCI_GETTARGETTEXT, wParam: 0,
                                 lParam: sptr_t(bitPattern: UInt(bitPattern: pointer.baseAddress)))
    }
    return String(cString: buffer)
}

private func replaceSelection(_ editor: ScintillaView, _ text: String) {
    text.withCString { cstr in
        _ = ScintillaView.directCall(editor, message: SCI_REPLACESEL, wParam: 0, lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
    }
}

enum MarkdownEditing {
    // MARK: - Continuar listas

    /// Sangría, y después cita ("> "), viñeta ("- ", "* ", "+ ") o número ("3. ", "3) "),
    /// con casilla de tarea opcional ("[ ] ", "[x] ").
    private static let listPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:(>[ \t]?)|([-*+])([ \t]+)(\[[ xX]\][ \t]+)?|(\d{1,9})([.)])([ \t]+)(\[[ xX]\][ \t]+)?)"#
    )

    /// Llamar desde SCN_CHARADDED en documentos Markdown. Con CRLF Scintilla avisa '\r' y
    /// después '\n'; solo se actúa en el último carácter del fin de línea.
    static func charAdded(_ character: Int, editor: ScintillaView) {
        let isCROnly = call(editor, SCI_GETEOLMODE) == 1
        guard character == 0x0A || (character == 0x0D && isCROnly) else { return }
        guard call(editor, SCI_GETSELECTIONS) == 1 else { return }
        let caret = call(editor, SCI_GETCURRENTPOS)
        let line = call(editor, SCI_LINEFROMPOSITION, caret)
        guard line > 0 else { return }
        let previous = line - 1
        let previousStart = call(editor, SCI_POSITIONFROMLINE, previous)
        let style = call(editor, SCI_GETSTYLEAT, previousStart) & 0xFF
        if [SCE_MARKDOWN_CODE, SCE_MARKDOWN_CODE2, SCE_MARKDOWN_CODEBK].contains(style) { return }

        let text = lineText(editor, previous)
        let ns = text as NSString
        guard let match = listPrefix.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }

        let rest = ns.substring(from: match.range.length).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty {
            // Enter sobre un ítem vacío termina la lista: se borra el marcador y el salto
            // recién insertado, y queda una línea vacía donde estaba el ítem.
            _ = call(editor, SCI_DELETERANGE, previousStart, caret - previousStart)
            return
        }

        let indent = group(1) ?? ""
        var prefix: String
        if let quote = group(2) {
            prefix = quote
        } else if let bullet = group(3) {
            prefix = bullet + (group(4) ?? " ") + (group(5) != nil ? "[ ] " : "")
        } else if let number = group(6).flatMap({ Int($0) }) {
            prefix = "\(number + 1)" + (group(7) ?? ".") + (group(8) ?? " ") + (group(9) != nil ? "[ ] " : "")
        } else {
            return
        }
        prefix = indent + prefix
        // Si Enter partió una línea, el resto ya está en la línea nueva: el prefijo va antes.
        let lineStart = call(editor, SCI_POSITIONFROMLINE, line)
        guard caret == lineStart else { return }
        replaceSelection(editor, prefix)
    }

    // MARK: - Casillas de tareas

    private static let taskBox = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]?)*[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+\[([ xX])\]"#)

    /// Marca/desmarca la casilla "[ ]"/"[x]" del ítem en `line` (0-based). Como una edición
    /// normal: se deshace con ⌘Z y la preview se rerenderiza sola.
    static func toggleTask(editor: ScintillaView, line: Int) -> Bool {
        guard line >= 0, line < call(editor, SCI_GETLINECOUNT) else { return false }
        let text = lineText(editor, line)
        let ns = text as NSString
        guard let match = taskBox.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return false }
        let markRange = match.range(at: 1)
        let checked = ns.substring(with: markRange) != " "
        // Posición en bytes: el prefijo es ASCII salvo la sangría, que puede no serlo
        // en teoría; se mide en UTF-8 para no desfasarse.
        let offset = ns.substring(to: markRange.location).utf8.count
        let position = call(editor, SCI_POSITIONFROMLINE, line) + offset
        _ = call(editor, SCI_SETTARGETRANGE, position, position + 1)
        (checked ? " " : "x").withCString { cstr in
            _ = ScintillaView.directCall(editor, message: SCI_REPLACETARGET, wParam: 1,
                                         lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
        }
        return true
    }

    // MARK: - Formatear tabla

    enum Alignment { case none, left, center, right }

    private static let separatorCell = try! NSRegularExpression(pattern: #"^\s*:?-+:?\s*$"#)

    /// Alinea las columnas de la tabla GFM donde está el caret. Devuelve false si el caret
    /// no está en una tabla (encabezado + fila de separadores).
    /// Con `align`, además cambia la alineación de la columna donde está el caret.
    @discardableResult
    static func formatTable(editor: ScintillaView, align: Alignment? = nil) -> Bool {
        let caret = call(editor, SCI_GETCURRENTPOS)
        let caretLine = call(editor, SCI_LINEFROMPOSITION, caret)
        let lineCount = call(editor, SCI_GETLINECOUNT)
        func isTableLine(_ line: Int) -> Bool { lineText(editor, line).contains("|") }
        guard isTableLine(caretLine) else { return false }
        var first = caretLine, last = caretLine
        while first > 0, isTableLine(first - 1) { first -= 1 }
        while last < lineCount - 1, isTableLine(last + 1) { last += 1 }
        guard last > first else { return false }

        var rows = (first...last).map { splitRow(lineText(editor, $0)) }
        let separatorRow = rows[1]
        guard separatorRow.allSatisfy({ isSeparator($0) }) else { return false }
        let columns = rows.map(\.count).max() ?? 0
        for index in rows.indices where rows[index].count < columns {
            rows[index] += Array(repeating: "", count: columns - rows[index].count)
        }
        var alignments: [Alignment] = (0..<columns).map { column in
            let cell = column < separatorRow.count ? separatorRow[column] : ""
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            default: return .none
            }
        }
        if let align {
            // Columna del caret: cuántos "|" sin escapar hay antes, sin contar el del borde.
            let lineStart = call(editor, SCI_POSITIONFROMLINE, caretLine)
            let before = String(decoding: Array(lineText(editor, caretLine).utf8.prefix(caret - lineStart)), as: UTF8.self)
            var pipes = 0
            var escaped = false
            for character in before {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "|" { pipes += 1 }
            }
            if before.trimmingCharacters(in: .whitespaces).hasPrefix("|") { pipes -= 1 }
            alignments[min(max(0, pipes), columns - 1)] = align
        }
        let widths: [Int] = (0..<columns).map { column in
            rows.enumerated().reduce(3) { width, item in
                item.offset == 1 ? width : max(width, item.element[column].count)
            }
        }

        let formatted = rows.enumerated().map { rowIndex, cells in
            let parts = (0..<columns).map { column -> String in
                let width = widths[column]
                if rowIndex == 1 {
                    switch alignments[column] {
                    case .none: return String(repeating: "-", count: width)
                    case .left: return ":" + String(repeating: "-", count: width - 1)
                    case .right: return String(repeating: "-", count: width - 1) + ":"
                    case .center: return ":" + String(repeating: "-", count: width - 2) + ":"
                    }
                }
                return pad(cells[column], to: width, alignment: alignments[column])
            }
            return "| " + parts.joined(separator: " | ") + " |"
        }

        let start = call(editor, SCI_POSITIONFROMLINE, first)
        let end = call(editor, SCI_GETLINEENDPOSITION, last)
        let eol = [0: "\r\n", 1: "\r", 2: "\n"][call(editor, SCI_GETEOLMODE)] ?? "\n"
        let caretColumnLine = caretLine
        _ = call(editor, SCI_SETTARGETRANGE, start, end)
        formatted.joined(separator: eol).withCString { cstr in
            _ = ScintillaView.directCall(editor, message: SCI_REPLACETARGET, wParam: uptr_t(bitPattern: -1),
                                         lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
        }
        // El caret vuelve al principio de la celda de la misma fila (las columnas cambiaron).
        let caretStart = call(editor, SCI_POSITIONFROMLINE, caretColumnLine)
        _ = call(editor, SCI_GOTOPOS, caretStart + 2)
        return true
    }

    /// Celdas de una fila, sin los "|" de los bordes. "\|" es un pipe dentro de la celda.
    private static func splitRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { cells.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") && !cells.isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparator(_ cell: String) -> Bool {
        separatorCell.firstMatch(in: cell, range: NSRange(location: 0, length: (cell as NSString).length)) != nil
    }

    private static func pad(_ text: String, to width: Int, alignment: Alignment) -> String {
        let space = max(0, width - text.count)
        switch alignment {
        case .right: return String(repeating: " ", count: space) + text
        case .center:
            let left = space / 2
            return String(repeating: " ", count: left) + text + String(repeating: " ", count: space - left)
        default: return text + String(repeating: " ", count: space)
        }
    }
}
