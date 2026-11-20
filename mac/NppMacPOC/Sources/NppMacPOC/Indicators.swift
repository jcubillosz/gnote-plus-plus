import Foundation
import Scintilla

// Indicadores propios de la app. Se usan 8-15 porque 0-7 pueden estar en uso por lexers.
//   8  = smart highlight (otras apariciones de la palabra seleccionada)
//   9  = resaltar todas las coincidencias de Find
//   10 = coincidencia actual de Find
//   11 = corrector ortográfico
//   12 = tags XML/HTML pareados
//   13 = cierre insertado por el autocierre (invisible; habilita el sobretipeo)
//   14 = marcas de "Marcar todo" (persisten hasta Borrar marcas)
//   15 = colores CSS (subrayado del color de cada literal; CSSColors.swift)
//   16 = campos del fragmento activo (invisible; valor = número de campo + 1; Snippets.swift)
//   17 = coincidencias del probador de regex (RegexTester.swift)
//   18 = grupos de la coincidencia seleccionada en el probador

let INDICATOR_SMART_HIGHLIGHT: Int = 8
let INDICATOR_FIND_HIGHLIGHT: Int = 9
let INDICATOR_FIND_CURRENT: Int = 10
let INDICATOR_SPELL: Int = 11
let INDICATOR_TAG_MATCH: Int = 12
let INDICATOR_AUTO_CLOSE: Int = 13
let INDICATOR_MARK: Int = 14
let INDICATOR_CSS_COLOR: Int = 15
let INDICATOR_SNIPPET_FIELD: Int = 16
let INDICATOR_REGEX_TEST: Int = 17
let INDICATOR_REGEX_GROUP: Int = 18

/// Estilos, alphas y orden de dibujo. Los colores van aparte (`applyIndicatorColours`)
/// porque dependen del tema.
func configureIndicators(_ editor: ScintillaView) {
    for (indicator, fill, outline) in [(INDICATOR_SMART_HIGHLIGHT, 100, 200),
                                       (INDICATOR_FIND_HIGHLIGHT, 100, 200),
                                       (INDICATOR_MARK, 100, 200),
                                       (INDICATOR_FIND_CURRENT, 0, 255),
                                       (INDICATOR_TAG_MATCH, 100, 200),
                                       (INDICATOR_REGEX_TEST, 100, 200)] {
        let id = uptr_t(indicator)
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETSTYLE, wParam: id, lParam: sptr_t(INDIC_ROUNDBOX))
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETUNDER, wParam: id, lParam: 1)
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETALPHA, wParam: id, lParam: sptr_t(fill))
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETOUTLINEALPHA, wParam: id, lParam: sptr_t(outline))
    }
    _ = ScintillaView.directCall(editor, message: SCI_INDICSETSTYLE, wParam: uptr_t(INDICATOR_AUTO_CLOSE), lParam: sptr_t(INDIC_HIDDEN))
    _ = ScintillaView.directCall(editor, message: SCI_INDICSETSTYLE, wParam: uptr_t(INDICATOR_SNIPPET_FIELD), lParam: sptr_t(INDIC_HIDDEN))
    _ = ScintillaView.directCall(editor, message: SCI_INDICSETSTYLE, wParam: uptr_t(INDICATOR_REGEX_GROUP), lParam: sptr_t(INDIC_BOX))
    _ = ScintillaView.directCall(editor, message: SCI_INDICSETUNDER, wParam: uptr_t(INDICATOR_REGEX_GROUP), lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_INDICSETSTYLE, wParam: uptr_t(INDICATOR_SPELL), lParam: sptr_t(INDIC_SQUIGGLEPIXMAP))
    _ = ScintillaView.directCall(editor, message: SCI_INDICSETFORE, wParam: uptr_t(INDICATOR_SPELL), lParam: 0x0000E0)
    _ = ScintillaView.directCall(editor, message: SCI_INDICSETUNDER, wParam: uptr_t(INDICATOR_SPELL), lParam: 1)
    // Sin color propio: cada tramo lleva el de su literal como valor.
    _ = ScintillaView.directCall(editor, message: SCI_INDICSETSTYLE, wParam: uptr_t(INDICATOR_CSS_COLOR), lParam: sptr_t(INDIC_COMPOSITIONTHICK))
    _ = ScintillaView.directCall(editor, message: SCI_INDICSETFLAGS, wParam: uptr_t(INDICATOR_CSS_COLOR), lParam: sptr_t(SC_INDICFLAG_VALUEFORE))
}

/// Colores desde los estilos globales del tema (con respaldo BGR si el tema no los trae).
func applyIndicatorColours(_ editor: ScintillaView, theme: EditorTheme) {
    let table: [(Int, String, sptr_t)] = [
        (INDICATOR_FIND_HIGHLIGHT, "Incremental highlight all", 0x0080FF),
        (INDICATOR_FIND_CURRENT, "Find Mark Style", 0x0000FF),
        // "Mark Style 1" y no "Find Mark Style": la marca persiste mientras la coincidencia actual
        // (indicador 10) se mueve con ese mismo color; con el mismo tono no se distinguirían.
        (INDICATOR_MARK, "Mark Style 1", 0xFFFF00),
        (INDICATOR_SMART_HIGHLIGHT, "Smart Highlighting", 0x00C000),
        (INDICATOR_TAG_MATCH, "Tags match highlighting", 0xD07A2E),
        (INDICATOR_REGEX_TEST, "Mark Style 2", 0x00FFFF),
        (INDICATOR_REGEX_GROUP, "Find Mark Style", 0x0000FF),
    ]
    for (indicator, name, fallback) in table {
        let colour = globalBackColour(name: name, theme: theme) ?? fallback
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETFORE, wParam: uptr_t(indicator), lParam: colour)
    }
}
