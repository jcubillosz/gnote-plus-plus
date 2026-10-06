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
/// Task 11 (menú contextual del corrector): convierte un punto (x,y) en coordenadas de
/// cliente de Scintilla en una posición del documento, o -1 si no cae sobre un carácter.
let SCI_POSITIONFROMPOINTCLOSE: UInt32 = 2023
/// Para reconstruir el ancho total de márgenes (ViewStyle::fixedColumnWidth): margen
/// izquierdo + suma de SCI_GETMARGINWIDTHN de cada margen.
let SCI_GETMARGINLEFT: UInt32 = 2156
let SCI_GETMARGINWIDTHN: UInt32 = 2243
let SCI_GETMARGINS: UInt32 = 2253
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
    // Un documento bloqueado ya tiene SCI_SETREADONLY(1) cuando se carga (attachToEditor corre
    // antes que loadText al abrir/restaurar sesión), y Scintilla ignora CLEARALL/APPENDTEXT en
    // solo lectura: el archivo bloqueado se abría en blanco (bug real de QA manual). La carga
    // no es una edición del usuario, así que se suspende el solo-lectura y se restaura después.
    let wasReadOnly = ScintillaView.directCall(editor, message: SCI_GETREADONLY, wParam: 0, lParam: 0) != 0
    if wasReadOnly {
        _ = ScintillaView.directCall(editor, message: SCI_SETREADONLY, wParam: 0, lParam: 0)
    }
    defer {
        if wasReadOnly {
            _ = ScintillaView.directCall(editor, message: SCI_SETREADONLY, wParam: 1, lParam: 0)
        }
    }
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

// Operaciones de línea (LineOperations.swift) — equivalentes a IDM_EDIT_* de Notepad++
// (PowerEditor/src/menuCmdID.h).
let SCI_BEGINUNDOACTION: UInt32 = 2078
let SCI_ENDUNDOACTION: UInt32 = 2079
let SCI_SELECTIONDUPLICATE: UInt32 = 2469
let SCI_MOVESELECTEDLINESUP: UInt32 = 2620
let SCI_MOVESELECTEDLINESDOWN: UInt32 = 2621
let SCI_LINEDELETE: UInt32 = 2338
let SCI_TARGETFROMSELECTION: UInt32 = 2287
let SCI_LINESJOIN: UInt32 = 2288
let SCI_UPPERCASE: UInt32 = 2341
let SCI_LOWERCASE: UInt32 = 2340
let SCI_SETTARGETRANGE: UInt32 = 2686
let SCI_GETLINEENDPOSITION: UInt32 = 2136

// Smart highlight (SmartHighlight.swift).
let SCI_WORDSTARTPOSITION: UInt32 = 2266
let SCI_WORDENDPOSITION: UInt32 = 2267
let SC_UPDATE_SELECTION: Int = 0x2
let INDIC_ROUNDBOX: Int = 7
/// 8: libre, debajo de los de Find (9/10) y el corrector (11).
let INDICATOR_SMART_HIGHLIGHT: Int = 8

// Marcadores y plegado (Bookmarks.swift, NppMacPOCApp.init, applyLanguage).
let SC_MARGIN_SYMBOL: Int = 0
let SCI_SETMARGINMASKN: UInt32 = 2244
let SCI_SETMARGINSENSITIVEN: UInt32 = 2246
let SCI_MARKERDEFINE: UInt32 = 2040
let SCI_MARKERSETFORE: UInt32 = 2041
let SCI_MARKERSETBACK: UInt32 = 2042
let SCI_MARKERADD: UInt32 = 2043
let SCI_MARKERDELETE: UInt32 = 2044
let SCI_MARKERDELETEALL: UInt32 = 2045
let SCI_MARKERGET: UInt32 = 2046
let SCI_MARKERNEXT: UInt32 = 2047
let SCI_MARKERPREVIOUS: UInt32 = 2048
let SCI_SETAUTOMATICFOLD: UInt32 = 2663
let SC_AUTOMATICFOLD_SHOW: Int = 0x1
let SC_AUTOMATICFOLD_CLICK: Int = 0x2
let SC_AUTOMATICFOLD_CHANGE: Int = 0x4
let SCI_FOLDALL: UInt32 = 2662
let SC_FOLDACTION_CONTRACT: Int = 0
let SC_FOLDACTION_EXPAND: Int = 1
let SCI_SETFOLDMARGINCOLOUR: UInt32 = 2290
let SCI_SETFOLDMARGINHICOLOUR: UInt32 = 2291
let SCI_SETFOLDFLAGS: UInt32 = 2233
let SC_FOLDFLAG_LINEAFTER_CONTRACTED: Int = 0x10
let SCN_MARGINCLICK: Int32 = 2010
/// Máscara de los 7 markers de plegado (25–31).
let SC_MASK_FOLDERS: Int = 0xFE000000
let SC_MARKNUM_FOLDEREND: Int = 25
let SC_MARKNUM_FOLDEROPENMID: Int = 26
let SC_MARKNUM_FOLDERMIDTAIL: Int = 27
let SC_MARKNUM_FOLDERTAIL: Int = 28
let SC_MARKNUM_FOLDERSUB: Int = 29
let SC_MARKNUM_FOLDER: Int = 30
let SC_MARKNUM_FOLDEROPEN: Int = 31
let SC_MARK_VLINE: Int = 9
let SC_MARK_LCORNER: Int = 10
let SC_MARK_TCORNER: Int = 11
let SC_MARK_BOXPLUS: Int = 12
let SC_MARK_BOXPLUSCONNECTED: Int = 13
let SC_MARK_BOXMINUS: Int = 14
let SC_MARK_BOXMINUSCONNECTED: Int = 15
let SC_MARK_BOOKMARK: Int = 31
/// Marker de marcadores de usuario: 20. Los 21–24 son del historial de cambios de Scintilla
/// (SC_MARKNUM_HISTORY_*) y 25–31 del plegado.
let MARKER_BOOKMARK: Int = 20
/// Márgenes: 0 = marcadores, 1 = números de línea, 2 = plegado, 3 = historial de cambios.
let MARGIN_BOOKMARKS: Int = 0
let MARGIN_FOLD: Int = 2
let SCN_CHARADDED: Int32 = 2001

// Llaves/tags, zoom y fin de línea (BraceMatcher.swift, EditorPreferences, Codificación).
let SCI_GETCHARAT: UInt32 = 2007
let SCI_BRACEHIGHLIGHT: UInt32 = 2351
let SCI_BRACEBADLIGHT: UInt32 = 2352
let SCI_BRACEMATCH: UInt32 = 2353
let STYLE_BRACELIGHT: Int = 34
let STYLE_BRACEBAD: Int = 35
/// 12: libre (8 smart highlight, 9/10 Find, 11 corrector).
let INDICATOR_TAG_MATCH: Int = 12
let SCI_SETZOOM: UInt32 = 2373
let SCI_CONVERTEOLS: UInt32 = 2029

// Selección múltiple (MultiSelection.swift).
let SCI_SETMULTIPLESELECTION: UInt32 = 2563
let SCI_SETADDITIONALSELECTIONTYPING: UInt32 = 2565
let SCI_SETMULTIPASTE: UInt32 = 2614
let SC_MULTIPASTE_EACH: Int = 1
let SCI_SETRECTANGULARSELECTIONMODIFIER: UInt32 = 2598
let SCMOD_ALT: Int = 4
let SCI_TARGETWHOLEDOCUMENT: UInt32 = 2690
let SCI_MULTIPLESELECTADDNEXT: UInt32 = 2688
let SCI_MULTIPLESELECTADDEACH: UInt32 = 2689
let SCI_ADDSELECTION: UInt32 = 2573
let SCI_GETSELECTIONS: UInt32 = 2570
let SCI_GETSELECTIONNCARET: UInt32 = 2577
let SCI_FINDCOLUMN: UInt32 = 2456

// Autocompletado (AutoComplete.swift).
let SCI_AUTOCSHOW: UInt32 = 2100
let SCI_AUTOCCANCEL: UInt32 = 2101
let SCI_AUTOCSETIGNORECASE: UInt32 = 2115
let SCI_AUTOCSETORDER: UInt32 = 2660
let SC_ORDER_PERFORMSORT: Int = 1
let SCI_AUTOCSETMAXHEIGHT: UInt32 = 2210

// Minimapa (DocumentMap.swift).
let SCI_GETDOCPOINTER: UInt32 = 2357
let SCI_SETVSCROLLBAR: UInt32 = 2280
let SCI_SETHSCROLLBAR: UInt32 = 2130
let SCI_SETCARETSTYLE: UInt32 = 2512
let CARETSTYLE_INVISIBLE: Int = 0
let SCI_SETCARETLINEVISIBLE: UInt32 = 2096
let SCI_TEXTHEIGHT: UInt32 = 2279
let SCI_DOCLINEFROMVISIBLE: UInt32 = 2221
let SCI_VISIBLEFROMDOCLINE: UInt32 = 2220

/// Primera línea DEL DOCUMENTO visible en el editor. SCI_GETFIRSTVISIBLELINE devuelve una
/// línea de pantalla: con ajuste de línea (o bloques plegados) no coincide con las líneas
/// del documento y puede superar SCI_GETLINECOUNT — usada como línea del documento,
/// SCI_POSITIONFROMLINE devolvía -1 y uptr_t(-1) crasheaba al abrir la app (sesión restaurada
/// con scroll cerca del final de un documento con ajuste de línea).
func firstVisibleDocumentLine(_ editor: ScintillaView) -> Int {
    let display = ScintillaView.directCall(editor, message: SCI_GETFIRSTVISIBLELINE, wParam: 0, lParam: 0)
    return Int(ScintillaView.directCall(editor, message: SCI_DOCLINEFROMVISIBLE, wParam: uptr_t(max(0, display)), lParam: 0))
}
