import AppKit
import Foundation
import Scintilla

// MARK: - Lógica pura (sin Scintilla; el script de prueba extrae este tramo)
// PURE-BEGIN

let htmlVoidElements: Set<String> = [
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
    "source", "track", "wbr",
]

/// `bytes` es el texto hasta el caret, que acaba de recibir un `>`. Devuelve el nombre del tag
/// si ese `>` cierra una apertura válida. Recorre hacia adelante (no hacia atrás desde el `>`)
/// porque solo así se sabe si un `>` está dentro de comillas de atributo o de un comentario.
func openingTagNameBeforeCaret(_ bytes: [UInt8], caret: Int) -> String? {
    let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">")
    guard caret > 0, caret <= bytes.count, bytes[caret - 1] == gt else { return nil }
    func isNameByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || b == UInt8(ascii: "-") || b == UInt8(ascii: "_") || b == UInt8(ascii: ":") || b == UInt8(ascii: ".")
    }
    func indexAfter(_ seq: [UInt8], from start: Int) -> Int? {
        var k = start
        while k + seq.count <= caret {
            if bytes[k..<(k + seq.count)].elementsEqual(seq) { return k + seq.count }
            k += 1
        }
        return nil
    }
    var i = 0
    while i < caret {
        guard bytes[i] == lt, i + 1 < caret else { i += 1; continue }
        let next = bytes[i + 1]
        if next == UInt8(ascii: "!") {
            let isComment = i + 3 < caret && bytes[i + 2] == UInt8(ascii: "-") && bytes[i + 3] == UInt8(ascii: "-")
            guard let end = isComment ? indexAfter(Array("-->".utf8), from: i + 4)
                                      : indexAfter([gt], from: i + 2) else { return nil }
            if end == caret { return nil }
            i = end
            continue
        }
        if next == UInt8(ascii: "?") {
            guard let end = indexAfter(Array("?>".utf8), from: i + 2) else { return nil }
            if end == caret { return nil }
            i = end
            continue
        }
        if next == UInt8(ascii: "/") { i += 2; continue }
        let nameStart = i + 1
        var nameEnd = nameStart
        while nameEnd < caret, isNameByte(bytes[nameEnd]) { nameEnd += 1 }
        guard nameEnd > nameStart else { i += 1; continue }
        var j = nameEnd
        var quote: UInt8?
        var closed = false
        while j < caret {
            let b = bytes[j]
            if let q = quote {
                if b == q { quote = nil }
            } else if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
                quote = b
            } else if b == gt {
                closed = true
                break
            } else if b == lt {
                break
            }
            j += 1
        }
        guard closed else {
            if j < caret { i = j; continue }   // otro '<' sin cerrar: reintentar desde ahí
            return nil
        }
        if j == caret - 1 {
            if bytes[j - 1] == UInt8(ascii: "/") { return nil }
            return String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
        }
        i = j + 1
    }
    return nil
}

/// Nombre del tag de cierre `</nombre>` que termina justo en el caret (el último `>` tecleado),
/// buscando solo dentro de la línea; nil si no hay uno.
func closingTagNameEndingAtCaret(_ bytes: [UInt8], caret: Int) -> String? {
    let gt = UInt8(ascii: ">"), lt = UInt8(ascii: "<"), slash = UInt8(ascii: "/")
    guard caret > 1, caret <= bytes.count, bytes[caret - 1] == gt else { return nil }
    // Hasta el índice 0 inclusive: autoCloseTag pasa una ventana que empieza en la línea del
    // último `<`, así que un `</div>` en columna 0 tiene su `<` en el 0.
    var k = caret - 2
    while k >= 0 {
        let b = bytes[k]
        if b == lt || b == 0x0A || b == 0x0D || b == gt { break }
        k -= 1
    }
    guard k >= 0, bytes[k] == lt, bytes[k + 1] == slash, k + 2 < caret - 1 else { return nil }
    let name = bytes[(k + 2)..<(caret - 1)]
    for b in name where !((b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                          || b == UInt8(ascii: "-") || b == UInt8(ascii: "_") || b == UInt8(ascii: ":") || b == UInt8(ascii: ".")) {
        return nil
    }
    return String(decoding: name, as: UTF8.self)
}
// PURE-END

extension TabsViewModel {
    private func tagCall(_ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
        Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
    }

    /// Tras escribir `>` de una apertura, inserta `</nombre>` sin mover el caret y lo marca con el
    /// indicador 13 para que teclear `</nombre>` encima lo pise (ver el sobretipeo más abajo).
    func autoCloseTag(character: Int, lexerName: String) {
        guard character == Int(UInt8(ascii: ">")),
              lexerName == "hypertext" || lexerName == "xml",
              tagCall(SCI_GETSELECTIONS) == 1 else { return }
        let caret = tagCall(SCI_GETCURRENTPOS)
        guard caret > 0 else { return }
        // Ventana hacia atrás y no el prefijo entero (copiado en cada `>`): desde el inicio de la
        // línea del último `<`, tope 64 KB. Un comentario o string de varias líneas que empieza
        // antes queda fuera de la ventana, pero eso lo descarta el estilo del lexer de abajo.
        let windowStart = max(0, caret - Self.autoCloseWindow)
        let window = rawBytes(from: windowStart, to: caret)
        guard window.count == caret - windowStart else { return }
        var scanStart = windowStart
        if let lastLT = window.lastIndex(of: UInt8(ascii: "<")) {
            let line = tagCall(SCI_LINEFROMPOSITION, windowStart + lastLT)
            scanStart = max(windowStart, tagCall(SCI_POSITIONFROMLINE, line))
        }
        let bytes = Array(window[(scanStart - windowStart)...])
        let localCaret = bytes.count
        // Sobretipeo: el `>` de un `</nombre>` tecleado a mano pisa el cierre autoinsertado
        // (todo marcado con el indicador 13) que sigue al caret; uno escrito por el usuario no
        // tiene marca, así que `<div><div>x</div>|</div>` no pierde el cierre externo.
        if let closeName = closingTagNameEndingAtCaret(bytes, caret: localCaret) {
            let expected = "</\(closeName)>"
            let size = expected.utf8.count
            if caret + size <= tagCall(SCI_GETLENGTH),
               SpellChecker.targetText(editor: editor, start: caret, end: caret + size) == expected,
               (0..<size).allSatisfy({ tagCall(SCI_INDICATORVALUEAT, INDICATOR_AUTO_CLOSE, caret + $0) != 0 }) {
                _ = tagCall(SCI_DELETERANGE, caret, size)
            }
            return
        }
        guard let name = openingTagNameBeforeCaret(bytes, caret: localCaret) else { return }
        // `if (a<b && c>d)` dentro de <script>/PHP/comentarios no es una apertura: se mira el
        // estilo del `>` (SCE_H_TAG/TAGEND son 1-2/11; los de script empiezan en 40). XML usa el
        // mismo lexer (LexHTML) y con la ventana también necesita descartar comentarios/CDATA.
        ensureStyled(editor: editor, upTo: caret)
        let style = tagCall(SCI_GETSTYLEAT, caret - 1)
        if style >= 40 || [6, 7, 9, 14, 17, 19, 20].contains(style) { return }
        if lexerName == "hypertext", htmlVoidElements.contains(name.lowercased()) { return }
        let closing = "</\(name)>"
        let length = tagCall(SCI_GETLENGTH)
        if let after = SpellChecker.targetText(editor: editor, start: caret, end: min(length, caret + closing.utf8.count)),
           after == closing { return }
        closing.withCString { cstr in
            _ = tagCall(SCI_INSERTTEXT, caret, Int(bitPattern: UInt(bitPattern: cstr)))
        }
        let previous = tagCall(SCI_GETINDICATORCURRENT)
        _ = tagCall(SCI_SETINDICATORCURRENT, INDICATOR_AUTO_CLOSE)
        _ = tagCall(SCI_SETINDICATORVALUE, 1)
        _ = tagCall(SCI_INDICATORFILLRANGE, caret, closing.utf8.count)
        _ = tagCall(SCI_SETINDICATORCURRENT, previous)
    }

    private static let autoCloseWindow = 64 * 1024

    /// Bytes crudos (no String): el inicio de la ventana puede caer a mitad de un carácter UTF-8.
    private func rawBytes(from start: Int, to end: Int) -> [UInt8] {
        guard end > start else { return [] }
        _ = tagCall(SCI_SETTARGETRANGE, start, end)
        var buffer = [UInt8](repeating: 0, count: end - start + 1)
        let length = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return tagCall(SCI_GETTARGETTEXT, 0, Int(bitPattern: UInt(bitPattern: base)))
        }
        return Array(buffer.prefix(min(length, end - start)))
    }

    /// Selecciona el nombre del tag bajo el caret y el de su pareja (multi-selección) para
    /// editar ambos a la vez.
    func renameTag() {
        guard let document = activeDocument, !document.isLocked,
              let (first, second) = BraceMatcher.matchingTagNames(editor: editor, lexerName: document.languageProfile.lexerName)
        else { NSSound.beep(); return }
        _ = tagCall(UInt32(SCI_SETSELECTION), first.upperBound, first.lowerBound)
        _ = tagCall(SCI_ADDSELECTION, second.upperBound, second.lowerBound)
    }
}
