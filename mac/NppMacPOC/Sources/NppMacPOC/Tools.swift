// Herramientas del menú Herramientas: resumen del documento, hashes MD5/SHA-1/SHA-256
// (CryptoKit) y Base64. Actúan sobre la selección principal o, sin selección, el documento.
import AppKit
import CryptoKit
import Scintilla

struct TextSummary {
    let lines: Int
    let words: Int
    let characters: Int
    let charactersWithoutSpaces: Int
    let utf8Bytes: Int

    init(_ text: String) {
        // Mismo criterio que Scintilla: texto vacío = 1 línea; "\r\n" cuenta como un solo salto.
        var count = 1
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if !previousWasCR { count += 1 }
                previousWasCR = false
            } else if scalar == "\r" {
                count += 1
                previousWasCR = true
            } else {
                previousWasCR = false
            }
        }
        lines = count
        words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        characters = text.count
        charactersWithoutSpaces = text.filter { !$0.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) }.count
        utf8Bytes = text.utf8.count
    }
}

enum HashKind {
    case md5, sha1, sha256

    var title: String {
        switch self {
        case .md5: return L("MD5")
        case .sha1: return L("SHA-1")
        case .sha256: return L("SHA-256")
        }
    }
}

func hexDigest(_ kind: HashKind, of text: String) -> String {
    let data = Data(text.utf8)
    func hex<D: Digest>(_ digest: D) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    switch kind {
    case .md5: return hex(Insecure.MD5.hash(data: data))
    case .sha1: return hex(Insecure.SHA1.hash(data: data))
    case .sha256: return hex(SHA256.hash(data: data))
    }
}

func base64Encode(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
}

func base64Decode(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func selectionRange(_ editor: ScintillaView) -> (start: Int, end: Int) {
    let start = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0))
    let end = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0))
    return (start, end)
}

private func selectedText(_ editor: ScintillaView) -> String? {
    let (start, end) = selectionRange(editor)
    guard end > start else { return nil }
    return SpellChecker.targetText(editor: editor, start: start, end: end)
}

func showDocumentSummary(editor: ScintillaView) {
    func block(_ s: TextSummary) -> String {
        [
            L("Líneas: \(s.lines)"),
            L("Palabras: \(s.words)"),
            L("Caracteres: \(s.characters)"),
            L("Caracteres sin espacios: \(s.charactersWithoutSpaces)"),
            L("Bytes (UTF-8): \(s.utf8Bytes)"),
        ].joined(separator: "\n")
    }
    var detail = L("Documento") + "\n" + block(TextSummary(currentText(editor)))
    if let selection = selectedText(editor) {
        detail += "\n\n" + L("Selección") + "\n" + block(TextSummary(selection))
    }
    presentAlert(L("Resumen"), detail: detail)
}

func showHash(_ kind: HashKind, editor: ScintillaView) {
    let text = selectedText(editor) ?? currentText(editor)
    let digest = hexDigest(kind, of: text)
    let alert = NSAlert()
    alert.messageText = kind.title
    alert.informativeText = digest
    alert.addButton(withTitle: L("Copiar"))
    alert.addButton(withTitle: L("OK"))
    if alert.runModal() == .alertFirstButtonReturn {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(digest, forType: .string)
    }
}

func base64Transform(editor: ScintillaView, encode: Bool) {
    let (start, end) = selectionRange(editor)
    guard let text = selectedText(editor) else { NSSound.beep(); return }
    let result: String
    if encode {
        result = base64Encode(text)
    } else if let decoded = base64Decode(text) {
        result = decoded
    } else {
        presentAlert(L("Base64"), detail: L("El texto seleccionado no es Base64 válido en UTF-8."))
        return
    }
    replaceRange(editor: editor, start: start, end: end, with: result, reselect: true)
}

// MARK: - JSON / XML

private func validateJSON(_ text: String) throws {
    do {
        _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    } catch {
        let ns = error as NSError
        let detail = (ns.userInfo["NSDebugDescription"] as? String) ?? ns.localizedDescription
        throw NSError(domain: "JSON", code: 2, userInfo: [NSLocalizedDescriptionKey: L("JSON no válido") + ": " + detail])
    }
    // JSONSerialization de macOS tolera comas finales; el JSON estricto no.
    var inString = false, escaped = false, pendingComma = false
    for c in text.unicodeScalars {
        if inString {
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            continue
        }
        if " \t\n\r".unicodeScalars.contains(c) { continue }
        if pendingComma, c == "}" || c == "]" {
            throw NSError(domain: "JSON", code: 1, userInfo: [NSLocalizedDescriptionKey: L("JSON no válido: coma final.")])
        }
        pendingComma = c == ","
        if c == "\"" { inString = true }
    }
}

/// Recorre los caracteres (no re-serializa) para conservar orden de claves, números y escapes tal cual.
private func rewriteJSON(_ text: String, indent: String?) -> String {
    var out = ""
    var depth = 0
    var inString = false
    var escaped = false
    let chars = Array(text.unicodeScalars)
    func newline() { if let indent { out += "\n" + String(repeating: indent, count: depth) } }
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if inString {
            out.unicodeScalars.append(c)
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
        } else {
            switch c {
            case "\"": inString = true; out.unicodeScalars.append(c)
            case " ", "\t", "\n", "\r": break
            case "{", "[":
                out.unicodeScalars.append(c)
                var j = i + 1
                while j < chars.count, " \t\n\r".unicodeScalars.contains(chars[j]) { j += 1 }
                if j < chars.count, (c == "{" && chars[j] == "}") || (c == "[" && chars[j] == "]") {
                    out.unicodeScalars.append(chars[j]); i = j
                } else {
                    depth += 1; newline()
                }
            case "}", "]": depth -= 1; newline(); out.unicodeScalars.append(c)
            case ",": out += ","; newline()
            case ":": out += indent == nil ? ":" : ": "
            default: out.unicodeScalars.append(c)
            }
        }
        i += 1
    }
    return out
}

func formatJSON(_ text: String, indent: String) throws -> String {
    try validateJSON(text)
    return rewriteJSON(text, indent: indent)
}

func minifyJSON(_ text: String) throws -> String {
    try validateJSON(text)
    return rewriteJSON(text, indent: nil)
}

private func hasMixedContent(_ node: XMLNode) -> Bool {
    guard let children = node.children else { return false }
    let hasElement = children.contains { $0.kind == .element }
    let hasText = children.contains { $0.kind == .text && !($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if hasElement && hasText && node.kind == .element { return true }
    return children.contains { hasMixedContent($0) }
}

/// Texto original anterior a la etiqueta de apertura de la raíz (declaración, comentarios, DOCTYPE, PIs).
private func xmlProlog(_ text: String) -> String {
    let s = Array(text.utf8)
    var i = 0
    func starts(_ lit: String, at k: Int) -> Bool {
        let u = Array(lit.utf8)
        return k + u.count <= s.count && Array(s[k..<k + u.count]) == u
    }
    func skip(to end: String, from k: Int) -> Int {
        var k = k
        while k < s.count, !starts(end, at: k) { k += 1 }
        return min(k + end.utf8.count, s.count)
    }
    while i < s.count {
        if starts("<!--", at: i) { i = skip(to: "-->", from: i + 4) }
        else if starts("<?", at: i) { i = skip(to: "?>", from: i + 2) }
        else if starts("<!", at: i) {
            var k = i + 2, bracket = 0
            while k < s.count, !(s[k] == UInt8(ascii: ">") && bracket == 0) {
                if s[k] == UInt8(ascii: "[") { bracket += 1 } else if s[k] == UInt8(ascii: "]") { bracket -= 1 }
                k += 1
            }
            i = min(k + 1, s.count)
        }
        else if s[i] == UInt8(ascii: "<") { break }
        else { i += 1 }
    }
    return String(decoding: s[0..<i], as: UTF8.self)
}

func formatXML(_ text: String, indent: String = "    ") throws -> String {
    let doc = try XMLDocument(xmlString: text, options: [.nodePreserveAll])
    guard let root = doc.rootElement() else { return text }
    if hasMixedContent(root) {
        throw NSError(domain: "XML", code: 1, userInfo: [NSLocalizedDescriptionKey:
            L("El XML tiene texto mezclado con elementos; formatearlo cambiaría el texto.")])
    }
    let pretty = root.xmlString(options: [.nodePrettyPrint])
    let reindented = pretty.components(separatedBy: "\n").map { line -> String in
        var units = 0
        var rest = Substring(line)
        while rest.hasPrefix("    ") { rest = rest.dropFirst(4); units += 1 }
        return String(repeating: indent, count: units) + rest
    }.joined(separator: "\n")
    let prolog = xmlProlog(text)
    let eol = text.contains("\r\n") ? "\r\n" : "\n"
    var epilogue = ""
    if let children = doc.children, let rootIndex = children.firstIndex(where: { $0 === root }) {
        for node in children[(rootIndex + 1)...] {
            if node.kind == .text, (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            epilogue += eol + node.xmlString(options: [.nodePreserveAll])
        }
    }
    return prolog + reindented + epilogue
}

/// Aplica `transform` a la selección o, sin selección, al documento (una sola acción de deshacer).
func applyFormatter(editor: ScintillaView, transform: (String) throws -> String) {
    var (start, end) = selectionRange(editor)
    let text: String
    if end > start {
        text = selectedText(editor) ?? ""
    } else {
        text = currentText(editor)
        start = 0
        end = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
    }
    do {
        var result = try transform(text)
        // "\r\n" es un solo Character en Swift: mirar el último unicodeScalar.
        func endsWithEOL(_ t: String) -> Bool { t.unicodeScalars.last == "\n" || t.unicodeScalars.last == "\r" }
        if end - start == text.utf8.count, endsWithEOL(text), !endsWithEOL(result) {
            result += text.unicodeScalars.last == "\r" ? "\r" : (text.contains("\r\n") ? "\r\n" : "\n")
        }
        replaceRange(editor: editor, start: start, end: end, with: result, reselect: false)
    } catch {
        presentAlert(L("Formatear"), detail: error.localizedDescription)
    }
}
