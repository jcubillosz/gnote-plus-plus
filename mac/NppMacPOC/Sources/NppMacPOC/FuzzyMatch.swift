// Coincidencia difusa para la paleta de comandos y "Abrir rápido".
import Foundation

struct FuzzyResult {
    let score: Int
    /// Índices de `Character` del candidato original.
    let matched: [Int]
}

/// Candidato ya plegado: Task 3 lo guarda en su índice para no replegar 50 000 rutas por pulsación.
struct FoldedCandidate {
    let original: [Character]
    let folded: [Character]
    init(_ s: String) {
        original = Array(s)
        folded = foldChars(original, source: s)
    }
}

/// Consulta plegada una sola vez por búsqueda.
func foldQuery(_ query: String) -> [Character] {
    let t = query.trimmingCharacters(in: .whitespaces)
    return foldChars(Array(t), source: t)
}

private func foldChars(_ chars: [Character], source: String) -> [Character] {
    // Camino rápido ASCII: minúscula por bytes, sin crear un String por carácter.
    var ascii = true
    for b in source.utf8 where b >= 128 { ascii = false; break }
    if ascii {
        return chars.map { ch in
            let v = ch.asciiValue ?? 0
            return (v >= 65 && v <= 90) ? Character(UnicodeScalar(v + 32)) : ch
        }
    }
    // Carácter a carácter: así el índice plegado es el índice original (plegar el String entero
    // puede cambiar su largo, p. ej. con ligaduras).
    return chars.map { ch in
        String(ch).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).first ?? ch
    }
}

/// Alineación óptima (DP): maximiza el puntaje, no toma la primera aparición de cada letra
/// ("dl" en "Duplicar línea" debe elegir la "l" de "línea", no la de "Duplicar").
func fuzzyScore(query: String, candidate: String, fileNameStart: Int? = nil) -> FuzzyResult? {
    fuzzyScore(foldedQuery: foldQuery(query), candidate: FoldedCandidate(candidate), fileNameStart: fileNameStart)
}

func fuzzyScore(foldedQuery q: [Character], candidate fc: FoldedCandidate, fileNameStart: Int? = nil) -> FuzzyResult? {
    let c = fc.folded
    let original = fc.original
    guard !q.isEmpty else { return FuzzyResult(score: 0, matched: []) }
    let n = c.count, m = q.count
    guard n >= m else { return nil }

    // Salida rápida: con 50 000 candidatos, la mayoría no es subsecuencia.
    var qi = 0
    for ch in c where qi < m && ch == q[qi] { qi += 1 }
    guard qi == m else { return nil }

    func bonus(_ j: Int) -> Int {
        var b = 10
        if j == 0 || !original[j - 1].isLetter && !original[j - 1].isNumber { b += 20 }
        else if original[j].isUppercase && original[j - 1].isLowercase { b += 20 }
        if let f = fileNameStart, j >= f { b += 8 }
        return b
    }

    let neg = Int.min / 2
    var dp = [[Int]](repeating: [Int](repeating: neg, count: n), count: m)
    var par = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)
    for j in 0..<n where c[j] == q[0] { dp[0][j] = bonus(j) }
    for i in 1..<max(m, 1) {
        // Mejor predecesor no contiguo con penalización lineal por hueco.
        var run = neg, runIdx = -1
        for j in i..<n {
            // Candidatos k <= j-2 entran al acumulado; k = j-1 es el contiguo.
            if j - 2 >= 0 {
                if run > neg { run -= 1 }
                if dp[i - 1][j - 2] > run { run = dp[i - 1][j - 2]; runIdx = j - 2 }
            }
            guard c[j] == q[i] else { continue }
            var best = neg, from = -1
            if dp[i - 1][j - 1] > neg { best = dp[i - 1][j - 1] + 20; from = j - 1 }
            if run > neg, run - 1 > best { best = run - 1; from = runIdx }
            if from >= 0 { dp[i][j] = best + bonus(j); par[i][j] = from }
        }
    }
    var bestJ = -1, bestScore = neg
    for j in 0..<n where dp[m - 1][j] > bestScore { bestScore = dp[m - 1][j]; bestJ = j }
    guard bestJ >= 0 else { return nil }
    var matched = [Int](repeating: 0, count: m)
    var j = bestJ
    for i in stride(from: m - 1, through: 0, by: -1) { matched[i] = j; j = par[i][j] }
    return FuzzyResult(score: bestScore, matched: matched)
}

func fuzzyRank<T>(_ items: [T], query: String, key: (T) -> String, fileNameStart: (T) -> Int?,
                  limit: Int) -> [(item: T, result: FuzzyResult)] {
    fuzzyRankFolded(items, query: query, candidate: { FoldedCandidate(key($0)) }, key: key,
                    fileNameStart: fileNameStart, limit: limit)
}

/// Variante con candidatos precalculados (`candidate` devuelve el guardado en el índice).
func fuzzyRankFolded<T>(_ items: [T], query: String, candidate: (T) -> FoldedCandidate, key: (T) -> String,
                        fileNameStart: (T) -> Int?, limit: Int) -> [(item: T, result: FuzzyResult)] {
    let q = foldQuery(query)
    if q.isEmpty { return items.prefix(limit).map { ($0, FuzzyResult(score: 0, matched: [])) } }
    var scored: [(item: T, result: FuzzyResult)] = []
    for item in items {
        if let r = fuzzyScore(foldedQuery: q, candidate: candidate(item), fileNameStart: fileNameStart(item)) {
            scored.append((item, r))
        }
    }
    // La clave solo se calcula al comparar empates.
    scored.sort { $0.result.score != $1.result.score ? $0.result.score > $1.result.score : key($0.item) < key($1.item) }
    return Array(scored.prefix(limit))
}
