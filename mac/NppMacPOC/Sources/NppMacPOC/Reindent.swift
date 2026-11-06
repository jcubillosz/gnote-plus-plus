import Foundation
import Scintilla

// Editar → Espacios en blanco → Reindentar. Lógica pura (sin Scintilla) + aplicación al editor.

/// Niveles de sangría por línea (en pasos, no columnas). nil = no tocar la línea.
/// `skip(line, column)`: el byte UTF-8 de esa columna está en comentario o string.
func indentLevels(lines: [String], skip: (_ line: Int, _ column: Int) -> Bool, family: IndentFamily) -> [Int?] {
    switch family {
    case .cLike: return cLikeLevels(lines: lines, skip: skip)
    case .markup: return markupLevels(lines: lines)
    case .python, .plain: return lines.map { _ in nil }
    }
}

private func isBlankLine(_ s: String) -> Bool { s.utf8.allSatisfy { $0 == 0x20 || $0 == 0x09 } }

/// Límite heurístico aceptado: una línea intermedia de un comentario de bloque o heredoc que
/// empieza en la col. 0 con `#`, `//` o un string cerrado puede juzgarse comentario de línea o
/// string cerrado, y entonces la línea siguiente se reindenta.
/// La línea anterior termina dentro de un comentario de bloque o string aún abierto: el tramo
/// final con estilo comentario/string no es un comentario de línea ni un literal ya cerrado.
private func endsInsideOpenConstruct(_ line: String, skip: (Int) -> Bool) -> Bool {
    let bytes = Array(line.utf8)
    guard let last = bytes.indices.last, skip(last) else { return false }
    var r = last
    while r > 0, skip(r - 1) { r -= 1 }
    if bytes[r] == 0x23 { return false }
    if r + 1 <= last, bytes[r] == 0x2F, bytes[r + 1] == 0x2F { return false }
    if r < last, bytes[r] == bytes[last], bytes[r] == 0x22 || bytes[r] == 0x27 { return false }
    if r < last, bytes[last] == 0x2F, bytes[last - 1] == 0x2A { return false }
    return true
}

private func cLikeLevels(lines: [String], skip: (Int, Int) -> Bool) -> [Int?] {
    var depth = 0
    var result = [Int?](repeating: nil, count: lines.count)
    for (n, line) in lines.enumerated() {
        let bytes = Array(line.utf8)
        let first = bytes.firstIndex(where: { $0 != 0x20 && $0 != 0x09 })
        // Continuación = la línea anterior terminó dentro de un comentario de bloque o string
        // (un comentario de línea nunca continúa; no se puede mirar la col. 0 porque una línea
        // que EMPIEZA con un string también tiene ese estilo ahí).
        var startsInside = false
        if n > 0, skip(n, 0) || first == nil {
            // Las líneas vacías no cierran nada: evaluar la última línea no vacía anterior.
            var p = n - 1
            while p >= 0, lines[p].utf8.isEmpty { p -= 1 }
            if p >= 0 { startsInside = endsInsideOpenConstruct(lines[p], skip: { skip(p, $0) }) }
        }
        if let first, !startsInside {
            var level = depth
            if [0x7D, 0x5D, 0x29].contains(bytes[first]), !skip(n, first) { level -= 1 }
            result[n] = max(0, level)
        }
        for (col, b) in bytes.enumerated() where !skip(n, col) {
            if b == 0x7B || b == 0x5B || b == 0x28 { depth += 1 }
            else if b == 0x7D || b == 0x5D || b == 0x29 { depth = max(0, depth - 1) }
        }
    }
    return result
}

private func markupLevels(lines: [String]) -> [Int?] {
    var result = [Int?](repeating: nil, count: lines.count)
    var depth = 0
    var inComment = false
    var rawTag: String?          // script/style abierto: contenido intacto
    var inTag = false            // dentro de <...> que sigue en la línea siguiente
    var tagIsClosing = false
    var tagName = ""
    var tagNameDone = false
    var quote: Character?
    var lastSlash = false
    for (n, line) in lines.enumerated() {
        let chars = Array(line)
        let startsClean = !inComment && rawTag == nil && !inTag
        if startsClean, let first = chars.firstIndex(where: { $0 != " " && $0 != "\t" }) {
            let closing = IndentRules.hasPrefix(chars, first, "</")
            result[n] = max(0, depth - (closing ? 1 : 0))
        } else if rawTag != nil, let first = chars.firstIndex(where: { $0 != " " && $0 != "\t" }),
                  IndentRules.hasPrefix(chars, first, "</") {
            result[n] = max(0, depth - 1)
        }
        var i = 0
        while i < chars.count {
            if inComment {
                if IndentRules.hasPrefix(chars, i, "-->") { inComment = false; i += 3 } else { i += 1 }
                continue
            }
            if let raw = rawTag {
                if IndentRules.hasPrefix(chars, i, "</"),
                   String(chars[(i + 2)...].prefix(raw.count)).lowercased() == raw {
                    rawTag = nil; depth = max(0, depth - 1)
                    inTag = true; tagIsClosing = true; tagName = raw; tagNameDone = true
                    i += 2 + raw.count
                } else { i += 1 }
                continue
            }
            if inTag {
                let c = chars[i]
                if let q = quote { if c == q { quote = nil } }
                else if c == "\"" || c == "'" { quote = c }
                else if c == ">" {
                    inTag = false
                    if !tagIsClosing, !lastSlash, !tagName.isEmpty, !IndentRules.voidTags.contains(tagName.lowercased()) {
                        depth += 1
                        let lower = tagName.lowercased()
                        if lower == "script" || lower == "style" { rawTag = lower }
                    }
                    lastSlash = false
                } else if !tagNameDone {
                    if c.isLetter || c.isNumber || c == "-" || c == ":" || c == "_" || c == "." { tagName.append(c) }
                    else { tagNameDone = true }
                }
                if c != "/" && c != " " { lastSlash = false }
                if c == "/" { lastSlash = true }
                i += 1
                continue
            }
            guard chars[i] == "<" else { i += 1; continue }
            if IndentRules.hasPrefix(chars, i, "<!--") { inComment = true; i += 4; continue }
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            if next == "!" || next == "?" {
                // DOCTYPE / PI: saltar hasta `>` (sin afectar la profundidad).
                var j = i + 1
                while j < chars.count, chars[j] != ">" { j += 1 }
                i = j + 1
                continue
            }
            if next == "/" {
                depth = max(0, depth - 1)
                var j = i + 2
                while j < chars.count, chars[j] != ">" { j += 1 }
                i = j + 1
                continue
            }
            guard next.isLetter else { i += 1; continue }
            inTag = true; tagIsClosing = false; tagName = ""; tagNameDone = false; quote = nil; lastSlash = false
            i += 1
        }
    }
    return result
}

/// Recalcula la sangría de la selección (o de todo el documento sin selección). false = sin regla.
@discardableResult
func reindent(editor: ScintillaView, family: IndentFamily, lexerName: String) -> Bool {
    guard family == .cLike || family == .markup else { return false }
    func call(_ m: UInt32, _ w: Int = 0, _ l: Int = 0) -> Int {
        Int(ScintillaView.directCall(editor, message: m, wParam: uptr_t(bitPattern: w), lParam: sptr_t(l)))
    }
    _ = call(SCI_COLOURISE, 0, -1)
    let lineCount = call(SCI_GETLINECOUNT)
    let total = call(SCI_GETLENGTH)
    var buffer = [UInt8](repeating: 0, count: total + 1)
    buffer.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        _ = ScintillaView.directCall(editor, message: SCI_GETTEXT, wParam: uptr_t(total + 1),
                                     lParam: sptr_t(bitPattern: UInt(bitPattern: base)))
    }
    var starts: [Int] = []
    var lines: [String] = []
    for n in 0..<lineCount {
        let s = call(SCI_POSITIONFROMLINE, n), e = call(SCI_GETLINEENDPOSITION, n)
        starts.append(s)
        lines.append(String(decoding: buffer[s..<max(s, e)], as: UTF8.self))
    }
    let levels = indentLevels(lines: lines, skip: { line, col in
        let pos = starts[line] + col
        return SpellChecker.isCommentOrStringStyle(call(SCI_GETSTYLEAT, pos), lexerName: lexerName)
    }, family: family)

    let selStart = call(SCI_GETSELECTIONSTART), selEnd = call(SCI_GETSELECTIONEND)
    var from = 0, to = lineCount - 1
    if selEnd > selStart {
        from = call(SCI_LINEFROMPOSITION, selStart)
        to = call(SCI_LINEFROMPOSITION, selEnd)
        if selEnd == call(SCI_POSITIONFROMLINE, to), to > from { to -= 1 }
    }
    var step = call(SCI_GETINDENT)
    if step <= 0 { step = max(1, call(SCI_GETTABWIDTH)) }
    _ = call(SCI_BEGINUNDOACTION)
    for n in from...to {
        guard let level = levels[n] else { continue }
        let columns = level * step
        if call(SCI_GETLINEINDENTATION, n) != columns { _ = call(SCI_SETLINEINDENTATION, n, columns) }
    }
    _ = call(SCI_ENDUNDOACTION)
    return true
}
