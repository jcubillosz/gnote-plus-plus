import Foundation

/// Estado publicado para la barra flotente de Find/Replace. FindEngine.swift lee y escribe
/// estos valores; FindBarView los refleja en la UI. Mismo patrón que StatusBarViewModel.
final class FindViewModel: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var showReplace: Bool = false
    @Published var findText: String = ""
    @Published var replaceText: String = ""
    @Published var useRegex: Bool = false
    @Published var matchCase: Bool = false
    @Published var wholeWord: Bool = false
    @Published var matchCount: Int = 0
    @Published var currentMatchIndex: Int = 0

    func reset() {
        isVisible = false
        showReplace = false
        findText = ""
        replaceText = ""
        matchCount = 0
        currentMatchIndex = 0
    }
}
