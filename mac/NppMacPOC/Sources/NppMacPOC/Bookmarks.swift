import Foundation
import AppKit
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

// MARK: - Operaciones sobre líneas con marcador

/// Líneas a borrar, de mayor a menor para que borrar una no corra las posiciones de las demás.
func linesToDelete(lineCount: Int, bookmarked: Set<Int>, deleteBookmarked: Bool) -> [Int] {
    (0..<max(lineCount, 0)).reversed().filter { bookmarked.contains($0) == deleteBookmarked }
}

/// Cada línea seguida de su EOL (también la última): al pegar no se funde con lo que haya después.
func joinedLines(_ lines: [String], eol: String) -> String {
    lines.map { $0 + eol }.joined()
}

private func bmCall(_ editor: ScintillaView, _ m: UInt32, _ w: Int = 0, _ l: Int = 0) -> Int {
    Int(ScintillaView.directCall(editor, message: m, wParam: uptr_t(bitPattern: w), lParam: sptr_t(l)))
}

private func bmLineCount(_ editor: ScintillaView) -> Int { bmCall(editor, SCI_GETLINECOUNT) }

private func bmLineStart(_ editor: ScintillaView, _ line: Int) -> Int { bmCall(editor, SCI_POSITIONFROMLINE, line) }

private func bmLineEnd(_ editor: ScintillaView, _ line: Int) -> Int { bmCall(editor, SCI_GETLINEENDPOSITION, line) }

private func bmEOL(_ editor: ScintillaView) -> String {
    switch bmCall(editor, SCI_GETEOLMODE) {
    case 0: return "\r\n"
    case 1: return "\r"
    default: return "\n"
    }
}

private func bmText(_ editor: ScintillaView, _ start: Int, _ end: Int) -> String {
    guard end > start else { return "" }
    _ = bmCall(editor, SCI_SETTARGETRANGE, start, end)
    let length = bmCall(editor, SCI_GETTARGETTEXT)
    guard length > 0 else { return "" }
    var buffer = [UInt8](repeating: 0, count: length + 1)
    buffer.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        _ = ScintillaView.directCall(editor, message: SCI_GETTARGETTEXT, wParam: 0, lParam: sptr_t(bitPattern: UInt(bitPattern: base)))
    }
    return String(decoding: buffer.prefix(length), as: UTF8.self)
}

/// Líneas con marcador de la pestaña activa, ascendente.
func bookmarkedLines(_ editor: ScintillaView) -> [Int] {
    var result: [Int] = []
    var line = bmCall(editor, SCI_MARKERNEXT, 0, 1 << MARKER_BOOKMARK)
    while line >= 0 {
        result.append(line)
        line = bmCall(editor, SCI_MARKERNEXT, line + 1, 1 << MARKER_BOOKMARK)
    }
    return result
}

func copyBookmarkedLines(_ editor: ScintillaView) {
    let lines = bookmarkedLines(editor)
    guard !lines.isEmpty else { return }
    let texts = lines.map { bmText(editor, bmLineStart(editor, $0), bmLineEnd(editor, $0)) }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(joinedLines(texts, eol: bmEOL(editor)), forType: .string)
}

func cutBookmarkedLines(_ editor: ScintillaView) {
    guard !bookmarkedLines(editor).isEmpty else { return }
    copyBookmarkedLines(editor)
    deleteLines(editor, bookmarked: true)
}

/// Cada línea con marcador (sin su EOL) se reemplaza por el texto completo del portapapeles,
/// como `pasteToMarkedLines` de Notepad++. De abajo hacia arriba para no mover las posiciones.
func pasteReplacingBookmarkedLines(_ editor: ScintillaView) {
    let lines = bookmarkedLines(editor)
    guard !lines.isEmpty, let clip = NSPasteboard.general.string(forType: .string) else { return }
    _ = bmCall(editor, SCI_BEGINUNDOACTION)
    for line in lines.reversed() {
        _ = bmCall(editor, SCI_SETTARGETRANGE, bmLineStart(editor, line), bmLineEnd(editor, line))
        clip.withCString { cstr in
            _ = ScintillaView.directCall(editor, message: SCI_REPLACETARGET, wParam: uptr_t(clip.utf8.count),
                                         lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
        }
    }
    _ = bmCall(editor, SCI_ENDUNDOACTION)
}

/// Borra las líneas con (o sin) marcador. Una línea es [inicio, inicio de la siguiente); la última,
/// si no termina en EOL, se lleva el EOL que la precede para no dejar la anterior pegada o un EOL suelto.
func deleteLines(_ editor: ScintillaView, bookmarked: Bool) {
    let count = bmLineCount(editor)
    let docLength = bmCall(editor, SCI_GETLENGTH)
    let marked = Set(bookmarkedLines(editor))
    var targets = linesToDelete(lineCount: count, bookmarked: marked, deleteBookmarked: bookmarked)
    // La línea final vacía (el documento termina en EOL) no es una línea real: no hay nada que borrar.
    if let last = targets.first, last == count - 1, last > 0, bmLineStart(editor, last) == docLength {
        targets.removeFirst()
    }
    guard !targets.isEmpty else { return }
    _ = bmCall(editor, SCI_BEGINUNDOACTION)
    for line in targets {
        var start = bmLineStart(editor, line)
        var end = line + 1 < bmLineCount(editor) ? bmLineStart(editor, line + 1) : bmCall(editor, SCI_GETLENGTH)
        if line + 1 >= bmLineCount(editor), line > 0 { start = bmLineEnd(editor, line - 1) }
        if end < start { end = start }
        _ = bmCall(editor, SCI_DELETERANGE, start, end - start)
    }
    _ = bmCall(editor, SCI_ENDUNDOACTION)
}

func invertBookmarks(_ editor: ScintillaView) {
    let mask = 1 << MARKER_BOOKMARK
    for line in 0..<bmLineCount(editor) {
        if bmCall(editor, SCI_MARKERGET, line) & mask != 0 {
            _ = bmCall(editor, SCI_MARKERDELETE, line, MARKER_BOOKMARK)
        } else {
            _ = bmCall(editor, SCI_MARKERADD, line, MARKER_BOOKMARK)
        }
    }
}
