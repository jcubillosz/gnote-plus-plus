// Fragmentos (snippets) del usuario: modelo, parser del cuerpo y archivo JSON. Lógica pura.
import Foundation

struct Snippet: Codable, Equatable {
    var prefix: String
    var name: String
    var languages: [String]
    var body: String
}

struct SnippetField: Equatable {
    let number: Int
    /// Bytes UTF-8 dentro del texto expandido (Scintilla trabaja en bytes).
    let range: Range<Int>
}

struct ParsedSnippet: Equatable {
    let text: String
    /// 1…n, espejos del mismo número juntos, `0` al final.
    let fields: [SnippetField]
    /// Orden de aparición en el cuerpo de cada campo (paralelo a `fields`): desempata campos
    /// vacíos en la misma posición (`$1$2`, `$2$1`) al desplazarlos.
    let appearance: [Int]
}

/// Expande el cuerpo: `\n` → EOL + indentación de la línea del prefijo, `\t` → unidad de
/// indentación del documento. `$n`, `${n}`, `${n:texto}`; `\$` y `\\` escapan; `$` suelto es literal.
func parseSnippet(_ body: String, indent: String, eol: String, tab: String) -> ParsedSnippet {
    // Por unicodeScalars: "\r\n" es un solo Character en Swift.
    let s = Array(body.unicodeScalars)
    var out = ""
    var bytes = 0
    var raw: [(number: Int, start: Int, end: Int, hasDefault: Bool, order: Int)] = []

    func emit(_ text: String) { out += text; bytes += text.utf8.count }
    func emitScalars(_ scalars: ArraySlice<Unicode.Scalar>) {
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let c = scalars[i]
            if c == "\r" {
                if i + 1 < scalars.endIndex, scalars[i + 1] == "\n" { i += 1 }
                emit(eol + indent)
            } else if c == "\n" {
                emit(eol + indent)
            } else if c == "\t" {
                emit(tab)
            } else {
                emit(String(c))
            }
            i += 1
        }
    }
    func readNumber(_ from: Int) -> (Int, Int)? {
        var j = from
        var digits = ""
        while j < s.count, s[j].properties.numericType == .decimal, s[j].isASCII { digits.unicodeScalars.append(s[j]); j += 1 }
        guard let n = Int(digits) else { return nil }
        return (n, j)
    }

    var i = 0
    while i < s.count {
        let c = s[i]
        if c == "\\", i + 1 < s.count, s[i + 1] == "$" || s[i + 1] == "\\" || s[i + 1] == "}" {
            emit(String(s[i + 1])); i += 2; continue
        }
        if c == "$" {
            if let (n, next) = readNumber(i + 1) {
                raw.append((n, bytes, bytes, false, raw.count)); i = next; continue
            }
            if i + 1 < s.count, s[i + 1] == "{", let (n, next) = readNumber(i + 2), next < s.count {
                if s[next] == "}" {
                    raw.append((n, bytes, bytes, false, raw.count)); i = next + 1; continue
                }
                if s[next] == ":" {
                    // Texto por defecto hasta la `}` sin escapar.
                    var j = next + 1
                    var text: [Unicode.Scalar] = []
                    var closed = false
                    while j < s.count {
                        if s[j] == "\\", j + 1 < s.count, s[j + 1] == "}" || s[j + 1] == "$" || s[j + 1] == "\\" {
                            text.append(s[j + 1]); j += 2; continue
                        }
                        if s[j] == "}" { closed = true; break }
                        text.append(s[j]); j += 1
                    }
                    if closed {
                        let start = bytes
                        emitScalars(text[...])
                        raw.append((n, start, bytes, true, raw.count)); i = j + 1; continue
                    }
                }
            }
        }
        emitScalars(s[i...i])
        i += 1
    }

    // Espejos: los números repetidos sin texto propio toman el del que lo define.
    var defaults: [Int: String] = [:]
    let utf8 = Array(out.utf8)
    for f in raw where f.hasDefault && defaults[f.number] == nil {
        defaults[f.number] = String(decoding: utf8[f.start..<f.end], as: UTF8.self)
    }
    if !defaults.isEmpty {
        var rebuilt: [UInt8] = []
        var cursor = 0
        var shift = 0
        var adjusted: [(Int, Int, Int, Int)] = []
        for f in raw.sorted(by: { $0.start != $1.start ? $0.start < $1.start : $0.order < $1.order }) {
            rebuilt += utf8[cursor..<f.start]
            cursor = f.start
            let start = f.start + shift
            if !f.hasDefault, let text = defaults[f.number] {
                rebuilt += Array(text.utf8)
                shift += text.utf8.count
                adjusted.append((f.number, start, start + text.utf8.count, f.order))
            } else {
                rebuilt += utf8[f.start..<f.end]
                cursor = f.end
                adjusted.append((f.number, start, f.end + shift, f.order))
            }
        }
        rebuilt += utf8[cursor...]
        out = String(decoding: rebuilt, as: UTF8.self)
        raw = adjusted.map { ($0.0, $0.1, $0.2, true, $0.3) }
    }

    var entries = raw.map { (field: SnippetField(number: $0.number, range: $0.start..<$0.end), order: $0.order) }
    if !entries.contains(where: { $0.field.number == 0 }) {
        let end = out.utf8.count
        entries.append((SnippetField(number: 0, range: end..<end), raw.count))
    }
    entries.sort { a, b in
        let ka = a.field.number == 0 ? Int.max : a.field.number
        let kb = b.field.number == 0 ? Int.max : b.field.number
        return ka != kb ? ka < kb : a.field.range.lowerBound < b.field.range.lowerBound
    }
    return ParsedSnippet(text: out, fields: entries.map(\.field), appearance: entries.map(\.order))
}

/// Si un campo se desplaza cuando el campo actual pasa de [oldStart, oldEnd) a otro largo. Un
/// campo en la misma posición que uno actual vacío solo se mueve si aparece después en el cuerpo.
func snippetFieldShifts(start: Int, appearance: Int, oldStart: Int, oldEnd: Int, primaryAppearance: Int) -> Bool {
    if start != oldEnd { return start > oldEnd }
    return start != oldStart || appearance > primaryAppearance
}

/// Palabra `[A-Za-z0-9_.-]+` justo antes del caret, precedida por espacio o inicio de línea.
func snippetPrefix(lineBeforeCaret: String) -> String? {
    let scalars = Array(lineBeforeCaret.unicodeScalars)
    var i = scalars.count
    while i > 0 {
        let c = scalars[i - 1]
        guard c.isASCII, c.properties.isAlphabetic || ("0"..."9").contains(c) || c == "_" || c == "." || c == "-" else { break }
        i -= 1
    }
    guard i < scalars.count else { return nil }
    if i > 0, scalars[i - 1] != " ", scalars[i - 1] != "\t" { return nil }
    var word = ""
    word.unicodeScalars.append(contentsOf: scalars[i...])
    return word
}

/// El fragmento del lenguaje gana sobre uno de `*`.
func matchingSnippet(prefix: String, language: String, in snippets: [Snippet]) -> Snippet? {
    let lang = language.lowercased()
    let candidates = snippets.filter { $0.prefix == prefix }
    return candidates.first { $0.languages.contains { $0.lowercased() == lang } }
        ?? candidates.first { $0.languages.contains("*") }
}

private struct SnippetFile: Codable {
    var version: Int
    var snippets: [Snippet]
}

func decodeSnippetFile(_ data: Data) -> [Snippet]? {
    (try? JSONDecoder().decode(SnippetFile.self, from: data))?.snippets
}

func encodeSnippetFile(_ snippets: [Snippet]) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(SnippetFile(version: 1, snippets: snippets))) ?? Data()
}

let defaultSnippets: [Snippet] = [
    Snippet(prefix: "fn", name: "Función", languages: ["swift"], body: "func ${1:nombre}($2) {\n\t$0\n}"),
    Snippet(prefix: "guard", name: "guard let", languages: ["swift"], body: "guard let ${1:valor} = ${2:opcional} else {\n\t${3:return}\n}\n$0"),
    Snippet(prefix: "ifl", name: "if let", languages: ["swift"], body: "if let ${1:valor} = ${2:opcional} {\n\t$0\n}"),
    Snippet(prefix: "fn", name: "Función", languages: ["javascript", "javascript.js", "typescript"], body: "function ${1:nombre}($2) {\n\t$0\n}"),
    Snippet(prefix: "log", name: "console.log", languages: ["javascript", "javascript.js", "typescript"], body: "console.log($1);$0"),
    Snippet(prefix: "afn", name: "Función flecha", languages: ["javascript", "javascript.js", "typescript"], body: "const ${1:nombre} = ($2) => {\n\t$0\n};"),
    Snippet(prefix: "def", name: "Función", languages: ["python"], body: "def ${1:nombre}($2):\n\t${0:pass}"),
    Snippet(prefix: "main", name: "Bloque main", languages: ["python"], body: "if __name__ == \"__main__\":\n\t${0:main()}"),
    Snippet(prefix: "html5", name: "Documento HTML5", languages: ["html"],
            body: "<!DOCTYPE html>\n<html lang=\"${1:es}\">\n<head>\n\t<meta charset=\"utf-8\">\n\t<title>${2:Título}</title>\n</head>\n<body>\n\t$0\n</body>\n</html>"),
    Snippet(prefix: "tbl", name: "Tabla", languages: ["markdown"],
            body: "| ${1:Columna} | ${2:Columna} |\n| --- | --- |\n| $3 | $4 |\n$0"),
    Snippet(prefix: "det", name: "Plegable", languages: ["markdown"],
            body: "<details>\n<summary>${1:Resumen}</summary>\n\n$0\n\n</details>"),
    Snippet(prefix: "todo", name: "TODO", languages: ["*"], body: "TODO: $0"),
]
