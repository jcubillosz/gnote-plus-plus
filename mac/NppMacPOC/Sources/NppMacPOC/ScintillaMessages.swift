import Scintilla

// IDs de mensajes Scintilla (SCI_*), confirmados contra scintilla/include/Scintilla.iface —
// no inventar números nuevos sin volver a confirmar ahí.
let SCI_CLEARALL: UInt32 = 2004
let SCI_GETLENGTH: UInt32 = 2006
let SCI_GETCURRENTPOS: UInt32 = 2008
let SCI_SETSAVEPOINT: UInt32 = 2014
let SCI_SETVIEWWS: UInt32 = 2021
let SCI_SETTABWIDTH: UInt32 = 2036
let SCI_STYLECLEARALL: UInt32 = 2050
let SCI_STYLESETFORE: UInt32 = 2051
let SCI_STYLESETBACK: UInt32 = 2052
let SCI_STYLESETBOLD: UInt32 = 2053
let SCI_STYLESETITALIC: UInt32 = 2054
let SCI_STYLESETSIZE: UInt32 = 2055
let SCI_STYLESETFONT: UInt32 = 2056
let SCI_STYLESETUNDERLINE: UInt32 = 2059
let SCI_SETSELBACK: UInt32 = 2068
let SCI_SETCARETFORE: UInt32 = 2069
let SCI_SETUSETABS: UInt32 = 2124
let SCI_GETCOLUMN: UInt32 = 2129
let SCI_GETSELECTIONSTART: UInt32 = 2143
let SCI_GETSELECTIONEND: UInt32 = 2145
let SCI_GETMODIFY: UInt32 = 2159
let SCI_LINEFROMPOSITION: UInt32 = 2166
let SCI_GOTOLINE: UInt32 = 2024
let SCI_GOTOPOS: UInt32 = 2025
let SCI_GETLINECOUNT: UInt32 = 2154
let SCI_ENSUREVISIBLEENFORCEPOLICY: UInt32 = 2234
let SCI_SETTEXT: UInt32 = 2181
let SCI_GETTEXT: UInt32 = 2182
let SCI_SETMARGINLEFT: UInt32 = 2155
let SCI_SETMARGINTYPEN: UInt32 = 2240
let SCI_SETMARGINWIDTHN: UInt32 = 2242
let SCI_SETWRAPMODE: UInt32 = 2268
let SCI_APPENDTEXT: UInt32 = 2282
let SCI_SETDOCPOINTER: UInt32 = 2358
let SCI_CREATEDOCUMENT: UInt32 = 2375
let SCI_RELEASEDOCUMENT: UInt32 = 2377
let SCI_COLOURISE: UInt32 = 4003
let SCI_SETKEYWORDS: UInt32 = 4005
let SCI_SETILEXER: UInt32 = 4033
let SCI_SETTARGETSTART: UInt32 = 2190
let SCI_GETTARGETSTART: UInt32 = 2191
let SCI_SETTARGETEND: UInt32 = 2192
let SCI_GETTARGETEND: UInt32 = 2193
let SCI_REPLACETARGET: UInt32 = 2194
let SCI_REPLACETARGETRE: UInt32 = 2195
let SCI_SEARCHINTARGET: UInt32 = 2197
let SCI_SETSEARCHFLAGS: UInt32 = 2198
let SCI_SETEOLMODE: UInt32 = 2031
let SCI_SETSEL: UInt32 = 2160
let SCI_SCROLLCARET: UInt32 = 2169
let SCI_SETINDICATORCURRENT: UInt32 = 2500
let SCI_INDICATORFILLRANGE: UInt32 = 2504
let SCI_INDICATORCLEARRANGE: UInt32 = 2505
let SCI_INDICSETSTYLE: UInt32 = 2080
let SCI_INDICSETFORE: UInt32 = 2082
let SCI_INDICSETALPHA: UInt32 = 2523
let SCI_INDICSETOUTLINEALPHA: UInt32 = 2558
let SCI_INDICSETUNDER: UInt32 = 2510

// Constantes de valor (no mensajes) usadas junto a los SCI_* de arriba.
let STYLE_DEFAULT: Int = 32
let STYLE_LINENUMBER: Int = 33
let SC_MARGIN_NUMBER: Int = 1
let SC_WRAP_NONE: Int = 0
let SC_WRAP_WORD: Int = 1
let SCWS_INVISIBLE: Int = 0
let SCWS_VISIBLEALWAYS: Int = 1
let SCFIND_WHOLEWORD: Int = 0x2
let SCFIND_MATCHCASE: Int = 0x4
let SCFIND_REGEXP: Int = 0x00200000
let SCFIND_CXX11REGEX: Int = 0x00800000
let INDIC_STRAIGHTBOX: Int = 8
/// Flag de SCNotification.updated: el cambio de UI incluyó cambio de contenido (no solo
/// caret/scroll/selección). Usado para filtrar cuándo refrescar la preview de Markdown.
let SC_UPDATE_CONTENT: Int = 0x1
/// Índice de indicador dedicado a highlight de búsqueda. Los indicadores 0-7 pueden estar
/// en uso por lexers/estilos; 9 está libre y fuera del rango típico usado por Scintilla/Lexilla.
let INDICATOR_FIND_HIGHLIGHT: Int = 9
/// Índice de indicador dedicado a marcar el match actual (distinto del resto pintado por
/// INDICATOR_FIND_HIGHLIGHT). 10 está libre por la misma razón que 9.
let INDICATOR_FIND_CURRENT: Int = 10

// Colores en formato 0x00BBGGRR (BGR), usado por SCI_STYLESETFORE/BACK.
func setStyle(_ editor: ScintillaView, _ style: Int, fore: sptr_t, back: sptr_t? = nil, fontStyle: Int? = nil) {
    _ = ScintillaView.directCall(editor, message: SCI_STYLESETFORE, wParam: uptr_t(style), lParam: fore)
    if let back {
        _ = ScintillaView.directCall(editor, message: SCI_STYLESETBACK, wParam: uptr_t(style), lParam: back)
    }
    // nil = STYLE_NOT_USED: el atributo no está en el XML, así que no se administra.
    // No hace falta apagarlos en ese caso: applyLanguage ya hizo SCI_STYLECLEARALL.
    if let fontStyle {
        let on: (Int) -> sptr_t = { (fontStyle & $0) != 0 ? 1 : 0 }
        _ = ScintillaView.directCall(editor, message: SCI_STYLESETBOLD, wParam: uptr_t(style), lParam: on(1))
        _ = ScintillaView.directCall(editor, message: SCI_STYLESETITALIC, wParam: uptr_t(style), lParam: on(2))
        _ = ScintillaView.directCall(editor, message: SCI_STYLESETUNDERLINE, wParam: uptr_t(style), lParam: on(4))
    }
}

/// Reemplaza el texto completo del documento actualmente adjunto al editor y re-colorea.
///
/// Usa SCI_CLEARALL + SCI_APPENDTEXT en vez de SCI_SETTEXT porque SETTEXT
/// determina el largo con strlen: cualquier NUL embebido truncaría el documento
/// ahí mismo, en silencio, y el siguiente guardado escribiría esa versión
/// truncada sobre el archivo original. APPENDTEXT recibe el largo explícito.
func loadText(_ editor: ScintillaView, _ text: String) {
    let bytes = Array(text.utf8)
    _ = ScintillaView.directCall(editor, message: SCI_CLEARALL, wParam: 0, lParam: 0)
    bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        _ = ScintillaView.directCall(
            editor, message: SCI_APPENDTEXT,
            wParam: uptr_t(buffer.count),
            lParam: sptr_t(bitPattern: UInt(bitPattern: base))
        )
    }
    _ = ScintillaView.directCall(editor, message: SCI_COLOURISE, wParam: 0, lParam: -1)
}

/// Lee el texto completo del documento actualmente adjunto al editor (para guardar a disco).
func currentText(_ editor: ScintillaView) -> String {
    let length = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
    guard length > 0 else { return "" }
    var buffer = [UInt8](repeating: 0, count: length + 1)
    buffer.withUnsafeMutableBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        _ = ScintillaView.directCall(editor, message: SCI_GETTEXT, wParam: uptr_t(length + 1), lParam: sptr_t(bitPattern: UInt(bitPattern: base)))
    }
    return String(decoding: buffer.prefix(length), as: UTF8.self)
}
