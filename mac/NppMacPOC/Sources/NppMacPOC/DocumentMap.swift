import AppKit
import SwiftUI
import Scintilla

/// Minimapa del documento (Notepad++: "Document Map", documentMap.cpp; VSCode: minimap).
///
/// Es un segundo ScintillaView que muestra EL MISMO documento de Scintilla que el editor
/// (SCI_GETDOCPOINTER → SCI_SETDOCPOINTER; Scintilla cuenta referencias y admite varias
/// vistas por documento). El lexer, los bytes de estilo y el plegado viven en el documento,
/// así que el coloreado sale gratis; lo que es de cada vista son las definiciones de estilo
/// (fuente, colores), que se copian con applyStyle. Encima va una capa transparente que
/// dibuja el área visible del editor y se queda con todos los eventos de mouse: la minimapa
/// nunca recibe foco ni teclado, así que no hay forma de editar desde ella.
final class DocumentMapView: NSView {
    private let map: ScintillaView
    private let overlay = DocumentMapOverlay()
    private weak var editor: ScintillaView?
    private var attachedDocument: sptr_t = 0
    /// Primera línea visible de la minimapa y alto de línea, de la última actualización:
    /// los usa el overlay para traducir un clic a una línea.
    private var mapFirstLine = 0
    private var lineHeight: CGFloat = 0

    static let width: CGFloat = 110

    init(editor: ScintillaView) {
        self.editor = editor
        map = ScintillaView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        super.init(frame: map.frame)
        map.autoresizingMask = [.width, .height]
        addSubview(map)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.owner = self
        addSubview(overlay)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    private func call(_ view: ScintillaView, _ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
        Int(ScintillaView.directCall(view, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
    }

    private func configure() {
        for margin in 0..<5 {
            _ = call(map, SCI_SETMARGINWIDTHN, margin, 0)
        }
        _ = call(map, SCI_SETVSCROLLBAR, 0)
        _ = call(map, SCI_SETHSCROLLBAR, 0)
        _ = call(map, SCI_SETCARETSTYLE, CARETSTYLE_INVISIBLE)
        _ = call(map, SCI_SETCARETLINEVISIBLE, 0)
        _ = call(map, SCI_SETWRAPMODE, SC_WRAP_NONE)
        _ = call(map, SCI_SETZOOM, -10)
    }

    /// Definiciones de estilo de la minimapa: las mismas que applyLanguage/applyGlobalStyle
    /// le ponen al editor, menos el lexer (es del documento: volver a crearlo desde acá le
    /// cambiaría el lexer al editor también).
    func applyStyle(profile: LanguageProfile?, theme: EditorTheme, fontName: String) {
        fontName.withCString { cstr in
            _ = ScintillaView.directCall(map, message: SCI_STYLESETFONT, wParam: uptr_t(STYLE_DEFAULT), lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
        }
        // Tamaño base fijo: con el zoom mínimo (-10) da ~2-3 pt, el tamaño de minimapa
        // de VSCode, sin depender del tamaño de letra del editor.
        _ = call(map, SCI_STYLESETSIZE, STYLE_DEFAULT, 12)
        if let defaultStyle = globalStyle(name: "Default Style", theme: theme) {
            setStyle(map, STYLE_DEFAULT, fore: defaultStyle.fore, back: defaultStyle.back)
        }
        _ = call(map, SCI_STYLECLEARALL)
        for (styleID, color) in profile?.styles ?? [:] {
            setStyle(map, styleID, fore: color.fore, back: color.back, fontStyle: color.fontStyle)
        }
        _ = call(map, SCI_SETZOOM, -10)
        refresh()
    }

    /// Sigue al documento activo y ubica la minimapa y el rectángulo del área visible.
    /// Barata: se llama en cada scroll, edición y redimensionado del editor.
    func refresh() {
        guard let editor, window != nil else { return }
        let document = call(editor, SCI_GETDOCPOINTER)
        if document != attachedDocument {
            _ = call(map, SCI_SETDOCPOINTER, 0, document)
            attachedDocument = document
        }

        lineHeight = CGFloat(call(map, SCI_TEXTHEIGHT, 0))
        guard lineHeight > 0 else { return }
        let totalLines = max(1, call(map, SCI_GETLINECOUNT))
        let firstDisplay = call(editor, SCI_GETFIRSTVISIBLELINE)
        let linesOnScreen = max(1, call(editor, SCI_LINESONSCREEN))
        // El editor puede tener ajuste de línea o bloques plegados: sus líneas "visibles" no
        // son líneas del documento. La minimapa no ajusta ni pliega, así que se traduce.
        let firstLine = call(editor, SCI_DOCLINEFROMVISIBLE, firstDisplay)
        let lastLine = min(totalLines, call(editor, SCI_DOCLINEFROMVISIBLE, firstDisplay + linesOnScreen))
        let shownLines = max(1, lastLine - firstLine)

        // Si el documento no entra en la minimapa, se desplaza proporcionalmente al scroll
        // del editor (mismo criterio que scrollMap de Notepad++).
        let mapLinesOnScreen = Int(bounds.height / lineHeight)
        var mapFirst = 0
        if totalLines > mapLinesOnScreen {
            let editorScrollable = max(1, totalLines - shownLines)
            let progress = min(1, Double(firstLine) / Double(editorScrollable))
            mapFirst = Int((progress * Double(totalLines - mapLinesOnScreen)).rounded())
        }
        if mapFirst != call(map, SCI_GETFIRSTVISIBLELINE) {
            _ = call(map, SCI_SETFIRSTVISIBLELINE, mapFirst)
        }
        mapFirstLine = mapFirst

        overlay.viewport = NSRect(
            x: 0,
            y: CGFloat(firstLine - mapFirst) * lineHeight,
            width: bounds.width,
            height: max(lineHeight * 2, CGFloat(shownLines) * lineHeight)
        )
    }

    /// Clic o arrastre en la minimapa: centra el editor en esa línea.
    fileprivate func scrollEditor(toMapY y: CGFloat) {
        guard let editor, lineHeight > 0 else { return }
        let totalLines = max(1, call(map, SCI_GETLINECOUNT))
        let line = min(totalLines - 1, max(0, mapFirstLine + Int(y / lineHeight)))
        let linesOnScreen = call(editor, SCI_LINESONSCREEN)
        let target = call(editor, SCI_VISIBLEFROMDOCLINE, line) - linesOnScreen / 2
        _ = call(editor, SCI_SETFIRSTVISIBLELINE, max(0, target))
        refresh()
    }

    fileprivate func forwardScroll(_ event: NSEvent) {
        editor?.scrollView.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }
}

/// Capa sobre la minimapa: dibuja el área visible del editor y recibe el mouse.
private final class DocumentMapOverlay: NSView {
    weak var owner: DocumentMapView?
    var viewport: NSRect = .zero { didSet { if viewport != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard viewport.height > 0 else { return }
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        viewport.fill()
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        let border = NSBezierPath(rect: viewport.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.scrollEditor(toMapY: convert(event.locationInWindow, from: nil).y)
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.scrollEditor(toMapY: convert(event.locationInWindow, from: nil).y)
    }

    override func scrollWheel(with event: NSEvent) {
        owner?.forwardScroll(event)
    }
}

/// El DocumentMapView es único y vive en TabsViewModel; esta vista lo adopta en un
/// contenedor nuevo en cada aparición (mismo motivo que MarkdownPreviewView: devolver la
/// instancia compartida directo desde makeNSView la deja fuera de la jerarquía al volver).
struct DocumentMapRepresentable: NSViewRepresentable {
    let map: DocumentMapView

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        if map.superview !== container {
            map.removeFromSuperview()
            map.frame = container.bounds
            map.autoresizingMask = [.width, .height]
            container.addSubview(map)
        }
        map.refresh()
    }
}
