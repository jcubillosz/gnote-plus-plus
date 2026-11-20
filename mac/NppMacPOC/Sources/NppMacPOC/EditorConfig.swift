import Foundation

// Soporte de .editorconfig (https://spec.editorconfig.org). Lógica pura arriba; la lectura de
// disco y la aplicación a Scintilla están en loadEditorConfig / TabsViewModel+EditorConfig.

struct EditorConfigProperties: Equatable {
    var indentStyle: String?
    var indentSize: Int?
    var tabWidth: Int?
    var endOfLine: String?
    var trimTrailingWhitespace: Bool?
    var insertFinalNewline: Bool?
    var charset: String?

    var isEmpty: Bool { self == EditorConfigProperties() }

    /// Una línea por propiedad definida, para el tooltip del indicador "EC".
    var summary: [String] {
        var out: [String] = []
        if let v = indentStyle { out.append("indent_style = \(v)") }
        if let v = indentSize { out.append("indent_size = \(v)") }
        if let v = tabWidth { out.append("tab_width = \(v)") }
        if let v = endOfLine { out.append("end_of_line = \(v)") }
        if let v = trimTrailingWhitespace { out.append("trim_trailing_whitespace = \(v)") }
        if let v = insertFinalNewline { out.append("insert_final_newline = \(v)") }
        if let v = charset { out.append("charset = \(v)") }
        return out
    }
}

func parseEditorConfig(_ text: String) -> (root: Bool, sections: [(glob: String, props: [String: String])]) {
    var root = false
    var sections: [(glob: String, props: [String: String])] = []
    for rawLine in text.unicodeScalars.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        let line = String(String.UnicodeScalarView(rawLine)).trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
        if line.hasPrefix("["), line.hasSuffix("]") {
            sections.append((String(line.dropFirst().dropLast()), [:]))
            continue
        }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).lowercased()
        if key.isEmpty { continue }
        if sections.isEmpty {
            if key == "root" { root = (value == "true") }
        } else {
            sections[sections.count - 1].props[key] = value
        }
    }
    return (root, sections)
}

// MARK: - Globs

private func globToRegex(_ g: [Character], _ i: inout Int, stopAtBraceEnd: Bool, stopAtComma: Bool) -> String {
    var out = ""
    while i < g.count {
        let c = g[i]
        if stopAtBraceEnd && c == "}" { break }
        if stopAtComma && c == "," { break }
        switch c {
        case "\\":
            if i + 1 < g.count { out += NSRegularExpression.escapedPattern(for: String(g[i + 1])); i += 2 } else { out += "\\\\"; i += 1 }
        case "*":
            if i + 1 < g.count, g[i + 1] == "*" {
                // "a/**/b" también debe valer para "a/b": la barra de después de ** es opcional.
                if i + 2 < g.count, g[i + 2] == "/" { out += "(?:.*/)?"; i += 3 } else { out += ".*"; i += 2 }
            } else { out += "[^/]*"; i += 1 }
        case "?":
            out += "[^/]"; i += 1
        case "[":
            // Sin "]" de cierre, el corchete es literal.
            var j = i + 1
            if j < g.count, g[j] == "!" { j += 1 }
            if j < g.count, g[j] == "]" { j += 1 }
            while j < g.count, g[j] != "]" { j += 1 }
            if j >= g.count { out += "\\["; i += 1; break }
            var body = Array(g[(i + 1)..<j])
            var neg = false
            if body.first == "!" { neg = true; body.removeFirst() }
            let escaped = body.map { $0 == "\\" || $0 == "[" || $0 == "^" ? "\\\($0)" : String($0) }.joined()
            out += "[" + (neg ? "^/" : "") + escaped + "]"
            i = j + 1
        case "{":
            // Buscar la llave de cierre con balance.
            var depth = 0
            var j = i
            var close = -1
            while j < g.count {
                if g[j] == "\\" { j += 2; continue }
                if g[j] == "{" { depth += 1 } else if g[j] == "}" { depth -= 1; if depth == 0 { close = j; break } }
                j += 1
            }
            if close < 0 { out += "\\{"; i += 1; break }
            let inner = String(g[(i + 1)..<close])
            if let range = numericRange(inner) {
                out += "(?:" + range.map(String.init).joined(separator: "|") + ")"
                i = close + 1
                break
            }
            var alts: [String] = []
            var k = i + 1
            while true {
                var sub = k
                // Se parte por comas de primer nivel: globToRegex consume las anidadas. Se sigue
                // hasta llegar a la llave para no perder una alternativa vacía final ("{a,}").
                let piece = globToRegexLimited(g, &sub, end: close)
                alts.append(piece)
                if sub >= close { break }
                k = sub + 1
            }
            if alts.count == 1 { out += "\\{" + alts[0] + "\\}" } else { out += "(?:" + alts.joined(separator: "|") + ")" }
            i = close + 1
        default:
            out += NSRegularExpression.escapedPattern(for: String(c)); i += 1
        }
    }
    return out
}

/// Traduce desde `i` hasta la próxima coma de primer nivel o `end`, dejando `i` sobre ella.
private func globToRegexLimited(_ g: [Character], _ i: inout Int, end: Int) -> String {
    let slice = Array(g[0..<end])
    return globToRegex(slice, &i, stopAtBraceEnd: false, stopAtComma: true)
}

private func numericRange(_ s: String) -> [Int]? {
    let parts = s.components(separatedBy: "..")
    guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), abs(b - a) <= 1000 else { return nil }
    return a <= b ? Array(a...b) : Array(b...a)
}

func editorConfigGlobMatches(_ glob: String, relativePath: String) -> Bool {
    var pattern = glob
    // Con "/" el glob se ancla a la carpeta del .editorconfig; sin "/" vale en cualquier subcarpeta.
    let prefix: String
    if pattern.contains("/") {
        if pattern.hasPrefix("/") { pattern.removeFirst() }
        prefix = ""
    } else {
        prefix = "(?:.*/)?"
    }
    let chars = Array(pattern)
    var i = 0
    let body = globToRegex(chars, &i, stopAtBraceEnd: false, stopAtComma: false)
    guard let re = try? NSRegularExpression(pattern: "^" + prefix + body + "$") else { return false }
    let range = NSRange(relativePath.startIndex..., in: relativePath)
    return re.firstMatch(in: relativePath, range: range) != nil
}

// MARK: - Resolución

func resolveEditorConfig(for filePath: String, files: [(dir: String, text: String)]) -> EditorConfigProperties {
    var merged: [String: String] = [:]
    for file in files {
        var dir = file.dir
        if !dir.hasSuffix("/") { dir += "/" }
        guard filePath.hasPrefix(dir) else { continue }
        let relative = String(filePath.dropFirst(dir.count))
        for section in parseEditorConfig(file.text).sections
        where editorConfigGlobMatches(section.glob, relativePath: relative) {
            for (k, v) in section.props { merged[k] = v }
        }
    }
    func value(_ key: String) -> String? {
        guard let v = merged[key], v != "unset", !v.isEmpty else { return nil }
        return v
    }
    var p = EditorConfigProperties()
    p.indentStyle = value("indent_style")
    p.tabWidth = value("tab_width").flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
    if let size = value("indent_size") {
        if size == "tab" { p.indentSize = p.tabWidth } else if let n = Int(size), n > 0 { p.indentSize = n }
    }
    if p.tabWidth == nil { p.tabWidth = p.indentSize }
    p.endOfLine = value("end_of_line")
    p.trimTrailingWhitespace = value("trim_trailing_whitespace").flatMap { $0 == "true" ? true : $0 == "false" ? false : nil }
    p.insertFinalNewline = value("insert_final_newline").flatMap { $0 == "true" ? true : $0 == "false" ? false : nil }
    p.charset = value("charset")
    return p
}

/// Lee los .editorconfig subiendo desde la carpeta del archivo hasta `root = true` o la raíz.
func loadEditorConfig(for url: URL) -> (props: EditorConfigProperties, sources: [URL]) {
    // Mismo criterio que `ancestorDirectoryPaths` para que el prefijo de carpeta calce.
    let filePath = (url.path as NSString).standardizingPath
    var found: [(dir: String, text: String)] = []
    var sources: [URL] = []
    for dirPath in ancestorDirectoryPaths(of: filePath) {
        let candidate = URL(fileURLWithPath: dirPath, isDirectory: true).appendingPathComponent(".editorconfig")
        if let data = try? Data(contentsOf: candidate) {
            let text = String(decoding: data, as: UTF8.self)
            found.append((dirPath, text))
            sources.append(candidate)
            if parseEditorConfig(text).root { break }
        }
    }
    return (resolveEditorConfig(for: filePath, files: found.reversed()), sources.reversed())
}

/// Carpetas ancestro de `path` (sin incluirlo), de la más cercana a "/". Se trabaja con texto y
/// con tope: subir con `URL.deletingLastPathComponent()` desde ciertas URLs (p. ej. resueltas
/// de bookmarks) puede dar "/..", "/../.." sin llegar nunca a un punto fijo — colgaba la app al
/// restaurar la sesión.
func ancestorDirectoryPaths(of path: String) -> [String] {
    var result: [String] = []
    var current = (path as NSString).standardizingPath
    for _ in 0..<256 {
        let parent = (current as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == current { break }
        result.append(parent)
        current = parent
    }
    return result
}
