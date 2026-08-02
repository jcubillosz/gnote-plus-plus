import Foundation
import SwiftUI

/// Selección de tema del editor. Sigue automáticamente el modo claro/oscuro del sistema
/// (sin selector manual en esta fase, confirmado con el usuario).
enum EditorTheme {
    case light
    case dark

    private var bundledResourceName: String {
        switch self {
        case .light: return "stylers.model"
        case .dark: return "DarkModeDefault"
        }
    }

    var xmlPath: String {
        Bundle.module.url(forResource: bundledResourceName, withExtension: "xml")!.path
    }

    private var overlayResourceName: String {
        switch self {
        case .light: return "stylers.mac-extra.light"
        case .dark: return "stylers.mac-extra.dark"
        }
    }

    /// Estilos propios del port para lenguajes que el tema de Notepad++ no define.
    /// Se consulta después de `xmlPath`, en cascada.
    var overlayXmlPath: String {
        Bundle.module.url(forResource: overlayResourceName, withExtension: "xml")!.path
    }
}

func editorTheme(for colorScheme: ColorScheme) -> EditorTheme {
    colorScheme == .dark ? .dark : .light
}
