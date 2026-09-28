import Scintilla

// IDs de mensajes Scintilla (SCI_*), confirmados contra scintilla/include/Scintilla.iface —
// no inventar números nuevos sin volver a confirmar ahí.
let SCI_CLEARALL: UInt32 = 2004
let SCI_GETLENGTH: UInt32 = 2006
let SCI_GETSTYLEAT: UInt32 = 2010
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
let SCI_SETREADONLY: UInt32 = 2171
let SCI_GETREADONLY: UInt32 = 2140
let SCI_EMPTYUNDOBUFFER: UInt32 = 2175
let SCI_LINEFROMPOSITION: UInt32 = 2166
let SCI_POSITIONFROMLINE: UInt32 = 2167
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
let SCI_SETUNDOCOLLECTION: UInt32 = 2012
let SCI_SETKEYWORDS: UInt32 = 4005
let SCI_SETILEXER: UInt32 = 4033
let SCI_SETPROPERTY: UInt32 = 4004
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
let SCI_REPLACESEL: UInt32 = 2170
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
/// Último estilo numerado válido: el tinte de bloqueo recorre 0...STYLE_MAX para cubrir
/// todos los estilos de sintaxis, sin importar cuáles use el lenguaje activo.
let STYLE_MAX: Int = 255
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
/// Flag de SCNotification.updated: cambió la posición de scroll vertical. Usado para
/// sincronizar el scroll de la vista previa de Markdown con el editor.
let SC_UPDATE_V_SCROLL: Int = 0x4
/// Códigos de SCNotification.nmhdr.code: el documento cruzó el savepoint (el punto que
/// SCI_SETSAVEPOINT marcó como "sin cambios"). Reached = volvió a coincidir con el
/// savepoint (undo hasta el original, o SCI_SETSAVEPOINT); Left = se alejó por primera vez.
/// Más confiable que SC_UPDATE_CONTENT para el punto de "sin guardar": ese último también
/// se dispara al recolorear (SCI_COLOURISE), sin cambios reales de contenido.
let SCN_SAVEPOINTREACHED: Int32 = 2002
let SCN_SAVEPOINTLEFT: Int32 = 2003
/// Se dispara cuando el usuario intenta modificar un documento en modo solo-lectura
/// (SCI_SETREADONLY). Usado para el pulso del ícono de candado (bloqueo por documento).
let SCN_MODIFYATTEMPTRO: Int32 = 2004
/// Se dispara cuando se suelta uno o más archivos/carpetas de Finder sobre el editor
/// (Task 12, drag&drop). ScintillaView ya se registra para NSPasteboardTypeFileURL y
/// consume el drop él mismo (PerformDragOperation en ScintillaCocoa.mm) antes de que
/// cualquier .onDrop de SwiftUI vea el evento — por eso el drop sobre el área del editor
/// se atiende acá, no con un overlay. Una notificación por cada URL soltada;
/// notification.pointee.text trae la ruta.
let SCN_URIDROPPED: Int32 = 2015
/// Se dispara ante cualquier modificación del documento (inserción, borrado, cambio de
/// estilo, plegado, etc. — ver `modificationType`). A diferencia de SC_UPDATE_CONTENT (que
/// también se enciende por el recoloreo perezoso del lexer al hacer scroll, sin texto
/// nuevo), acá se puede filtrar por el tipo exacto de cambio.
let SCN_MODIFIED: Int32 = 2008
/// Flags de SCNotification.modificationType: solo estos dos representan una edición real
/// de texto. SC_MOD_CHANGESTYLE (recoloreo del lexer) y el resto se ignoran a propósito.
let SC_MOD_INSERTTEXT: Int = 0x1
let SC_MOD_DELETETEXT: Int = 0x2
let SCI_GETFIRSTVISIBLELINE: UInt32 = 2152
let SCI_LINESONSCREEN: UInt32 = 2370
let SCI_SETFIRSTVISIBLELINE: UInt32 = 2613
let SCI_GETXOFFSET: UInt32 = 2398
let SCI_SETXOFFSET: UInt32 = 2397
let SCI_SETSELECTIONSERIALIZED: UInt32 = 2784
let SCI_GETSELECTIONSERIALIZED: UInt32 = 2785
/// Índice de indicador dedicado a highlight de búsqueda. Los indicadores 0-7 pueden estar
/// en uso por lexers/estilos; 9 está libre y fuera del rango típico usado por Scintilla/Lexilla.
let INDICATOR_FIND_HIGHLIGHT: Int = 9
/// Índice de indicador dedicado a marcar el match actual (distinto del resto pintado por
/// INDICATOR_FIND_HIGHLIGHT). 10 está libre por la misma razón que 9.
let INDICATOR_FIND_CURRENT: Int = 10
/// Índice de indicador dedicado al subrayado ortográfico (Task 10). 11 sigue libre por la
/// misma razón que 9/10.
let INDICATOR_SPELL: Int = 11
/// Estilo de indicador "squiggle" (subrayado ondulado, tipo corrector ortográfico nativo de
/// macOS). Confirmado en scintilla/include/Scintilla.iface como INDIC_SQUIGGLEPIXMAP=13.
let INDIC_SQUIGGLEPIXMAP: Int = 13
/// Devuelve el texto (y su largo) entre SCI_SETTARGETSTART/SCI_SETTARGETEND, como bytes UTF-8.
/// A diferencia de SCI_GETTEXTRANGE no requiere construir el struct Sci_TextRange desde Swift.
let SCI_GETTARGETTEXT: UInt32 = 2687
/// Task 11 (menú contextual del corrector): convierte un punto (x,y) de la vista en una
/// posición del documento, para saber sobre qué palabra cayó el clic derecho.
let SCI_POSITIONFROMPOINT: UInt32 = 2022
/// Valor del indicador en una posición dada (wParam=indicador, lParam=posición). Con
/// INDICATOR_SPELL distinto de 0 significa que esa posición está bajo el squiggle rojo.
let SCI_INDICATORVALUEAT: UInt32 = 2507
/// Inicio/fin del tramo contiguo de un indicador que contiene la posición dada (wParam=
/// indicador, lParam=posición) — da el rango exacto de la palabra subrayada.
let SCI_INDICATORSTART: UInt32 = 2508
let SCI_INDICATOREND: UInt32 = 2509

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

/// Serializa la selección actual (incluye multi-cursor) a un string opaco de Scintilla,
/// para poder restaurarla después de un SCI_SETDOCPOINTER a otro documento. Mismo patrón
/// de dos llamadas que currentText: primero se pide el largo (lParam 0), después se llena
/// el buffer.
func selectionSerialized(_ editor: ScintillaView) -> String {
    let length = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONSERIALIZED, wParam: 0, lParam: 0))
    guard length > 0 else { return "" }
    var buffer = [UInt8](repeating: 0, count: length + 1)
    buffer.withUnsafeMutableBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        _ = ScintillaView.directCall(editor, message: SCI_GETSELECTIONSERIALIZED, wParam: 0, lParam: sptr_t(bitPattern: UInt(bitPattern: base)))
    }
    return String(decoding: buffer.prefix(length), as: UTF8.self)
}

/// Restaura una selección serializada previamente con selectionSerialized. Una selección
/// fuera de rango (por ejemplo tras un reload que acortó el documento) se acota sola.
func setSelectionSerialized(_ editor: ScintillaView, _ s: String) {
    s.withCString { cstr in
        _ = ScintillaView.directCall(editor, message: SCI_SETSELECTIONSERIALIZED, wParam: 0, lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
    }
}
