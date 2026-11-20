import AppKit
import Scintilla
import SwiftUI

/// Clic en el margen git (4) → popover con el texto de HEAD del bloque y "Restaurar bloque".
final class GitHunkRevertController {
    static let shared = GitHunkRevertController()

    private var monitor: Any?
    private var popover: NSPopover?
    private static let maxPreviewLines = 20

    /// Monitor local y no SCN_MARGINCLICK: ese aviso lo maneja ScintillaEditorView, que no se toca.
    /// Solo consume el clic si cae en la franja del margen 4 de la ventana principal y la línea
    /// tiene un marker git; si no, el evento sigue intacto.
    func installMonitor(editor: ScintillaView, tabs: TabsViewModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak tabs, weak editor] event in
            guard let self, let tabs, let editor,
                  let window = editor.window, event.window === window, window.isKeyWindow,
                  let document = tabs.activeDocument,
                  let line = Self.gitMarkerLine(at: event, editor: editor),
                  let hunks = tabs.gitGutter.lastHunks(for: document.id),
                  let base = tabs.gitGutter.baseLines(for: document.id),
                  let hunk = hunk(containing: line, in: hunks)
            else { return event }
            self.showPopover(hunk: hunk, base: base, document: document, tabs: tabs, editor: editor, event: event)
            return nil
        }
    }

    private static func call(_ editor: ScintillaView, _ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
        Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
    }

    /// Coordenadas de Scintilla: las del SCIContentView menos el origen del scroll más el ancho
    /// de los márgenes (mismo cálculo que el menú del corrector y `dropPosition`).
    private static func gitMarkerLine(at event: NSEvent, editor: ScintillaView) -> Int? {
        guard let content = editor.content(),
              editor.bounds.contains(editor.convert(event.locationInWindow, from: nil)) else { return nil }
        let point = content.convert(event.locationInWindow, from: nil)
        let origin = content.enclosingScrollView?.contentView.bounds.origin ?? .zero
        let marginLeft = call(editor, SCI_GETMARGINLEFT)
        var margins = 0
        for margin in 0..<call(editor, SCI_GETMARGINS) { margins += call(editor, SCI_GETMARGINWIDTHN, margin) }
        let x = Int(point.x - origin.x) + margins + marginLeft
        var gitStart = 0
        for margin in 0..<MARGIN_GIT { gitStart += call(editor, SCI_GETMARGINWIDTHN, margin) }
        let gitWidth = call(editor, SCI_GETMARGINWIDTHN, MARGIN_GIT)
        guard gitWidth > 0, x >= gitStart, x < gitStart + gitWidth else { return nil }
        let y = max(0, Int(point.y - origin.y))
        let position = call(editor, SCI_POSITIONFROMPOINT, margins + marginLeft, y)
        guard position >= 0 else { return nil }
        let line = call(editor, SCI_LINEFROMPOSITION, position)
        let mask = (1 << MARKER_GIT_ADDED) | (1 << MARKER_GIT_MODIFIED) | (1 << MARKER_GIT_DELETED)
        return call(editor, SCI_MARKERGET, line) & mask != 0 ? line : nil
    }

    private func showPopover(hunk: DiffHunk, base: [Substring], document: Document, tabs: TabsViewModel,
                             editor: ScintillaView, event: NSEvent) {
        popover?.close()
        let original = hunk.oldRange.clamped(to: 0..<base.count).map { String(base[$0]) }
        var preview = original.prefix(Self.maxPreviewLines).joined(separator: "\n")
        if original.count > Self.maxPreviewLines { preview += "\n…" }
        let popover = NSPopover()
        popover.behavior = .transient
        let view = GitHunkPopoverView(
            preview: preview,
            isPureAddition: original.isEmpty,
            isLocked: document.isLocked,
            restore: { [weak self, weak tabs] in
                popover.close()
                guard let self, let tabs else { return }
                self.restore(hunk, base: base, in: document, tabs: tabs, editor: editor)
            },
            copy: {
                popover.close()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(original.joined(separator: "\n"), forType: .string)
            })
        popover.contentViewController = NSHostingController(rootView: view)
        self.popover = popover
        let point = editor.convert(event.locationInWindow, from: nil)
        popover.show(relativeTo: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4), of: editor, preferredEdge: .maxX)
    }

    /// Una sola acción de deshacer. Si el documento cambió desde el popover (otra pestaña o el
    /// diff quedó viejo), no se toca: el rango ya no correspondería.
    func restore(_ hunk: DiffHunk, base: [Substring], in document: Document, tabs: TabsViewModel, editor: ScintillaView) {
        let call = { (m: UInt32, w: Int, l: Int) in Self.call(editor, m, w, l) }
        let lineCount = call(SCI_GETLINECOUNT, 0, 0)
        guard !document.isLocked, document === tabs.activeDocument,
              call(SCI_GETDOCPOINTER, 0, 0) == document.pointer,
              tabs.gitGutter.lastHunks(for: document.id)?.contains(hunk) == true,
              hunk.newRange.upperBound <= lineCount else {
            NSSound.beep()
            return
        }
        let eolMode = call(SCI_GETEOLMODE, 0, 0)
        let eol = eolMode == 0 ? "\r\n" : (eolMode == 1 ? "\r" : "\n")
        let span = revertSpan(hunk: hunk, baseCount: base.count)
        let start: Int
        switch span.start {
        case .lineStart(let line): start = call(SCI_POSITIONFROMLINE, line, 0)
        case .lineEnd(let line): start = call(SCI_GETLINEENDPOSITION, line, 0)
        }
        let end: Int
        switch span.end {
        case .lineStart(let line): end = call(SCI_POSITIONFROMLINE, line, 0)
        case .documentEnd: end = call(SCI_GETLENGTH, 0, 0)
        }
        guard start >= 0, end >= start else { NSSound.beep(); return }
        let text = revertedText(base: base, hunk: hunk, eol: eol)
        _ = call(SCI_BEGINUNDOACTION, 0, 0)
        _ = call(SCI_SETTARGETRANGE, start, end)
        text.withCString { cstr in
            _ = ScintillaView.directCall(editor, message: SCI_REPLACETARGET, wParam: uptr_t(bitPattern: -1),
                                         lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
        }
        _ = call(SCI_ENDUNDOACTION, 0, 0)
        tabs.gitGutter.refreshNow(document: document, editor: editor)
    }
}

private struct GitHunkPopoverView: View {
    let preview: String
    let isPureAddition: Bool
    let isLocked: Bool
    let restore: () -> Void
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isPureAddition {
                Text(L("Líneas agregadas (no están en HEAD)"))
                    .foregroundStyle(.secondary)
            } else {
                Text(L("Original en HEAD"))
                    .font(.headline)
                ScrollView([.horizontal, .vertical]) {
                    Text(preview)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 520, maxHeight: 320)
            }
            HStack {
                Button(isPureAddition ? L("Quitar líneas agregadas") : L("Restaurar bloque"), action: restore)
                    .disabled(isLocked)
                    .help(isLocked ? L("El documento está bloqueado") : "")
                if !isPureAddition {
                    Button(L("Copiar original"), action: copy)
                }
            }
        }
        .padding(12)
    }
}
