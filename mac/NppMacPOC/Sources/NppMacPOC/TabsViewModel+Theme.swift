// Aplicación de tema, lenguaje forzado y estilos globales al editor compartido.
import AppKit
import Scintilla

extension TabsViewModel {
    // MARK: - Preferencias y tema

    /// Reaplica fuente/opciones de edición, el lenguaje del documento activo y los colores
    /// globales del tema. SCI_STYLECLEARALL (dentro de applyLanguage) propaga STYLE_DEFAULT
    /// a TODOS los estilos numerados, incluido STYLE_LINENUMBER — por eso el tema global debe
    /// reaplicarse después de applyLanguage en cada attach, o el número de línea/caret/selección
    /// quedan pisados por los colores de texto plano.
    func reapplyPreferencesAndTheme() {
        preferences.apply(to: editor) // fuente primero (ver nota en EditorPreferences.applyFont)
        // SCI_STYLECLEARALL (dentro de applyLanguage, más abajo) copia el STYLE_DEFAULT
        // ACTUAL a todos los estilos, incluido el 0 — no un valor neutro. Si el documento
        // anterior quedó teñido navy por un bloqueo (applyLockTint tiñe STYLE_DEFAULT
        // también), y el perfil nuevo no define estilos propios (ej. texto plano,
        // nullProfile en Language.swift), STYLECLEARALL propaga ese navy y nada lo
        // corrige después: applyGlobalStyle de abajo llega tarde para estilos que un
        // lenguaje sin stylers.xml nunca toca. Como ScintillaView es compartido entre
        // pestañas, el tinte se filtraba incluso a pestañas de texto plano que nunca se
        // bloquearon. Fijar acá el color real del tema en STYLE_DEFAULT, ANTES de
        // STYLECLEARALL, garantiza que lo que se propaga sea siempre el default correcto,
        // sin importar si el documento estaba bloqueado o si el lenguaje nuevo define
        // estilos propios.
        if let defaultStyle = globalStyle(name: "Default Style", theme: currentTheme) {
            setStyle(editor, STYLE_DEFAULT, fore: defaultStyle.fore, back: defaultStyle.back)
        }
        if let profile = activeDocument?.languageProfile {
            applyLanguage(editor, profile: profile)
        }
        applyGlobalStyle(theme: currentTheme)
        // Al final y condicional: applyLanguage (STYLECLEARALL) y applyGlobalStyle ya
        // dejaron los colores "normales" puestos, así que el tinte de bloqueo pisa encima
        // sin que un cambio de tema/lenguaje/preferencias lo pierda. Si el documento no
        // está bloqueado, no se toca nada más — los colores de arriba son el resultado final.
        // La minimapa copia los estilos del lenguaje y el tema: son de cada vista, no del
        // documento compartido.
        documentMap.applyStyle(profile: activeDocument?.languageProfile, theme: currentTheme, fontName: preferences.fontName)
        if activeDocument?.isLocked == true {
            applyLockTint(editor, theme: currentTheme)
        }
    }

    // MARK: - Forzar lenguaje manualmente (solo sesión, no persiste)

    func forceLanguage(_ langName: String) {
        guard let document = activeDocument else { return }
        let profile = languageProfile(byLanguageName: langName, theme: currentTheme)
        document.forcedLanguageName = langName
        document.languageProfile = profile
        objectWillChange.send()
        // Mismo motivo que en applyTheme/saveActiveAs: ir directo a applyLanguage salta el
        // reset de STYLE_DEFAULT previo a STYLECLEARALL y el reaplicado del tinte de bloqueo
        // que reapplyPreferencesAndTheme() hace en orden — en un documento bloqueado eso deja
        // el tinte a medio aplicar y puede pisar número de línea/caret/selección.
        reapplyPreferencesAndTheme()
    }

    // MARK: - Colores globales (applyTheme está en Document.swift)

    /// Fondo de la línea actual. Scintilla 5: SETCARETLINEVISIBLE(1) recrea el elemento en
    /// amarillo y SETCARETLINEBACK sin elemento lo crea con alpha 0, así que se maneja el
    /// elemento directo. El color es ColourRGBA (alpha en el byte alto, BGR en los bajos).
    func applyCaretLine(theme: EditorTheme? = nil) {
        let theme = theme ?? currentTheme
        // El E8E8FF del tema claro es indistinguible del tinte de bloqueo (E8EFF9).
        let lockedBack = activeDocument?.isLocked == true
            ? hexRRGGBBToScintillaBGR(theme == .dark ? "1C2F4D" : "D3DFF2") : nil
        guard preferences.highlightCurrentLine,
              let back = lockedBack ?? globalBackColour(name: "Current line background colour", theme: theme) else {
            _ = ScintillaView.directCall(editor, message: SCI_RESETELEMENTCOLOUR, wParam: uptr_t(SC_ELEMENT_CARET_LINE_BACK), lParam: 0)
            return
        }
        _ = ScintillaView.directCall(editor, message: SCI_SETELEMENTCOLOUR, wParam: uptr_t(SC_ELEMENT_CARET_LINE_BACK), lParam: back | 0xFF000000)
        _ = ScintillaView.directCall(editor, message: SCI_SETCARETLINEVISIBLEALWAYS, wParam: 1, lParam: 0)
    }

    /// Colores globales del tema (no ligados a un lenguaje): fondo/texto por defecto, número
    /// de línea, selección, caret e indicadores. Nombres confirmados leyendo <GlobalStyles>
    /// real de stylers.model.xml/DarkModeDefault.xml.
    private func applyGlobalStyle(theme: EditorTheme) {
        if let defaultStyle = globalStyle(name: "Default Style", theme: theme) {
            setStyle(editor, STYLE_DEFAULT, fore: defaultStyle.fore, back: defaultStyle.back)
        }
        if let lineNumber = globalStyle(name: "Line number margin", theme: theme) {
            setStyle(editor, STYLE_LINENUMBER, fore: lineNumber.fore, back: lineNumber.back)
        }
        // Notepad++ hace lo mismo (ScintillaEditView.cpp:3192): sin color propio para la
        // selección inactiva, con el foco en la barra de búsqueda la coincidencia actual se pinta
        // con el gris del sistema (unemphasizedSelectedTextBackgroundColor) en vez del del tema.
        // Sin el estilo en el tema se resetea, para no heredar el color del tema anterior.
        let selection = globalStyle(name: "Selected text colour", theme: theme)?.back
        let multi = globalBackColour(name: "Multi-selected text color", theme: theme)
        for (colour, elements) in [(selection, [SC_ELEMENT_SELECTION_BACK, SC_ELEMENT_SELECTION_INACTIVE_BACK]),
                                   (multi, [SC_ELEMENT_SELECTION_ADDITIONAL_BACK, SC_ELEMENT_SELECTION_INACTIVE_ADDITIONAL_BACK])] {
            for element in elements {
                if let colour {
                    _ = ScintillaView.directCall(editor, message: SCI_SETELEMENTCOLOUR, wParam: uptr_t(element), lParam: colour | 0xFF000000)
                } else {
                    _ = ScintillaView.directCall(editor, message: SCI_RESETELEMENTCOLOUR, wParam: uptr_t(element), lParam: 0)
                }
            }
        }
        applyIndicatorColours(editor, theme: theme)
        applyBookmarkAndFoldColors(editor, theme: theme)
        if let edge = globalStyle(name: "Edge colour", theme: theme) {
            _ = ScintillaView.directCall(editor, message: SCI_SETEDGECOLOUR, wParam: uptr_t(edge.fore), lParam: 0)
        }
        if let guide = globalStyle(name: "Indent guideline style", theme: theme) {
            setStyle(editor, STYLE_INDENTGUIDE, fore: guide.fore, back: guide.back)
        }
        if let brace = globalStyle(name: "Brace highlight style", theme: theme) {
            setStyle(editor, STYLE_BRACELIGHT, fore: brace.fore, back: brace.back)
            _ = ScintillaView.directCall(editor, message: SCI_STYLESETBOLD, wParam: uptr_t(STYLE_BRACELIGHT), lParam: 1)
        }
        if let bad = globalStyle(name: "Bad brace colour", theme: theme) {
            setStyle(editor, STYLE_BRACEBAD, fore: bad.fore, back: bad.back)
        }
        applyCaretLine(theme: theme)
        if let caret = globalStyle(name: "Caret colour", theme: theme) {
            // SetCaretFore=2069(colour fore,) — el color va en wParam, no en lParam (confirmado
            // contra scintilla/include/Scintilla.iface). Invertido pisaba el caret a negro.
            _ = ScintillaView.directCall(editor, message: SCI_SETCARETFORE, wParam: uptr_t(caret.fore), lParam: 0)
        }
    }
}
