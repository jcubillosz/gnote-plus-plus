import Foundation
import Scintilla

/// Resaltado de llaves y de tags XML/HTML pareados, como Notepad++ (brace highlight de
/// Notepad_plus.cpp y xmlMatchedTagsHighlighter.cpp).
enum BraceMatcher {
    /// Llave en el caret o justo antes: la pareja se resalta con STYLE_BRACELIGHT; sin pareja,
    /// STYLE_BRACEBAD. SCI_BRACEMATCH ya ignora llaves de otro estilo (p.ej. dentro de strings
    /// o comentarios si la llave de partida está en código).
    static func updateBraces(editor: ScintillaView) {
        let caret = Int(ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0))
        var bracePosition = -1
        if caret > 0, isBrace(charAt(editor, caret - 1)) {
            bracePosition = caret - 1
        } else if isBrace(charAt(editor, caret)) {
            bracePosition = caret
        }
        guard bracePosition >= 0 else {
            _ = ScintillaView.directCall(editor, message: SCI_BRACEHIGHLIGHT, wParam: uptr_t(bitPattern: -1), lParam: -1)
            return
        }
        let match = Int(ScintillaView.directCall(editor, message: SCI_BRACEMATCH, wParam: uptr_t(bracePosition), lParam: 0))
        if match >= 0 {
            _ = ScintillaView.directCall(editor, message: SCI_BRACEHIGHLIGHT, wParam: uptr_t(bracePosition), lParam: sptr_t(match))
        } else {
            _ = ScintillaView.directCall(editor, message: SCI_BRACEBADLIGHT, wParam: uptr_t(bracePosition), lParam: 0)
        }
    }

    private static func charAt(_ editor: ScintillaView, _ position: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: ScintillaView.directCall(editor, message: SCI_GETCHARAT, wParam: uptr_t(position), lParam: 0))
    }

    private static func isBrace(_ byte: UInt8) -> Bool {
        "()[]{}".utf8.contains(byte)
    }

    // MARK: - Tags XML/HTML

    static func clearTags(editor: ScintillaView) {
        let length = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
        guard length > 0 else { return }
        _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_TAG_MATCH), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_INDICATORCLEARRANGE, wParam: 0, lParam: sptr_t(length))
    }

    /// Si el caret está dentro de un tag de apertura o cierre, marca el nombre de ese tag y el
    /// de su pareja con INDICATOR_TAG_MATCH. Solo para los lexers hypertext/xml y documentos de
    /// hasta 1 MB (recorre el documento entero en cada llamada; ContentView la difiere 150ms).
    static func updateTags(editor: ScintillaView, lexerName: String) {
        clearTags(editor: editor)
        guard lexerName == "hypertext" || lexerName == "xml" else { return }
        let length = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
        guard length > 0, length <= 1_000_000,
              let text = SpellChecker.targetText(editor: editor, start: 0, end: length) else { return }
        let bytes = Array(text.utf8)
        let caret = Int(ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0))

        let tags = scanTags(bytes)
        // Caret pegado al '<' o dentro del tag; si no, justo después del '>' (como Notepad++).
        guard let index = tags.firstIndex(where: { $0.start <= caret && caret < $0.end })
                ?? tags.firstIndex(where: { $0.end == caret }) else { return }
        let tag = tags[index]
        guard !tag.isSelfClosing else { return }

        var depth = 0
        var partner: Tag?
        if tag.isClosing {
            for candidate in tags[..<index].reversed() where candidate.name == tag.name && !candidate.isSelfClosing {
                if candidate.isClosing { depth += 1 } else if depth == 0 { partner = candidate; break } else { depth -= 1 }
            }
        } else {
            for candidate in tags[(index + 1)...] where candidate.name == tag.name && !candidate.isSelfClosing {
                if !candidate.isClosing { depth += 1 } else if depth == 0 { partner = candidate; break } else { depth -= 1 }
            }
        }
        guard let partner else { return }
        _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_TAG_MATCH), lParam: 0)
        for marked in [tag, partner] {
            _ = ScintillaView.directCall(editor, message: SCI_INDICATORFILLRANGE, wParam: uptr_t(marked.nameStart), lParam: sptr_t(marked.nameEnd - marked.nameStart))
        }
    }

    private struct Tag {
        let start: Int       // posición del '<'
        let end: Int         // posición siguiente al '>'
        let nameStart: Int
        let nameEnd: Int
        let name: [UInt8]
        let isClosing: Bool
        let isSelfClosing: Bool
    }

    /// Recorre los bytes (UTF-8, mismas posiciones que Scintilla) y devuelve los tags en orden,
    /// salteando comentarios `<!-- -->`, declaraciones `<!…>`/`<?…?>` y los `>` dentro de
    /// valores de atributo entre comillas. Los nombres se comparan sin distinguir mayúsculas
    /// (HTML).
    private static func scanTags(_ bytes: [UInt8]) -> [Tag] {
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/")
        var tags: [Tag] = []
        var i = 0
        let count = bytes.count
        while i < count {
            guard bytes[i] == lt, i + 1 < count else { i += 1; continue }
            let next = bytes[i + 1]
            if next == UInt8(ascii: "!") {
                if i + 3 < count, bytes[i + 2] == UInt8(ascii: "-"), bytes[i + 3] == UInt8(ascii: "-") {
                    i = indexAfter(sequence: Array("-->".utf8), in: bytes, from: i + 4)
                } else {
                    i = (bytes[(i + 1)...].firstIndex(of: gt) ?? count - 1) + 1
                }
                continue
            }
            if next == UInt8(ascii: "?") {
                i = indexAfter(sequence: Array("?>".utf8), in: bytes, from: i + 2)
                continue
            }
            let isClosing = next == slash
            let nameStart = i + (isClosing ? 2 : 1)
            var nameEnd = nameStart
            while nameEnd < count, isNameByte(bytes[nameEnd]) { nameEnd += 1 }
            guard nameEnd > nameStart else { i += 1; continue }

            var j = nameEnd
            var quote: UInt8?
            while j < count {
                let byte = bytes[j]
                if let q = quote {
                    if byte == q { quote = nil }
                } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                    quote = byte
                } else if byte == gt || byte == lt {
                    break
                }
                j += 1
            }
            guard j < count, bytes[j] == gt else { i = nameEnd; continue }
            let isSelfClosing = !isClosing && j > nameEnd && bytes[j - 1] == slash
            tags.append(Tag(
                start: i, end: j + 1, nameStart: nameStart, nameEnd: nameEnd,
                name: bytes[nameStart..<nameEnd].map { $0 | 0x20 },
                isClosing: isClosing, isSelfClosing: isSelfClosing
            ))
            i = j + 1
        }
        return tags
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ":") || byte == UInt8(ascii: ".")
    }

    private static func indexAfter(sequence: [UInt8], in bytes: [UInt8], from start: Int) -> Int {
        var i = start
        while i + sequence.count <= bytes.count {
            if bytes[i..<(i + sequence.count)].elementsEqual(sequence) { return i + sequence.count }
            i += 1
        }
        return bytes.count
    }
}
