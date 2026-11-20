import Foundation
import SwiftUI
import Scintilla

/// Preferencias de edición globales (no por lenguaje ni por documento), persistidas entre
/// sesiones vía @AppStorage.
final class EditorPreferences: ObservableObject {
    // @Published + didSet, NO @AppStorage: dentro de una clase, @AppStorage persiste pero
    // no dispara objectWillChange, así que ninguna vista se entera del cambio. Ese era el
    // bug de los checks del menú Vista, que ejecutaban la acción sin actualizar la marca.
    @Published var fontName: String { didSet { store(fontName, "editor.fontName") } }
    @Published var fontSize: Double { didSet { store(fontSize, "editor.fontSize") } }
    @Published var useTabs: Bool { didSet { store(useTabs, "editor.useTabs") } }
    @Published var tabWidth: Int { didSet { store(tabWidth, "editor.tabWidth") } }
    @Published var wordWrap: Bool { didSet { store(wordWrap, "editor.wordWrap") } }
    @Published var showLineNumbers: Bool { didSet { store(showLineNumbers, "editor.showLineNumbers") } }
    @Published var showWhitespace: Bool { didSet { store(showWhitespace, "editor.showWhitespace") } }
    @Published var highlightCurrentLine: Bool { didSet { store(highlightCurrentLine, "editor.highlightCurrentLine") } }
    @Published var showEOL: Bool { didSet { store(showEOL, "editor.showEOL") } }
    @Published var showIndentGuides: Bool { didSet { store(showIndentGuides, "editor.showIndentGuides") } }
    @Published var showEdge: Bool { didSet { store(showEdge, "editor.showEdge") } }
    @Published var edgeColumn: Int { didSet { store(edgeColumn, "editor.edgeColumn") } }
    @Published var showFoldMargin: Bool { didSet { store(showFoldMargin, "editor.showFoldMargin") } }
    /// Puntos de zoom de Scintilla (SCI_SETZOOM), persistido: el ScintillaView es uno solo y
    /// compartido, así que el zoom es global, no por documento.
    @Published var zoom: Int { didSet { store(zoom, "editor.zoom") } }
    /// Autocompletado en lenguajes de programación (nunca en texto plano/Markdown).
    @Published var autoComplete: Bool { didSet { store(autoComplete, "editor.autoComplete") } }
    /// Minimapa a la derecha del editor (DocumentMap.swift).
    @Published var showDocumentMap: Bool { didSet { store(showDocumentMap, "editor.showDocumentMap") } }
    /// Ruta de navegación (carpetas › archivo › símbolos) sobre el editor (Breadcrumbs.swift).
    @Published var showBreadcrumbs: Bool { didSet { store(showBreadcrumbs, "editor.showBreadcrumbs") } }
    /// Barra de líneas modificadas/guardadas (EditorExtras.swift). El historial se registra
    /// siempre; esto solo muestra u oculta el margen.
    @Published var showChangeHistory: Bool { didSet { store(showChangeHistory, "editor.showChangeHistory") } }
    /// Margen de cambios respecto de HEAD (GitGutter.swift).
    @Published var showGitGutter: Bool { didSet { store(showGitGutter, "git.showGutter") } }
    @Published var snippetsEnabled: Bool { didSet { store(snippetsEnabled, "snippets.enabled") } }
    /// Encabezado fijo del símbolo actual sobre el editor (StickyHeader.swift).
    @Published var stickyScroll: Bool { didSet { store(stickyScroll, "view.stickyScroll") } }
    /// Autor y fecha del commit de la línea del cursor (GitBlame.swift).
    @Published var showInlineBlame: Bool { didSet { store(showInlineBlame, "git.inlineBlame") } }
    @Published var autoCloseBrackets: Bool { didSet { store(autoCloseBrackets, "editor.autoCloseBrackets") } }
    /// Sangría automática al escribir (AutoIndent.swift).
    @Published var autoIndent: Bool { didSet { store(autoIndent, "editor.autoIndent") } }
    @Published var markdownLargeToolbar: Bool { didSet { store(markdownLargeToolbar, "markdown.largeToolbar") } }
    @Published var backupEnabled: Bool { didSet { store(backupEnabled, "session.backup") } }
    /// Apagado por defecto, como en Notepad++: cambia líneas que el usuario no tocó.
    @Published var trimTrailingWhitespaceOnSave: Bool { didSet { store(trimTrailingWhitespaceOnSave, "editor.trimOnSave") } }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    init() {
        let defaults = UserDefaults.standard
        fontName = defaults.string(forKey: "editor.fontName") ?? "Menlo"
        // `object(forKey:)` y no `double/bool/integer(forKey:)`: esos devuelven 0/false
        // cuando la clave no existe, lo que pisaría los defaults en el primer arranque.
        fontSize = (defaults.object(forKey: "editor.fontSize") as? Double) ?? 13
        useTabs = (defaults.object(forKey: "editor.useTabs") as? Bool) ?? true
        tabWidth = (defaults.object(forKey: "editor.tabWidth") as? Int) ?? 4
        wordWrap = (defaults.object(forKey: "editor.wordWrap") as? Bool) ?? false
        showLineNumbers = (defaults.object(forKey: "editor.showLineNumbers") as? Bool) ?? true
        showWhitespace = (defaults.object(forKey: "editor.showWhitespace") as? Bool) ?? false
        highlightCurrentLine = (defaults.object(forKey: "editor.highlightCurrentLine") as? Bool) ?? true
        showEOL = (defaults.object(forKey: "editor.showEOL") as? Bool) ?? false
        showIndentGuides = (defaults.object(forKey: "editor.showIndentGuides") as? Bool) ?? true
        showEdge = (defaults.object(forKey: "editor.showEdge") as? Bool) ?? false
        edgeColumn = (defaults.object(forKey: "editor.edgeColumn") as? Int) ?? 80
        showFoldMargin = (defaults.object(forKey: "editor.showFoldMargin") as? Bool) ?? true
        zoom = (defaults.object(forKey: "editor.zoom") as? Int) ?? 0
        autoComplete = (defaults.object(forKey: "editor.autoComplete") as? Bool) ?? true
        showDocumentMap = (defaults.object(forKey: "editor.showDocumentMap") as? Bool) ?? true
        showBreadcrumbs = (defaults.object(forKey: "editor.showBreadcrumbs") as? Bool) ?? true
        showChangeHistory = (defaults.object(forKey: "editor.showChangeHistory") as? Bool) ?? true
        showGitGutter = (defaults.object(forKey: "git.showGutter") as? Bool) ?? true
        snippetsEnabled = (defaults.object(forKey: "snippets.enabled") as? Bool) ?? true
        stickyScroll = (defaults.object(forKey: "view.stickyScroll") as? Bool) ?? false
        showInlineBlame = (defaults.object(forKey: "git.inlineBlame") as? Bool) ?? false
        autoCloseBrackets = (defaults.object(forKey: "editor.autoCloseBrackets") as? Bool) ?? true
        autoIndent = (defaults.object(forKey: "editor.autoIndent") as? Bool) ?? true
        markdownLargeToolbar = (defaults.object(forKey: "markdown.largeToolbar") as? Bool) ?? false
        backupEnabled = (defaults.object(forKey: "session.backup") as? Bool) ?? true
        trimTrailingWhitespaceOnSave = (defaults.object(forKey: "editor.trimOnSave") as? Bool) ?? false
    }

    /// IMPORTANTE: llamar ANTES de applyLanguage(). SCI_STYLECLEARALL (dentro de
    /// applyLanguage) copia la apariencia de STYLE_DEFAULT a todos los estilos numerados,
    /// incluyendo fuente/tamaño — si se llama después, el tema pisa el fondo/color pero la
    /// fuente ya quedó propagada correctamente porque STYLESETFONT/SIZE se hizo antes del clear.
    func applyFont(to editor: ScintillaView) {
        fontName.withCString { cstr in
            _ = ScintillaView.directCall(editor, message: SCI_STYLESETFONT, wParam: uptr_t(STYLE_DEFAULT), lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
        }
        _ = ScintillaView.directCall(editor, message: SCI_STYLESETSIZE, wParam: uptr_t(STYLE_DEFAULT), lParam: sptr_t(Int(fontSize)))
    }

    /// .editorconfig del documento activo: pisa tabs/indentación globales solo para él. Scintilla
    /// guarda useTabs/tabWidth/indent por documento, así que se reaplica junto con las globales.
    var activeEditorConfig: EditorConfigProperties?

    func applyEditingOptions(to editor: ScintillaView) {
        _ = ScintillaView.directCall(editor, message: SCI_SETUSETABS, wParam: uptr_t(((activeEditorConfig?.indentStyle).map { $0 == "tab" } ?? useTabs) ? 1 : 0), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETTABWIDTH, wParam: uptr_t(activeEditorConfig?.tabWidth ?? tabWidth), lParam: 0)
        // indent 0 = usar el ancho de tabulación; se reinicia siempre porque viaja con el documento.
        _ = ScintillaView.directCall(editor, message: SCI_SETINDENT, wParam: uptr_t(activeEditorConfig?.indentSize ?? 0), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETWRAPMODE, wParam: uptr_t(wordWrap ? SC_WRAP_WORD : SC_WRAP_NONE), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETMARGINWIDTHN, wParam: 1, lParam: sptr_t(showLineNumbers ? 40 : 0))
        _ = ScintillaView.directCall(editor, message: SCI_SETVIEWWS, wParam: uptr_t(showWhitespace ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETVIEWEOL, wParam: uptr_t(showEOL ? 1 : 0), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETINDENTATIONGUIDES, wParam: uptr_t(showIndentGuides ? SC_IV_LOOKBOTH : SC_IV_NONE), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETEDGEMODE, wParam: uptr_t(showEdge ? EDGE_LINE : EDGE_NONE), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETEDGECOLUMN, wParam: uptr_t(edgeColumn), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETMARGINWIDTHN, wParam: uptr_t(MARGIN_FOLD), lParam: sptr_t(showFoldMargin ? 14 : 0))
        _ = ScintillaView.directCall(editor, message: SCI_SETMARGINWIDTHN, wParam: uptr_t(MARGIN_CHANGE_HISTORY), lParam: sptr_t(showChangeHistory ? 4 : 0))
        _ = ScintillaView.directCall(editor, message: SCI_SETZOOM, wParam: uptr_t(bitPattern: zoom), lParam: 0)
        DocumentMapView.applyMargin(to: editor, visible: showDocumentMap)
    }

    /// Aplica fuente primero, luego el resto — ver nota en applyFont().
    func apply(to editor: ScintillaView) {
        applyFont(to: editor)
        applyEditingOptions(to: editor)
    }
}
