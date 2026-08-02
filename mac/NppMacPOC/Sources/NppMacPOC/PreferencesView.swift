import SwiftUI
import AppKit

struct PreferencesView: View {
    @ObservedObject var preferences: EditorPreferences
    let tabs: TabsViewModel

    private var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    var body: some View {
        Form {
            Section(L("Fuente")) {
                Picker(L("Familia"), selection: Binding(
                    get: { preferences.fontName },
                    set: { preferences.fontName = $0; tabs.reapplyPreferencesAndTheme() }
                )) {
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
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
