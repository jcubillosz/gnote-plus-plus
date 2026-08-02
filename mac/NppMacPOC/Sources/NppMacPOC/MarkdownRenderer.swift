import Foundation
import CmarkShim

/// Render de Markdown (GitHub Flavored) a HTML, vía cmark-gfm vendorizado.
///
/// Es una función pura y sincrónica a propósito: la vista previa, el export a
/// HTML y el export a PDF comparten exactamente este render, así que no pueden
/// divergir entre sí.

enum MarkdownTheme: String {
    case light
    case dark
}

/// Orígenes permitidos para `img-src` en el CSP. El export usa `file:` (el HTML
/// resultante se abre desde disco); la preview usa su esquema propio, porque las
/// imágenes las sirve el WKURLSchemeHandler y no hay acceso a file: alguno.
enum MarkdownImageSource {
    case file
    case previewScheme

    /// Valor que va en la directiva `img-src` del CSP. El del esquema propio se
    /// deriva de `markdownPreviewScheme` en vez de repetir el literal: antes eran
    /// dos strings que tenían que coincidir, y si se desincronizaban la preview
    /// dejaba de cargar imágenes sin ningún otro síntoma.
    var cspSource: String {
        switch self {
        case .file: return "file:"
        case .previewScheme: return "\(markdownPreviewScheme):"
        }
    }
}

/// Renderiza Markdown al fragmento HTML del `<body>`, sin envoltorio.
func renderMarkdownFragment(_ markdown: String, sourcePositions: Bool = false) -> String {
    let byteCount = markdown.utf8.count
    let rendered: String? = markdown.withCString { cstr in
        guard let html = cmark_shim_render_html(cstr, byteCount, sourcePositions ? 1 : 0) else {
            return nil
        }
        defer { cmark_shim_free(html) }
        return String(cString: html)
    }
    return rendered ?? ""
}

/// Renderiza Markdown a un documento HTML completo y autocontenido: CSS
/// embebido, sin archivos externos ni red. Es lo que carga la vista previa y lo
/// que se escribe en el export.
///
/// - Parameters:
///   - title: va al `<title>`; usar el nombre del archivo.
///   - theme: la preview usa el del sistema; el export fija `.light`, porque un
///     documento que se comparte no debe depender del tema de quien lo abra.
///   - sourcePositions: sólo para mapear preview→editor. El export pasa `false`.
func renderMarkdownDocument(
    _ markdown: String,
    title: String,
    theme: MarkdownTheme,
    sourcePositions: Bool = false,
    imageSource: MarkdownImageSource = .file
) -> String {
    let body = renderMarkdownFragment(markdown, sourcePositions: sourcePositions)

    // `default-src 'none'` corta toda carga remota: sin esto una imagen remota
    // en el Markdown delata al lector (IP, hora de lectura) apenas abre el
    // archivo. Las imágenes quedan restringidas a `imageSource` y data:. Sin
    // script-src habilitado, cualquier <script> que sobreviva al tagfilter no
    // ejecuta.
    let csp = "default-src 'none'; img-src \(imageSource.cspSource) data:; style-src 'unsafe-inline'; "
        + "font-src file: data:; media-src file: data:"

    return """
    <!DOCTYPE html>
    <html lang="es" data-theme="\(theme.rawValue)">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="\(csp)">
    <title>\(escapeHTMLText(title))</title>
    <style>
    \(markdownPreviewCSS)
    </style>
    </head>
    <body>
    \(body)
    </body>
    </html>
    """
}

/// Escapa texto para insertarlo como contenido de un elemento o atributo.
func escapeHTMLText(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for ch in text {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default: out.append(ch)
        }
    }
    return out
}

/// CSS de la preview, leído una sola vez del bundle de recursos.
let markdownPreviewCSS: String = {
    guard let url = Bundle.module.url(forResource: "markdown-preview", withExtension: "css"),
          let css = try? String(contentsOf: url, encoding: .utf8) else {
        // Sin la hoja de estilo el HTML sigue siendo legible, sólo que sin
        // formato — preferible a no renderizar nada.
        return "body { font-family: -apple-system, sans-serif; padding: 2rem; }"
    }
    return css
}()
