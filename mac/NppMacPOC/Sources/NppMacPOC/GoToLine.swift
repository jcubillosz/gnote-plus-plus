import AppKit
import Scintilla

/// Diálogo modal "Ir a la línea". NSAlert + accessory view en vez de un sheet SwiftUI: no
/// necesita estado publicado propio y esquiva el problema de ObservableObject anidado
/// (Global Constraint 4 del plan P2) — mismo patrón que confirmDiscard en Document.swift.
func goToLine(editor: ScintillaView) {
    let segmented = NSSegmentedControl(labels: [L("Línea"), L("Posición")], trackingMode: .selectOne, target: nil, action: nil)
    segmented.selectedSegment = 0
    segmented.translatesAutoresizingMaskIntoConstraints = false

    let currentPos = ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0)
    let currentLine = ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: UInt(currentPos), lParam: 0)

    let field = NSTextField(string: String(currentLine + 1))
    field.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [segmented, field])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.alignment = .leading
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 56))
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        stack.topAnchor.constraint(equalTo: container.topAnchor),
        stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        field.widthAnchor.constraint(equalTo: stack.widthAnchor)
    ])

    let lineCount = ScintillaView.directCall(editor, message: SCI_GETLINECOUNT, wParam: 0, lParam: 0)
    let length = ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0)

    func updateInformativeText(_ alert: NSAlert) {
        if segmented.selectedSegment == 0 {
            alert.informativeText = L("Ir a la línea (1–\(Int(lineCount)))")
        } else {
            alert.informativeText = L("Ir a la posición (0–\(Int(length)))")
        }
    }

    let alert = NSAlert()
    alert.messageText = L("Ir a la línea")
    alert.addButton(withTitle: L("OK"))
    alert.addButton(withTitle: L("Cancelar"))
    alert.accessoryView = container
    updateInformativeText(alert)

    // El target del segmented control se resuelve después de crear el alert porque necesita
    // capturar `alert` para refrescar el rango válido al cambiar de segmento.
    let segmentHandler = SegmentChangeHandler {
        updateInformativeText(alert)
    }
    segmented.target = segmentHandler
    segmented.action = #selector(SegmentChangeHandler.changed)

    alert.window.initialFirstResponder = field
    field.selectText(nil)

    // NSControl.target es `weak` (ver NSControl.h): nada más retiene a segmentHandler, así
    // que ARC podría liberarlo apenas termina la línea de arriba y el target quedaría en nil
    // — cambiar de segmento dejaría de refrescar el rango, sin crash y sin síntoma en debug.
    let response = withExtendedLifetime(segmentHandler) { alert.runModal() }
    guard response == .alertFirstButtonReturn else { return }

    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Int(text) else { return }

    if segmented.selectedSegment == 0 {
        // El usuario escribe 1-based; SCI_GOTOLINE es 0-based.
        let clampedLine = min(max(value, 1), Int(lineCount))
        let targetLine = clampedLine - 1
        _ = ScintillaView.directCall(editor, message: SCI_GOTOLINE, wParam: uptr_t(targetLine), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_ENSUREVISIBLEENFORCEPOLICY, wParam: uptr_t(targetLine), lParam: 0)
    } else {
        let clampedPos = min(max(value, 0), Int(length))
        _ = ScintillaView.directCall(editor, message: SCI_GOTOPOS, wParam: uptr_t(clampedPos), lParam: 0)
        let targetLine = ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(clampedPos), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_ENSUREVISIBLEENFORCEPOLICY, wParam: uptr_t(targetLine), lParam: 0)
    }
    _ = ScintillaView.directCall(editor, message: SCI_SCROLLCARET, wParam: 0, lParam: 0)

    editor.window?.makeFirstResponder(editor)
}

/// NSSegmentedControl necesita un target Objective-C; una clase mínima envuelve el closure
/// porque el @Sendable/@escaping de Swift no puede ser #selector target directamente.
private final class SegmentChangeHandler: NSObject {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    @objc func changed() {
        onChange()
    }
}
