import Foundation

// Restaurar un hunk del margen git (puro: se prueba con swiftc suelto).

/// Tramo del documento que reemplaza `revertedText`.
struct RevertSpan: Equatable {
    enum Start: Equatable { case lineStart(Int), lineEnd(Int) }
    enum End: Equatable { case lineStart(Int), documentEnd }
    let start: Start
    let end: End
}

/// Un hunk que llega al final de la base también llega al final del documento (lo que sigue es
/// sufijo común). Ahí la última línea no tiene salto: se reemplaza desde el fin de la línea
/// anterior, para que el salto que la separa entre o salga junto con el bloque.
func revertSpan(hunk: DiffHunk, baseCount: Int) -> RevertSpan {
    let lower = hunk.newRange.lowerBound
    guard hunk.oldRange.upperBound >= baseCount else {
        return RevertSpan(start: .lineStart(lower), end: .lineStart(hunk.newRange.upperBound))
    }
    return RevertSpan(start: lower > 0 ? .lineEnd(lower - 1) : .lineStart(0), end: .documentEnd)
}

/// Líneas base del hunk unidas con `eol`, para el tramo de `revertSpan`.
func revertedText(base: [Substring], hunk: DiffHunk, eol: String) -> String {
    let lines = hunk.oldRange.clamped(to: 0..<base.count).map { base[$0] }
    if hunk.oldRange.upperBound < base.count {
        return lines.map { $0 + eol }.joined()
    }
    if lines.isEmpty { return "" }
    let body = lines.joined(separator: eol)
    return hunk.newRange.lowerBound > 0 ? eol + body : body
}
