import Foundation

// MARK: - Diff de líneas (puro)

enum LineChange: Equatable {
    case added(Range<Int>)
    case modified(Range<Int>)
    /// Línea del documento nuevo que sigue a lo borrado (puede ser igual a la cantidad de líneas).
    case deleted(atLine: Int)
}

/// Líneas como las numera Scintilla: separadas por LF, CRLF o CR, y la parte tras el último
/// salto cuenta como línea aunque esté vacía. Se recorre por bytes UTF-8: en Swift "\r\n" es un
/// solo Character y partir por Character no lo vería.
func gitLines(_ text: String) -> [Substring] {
    var lines: [Substring] = []
    let utf8 = text.utf8
    var start = utf8.startIndex
    var index = start
    while index != utf8.endIndex {
        let byte = utf8[index]
        if byte == 0x0A || byte == 0x0D {
            lines.append(text[start..<index])
            var next = utf8.index(after: index)
            if byte == 0x0D, next != utf8.endIndex, utf8[next] == 0x0A { next = utf8.index(after: next) }
            start = next
            index = next
        } else {
            index = utf8.index(after: index)
        }
    }
    lines.append(text[start..<utf8.endIndex])
    return lines
}

/// Más allá de esta distancia de edición el diff fino no vale lo que cuesta (memoria cuadrática
/// en D): el tramo entre el primer y el último cambio se marca entero.
private let maxEditDistance = 2000

struct DiffHunk: Equatable {
    let oldRange: Range<Int>
    let newRange: Range<Int>
}

/// Myers (greedy, con la traza por paso para reconstruir el camino). Antes se recortan prefijo y
/// sufijo comunes, y las líneas se comparan como enteros internados. Si Myers se rinde
/// (`maxEditDistance`), un solo hunk cubre todo lo que hay entre prefijo y sufijo comunes.
func diffHunks(old: [Substring], new: [Substring]) -> [DiffHunk] {
    var prefix = 0
    while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < old.count - prefix, suffix < new.count - prefix,
          old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
    let oldMiddle = old[prefix..<(old.count - suffix)]
    let newMiddle = new[prefix..<(new.count - suffix)]
    if oldMiddle.isEmpty && newMiddle.isEmpty { return [] }

    var ids: [Substring: Int32] = [:]
    func intern(_ lines: ArraySlice<Substring>) -> [Int32] {
        lines.map { line in
            if let id = ids[line] { return id }
            let id = Int32(ids.count)
            ids[line] = id
            return id
        }
    }
    let a = intern(oldMiddle), b = intern(newMiddle)

    guard let operations = myers(a, b) else {
        return [DiffHunk(oldRange: prefix..<(prefix + a.count), newRange: prefix..<(prefix + b.count))]
    }
    var hunks: [DiffHunk] = []
    var oldLine = prefix, newLine = prefix
    var oldStart = prefix, newStart = prefix
    func flush() {
        if oldLine > oldStart || newLine > newStart {
            hunks.append(DiffHunk(oldRange: oldStart..<oldLine, newRange: newStart..<newLine))
        }
    }
    for operation in operations {
        switch operation {
        case .equal:
            flush()
            oldLine += 1
            newLine += 1
            oldStart = oldLine
            newStart = newLine
        case .delete:
            oldLine += 1
        case .insert:
            newLine += 1
        }
    }
    flush()
    return hunks
}

/// Rangos de líneas 0-based del documento nuevo; `deleted(atLine:)` = línea siguiente al borrado.
func diffLines(old: [Substring], new: [Substring]) -> [LineChange] {
    lineChanges(diffHunks(old: old, new: new))
}

/// Lo mismo que `diffLines` a partir de hunks ya calculados (GitGutter los conserva para el blame).
func lineChanges(_ hunks: [DiffHunk]) -> [LineChange] {
    hunks.flatMap {
        hunkChanges(start: $0.newRange.lowerBound, deleted: $0.oldRange.count, inserted: $0.newRange.count)
    }
}

/// Un hunk con borradas y agregadas: las primeras min(borradas, agregadas) son "modificadas" y
/// el resto de las agregadas, "agregadas" (las borradas de más no tienen línea donde marcarse).
private func hunkChanges(start: Int, deleted: Int, inserted: Int) -> [LineChange] {
    if inserted == 0 { return [.deleted(atLine: start)] }
    if deleted == 0 { return [.added(start..<(start + inserted))] }
    let modified = min(deleted, inserted)
    var result: [LineChange] = [.modified(start..<(start + modified))]
    if inserted > modified { result.append(.added((start + modified)..<(start + inserted))) }
    return result
}

private enum DiffOperation { case equal, delete, insert }

/// nil si la distancia de edición supera `maxEditDistance`.
private func myers(_ a: [Int32], _ b: [Int32]) -> [DiffOperation]? {
    let n = a.count, m = b.count
    let maxD = min(n + m, maxEditDistance)
    let offset = maxD + 1
    var v = [Int32](repeating: 0, count: 2 * maxD + 3)
    // trace[d] = v[-d-1 ... d+1] al empezar el paso d (lo que dejó el paso d-1).
    var trace: [[Int32]] = []
    var found = false
    search: for d in 0...maxD {
        trace.append(Array(v[(offset - d - 1)...(offset + d + 1)]))
        for k in stride(from: -d, through: d, by: 2) {
            var x: Int
            if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                x = Int(v[offset + k + 1])
            } else {
                x = Int(v[offset + k - 1]) + 1
            }
            var y = x - k
            while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
            v[offset + k] = Int32(x)
            if x >= n && y >= m { found = true; break search }
        }
    }
    guard found else { return nil }

    var operations: [DiffOperation] = []
    operations.reserveCapacity(n + m)
    var x = n, y = m
    for d in stride(from: trace.count - 1, through: 0, by: -1) {
        let snapshot = trace[d]
        func value(_ k: Int) -> Int { Int(snapshot[k + d + 1]) }
        let k = x - y
        let previousK = (k == -d || (k != d && value(k - 1) < value(k + 1))) ? k + 1 : k - 1
        let previousX = value(previousK)
        let previousY = previousX - previousK
        while x > previousX && y > previousY {
            operations.append(.equal)
            x -= 1; y -= 1
        }
        if d > 0 {
            operations.append(x == previousX ? .insert : .delete)
            x = previousX
            y = previousY
        }
    }
    operations.reverse()
    return operations
}
