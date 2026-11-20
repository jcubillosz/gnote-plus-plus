// Lógica pura del probador de expresiones regulares (sin AppKit ni Scintilla).
import Foundation

struct RegexOptions: Equatable {
    var caseInsensitive: Bool
    var anchorsMatchLines: Bool
    var dotAll: Bool
}

struct RegexGroupMatch: Equatable {
    let index: Int
    let name: String?
    /// Bytes UTF-8 (posiciones de Scintilla); nil si el grupo no participó.
    let range: Range<Int>?
    let value: String?
}

struct RegexMatchResult: Equatable {
    /// Bytes UTF-8.
    let range: Range<Int>
    let groups: [RegexGroupMatch]
}

enum RegexRunOutcome: Equatable {
    case ok([RegexMatchResult], truncated: Bool)
    case invalid(String)
    case timedOut([RegexMatchResult])
}

/// `Result` exige `Error`: el mensaje del compilador va envuelto.
struct RegexCompileError: Error, Equatable { let message: String }

func compileTestRegex(_ pattern: String, _ options: RegexOptions) -> Result<NSRegularExpression, RegexCompileError> {
    var opts: NSRegularExpression.Options = []
    if options.caseInsensitive { opts.insert(.caseInsensitive) }
    if options.anchorsMatchLines { opts.insert(.anchorsMatchLines) }
    if options.dotAll { opts.insert(.dotMatchesLineSeparators) }
    do {
        return .success(try NSRegularExpression(pattern: pattern, options: opts))
    } catch {
        return .failure(RegexCompileError(message: (error as NSError).localizedDescription))
    }
}

/// Tabla índice UTF-16 → byte UTF-8, con una entrada extra para el final. La mitad baja de un
/// par subrogado apunta al inicio del escalar (un rango nunca debería caer ahí).
func utf8Offsets(_ text: String) -> [Int] {
    var table: [Int] = []
    table.reserveCapacity(text.utf16.count + 1)
    var byte = 0
    for scalar in text.unicodeScalars {
        let units = scalar.utf16.count
        for _ in 0..<units { table.append(byte) }
        byte += scalar.utf8.count
    }
    table.append(byte)
    return table
}

/// Nombres de grupos `(?<nombre>…)` por número de grupo. Cuenta solo grupos de captura:
/// ignora escapes, clases `[...]` y grupos `(?:…)`, `(?=…)`, `(?<=…)`, etc.
func groupNames(in pattern: String) -> [Int: String] {
    let chars = Array(pattern)
    var result: [Int: String] = [:]
    var number = 0
    var i = 0
    var inClass = false
    while i < chars.count {
        let c = chars[i]
        if c == "\\" { i += 2; continue }
        if inClass { if c == "]" { inClass = false }; i += 1; continue }
        if c == "[" { inClass = true; i += 1; continue }
        if c == "(" {
            if i + 1 < chars.count, chars[i + 1] == "?" {
                // (?<nombre> o (?P<nombre> = captura con nombre; (?<= y (?<! son lookbehind.
                var j = i + 2
                if j < chars.count, chars[j] == "P" { j += 1 }
                if j < chars.count, chars[j] == "<" || chars[j] == "'", j + 1 < chars.count,
                   chars[j + 1] != "=", chars[j + 1] != "!" {
                    let close: Character = chars[j] == "<" ? ">" : "'"
                    var k = j + 1
                    var name = ""
                    while k < chars.count, chars[k] != close { name.append(chars[k]); k += 1 }
                    number += 1
                    result[number] = name
                }
            } else {
                number += 1
            }
        }
        i += 1
    }
    return result
}

/// Corre la regex sobre `text`. El plazo se revisa en cada coincidencia y en los avisos de
/// progreso, pero NO corta un backtracking catastrófico dentro de un intento de match
/// (NSRegularExpression no se puede interrumpir): para eso está el vigía de `SerialRegexWorker`.
func runRegex(_ regex: NSRegularExpression, text: String, maxMatches: Int, deadline: Date) -> RegexRunOutcome {
    let ns = text as NSString
    let offsets = utf8Offsets(text)
    let names = groupNames(in: regex.pattern)
    var results: [RegexMatchResult] = []
    var truncated = false
    var timedOut = false
    if Date() >= deadline { return .timedOut([]) }
    regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: ns.length)) { match, _, stop in
        if Date() >= deadline { timedOut = true; stop.pointee = true; return }
        guard let match else { return }
        if results.count >= maxMatches { truncated = true; stop.pointee = true; return }
        var groups: [RegexGroupMatch] = []
        for g in 0..<match.numberOfRanges {
            let r = match.range(at: g)
            if r.location == NSNotFound {
                groups.append(RegexGroupMatch(index: g, name: names[g], range: nil, value: nil))
            } else {
                groups.append(RegexGroupMatch(index: g, name: names[g],
                                              range: offsets[r.location]..<offsets[r.location + r.length],
                                              value: ns.substring(with: r)))
            }
        }
        let whole = match.range
        results.append(RegexMatchResult(range: offsets[whole.location]..<offsets[whole.location + whole.length], groups: groups))
    }
    if timedOut { return .timedOut(results) }
    return .ok(results, truncated: truncated)
}

/// Una sola corrida en vuelo: un patrón desbocado no se puede matar, así que lanzar otra por
/// cada tecla acumularía hilos girando. Mientras hay una en curso, solo se guarda el último
/// pedido. El vigía avisa del plazo vencido aunque el trabajador siga girando.
/// Todo el estado vive en `callbackQueue` (main en la app): `submit`/`cancel` se llaman desde ahí.
final class SerialRegexWorker {
    private let workQueue = DispatchQueue(label: "gnote.regex-tester", qos: .userInitiated)
    private let callbackQueue: DispatchQueue
    private(set) var startedRuns = 0
    private(set) var isBusy = false
    private var generation = 0
    private var delivered = Set<Int>()
    private var pending: (generation: Int, job: () -> RegexRunOutcome, onResult: (RegexRunOutcome) -> Void)?

    init(callbackQueue: DispatchQueue = .main) { self.callbackQueue = callbackQueue }

    /// `onTimeout` corre si no llegó resultado de este pedido a los `timeLimit` s; `onResult` solo
    /// si sigue siendo el pedido vigente. Ambos en `callbackQueue`.
    func submit(timeLimit: TimeInterval, job: @escaping () -> RegexRunOutcome,
                onTimeout: @escaping () -> Void, onResult: @escaping (RegexRunOutcome) -> Void) {
        generation += 1
        let current = generation
        delivered.removeAll()
        callbackQueue.asyncAfter(deadline: .now() + timeLimit) { [weak self] in
            guard let self, self.generation == current, !self.delivered.contains(current) else { return }
            onTimeout()
        }
        if isBusy {
            pending = (current, job, onResult)
        } else {
            start(current, job, onResult)
        }
    }

    /// Descarta el pedido vigente y el encolado; una corrida en curso termina sola y se ignora.
    func cancel() {
        generation += 1
        pending = nil
    }

    private func start(_ gen: Int, _ job: @escaping () -> RegexRunOutcome, _ onResult: @escaping (RegexRunOutcome) -> Void) {
        isBusy = true
        startedRuns += 1
        workQueue.async { [weak self] in
            let outcome = job()
            guard let self else { return }
            self.callbackQueue.async {
                self.isBusy = false
                if gen == self.generation {
                    self.delivered.insert(gen)
                    onResult(outcome)
                }
                if let next = self.pending {
                    self.pending = nil
                    if next.generation == self.generation { self.start(next.generation, next.job, next.onResult) }
                }
            }
        }
    }
}
