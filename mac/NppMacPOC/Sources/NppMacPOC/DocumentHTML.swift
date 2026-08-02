import Foundation
import Scintilla

/// Tamaño de fuente para imprimir el HTML coloreado: más chico que en pantalla, acotado
/// a 8-11pt (el tamaño de edición puede ser bastante mayor que lo cómodo para imprimir,
/// y restar 2 solo no alcanza a bajarlo). Compartido con Printing.swift, que lo vuelve a
/// forzar sobre el NSAttributedString ya importado — el CSS del <pre> no cascadea de
/// forma confiable en el importador HTML de NSAttributedString.
func printBodyFontSize(preferences: EditorPreferences) -> CGFloat {
    CGFloat(min(11, max(8, Int(preferences.fontSize.rounded()) - 2)))
}

/// Convierte el documento activo en HTML con los colores de sintaxis, para imprimir y
/// exportar.
///
/// Deliberadamente usa el perfil del tema CLARO, sin importar el tema en pantalla: en
/// modo oscuro, los colores del editor tienen fondos oscuros y una impresora vacía el
/// cartucho pintándolos. La regla ya no es "impreso y en pantalla no pueden discrepar" —
/// imprimir siempre se ve como el tema claro.
func styledHTMLDocument(editor: ScintillaView, document: Document, preferences: EditorPreferences) -> String {
    let text = currentText(editor)
    // Si el documento no tiene extensión reconocida, forExtension ya devuelve el perfil
    // nulo (negro sobre blanco), que es el camino correcto para imprimir.
    let lightProfile = document.url.map { languageProfile(forExtension: $0.pathExtension, theme: .light) } ?? document.languageProfile
    let body = styledHTMLBody(editor: editor, text: text, styles: lightProfile.styles)
    let title = escapeHTMLText(document.displayName)

    // La fuente y el tamaño salen de las preferencias del editor: imprimir con otra
    // tipografía cambiaría dónde cortan las líneas respecto de lo que se ve.
    // Va dentro de una regla CSS, no de texto HTML: escapar entidades no la sanea.
    // Se descartan comillas y barras, que son lo único que puede romper la declaración.
    let fontFamily = preferences.fontName.filter { $0 != "\"" && $0 != "'" && $0 != "\\" }
    let fontSize = Int(printBodyFontSize(preferences: preferences))

    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <title>\(title)</title>
    <style>
    body { margin: 0; }
    /* El encabezado con el nombre del archivo NO va acá: el importador de
       NSAttributedString ignora `position: fixed`, así que solo saldría en la primera
       página. Lo dibuja PaginatedTextView en cada página (ver Printing.swift). */
    @media print { @page { margin: 1.5cm; } }
    </style>
    </head>
    <body>
    <pre style="font-family:'\(fontFamily)', Menlo, monospace; font-size:\(fontSize)pt; line-height:1.35; white-space:pre-wrap; word-wrap:break-word; margin:0;">\(body)</pre>
    </body>
    </html>
    """
}

/// Recorre el texto agrupando caracteres consecutivos que comparten estilo y emite un
/// `<span>` por grupo. Un span por carácter multiplicaría por diez el tamaño del HTML.
private func styledHTMLBody(editor: ScintillaView, text: String, styles: [Int: StyleSpec]) -> String {
    guard !text.isEmpty else { return "" }

    // Scintilla colorea de forma perezosa: una edición reinicia endStyled en ese punto y
    // solo se re-estiliza hasta el final de lo visible al pintar. SCI_GETSTYLEAT más allá
    // de SCI_GETENDSTYLED devuelve 0, así que sin esto, editar la línea 5 de un archivo
    // largo e imprimir sin scrollear sacaría todo lo de abajo en negro.
    _ = ScintillaView.directCall(editor, message: SCI_COLOURISE, wParam: 0, lParam: -1)

    var html = ""
    html.reserveCapacity(text.count * 2)

    var runText = ""
    var runStyle: Int?
    var byteOffset = 0
    var isFirst = true

    func flushRun() {
        guard !runText.isEmpty else { return }
        html += span(for: runStyle, content: escapeHTMLText(runText), styles: styles)
        runText = ""
    }

    for character in text {
        // Scintilla indexa los estilos POR BYTE y el texto es UTF-8: consultar byte a byte
        // partiría un carácter multibyte al medio y produciría basura. Se consulta en el
        // primer byte de cada carácter y el grupo queda alineado a caracteres.
        let style = Int(ScintillaView.directCall(editor, message: SCI_GETSTYLEAT, wParam: uptr_t(byteOffset), lParam: 0))
        byteOffset += character.utf8.count

        if isFirst {
            runStyle = style
            isFirst = false
        } else if style != runStyle {
            flushRun()
            runStyle = style
        }
        runText.append(character)
    }
    flushRun()

    return html
}

private func span(for styleID: Int?, content: String, styles: [Int: StyleSpec]) -> String {
    guard let styleID, let spec = styles[styleID] else { return content }

    var css = "color:\(scintillaBGRToCSSHex(spec.fore))"
    // El fondo se omite si es blanco: pintar un rectángulo blanco por cada run no cambia
    // nada en pantalla y en papel gasta tinta en las impresoras que no lo detectan.
    if let back = spec.back, scintillaBGRToCSSHex(back).lowercased() != "#ffffff" {
        css += ";background-color:\(scintillaBGRToCSSHex(back))"
    }
    // Máscara FONTSTYLE_* de M3 (1 negrita, 2 cursiva, 4 subrayado).
    if let fontStyle = spec.fontStyle {
        if fontStyle & 1 != 0 { css += ";font-weight:bold" }
        if fontStyle & 2 != 0 { css += ";font-style:italic" }
        if fontStyle & 4 != 0 { css += ";text-decoration:underline" }
    }
    return "<span style=\"\(css)\">\(content)</span>"
}
