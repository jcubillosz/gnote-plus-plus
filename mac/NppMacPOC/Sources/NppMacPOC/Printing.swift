import AppKit

// Imprimir y exportar a PDF: HTML -> NSAttributedString -> NSTextView -> NSPrintOperation.
//
// NO se usa WKWebView.printOperation(with:). Se probó con un .app real y `run()` nunca
// retorna: el PDF crece sin límite (357 MB sin ventana, 365 MB dentro de un NSWindow
// offscreen, 221 MB con un documento de solo 5 párrafos) y la operación no termina. No
// depende del contenido ni de la reentrancia del callback. La ruta nativa, con el mismo
// documento, devuelve true en un segundo y produce 104 KB / 30 páginas con las fuentes
// embebidas — texto vectorial y seleccionable, no rasterizado.
//
// El precio es que el importador HTML de NSAttributedString entiende encabezados, listas,
// tablas, blockquote, código, colores y fuentes, pero no CSS moderno (flexbox,
// border-radius, :has()). El PDF de un Markdown sale más sobrio que la vista previa.

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

    // El importador HTML de NSAttributedString cascadea de forma poco confiable el
    // font-size declarado en <style>/atributos del <pre>: se fuerza acá, directo sobre
    // el NSAttributedString ya importado, para no depender de si el CSS cascadeó.
    // Preserva familia y variantes (negrita/cursiva) de cada run, solo cambia el tamaño.
    let printable: NSAttributedString
    if let bodyFontSize {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        mutable.enumerateAttribute(.font, in: NSRange(location: 0, length: mutable.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let resized = NSFontManager.shared.convert(font, toSize: bodyFontSize)
            mutable.addAttribute(.font, value: resized, range: range)
        }
        printable = mutable
    } else {
        printable = attributed
    }
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

private func makePrintInfo() -> NSPrintInfo {
    let info = NSPrintInfo.shared.copy() as! NSPrintInfo
    info.topMargin = 40
    info.bottomMargin = 40
    info.leftMargin = 40
    info.rightMargin = 40
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
        // borderSize es la hoja completa; el margen superior de makePrintInfo es 40,
        // así que el encabezado va dentro de esa banda y no pisa el texto.
        let origin = NSPoint(x: 40, y: borderSize.height - 26)
        title.draw(at: origin, withAttributes: attributes)

        let line = NSBezierPath()
        line.move(to: NSPoint(x: 40, y: borderSize.height - 30))
        line.line(to: NSPoint(x: borderSize.width - 40, y: borderSize.height - 30))
        NSColor.lightGray.setStroke()
        line.lineWidth = 0.5
        line.stroke()
    }
}
