import Foundation

// Parser CSV/TSV puro (RFC 4180, tolerante). Trabaja sobre bytes UTF-8: los rangos crudos de
// cada fila son offsets de Scintilla y "Ordenar documento" reordena esos bytes sin re-serializar.

struct CSVRow: Equatable {
    let fields: [String]
    /// Bytes UTF-8 de la fila en el documento, incluido su fin de línea (si lo tiene).
    let rawRange: Range<Int>
    /// Línea (0-based) donde empieza la fila; un campo con saltos entre comillas ocupa varias.
    let line: Int
}

struct CSVTable: Equatable {
    let rows: [CSVRow]
    let truncated: Bool
    let unterminatedQuote: Bool
}

private let quoteByte = UInt8(ascii: "\"")
private let crByte = UInt8(ascii: "\r")
private let lfByte = UInt8(ascii: "\n")

func detectDelimiter(_ sample: String, fileExtension: String?) -> Character {
    let ext = fileExtension?.lowercased()
    if ext == "tsv" || ext == "tab" { return "\t" }
    let candidates: [Character] = [",", ";", "\t", "|"]
    // Conteo por línea fuera de comillas, primeras 50 líneas lógicas.
    var counts: [[Int]] = Array(repeating: [], count: candidates.count)
    var current = Array(repeating: 0, count: candidates.count)
    var inQuote = false
    var lines = 0
    var sawContent = false
    let bytes = Array(sample.utf8.prefix(256 * 1024))
    var i = 0
    func endLine() {
        if sawContent { for c in 0..<candidates.count { counts[c].append(current[c]) } ; lines += 1 }
        current = Array(repeating: 0, count: candidates.count)
        sawContent = false
    }
    while i < bytes.count, lines < 50 {
        let b = bytes[i]
        if b == quoteByte {
            inQuote.toggle()
            sawContent = true
        } else if !inQuote, b == lfByte || b == crByte {
            endLine()
            if b == crByte, i + 1 < bytes.count, bytes[i + 1] == lfByte { i += 1 }
        } else {
            sawContent = true
            if !inQuote, let c = candidates.firstIndex(where: { $0.asciiValue == b }) { current[c] += 1 }
        }
        i += 1
    }
    if lines < 50 { endLine() }
    var best: Character = ","
    var bestScore = 0
    var bestCount = 0
    for (c, perLine) in counts.enumerated() {
        guard let first = perLine.first, first > 0 else { continue }
        let score = perLine.filter { $0 == first }.count
        if score > bestScore || (score == bestScore && first > bestCount) {
            best = candidates[c]
            bestScore = score
            bestCount = first
        }
    }
    return best
}

func parseCSV(_ text: String, delimiter: Character, maxBytes: Int = 5_000_000, maxRows: Int = 100_000) -> CSVTable {
    let delim = delimiter.asciiValue ?? UInt8(ascii: ",")
    var rows: [CSVRow] = []
    var truncated = false
    var unterminated = false
    var utf8 = Array(text.utf8)
    if utf8.count > maxBytes {
        utf8 = Array(utf8.prefix(maxBytes))
        truncated = true
    }
    let n = utf8.count
    var i = 0
    var line = 0
    while i < n {
        if rows.count >= maxRows { truncated = true; break }
        let rowStart = i
        let rowLine = line
        var fields: [String] = []
        var field: [UInt8] = []
        var inQuote = false
        var atFieldStart = true
        var ended = false
        while i < n {
            let b = utf8[i]
            if inQuote {
                if b == quoteByte {
                    if i + 1 < n, utf8[i + 1] == quoteByte { field.append(quoteByte); i += 2; continue }
                    inQuote = false
                    i += 1
                    continue
                }
                if b == lfByte || b == crByte {
                    if b == crByte, i + 1 < n, utf8[i + 1] == lfByte { field.append(crByte); i += 1 }
                    line += 1
                }
                field.append(utf8[i])
                i += 1
                continue
            }
            if b == quoteByte, atFieldStart {
                inQuote = true
                atFieldStart = false
                i += 1
                continue
            }
            if b == delim {
                fields.append(String(decoding: field, as: UTF8.self))
                field.removeAll(keepingCapacity: true)
                atFieldStart = true
                i += 1
                continue
            }
            if b == lfByte || b == crByte {
                i += (b == crByte && i + 1 < n && utf8[i + 1] == lfByte) ? 2 : 1
                line += 1
                ended = true
                break
            }
            field.append(b)
            atFieldStart = false
            i += 1
        }
        // Truncado por bytes: la última fila puede estar cortada a la mitad; se descarta.
        if truncated, !ended, i >= n, !rows.isEmpty || inQuote { break }
        if inQuote { unterminated = true }
        fields.append(String(decoding: field, as: UTF8.self))
        rows.append(CSVRow(fields: fields, rawRange: rowStart..<i, line: rowLine))
    }
    return CSVTable(rows: rows, truncated: truncated, unterminatedQuote: unterminated)
}

private func csvNumber(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return nil }
    return Double(t)
}

func guessHasHeader(_ table: CSVTable) -> Bool {
    guard let first = table.rows.first, table.rows.count > 1 else { return false }
    let fields = first.fields.map { $0.trimmingCharacters(in: .whitespaces) }
    guard fields.allSatisfy({ !$0.isEmpty && csvNumber($0) == nil }) else { return false }
    return Set(fields).count == fields.count
}

/// Índices (en `table.rows`) de las filas de datos ordenadas; el encabezado queda fuera.
func sortedRowIndices(_ table: CSVTable, column: Int, ascending: Bool, skipHeader: Bool) -> [Int] {
    let start = skipHeader ? min(1, table.rows.count) : 0
    let keys: [(Int, String, Double?)] = (start..<table.rows.count).map { index in
        let fields = table.rows[index].fields
        let value = column < fields.count ? fields[column] : ""
        return (index, value, csvNumber(value))
    }
    // Estable: a igualdad se conserva el orden original.
    let sorted = keys.enumerated().sorted { lhs, rhs in
        let a = lhs.element, b = rhs.element
        let result: ComparisonResult
        if let x = a.2, let y = b.2 {
            result = x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        } else {
            result = a.1.localizedStandardCompare(b.1)
        }
        if result == .orderedSame { return lhs.offset < rhs.offset }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }
    return sorted.map { $0.element.0 }
}

/// Reordena las filas crudas (comillas y EOL originales). `order` son índices de filas de datos.
func reorderedDocument(_ text: String, table: CSVTable, order: [Int], skipHeader: Bool, eol: String) -> String {
    let bytes = Array(text.utf8)
    guard let firstRow = table.rows.first, let lastRow = table.rows.last else { return text }
    let eolBytes = Array(eol.utf8)
    func hasEOL(_ range: Range<Int>) -> Bool {
        guard let last = range.last else { return false }
        return bytes[last] == lfByte || bytes[last] == crByte
    }
    func stripEOL(_ raw: [UInt8]) -> [UInt8] {
        var raw = raw
        if raw.last == lfByte { raw.removeLast() }
        if raw.last == crByte { raw.removeLast() }
        return raw
    }
    let originalEndsWithEOL = hasEOL(lastRow.rawRange)
    var sequence: [Int] = []
    if skipHeader { sequence.append(0) }
    sequence += order
    var out = Array(bytes[0..<firstRow.rawRange.lowerBound])
    for (position, index) in sequence.enumerated() {
        var raw = Array(bytes[table.rows[index].rawRange])
        let isLast = position == sequence.count - 1
        if !isLast, !hasEOL(table.rows[index].rawRange) { raw += eolBytes }
        if isLast, !originalEndsWithEOL { raw = stripEOL(raw) }
        out += raw
    }
    out += bytes[lastRow.rawRange.upperBound...]
    return String(decoding: out, as: UTF8.self)
}

/// Offset (bytes, relativo al inicio de la fila) donde empieza el campo `column`.
func csvFieldByteOffset(_ raw: ArraySlice<UInt8>, column: Int, delimiter: Character) -> Int {
    let delim = delimiter.asciiValue ?? UInt8(ascii: ",")
    var seen = 0
    var inQuote = false
    for (offset, b) in raw.enumerated() {
        if seen == column { return offset }
        if b == quoteByte { inQuote.toggle() } else if !inQuote, b == delim { seen += 1; if seen == column { return offset + 1 } }
        else if !inQuote, b == lfByte || b == crByte { break }
    }
    return 0
}

/// Orden para "Ordenar documento", o nil si no se puede: truncado (no se ve todo), comilla sin
/// cerrar (la última fila se tragaría el resto del archivo) o sin filas que ordenar.
func documentSortOrder(_ table: CSVTable, column: Int, ascending: Bool, skipHeader: Bool) -> [Int]? {
    guard !table.truncated, !table.unterminatedQuote, table.rows.count > 1 else { return nil }
    return sortedRowIndices(table, column: column, ascending: ascending, skipHeader: skipHeader)
}
