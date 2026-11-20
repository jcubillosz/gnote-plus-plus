import AppKit
import Scintilla

extension TabsViewModel {
    /// Confirmación con conteos y ejecución; después re-ejecuta la búsqueda para que la lista no
    /// muestre coincidencias que ya no existen. Leer, decodificar y escribir los archivos cerrados
    /// va en una cola de fondo (cerca del tope de resultados bloqueaba la app); los documentos
    /// abiertos se cuentan y editan en el hilo principal porque pasan por Scintilla.
    func confirmAndReplaceInFiles(rerun: @escaping (URL) -> Void) {
        let model = findInFiles
        guard !model.isReplacing, let snap = model.snapshot, !model.snapshotIsStale,
              let regex = FindInFilesViewModel.makeRegex(query: snap.query, matchCase: snap.matchCase,
                                                         wholeWord: snap.wholeWord, useRegex: snap.useRegex) else { return }
        let template = replacementTemplate(model.replacement, useRegex: snap.useRegex)
        let candidates = model.results.map { result -> ReplaceCandidate in
            switch result.source {
            case .document(let id):
                return ReplaceCandidate(target: .document(id), count: result.matches.count, isSelected: result.isSelected)
            case .file(let url):
                return ReplaceCandidate(target: .file(url, result.stamp), count: result.matches.count, isSelected: result.isSelected)
            }
        }
        let initial = buildReplacePlan(candidates) { url in
            let path = canonicalFilePath(url)
            return self.documents.first { $0.url.map(canonicalFilePath) == path }?.id
        }
        let openOutcomes = recountOpenDocuments(initial, regex: regex)
        model.setReplacing(true)
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = recountPlan(initial, open: { openOutcomes[$0] }, closed: { Self.recountClosedFile($0, regex: regex) })
            DispatchQueue.main.async {
                model.setReplacing(false)
                self.confirmReplacePlan(plan, snapshot: snap, regex: regex, template: template, rerun: rerun)
            }
        }
    }

    private func confirmReplacePlan(_ plan: ReplacePlan, snapshot snap: SearchSnapshot, regex: NSRegularExpression,
                                    template: String, rerun: @escaping (URL) -> Void) {
        let model = findInFiles
        guard !plan.isEmpty else {
            if !plan.omitted.isEmpty { showReplaceSkips(plan.omitted) }
            return
        }
        let openCount = plan.openMatchCount, openFiles = plan.openDocs.count
        let closedCount = plan.closedMatchCount, closedFiles = plan.closedFiles.count
        let alert = NSAlert()
        alert.messageText = L("¿Reemplazar \(openCount + closedCount) coincidencias en \(openFiles + closedFiles) archivos?")
        var detail = L("Documentos abiertos: \(openCount) coincidencias en \(openFiles) (se puede deshacer en cada pestaña).")
        if closedFiles > 0 {
            detail += "\n" + L("Archivos cerrados: \(closedCount) coincidencias en \(closedFiles). Se escriben a disco y no se puede deshacer.")
        }
        if model.truncated {
            detail += "\n" + L("La búsqueda se cortó en el límite de resultados: los archivos no listados no se modifican.")
        }
        if !plan.omitted.isEmpty {
            detail += "\n\n" + L("Se omitirán:") + "\n" + skipLines(plan.omitted).joined(separator: "\n")
        }
        alert.informativeText = detail
        alert.addButton(withTitle: L("Reemplazar"))
        alert.addButton(withTitle: L("Cancelar"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var skipped = replaceInOpenDocuments(plan, regex: regex, template: template)
        model.setReplacing(true)
        let closed = plan.closedFiles
        DispatchQueue.global(qos: .userInitiated).async {
            var closedSkips: [(URL, ReplaceSkip)] = []
            for (url, _, stamp) in closed {
                if let skip = replaceInClosedFile(url, regex: regex, template: template, expectedStamp: stamp,
                                                  decode: Self.decodeForReplace) {
                    closedSkips.append((url, skip))
                }
            }
            DispatchQueue.main.async {
                model.setReplacing(false)
                skipped += closedSkips
                if !skipped.isEmpty { self.showReplaceSkips(skipped) }
                if let root = snap.root {
                    rerun(root)
                } else {
                    model.clear()
                    model.setSummary(L("Reemplazo terminado"))
                }
            }
        }
    }

    /// Los conteos de la búsqueda pueden estar recortados (tope de resultados) o venir del disco
    /// para pestañas con cambios sin guardar: el diálogo muestra lo que de verdad se reemplaza.
    /// Las bloqueadas se omiten, así que no cuentan.
    private func recountOpenDocuments(_ plan: ReplacePlan, regex: NSRegularExpression) -> [UUID: (url: URL, outcome: RecountOutcome)] {
        var outcomes: [UUID: (url: URL, outcome: RecountOutcome)] = [:]
        for (id, _) in plan.openDocs {
            guard let document = documents.first(where: { $0.id == id }) else { continue }
            let url = document.url ?? URL(fileURLWithPath: document.displayName)
            outcomes[id] = document.isLocked
                ? (url, .skip(.locked))
                : (url, .count(countReplaceable(in: text(of: document), regex: regex)))
        }
        return outcomes
    }

    /// Lo que no se puede decodificar sin perder bytes se omitiría al escribir: no cuenta.
    private static func recountClosedFile(_ url: URL, regex: NSRegularExpression) -> RecountOutcome {
        guard let data = try? Data(contentsOf: url.resolvingSymlinksInPath()) else {
            return .skip(.writeFailed(L("No se pudo leer el archivo")))
        }
        guard let decoded = decodeForReplace(data) else { return .skip(.undecodable) }
        return .count(countReplaceable(in: decoded.text, regex: regex))
    }

    /// El bloqueo se vuelve a mirar: pudo cambiar mientras el diálogo estaba abierto.
    private func replaceInOpenDocuments(_ plan: ReplacePlan, regex: NSRegularExpression, template: String) -> [(URL, ReplaceSkip)] {
        var skipped: [(URL, ReplaceSkip)] = []
        for (id, _) in plan.openDocs {
            guard let document = documents.first(where: { $0.id == id }) else { continue }
            if document.isLocked {
                skipped.append((document.url ?? URL(fileURLWithPath: document.displayName), .locked))
                continue
            }
            replaceInOpenDocument(document, regex: regex, template: template)
        }
        return skipped
    }

    /// Solo se acepta un decodificado que vuelve a dar exactamente los mismos bytes: los respaldos
    /// de decodeWithDetectedEncoding (UTF-8 con U+FFFD, UTF-16BE que vuelve como LE) cambiarían
    /// partes del archivo que el reemplazo no toca.
    static func decodeForReplace(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        guard !data.prefix(8192).contains(0) else { return nil }
        let decoded = decodeWithDetectedEncoding(data)
        let hadBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
        guard encodeForWrite(decoded.text, encoding: decoded.encoding, hadBOM: hadBOM) == data else { return nil }
        return (decoded.text, decoded.encoding)
    }

    /// Por el editor (una acción de deshacer). Los no activos van por el lector oculto: cambiar el
    /// documento del editor visible movería la pestaña activa.
    private func replaceInOpenDocument(_ document: Document, regex: NSRegularExpression, template: String) {
        let isActive = document === activeDocument
        let changed = withDocumentView(document) { view -> Bool in
            let text = currentText(view)
            let utf16 = text.utf16
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: utf16.count))
                .filter { $0.range.length > 0 }
            guard !matches.isEmpty else { return false }
            // Offsets UTF-8 desde UTF-16 por escalares: Range(_:in:) exige bordes de Character y
            // descartaba en silencio coincidencias dentro de un CRLF.
            func byteOffset(_ utf16Offset: Int) -> Int {
                text.utf8.distance(from: text.startIndex, to: String.Index(utf16Offset: utf16Offset, in: text))
            }
            _ = ScintillaView.directCall(view, message: SCI_BEGINUNDOACTION, wParam: 0, lParam: 0)
            // De atrás hacia adelante: las posiciones en bytes de las anteriores siguen valiendo.
            for match in matches.reversed() {
                let start = byteOffset(match.range.location)
                let end = byteOffset(match.range.location + match.range.length)
                let replacement = regex.replacementString(for: match, in: text, offset: 0, template: template)
                _ = ScintillaView.directCall(view, message: SCI_SETTARGETRANGE, wParam: UInt(start), lParam: end)
                replacement.withCString { cstr in
                    _ = ScintillaView.directCall(view, message: SCI_REPLACETARGET, wParam: UInt(replacement.utf8.count),
                                                 lParam: Int(bitPattern: cstr))
                }
            }
            _ = ScintillaView.directCall(view, message: SCI_ENDUNDOACTION, wParam: 0, lParam: 0)
            return true
        }
        if changed && !isActive {
            // Las notificaciones de savepoint del lector oculto no llegan a ningún delegado.
            document.isDirty = true
            document.backupPending = true
            objectWillChange.send()
        }
    }

    private func skipLines(_ skipped: [(URL, ReplaceSkip)]) -> [String] {
        skipped.sorted { $0.0.path < $1.0.path }.map { url, skip -> String in
            let reason: String
            switch skip {
            case .changedOnDisk: reason = L("cambió en disco desde la búsqueda")
            case .encoding: reason = L("el texto nuevo no se puede representar en su codificación")
            case .undecodable: reason = L("su codificación no se puede leer sin perder bytes")
            case .locked: reason = L("el documento está bloqueado")
            case .writeFailed(let message): reason = message
            }
            return "\(url.lastPathComponent): \(reason)"
        }
    }

    private func showReplaceSkips(_ skipped: [(URL, ReplaceSkip)]) {
        let alert = NSAlert()
        alert.messageText = L("Se omitieron \(skipped.count) archivos")
        alert.informativeText = skipLines(skipped).joined(separator: "\n")
        alert.runModal()
    }
}
