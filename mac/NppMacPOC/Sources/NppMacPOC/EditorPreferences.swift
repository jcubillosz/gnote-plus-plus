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

    func applyEditingOptions(to editor: ScintillaView) {
        _ = ScintillaView.directCall(editor, message: SCI_SETUSETABS, wParam: uptr_t(useTabs ? 1 : 0), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETTABWIDTH, wParam: uptr_t(tabWidth), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETWRAPMODE, wParam: uptr_t(wordWrap ? SC_WRAP_WORD : SC_WRAP_NONE), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETMARGINWIDTHN, wParam: 1, lParam: sptr_t(showLineNumbers ? 40 : 0))
        _ = ScintillaView.directCall(editor, message: SCI_SETVIEWWS, wParam: uptr_t(showWhitespace ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE), lParam: 0)
    }

    /// Aplica fuente primero, luego el resto — ver nota en applyFont().
    func apply(to editor: ScintillaView) {
        applyFont(to: editor)
        applyEditingOptions(to: editor)
    }
}
