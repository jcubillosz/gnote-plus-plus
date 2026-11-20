// Fragmentos del usuario: archivo snippets.json, inserción con campos y ventana de administración.
import SwiftUI
import AppKit
import Scintilla

final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    @Published private(set) var snippets: [Snippet] = defaultSnippets
    private var warnedInvalid = false

    static var fileURL: URL { appDataDirectory().appendingPathComponent("snippets.json") }

    private init() { load() }

    /// Sin archivo se escriben los defaults; con JSON inválido se conserva el archivo (lo arregla
    /// el usuario) y se usan los defaults en memoria, avisando una sola vez.
    func load() {
        let url = Self.fileURL
        guard let data = try? Data(contentsOf: url) else {
            snippets = defaultSnippets
            try? encodeSnippetFile(defaultSnippets).write(to: url, options: .atomic)
            return
        }
        if let decoded = decodeSnippetFile(data) {
            snippets = decoded
            warnedInvalid = false
        } else {
            snippets = defaultSnippets
            if !warnedInvalid {
                warnedInvalid = true
                DispatchQueue.main.async {
                    presentAlert(L("snippets.json no es válido."),
                                 detail: L("Se usan los fragmentos predeterminados hasta que se corrija el archivo."))
                }
            }
        }
    }

    func save(_ list: [Snippet]) {
        snippets = list
        try? encodeSnippetFile(list).write(to: Self.fileURL, options: .atomic)
    }

    /// Guardar snippets.json desde una pestaña lo recarga.
    func documentSaved(at url: URL) {
        if url.resolvingSymlinksInPath().standardizedFileURL.path
            == Self.fileURL.resolvingSymlinksInPath().standardizedFileURL.path { load() }
    }

    func snippets(for profile: LanguageProfile) -> [Snippet] {
        let names = [profile.languageName.lowercased(), profile.lexerName.lowercased()]
        return snippets.filter { s in s.languages.contains { names.contains($0.lowercased()) || $0 == "*" } }
    }

    func match(prefix: String, profile: LanguageProfile) -> Snippet? {
        // Por nombre de Notepad++ ("html") o de lexer ("markdown", "hypertext"); `*` al final.
        let specific = snippets.filter { !$0.languages.contains("*") }
        return matchingSnippet(prefix: prefix, language: profile.languageName, in: specific)
            ?? matchingSnippet(prefix: prefix, language: profile.lexerName, in: specific)
            ?? matchingSnippet(prefix: prefix, language: "", in: snippets)
    }
}

/// Recorrido de los campos de un fragmento recién insertado. Las posiciones se llevan a mano
/// (no solo con el indicador 16) porque un campo vacío no puede tener indicador.
final class SnippetSession {
    static var current: SnippetSession?

    private struct Field { let number: Int; var start: Int; var end: Int; let appearance: Int }

    private let editor: ScintillaView
    private let documentPointer: sptr_t
    private var fields: [Field]
    private let stops: [Int]
    private var stopIndex = 0
    private var lastLength: Int

    private init(editor: ScintillaView, document: Document, fields: [Field]) {
        self.editor = editor
        documentPointer = document.pointer
        self.fields = fields
        var seen = Set<Int>()
        stops = fields.map(\.number).filter { seen.insert($0).inserted }
        lastLength = Self.call(editor, SCI_GETLENGTH)
    }

    @discardableResult
    private static func call(_ editor: ScintillaView, _ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
        Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
    }
    @discardableResult
    private func call(_ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int { Self.call(editor, message, wParam, lParam) }

    /// Inserta en `start..<end` (bytes) en una sola acción de deshacer y arranca la sesión.
    static func insert(_ snippet: Snippet, editor: ScintillaView, document: Document, replacing start: Int, _ end: Int) {
        current?.end()
        let lineStart = call(editor, SCI_POSITIONFROMLINE, call(editor, SCI_LINEFROMPOSITION, start))
        let line = SpellChecker.targetText(editor: editor, start: lineStart, end: start) ?? ""
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let width = call(editor, SCI_GETINDENT) > 0 ? call(editor, SCI_GETINDENT) : max(1, call(editor, SCI_GETTABWIDTH))
        let tab = call(editor, SCI_GETUSETABS) != 0 ? "\t" : String(repeating: " ", count: width)
        let eol = [0: "\r\n", 1: "\r", 2: "\n"][call(editor, SCI_GETEOLMODE)] ?? "\n"
        let parsed = parseSnippet(snippet.body, indent: indent, eol: eol, tab: tab)
        call(editor, SCI_BEGINUNDOACTION)
        call(editor, SCI_SETTARGETRANGE, start, end)
        parsed.text.withCString { cstr in
            _ = call(editor, SCI_REPLACETARGET, parsed.text.utf8.count, Int(bitPattern: UInt(bitPattern: cstr)))
        }
        call(editor, SCI_ENDUNDOACTION)
        let fields = zip(parsed.fields, parsed.appearance).map { f, order in
            Field(number: f.number, start: start + f.range.lowerBound, end: start + f.range.upperBound, appearance: order)
        }
        let session = SnippetSession(editor: editor, document: document, fields: fields)
        session.markAll()
        if session.stops.first == 0 {
            session.select(number: 0)
            session.clearIndicator()
            return
        }
        current = session
        session.select(number: session.stops[0])
    }

    var isActive: Bool { Self.current === self }

    func next() {
        reconcile()
        guard isActive else { return }
        leaveField()
        stopIndex = min(stopIndex + 1, stops.count - 1)
        select(number: stops[stopIndex])
        if stops[stopIndex] == 0 { end() }
    }

    func previous() {
        reconcile()
        guard isActive else { return }
        leaveField()
        stopIndex = max(0, stopIndex - 1)
        select(number: stops[stopIndex])
    }

    func end() {
        if isActive, call(SCI_GETDOCPOINTER) == Int(documentPointer) { leaveField() }
        clearIndicator()
        if Self.current === self { Self.current = nil }
    }

    /// Tras una edición o un movimiento del caret: la edición se atribuye al campo actual si el
    /// caret quedó dentro de él (desplaza los campos posteriores); si no, la sesión termina.
    func reconcile() {
        guard isActive else { return }
        // Cambio de pestaña: el editor ya muestra otro documento.
        guard call(SCI_GETDOCPOINTER) == Int(documentPointer) else { end(); return }
        let length = call(SCI_GETLENGTH)
        let delta = length - lastLength
        let caret = call(SCI_GETCURRENTPOS)
        let current = stops[stopIndex]
        guard let primary = fields.firstIndex(where: { $0.number == current }) else { end(); return }
        let oldStart = fields[primary].start, oldEnd = fields[primary].end
        let newEnd = oldEnd + delta
        guard newEnd >= oldStart, caret >= oldStart, caret <= newEnd else { end(); return }
        if delta != 0 {
            for i in fields.indices where i != primary && snippetFieldShifts(
                start: fields[i].start, appearance: fields[i].appearance, oldStart: oldStart, oldEnd: oldEnd,
                primaryAppearance: fields[primary].appearance) {
                fields[i].start += delta
                fields[i].end += delta
            }
            fields[primary].end = newEnd
            lastLength = length
            // Re-marca desde el inicio guardado: Scintilla no extiende el indicador al escribir
            // al inicio de un tramo, ni lo hay en un campo que estaba vacío.
            mark(fields[primary])
        }
    }

    // MARK: - Interno

    private func select(number: Int) {
        guard let f = fields.first(where: { $0.number == number }) else { return }
        call(SCI_SETSEL, f.start, f.end)
        call(SCI_SCROLLCARET)
    }

    /// Copia el texto del campo a sus espejos (al salir del campo, no por tecla, para no
    /// fragmentar el deshacer).
    private func leaveField() {
        let number = stops[stopIndex]
        guard let primary = fields.firstIndex(where: { $0.number == number }) else { return }
        let mirrors = fields.indices.filter { $0 != primary && fields[$0].number == number }
        guard !mirrors.isEmpty,
              let text = SpellChecker.targetText(editor: editor, start: fields[primary].start, end: fields[primary].end)
        else { return }
        let bytes = text.utf8.count
        call(SCI_BEGINUNDOACTION)
        for m in mirrors.sorted(by: { fields[$0].start > fields[$1].start }) {
            let old = fields[m]
            let delta = bytes - (old.end - old.start)
            guard delta != 0 || SpellChecker.targetText(editor: editor, start: old.start, end: old.end) != text else { continue }
            call(SCI_SETTARGETRANGE, old.start, old.end)
            text.withCString { cstr in
                _ = call(SCI_REPLACETARGET, bytes, Int(bitPattern: UInt(bitPattern: cstr)))
            }
            for i in fields.indices where i != m && fields[i].start >= old.end {
                fields[i].start += delta
                fields[i].end += delta
            }
            fields[m].end = old.start + bytes
            mark(fields[m])
        }
        call(SCI_ENDUNDOACTION)
        lastLength = call(SCI_GETLENGTH)
    }

    private func mark(_ f: Field) {
        call(SCI_SETINDICATORCURRENT, INDICATOR_SNIPPET_FIELD)
        call(SCI_SETINDICATORVALUE, f.number + 1)
        if f.end > f.start { call(SCI_INDICATORFILLRANGE, f.start, f.end - f.start) }
        call(SCI_SETINDICATORVALUE, 1)
    }

    private func markAll() { fields.forEach(mark) }

    private func clearIndicator() {
        call(SCI_SETINDICATORCURRENT, INDICATOR_SNIPPET_FIELD)
        call(SCI_INDICATORCLEARRANGE, 0, call(SCI_GETLENGTH))
    }
}

extension TabsViewModel {
    /// Tab: expande el fragmento cuyo prefijo está antes del caret.
    func expandSnippetAtCaret() -> Bool {
        guard let document = activeDocument, !document.isLocked else { return false }
        func call(_ m: UInt32, _ w: Int = 0) -> Int { Int(ScintillaView.directCall(editor, message: m, wParam: uptr_t(bitPattern: w), lParam: 0)) }
        guard call(SCI_GETSELECTIONS) == 1, call(SCI_GETSELECTIONEMPTY) != 0 else { return false }
        let caret = call(SCI_GETCURRENTPOS)
        let lineStart = call(SCI_POSITIONFROMLINE, call(SCI_LINEFROMPOSITION, caret))
        guard caret > lineStart,
              let line = SpellChecker.targetText(editor: editor, start: lineStart, end: caret),
              let prefix = snippetPrefix(lineBeforeCaret: line),
              let snippet = SnippetStore.shared.match(prefix: prefix, profile: document.languageProfile)
        else { return false }
        SnippetSession.insert(snippet, editor: editor, document: document, replacing: caret - prefix.utf8.count, caret)
        return true
    }

    /// Editar → Fragmentos → Insertar fragmento…: reemplaza la selección.
    func showSnippetPicker() {
        guard let document = activeDocument, !document.isLocked else { NSSound.beep(); return }
        let available = SnippetStore.shared.snippets(for: document.languageProfile)
        quickPanel.show(placeholder: L("Buscar un fragmento…")) { [weak self] query in
            guard let self else { return [] }
            func item(_ s: Snippet, _ i: Int, matched: [Int]) -> QuickPanelItem {
                QuickPanelItem(id: "snip:\(i):\(s.prefix)", title: s.name, subtitle: s.prefix, shortcut: nil,
                               isEnabled: true, isChecked: false, matched: matched) { [weak self] in
                    guard let self, let doc = self.activeDocument, doc === document, !doc.isLocked else { NSSound.beep(); return }
                    let start = Int(ScintillaView.directCall(self.editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0))
                    let end = Int(ScintillaView.directCall(self.editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0))
                    // Como la barra Markdown: insertar desde el menú no se graba en la macro.
                    self.macros.suppressing {
                        SnippetSession.insert(s, editor: self.editor, document: doc, replacing: start, end)
                    }
                }
            }
            let indexed = Array(available.enumerated())
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                return indexed.map { item($0.element, $0.offset, matched: []) }
            }
            return fuzzyRank(indexed, query: query, key: { "\($0.element.name) \($0.element.prefix)" },
                             fileNameStart: { _ in nil }, limit: QuickPanelViewModel.maxRows)
                .map { item($0.item.element, $0.item.offset, matched: $0.result.matched) }
        }
    }

    func openSnippetsFile() {
        _ = SnippetStore.shared  // escribe los defaults si el archivo no existe
        _ = open(url: SnippetStore.fileURL)
    }
}

// MARK: - Administrar fragmentos

final class SnippetManagerWindow {
    private static var controller: NSWindowController?

    static func show() {
        if let window = controller?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = L("Administrar fragmentos")
        window.contentView = NSHostingView(rootView: SnippetManagerView(store: SnippetStore.shared))
        window.center()
        let c = NSWindowController(window: window)
        controller = c
        c.showWindow(nil)
    }
}

private struct SnippetManagerView: View {
    @ObservedObject var store: SnippetStore
    @State private var draft: [Snippet] = []
    @State private var selection: Int?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(Array(draft.enumerated()), id: \.offset) { i, s in
                        VStack(alignment: .leading) {
                            Text(s.name.isEmpty ? L("(sin nombre)") : s.name)
                            Text("\(s.prefix) · \(s.languages.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(i)
                    }
                }
                HStack {
                    Button(L("Agregar")) {
                        draft.append(Snippet(prefix: "nuevo", name: L("Nuevo fragmento"), languages: ["*"], body: "$0"))
                        selection = draft.count - 1
                    }
                    Button(L("Eliminar")) {
                        guard let i = selection, draft.indices.contains(i) else { return }
                        draft.remove(at: i)
                        selection = draft.isEmpty ? nil : min(i, draft.count - 1)
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 220)
            VStack(alignment: .leading, spacing: 8) {
                if let i = selection, draft.indices.contains(i) {
                    TextField(L("Prefijo"), text: $draft[i].prefix)
                    TextField(L("Nombre"), text: $draft[i].name)
                    TextField(L("Lenguajes (separados por comas, * = todos)"), text: Binding(
                        get: { draft[i].languages.joined(separator: ", ") },
                        set: { draft[i].languages = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }))
                    Text(L("Cuerpo: $1, ${1:texto}, $0 = fin")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $draft[i].body)
                        .font(.system(.body, design: .monospaced))
                        .border(Color.secondary.opacity(0.3))
                } else {
                    Text(L("Selecciona un fragmento")).foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Spacer()
                    Button(L("Guardar")) { store.save(draft) }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(draft == store.snippets)
                }
            }
            .padding(12)
            .frame(minWidth: 380)
        }
        .onAppear { draft = store.snippets }
    }
}
