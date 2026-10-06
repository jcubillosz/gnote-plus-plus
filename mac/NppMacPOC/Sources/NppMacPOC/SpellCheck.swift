import AppKit
import Foundation
import NaturalLanguage
import Scintilla

/// Estado publicado del corrector ortográfico (Task 10). Mismo patrón que FindViewModel:
/// ObservableObject anidado en TabsViewModel, observado directo (@ObservedObject) por
/// cualquier vista/menú que dependa de él, porque no reenvía objectWillChange al padre.
final class SpellCheckViewModel: ObservableObject {
    private enum DefaultsKey {
        static let enabled = "spellCheck.enabled"
        static let language = "spellCheck.language"
    }

    @Published var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            UserDefaults.standard.set(enabled, forKey: DefaultsKey.enabled)
        }
    }
    /// "es", "en" o "auto". Con "auto" se detecta el idioma dominante de cada documento
    /// (SpellChecker.resolvedLanguage) y se revisa con ese idioma fijo.
    @Published var language: String {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language, forKey: DefaultsKey.language)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        self.enabled = defaults.object(forKey: DefaultsKey.enabled) as? Bool ?? false
        self.language = defaults.string(forKey: DefaultsKey.language) ?? "auto"
    }
}

/// Motor de revisión ortográfica: recorre un rango visible del documento activo con
/// NSSpellChecker y pinta INDICATOR_SPELL (squiggle rojo) sobre cada palabra mal escrita,
/// filtrando por estilo del lexer para no revisar código/URLs.
enum SpellChecker {
    /// Limpia el indicador en todo el documento (usado al desactivar el corrector o al
    /// cambiar de pestaña/documento antes de revisar el nuevo).
    static func clearAll(editor: ScintillaView) {
        let length = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
        guard length > 0 else { return }
        _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_SPELL), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_INDICATORCLEARRANGE, wParam: 0, lParam: sptr_t(length))
    }

    /// Revisa el rango visible del editor (más ~50 líneas de margen arriba/abajo) contra
    /// NSSpellChecker y actualiza INDICATOR_SPELL. No revisa el documento entero de una:
    /// NSSpellChecker es lento sobre archivos grandes y esto se dispara en cada scroll/tecla
    /// (con debounce en ContentView), así que limitar el rango es lo que lo hace viable.
    static func check(editor: ScintillaView, document: Document, spellCheck: SpellCheckViewModel) {
        guard spellCheck.enabled else { return }

        let totalLength = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
        guard totalLength > 0 else { return }

        let lineCount = Int(ScintillaView.directCall(editor, message: SCI_GETLINECOUNT, wParam: 0, lParam: 0))
        let firstVisibleLine = firstVisibleDocumentLine(editor)
        let linesOnScreen = Int(ScintillaView.directCall(editor, message: SCI_LINESONSCREEN, wParam: 0, lParam: 0))
        let margin = 50
        let startLine = max(0, firstVisibleLine - margin)
        let endLineExclusive = min(lineCount, firstVisibleLine + linesOnScreen + margin + 1)

        let rangeStart = Int(ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(startLine), lParam: 0))
        let rangeEnd = endLineExclusive >= lineCount
            ? totalLength
            : Int(ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(endLineExclusive), lParam: 0))

        guard rangeStart >= 0, rangeEnd >= rangeStart else { return }

        // Limpiar solo el rango que se va a revisar de nuevo, no el documento entero: fuera
        // de este rango puede haber squiggles de una revisión anterior (scroll previo) que
        // siguen siendo válidos y no hace falta recalcular.
        _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_SPELL), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_INDICATORCLEARRANGE, wParam: uptr_t(rangeStart), lParam: sptr_t(rangeEnd - rangeStart))
        guard rangeEnd > rangeStart else { return }

        guard let rangeText = targetText(editor: editor, start: rangeStart, end: rangeEnd), !rangeText.isEmpty else { return }

        // Scintilla lexea perezoso (solo lo visible): sin esto, las líneas de margen fuera de
        // pantalla —o todo el documento recién abierto— tienen estilo 0 y shouldCheckStyle
        // decide mal (comentarios de código sin revisar, bloques de código Markdown revisados).
        _ = ScintillaView.directCall(editor, message: SCI_COLOURISE, wParam: uptr_t(rangeStart), lParam: sptr_t(rangeEnd))

        let checker = NSSpellChecker.shared
        checker.automaticallyIdentifiesLanguages = false
        let language = resolvedLanguage(editor: editor, document: document, spellCheck: spellCheck)

        let nsText = rangeText as NSString
        let profile = document.languageProfile
        var searchStart = 0
        let totalUTF16Length = nsText.length

        // Tope defensivo: si NSSpellChecker no avanzara searchStart por algún motivo, esto
        // evita un bucle infinito en vez de colgar la app.
        var iterations = 0
        let maxIterations = totalUTF16Length + 1

        while searchStart < totalUTF16Length, iterations < maxIterations {
            iterations += 1
            var wordCount = 0
            let misspelled = checker.checkSpelling(
                of: rangeText,
                startingAt: searchStart,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: document.spellDocumentTag,
                wordCount: &wordCount
            )
            guard misspelled.location != NSNotFound, misspelled.length > 0 else { break }

            if let byteRange = utf8ByteRange(of: misspelled, in: nsText) {
                let wordStart = rangeStart + byteRange.location
                let wordEnd = wordStart + byteRange.length
                let styleAtStart = Int(ScintillaView.directCall(editor, message: SCI_GETSTYLEAT, wParam: uptr_t(wordStart), lParam: 0))
                if shouldCheckStyle(styleAtStart, lexerName: profile.lexerName) {
                    _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_SPELL), lParam: 0)
                    _ = ScintillaView.directCall(editor, message: SCI_INDICATORFILLRANGE, wParam: uptr_t(wordStart), lParam: sptr_t(wordEnd - wordStart))
                }
            }

            searchStart = misspelled.location + misspelled.length
        }
    }

    /// Idioma con el que se revisa `document`. En modo "auto" NO se deja que NSSpellChecker
    /// adivine en cada pasada (automaticallyIdentifiesLanguages): adivinaba sobre cada
    /// fragmento revisado y la misma palabra quedaba marcada o no según el rango visible.
    /// Se detecta una vez el idioma dominante del documento (es/en) y se cachea; solo se
    /// re-detecta si el largo cambió más de un 20%.
    static func resolvedLanguage(editor: ScintillaView, document: Document, spellCheck: SpellCheckViewModel) -> String {
        guard spellCheck.language == "auto" else { return spellCheck.language }
        let length = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
        if let cached = document.detectedSpellLanguage,
           abs(length - document.detectedSpellLanguageLength) * 5 <= max(document.detectedSpellLanguageLength, 1) {
            return cached
        }
        let sample = targetText(editor: editor, start: 0, end: min(length, 20_000)) ?? ""
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.spanish, .english]
        recognizer.processString(sample)
        let detected: String
        switch recognizer.dominantLanguage {
        case .spanish?: detected = "es"
        case .english?: detected = "en"
        default: detected = fallbackLanguage
        }
        // Con muy poco texto la detección no es confiable: no se cachea, se reintenta
        // en la próxima revisión cuando haya más.
        if sample.count >= 40 {
            document.detectedSpellLanguage = detected
            document.detectedSpellLanguageLength = length
        }
        return detected
    }

    /// Idioma preferido del sistema si es es/en; si no, español.
    private static var fallbackLanguage: String {
        let preferred = Locale.preferredLanguages.first?.prefix(2) ?? "es"
        return preferred == "en" ? "en" : "es"
    }

    /// Lee el texto entre `start` y `end` (posiciones en bytes UTF-8 de Scintilla) usando
    /// SCI_SETTARGETSTART/END + SCI_GETTARGETTEXT — mismo patrón de "pedir el largo primero,
    /// después llenar el buffer" que currentText()/selectionSerialized() en ScintillaMessages.swift.
    /// Se prefiere sobre SCI_GETTEXTRANGE porque ese mensaje requiere construir el struct C
    /// Sci_TextRange, que no está expuesto a Swift sin interop adicional.
    static func targetText(editor: ScintillaView, start: Int, end: Int) -> String? {
        _ = ScintillaView.directCall(editor, message: SCI_SETTARGETSTART, wParam: uptr_t(start), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETTARGETEND, wParam: uptr_t(end), lParam: 0)
        let length = Int(ScintillaView.directCall(editor, message: SCI_GETTARGETTEXT, wParam: 0, lParam: 0))
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length + 1)
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = ScintillaView.directCall(editor, message: SCI_GETTARGETTEXT, wParam: 0, lParam: sptr_t(bitPattern: UInt(bitPattern: base)))
        }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }

    /// Convierte un NSRange en unidades UTF-16 (el que devuelve NSSpellChecker, medido sobre
    /// `nsText`) a un offset/largo en BYTES UTF-8, que es lo que esperan
    /// SCI_INDICATORFILLRANGE/SCI_GETSTYLEAT. Un acento o emoji ocupa distinto número de
    /// unidades en UTF-16 que en UTF-8, así que no se puede usar el NSRange tal cual.
    private static func utf8ByteRange(of nsRange: NSRange, in nsText: NSString) -> (location: Int, length: Int)? {
        let text = nsText as String
        guard let swiftRange = Range(nsRange, in: text) else { return nil }
        // String.Index es común a todas las vistas (utf8/utf16/Character) desde Swift 4:
        // no hace falta samePosition(in:) para reindexar sobre utf8.
        let prefixByteCount = text.utf8.distance(from: text.utf8.startIndex, to: swiftRange.lowerBound)
        let wordByteCount = text.utf8.distance(from: swiftRange.lowerBound, to: swiftRange.upperBound)
        return (prefixByteCount, wordByteCount)
    }

    /// ¿Se revisa una palabra que empieza en este estilo, para este lexer? Ver task-10-brief.md
    /// punto 5 e IDs confirmados contra lexilla/include/SciLexer.h.
    private static func shouldCheckStyle(_ style: Int, lexerName: String) -> Bool {
        switch lexerName {
        case "null":
            // Texto plano (o lenguaje sin perfil propio): se revisa todo.
            return true
        case "markdown":
            // Se excluyen bloques/spans de código y URLs de enlaces; el resto de Markdown
            // (texto, encabezados, énfasis, listas, citas) sí se revisa.
            return !markdownExcludedStyles.contains(style)
        case "cpp":
            // Cubre cpp, java, javascript, typescript, objc, cs, go, swift, actionscript —
            // todos mapean a este lexer real vía lexerNameOverrides en Language.swift.
            return cppCommentStringStyles.contains(style)
        case "python":
            return pythonCommentStringStyles.contains(style)
        case "bash":
            return bashCommentStringStyles.contains(style)
        case "hypertext", "xml":
            // "xml" comparte lexer/estilos SCE_H_* con "hypertext" (LexHTML.cxx implementa
            // ambos, ver lmHTML/lmXML en lexilla/lexers/LexHTML.cxx). "hypertext" además cubre
            // el JS/PHP embebido (SCE_HJ_*/SCE_HJA_*/SCE_HPHP_*).
            return hypertextCommentStringStyles.contains(style)
        default:
            // Cualquier otro lexer no está en el alcance de esta task (brief: "en otros
            // lexers no se revisa").
            return false
        }
    }

    // SCE_MARKDOWN_CODE=19, SCE_MARKDOWN_CODE2=20 (código en línea, dos variantes de
    // delimitador), SCE_MARKDOWN_CODEBK=21 (bloque ```), SCE_MARKDOWN_LINK=18 (URL de enlace).
    private static let markdownExcludedStyles: Set<Int> = [18, 19, 20, 21]

    // SCE_C_COMMENT=1, SCE_C_COMMENTLINE=2, SCE_C_COMMENTDOC=3, SCE_C_STRING=6,
    // SCE_C_CHARACTER=7, SCE_C_COMMENTLINEDOC=15, SCE_C_COMMENTDOCKEYWORD=17,
    // SCE_C_COMMENTDOCKEYWORDERROR=18, SCE_C_STRINGRAW=20, SCE_C_TRIPLEVERBATIM=21,
    // SCE_C_HASHQUOTEDSTRING=22.
    private static let cppCommentStringStyles: Set<Int> = [1, 2, 3, 6, 7, 15, 17, 18, 20, 21, 22]

    // SCE_P_COMMENTLINE=1, SCE_P_STRING=3, SCE_P_CHARACTER=4, SCE_P_TRIPLE=6,
    // SCE_P_TRIPLEDOUBLE=7, SCE_P_COMMENTBLOCK=12, SCE_P_FSTRING=16.
    private static let pythonCommentStringStyles: Set<Int> = [1, 3, 4, 6, 7, 12, 16]

    // SCE_SH_COMMENTLINE=2, SCE_SH_STRING=5, SCE_SH_CHARACTER=6.
    private static let bashCommentStringStyles: Set<Int> = [2, 5, 6]

    // HTML: SCE_H_DOUBLESTRING=6, SCE_H_SINGLESTRING=7, SCE_H_COMMENT=9,
    // SCE_H_XCCOMMENT=20 (comentario estilo XML <?...?>). JS embebido (SCE_HJ_*):
    // COMMENT=42, COMMENTLINE=43, COMMENTDOC=44, DOUBLESTRING=48, SINGLESTRING=49.
    // JS embebido en ASP (SCE_HJA_*, mismo layout +15): COMMENT=57, COMMENTLINE=58,
    // COMMENTDOC=59, DOUBLESTRING=63, SINGLESTRING=64. PHP (SCE_HPHP_*):
    // HSTRING=119, SIMPLESTRING=120, COMMENT=124, COMMENTLINE=125.
    private static let hypertextCommentStringStyles: Set<Int> = [
        6, 7, 9, 20,
        42, 43, 44, 48, 49,
        57, 58, 59, 63, 64,
        119, 120, 124, 125,
    ]
}

/// Menú contextual del corrector ortográfico (Task 11): sugerencias, aprender/ignorar y los
/// ítems estándar de edición, sobre la palabra bajo el clic derecho.
///
/// Lo invoca ContextMenuScintillaView.menu(for:) (ScintillaEditorView.swift) solo cuando el
/// clic cae sobre INDICATOR_SPELL; en cualquier otro punto Scintilla muestra su menú nativo.
enum SpellCheckContextMenu {
    /// Construye el menú para la palabra marcada en [wordStart, wordEnd) (posiciones de
    /// Scintilla, bytes UTF-8). Si por algún motivo no se puede leer la palabra, degrada al
    /// menú estándar de edición (nunca deja el clic derecho sin menú).
    static func build(
        editor: ScintillaView,
        document: Document,
        spellCheck: SpellCheckViewModel,
        wordStart: Int,
        wordEnd: Int,
        onAction: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        // Boxes con acción: se cuelgan de representedObject (que NSMenuItem retiene) para
        // sobrevivir el tracking modal del menú — item.target no retiene fuerte.
        if let word = SpellChecker.targetText(editor: editor, start: wordStart, end: wordEnd), !word.isEmpty {
            let checker = NSSpellChecker.shared
            if !document.isLocked {
                let language = SpellChecker.resolvedLanguage(editor: editor, document: document, spellCheck: spellCheck)
                let guesses = checker.guesses(
                    forWordRange: NSRange(location: 0, length: (word as NSString).length),
                    in: word,
                    language: language,
                    inSpellDocumentWithTag: document.spellDocumentTag
                ) ?? []

                if guesses.isEmpty {
                    let none = NSMenuItem(title: L("Sin sugerencias"), action: nil, keyEquivalent: "")
                    none.isEnabled = false
                    menu.addItem(none)
                } else {
                    for suggestion in guesses.prefix(6) {
                        addAction(suggestion, to: menu) {
                            replaceWord(editor: editor, start: wordStart, end: wordEnd, with: suggestion)
                            onAction()
                        }
                    }
                }
                menu.addItem(.separator())
            }

            addAction(L("Agregar al diccionario"), to: menu) {
                checker.learnWord(word)
                onAction()
            }
            addAction(L("Ignorar"), to: menu) {
                checker.ignoreWord(word, inSpellDocumentWithTag: document.spellDocumentTag)
                onAction()
            }
            menu.addItem(.separator())
        }

        appendStandardEditItems(to: menu, target: editor.content())
        return menu
    }

    /// Reemplaza [start, end) por `replacement` vía SETTARGETSTART/END + REPLACETARGET, mismo
    /// patrón que targetText/loadText (largo explícito + puntero C, sin depender de strlen).
    private static func replaceWord(editor: ScintillaView, start: Int, end: Int, with replacement: String) {
        _ = ScintillaView.directCall(editor, message: SCI_SETTARGETSTART, wParam: uptr_t(start), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETTARGETEND, wParam: uptr_t(end), lParam: 0)
        replacement.withCString { cstr in
            _ = ScintillaView.directCall(
                editor, message: SCI_REPLACETARGET,
                wParam: uptr_t(replacement.utf8.count),
                lParam: sptr_t(bitPattern: UInt(bitPattern: cstr))
            )
        }
        // El clic derecho seleccionó la palabra; tras reemplazar, caret al final (como NSTextView).
        let newEnd = start + replacement.utf8.count
        _ = ScintillaView.directCall(editor, message: SCI_SETSEL, wParam: uptr_t(newEnd), lParam: sptr_t(newEnd))
    }

    /// Cortar/Copiar/Pegar dirigidos explícitamente al SCIContentView (que implementa
    /// cut:/copy:/paste: y su validación). Con target nil dependían del first responder de la
    /// ventana, que no siempre es el editor al abrir el menú, y quedaban deshabilitados.
    private static func appendStandardEditItems(to menu: NSMenu, target: NSView?) {
        for (title, action) in [(L("Cortar"), #selector(NSText.cut(_:))),
                                (L("Copiar"), #selector(NSText.copy(_:))),
                                (L("Pegar"), #selector(NSText.paste(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = target
        }
    }

    private static func addAction(_ title: String, to menu: NSMenu, _ action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(ActionBox.run(_:)), keyEquivalent: "")
        let box = ActionBox(action: action)
        item.representedObject = box
        item.target = box
        menu.addItem(item)
    }

    /// NSMenuItem necesita un target/selector @objc reales; esta caja adapta un closure.
    private final class ActionBox: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func run(_ sender: Any?) { action() }
    }
}
