import AppKit
import Scintilla

/// Encabezado fijo: líneas de los símbolos que contienen la primera línea visible, pintadas
/// arriba del área de texto. Es subvista del ScintillaView compartido (no un overlay SwiftUI)
/// para no cubrir el editor con una vista que intercepte clics fuera de la franja.
final class StickyHeaderView: NSView {
    static let shared = StickyHeaderView()

    private weak var editor: ScintillaView?
    private var rows: [(line: Int, text: String)] = []
    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var foreColor = NSColor.textColor
    private var backColor = NSColor.textBackgroundColor
    private var separatorColor = NSColor.separatorColor
    private var rowHeight: CGFloat = 16
    private var pending: DispatchWorkItem?

    override var isFlipped: Bool { true }

    /// Scroll con debounce: el trabajo (esquema + SCI_GETLINE) no corre en cada SCN_UPDATEUI.
    func schedule(_ work: @escaping () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem(block: work)
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    func hide() {
        pending?.cancel()
        isHidden = true
    }

    func update(editor: ScintillaView, items: [OutlineItem], theme: EditorTheme, fontName: String) {
        self.editor = editor
        if superview !== editor {
            removeFromSuperview()
            editor.addSubview(self)
        }
        func call(_ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
            Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
        }
        let topLine = firstVisibleDocumentLine(editor)
        let headers = stickyHeaders(items: items, topLine: topLine, visibleLines: call(SCI_LINESONSCREEN))
        guard !headers.isEmpty else { isHidden = true; return }

        rows = headers.map { (line: $0.line, text: lineText(editor, line: $0.line)) }
        rowHeight = CGFloat(max(1, call(SCI_TEXTHEIGHT, topLine)))
        let size = CGFloat(max(4, call(SCI_STYLEGETSIZE, STYLE_DEFAULT) + call(SCI_GETZOOM)))
        font = NSFont(name: fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        foreColor = colorFromBGR(call(SCI_STYLEGETFORE, STYLE_DEFAULT))
        backColor = colorFromBGR(call(SCI_STYLEGETBACK, STYLE_DEFAULT))
        separatorColor = theme == .dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.15)

        var margins = call(SCI_GETMARGINLEFT)
        for margin in 0..<call(SCI_GETMARGINS) { margins += call(SCI_GETMARGINWIDTHN, margin) }
        let x = CGFloat(margins)
        let scroller = editor.scrollView.verticalScroller.map { $0.isHidden ? 0 : $0.frame.width } ?? 0
        // SCI_GETMARGINRIGHT incluye la franja del minimapa (DocumentMapView.applyMargin).
        let width = max(0, editor.bounds.width - x - scroller - CGFloat(call(SCI_GETMARGINRIGHT)))
        let height = rowHeight * CGFloat(rows.count) + 1
        let y = editor.isFlipped ? 0 : editor.bounds.height - height
        frame = NSRect(x: x, y: y, width: width, height: height)
        autoresizingMask = editor.isFlipped ? [.width] : [.width, .minYMargin]
        isHidden = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        backColor.setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreColor]
        for (index, row) in rows.enumerated() {
            let y = CGFloat(index) * rowHeight + (rowHeight - font.ascender + font.descender) / 2
            NSAttributedString(string: row.text, attributes: attributes)
                .draw(at: NSPoint(x: 2, y: y))
        }
        separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let editor else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.y / rowHeight)
        guard rows.indices.contains(index) else { return }
        _ = ScintillaView.directCall(editor, message: SCI_GOTOLINE, wParam: uptr_t(rows[index].line), lParam: 0)
        window?.makeFirstResponder(editor.content())
    }

    override func scrollWheel(with event: NSEvent) {
        editor?.scrollView.scrollWheel(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func colorFromBGR(_ bgr: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(bgr & 0xFF) / 255, green: CGFloat((bgr >> 8) & 0xFF) / 255,
                blue: CGFloat((bgr >> 16) & 0xFF) / 255, alpha: 1)
    }

    private func lineText(_ editor: ScintillaView, line: Int) -> String {
        let length = Int(ScintillaView.directCall(editor, message: SCI_GETLINE, wParam: uptr_t(line), lParam: 0))
        guard length > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: length + 1)
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = ScintillaView.directCall(editor, message: SCI_GETLINE, wParam: uptr_t(line), lParam: sptr_t(bitPattern: UInt(bitPattern: base)))
        }
        let text = String(decoding: buffer.prefix(length), as: UTF8.self)
        // Tabs a espacios: NSAttributedString usa tab stops propios, no el ancho de tab del editor.
        let tabWidth = Int(ScintillaView.directCall(editor, message: SCI_GETTABWIDTH, wParam: 0, lParam: 0))
        return text.trimmingCharacters(in: .newlines)
            .replacingOccurrences(of: "\t", with: String(repeating: " ", count: max(1, tabWidth)))
    }
}
