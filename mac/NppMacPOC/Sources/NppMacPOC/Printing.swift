import AppKit
import CoreGraphics
import PDFKit
import WebKit

// Imprimir y exportar a PDF del código coloreado (no-Markdown): HTML -> NSAttributedString
// -> NSTextView -> NSPrintOperation.
//
// NO se usa WKWebView.printOperation(with:). Se probó con un .app real y `run()` nunca
// retorna: el PDF crece sin límite (357 MB sin ventana, 365 MB dentro de un NSWindow
// offscreen, 221 MB con un documento de solo 5 párrafos) y la operación no termina. No
// depende del contenido ni de la reentrancia del callback. La ruta nativa, con el mismo
// documento, devuelve true en un segundo y produce 104 KB / 30 páginas con las fuentes
// embebidas — texto vectorial y seleccionable, no rasterizado.
//
// El precio es que el importador HTML de NSAttributedString entiende encabezados, listas,
// colores y fuentes, pero NO tablas reales (linealiza cada celda, una por línea, incluso
// sin CSS de por medio — probado con una tabla mínima) ni CSS moderno. Por eso Markdown
// (que sí puede traer tablas) usa un camino aparte más abajo: WKWebView.createPDF, una
// API distinta de printOperation, sin el bug de arriba — genera el PDF ya paginado con
// CSS real y de ahí en más todo pasa por PDFKit.

/// Reemplaza los tamaños de fuente de un NSAttributedString ya importado, preservando
/// la jerarquía relativa en vez de aplanarla a un solo tamaño.
///
/// El importador HTML de NSAttributedString sí trae el `font-size` de cada tag (2em en
/// h1, 1.5em en h2, etc.) pero relativo al tamaño base de WebKit (~15-16pt), no al de
/// impresión: un h1 sale con ~30pt en papel y hasta el cuerpo sale más grande que
/// `bodySize` (14pt en vez de 11pt), así que "todo lo que mida más que bodySize es
/// título" clasifica mal — el cuerpo mismo cae ahí. En cambio: se pesa cada tamaño por
/// cuánto texto cubre (en caracteres) y el que más cubre ES el cuerpo real, sea cual
/// sea su valor en puntos; el resto se reescala por su RATIO contra ese cuerpo detectado
/// (2x, 1.5x, 1.25x… igual que el CSS de la preview), no por su valor absoluto.
private func remapFontSizes(_ attributed: NSAttributedString, bodySize: CGFloat) -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: attributed)
    let fullRange = NSRange(location: 0, length: mutable.length)

    var weightBySize: [CGFloat: Int] = [:]
    mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
        guard let font = value as? NSFont else { return }
        weightBySize[font.pointSize.rounded(), default: 0] += range.length
    }
    guard let detectedBodySize = weightBySize.max(by: { $0.value < $1.value })?.key, detectedBodySize > 0 else {
        return attributed
    }

    // Escalones relativos al cuerpo detectado, calcados de los ratios em de
    // markdownPreviewCSS (h1 2em, h2 1.5em, h3 1.25em) pero aplicados sobre bodySize.
    func target(forRatio ratio: CGFloat) -> CGFloat {
        switch ratio {
        case 1.85...: return bodySize + 3
        case 1.35..<1.85: return bodySize + 2
        case 1.15..<1.35: return bodySize + 1.5
        default: return bodySize
        }
    }

    mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
        guard let font = value as? NSFont else { return }
        let ratio = font.pointSize.rounded() / detectedBodySize
        let resized = NSFontManager.shared.convert(font, toSize: target(forRatio: ratio))
        mutable.addAttribute(.font, value: resized, range: range)
    }
    return mutable
}

/// Arma la vista de texto paginable a partir del HTML. Devuelve nil si el HTML no se
/// puede interpretar, que en la práctica solo pasa si viene vacío o mal formado.
private func makePrintableTextView(html: String, printInfo: NSPrintInfo, header: String, bodyFontSize: CGFloat? = nil) -> PaginatedTextView? {
    guard let data = html.data(using: .utf8),
          let attributed = NSAttributedString(
            html: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
          )
    else { return nil }

    let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
    let textView = PaginatedTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
    textView.headerTitle = header
    // El HTML renderizado (Markdown y preview) siempre se piensa como "hoja blanca":
    // sin esto, con la app en tema oscuro el NSTextView hereda fondo oscuro del sistema.
    textView.drawsBackground = true
    textView.backgroundColor = .white

    let printable = bodyFontSize.map { remapFontSizes(attributed, bodySize: $0) } ?? attributed
    textView.textStorage?.setAttributedString(printable)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true

    // Sin forzar el layout, la altura queda en el valor inicial y sale una sola página
    // casi vacía en vez del documento completo.
    textView.sizeToFit()

    return textView
}

/// 2cm en puntos (1cm = 72/2.54pt) — margen de hoja pedido para impresión/PDF.
private let printMarginPoints: CGFloat = 2 * 72 / 2.54

private func makePrintInfo() -> NSPrintInfo {
    let info = NSPrintInfo.shared.copy() as! NSPrintInfo
    info.topMargin = printMarginPoints
    info.bottomMargin = printMarginPoints
    info.leftMargin = printMarginPoints
    info.rightMargin = printMarginPoints
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    // NSPrintInfo.shared puede traer esto en true (según panel de impresión del sistema
    // o de un job anterior); un documento corto saldría centrado en la hoja en vez de
    // empezar arriba.
    info.isVerticallyCentered = false
    info.isHorizontallyCentered = false
    return info
}

/// Abre el diálogo de impresión del sistema con el documento ya paginado.
func printHTML(_ html: String, jobTitle: String, bodyFontSize: CGFloat? = nil) {
    let info = makePrintInfo()
    guard let textView = makePrintableTextView(html: html, printInfo: info, header: jobTitle, bodyFontSize: bodyFontSize) else {
        presentPrintError(detail: L("No se pudo preparar el documento para imprimir."))
        return
    }
    let operation = NSPrintOperation(view: textView, printInfo: info)
    operation.jobTitle = jobTitle
    operation.run()
}

/// Escribe el documento como PDF. Devuelve false si falló, para que el llamador avise.
func savePDF(from html: String, to url: URL, jobTitle: String, bodyFontSize: CGFloat? = nil) -> Bool {
    let info = makePrintInfo()
    info.jobDisposition = .save
    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

    guard let textView = makePrintableTextView(html: html, printInfo: info, header: jobTitle, bodyFontSize: bodyFontSize) else { return false }

    let operation = NSPrintOperation(view: textView, printInfo: info)
    operation.jobTitle = jobTitle
    // Sin desactivar los paneles, exportar a PDF abriría el diálogo de impresión igual.
    operation.showsPrintPanel = false
    operation.showsProgressPanel = false
    return operation.run()
}

func presentPrintError(detail: String) {
    let alert = NSAlert()
    alert.messageText = L("No se pudo imprimir el documento.")
    alert.informativeText = detail
    alert.addButton(withTitle: L("OK"))
    alert.runModal()
}

/// NSTextView que dibuja el nombre del archivo arriba de CADA página.
///
/// El encabezado no puede venir del HTML: el importador de NSAttributedString ignora
/// `position: fixed`, así que un `<div>` saldría solo en la primera página. AppKit lo
/// resuelve con drawPageBorder(with:), que se llama una vez por página.
final class PaginatedTextView: NSTextView {
    var headerTitle: String = ""

    override func drawPageBorder(with borderSize: NSSize) {
        guard !headerTitle.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.gray
        ]
        let title = headerTitle as NSString
        // borderSize es la hoja completa; el margen superior de makePrintInfo es
        // printMarginPoints, así que el encabezado va dentro de esa banda y no pisa el texto.
        let origin = NSPoint(x: printMarginPoints, y: borderSize.height - 26)
        title.draw(at: origin, withAttributes: attributes)

        let line = NSBezierPath()
        line.move(to: NSPoint(x: printMarginPoints, y: borderSize.height - 30))
        line.line(to: NSPoint(x: borderSize.width - printMarginPoints, y: borderSize.height - 30))
        NSColor.lightGray.setStroke()
        line.lineWidth = 0.5
        line.stroke()
    }
}

// MARK: - PDF de Markdown (WKWebView.createPDF + PDFKit)

/// Hoja carta US en puntos (1pt = 1/72"; WKWebView ya opera en esa misma unidad, un CSS
/// px de contenido mide 1pt acá, sin conversión de dpi de por medio) y margen de 2cm.
private let markdownPDFPageSize = CGSize(width: 612, height: 792)
private let markdownPDFMargin: CGFloat = 2 * 72 / 2.54
private let markdownPDFContentWidth = markdownPDFPageSize.width - markdownPDFMargin * 2

/// JS que junta los bordes inferiores de los elementos "seguros para cortar" (párrafo,
/// ítem de lista, fila de tabla, título, bloque de código, cita, imagen) — el resultado
/// (JSON, array de Y en px CSS desde el borde superior del documento) le dice a
/// paginate() dónde SÍ puede terminar una página sin partir un renglón al medio.
private let markdownPageBreakPointsJS = """
JSON.stringify(Array.from(new Set(
  Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,tr,pre,blockquote,hr,img'))
    .map(function(el) { return Math.round(el.getBoundingClientRect().bottom); })
    .filter(function(y) { return y > 0; })
)).sort(function(a, b) { return a - b; }))
"""

/// `WKWebView.createPDF` sin `rect` explícito NO pagina por `@page` del CSS: genera una
/// única página tan alta como TODO el contenido renderizado (un documento de 9 páginas
/// de texto sale como una sola página gigante, y al imprimirla en una hoja carta normal
/// solo se ve la esquina que entra). Esta función corta esa tira larga en páginas carta
/// reales con margen, redibujando el mismo contenido origen recortado y trasladado en
/// cada una. `breakPoints` (bordes inferiores de párrafos/filas/títulos, en el mismo
/// sistema de coordenadas — ver markdownPageBreakPointsJS) evita partir un renglón al
/// medio: cada corte de página se ajusta al candidato más cercano por debajo del alto
/// ideal, en vez de cortar a una altura fija ciega.
private func paginate(_ singlePagePDF: Data, pageSize: CGSize, margin: CGFloat, breakPoints: [CGFloat]) -> Data? {
    guard let provider = CGDataProvider(data: singlePagePDF as CFData),
          let sourceDocument = CGPDFDocument(provider),
          let sourcePage = sourceDocument.page(at: 1)
    else { return nil }

    let sourceBox = sourcePage.getBoxRect(.mediaBox)
    let contentWidth = pageSize.width - margin * 2
    let contentHeight = pageSize.height - margin * 2
    guard contentHeight > 0, sourceBox.width > 0, sourceBox.height > 0 else { return nil }

    // createPDF puede entregar la página al factor de escala real de la pantalla (2x en
    // Retina), no 1pt-por-CSS-px: no se puede asumir que el ancho de la página fuente
    // coincide con markdownPDFContentWidth. Se mide el ancho real y se calcula la
    // escala necesaria para llevarlo al ancho de contenido de la hoja de destino.
    let scale = contentWidth / sourceBox.width
    let sourceHeight = sourceBox.height
    let maxContentPerPage = contentHeight / scale
    let sortedBreaks = breakPoints.sorted()
    // El WKWebView reporta el alto de documento como máximo(alto real del contenido,
    // alto del viewport) — con un documento corto en un frame de 800pt, scrollHeight
    // (y por lo tanto sourceHeight acá) sale inflado a 800 aunque el contenido real
    // termine mucho antes, dejando "relleno" en blanco que el bucle de abajo pagina
    // igual. Se corta en el último punto de corte real (fin del último párrafo/fila/
    // título), no en sourceHeight, para no generar una página vacía por ese relleno.
    let contentBottom = sortedBreaks.last ?? sourceHeight

    // Recorre el documento de arriba hacia abajo (coordenadas DOM, 0 en el borde
    // superior) armando páginas: cada una toma tanto contenido como entre hasta el
    // candidato de corte válido más grande que no pase el alto ideal.
    var pageRanges: [(top: CGFloat, bottom: CGFloat)] = []
    var currentTop: CGFloat = 0
    while currentTop < contentBottom - 0.5 {
        let idealBottom = min(currentTop + maxContentPerPage, contentBottom)
        let candidate = sortedBreaks.last { $0 > currentTop + 1 && $0 <= idealBottom }
        // Sin candidato válido (un solo elemento más alto que una página entera): corte
        // duro en el ideal, mejor una página con un salto feo que un bucle infinito.
        let bottom = candidate ?? idealBottom
        pageRanges.append((currentTop, bottom))
        currentTop = bottom
    }
    if pageRanges.isEmpty { pageRanges = [(0, sourceHeight)] }

    let output = NSMutableData()
    guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return nil }
    var mediaBox = CGRect(origin: .zero, size: pageSize)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

    for range in pageRanges {
        context.beginPDFPage(nil)
        context.saveGState()
        // Todo lo que caiga fuera de la caja de contenido (dentro del margen) se descarta:
        // sin este clip, dibujar la página origen completa la desbordaría en las 4
        // direcciones sobre cada hoja.
        context.clip(to: CGRect(x: margin, y: margin, width: contentWidth, height: contentHeight))
        // Se ancla el borde SUPERIOR de la porción al tope de la caja de contenido (no
        // el inferior): así el contenido fluye desde arriba y el espacio que sobra en
        // la última página (más corta que una hoja completa) queda abajo, como en
        // cualquier documento normal — anclar por abajo lo empujaba al fondo de la hoja
        // dejando un hueco enorme arriba en toda página que no llenara el margen entero.
        // PDF crece en Y hacia arriba; range.top está en coordenadas DOM (Y hacia abajo
        // desde el tope del documento) — hay que convertir al sistema de la página origen.
        let sliceTopInSource = sourceHeight - range.top
        context.translateBy(x: margin, y: margin + contentHeight - scale * sliceTopInSource)
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(sourcePage)
        context.restoreGState()
        context.endPDFPage()
    }
    context.closePDF()
    return output as Data
}

/// Overrides para la copia de Markdown que va a `createPDF` — no van dentro de un
/// `@media print` porque createPDF renderiza en modo pantalla (esa media query nunca
/// dispara), así que se inyectan como reglas normales, después de markdownPreviewCSS,
/// y ganan por cascada. `padding:0` en vez del `2rem/2.5rem` de pantalla porque el
/// margen de hoja ya lo pone paginate() con margin/clip en el PDF final — duplicarlo acá
/// sumaría los dos y dejaría un margen lateral enorme.
private let markdownPrintOverrideCSS = """
body { padding: 0; font-size: 11pt; font-family: Helvetica, Arial, sans-serif; }
h1 { font-size: 14pt; }
h2 { font-size: 13pt; }
h3 { font-size: 12.5pt; }
h4, h5, h6 { font-size: 11pt; }
table { display: table; width: 100%; overflow: visible; }
h1, h2, h3, h4, h5, h6 { break-after: avoid; }
pre, blockquote, table, img { break-inside: avoid; }
a { color: inherit; text-decoration: underline; }
"""

/// Genera el PDF de un HTML renderizado (Markdown) cargándolo en un WKWebView real y
/// pidiéndole el PDF ya paginado — CSS completo (tablas, todo lo que la vista previa en
/// pantalla ya muestra bien). Se autorretiene en `active` mientras dura la carga async:
/// `webView.navigationDelegate` es `weak`, así que sin esto el generador se liberaría
/// antes de que `didFinish` llegue a dispararse.
private final class MarkdownPDFGenerator: NSObject, WKNavigationDelegate {
    private static var active: [MarkdownPDFGenerator] = []

    private var webView: WKWebView?
    private var completion: ((Data?) -> Void)?

    static func generate(html rawHTML: String, baseURL: URL?, completion: @escaping (Data?) -> Void) {
        let html = rawHTML.replacingOccurrences(
            of: "</head>",
            with: "<style>\(markdownPrintOverrideCSS)</style></head>"
        )
        let generator = MarkdownPDFGenerator()
        generator.completion = completion
        active.append(generator)

        // El ancho del frame SÍ importa (determina dónde envuelve el texto); el alto no
        // — createPDF sin `rect` captura la altura completa de scroll del documento, no
        // el alto del frame. Se usa el ancho de contenido (carta menos los 2 márgenes)
        // para que el resultado ya venga al ancho final y paginate() no tenga que escalar.
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: markdownPDFContentWidth, height: 800))
        webView.navigationDelegate = generator
        generator.webView = webView
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    private func finish(_ data: Data?, breakPoints: [CGFloat]) {
        completion?(data.flatMap { paginate($0, pageSize: markdownPDFPageSize, margin: markdownPDFMargin, breakPoints: breakPoints) })
        completion = nil
        webView = nil
        MarkdownPDFGenerator.active.removeAll { $0 === self }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Los puntos de corte hay que medirlos ANTES de createPDF, sobre el DOM ya
        // layouteado: son coordenadas de pantalla (getBoundingClientRect), no algo que
        // se pueda derivar del PDF ya generado.
        webView.evaluateJavaScript(markdownPageBreakPointsJS) { [weak self] result, _ in
            let breakPoints = ((result as? String).flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [Double])?
                .map { CGFloat($0) } ?? []
            webView.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
                self?.finish(try? result.get(), breakPoints: breakPoints)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil, breakPoints: [])
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil, breakPoints: [])
    }
}

/// Imprime el PDF renderizado de Markdown con el diálogo nativo de impresión, vía PDFKit
/// (no NSAttributedString/NSTextView — ver nota de MarkdownPDFGenerator).
func printMarkdownHTML(_ html: String, baseURL: URL?, jobTitle: String) {
    MarkdownPDFGenerator.generate(html: html, baseURL: baseURL) { data in
        // paginate() ya cortó el contenido a markdownPDFPageSize: NSPrintInfo.shared
        // podría traer otro tamaño de papel (A4 en vez de carta) y desalinear el corte.
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = markdownPDFPageSize
        guard let data, let document = PDFDocument(data: data),
              let operation = document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: true)
        else {
            presentPrintError(detail: L("No se pudo preparar el documento para imprimir."))
            return
        }
        operation.jobTitle = jobTitle
        operation.run()
    }
}

/// Guarda el PDF renderizado de Markdown vía WebKit. `completion` porque createPDF es
/// async — no hay forma de bloquear el hilo principal esperándolo como con NSPrintOperation.
func saveMarkdownPDF(html: String, baseURL: URL?, to url: URL, completion: @escaping (Bool) -> Void) {
    MarkdownPDFGenerator.generate(html: html, baseURL: baseURL) { data in
        guard let data else {
            completion(false)
            return
        }
        do {
            try data.write(to: url)
            completion(true)
        } catch {
            completion(false)
        }
    }
}
