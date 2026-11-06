import Foundation
import Scintilla

// Indicadores propios de la app. Se usan 8-13 porque 0-7 pueden estar en uso por lexers.
//   8  = smart highlight (otras apariciones de la palabra seleccionada)
//   9  = resaltar todas las coincidencias de Find
//   10 = coincidencia actual de Find
//   11 = corrector ortográfico
//   12 = tags XML/HTML pareados
//   13 = cierre insertado por el autocierre (invisible; habilita el sobretipeo)

let INDICATOR_SMART_HIGHLIGHT: Int = 8
let INDICATOR_FIND_HIGHLIGHT: Int = 9
let INDICATOR_FIND_CURRENT: Int = 10
let INDICATOR_SPELL: Int = 11
let INDICATOR_TAG_MATCH: Int = 12
let INDICATOR_AUTO_CLOSE: Int = 13

/// Estilos, alphas y orden de dibujo. Los colores van aparte (`applyIndicatorColours`)
/// porque dependen del tema.
func configureIndicators(_ editor: ScintillaView) {
    for (indicator, fill, outline) in [(INDICATOR_SMART_HIGHLIGHT, 100, 200),
                                       (INDICATOR_FIND_HIGHLIGHT, 100, 200),
                                       (INDICATOR_FIND_CURRENT, 0, 255),
                                       (INDICATOR_TAG_MATCH, 100, 200)] {
        let id = uptr_t(indicator)
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETSTYLE, wParam: id, lParam: sptr_t(INDIC_ROUNDBOX))
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETUNDER, wParam: id, lParam: 1)
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETALPHA, wParam: id, lParam: sptr_t(fill))
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETOUTLINEALPHA, wParam: id, lParam: sptr_t(outline))
    }
    _ = ScintillaView.directCall(editor, message: SCI_INDICSETSTYLE, wParam: uptr_t(INDICATOR_AUTO_CLOSE), lParam: sptr_t(INDIC_HIDDEN))
    _ = ScintillaView.directCall(editor, message: SCI_INDICSETSTYLE, wParam: uptr_t(INDICATOR_SPELL), lParam: sptr_t(INDIC_SQUIGGLEPIXMAP))
    _ = ScintillaView.directCall(editor, message: SCI_INDICSETFORE, wParam: uptr_t(INDICATOR_SPELL), lParam: 0x0000E0)
    _ = ScintillaView.directCall(editor, message: SCI_INDICSETUNDER, wParam: uptr_t(INDICATOR_SPELL), lParam: 1)
}

/// Colores desde los estilos globales del tema (con respaldo BGR si el tema no los trae).
func applyIndicatorColours(_ editor: ScintillaView, theme: EditorTheme) {
    let table: [(Int, String, sptr_t)] = [
        (INDICATOR_FIND_HIGHLIGHT, "Incremental highlight all", 0x0080FF),
        (INDICATOR_FIND_CURRENT, "Find Mark Style", 0x0000FF),
        (INDICATOR_SMART_HIGHLIGHT, "Smart Highlighting", 0x00C000),
        (INDICATOR_TAG_MATCH, "Tags match highlighting", 0xD07A2E),
    ]
    for (indicator, name, fallback) in table {
        let colour = globalBackColour(name: name, theme: theme) ?? fallback
        _ = ScintillaView.directCall(editor, message: SCI_INDICSETFORE, wParam: uptr_t(indicator), lParam: colour)
    }
}
