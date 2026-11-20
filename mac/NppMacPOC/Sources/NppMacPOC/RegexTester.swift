// Probador de expresiones regulares: panel flotante, cómputo en segundo plano e indicadores
// 17 (coincidencias) y 18 (grupos de la seleccionada) sobre el documento activo.
import SwiftUI
import AppKit
import Scintilla

final class RegexTesterViewModel: ObservableObject {
    struct Row: Identifiable {
        let id: Int
        let line: Int
        let column: Int
        let text: String
        let match: RegexMatchResult
    }

    static let maxMatches = 5_000
    static let maxBytes = 10 * 1024 * 1024
    static let timeLimit: TimeInterval = 1

    @Published var pattern: String = "" { didSet { if pattern != oldValue { schedule() } } }
    @Published var options = RegexOptions(caseInsensitive: false, anchorsMatchLines: true, dotAll: false) {
        didSet { if options != oldValue { schedule() } }
    }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var error: String?
    @Published private(set) var truncated = false
    @Published private(set) var timedOut = false
    @Published private(set) var textCut = false
    @Published private(set) var totalMatches = 0
    @Published var selectedRow: Int? { didSet { if selectedRow != oldValue { selectionChanged() } } }

    weak var tabs: TabsViewModel?
    var isOpen = false
    private var generation = 0
    private var pending: DispatchWorkItem?
    private let worker = SerialRegexWorker()
    /// Documento sobre el que están pintados los indicadores.
    private var paintedDocument: UUID?
    /// Documentos que quedaron con indicadores pintados al cambiar de pestaña o cerrar el panel:
    /// los indicadores son del documento, así que se limpian cuando vuelve a estar activo.
    private var staleDocuments: Set<UUID> = []

    func schedule() {
        guard isOpen else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Edición o cambio de pestaña (llamado desde ContentView).
    func documentChanged() {
        guard let tabs, let id = tabs.activeDocument?.id else { return }
        if let painted = paintedDocument, painted != id {
            staleDocuments.insert(painted)
            paintedDocument = nil
        }
        if staleDocuments.remove(id) != nil { clearIndicators(tabs.editor) }
        schedule()
    }

    func close() {
        isOpen = false
        pending?.cancel()
        worker.cancel()
        generation += 1
        if let tabs, let painted = paintedDocument {
            if painted == tabs.activeDocument?.id { clearIndicators(tabs.editor) } else { staleDocuments.insert(painted) }
        }
        paintedDocument = nil
    }

    func runNow() {
        pending?.cancel()
        worker.cancel()
        generation += 1
        let current = generation
        guard let tabs, let document = tabs.activeDocument else { reset(error: nil); return }
        let editor = tabs.editor
        guard !pattern.isEmpty else {
            reset(error: nil)
            clearIndicators(editor)
            paintedDocument = document.id
            return
        }
        let regex: NSRegularExpression
        switch compileTestRegex(pattern, options) {
        case .success(let r): regex = r
        case .failure(let e):
            reset(error: e.message)
            clearIndicators(editor)
            paintedDocument = document.id
            return
        }
        var text = currentText(editor)
        var cut = false
        if text.utf8.count > Self.maxBytes {
            // Cortar en frontera de escalar: un byte de continuación (10xxxxxx) partiría un carácter.
            let bytes = Array(text.utf8)
            var end = Self.maxBytes
            while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
            text = String(decoding: bytes[..<end], as: UTF8.self)
            cut = true
        }
        let documentID = document.id
        let limit = Self.timeLimit
        let snapshot = text, wasCut = cut
        worker.submit(timeLimit: limit, job: {
            runRegex(regex, text: snapshot, maxMatches: Self.maxMatches, deadline: Date().addingTimeInterval(limit))
        }, onTimeout: { [weak self] in
            guard let self, self.generation == current, self.isOpen,
                  self.tabs?.activeDocument?.id == documentID else { return }
            self.apply(.timedOut([]), textCut: wasCut, documentID: documentID)
        }, onResult: { [weak self] outcome in
            guard let self, self.generation == current, self.isOpen,
                  self.tabs?.activeDocument?.id == documentID else { return }
            self.apply(outcome, textCut: wasCut, documentID: documentID)
        })
    }

    private func reset(error: String?) {
        self.error = error
        rows = []
        totalMatches = 0
        truncated = false
        timedOut = false
        textCut = false
        selectedRow = nil
    }

    private func apply(_ outcome: RegexRunOutcome, textCut: Bool, documentID: UUID) {
        guard let editor = tabs?.editor else { return }
        let matches: [RegexMatchResult]
        reset(error: nil)
        switch outcome {
        case .ok(let m, let t): matches = m; truncated = t
        case .timedOut(let m): matches = m; timedOut = true
        case .invalid(let e): matches = []; error = e
        }
        self.textCut = textCut
        totalMatches = matches.count
        clearIndicators(editor)
        _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_REGEX_TEST), lParam: 0)
        var built: [Row] = []
        built.reserveCapacity(matches.count)
        for (i, m) in matches.enumerated() {
            if !m.range.isEmpty {
                _ = ScintillaView.directCall(editor, message: SCI_INDICATORFILLRANGE, wParam: uptr_t(m.range.lowerBound), lParam: sptr_t(m.range.count))
            }
            let line = Int(ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(m.range.lowerBound), lParam: 0))
            let column = Int(ScintillaView.directCall(editor, message: SCI_GETCOLUMN, wParam: uptr_t(m.range.lowerBound), lParam: 0))
            let value = m.groups.first?.value ?? ""
            built.append(Row(id: i, line: line + 1, column: column + 1,
                             text: value.count > 200 ? String(value.prefix(200)) + "…" : value, match: m))
        }
        rows = built
        paintedDocument = documentID
    }

    private func selectionChanged() {
        guard let tabs, let index = selectedRow, index < rows.count,
              paintedDocument == tabs.activeDocument?.id else { return }
        let editor = tabs.editor
        let length = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
        let match = rows[index].match
        guard match.range.upperBound <= length else { return }
        _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_REGEX_GROUP), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_INDICATORCLEARRANGE, wParam: 0, lParam: sptr_t(length))
        for group in match.groups.dropFirst() {
            guard let r = group.range, !r.isEmpty, r.upperBound <= length else { continue }
            _ = ScintillaView.directCall(editor, message: SCI_INDICATORFILLRANGE, wParam: uptr_t(r.lowerBound), lParam: sptr_t(r.count))
        }
        _ = ScintillaView.directCall(editor, message: SCI_SETSEL, wParam: uptr_t(match.range.lowerBound), lParam: sptr_t(match.range.upperBound))
        _ = ScintillaView.directCall(editor, message: SCI_SCROLLCARET, wParam: 0, lParam: 0)
    }

    private func clearIndicators(_ editor: ScintillaView) {
        let length = sptr_t(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
        for indicator in [INDICATOR_REGEX_TEST, INDICATOR_REGEX_GROUP] {
            _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(indicator), lParam: 0)
            _ = ScintillaView.directCall(editor, message: SCI_INDICATORCLEARRANGE, wParam: 0, lParam: length)
        }
    }
}

final class RegexTesterPanel: NSObject, NSWindowDelegate {
    static let shared = RegexTesterPanel()
    let model = RegexTesterViewModel()
    private var panel: NSPanel?

    func show(tabs: TabsViewModel) {
        model.tabs = tabs
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.hidesOnDeactivate = true
            p.isReleasedWhenClosed = false
            p.title = L("Probar expresión regular")
            p.delegate = self
            p.contentView = NSHostingView(rootView: RegexTesterView(model: model, onUseInFind: { [weak tabs, weak model] in
                guard let tabs, let model else { return }
                tabs.find.usePattern(model.pattern, caseInsensitive: model.options.caseInsensitive)
            }))
            p.center()
            panel = p
        }
        model.isOpen = true
        model.runNow()
        panel?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.close()
    }
}

private struct RegexTesterView: View {
    @ObservedObject var model: RegexTesterViewModel
    let onUseInFind: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("Expresión regular"), text: $model.pattern)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            HStack {
                Toggle(L("Ignorar mayúsculas"), isOn: $model.options.caseInsensitive)
                Toggle(L("^ y $ por línea"), isOn: $model.options.anchorsMatchLines)
                Toggle(L(". incluye salto de línea"), isOn: $model.options.dotAll)
            }
            .toggleStyle(.checkbox)
            if let error = model.error {
                Text(error).foregroundColor(.red).font(.callout).textSelection(.enabled)
            } else {
                Text(status).font(.callout).foregroundColor(model.timedOut ? .orange : .secondary)
            }
            List(selection: $model.selectedRow) {
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(row.line):\(row.column)").foregroundColor(.secondary).monospacedDigit()
                            Text(row.text.isEmpty ? L("(vacía)") : row.text)
                                .font(.system(.body, design: .monospaced)).lineLimit(1)
                        }
                        if row.match.groups.count > 1 {
                            DisclosureGroup(L("Grupos")) {
                                ForEach(row.match.groups.dropFirst(), id: \.index) { group in
                                    groupRow(group)
                                }
                            }
                            .font(.callout)
                        }
                    }
                    .tag(row.id)
                }
            }
            HStack {
                Text(L("El motor es NSRegularExpression; la búsqueda del editor puede diferir levemente."))
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(L("Usar en Buscar"), action: onUseInFind).disabled(model.pattern.isEmpty || model.error != nil)
            }
        }
        .padding(12)
        .frame(minWidth: 420, minHeight: 320)
    }

    private var status: String {
        var parts: [String] = []
        if model.pattern.isEmpty { return L("Escribe un patrón") }
        let n = model.totalMatches
        parts.append(n == 1 ? L("1 coincidencia") : L("\(n) coincidencias"))
        if model.truncated { parts.append(L("+ hay más")) }
        if model.timedOut { parts.append(L("patrón demasiado lento: resultados parciales")) }
        if model.textCut { parts.append(L("solo los primeros 10 MB")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func groupRow(_ group: RegexGroupMatch) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(group.name.map { "\(group.index) <\($0)>" } ?? "\(group.index)").monospacedDigit()
            if let r = group.range, let v = group.value {
                Text("[\(r.lowerBound)–\(r.upperBound)]").foregroundColor(.secondary).monospacedDigit()
                Text(v).font(.system(.callout, design: .monospaced)).lineLimit(1)
            } else {
                Text(L("sin participar")).foregroundColor(.secondary).italic()
            }
        }
    }
}
