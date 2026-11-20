import Foundation

// Modelo puro de la comparación lado a lado (sin UI: se prueba con swiftc suelto).

enum CompareRowKind { case equal, added, deleted, modified }

struct CompareRow: Equatable {
    let left: Int?
    let right: Int?
    let kind: CompareRowKind
}

struct SideBySide {
    let rows: [CompareRow]
    /// Rangos de filas (no de líneas) de cada hunk, para navegar entre diferencias.
    let hunks: [Range<Int>]
}

/// En cada hunk las primeras min(borradas, agregadas) líneas se emparejan como modificadas (igual
/// que el gutter de git); lo que sobra de un lado queda frente a un hueco.
func buildSideBySide(old: [Substring], new: [Substring]) -> SideBySide {
    var rows: [CompareRow] = []
    var rowHunks: [Range<Int>] = []
    var oldLine = 0, newLine = 0
    func appendEqual(until oldEnd: Int) {
        while oldLine < oldEnd {
            rows.append(CompareRow(left: oldLine, right: newLine, kind: .equal))
            oldLine += 1
            newLine += 1
        }
    }
    for hunk in diffHunks(old: old, new: new) {
        appendEqual(until: hunk.oldRange.lowerBound)
        let start = rows.count
        let paired = min(hunk.oldRange.count, hunk.newRange.count)
        for i in 0..<paired {
            rows.append(CompareRow(left: hunk.oldRange.lowerBound + i, right: hunk.newRange.lowerBound + i, kind: .modified))
        }
        for line in (hunk.oldRange.lowerBound + paired)..<hunk.oldRange.upperBound {
            rows.append(CompareRow(left: line, right: nil, kind: .deleted))
        }
        for line in (hunk.newRange.lowerBound + paired)..<hunk.newRange.upperBound {
            rows.append(CompareRow(left: nil, right: line, kind: .added))
        }
        rowHunks.append(start..<rows.count)
        oldLine = hunk.oldRange.upperBound
        newLine = hunk.newRange.upperBound
    }
    appendEqual(until: old.count)
    return SideBySide(rows: rows, hunks: rowHunks)
}

/// Más allá de esto el resaltado intra-línea no aporta y cuesta.
private let maxIntraLineBytes = 2000

/// Tramo distinto entre dos líneas (prefijo y sufijo comunes fuera), en offsets UTF-8 porque así
/// posiciona Scintilla. Los bordes se corren a inicio de escalar: "ñ" y "ò" comparten el primer
/// byte y un corte ahí dejaría un indicador sobre medio carácter.
func intraLineRanges(_ a: Substring, _ b: Substring) -> (left: Range<Int>, right: Range<Int>)? {
    let x = Array(a.utf8), y = Array(b.utf8)
    if x == y || x.count > maxIntraLineBytes || y.count > maxIntraLineBytes { return nil }
    func isContinuation(_ byte: UInt8) -> Bool { byte & 0xC0 == 0x80 }
    var prefix = 0
    while prefix < x.count, prefix < y.count, x[prefix] == y[prefix] { prefix += 1 }
    while prefix > 0, (prefix < x.count && isContinuation(x[prefix])) || (prefix < y.count && isContinuation(y[prefix])) {
        prefix -= 1
    }
    var suffix = 0
    while suffix < x.count - prefix, suffix < y.count - prefix,
          x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
    // El sufijo debe empezar en inicio de escalar en ambos lados.
    while suffix > 0, isContinuation(x[x.count - suffix]) || isContinuation(y[y.count - suffix]) { suffix -= 1 }
    return (prefix..<(x.count - suffix), prefix..<(y.count - suffix))
}

/// Hunk que toca la línea `line` del documento nuevo. Un borrado puro (`newRange` vacío en `k`)
/// no tiene líneas propias: se asocia a las líneas que lo rodean, `k-1` y `k`.
func hunk(containing line: Int, in hunks: [DiffHunk]) -> DiffHunk? {
    hunks.first { hunk in
        if hunk.newRange.isEmpty {
            let k = hunk.newRange.lowerBound
            return line == k - 1 || line == k
        }
        return hunk.newRange.contains(line)
    }
}

/// Línea equivalente en la versión base, o nil si la línea es agregada o modificada.
/// `hunks` en orden, como los devuelve `diffHunks`.
func mapLineToBase(_ line: Int, hunks: [DiffHunk]) -> Int? {
    var delta = 0
    for hunk in hunks {
        if line < hunk.newRange.lowerBound { break }
        if hunk.newRange.contains(line) { return nil }
        delta = hunk.oldRange.upperBound - hunk.newRange.upperBound
    }
    return line + delta
}

/// Texto de un lado de la comparación con una fila por línea (los huecos son líneas vacías) y el
/// número de línea real de cada fila. Se une con LF: las vistas son de solo lectura y así fila =
/// línea de Scintilla aunque el original tenga CRLF.
struct AlignedSide {
    let text: String
    let numbers: [Int?]
}

func alignedSide(_ rows: [CompareRow], lines: [Substring], left: Bool) -> AlignedSide {
    var parts: [Substring] = []
    var numbers: [Int?] = []
    parts.reserveCapacity(rows.count)
    numbers.reserveCapacity(rows.count)
    for row in rows {
        let line = left ? row.left : row.right
        numbers.append(line)
        parts.append(line.map { lines[$0] } ?? "")
    }
    return AlignedSide(text: parts.joined(separator: "\n"), numbers: numbers)
}

/// Hunk siguiente/anterior con vuelta al principio/final; sin selección arranca por un extremo.
func stepHunk(current: Int?, delta: Int, count: Int) -> Int? {
    guard count > 0 else { return nil }
    guard let current else { return delta >= 0 ? 0 : count - 1 }
    return ((current + delta) % count + count) % count
}

let compareMaxBytes = 5 * 1024 * 1024
let compareMaxLines = 50_000

func compareTooLarge(_ text: String) -> Bool {
    if text.utf8.count > compareMaxBytes { return true }
    var lines = 1
    for byte in text.utf8 where byte == 0x0A {
        lines += 1
        if lines > compareMaxLines { return true }
    }
    return false
}

/// Fila modificada con los rangos (en bytes UTF-8 de la línea) que difieren de cada lado.
struct IntraLineMark: Equatable {
    let row: Int
    let left: Range<Int>
    let right: Range<Int>
}

/// Todo lo que la ventana de comparar pinta, calculado de una vez y fuera del hilo principal:
/// repintar (cambio de tema) reusa esto sin volver a alinear.
struct PreparedComparison {
    let model: SideBySide
    let left: AlignedSide
    let right: AlignedSide
    let intraLine: [IntraLineMark]
}

func prepareComparison(oldText: String, newText: String) -> PreparedComparison {
    let oldLines = gitLines(oldText), newLines = gitLines(newText)
    let model = buildSideBySide(old: oldLines, new: newLines)
    var marks: [IntraLineMark] = []
    for (row, entry) in model.rows.enumerated() where entry.kind == .modified {
        guard let l = entry.left, let r = entry.right,
              let ranges = intraLineRanges(oldLines[l], newLines[r]) else { continue }
        marks.append(IntraLineMark(row: row, left: ranges.left, right: ranges.right))
    }
    return PreparedComparison(model: model,
                              left: alignedSide(model.rows, lines: oldLines, left: true),
                              right: alignedSide(model.rows, lines: newLines, left: false),
                              intraLine: marks)
}
