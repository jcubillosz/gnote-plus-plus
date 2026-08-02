import Foundation
import Scintilla
import LexillaShim
import NppDataShim

// Mapa de excepciones: nombre de "Language" en PowerEditor/src/langs.model.xml → nombre
// real de lexer registrado en Lexilla (lexilla/lexers/*.cxx). Para la inmensa mayoría de
// lenguajes el nombre coincide 1:1 (python, ruby, css, sql, bash, xml, lua, rust, ada, ...);
// esta tabla cubre solo los casos donde Notepad++ reusa el lexer "cpp"/"hypertext"
// para varias familias de lenguaje C-like o con nombre distinto al de Lexilla.
private let lexerNameOverrides: [String: String] = [
    "java": "cpp", "javascript": "cpp", "typescript": "cpp", "cs": "cpp",
    "objc": "cpp", "actionscript": "cpp", "go": "cpp", "swift": "cpp",
    "php": "hypertext",
    "html": "hypertext",
]

private func lexillaLexerName(forLanguageName langName: String) -> String {
    lexerNameOverrides[langName] ?? langName
}

// stylers.model.xml tiene DOS <LexerType> distintos para JavaScript: "javascript" (variante
// embebida en HTML, estilos SCE_HJ_*) y "javascript.js" (JS standalone con motor cpp, estilos
// SCE_C_*, ver setJsLexer() → getLexerStylerByName(_langNameInfoArray[L_JAVASCRIPT]._langName)
// donde ese campo literalmente vale "javascript.js"). Para .js standalone hay que consultar
// el segundo, no el primero.
private let stylerNameOverrides: [String: String] = [
    "javascript": "javascript.js",
]

private func stylerLookupName(forLanguageName langName: String) -> String {
    stylerNameOverrides[langName] ?? langName
}

// Familia "cpp" (cpp/java/javascript/typescript/objc/cs/go/swift): Notepad++ NO manda los
// índices de SCI_SETKEYWORDS en el mismo orden que LANG_INDEX_* (ver setCppLexer/setJsLexer/
// setTypeScriptLexer en PowerEditor/src/ScintillaComponent/ScintillaEditView.cpp). Remapeo
// confirmado leyendo ese código: instre1→0 (igual), type1→1 (LANG_INDEX_TYPE=2 normalmente),
// type2→2 (doxygen, LANG_INDEX_TYPE2=3 normalmente), instre2→3 (LANG_INDEX_INSTR2=1 normalmente).
private let cppFamilyLanguages: Set<String> = [
    "cpp", "java", "javascript", "typescript", "objc", "cs", "go", "swift", "actionscript",
]
private let cppFamilyIndexRemap: [Int: Int] = [0: 0, 2: 1, 3: 2, 1: 3]

private func remapKeywordIndices(_ keywords: [Int: String], forLanguage langName: String) -> [Int: String] {
    guard cppFamilyLanguages.contains(langName) else { return keywords }
    var remapped: [Int: String] = [:]
    for (langIndex, text) in keywords {
        let sciIndex = cppFamilyIndexRemap[langIndex] ?? langIndex
        remapped[sciIndex] = text
    }
    return remapped
}

struct StyleSpec {
    let fore: sptr_t
    let back: sptr_t?
    /// Máscara FONTSTYLE_* (1=negrita, 2=cursiva, 4=subrayado). `nil` cuando el
    /// atributo falta en el XML: significa "no administrado", no "sin adornos"
    /// (STYLE_NOT_USED en el original, ver Parameters.cpp:5086).
    let fontStyle: Int?
}

struct LanguageProfile {
    let lexerName: String
    // wordListIndex (índice real SCI_SETKEYWORDS, ver LANG_INDEX_* en
    // PowerEditor/src/MISC/Common/NppConstants.h) → texto de keywords.
    let keywords: [Int: String]
    // styleID (SCE_* real del lexer) → color fg/bg/fontStyle.
    let styles: [Int: StyleSpec]
}

private func hexRRGGBBToScintillaBGR(_ hex: String) -> sptr_t? {
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    let r = (value >> 16) & 0xFF
    let g = (value >> 8) & 0xFF
    let b = value & 0xFF
    return sptr_t((b << 16) | (g << 8) | r)
}

private let langsXmlPath: String = Bundle.module.url(forResource: "langs.model", withExtension: "xml")!.path
// Overlay propio: lenguajes que Notepad++ no define (ver langs.mac-extra.xml). Se
// consulta después de langsXmlPath, en cascada — upstream siempre gana si define algo.
private let langsOverlayXmlPath: String = Bundle.module.url(forResource: "langs.mac-extra", withExtension: "xml")!.path

// Perfil "null": tokenizado plano, sin color propio. Usado cuando la extensión no está
// ni en langs.model.xml ni en el overlay, o no hay estilos definidos para ese lenguaje
// en el tema activo.
private let nullProfile = LanguageProfile(lexerName: "null", keywords: [:], styles: [:])

// langs.model.xml guarda ext="" (vacío) para "javascript": Notepad++ trae su extensión
// default ".js" desde otra tabla C++ (_langNameInfoArray en ScintillaEditView.cpp), no de
// este XML. Cubrimos ese caso puntual acá en vez de depender solo del atributo ext.
private let extensionToLangNameOverride: [String: String] = [
    "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
]

// Lenguajes cuyo archivo real Notepad++ lexea con el lexer compuesto "hypertext" (HTML +
// JS embebido + PHP embebido en un solo pase), confirmado leyendo setHTMLLexer/
// setEmbeddedJSLexer/setEmbeddedPhpLexer en ScintillaEditView.cpp.
private let htmlFamilyLangNames: Set<String> = ["html", "php"]

private func parseKeywordFields(_ fields: ArraySlice<String>) -> [Int: String] {
    var keywords: [Int: String] = [:]
    for field in fields {
        guard let colonIndex = field.firstIndex(of: ":") else { continue }
        let idxStr = field[field.startIndex..<colonIndex]
        let text = field[field.index(after: colonIndex)...]
        if let idx = Int(idxStr) {
            keywords[idx] = String(text)
        }
    }
    return keywords
}

// Devuelve (langName, keywords LANG_INDEX-keyed) o nil.
private func rawKeywords(fromXml xmlPath: String, forExtension ext: String) -> (String, [Int: String])? {
    guard let raw = npp_lookup_language(xmlPath, ext) else { return nil }
    defer { npp_free_string(raw) }
    var fields = String(cString: raw).split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
    guard !fields.isEmpty else { return nil }
    let langName = fields.removeFirst()
    return (langName, parseKeywordFields(fields[...]))
}

// Cascada: upstream primero, overlay solo si Notepad++ no define nada para esa extensión.
private func rawKeywords(forExtension ext: String) -> (String, [Int: String])? {
    rawKeywords(fromXml: langsXmlPath, forExtension: ext) ?? rawKeywords(fromXml: langsOverlayXmlPath, forExtension: ext)
}

private func rawKeywords(fromXml xmlPath: String, forLangName langName: String) -> [Int: String] {
    guard let raw = npp_lookup_language_by_name(xmlPath, langName) else { return [:] }
    defer { npp_free_string(raw) }
    var fields = String(cString: raw).split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
    guard !fields.isEmpty else { return [:] }
    fields.removeFirst() // langName, ya lo tenemos
    return parseKeywordFields(fields[...])
}

private func rawKeywords(forLangName langName: String) -> [Int: String] {
    let upstream = rawKeywords(fromXml: langsXmlPath, forLangName: langName)
    if !upstream.isEmpty { return upstream }
    return rawKeywords(fromXml: langsOverlayXmlPath, forLangName: langName)
}

private func parseStyles(_ raw: String) -> [Int: StyleSpec] {
    var styles: [Int: StyleSpec] = [:]
    for entry in raw.split(separator: ";") {
        let parts = entry.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 4, let styleID = Int(parts[0]) else { continue }
        guard let fore = hexRRGGBBToScintillaBGR(String(parts[1])) else { continue }
        let back = hexRRGGBBToScintillaBGR(String(parts[2]))
        // -1 (o no parseable) = STYLE_NOT_USED: atributo ausente en el XML, no administrado.
        let rawFontStyle = Int(parts[3])
        let fontStyle = (rawFontStyle == -1) ? nil : rawFontStyle
        styles[styleID] = StyleSpec(fore: fore, back: back, fontStyle: fontStyle)
    }
    return styles
}

private func rawStyles(fromXml xmlPath: String, forLangName langName: String) -> [Int: StyleSpec] {
    guard let rawStylesStr = npp_lookup_styles(xmlPath, langName) else { return [:] }
    defer { npp_free_string(rawStylesStr) }
    return parseStyles(String(cString: rawStylesStr))
}

// Cascada: upstream primero, overlay del tema activo solo si Notepad++ no define
// estilos para ese lenguaje (caso de markdown, ausente de stylers.model.xml).
private func rawStyles(forLangName langName: String, theme: EditorTheme) -> [Int: StyleSpec] {
    let upstream = rawStyles(fromXml: theme.xmlPath, forLangName: langName)
    if !upstream.isEmpty { return upstream }
    return rawStyles(fromXml: theme.overlayXmlPath, forLangName: langName)
}

/// Busca un color global de tema (ej. "Default Style", "Selected text colour", "Caret colour")
/// en `<GlobalStyles>` del XML de tema activo.
func globalStyle(name: String, theme: EditorTheme) -> StyleSpec? {
    // El overlay define estilos de lenguaje (LexerStyles), no colores globales de la
    // app: no tiene <GlobalStyles>, así que acá no hay cascada, solo theme.xmlPath.
    guard let raw = npp_lookup_global_style(theme.xmlPath, name) else { return nil }
    defer { npp_free_string(raw) }
    let parts = String(cString: raw).split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 2, let fore = hexRRGGBBToScintillaBGR(String(parts[0])) else { return nil }
    let back = hexRRGGBBToScintillaBGR(String(parts[1]))
    // <GlobalStyles> se aplica a widgets de la app (margen, caret, selección), no a
    // estilos de sintaxis: fontStyle queda fuera de alcance acá, siempre nil.
    return StyleSpec(fore: fore, back: back, fontStyle: nil)
}

/// Nombres de todos los `<Language name="...">` de langs.model.xml + el overlay propio,
/// unidos, sin duplicados y ordenados alfabéticamente. Usado para poblar el menú
/// "Language" (forzar lenguaje manualmente).
func availableLanguageNames() -> [String] {
    func names(fromXml xmlPath: String) -> [String] {
        guard let raw = npp_list_language_names(xmlPath) else { return [] }
        defer { npp_free_string(raw) }
        return String(cString: raw).split(separator: ";").map(String.init)
    }
    let combined = Set(names(fromXml: langsXmlPath)).union(names(fromXml: langsOverlayXmlPath))
    return combined.sorted()
}

/// Agrupa los lenguajes reales (sin pseudo-lenguajes internos de Notepad++)
/// en buckets por rango alfabético para el menú "Language", igual que
/// Notepad++ nativo.
func languageMenuGroups() -> [(label: String, names: [String])] {
    let excluded: Set<String> = ["normal", "errorlist", "escseq", "escript", "searchResult"]
    let names = availableLanguageNames().filter { !excluded.contains($0) }

    let buckets: [(label: String, letters: ClosedRange<Character>)] = [
        ("A-C", "A"..."C"),
        ("D-I", "D"..."I"),
        ("J-N", "J"..."N"),
        ("O-P", "O"..."P"),
        ("R-S", "R"..."S"),
        ("T-Z", "T"..."Z"),
    ]

    return buckets.map { bucket in
        let namesInBucket = names.filter { name in
            guard let first = name.uppercased().first else { return false }
            return bucket.letters.contains(first)
        }
        return (label: bucket.label, names: namesInBucket)
    }
}

// Compone el perfil real de Notepad++ para .html/.php: HTML aporta tags (instre1→SCI 0) y
// doctype (instre2→SCI 5), JavaScript embebido aporta su instre1→SCI 1, PHP embebido aporta
// su instre1→SCI 4 (índices confirmados leyendo setHTMLLexer/setEmbeddedJSLexer/
// setEmbeddedPhpLexer). Los estilos de los 3 lenguajes no chocan: usan rangos SCE_H_*/
// SCE_HJ_*/SCE_HPHP_* distintos dentro del mismo lexer "hypertext".
private func htmlFamilyProfile(theme: EditorTheme) -> LanguageProfile {
    let htmlKw = rawKeywords(forLangName: "html")
    let jsKw = rawKeywords(forLangName: "javascript")
    let phpKw = rawKeywords(forLangName: "php")

    var keywords: [Int: String] = [:]
    if let tags = htmlKw[0] { keywords[0] = tags }
    if let doctype = htmlKw[1] { keywords[5] = doctype }
    if let jsInstr = jsKw[0] { keywords[1] = jsInstr }
    if let phpInstr = phpKw[0] { keywords[4] = phpInstr }

    var styles: [Int: StyleSpec] = [:]
    styles.merge(rawStyles(forLangName: "html", theme: theme)) { _, new in new }
    styles.merge(rawStyles(forLangName: "javascript", theme: theme)) { _, new in new }
    styles.merge(rawStyles(forLangName: "php", theme: theme)) { _, new in new }

    return LanguageProfile(lexerName: "hypertext", keywords: keywords, styles: styles)
}

private func profile(forLangName langName: String, keywords: [Int: String], theme: EditorTheme) -> LanguageProfile {
    let remapped = remapKeywordIndices(keywords, forLanguage: langName)
    let lexerName = lexillaLexerName(forLanguageName: langName)
    let styles = rawStyles(forLangName: stylerLookupName(forLanguageName: langName), theme: theme)
    return LanguageProfile(lexerName: lexerName, keywords: remapped, styles: styles)
}

func languageProfile(forExtension ext: String, theme: EditorTheme) -> LanguageProfile {
    let lower = ext.lowercased()

    let langName: String
    var keywords: [Int: String]

    if let overrideLangName = extensionToLangNameOverride[lower] {
        langName = overrideLangName
        keywords = rawKeywords(forLangName: overrideLangName)
    } else if let (name, kw) = rawKeywords(forExtension: lower) {
        langName = name
        keywords = kw
    } else {
        return nullProfile
    }

    if htmlFamilyLangNames.contains(langName) {
        return htmlFamilyProfile(theme: theme)
    }

    return profile(forLangName: langName, keywords: keywords, theme: theme)
}

/// Fuerza un lenguaje por nombre (no por extensión) — usado por el menú "Language" para
/// override manual del usuario, solo para la sesión actual (no persiste).
func languageProfile(byLanguageName langName: String, theme: EditorTheme) -> LanguageProfile {
    if htmlFamilyLangNames.contains(langName) {
        return htmlFamilyProfile(theme: theme)
    }
    return profile(forLangName: langName, keywords: rawKeywords(forLangName: langName), theme: theme)
}

func applyLanguage(_ editor: ScintillaView, profile: LanguageProfile) {
    let lexerPtr = Lexilla_CreateLexer(profile.lexerName)
    _ = ScintillaView.directCall(editor, message: SCI_SETILEXER, wParam: 0, lParam: sptr_t(bitPattern: lexerPtr))

    _ = ScintillaView.directCall(editor, message: SCI_STYLECLEARALL, wParam: 0, lParam: 0)

    for (index, text) in profile.keywords {
        text.withCString { cstr in
            _ = ScintillaView.directCall(editor, message: SCI_SETKEYWORDS, wParam: uptr_t(index), lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
        }
    }

    for (styleID, color) in profile.styles {
        setStyle(editor, styleID, fore: color.fore, back: color.back, fontStyle: color.fontStyle)
    }

    _ = ScintillaView.directCall(editor, message: SCI_COLOURISE, wParam: 0, lParam: -1)
}
