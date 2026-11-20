import Foundation

/// Lógica pura de Reemplazar en archivos (sin AppKit/Scintilla: se prueba con swiftc suelto).

/// Plantilla para NSRegularExpression: sin regex, `$` y `\` del reemplazo son literales.
func replacementTemplate(_ replacement: String, useRegex: Bool) -> String {
    useRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
}

/// Coincidencias vacías no cuentan ni se reemplazan, igual que en la búsqueda (matchesIn).
func replaceAll(in text: String, regex: NSRegularExpression, template: String) -> (text: String, count: Int) {
    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter { $0.range.length > 0 }
    guard !matches.isEmpty else { return (text, 0) }
    let result = NSMutableString(string: ns)
    for match in matches.reversed() {
        let replacement = regex.replacementString(for: match, in: text, offset: 0, template: template)
        result.replaceCharacters(in: match.range, with: replacement)
    }
    return (result as String, matches.count)
}

/// `nil` si el texto no es representable en el encoding original: no se convierte.
/// UTF-8 con BOM: el texto decodificado ya trae U+FEFF, así que solo se repone si falta.
func encodeForWrite(_ text: String, encoding: String.Encoding, hadBOM: Bool) -> Data? {
    guard var data = text.data(using: encoding, allowLossyConversion: false) else { return nil }
    let bom = Data([0xEF, 0xBB, 0xBF])
    if hadBOM, encoding == .utf8, !data.starts(with: bom) { data = bom + data }
    return data
}

/// Búsqueda que produjo los resultados vigentes: el reemplazo usa esta, no los campos editables
/// (cambiarlos sin volver a buscar aplicaría otro patrón a archivos elegidos por el anterior).
struct SearchSnapshot: Equatable {
    let query: String
    let matchCase: Bool
    let wholeWord: Bool
    let useRegex: Bool
    /// Carpeta buscada; nil en Buscar todo (documento/abiertos).
    let root: URL?

    func matches(query: String, matchCase: Bool, wholeWord: Bool, useRegex: Bool) -> Bool {
        self.query == query && self.matchCase == matchCase && self.wholeWord == wholeWord && self.useRegex == useRegex
    }
}

/// Mismo criterio que replaceAll: lo que se cuenta es lo que se reemplaza.
func countReplaceable(in text: String, regex: NSRegularExpression) -> Int {
    regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).filter { $0.range.length > 0 }.count
}

struct ReplacePlan {
    var openDocs: [(UUID, Int)] = []
    var closedFiles: [(URL, Int, FileStamp)] = []
    /// Lo que se sabe de antemano que no se va a tocar: fuera de los conteos, listado en el diálogo.
    var omitted: [(URL, ReplaceSkip)] = []
    var openMatchCount: Int { openDocs.reduce(0) { $0 + $1.1 } }
    var closedMatchCount: Int { closedFiles.reduce(0) { $0 + $1.1 } }
    var isEmpty: Bool { openDocs.isEmpty && closedFiles.isEmpty }
}

enum ReplaceSkip: Equatable {
    case changedOnDisk, encoding, undecodable, locked, writeFailed(String)
}

enum RecountOutcome: Equatable {
    case count(Int)
    case skip(ReplaceSkip)
}

/// Rehace los conteos del plan con lo que de verdad se va a reemplazar. `open` devuelve nil si la
/// pestaña ya no existe; los conteos en 0 salen del plan.
func recountPlan(_ plan: ReplacePlan, open: (UUID) -> (url: URL, outcome: RecountOutcome)?,
                 closed: (URL) -> RecountOutcome) -> ReplacePlan {
    var result = ReplacePlan()
    for (id, _) in plan.openDocs {
        guard let entry = open(id) else { continue }
        switch entry.outcome {
        case .count(let n): if n > 0 { result.openDocs.append((id, n)) }
        case .skip(let skip): result.omitted.append((entry.url, skip))
        }
    }
    for (url, _, stamp) in plan.closedFiles {
        switch closed(url) {
        case .count(let n): if n > 0 { result.closedFiles.append((url, n, stamp)) }
        case .skip(let skip): result.omitted.append((url, skip))
        }
    }
    return result
}

struct ReplaceCandidate {
    enum Target {
        case document(UUID)
        /// Stamp tomado al buscar; nil = no se pudo leer (se omite: no hay con qué comparar).
        case file(URL, FileStamp?)
    }
    let target: Target
    let count: Int
    let isSelected: Bool
}

/// Un archivo abierto en una pestaña va por el editor aunque el resultado venga de disco: escribir
/// por detrás dejaría la pestaña con el texto viejo.
func buildReplacePlan(_ candidates: [ReplaceCandidate], openDocument: (URL) -> UUID?) -> ReplacePlan {
    var plan = ReplacePlan()
    var openIndex: [UUID: Int] = [:]
    func addOpen(_ id: UUID, _ count: Int) {
        if let i = openIndex[id] { plan.openDocs[i].1 += count } else {
            openIndex[id] = plan.openDocs.count
            plan.openDocs.append((id, count))
        }
    }
    for candidate in candidates where candidate.isSelected && candidate.count > 0 {
        switch candidate.target {
        case .document(let id):
            addOpen(id, candidate.count)
        case .file(let url, let stamp):
            if let id = openDocument(url) { addOpen(id, candidate.count) }
            else if let stamp { plan.closedFiles.append((url, candidate.count, stamp)) }
        }
    }
    return plan
}

/// Reemplaza en un archivo cerrado. nil = escrito (o sin coincidencias); si no, por qué se omitió.
func replaceInClosedFile(_ url: URL, regex: NSRegularExpression, template: String, expectedStamp: FileStamp,
                         decode: (Data) -> (text: String, encoding: String.Encoding)?) -> ReplaceSkip? {
    guard FileStamp.of(url) == expectedStamp else { return .changedOnDisk }
    // .atomic sobre el enlace lo reemplazaría por un archivo normal: se escribe en el destino real.
    let target = url.resolvingSymlinksInPath()
    guard let data = try? Data(contentsOf: target) else { return .writeFailed(L("No se pudo leer el archivo")) }
    guard let decoded = decode(data) else { return .encoding }
    let result = replaceAll(in: decoded.text, regex: regex, template: template)
    guard result.count > 0 else { return nil }
    let hadBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
    guard let output = encodeForWrite(result.text, encoding: decoded.encoding, hadBOM: hadBOM) else { return .encoding }
    do {
        try output.write(to: target, options: .atomic)
        return nil
    } catch {
        return .writeFailed(error.localizedDescription)
    }
}
