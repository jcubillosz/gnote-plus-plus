import Foundation
import Scintilla

// Marcadores de línea y plegado de código (Notepad++: IDM_SEARCH_TOGGLE_BOOKMARK y el margen
// de folding de ScintillaEditView.cpp). Los markers viven en el documento de Scintilla, así
// que cada pestaña conserva los suyos al cambiar de documento (SCI_SETDOCPOINTER).

/// Márgenes 0 (marcadores) y 2 (plegado). Se configura una sola vez sobre el ScintillaView
/// compartido; los anchos los ajusta EditorPreferences.applyEditingOptions y los colores el
/// tema (applyGlobalStyle).
func configureBookmarkAndFoldMargins(_ editor: ScintillaView) {
    func call(_ message: UInt32, _ wParam: Int, _ lParam: Int) {
        _ = ScintillaView.directCall(editor, message: message, wParam: uptr_t(wParam), lParam: sptr_t(lParam))
    }
    call(SCI_SETMARGINTYPEN, MARGIN_BOOKMARKS, SC_MARGIN_SYMBOL)
    call(SCI_SETMARGINMASKN, MARGIN_BOOKMARKS, 1 << MARKER_BOOKMARK)
    call(SCI_SETMARGINSENSITIVEN, MARGIN_BOOKMARKS, 1)
    call(SCI_SETMARGINWIDTHN, MARGIN_BOOKMARKS, 14)
    call(SCI_MARKERDEFINE, MARKER_BOOKMARK, SC_MARK_BOOKMARK)

    call(SCI_SETMARGINTYPEN, MARGIN_FOLD, SC_MARGIN_SYMBOL)
    call(SCI_SETMARGINMASKN, MARGIN_FOLD, SC_MASK_FOLDERS)
    call(SCI_SETMARGINSENSITIVEN, MARGIN_FOLD, 1)
    // Estilo "árbol de cajas", el default de Notepad++.
    let symbols: [(Int, Int)] = [
        (SC_MARKNUM_FOLDEROPEN, SC_MARK_BOXMINUS),
        (SC_MARKNUM_FOLDER, SC_MARK_BOXPLUS),
        (SC_MARKNUM_FOLDERSUB, SC_MARK_VLINE),
        (SC_MARKNUM_FOLDERTAIL, SC_MARK_LCORNER),
        (SC_MARKNUM_FOLDEREND, SC_MARK_BOXPLUSCONNECTED),
        (SC_MARKNUM_FOLDEROPENMID, SC_MARK_BOXMINUSCONNECTED),
        (SC_MARKNUM_FOLDERMIDTAIL, SC_MARK_TCORNER),
    ]
    for (marker, symbol) in symbols {
        call(SCI_MARKERDEFINE, marker, symbol)
    }
    // Scintilla maneja solo los clics y el mostrar/ocultar al editar. Los flags van en
    // wParam: pasados en lParam el plegado automático quedaba apagado y el "−" no hacía nada.
    call(SCI_SETAUTOMATICFOLD, SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE, 0)
    call(SCI_SETFOLDFLAGS, SC_FOLDFLAG_LINEAFTER_CONTRACTED, 0)
}

/// Colores de marcadores y plegado del tema activo (WidgetStyle "Fold"/"Fold margin" de
/// stylers.model.xml y DarkModeDefault.xml). El marcador usa el color de acento del sistema.
func applyBookmarkAndFoldColors(_ editor: ScintillaView, theme: EditorTheme) {
    func call(_ message: UInt32, _ wParam: Int, _ lParam: Int) {
        _ = ScintillaView.directCall(editor, message: message, wParam: uptr_t(wParam), lParam: sptr_t(lParam))
    }
    if let fold = globalStyle(name: "Fold", theme: theme) {
        for marker in SC_MARKNUM_FOLDEREND...SC_MARKNUM_FOLDEROPEN {
            call(SCI_MARKERSETFORE, marker, Int(fold.back ?? fold.fore))
            call(SCI_MARKERSETBACK, marker, Int(fold.fore))
        }
    }
    if let margin = globalStyle(name: "Fold margin", theme: theme) {
        call(SCI_SETFOLDMARGINCOLOUR, 1, Int(margin.back ?? margin.fore))
        call(SCI_SETFOLDMARGINHICOLOUR, 1, Int(margin.fore))
    }
    // Azul (BGR 0xD07A2E = RGB #2E7AD0), legible sobre márgenes claros y oscuros.
    call(SCI_MARKERSETFORE, MARKER_BOOKMARK, 0xD07A2E)
    call(SCI_MARKERSETBACK, MARKER_BOOKMARK, 0xD07A2E)
}

private func currentLine(_ editor: ScintillaView) -> Int {
    let pos = ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0)
    return Int(ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(pos), lParam: 0))
}

func toggleBookmark(editor: ScintillaView, line: Int? = nil) {
    let target = line ?? currentLine(editor)
    let markers = Int(ScintillaView.directCall(editor, message: SCI_MARKERGET, wParam: uptr_t(target), lParam: 0))
    let message = markers & (1 << MARKER_BOOKMARK) != 0 ? SCI_MARKERDELETE : SCI_MARKERADD
    _ = ScintillaView.directCall(editor, message: message, wParam: uptr_t(target), lParam: sptr_t(MARKER_BOOKMARK))
}

/// Siguiente/anterior marcador con vuelta al principio/final, como Notepad++ (F2/⇧F2).
func goToBookmark(editor: ScintillaView, forward: Bool) {
    let mask = sptr_t(1 << MARKER_BOOKMARK)
    let line = currentLine(editor)
    let lineCount = Int(ScintillaView.directCall(editor, message: SCI_GETLINECOUNT, wParam: 0, lParam: 0))
    var found: Int
    if forward {
        found = Int(ScintillaView.directCall(editor, message: SCI_MARKERNEXT, wParam: uptr_t(line + 1), lParam: mask))
        if found < 0 { found = Int(ScintillaView.directCall(editor, message: SCI_MARKERNEXT, wParam: 0, lParam: mask)) }
    } else {
        found = line > 0 ? Int(ScintillaView.directCall(editor, message: SCI_MARKERPREVIOUS, wParam: uptr_t(line - 1), lParam: mask)) : -1
        if found < 0 { found = Int(ScintillaView.directCall(editor, message: SCI_MARKERPREVIOUS, wParam: uptr_t(max(0, lineCount - 1)), lParam: mask)) }
    }
    guard found >= 0 else { return }
    _ = ScintillaView.directCall(editor, message: SCI_GOTOLINE, wParam: uptr_t(found), lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_ENSUREVISIBLEENFORCEPOLICY, wParam: uptr_t(found), lParam: 0)
}

func clearBookmarks(editor: ScintillaView) {
    _ = ScintillaView.directCall(editor, message: SCI_MARKERDELETEALL, wParam: uptr_t(MARKER_BOOKMARK), lParam: 0)
}

func foldAll(editor: ScintillaView, expand: Bool) {
    _ = ScintillaView.directCall(editor, message: SCI_FOLDALL, wParam: uptr_t(expand ? SC_FOLDACTION_EXPAND : SC_FOLDACTION_CONTRACT), lParam: 0)
}
