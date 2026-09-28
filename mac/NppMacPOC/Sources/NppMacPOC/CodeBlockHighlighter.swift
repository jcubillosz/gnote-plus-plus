import AppKit
import Foundation
import Scintilla

/// Tamaño máximo (en bytes UTF-8) de un bloque de código a colorear. Colorear corre en
/// el main thread y recorre el texto carácter por carácter con SCI_GETSTYLEAT: un
/// bloque gigante congelaría la preview en cada tecla (debounce de 300ms).
private let codeBlockHighlightByteLimit = 200 * 1024

// Solo los alias cuyo destino existe en langs.model.xml / langs.mac-extra.xml. Lo que
// no está acá cae a languageProfile(forExtension:) con el tag tal cual.
private let codeLanguageAliases: [String: String] = [
    "js": "javascript", "jsx": "javascript",
    "ts": "typescript", "tsx": "typescript",
    "py": "python", "rb": "ruby",
    "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash",
    "c++": "cpp", "cxx": "cpp", "hpp": "cpp",
    "h": "c",
    "cs": "cs", "csharp": "cs",
    "yml": "yaml", "md": "markdown",
    "objective-c": "objc", "objc": "objc",
    "rs": "rust",
    "ps1": "powershell", "powershell": "powershell",
    "html": "html", "xhtml": "html",
    "jsonc": "json", "golang": "go",
]

/// Perfil de lenguaje para el tag de un bloque ```tag, o nil si no se reconoce (o si
/// resuelve a texto plano, que no tiene nada que colorear).
func codeLanguageProfile(for tag: String, theme: EditorTheme) -> LanguageProfile? {
    let lower = tag.lowercased()
    let name = codeLanguageAliases[lower] ?? lower
    // Un nombre inexistente no falla: devuelve un perfil sin estilos. Por eso el criterio
    // de "resuelto" es tener estilos, no el lexerName.
    let byName = languageProfile(byLanguageName: name, theme: theme)
    if !byName.styles.isEmpty { return byName }
    let byExt = languageProfile(forExtension: lower, theme: theme)
    return byExt.styles.isEmpty ? nil : byExt
}

/// ScintillaView oculto, sin ventana, usado solo para lexear bloques de código. Lexilla
/// colorea sobre el Document de Scintilla; SCI_COLOURISE no necesita pintar, así que no
/// hace falta que la vista esté en pantalla.
@MainActor
private let hiddenHighlighterView: ScintillaView = {
    let view = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    // Sin undo: cada refresh (cada 300ms al tipear) recarga todos los bloques con
    // CLEARALL+APPENDTEXT, y con undo activo ese historial crecería sin límite.
    _ = ScintillaView.directCall(view, message: SCI_SETUNDOCOLLECTION, wParam: 0, lParam: 0)
    return view
}()

/// HTML con spans coloreados para `code` (texto plano, ya desescapado), o nil si no se
/// puede colorear.
@MainActor
private func highlightedCodeHTML(_ code: String, profile: LanguageProfile, theme: EditorTheme) -> String? {
    let view = hiddenHighlighterView
    // Igual que reapplyPreferencesAndTheme: STYLE_DEFAULT antes de STYLECLEARALL.
    if let defaultStyle = globalStyle(name: "Default Style", theme: theme) {
        setStyle(view, STYLE_DEFAULT, fore: defaultStyle.fore, back: defaultStyle.back)
    }
    applyLanguage(view, profile: profile)
    loadText(view, code)
    // Sin fondos por run: el fondo del bloque lo pone el CSS (--md-code-bg); los fondos
    // del tema del editor (ej. #1e1e1e en oscuro) dejarían parches sobre él.
    let styles = profile.styles.mapValues { StyleSpec(fore: $0.fore, back: nil, fontStyle: $0.fontStyle) }
    return styledHTMLBody(editor: view, text: code, styles: styles)
}

private func unescapeHTMLText(_ text: String) -> String {
    // &amp; al final: si fuera primero, "&amp;lt;" terminaría como "<".
    text.replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
}

private let fencedCodeRegex = try! NSRegularExpression(
    pattern: #"<pre([^>]*)><code class="language-([^"]+)">(.*?)</code></pre>"#,
    options: [.dotMatchesLineSeparators]
)

/// Envuelve cada bloque con lenguaje en un contenedor con cabecera (nombre del lenguaje)
/// y colorea su contenido si el lenguaje se reconoce. Los bloques sin lenguaje quedan
/// intactos. Los atributos del <pre> (data-sourcepos del salto a la fuente) se conservan.
@MainActor
func decorateFencedCodeBlocks(_ html: String, theme: EditorTheme) -> String {
    let ns = html as NSString
    let matches = fencedCodeRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return html }

    var out = ""
    out.reserveCapacity(html.utf8.count + matches.count * 128)
    var cursor = 0
    for match in matches {
        out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        let preAttrs = ns.substring(with: match.range(at: 1))
        let tagEscaped = ns.substring(with: match.range(at: 2))
        let bodyEscaped = ns.substring(with: match.range(at: 3))

        let tag = unescapeHTMLText(tagEscaped)
        var body = bodyEscaped
        if let profile = codeLanguageProfile(for: tag, theme: theme) {
            let code = unescapeHTMLText(bodyEscaped)
            if code.utf8.count <= codeBlockHighlightByteLimit,
               let colored = highlightedCodeHTML(code, profile: profile, theme: theme) {
                body = colored
            }
        }
        out += "<div class=\"code-block\"><div class=\"code-lang\">\(escapeHTMLText(tag))</div>"
        out += "<pre\(preAttrs)><code class=\"language-\(tagEscaped)\">\(body)</code></pre></div>"
        cursor = match.range.location + match.range.length
    }
    out += ns.substring(from: cursor)
    return out
}
