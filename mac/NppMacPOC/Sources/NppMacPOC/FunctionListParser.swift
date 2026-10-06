import Foundation
import RegexShim

/// Lista de funciones para código, con las reglas de Notepad++ (`functionList/*.xml`) y su
/// mismo motor de regex (Boost, vía RegexShim). Port acotado de
/// PowerEditor/src/WinControls/FunctionList/functionParser.cpp:
/// - parser "unit" (solo `<function>`), "zone" (solo `<classRange>`) y "mix" (ambos);
/// - zonas de comentario (`commentExpr`) excluidas;
/// - nombres por cadena de `nameExpr`/`funcNameExpr`, cada una buscada dentro de la anterior;
/// - cuerpo de clase delimitado balanceando `openSymbole`/`closeSymbole`.
/// Simplificación: un solo nivel de clases (Notepad++ vuelve a escanear un segundo nivel).
enum FunctionList {
    /// Regla para el lenguaje, o nil si Notepad++ (o GNote++) no trae una. Cacheada.
    static func rule(forLanguage languageName: String) -> FunctionListRule? {
        guard !languageName.isEmpty else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[languageName] { return cached }
        let fileName = fileNameOverrides[languageName] ?? languageName
        let rule = Bundle.module.url(forResource: fileName, withExtension: "xml", subdirectory: "functionList")
            .flatMap(FunctionListRule.load(from:))
        cache[languageName] = .some(rule)
        return rule
    }

    /// Nombres de archivo que no coinciden con el `<Language name>` (overrideMap.xml de Notepad++).
    private static let fileNameOverrides = ["javascript": "javascript.js"]
    private static var cache: [String: FunctionListRule?] = [:]
    private static let cacheLock = NSLock()
}

final class FunctionListRule {
    struct ClassRange {
        var mainExpr = ""
        var openSymbol = ""
        var closeSymbol = ""
        var classNameExprs: [String] = []
        var functionExpr = ""
        var functionNameExprs: [String] = []
    }

    struct Function {
        var mainExpr = ""
        var nameExprs: [String] = []
        var classNameExprs: [String] = []
    }

    var commentExpr = ""
    var classRange: ClassRange?
    var function: Function?

    static func load(from url: URL) -> FunctionListRule? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parser = XMLParser(data: Data(preservingAttributeNewlines(raw).utf8))
        let delegate = RuleXMLDelegate()
        parser.delegate = delegate
        guard parser.parse(), delegate.foundParser else { return nil }
        let rule = delegate.rule
        guard rule.classRange != nil || rule.function != nil else { return nil }
        return rule
    }

    /// Varias reglas (cpp, cs, java…) usan `(?x)` con comentarios `#` hasta fin de línea dentro
    /// del atributo mainExpr. La normalización de atributos de XML (que aplica XMLParser)
    /// convierte esos saltos de línea en espacios y el resto del patrón queda comentado; el
    /// parser XML de Notepad++ los conserva. Se reescriben como `&#10;` (que la normalización
    /// respeta) solo dentro de valores de atributo entre comillas, fuera de comentarios XML.
    private static func preservingAttributeNewlines(_ xml: String) -> String {
        var output = ""
        output.reserveCapacity(xml.utf8.count)
        var inTag = false, inComment = false
        var quote: Character?
        var recent = ""
        for character in xml {
            recent = String((recent + String(character)).suffix(4))
            if inComment {
                output.append(character)
                if recent.hasSuffix("-->") { inComment = false }
                continue
            }
            if let q = quote {
                switch character {
                case q: quote = nil; output.append(character)
                case "\n", "\r\n": output += "&#10;"
                case "\r": output += "&#10;"
                case "\t": output += "&#9;"
                default: output.append(character)
                }
                continue
            }
            output.append(character)
            if recent == "<!--" {
                inComment = true
                inTag = false
            } else if character == "<" {
                inTag = true
            } else if character == ">" {
                inTag = false
            } else if inTag, character == "\"" || character == "'" {
                quote = character
            }
        }
        return output
    }

    // MARK: - Parseo

    /// Devuelve los ítems del esquema a partir de los bytes UTF-8 del documento (mismas
    /// posiciones que Scintilla).
    func parse(_ bytes: [CChar]) -> [OutlineItem] {
        let engine = RegexEngine()
        let length = bytes.count
        var found: [Found] = []

        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let text = Text(base: base, length: length, engine: engine)
            let comments = text.zones(commentExpr, 0..<length)

            var classZones: [Range<Int>] = []
            if let classRange {
                var begin = 0
                while begin < length, let match = text.search(classRange.mainExpr, begin..<length) {
                    let className = text.subLevel(classRange.classNameExprs, match)
                    var end = match.upperBound
                    if !classRange.openSymbol.isEmpty, !classRange.closeSymbol.isEmpty {
                        end = text.bodyClose(from: match.upperBound, open: classRange.openSymbol, close: classRange.closeSymbol, comments: comments)
                    }
                    let zone = match.lowerBound..<max(end, match.upperBound)
                    if !Text.isInZones(match.lowerBound, comments) {
                        classZones.append(zone)
                        let name = className?.text ?? ""
                        found.append(Found(name: name, position: className?.position ?? match.lowerBound, className: nil, isClass: true))
                        text.functions(
                            main: classRange.functionExpr, nameExprs: classRange.functionNameExprs, classNameExprs: [],
                            in: zone, comments: comments, className: name, into: &found
                        )
                    }
                    begin = zone.upperBound > begin ? zone.upperBound : begin + 1
                }
            }

            if let function {
                // Sin classRange (parser "unit") se excluyen los comentarios; con classRange
                // ("mix") se excluyen las zonas de clase ya escaneadas.
                let excluded = classRange == nil ? comments : classZones
                for zone in Text.invert(excluded, total: length) {
                    text.functions(
                        main: function.mainExpr, nameExprs: function.nameExprs, classNameExprs: function.classNameExprs,
                        in: zone, comments: comments, className: nil, into: &found
                    )
                }
            }
        }

        return makeItems(found, bytes: bytes)
    }

    /// Clase (nivel 1) seguida de sus métodos (nivel 2); funciones sueltas en nivel 1. Las
    /// funciones con nombre de clase propio (p.ej. `Clase::metodo` en C++) se muestran con ese
    /// prefijo en nivel 1 para mantener el orden por línea (lo usa currentIndex del esquema).
    private func makeItems(_ found: [Found], bytes: [CChar]) -> [OutlineItem] {
        var lineStarts = [0]
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            lineStarts.append(index + 1)
        }
        func line(of position: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= position { low = mid } else { high = mid - 1 }
            }
            return low
        }

        var items: [OutlineItem] = []
        var seen = Set<String>()
        for entry in found.sorted(by: { $0.position < $1.position }) {
            let title: String
            let level: Int
            if entry.isClass {
                title = entry.name
                level = 1
            } else if let className = entry.className, entry.fromClassRange {
                title = entry.name
                level = className.isEmpty ? 1 : 2
            } else if let className = entry.className, !className.isEmpty {
                title = "\(className)::\(entry.name)"
                level = 1
            } else {
                title = entry.name
                level = 1
            }
            let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            guard !cleaned.isEmpty else { continue }
            let item = OutlineItem(level: level, title: cleaned, line: line(of: entry.position))
            guard seen.insert(item.id).inserted else { continue }
            items.append(item)
        }
        return items
    }

    struct Found {
        let name: String
        let position: Int
        let className: String?
        let isClass: Bool
        var fromClassRange = false
    }
}

/// Acceso a los bytes del documento + motor de regex, con las operaciones de functionParser.cpp.
private struct Text {
    let base: UnsafePointer<CChar>
    let length: Int
    let engine: RegexEngine

    func search(_ pattern: String, _ range: Range<Int>) -> Range<Int>? {
        guard !pattern.isEmpty, range.lowerBound < range.upperBound else { return nil }
        return engine.search(pattern, base: base, length: length, range: range)
    }

    func string(_ range: Range<Int>) -> String {
        let buffer = UnsafeBufferPointer(start: base + range.lowerBound, count: range.count)
        return String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Todas las coincidencias no superpuestas (zonas de comentario).
    func zones(_ pattern: String, _ range: Range<Int>) -> [Range<Int>] {
        var zones: [Range<Int>] = []
        var begin = range.lowerBound
        while begin < range.upperBound, let match = search(pattern, begin..<range.upperBound) {
            zones.append(match)
            begin = match.upperBound > begin ? match.upperBound : begin + 1
        }
        return zones
    }

    /// parseSubLevel: cada expresión se busca dentro de la coincidencia anterior.
    func subLevel(_ exprs: [String], _ range: Range<Int>) -> (text: String, position: Int)? {
        guard !exprs.isEmpty else { return nil }
        var current = range
        for expr in exprs {
            guard let match = search(expr, current) else { return nil }
            current = match
        }
        return (string(current), current.lowerBound)
    }

    /// getBodyClosePos: balancea open/close desde `begin` (el primer open ya consumido por
    /// mainExpr cuenta como abierto), ignorando símbolos dentro de comentarios.
    func bodyClose(from begin: Int, open: String, close: String, comments: [Range<Int>]) -> Int {
        let either = "(\(open)|\(close))"
        var depth = 1
        var position = begin
        while position < length, let match = search(either, position..<length) {
            if !Text.isInZones(match.lowerBound, comments) {
                if search(open, match) != nil { depth += 1 } else { depth -= 1 }
                if depth == 0 { return match.upperBound }
            }
            position = match.upperBound > position ? match.upperBound : position + 1
        }
        return length
    }

    /// funcParse: funciones en `range`; `className` fija la clase (dentro de un classRange).
    func functions(
        main: String, nameExprs: [String], classNameExprs: [String], in range: Range<Int>,
        comments: [Range<Int>], className: String?, into found: inout [FunctionListRule.Found]
    ) {
        var begin = range.lowerBound
        while begin < range.upperBound, let match = search(main, begin..<range.upperBound) {
            defer { begin = match.upperBound > begin ? match.upperBound : begin + 1 }
            let name: (text: String, position: Int)?
            if nameExprs.isEmpty {
                name = (string(match), match.lowerBound)
            } else {
                name = subLevel(nameExprs, match)
            }
            guard let name, !Text.isInZones(name.position, comments) else { continue }
            let resolvedClass = className ?? subLevel(classNameExprs, match)?.text
            var entry = FunctionListRule.Found(name: name.text, position: name.position, className: resolvedClass, isClass: false)
            entry.fromClassRange = className != nil
            found.append(entry)
        }
    }

    static func isInZones(_ position: Int, _ zones: [Range<Int>]) -> Bool {
        zones.contains { $0.contains(position) }
    }

    static func invert(_ zones: [Range<Int>], total: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var cursor = 0
        for zone in zones.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if zone.lowerBound > cursor { result.append(cursor..<zone.lowerBound) }
            cursor = max(cursor, zone.upperBound)
        }
        if cursor < total { result.append(cursor..<total) }
        return result
    }
}

/// Compila cada patrón una vez por parseo (las reglas repiten las mismas expresiones en cada
/// búsqueda). Un patrón que Boost no acepta se recuerda como inválido y no vuelve a intentarse.
private final class RegexEngine {
    private var compiled: [String: UnsafeMutableRawPointer?] = [:]
    private static var reported = Set<String>()
    private static let reportLock = NSLock()

    func search(_ pattern: String, base: UnsafePointer<CChar>, length: Int, range: Range<Int>) -> Range<Int>? {
        guard let handle = handle(for: pattern) else { return nil }
        var start = 0, end = 0
        let result = npp_regex_search(handle, base, length, range.lowerBound, range.upperBound, &start, &end)
        guard result == 1 else { return nil }
        return start..<end
    }

    private func handle(for pattern: String) -> UnsafeMutableRawPointer? {
        if let cached = compiled[pattern] { return cached }
        var error: UnsafeMutablePointer<CChar>?
        let handle = npp_regex_compile(pattern, &error)
        if let error {
            // Una vez por patrón en toda la sesión (el esquema se recalcula en cada edición).
            // Pasa con reglas del propio upstream, p.ej. el commentExpr de fortran77.xml.
            RegexEngine.reportLock.lock()
            if RegexEngine.reported.insert(pattern).inserted {
                FileHandle.standardError.write("[functionList] regex inválida: \(pattern) — \(String(cString: error))\n".data(using: .utf8)!)
            }
            RegexEngine.reportLock.unlock()
            npp_regex_free_string(error)
        }
        compiled[pattern] = handle
        return handle
    }

    deinit {
        for handle in compiled.values {
            if let handle { npp_regex_free(handle) }
        }
    }
}

/// Lee `<parser>` del XML de reglas: atributos de parser, classRange (+className, function,
/// functionName/funcNameExpr) y function (+functionName/nameExpr, className/nameExpr).
private final class RuleXMLDelegate: NSObject, XMLParserDelegate {
    let rule = FunctionListRule()
    var foundParser = false
    private var path: [String] = []

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        defer { path.append(element) }
        let parent = path.last
        let inClassRange = path.contains("classRange")
        switch element {
        case "parser" where !foundParser:
            foundParser = true
            rule.commentExpr = attributes["commentExpr"] ?? ""
        case "classRange":
            var range = FunctionListRule.ClassRange()
            range.mainExpr = attributes["mainExpr"] ?? ""
            range.openSymbol = attributes["openSymbole"] ?? ""
            range.closeSymbol = attributes["closeSymbole"] ?? ""
            rule.classRange = range
        case "function" where inClassRange:
            rule.classRange?.functionExpr = attributes["mainExpr"] ?? ""
        case "function" where parent == "parser":
            var function = FunctionListRule.Function()
            function.mainExpr = attributes["mainExpr"] ?? ""
            rule.function = function
        case "nameExpr", "funcNameExpr":
            guard let expr = attributes["expr"], !expr.isEmpty else { return }
            if inClassRange {
                if parent == "className" {
                    rule.classRange?.classNameExprs.append(expr)
                } else if parent == "functionName" {
                    rule.classRange?.functionNameExprs.append(expr)
                }
            } else if parent == "functionName" {
                rule.function?.nameExprs.append(expr)
            } else if parent == "className" {
                rule.function?.classNameExprs.append(expr)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if path.last == element { path.removeLast() }
    }
}
