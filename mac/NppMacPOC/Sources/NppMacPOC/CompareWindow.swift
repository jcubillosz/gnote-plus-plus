import AppKit
import SwiftUI
import Scintilla

// Markers de las vistas de comparar: son vistas y documentos propios, no comparten numeración
// con los del editor.
private let MARKER_COMPARE_ADDED = 1
private let MARKER_COMPARE_DELETED = 2
private let MARKER_COMPARE_MODIFIED = 3
private let MARKER_COMPARE_FILLER = 4
let INDICATOR_COMPARE_INTRALINE = 16

/// Colores BGR de fondo por tema. Se mezclan a mano con el fondo del tema en vez de usar alpha
/// del marker: SC_MARK_BACKGROUND con alpha depende de la capa de dibujo y en oscuro quedaba sucio.
private struct ComparePalette {
    let added: NSColor, deleted: NSColor, modified: NSColor, filler: NSColor
    let intraLeft: NSColor, intraRight: NSColor

    static func of(_ theme: EditorTheme) -> ComparePalette {
        switch theme {
        case .light:
            return ComparePalette(added: NSColor(srgbRed: 0.18, green: 0.70, blue: 0.30, alpha: 0.22),
                                  deleted: NSColor(srgbRed: 0.90, green: 0.20, blue: 0.20, alpha: 0.20),
                                  modified: NSColor(srgbRed: 0.95, green: 0.70, blue: 0.10, alpha: 0.25),
                                  filler: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.12),
                                  intraLeft: NSColor(srgbRed: 0.85, green: 0.15, blue: 0.15, alpha: 1),
                                  intraRight: NSColor(srgbRed: 0.10, green: 0.60, blue: 0.20, alpha: 1))
        case .dark:
            return ComparePalette(added: NSColor(srgbRed: 0.25, green: 0.75, blue: 0.35, alpha: 0.22),
                                  deleted: NSColor(srgbRed: 0.95, green: 0.30, blue: 0.30, alpha: 0.22),
                                  modified: NSColor(srgbRed: 0.95, green: 0.70, blue: 0.15, alpha: 0.20),
                                  filler: NSColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 0.10),
                                  intraLeft: NSColor(srgbRed: 1.0, green: 0.35, blue: 0.35, alpha: 1),
                                  intraRight: NSColor(srgbRed: 0.35, green: 0.85, blue: 0.45, alpha: 1))
        }
    }
}

private func bgr(_ color: NSColor) -> sptr_t {
    let c = color.usingColorSpace(.sRGB) ?? color
    let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded())
    let b = Int((c.blueComponent * 255).rounded())
    return sptr_t(r | (g << 8) | (b << 16))
}

/// `color` con su alpha sobre el fondo `back` (BGR), resultado opaco en BGR.
private func blend(_ color: NSColor, over back: sptr_t) -> sptr_t {
    let c = color.usingColorSpace(.sRGB) ?? color
    let a = c.alphaComponent
    func mix(_ fg: CGFloat, _ shift: Int) -> Int {
        let bg = CGFloat((Int(back) >> shift) & 0xFF) / 255
        return Int(((fg * a + bg * (1 - a)) * 255).rounded())
    }
    return sptr_t(mix(c.redComponent, 0) | (mix(c.greenComponent, 8) << 8) | (mix(c.blueComponent, 16) << 16))
}

/// Estado de la barra (contador y botones), observado por la vista SwiftUI.
final class CompareBarModel: ObservableObject {
    @Published var current: Int?
    @Published var count = 0
    @Published var loading = true
    @Published var leftTitle = ""
    @Published var rightTitle = ""
}

private struct CompareBar: View {
    @ObservedObject var model: CompareBarModel
    let step: (Int) -> Void
    let reload: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(model.leftTitle).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .help(L("Cambio anterior"))
                .keyboardShortcut(.upArrow, modifiers: .option)
                .disabled(model.count == 0)
            Text(counter).monospacedDigit().frame(minWidth: 50)
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .help(L("Cambio siguiente"))
                .keyboardShortcut(.downArrow, modifiers: .option)
                .disabled(model.count == 0)
            Button(L("Recargar"), action: reload)
            Text(model.rightTitle).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var counter: String {
        if model.loading { return "…" }
        if model.count == 0 { return L("Sin cambios") }
        return "\(model.current.map { $0 + 1 } ?? 0)/\(model.count)"
    }
}

/// Contenedor de las dos vistas: mitad y mitad, sin divisor arrastrable (el scroll va sincronizado).
private final class CompareSplitView: NSView {
    let left: ScintillaView
    let right: ScintillaView

    init(left: ScintillaView, right: ScintillaView) {
        self.left = left
        self.right = right
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        addSubview(left)
        addSubview(right)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    override func layout() {
        super.layout()
        let half = floor((bounds.width - 1) / 2)
        left.frame = NSRect(x: 0, y: 0, width: half, height: bounds.height)
        right.frame = NSRect(x: half + 1, y: 0, width: bounds.width - half - 1, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: left.frame.maxX, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// Ventana de comparación lado a lado. Dos ScintillaView propias, de solo lectura; la vista
/// compartida del editor no se toca.
final class CompareWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: CompareWindowController] = [:]

    let leftSource: CompareSource
    let rightSource: CompareSource
    private weak var tabs: TabsViewModel?
    private let leftView = ScintillaView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
    private let rightView = ScintillaView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
    private let bar = CompareBarModel()
    private var prepared: PreparedComparison?
    private var model: SideBySide { prepared?.model ?? SideBySide(rows: [], hunks: []) }
    private var syncing = false
    private var loadToken = 0
    private var relays: [CompareScrollRelay] = []

    private var key: String { Self.key(leftSource, rightSource) }
    private static func key(_ a: CompareSource, _ b: CompareSource) -> String { "\(a)|\(b)" }

    /// Abre la comparación, o trae al frente (y recarga) la ventana del mismo par.
    static func show(left: CompareSource, right: CompareSource, tabs: TabsViewModel) {
        if let existing = open[key(left, right)] {
            existing.reload()
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = CompareWindowController(left: left, right: right, tabs: tabs)
        open[controller.key] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.reload()
    }

    /// Re-pinta todas las ventanas abiertas con el tema nuevo (lo llama TabsViewModel.applyTheme).
    static func applyThemeToAll() {
        for controller in open.values { controller.render(keepScroll: true) }
    }

    private init(left: CompareSource, right: CompareSource, tabs: TabsViewModel) {
        leftSource = left
        rightSource = right
        self.tabs = tabs
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = L("Comparar")
        window.setFrameAutosaveName("CompareWindow")
        super.init(window: window)

        let split = CompareSplitView(left: leftView, right: rightView)
        let host = NSHostingView(rootView: CompareBar(model: bar, step: { [weak self] in self?.goToHunk($0) },
                                                      reload: { [weak self] in self?.reload() }))
        let stack = NSStackView(views: [host, split])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        host.setContentHuggingPriority(.required, for: .vertical)
        window.contentView = stack
        window.delegate = self
        if !window.setFrameUsingName("CompareWindow") { window.center() }

        for view in [leftView, rightView] {
            configure(view)
            let relay = CompareScrollRelay(owner: self, view: view)
            relays.append(relay)
            view.delegate = relay
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    func windowWillClose(_ notification: Notification) {
        // delegate es unsafe_unretained: sin esto una notificación tardía apuntaría a basura.
        leftView.delegate = nil
        rightView.delegate = nil
        Self.open[key] = nil
    }

    private func call(_ view: ScintillaView, _ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
        Int(ScintillaView.directCall(view, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
    }

    private func configure(_ view: ScintillaView) {
        // Sin ajuste de línea: fila de la izquierda = fila de la derecha en pantalla.
        _ = call(view, SCI_SETWRAPMODE, SC_WRAP_NONE)
        _ = call(view, SCI_SETMARGINTYPEN, 0, SC_MARGIN_RTEXT)
        for margin in 1..<5 { _ = call(view, SCI_SETMARGINWIDTHN, margin, 0) }
        for marker in [MARKER_COMPARE_ADDED, MARKER_COMPARE_DELETED, MARKER_COMPARE_MODIFIED, MARKER_COMPARE_FILLER] {
            _ = call(view, SCI_MARKERDEFINE, marker, SC_MARK_BACKGROUND)
        }
        _ = call(view, SCI_INDICSETSTYLE, INDICATOR_COMPARE_INTRALINE, INDIC_STRAIGHTBOX)
        _ = call(view, SCI_INDICSETALPHA, INDICATOR_COMPARE_INTRALINE, 90)
        _ = call(view, SCI_INDICSETOUTLINEALPHA, INDICATOR_COMPARE_INTRALINE, 0)
        _ = call(view, SCI_INDICSETUNDER, INDICATOR_COMPARE_INTRALINE, 1)
        _ = call(view, SCI_SETREADONLY, 1)
    }

    // MARK: - Carga

    func reload() {
        guard let tabs else { return }
        loadToken += 1
        let token = loadToken
        bar.loading = true
        var results: [Int: Result<CompareText, CompareLoadError>] = [:]
        func collect(_ side: Int, _ result: Result<CompareText, CompareLoadError>) {
            guard token == loadToken else { return }
            results[side] = result
            guard let left = results[0], let right = results[1] else { return }
            switch (left, right) {
            case (.success(let l), .success(let r)):
                // Myers sobre hasta 50 000 líneas por lado: en el hilo principal congelaba la app.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let result = prepareComparison(oldText: l.text, newText: r.text)
                    DispatchQueue.main.async {
                        guard let self, token == self.loadToken else { return }
                        self.bar.loading = false
                        self.prepared = result
                        self.bar.leftTitle = l.title
                        self.bar.rightTitle = r.title
                        self.window?.title = "\(l.title) ↔ \(r.title)"
                        self.render(keepScroll: false)
                    }
                }
            case (.failure(let error), _), (_, .failure(let error)):
                bar.loading = false
                showError(error.message)
            }
        }
        CompareLoader.load(leftSource, tabs: tabs) { collect(0, $0) }
        CompareLoader.load(rightSource, tabs: tabs) { collect(1, $0) }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L("No se puede comparar")
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        let hasContent = !model.rows.isEmpty
        if let window, window.isVisible, hasContent {
            alert.beginSheetModal(for: window)
        } else {
            // Nada que mostrar: la ventana vacía no sirve, se cierra.
            window?.orderOut(nil)
            alert.runModal()
            close()
        }
    }

    // MARK: - Pintado

    private func render(keepScroll: Bool) {
        guard let tabs, let prepared else { return }
        let firstLine = call(leftView, SCI_GETFIRSTVISIBLELINE)
        let theme = tabs.currentTheme
        let profile = tabs.documents.first { $0.id == leftSource.documentID }?.languageProfile
        let palette = ComparePalette.of(theme)
        let leftSide = prepared.left, rightSide = prepared.right
        let back = globalStyle(name: "Default Style", theme: theme)?.back ?? 0xFFFFFF

        for (view, side, isLeft) in [(leftView, leftSide, true), (rightView, rightSide, false)] {
            applyStyle(view, profile: profile, theme: theme, fontName: tabs.preferences.fontName,
                       fontSize: tabs.preferences.fontSize)
            _ = call(view, SCI_MARKERSETBACK, MARKER_COMPARE_ADDED, blend(palette.added, over: back))
            _ = call(view, SCI_MARKERSETBACK, MARKER_COMPARE_DELETED, blend(palette.deleted, over: back))
            _ = call(view, SCI_MARKERSETBACK, MARKER_COMPARE_MODIFIED, blend(palette.modified, over: back))
            _ = call(view, SCI_MARKERSETBACK, MARKER_COMPARE_FILLER, blend(palette.filler, over: back))
            _ = call(view, SCI_INDICSETFORE, INDICATOR_COMPARE_INTRALINE,
                     Int(bgr(isLeft ? palette.intraLeft : palette.intraRight)))
            _ = call(view, SCI_SETREADONLY, 0)
            loadText(view, side.text)
            _ = call(view, SCI_EMPTYUNDOBUFFER)
            _ = call(view, SCI_SETREADONLY, 1)
            fillMargin(view, numbers: side.numbers)
            fillMarkers(view, left: isLeft)
        }
        fillIntraLine(prepared.intraLine)

        if keepScroll {
            scrollBoth(to: firstLine)
        } else {
            bar.count = model.hunks.count
            bar.current = nil
            if model.hunks.isEmpty { scrollBoth(to: 0) } else { goToHunk(1) }
        }
        bar.count = model.hunks.count
    }

    /// Estilos como DocumentMapView.applyStyle, pero con lexer propio: el documento es de esta vista.
    private func applyStyle(_ view: ScintillaView, profile: LanguageProfile?, theme: EditorTheme,
                            fontName: String, fontSize: Double) {
        fontName.withCString { cstr in
            _ = ScintillaView.directCall(view, message: SCI_STYLESETFONT, wParam: uptr_t(STYLE_DEFAULT),
                                         lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
        }
        _ = call(view, SCI_STYLESETSIZE, STYLE_DEFAULT, Int(fontSize))
        if let defaultStyle = globalStyle(name: "Default Style", theme: theme) {
            setStyle(view, STYLE_DEFAULT, fore: defaultStyle.fore, back: defaultStyle.back)
        }
        if let profile {
            applyLanguage(view, profile: profile)
        } else {
            _ = call(view, SCI_STYLECLEARALL)
        }
        if let lineNumber = globalStyle(name: "Line number margin", theme: theme) {
            setStyle(view, STYLE_LINENUMBER, fore: lineNumber.fore, back: lineNumber.back)
        }
    }

    private func fillMargin(_ view: ScintillaView, numbers: [Int?]) {
        _ = call(view, SCI_MARGINTEXTCLEARALL)
        let widest = String(max(1, (numbers.compactMap { $0 }.max() ?? 0) + 1))
        let sample = "_" + widest + "_"
        let width = sample.withCString { cstr in
            Int(ScintillaView.directCall(view, message: SCI_TEXTWIDTH, wParam: uptr_t(STYLE_LINENUMBER),
                                         lParam: sptr_t(bitPattern: UInt(bitPattern: cstr))))
        }
        _ = call(view, SCI_SETMARGINWIDTHN, 0, width)
        for (row, number) in numbers.enumerated() {
            if let number {
                String(number + 1).withCString { cstr in
                    _ = ScintillaView.directCall(view, message: SCI_MARGINSETTEXT, wParam: uptr_t(row),
                                                 lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
                }
            }
            _ = call(view, SCI_MARGINSETSTYLE, row, STYLE_LINENUMBER)
        }
    }

    private func fillMarkers(_ view: ScintillaView, left: Bool) {
        _ = call(view, SCI_MARKERDELETEALL, -1)
        for (row, entry) in model.rows.enumerated() {
            let marker: Int?
            switch entry.kind {
            case .equal: marker = nil
            case .modified: marker = MARKER_COMPARE_MODIFIED
            case .added: marker = left ? MARKER_COMPARE_FILLER : MARKER_COMPARE_ADDED
            case .deleted: marker = left ? MARKER_COMPARE_DELETED : MARKER_COMPARE_FILLER
            }
            if let marker { _ = call(view, SCI_MARKERADD, row, marker) }
        }
    }

    private func fillIntraLine(_ marks: [IntraLineMark]) {
        for view in [leftView, rightView] {
            _ = call(view, SCI_SETINDICATORCURRENT, INDICATOR_COMPARE_INTRALINE)
            _ = call(view, SCI_INDICATORCLEARRANGE, 0, call(view, SCI_GETLENGTH))
        }
        for mark in marks {
            // Una inserción pura deja vacío el rango de un lado: no hay nada que pintar ahí.
            for (view, range) in [(leftView, mark.left), (rightView, mark.right)] where !range.isEmpty {
                let start = call(view, SCI_POSITIONFROMLINE, mark.row)
                _ = call(view, SCI_INDICATORFILLRANGE, start + range.lowerBound, range.count)
            }
        }
    }

    // MARK: - Navegación y scroll

    func goToHunk(_ delta: Int) {
        guard let index = stepHunk(current: bar.current, delta: delta, count: model.hunks.count) else { return }
        bar.current = index
        let row = model.hunks[index].lowerBound
        scrollBoth(to: max(0, row - 3))
        for view in [leftView, rightView] {
            let position = call(view, SCI_POSITIONFROMLINE, row)
            _ = call(view, SCI_SETEMPTYSELECTION, position)
        }
    }

    private func scrollBoth(to line: Int) {
        syncing = true
        defer { syncing = false }
        for view in [leftView, rightView] { _ = call(view, SCI_SETFIRSTVISIBLELINE, line) }
    }

    /// Copia el scroll de `source` a la otra vista. La guarda evita el rebote: mover la otra
    /// dispara su propio SCN_UPDATEUI.
    fileprivate func scrolled(_ source: ScintillaView) {
        guard !syncing else { return }
        let target = source === leftView ? rightView : leftView
        syncing = true
        defer { syncing = false }
        let first = call(source, SCI_GETFIRSTVISIBLELINE)
        if call(target, SCI_GETFIRSTVISIBLELINE) != first { _ = call(target, SCI_SETFIRSTVISIBLELINE, first) }
        let x = call(source, SCI_GETXOFFSET)
        if call(target, SCI_GETXOFFSET) != x { _ = call(target, SCI_SETXOFFSET, x) }
    }
}

/// Delegate por vista: la notificación no dice de qué ScintillaView viene (hwndFrom es el
/// ScintillaCocoa interno), así que cada vista tiene el suyo.
private final class CompareScrollRelay: NSObject, ScintillaNotificationProtocol {
    weak var owner: CompareWindowController?
    weak var view: ScintillaView?

    init(owner: CompareWindowController, view: ScintillaView) {
        self.owner = owner
        self.view = view
    }

    func notification(_ notification: UnsafeMutablePointer<SCNotification>!) {
        guard let notification, let view,
              Int32(notification.pointee.nmhdr.code) == SCN_UPDATEUI,
              Int(notification.pointee.updated) & (SC_UPDATE_V_SCROLL | SC_UPDATE_H_SCROLL) != 0 else { return }
        owner?.scrolled(view)
    }
}
