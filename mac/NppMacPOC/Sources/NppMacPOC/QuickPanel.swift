// Panel flotante compartido por la paleta de comandos y "Abrir rápido": campo + lista difusa.
import SwiftUI
import AppKit

struct QuickPanelItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let shortcut: String?
    let isEnabled: Bool
    let isChecked: Bool
    let matched: [Int]
    let action: () -> Void
}

final class QuickPanelViewModel: ObservableObject {
    static let maxRows = 50

    @Published var isVisible = false
    @Published var query = ""
    @Published var items: [QuickPanelItem] = []
    @Published var selection = 0
    @Published var placeholder = ""
    @Published var footer: String?
    var provider: ((String) -> [QuickPanelItem])?
    /// Devuelve el foco según el modo de vista; se llama en toda ruta de cierre (salvo `restoreFocus: false`).
    var onDidClose: (() -> Void)?
    /// Cambia en cada `show`: un resultado asíncrono de una apertura anterior no pisa la actual.
    private(set) var session = 0

    func show(placeholder: String, query initialQuery: String = "", provider: @escaping (String) -> [QuickPanelItem]) {
        session += 1
        self.placeholder = placeholder
        self.provider = provider
        footer = nil
        query = initialQuery
        selection = 0
        refresh()
        isVisible = true
    }

    func refresh() {
        items = Array((provider?(query) ?? []).prefix(Self.maxRows))
        selection = min(selection, max(0, items.count - 1))
    }

    /// Ranking calculado en segundo plano (Abrir rápido): se descarta si el panel ya no muestra
    /// esa apertura o el usuario siguió tipeando.
    func publish(_ newItems: [QuickPanelItem], session: Int, query: String) {
        guard isVisible, session == self.session, query == self.query else { return }
        let selectedID = items.indices.contains(selection) ? items[selection].id : nil
        items = Array(newItems.prefix(Self.maxRows))
        selection = quickPanelSelection(previous: selection, previousID: selectedID, in: items.map(\.id))
    }

    func close(restoreFocus: Bool = true) {
        let wasVisible = isVisible
        isVisible = false
        provider = nil
        items = []
        if wasVisible && restoreFocus { onDidClose?() }
    }

    func activateSelection() {
        guard items.indices.contains(selection) else { return }
        activate(items[selection])
    }

    func activate(_ item: QuickPanelItem) {
        guard item.isEnabled else { NSSound.beep(); return }
        close()
        // Después de cerrar y de devolver el foco (onDidClose lo difiere con el mismo mecanismo, y
        // los timers de intervalo 0 corren en orden): una acción que abre un modal o una barra con
        // campo propio no compite con el foco del panel ni se lo devuelven al editor después.
        deferPastCurrentLayoutPass { item.action() }
    }
}

// BEGIN-PURE
/// Selección tras reemplazar la lista por un ranking asíncrono: el índice viejo apuntaría a otra
/// fila. Si el usuario había bajado a una fila y esta sigue en la lista, se queda en ella; si no,
/// la primera. En la fila 0 se queda en la 0: es "la mejor coincidencia", no un ítem concreto, y
/// Enter justo después de tipear debe abrir la mejor del ranking nuevo.
func quickPanelSelection(previous: Int, previousID: String?, in newIDs: [String]) -> Int {
    guard previous > 0, let id = previousID, let index = newIDs.firstIndex(of: id) else { return 0 }
    return index
}
// END-PURE

/// Campo de texto de un panel flotante (paleta, Abrir rápido, historial del portapapeles), para
/// reconocerlo como "su" field editor al decidir si el foco perdido lo tomó otra vista.
final class FloatingPanelFocus {
    private weak var field: NSView?
    private weak var window: NSWindow?

    /// Se llama al ganar el foco: el first responder es entonces el field editor del campo. Si
    /// AppKit todavía no lo asentó, se reintenta un tick después (`onlyIfMissing`).
    func capture(onlyIfMissing: Bool = false) {
        if onlyIfMissing && field != nil { return }
        guard let window = NSApp.keyWindow,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let owner = editor.delegate as? NSView else { return }
        field = owner
        self.window = window
    }

    /// Tras perder el foco: ¿lo tomó otra vista (barra de búsqueda, buscar en archivos, preview,
    /// editor, otro panel)? Entonces no hay que devolverlo al editor, o lo tecleado iría al
    /// documento. Si quedó en la ventana o en el propio campo, nadie lo tomó.
    func takenElsewhere() -> Bool {
        guard let window = window ?? NSApp.keyWindow,
              let responder = window.firstResponder, responder !== window else { return false }
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            guard let owner = editor.delegate as? NSView else { return false }
            return owner !== field && owner.window != nil
        }
        return true
    }
}

struct QuickPanelView: View {
    @ObservedObject var model: QuickPanelViewModel
    /// Sesión del modelo que muestra esta vista: un cierre por foco que llega tarde no debe cerrar
    /// una apertura posterior.
    let session: Int

    @FocusState private var focused: Bool
    @State private var monitor: Any?
    @State private var focusTracker = FloatingPanelFocus()

    private func highlighted(_ item: QuickPanelItem) -> AttributedString {
        var text = AttributedString(item.title)
        let chars = Array(item.title)
        let set = Set(item.matched)
        // Se recorre por Character: los índices de `matched` son de Character, no de UTF-16.
        var index = text.startIndex
        for i in chars.indices {
            let end = text.index(index, offsetByCharacters: 1)
            if set.contains(i) { text[index..<end].font = .body.bold() }
            index = end
        }
        return text
    }

    var body: some View {
        VStack(spacing: 6) {
            TextField(model.placeholder, text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { model.activateSelection() }
                .onChange(of: model.query) { _ in
                    model.selection = 0
                    model.refresh()
                }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 8) {
                                if item.isChecked { Text("✓").foregroundStyle(.secondary) }
                                Text(highlighted(item)).lineLimit(1).truncationMode(.middle)
                                if let sub = item.subtitle {
                                    Text(sub).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                Spacer(minLength: 0)
                                if let sc = item.shortcut {
                                    Text(sc).font(.caption).foregroundStyle(.secondary).fixedSize()
                                }
                            }
                            .opacity(item.isEnabled ? 1 : 0.4)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == model.selection ? Color.accentColor.opacity(0.35) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { model.activate(item) }
                        }
                        if model.items.isEmpty {
                            Text(L("Sin resultados")).foregroundStyle(.secondary).padding(6)
                        }
                    }
                }
                .frame(height: 280)
                // Identidad de fila = id del ítem (del ForEach). Un `.id(index)` extra la pisaba y
                // la LazyVStack reusaba filas por posición: al filtrar quedaban títulos viejos.
                .onChange(of: model.selection) { i in
                    if model.items.indices.contains(i) { proxy.scrollTo(model.items[i].id) }
                }
            }
            if let footer = model.footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 8)
        .padding(.top, 8)
        .onAppear {
            focused = true
            // Mismo patrón que ClipboardHistoryPicker (ClipboardHistory.swift): el campo se queda
            // con ↑↓ y onKeyPress pide macOS 14, así que un monitor local acotado.
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window === NSApp.keyWindow, focused,
                      (NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor == true,
                      event.modifierFlags.intersection([.command, .shift, .option]).isEmpty
                else { return event }
                switch event.keyCode {
                case 53: model.close(); return nil
                case 126: model.selection = max(0, model.selection - 1); return nil
                case 125: model.selection = min(max(0, model.items.count - 1), model.selection + 1); return nil
                default: return event
                }
            }
        }
        .onDisappear { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }
        .onExitCommand { model.close() }
        .onChange(of: focused) { isFocused in
            if isFocused {
                focusTracker.capture()
                DispatchQueue.main.async { focusTracker.capture(onlyIfMissing: true) }
                return
            }
            // Un tick después: el first responder nuevo ya está asentado al decidir.
            DispatchQueue.main.async {
                guard model.isVisible, model.session == session else { return }
                model.close(restoreFocus: !focusTracker.takenElsewhere())
            }
        }
    }
}

/// Observa el modelo directamente: un ObservableObject anidado en TabsViewModel no reenvía su
/// objectWillChange, así que ContentView no se enteraría de `isVisible`.
struct QuickPanelHost: View {
    @ObservedObject var model: QuickPanelViewModel
    let onShown: () -> Void
    /// Devuelve el foco según el modo de vista (editor o preview).
    let onClose: () -> Void

    var body: some View {
        Group {
            if model.isVisible {
                // Vista nueva por apertura: si un ítem de la paleta reabre el panel (close + show
                // antes del render), SwiftUI conservaría la vista vieja sin onAppear ni re-enfoque, y
                // su focused=false la cerraría sola.
                QuickPanelView(model: model, session: model.session)
                    .id(model.session)
            }
        }
        .onAppear { model.onDidClose = onClose }
        .onChange(of: model.isVisible) { if $0 { onShown() } }
    }
}
