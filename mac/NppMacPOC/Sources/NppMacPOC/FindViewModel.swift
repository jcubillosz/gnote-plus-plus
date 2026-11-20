import Foundation

/// Estado publicado para la barra flotente de Find/Replace. FindEngine.swift lee y escribe
/// estos valores; FindBarView los refleja en la UI. Mismo patrón que StatusBarViewModel.
final class FindViewModel: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var showReplace: Bool = false
    @Published var findText: String = "" {
        didSet { if findText != oldValue { statusMessage = nil } }
    }
    @Published var replaceText: String = ""
    @Published var useRegex: Bool = false
    @Published var matchCase: Bool = false
    @Published var wholeWord: Bool = false
    @Published var inSelection: Bool = false
    @Published var matchCount: Int = 0
    @Published var currentMatchIndex: Int = 0
    /// "Marcar todo" también pone marcador de línea (margen) a cada coincidencia.
    @Published var markLines: Bool = UserDefaults.standard.object(forKey: "find.markLines") as? Bool ?? true {
        didSet { UserDefaults.standard.set(markLines, forKey: "find.markLines") }
    }
    /// Mensaje que reemplaza al contador n/m (p.ej. "N coincidencias marcadas"); se limpia al cambiar el texto.
    @Published var statusMessage: String?

    /// "Usar en Buscar" del probador de regex: abre la barra con el patrón y regex activa.
    func usePattern(_ pattern: String, caseInsensitive: Bool) {
        useRegex = true
        wholeWord = false
        matchCase = !caseInsensitive
        findText = pattern
        isVisible = true
    }

    func reset() {
        isVisible = false
        showReplace = false
        findText = ""
        replaceText = ""
        matchCount = 0
        currentMatchIndex = 0
        statusMessage = nil
    }
}
