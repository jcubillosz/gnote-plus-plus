import Foundation
import Scintilla

// Indentación automática al escribir, inspirada en el modo avanzado de Notepad++
// (Notepad_plus::maintainIndentation). Se llama desde SCN_CHARADDED.

enum IndentFamily {
    case cLike, python, markup, plain

    init(lexerName: String) {
        switch lexerName {
        case "cpp", "css", "json", "rust", "perl", "powershell": self = .cLike
        case "python": self = .python
        case "hypertext", "xml": self = .markup
        default: self = .plain
        }
    }
}

// MARK: - Puro (sin dependencia de Scintilla)

enum IndentRules {
    static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input",
                                        "link", "meta", "source", "track", "wbr"]

    /// Nombre del tag de apertura que deja abierto un bloque si `line` termina justo en él
    /// (ignorando espacios finales): `<div>` sí, `<br>`, `<a/>`, `</div>`, `<!-- x -->` no.
    /// Respeta comillas dentro del tag (`<p class="a>b">`).
    static func openingTagName(endingLine line: String) -> String? {
        let chars = Array(line)
        var last: (name: String, isOpening: Bool, end: Int)?
        var i = 0
        while i < chars.count {
            guard chars[i] == "<" else { i += 1; continue }
            if hasPrefix(chars, i, "<!--") {
                var j = i + 4
                var closed = false
                while j + 2 < chars.count {
                    if chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">" { closed = true; break }
                    j += 1
                }
                guard closed else { return nil }
                last = ("", false, j + 3)
                i = j + 3
                continue
            }
            // Fin del tag respetando comillas.
            var j = i + 1
            var quote: Character?
            var end: Int?
            while j < chars.count {
                let c = chars[j]
                if let q = quote { if c == q { quote = nil } }
                else if c == "\"" || c == "'" { quote = c }
                else if c == ">" { end = j; break }
                j += 1
            }
            guard let tagEnd = end else { return nil }
            // `x < y <div>`: el primer `<` no es un tag; reiniciar desde el `<` interno.
            if let inner = chars[(i + 1)..<tagEnd].lastIndex(of: "<") {
                i = inner
                continue
            }
            let inner = chars[(i + 1)..<tagEnd]
            let first = inner.first
            if first == "!" || first == "?" || first == "/" {
                last = ("", false, tagEnd + 1)
            } else if inner.last == "/" {
                last = ("", false, tagEnd + 1)
            } else {
                var name = ""
                for c in inner {
                    if c.isLetter || c.isNumber || c == "-" || c == ":" || c == "_" || c == "." { name.append(c) }
                    else { break }
                }
                last = (name, !name.isEmpty && !voidTags.contains(name.lowercased()), tagEnd + 1)
            }
            i = tagEnd + 1
        }
        guard let last, last.isOpening else { return nil }
        let tail = chars[last.end...]
        guard tail.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        return last.name
    }

    static func hasPrefix(_ chars: [Character], _ index: Int, _ prefix: String) -> Bool {
        let p = Array(prefix)
        guard index + p.count <= chars.count else { return false }
        return Array(chars[index..<(index + p.count)]) == p
    }

    /// Último carácter no blanco de la línea.
    static func lastNonBlank(_ line: String) -> Character? {
        line.last(where: { $0 != " " && $0 != "\t" })
    }

    /// `text` empieza (tras espacios) con el cierre `</name`.
    static func startsWithClosing(_ text: String, name: String) -> Bool {
        let trimmed = text.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.hasPrefix("</") else { return false }
        let rest = trimmed.dropFirst(2)
        return rest.lowercased().hasPrefix(name.lowercased())
    }
}

// MARK: - Scintilla

enum AutoIndent {
    private static func call(_ editor: ScintillaView, _ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
        Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
    }

    private static func lineText(_ editor: ScintillaView, _ line: Int) -> String {
        let start = call(editor, SCI_POSITIONFROMLINE, line)
        let end = call(editor, SCI_GETLINEENDPOSITION, line)
        return text(editor, start, end)
    }

    private static func text(_ editor: ScintillaView, _ start: Int, _ end: Int) -> String {
        guard start >= 0, end > start else { return "" }
        _ = call(editor, SCI_SETTARGETSTART, start)
        _ = call(editor, SCI_SETTARGETEND, end)
        var buffer = [CChar](repeating: 0, count: end - start + 1)
        _ = buffer.withUnsafeMutableBufferPointer { ptr in
            ScintillaView.directCall(editor, message: SCI_GETTARGETTEXT, wParam: 0,
                                     lParam: sptr_t(bitPattern: UInt(bitPattern: ptr.baseAddress)))
        }
        return String(cString: buffer)
    }

    private static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    static func charAdded(_ character: Int, editor: ScintillaView, lexerName: String, tabWidth: Int) {
        guard call(editor, SCI_GETSELECTIONS) == 1 else { return }
        let family = IndentFamily(lexerName: lexerName)
        let eolMode = call(editor, SCI_GETEOLMODE) // 0 CRLF, 1 CR, 2 LF
        if character == 0x0A && eolMode != 1 || character == 0x0D && eolMode == 1 {
            enter(editor, family: family, eolMode: eolMode, step: tabWidth)
        } else if family == .cLike, character == 0x7D || character == 0x5D || character == 0x29 {
            closer(editor)
        }
    }

    private static func setIndent(_ editor: ScintillaView, line: Int, _ columns: Int) {
        _ = call(editor, SCI_SETLINEINDENTATION, line, max(0, columns))
    }

    private static func enter(_ editor: ScintillaView, family: IndentFamily, eolMode: Int, step: Int) {
        let caret = call(editor, SCI_GETCURRENTPOS)
        let line = call(editor, SCI_LINEFROMPOSITION, caret)
        guard line > 0, caret == call(editor, SCI_POSITIONFROMLINE, line) else { return }
        let previous = line - 1
        let previousText = lineText(editor, previous)

        // Última línea no vacía anterior como base (la línea inmediata si tiene contenido).
        var base = previous
        while base > 0, isBlank(lineText(editor, base)) { base -= 1 }
        let baseIndent = call(editor, SCI_GETLINEINDENTATION, base)
        let previousIndent = call(editor, SCI_GETLINEINDENTATION, previous)

        // Cuántos niveles extra y si hay un par que partir entre líneas.
        var extra = 0
        var splitCloser: Character?
        let next = call(editor, SCI_GETCHARAT, caret)
        if !isBlank(previousText) {
            switch family {
            case .cLike:
                if let last = IndentRules.lastNonBlank(previousText), "{[(".contains(last) {
                    extra = 1
                    let closers: [Character: Int] = ["{": 0x7D, "[": 0x5D, "(": 0x29]
                    if closers[last] == next { splitCloser = last }
                }
            case .python:
                if IndentRules.lastNonBlank(previousText) == ":" { extra = 1 }
            case .markup:
                if let name = IndentRules.openingTagName(endingLine: previousText) {
                    extra = 1
                    let end = call(editor, SCI_GETLINEENDPOSITION, line)
                    if next == 0x3C,
                       IndentRules.startsWithClosing(text(editor, caret, end), name: name) { splitCloser = "<" }
                }
            case .plain: break
            }
        }

        let target = (isBlank(previousText) ? baseIndent : previousIndent) + extra * step
        guard target > 0 || splitCloser != nil else { return }
        // Enter y la sangría son dos pasos de deshacer: SCN_CHARADDED llega después de insertar el
        // salto de línea (igual que Notepad++); este grupo cubre solo la sangría.
        _ = call(editor, SCI_BEGINUNDOACTION)
        defer { _ = call(editor, SCI_ENDUNDOACTION) }
        if splitCloser != nil {
            // El cierre baja a su propia línea con la sangría de la línea de apertura.
            let eol = eolMode == 0 ? "\r\n" : (eolMode == 1 ? "\r" : "\n")
            eol.withCString { cstr in
                _ = ScintillaView.directCall(editor, message: SCI_INSERTTEXT, wParam: uptr_t(caret),
                                             lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
            }
            setIndent(editor, line: line + 1, previousIndent)
        }
        setIndent(editor, line: line, target)
        _ = call(editor, SCI_GOTOPOS, call(editor, SCI_GETLINEINDENTPOSITION, line))
    }

    /// `}`, `]` o `)` como primer carácter no blanco: la línea toma la sangría de la de su pareja.
    private static func closer(_ editor: ScintillaView) {
        let caret = call(editor, SCI_GETCURRENTPOS)
        let line = call(editor, SCI_LINEFROMPOSITION, caret)
        let lineStart = call(editor, SCI_POSITIONFROMLINE, line)
        guard caret - 1 >= lineStart, isBlank(text(editor, lineStart, caret - 1)) else { return }
        let match = call(editor, SCI_BRACEMATCH, caret - 1)
        guard match >= 0 else { return }
        let matchLine = call(editor, SCI_LINEFROMPOSITION, match)
        guard matchLine != line else { return }
        let wanted = call(editor, SCI_GETLINEINDENTATION, matchLine)
        guard wanted != call(editor, SCI_GETLINEINDENTATION, line) else { return }
        let fromEnd = call(editor, SCI_GETLINEENDPOSITION, line) - caret
        setIndent(editor, line: line, wanted)
        _ = call(editor, SCI_GOTOPOS, call(editor, SCI_GETLINEENDPOSITION, line) - fromEnd)
    }
}
