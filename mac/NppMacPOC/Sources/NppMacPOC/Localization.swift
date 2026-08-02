import Foundation

/// Traduce una clave de `Localizable.strings`.
///
/// Existe por dos razones y las dos son trampas de SwiftPM:
///
/// 1. `Text("…")` de SwiftUI resuelve su `LocalizedStringKey` contra
///    `Bundle.main`, pero en un paquete SwiftPM los `.strings` viven en el
///    bundle de recursos del módulo. Sin pasar `bundle:` explícito, cada string
///    se mostraría con su clave cruda.
/// 2. La app mezcla SwiftUI y AppKit: los `NSAlert` necesitan `String`, no
///    `LocalizedStringKey`. Una sola función sirve a los dos mundos.
///
/// El idioma sale del sistema; `es` es el default cuando no hay traducción.
///
/// Convención: la clave es el texto en español. Si falta una traducción, se
/// muestra el español en vez de un identificador incomprensible.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
