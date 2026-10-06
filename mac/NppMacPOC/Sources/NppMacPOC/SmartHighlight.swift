import Foundation
import Scintilla

/// Smart highlight de Notepad++ (PowerEditor/src/ScintillaComponent/SmartHighlighter.cpp): al
/// seleccionar una palabra completa, marca sus otras apariciones con INDICATOR_SMART_HIGHLIGHT.
enum SmartHighlighter {
    static let enabledDefaultsKey = "smartHighlight.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    static func clear(editor: ScintillaView) {
        let length = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
        guard length > 0 else { return }
        _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_SMART_HIGHLIGHT), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_INDICATORCLEARRANGE, wParam: 0, lParam: sptr_t(length))
    }

    /// Recalcula según la selección actual. Solo resalta si la selección es exactamente una
    /// palabra (mismo criterio que Notepad++ con "match whole word only"); cualquier otra
    /// selección —parcial, multilínea, vacía— limpia el resaltado.
    static func update(editor: ScintillaView) {
        clear(editor: editor)
        guard isEnabled else { return }

        let selStart = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0))
        let selEnd = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0))
        guard selEnd - selStart >= 2 else { return }
        let wordStart = Int(ScintillaView.directCall(editor, message: SCI_WORDSTARTPOSITION, wParam: uptr_t(selEnd), lParam: 1))
        let wordEnd = Int(ScintillaView.directCall(editor, message: SCI_WORDENDPOSITION, wParam: uptr_t(selStart), lParam: 1))
        guard wordStart == selStart, wordEnd == selEnd,
              let word = SpellChecker.targetText(editor: editor, start: selStart, end: selEnd) else { return }

        // Rango visible ±100 líneas, como SpellChecker.check: recorrer el documento entero en
        // cada cambio de selección no escala en archivos grandes.
        let lineCount = Int(ScintillaView.directCall(editor, message: SCI_GETLINECOUNT, wParam: 0, lParam: 0))
        let firstVisible = firstVisibleDocumentLine(editor)
        let linesOnScreen = Int(ScintillaView.directCall(editor, message: SCI_LINESONSCREEN, wParam: 0, lParam: 0))
        let startLine = max(0, firstVisible - 100)
        let endLine = min(lineCount, firstVisible + linesOnScreen + 100)
        let rangeStart = Int(ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(startLine), lParam: 0))
        let rangeEnd = endLine >= lineCount
            ? Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
            : Int(ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(endLine), lParam: 0))

        guard rangeStart >= 0, rangeEnd >= rangeStart else { return }

        _ = ScintillaView.directCall(editor, message: SCI_SETSEARCHFLAGS, wParam: uptr_t(SCFIND_MATCHCASE | SCFIND_WHOLEWORD), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_SMART_HIGHLIGHT), lParam: 0)
        var cursor = rangeStart
        var matches = 0
        while cursor < rangeEnd, matches < 10_000 {
            _ = ScintillaView.directCall(editor, message: SCI_SETTARGETRANGE, wParam: uptr_t(cursor), lParam: sptr_t(rangeEnd))
            let found = word.withCString { cstr in
                ScintillaView.directCall(
                    editor, message: SCI_SEARCHINTARGET,
                    wParam: uptr_t(word.utf8.count),
                    lParam: sptr_t(bitPattern: UInt(bitPattern: cstr))
                )
            }
            guard found >= 0 else { break }
            let matchStart = Int(found)
            let matchEnd = Int(ScintillaView.directCall(editor, message: SCI_GETTARGETEND, wParam: 0, lParam: 0))
            if matchStart != selStart {
                _ = ScintillaView.directCall(editor, message: SCI_INDICATORFILLRANGE, wParam: uptr_t(matchStart), lParam: sptr_t(matchEnd - matchStart))
            }
            matches += 1
            cursor = max(matchEnd, matchStart + 1)
        }
    }
}
