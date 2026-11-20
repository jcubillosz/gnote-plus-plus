import Foundation

// MARK: - Blame (puro)

struct BlameLine: Equatable {
    let sha: String
    let author: String
    let authorTime: Date
    let summary: String
    var isUncommitted: Bool
}

/// Salida de `git blame --porcelain`. Índice del resultado = línea de HEAD (0-based). Porcelain
/// trae la cabecera completa de un commit solo la primera vez que aparece; después la línea de
/// encabezado es solo "sha orig final [n]", así que los datos se guardan por sha.
func parseBlamePorcelain(_ data: Data) -> [BlameLine] {
    struct Info { var author = ""; var time = Date(timeIntervalSince1970: 0); var summary = "" }
    var commits: [String: Info] = [:]
    var result: [BlameLine] = []
    var currentSha: String?
    var current = Info()

    for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
        guard let first = rawLine.first else { continue }
        // Línea de contenido: empieza con TAB y cierra la entrada.
        if first == 0x09 {
            guard let sha = currentSha else { continue }
            if commits[sha] == nil { commits[sha] = current }
            let info = commits[sha]!
            result.append(BlameLine(sha: sha, author: info.author, authorTime: info.time, summary: info.summary,
                                    isUncommitted: sha.allSatisfy { $0 == "0" }))
            currentSha = nil
            continue
        }
        let line = String(decoding: rawLine, as: UTF8.self)
        if currentSha == nil {
            // Encabezado: "<sha40> <orig> <final> [<n>]".
            let sha = line.prefix { $0 != " " }
            guard sha.count == 40 else { continue }
            currentSha = String(sha)
            current = commits[currentSha!] ?? Info()
            continue
        }
        guard commits[currentSha!] == nil, let space = line.firstIndex(of: " ") else { continue }
        let value = String(line[line.index(after: space)...])
        switch line[..<space] {
        case "author": current.author = value
        case "author-time": current.time = Date(timeIntervalSince1970: TimeInterval(value) ?? 0)
        case "summary": current.summary = value
        default: break
        }
    }
    return result
}

/// "Autor, hace 3 días · resumen" (resumen truncado a 60). nil o sin commitear → "Sin commitear".
func blameText(_ line: BlameLine?, now: Date, locale: Locale) -> String {
    guard let line, !line.isUncommitted else { return L("Sin commitear") }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = .full
    let when = formatter.localizedString(for: min(line.authorTime, now), relativeTo: now)
    let summary = line.summary.count > 60 ? String(line.summary.prefix(59)) + "…" : line.summary
    return summary.isEmpty ? "\(line.author), \(when)" : "\(line.author), \(when) · \(summary)"
}
