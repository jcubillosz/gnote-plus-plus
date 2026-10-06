import Foundation
import Scintilla

// Selección múltiple y edición en columna (Notepad++: IDM_EDIT_MULTISELECT*). Scintilla lo
// soporta nativo; acá solo se habilita y se exponen los comandos del menú.

/// Una vez, sobre el ScintillaView compartido: escribir/pegar en todas las selecciones y
/// ⌥+arrastre (o ⌥⇧+flechas, keybinding por defecto) para selección rectangular.
func configureMultipleSelection(_ editor: ScintillaView) {
    _ = ScintillaView.directCall(editor, message: SCI_SETMULTIPLESELECTION, wParam: 1, lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_SETADDITIONALSELECTIONTYPING, wParam: 1, lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_SETMULTIPASTE, wParam: uptr_t(SC_MULTIPASTE_EACH), lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_SETRECTANGULARSELECTIONMODIFIER, wParam: uptr_t(SCMOD_ALT), lParam: 0)
}

/// Agrega la siguiente coincidencia de la selección principal (sin selección, Scintilla toma
/// la palabra bajo el caret y sigue buscando como palabra completa). `all` agrega todas.
func addNextOccurrence(editor: ScintillaView, all: Bool) {
    _ = ScintillaView.directCall(editor, message: SCI_TARGETWHOLEDOCUMENT, wParam: 0, lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_SETSEARCHFLAGS, wParam: uptr_t(SCFIND_MATCHCASE), lParam: 0)
    _ = ScintillaView.directCall(editor, message: all ? SCI_MULTIPLESELECTADDEACH : SCI_MULTIPLESELECTADDNEXT, wParam: 0, lParam: 0)
}

/// Agrega un cursor en la línea de arriba/abajo del último cursor agregado, en la misma
/// columna visual (como ⌥⌘↑/↓ en Xcode).
func addCursorVertically(editor: ScintillaView, up: Bool) {
    let selections = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONS, wParam: 0, lParam: 0))
    let caret = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONNCARET, wParam: uptr_t(max(0, selections - 1)), lParam: 0))
    let line = Int(ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(caret), lParam: 0))
    let column = Int(ScintillaView.directCall(editor, message: SCI_GETCOLUMN, wParam: uptr_t(caret), lParam: 0))
    let lineCount = Int(ScintillaView.directCall(editor, message: SCI_GETLINECOUNT, wParam: 0, lParam: 0))
    let target = up ? line - 1 : line + 1
    guard target >= 0, target < lineCount else { return }
    let position = Int(ScintillaView.directCall(editor, message: SCI_FINDCOLUMN, wParam: uptr_t(target), lParam: sptr_t(column)))
    _ = ScintillaView.directCall(editor, message: SCI_ADDSELECTION, wParam: uptr_t(position), lParam: sptr_t(position))
}
