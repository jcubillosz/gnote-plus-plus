import SwiftUI
import AppKit

struct PreferencesView: View {
    @ObservedObject var preferences: EditorPreferences
    let tabs: TabsViewModel
    @State private var showAllFonts = false

    // Recorrer las ~300 familias del sistema y filtrar por trait monospace es lento;
    // se calcula una sola vez, no en cada redibujo de la vista.
    private static let monospaceFontFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { family in
            guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) else { return false }
            return font.isFixedPitch
        }
        .sorted()

    private var fontFamilies: [String] {
        if showAllFonts {
            return NSFontManager.shared.availableFontFamilies.sorted()
        }
        var families = Self.monospaceFontFamilies
        // Si la fuente guardada no es monoespaciada, insertarla igual: si no, el Picker
        // quedaría en un tag sin fila y se mostraría vacío.
        if !families.contains(preferences.fontName) {
            families.append(preferences.fontName)
            families.sort()
        }
        return families
    }

    var body: some View {
        Form {
            Section(L("Fuente")) {
                Picker(L("Familia"), selection: Binding(
                    get: { preferences.fontName },
                    set: { preferences.fontName = $0; tabs.reapplyPreferencesAndTheme() }
                )) {
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).font(.custom(family, size: 13)).tag(family)
                    }
                }
                Toggle(L("Mostrar todas las fuentes"), isOn: $showAllFonts)
                Stepper(value: Binding(
                    get: { preferences.fontSize },
                    set: { preferences.fontSize = $0; tabs.reapplyPreferencesAndTheme() }
                ), in: 8...36) {
                    Text(L("Tamaño: \(Int(preferences.fontSize))"))
                }
            }
            Section(L("Indentación")) {
                Toggle(L("Usar tabs (en vez de espacios)"), isOn: Binding(
                    get: { preferences.useTabs },
                    set: { preferences.useTabs = $0; preferences.applyEditingOptions(to: tabs.editor) }
                ))
                Stepper(value: Binding(
                    get: { preferences.tabWidth },
                    set: { preferences.tabWidth = $0; preferences.applyEditingOptions(to: tabs.editor) }
                ), in: 1...8) {
                    Text(L("Ancho de tab: \(preferences.tabWidth)"))
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
