import AppKit
import Foundation
import Scintilla

// Emmet para HTML: un subconjunto (elementos, #id, .clase, [attr], {texto}, > + ^, *N, $, ( ))
// que se expande con Tab o con Editar → Expandir abreviatura.

// MARK: - Lógica pura (sin Scintilla; el script de prueba extrae este tramo)
// PURE-BEGIN

/// Una palabra suelta solo se expande si es uno de estos tags: así Tab tras "hola" o "texto"
/// indenta en vez de producir `<hola></hola>`.
let emmetKnownTags: Set<String> = [
    "a", "abbr", "address", "area", "article", "aside", "audio", "b", "base", "bdi", "bdo",
    "blockquote", "body", "br", "button", "canvas", "caption", "cite", "code", "col", "colgroup",
    "data", "datalist", "dd", "del", "details", "dfn", "dialog", "div", "dl", "dt", "em", "embed",
    "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head",
    "header", "hgroup", "hr", "html", "i", "iframe", "img", "input", "ins", "kbd", "label", "legend",
    "li", "link", "main", "map", "mark", "menu", "meta", "meter", "nav", "noscript", "object", "ol",
    "optgroup", "option", "output", "p", "param", "picture", "pre", "progress", "q", "rp", "rt",
    "ruby", "s", "samp", "script", "search", "section", "select", "slot", "small", "source", "span",
    "strong", "style", "sub", "summary", "sup", "svg", "table", "tbody", "td", "template", "textarea",
    "tfoot", "th", "thead", "time", "title", "tr", "track", "u", "ul", "var", "video", "wbr",
]

/// Elementos vacíos: se escriben sin cierre.
let emmetVoidTags: Set<String> = [
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
    "source", "track", "wbr",
]

/// Atributos que Emmet agrega siempre (vacíos, para que el caret caiga en el primero).
let emmetDefaultAttributes: [String: [(String, String)]] = [
    "a": [("href", "")],
    "img": [("src", ""), ("alt", "")],
    "link": [("rel", "stylesheet"), ("href", "")],
    "input": [("type", "text")],
    "form": [("action", "")],
    "label": [("for", "")],
    "iframe": [("src", "")],
    "script": [],
    "source": [("src", "")],
]

private final class EmmetNode {
    var name: String?
    var id: String?
    var classes: [String] = []
    var attributes: [(name: String, value: String?)] = []
    var text: String?
    var children: [EmmetNode] = []
    var multiplier: Int?
    var isGroup = false

    var isTextOnly: Bool { name == nil && id == nil && classes.isEmpty && attributes.isEmpty && text != nil && !isGroup }
}

private struct EmmetParser {
    let chars: [Character]
    var pos = 0

    init(_ abbreviation: String) { chars = Array(abbreviation) }

    var current: Character? { pos < chars.count ? chars[pos] : nil }

    mutating func parseAbbreviation() -> EmmetNode? {
        let root = EmmetNode()
        root.isGroup = true
        guard parseSequence(into: root), pos == chars.count else { return nil }
        return root
    }

    /// Elementos unidos por `>`, `+` y `^` hasta `)` o el final. La pila guarda el padre al que
    /// se agrega cada elemento: `>` baja al último, `^` sube uno por cada `^`.
    mutating func parseSequence(into container: EmmetNode) -> Bool {
        var stack = [container]
        while true {
            guard let item = parseItem() else { return false }
            stack[stack.count - 1].children.append(item)
            guard let op = current, op != ")" else { return true }
            switch op {
            case ">":
                // Hijos de un grupo o de un texto: Emmet los resuelve de formas poco intuitivas;
                // mejor no expandir.
                guard !item.isGroup, !item.isTextOnly else { return false }
                pos += 1
                stack.append(item)
            case "+":
                pos += 1
            case "^":
                while current == "^" {
                    pos += 1
                    if stack.count > 1 { stack.removeLast() }
                }
            default:
                return false
            }
        }
    }

    mutating func parseItem() -> EmmetNode? {
        guard let first = current else { return nil }
        let node: EmmetNode
        if first == "(" {
            pos += 1
            node = EmmetNode()
            node.isGroup = true
            guard parseSequence(into: node), current == ")" else { return nil }
            pos += 1
        } else {
            guard let element = parseElement() else { return nil }
            node = element
        }
        if current == "*" {
            pos += 1
            var digits = ""
            while let c = current, c.isASCII, c.isNumber { digits.append(c); pos += 1 }
            guard let n = Int(digits), n >= 1, n <= 1000 else { return nil }
            node.multiplier = n
        }
        return node
    }

    mutating func parseElement() -> EmmetNode? {
        let node = EmmetNode()
        var name = ""
        while let c = current, c.isASCII, c.isLetter || c.isNumber || c == "-" || c == ":" || c == "_" {
            name.append(c)
            pos += 1
        }
        if !name.isEmpty {
            guard name.first!.isLetter else { return nil }
            node.name = name
        }
        loop: while let c = current {
            switch c {
            case "#":
                pos += 1
                guard let ident = readIdentifier() else { return nil }
                node.id = ident
            case ".":
                pos += 1
                guard let ident = readIdentifier() else { return nil }
                node.classes.append(ident)
            case "[":
                pos += 1
                guard parseAttributes(into: node) else { return nil }
            case "{":
                pos += 1
                var text = ""
                while let t = current, t != "}" { text.append(t); pos += 1 }
                guard current == "}" else { return nil }
                pos += 1
                node.text = (node.text ?? "") + text
            default:
                break loop
            }
        }
        guard node.name != nil || node.id != nil || !node.classes.isEmpty
                || !node.attributes.isEmpty || node.text != nil else { return nil }
        return node
    }

    mutating func readIdentifier() -> String? {
        var ident = ""
        while let c = current, !c.isWhitespace, !"#.[]{}>+^*()\"'".contains(c) {
            ident.append(c)
            pos += 1
        }
        return ident.isEmpty ? nil : ident
    }

    mutating func parseAttributes(into node: EmmetNode) -> Bool {
        while true {
            while let c = current, c.isWhitespace { pos += 1 }
            guard let c = current else { return false }
            if c == "]" { pos += 1; return true }
            var name = ""
            while let n = current, !n.isWhitespace, n != "=", n != "]", n != "\"", n != "'" {
                name.append(n)
                pos += 1
            }
            guard !name.isEmpty else { return false }
            var value: String?
            if current == "=" {
                pos += 1
                var v = ""
                if let q = current, q == "\"" || q == "'" {
                    pos += 1
                    while let t = current, t != q { v.append(t); pos += 1 }
                    guard current == q else { return false }
                    pos += 1
                } else {
                    while let t = current, !t.isWhitespace, t != "]" { v.append(t); pos += 1 }
                }
                value = v
            }
            node.attributes.append((name, value))
        }
    }
}

private struct EmmetWriter {
    let indent: String
    let eol: String
    var out = ""
    var caret: Int?
    var elementCount = 0
    var invalid = false

    mutating func newLine(_ depth: Int) {
        if !out.isEmpty { out += eol }
        out += String(repeating: indent, count: depth)
    }

    /// Lugar vacío para el caret: el primero en orden de documento.
    mutating func markCaret() {
        if caret == nil { caret = out.utf8.count }
    }

    /// `$`, `$$`, … → el índice con ceros a la izquierda hasta el largo de la tira.
    func numbered(_ s: String, _ index: Int) -> String {
        guard s.contains("$") else { return s }
        var result = ""
        var run = 0
        func flush() {
            if run > 0 {
                let digits = String(index)
                result += String(repeating: "0", count: max(0, run - digits.count)) + digits
                run = 0
            }
        }
        for c in s {
            if c == "$" { run += 1 } else { flush(); result.append(c) }
        }
        flush()
        return result
    }

    func implicitTag(parent: String?) -> String {
        switch parent?.lowercased() {
        case "ul", "ol", "menu": return "li"
        case "table", "tbody", "thead", "tfoot": return "tr"
        case "tr": return "td"
        case "select", "optgroup": return "option"
        default: return "div"
        }
    }

    func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "&quot;")
    }

    mutating func write(_ nodes: [EmmetNode], depth: Int, parent: String?, index: Int) {
        for node in nodes { write(node, depth: depth, parent: parent, index: index) }
    }

    mutating func write(_ node: EmmetNode, depth: Int, parent: String?, index: Int) {
        for repetition in 1...(node.multiplier ?? 1) {
            guard !invalid else { return }
            // Sin `*N` propio, `$` toma el índice del multiplicador más cercano hacia arriba.
            let idx = node.multiplier != nil ? repetition : index
            if node.isGroup {
                write(node.children, depth: depth, parent: parent, index: idx)
                continue
            }
            elementCount += 1
            if elementCount > 5000 { invalid = true; return }
            if node.isTextOnly {
                newLine(depth)
                out += numbered(node.text ?? "", idx)
                continue
            }
            writeElement(node, depth: depth, parent: parent, index: idx)
        }
    }

    mutating func writeElement(_ node: EmmetNode, depth: Int, parent: String?, index: Int) {
        let name = node.name ?? implicitTag(parent: parent)
        var attributes = emmetDefaultAttributes[name.lowercased()] ?? []
        var id = node.id.map { numbered($0, index) }
        var classes = node.classes.map { numbered($0, index) }
        var custom: [(String, String)] = []
        for (attrName, attrValue) in node.attributes {
            let n = numbered(attrName, index)
            let v = numbered(attrValue ?? "", index)
            if n == "class" {
                classes += v.split(separator: " ").map(String.init)
            } else if n == "id" {
                if id == nil { id = v }
            } else if let k = attributes.firstIndex(where: { $0.0 == n }) {
                attributes[k].1 = v
            } else {
                custom.append((n, v))
            }
        }
        if let id { attributes.append(("id", id)) }
        if !classes.isEmpty { attributes.append(("class", classes.joined(separator: " "))) }
        attributes += custom

        newLine(depth)
        out += "<" + name
        for (attrName, value) in attributes {
            out += " \(attrName)=\""
            if value.isEmpty { markCaret() }
            out += escaped(value) + "\""
        }
        out += ">"
        if emmetVoidTags.contains(name.lowercased()) {
            if !node.children.isEmpty || node.text != nil { invalid = true }
            return
        }
        if node.children.isEmpty {
            if let text = node.text { out += numbered(text, index) } else { markCaret() }
        } else {
            if let text = node.text {
                newLine(depth + 1)
                out += numbered(text, index)
            }
            write(node.children, depth: depth + 1, parent: name, index: index)
            newLine(depth)
        }
        out += "</" + name + ">"
    }
}

/// Prosa no expande: "index.html", "Hello.World" o "foo.bar" parsean como tag + clase. Los nombres
/// del nivel superior (también dentro de grupos) deben ser minúscula y un tag HTML conocido o un
/// custom element (con `-`). Los hijos tras `>` no se miran: ese operador ya es intención explícita
/// (`svg>circle`).
private func emmetTopLevelNamesLookLikeTags(_ nodes: [EmmetNode]) -> Bool {
    nodes.allSatisfy { node in
        if node.isGroup { return emmetTopLevelNamesLookLikeTags(node.children) }
        guard let name = node.name else { return true }
        return name == name.lowercased() && (emmetKnownTags.contains(name) || name.contains("-"))
    }
}

/// Expande una abreviatura Emmet. `caretOffset` está en bytes UTF-8 (posiciones de Scintilla)
/// desde el inicio de `text`. nil si no parsea o si es una palabra suelta que no es un tag HTML.
func expandEmmet(_ abbreviation: String, indent: String, eol: String) -> (text: String, caretOffset: Int)? {
    var writer = EmmetWriter(indent: indent, eol: eol)
    if abbreviation == "!" {
        let skeleton: [(Int, String)] = [
            (0, "<!DOCTYPE html>"), (0, "<html lang=\"en\">"), (0, "<head>"),
            (1, "<meta charset=\"UTF-8\">"),
            (1, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">"),
            (1, "<title>Document</title>"), (0, "</head>"), (0, "<body>"),
        ]
        for (depth, line) in skeleton { writer.newLine(depth); writer.out += line }
        writer.newLine(1)
        writer.markCaret()
        writer.newLine(0); writer.out += "</body>"
        writer.newLine(0); writer.out += "</html>"
        return (writer.out, writer.caret ?? 0)
    }
    var parser = EmmetParser(abbreviation)
    guard let root = parser.parseAbbreviation() else { return nil }
    guard emmetTopLevelNamesLookLikeTags(root.children) else { return nil }
    writer.write(root.children, depth: 0, parent: nil, index: 1)
    guard !writer.invalid, !writer.out.isEmpty else { return nil }
    return (writer.out, writer.caret ?? writer.out.utf8.count)
}

/// Abreviatura que termina al final de `line` (el texto de la línea hasta el caret): hacia atrás
/// hasta un espacio, el inicio o el `>` de un tag; los espacios dentro de `[…]` y `{…}` cuentan.
/// nil si corta en otro carácter (`<div`, `"x`): ahí no hay una abreviatura sino otra cosa.
func emmetAbbreviation(beforeCaretIn line: String) -> String? {
    let chars = Array(line)
    // `>` de cierre de un tag (`<p>`) y no el operador hijo: hay un `<` antes sin otro `>` en medio.
    func isTagEnd(_ gt: Int) -> Bool {
        var k = gt - 1
        while k >= 0 {
            if chars[k] == ">" { return false }
            if chars[k] == "<" {
                guard k + 1 < gt else { return false }
                let next = chars[k + 1]
                return (next.isASCII && next.isLetter) || next == "/" || next == "!" || next == "?"
            }
            k -= 1
        }
        return false
    }
    var i = chars.count
    var brace = 0, bracket = 0
    var quote: Character?
    var stoppedOnBoundary = true
    while i > 0 {
        let c = chars[i - 1]
        if brace > 0 {
            if c == "{" { brace -= 1 } else if c == "}" { brace += 1 }
        } else if bracket > 0 {
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "[" {
                bracket -= 1
            } else if c == "]" {
                bracket += 1
            }
        } else if c == "}" {
            brace = 1
        } else if c == "]" {
            bracket = 1
        } else if c == ">" {
            if isTagEnd(i - 1) { break }
        } else if c.isWhitespace {
            break
        } else if !((c.isASCII && (c.isLetter || c.isNumber)) || "#.-_:$*+^()!@".contains(c)) {
            stoppedOnBoundary = false
            break
        }
        i -= 1
    }
    guard stoppedOnBoundary, brace == 0, bracket == 0, i < chars.count else { return nil }
    return String(chars[i...])
}

/// Agrega la indentación de la línea actual (`base`) tras cada salto de `text`, corriendo el
/// caret (bytes UTF-8). Por bytes y no por Character: "\r\n" es un solo Character en Swift.
func emmetIndentContinuation(_ text: String, caretOffset: Int, base: String, eol: String) -> (text: String, caretOffset: Int) {
    guard !base.isEmpty else { return (text, caretOffset) }
    let bytes = Array(text.utf8), eolBytes = Array(eol.utf8), baseBytes = Array(base.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var caret = caretOffset
    var i = 0
    while i < bytes.count {
        if !eolBytes.isEmpty, i + eolBytes.count <= bytes.count,
           bytes[i..<(i + eolBytes.count)].elementsEqual(eolBytes) {
            out += eolBytes
            out += baseBytes
            if i + eolBytes.count <= caretOffset { caret += baseBytes.count }
            i += eolBytes.count
        } else {
            out.append(bytes[i])
            i += 1
        }
    }
    return (String(decoding: out, as: UTF8.self), caret)
}

/// El lexer hypertext no estiliza el CSS de `<style>` (queda como texto, SCE_H_DEFAULT): se
/// decide por el último `<style…>` o `</style>` antes del caret, mirando hacia atrás.
func isInsideStyleBlock(_ textBeforeCaret: String) -> Bool {
    let bytes = Array(textBeforeCaret.utf8)
    var k = bytes.count - 1
    while k >= 0 {
        switch styleTagBoundary(bytes, at: k) {
        case .close, .incomplete: return false
        case .open: return true
        case nil: k -= 1
        }
    }
    return false
}

enum StyleTagBoundary { case open, close, incomplete }

/// ¿Empieza en `bytes[k]` un `<style…` (seguido de `>`, blanco o `/`) o un `</style`? Sin
/// distinguir mayúsculas. `.incomplete` = `<style` justo al final del texto (a medio escribir).
/// Compartido con los colores CSS (CSSColors.swift), que recorren el HTML hacia adelante.
func styleTagBoundary(_ bytes: [UInt8], at k: Int) -> StyleTagBoundary? {
    guard bytes[k] == UInt8(ascii: "<") else { return nil }
    func matches(_ seq: StaticString, at start: Int) -> Bool {
        let count = seq.utf8CodeUnitCount
        guard start + count <= bytes.count else { return false }
        let p = seq.utf8Start
        for j in 0..<count {
            var b = bytes[start + j]
            if b >= 0x41 && b <= 0x5A { b += 0x20 }
            if b != p[j] { return false }
        }
        return true
    }
    if matches("</style", at: k) { return .close }
    guard matches("<style", at: k) else { return nil }
    let after = k + 6
    if after == bytes.count { return .incomplete }
    let b = bytes[after]
    if b == UInt8(ascii: ">") || b == UInt8(ascii: " ") || b == UInt8(ascii: "\t")
        || b == UInt8(ascii: "\n") || b == UInt8(ascii: "\r") || b == UInt8(ascii: "/") {
        return .open
    }
    return nil
}
// PURE-END

// MARK: - Integración con Scintilla

/// Expande la abreviatura que termina en el caret, en una sola acción de deshacer. false si no
/// hay nada que expandir (entonces Tab sigue normal; ⌘E da beep). `isAllowedHere` se consulta
/// recién cuando hay una expansión posible: Tab en una línea vacía o tras "hola" no paga el
/// estilizado ni la búsqueda de `<style>`.
@discardableResult
func expandEmmetAtCaret(editor: ScintillaView, isAllowedHere: (() -> Bool)? = nil) -> Bool {
    func call(_ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
        Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
    }
    guard call(SCI_GETSELECTIONS) == 1, call(SCI_GETSELECTIONEMPTY) != 0 else { return false }
    let caret = call(SCI_GETCURRENTPOS)
    let lineStart = call(SCI_POSITIONFROMLINE, call(SCI_LINEFROMPOSITION, caret))
    guard caret > lineStart,
          let prefix = SpellChecker.targetText(editor: editor, start: lineStart, end: caret),
          prefix.utf8.count == caret - lineStart,
          let abbreviation = emmetAbbreviation(beforeCaretIn: prefix) else { return false }
    // SCI_GETUSETABS/GETTABWIDTH son las preferencias (EditorPreferences.applyEditingOptions);
    // GETINDENT por si algún día difiere del ancho de tab, como en Reindent.
    let width = call(SCI_GETINDENT) > 0 ? call(SCI_GETINDENT) : max(1, call(SCI_GETTABWIDTH))
    let unit = call(SCI_GETUSETABS) != 0 ? "\t" : String(repeating: " ", count: width)
    let eol = [0: "\r\n", 1: "\r", 2: "\n"][call(SCI_GETEOLMODE)] ?? "\n"
    guard let expansion = expandEmmet(abbreviation, indent: unit, eol: eol),
          isAllowedHere?() ?? true else { return false }
    let base = String(prefix.prefix(while: { $0 == " " || $0 == "\t" }))
    let (text, offset) = emmetIndentContinuation(expansion.text, caretOffset: expansion.caretOffset, base: base, eol: eol)
    let start = caret - abbreviation.utf8.count
    _ = call(SCI_BEGINUNDOACTION)
    _ = call(SCI_SETTARGETRANGE, start, caret)
    text.withCString { cstr in
        _ = call(SCI_REPLACETARGET, text.utf8.count, Int(bitPattern: UInt(bitPattern: cstr)))
    }
    _ = call(SCI_GOTOPOS, start + offset)
    _ = call(SCI_ENDUNDOACTION)
    return true
}

enum EmmetTabTrigger {
    /// Tab en HTML, llamado por TabKeyRouter (que ya verificó foco, marked text y autocompletado).
    /// Sin abreviatura devuelve false y el Tab sigue a Scintilla.
    static func tryExpand(tabs: TabsViewModel) -> Bool {
        guard let document = tabs.activeDocument, !document.isLocked,
              document.languageProfile.lexerName == "hypertext" else { return false }
        return expandEmmetAtCaret(editor: tabs.editor, isAllowedHere: { caretIsInHTMLText(editor: tabs.editor) })
    }

    /// Fuera de JS/PHP embebido (estilos >= 40), strings, comentarios y del interior de un tag:
    /// solo texto HTML (SCE_H_DEFAULT = 0) que no esté dentro de `<style>`.
    private static func caretIsInHTMLText(editor: ScintillaView) -> Bool {
        func call(_ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
            Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
        }
        let caret = call(SCI_GETCURRENTPOS)
        guard caret > 0 else { return false }
        ensureStyled(editor: editor, upTo: caret)
        guard call(SCI_GETSTYLEAT, caret - 1) == 0 else { return false }
        return !styleBlockIsOpen(before: caret, editor: editor)
    }
}
