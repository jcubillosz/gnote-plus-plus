import Foundation
import Scintilla

/// Autocompletado por palabras del documento + keywords del lenguaje (Notepad++:
/// AutoCompletion.cpp, modo "función y palabra"). Se dispara desde SCN_CHARADDED.
enum AutoComplete {
    private static let minimumPrefix = 3
    private static let maxCandidates = 200

    /// Lenguajes de prosa donde la lista molesta más de lo que ayuda (decisión del usuario:
    /// solo en código).
    static func isEnabled(for profile: LanguageProfile) -> Bool {
        profile.lexerName != "null" && profile.lexerName != "markdown"
    }

    static func configure(_ editor: ScintillaView) {
        _ = ScintillaView.directCall(editor, message: SCI_AUTOCSETIGNORECASE, wParam: 1, lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_AUTOCSETORDER, wParam: uptr_t(SC_ORDER_PERFORMSORT), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_AUTOCSETMAXHEIGHT, wParam: 8, lParam: 0)
    }

    static func charAdded(_ character: Int, editor: ScintillaView, document: Document) {
        guard let scalar = UnicodeScalar(UInt32(truncatingIfNeeded: character)),
              CharacterSet.alphanumerics.contains(scalar) || scalar == "_" else { return }
        // Con varias selecciones la lista solo completaría la principal.
        guard ScintillaView.directCall(editor, message: SCI_GETSELECTIONS, wParam: 0, lParam: 0) == 1 else { return }

        let caret = Int(ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0))
        let wordStart = Int(ScintillaView.directCall(editor, message: SCI_WORDSTARTPOSITION, wParam: uptr_t(caret), lParam: 1))
        guard caret - wordStart >= minimumPrefix,
              let prefix = SpellChecker.targetText(editor: editor, start: wordStart, end: caret) else { return }

        let candidates = collectCandidates(editor: editor, document: document, prefix: prefix)
        guard !candidates.isEmpty else {
            _ = ScintillaView.directCall(editor, message: SCI_AUTOCCANCEL, wParam: 0, lParam: 0)
            return
        }
        let list = candidates.joined(separator: " ")
        list.withCString { cstr in
            _ = ScintillaView.directCall(
                editor, message: SCI_AUTOCSHOW,
                wParam: uptr_t(caret - wordStart),
                lParam: sptr_t(bitPattern: UInt(bitPattern: cstr))
            )
        }
    }

    /// Palabras de 4+ caracteres del rango visible ±500 líneas (no del documento entero: esto
    /// corre en cada tecla) más las keywords del perfil, filtradas por prefijo sin distinguir
    /// mayúsculas y sin el propio prefijo.
    private static func collectCandidates(editor: ScintillaView, document: Document, prefix: String) -> [String] {
        let lineCount = Int(ScintillaView.directCall(editor, message: SCI_GETLINECOUNT, wParam: 0, lParam: 0))
        let firstVisible = firstVisibleDocumentLine(editor)
        let startLine = max(0, firstVisible - 500)
        let endLine = min(lineCount, firstVisible + 600)
        let start = Int(ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(startLine), lParam: 0))
        let end = endLine >= lineCount
            ? Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
            : Int(ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(endLine), lParam: 0))

        let lowerPrefix = prefix.lowercased()
        var words = Set<String>()
        func consider(_ word: Substring) {
            guard word.count > prefix.count, word.lowercased().hasPrefix(lowerPrefix) else { return }
            words.insert(String(word))
        }

        if let text = SpellChecker.targetText(editor: editor, start: start, end: end) {
            var scanned = 0
            for word in text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }) where word.count >= 4 {
                consider(word)
                scanned += 1
                if scanned >= 20_000 { break }
            }
        }
        for keywords in document.languageProfile.keywords.values {
            for keyword in keywords.split(separator: " ") { consider(keyword) }
        }
        return Array(words.sorted { $0.lowercased() < $1.lowercased() }.prefix(maxCandidates))
    }
}
