import AppKit
import WebKit
import UniformTypeIdentifiers
import Scintilla

/// Guardar/copiar el diagrama Mermaid donde está el caret (menú Diagramas). Usa la versión
/// en tema claro, la misma que exportar/imprimir: se lee bien sobre fondo blanco y al
/// compartirla no depende del tema de quien la abra.
@MainActor
enum MermaidExport {
    enum Format { case png, svg }

    /// Texto del bloque ```mermaid que contiene la línea del caret, o nil.
    static func sourceAtCaret(editor: ScintillaView) -> String? {
        let lines = currentText(editor).components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let pos = ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0)
        let caretLine = Int(ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(pos), lParam: 0))
        guard caretLine < lines.count else { return nil }
        // Se recorren las cercas desde el principio: así una ``` de cierre no se confunde
        // con una de apertura.
        var openLine: Int?
        var isMermaid = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { continue }
            if let start = openLine {
                if index >= caretLine {
                    return isMermaid && caretLine >= start ? lines[(start + 1)..<index].joined(separator: "\n") : nil
                }
                openLine = nil
            } else {
                if index > caretLine { return nil }
                openLine = index
                isMermaid = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("mermaid")
            }
        }
        return nil
    }

    static func save(_ format: Format, editor: ScintillaView, document: Document?) {
        guard let source = caretSourceOrAlert(editor: editor) else { return }
        save(format, source: source, document: document)
    }

    static func copyImage(editor: ScintillaView) {
        guard let source = caretSourceOrAlert(editor: editor) else { return }
        copyImage(source: source)
    }

    static func save(_ format: Format, source: String, document: Document?) {
        withSVG(for: source) { svg in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == .png ? .png : .svg]
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMddHHmmss"
            panel.nameFieldStringValue = "img_\(stamp.string(from: Date())).\(format == .png ? "png" : "svg")"
            if let folder = document?.url?.deletingLastPathComponent() { panel.directoryURL = folder }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            switch format {
            case .svg:
                write(Data(svg.utf8), to: url)
            case .png:
                PNGSnapshotter.render(svg: svg) { data in
                    guard let data else { return failed(nil) }
                    write(data, to: url)
                }
            }
        }
    }

    static func copyImage(source: String) {
        withSVG(for: source) { svg in
            PNGSnapshotter.render(svg: svg) { data in
                guard let data else { return failed(nil) }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(data, forType: .png)
            }
        }
    }

    private static func caretSourceOrAlert(editor: ScintillaView) -> String? {
        guard let source = sourceAtCaret(editor: editor) else {
            alert(L("El cursor no está dentro de un bloque ```mermaid."), detail: "")
            return nil
        }
        return source
    }

    /// Código de un bloque a partir del data-sourcepos de cmark ("L1:C-L2:C", 1-based):
    /// L1 es la cerca de apertura y L2 la de cierre.
    static func source(fromSourcepos sourcepos: String, text: String) -> String? {
        let numbers = sourcepos.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 3 else { return nil }
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let first = numbers[0], last = numbers[2]
        guard first >= 1, last <= lines.count, last - 1 > first else { return nil }
        return lines[first..<(last - 1)].joined(separator: "\n")
    }

    /// SVG claro del diagrama; si todavía no está dibujado espera a que lo esté (sin avisar:
    /// tarda menos de un segundo). Solo avisa si el diagrama tiene errores.
    private static func withSVG(for source: String, _ action: @escaping (String) -> Void) {
        MermaidRenderer.shared.render(source, dark: false) { entry in
            switch entry {
            case .svg(let svg): action(svg)
            case .failed(let message): alert(L("El diagrama tiene errores."), detail: message)
            }
        }
    }

    private static func write(_ data: Data, to url: URL) {
        do { try data.write(to: url, options: .atomic) } catch { failed(error) }
    }

    private static func failed(_ error: Error?) {
        alert(L("No se pudo generar la imagen del diagrama."), detail: error?.localizedDescription ?? "")
    }

    private static func alert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

/// SVG → PNG a 2x. WebKit dibuja el SVG igual que en la preview (NSImage no soporta todo
/// lo que emite mermaid). Ventana fuera de pantalla: un WKWebView sin ventana no pinta y
/// takeSnapshot devuelve una imagen vacía. Sin JavaScript, y el SVG va como <img>.
@MainActor
private final class PNGSnapshotter: NSObject, WKNavigationDelegate {
    private static var active: Set<PNGSnapshotter> = []

    private let window: NSWindow
    private let webView: WKWebView
    private let size: NSSize
    private let completion: (Data?) -> Void

    static func render(svg: String, completion: @escaping (Data?) -> Void) {
        let snapshotter = PNGSnapshotter(svg: svg, completion: completion)
        active.insert(snapshotter)
    }

    private init(svg: String, completion: @escaping (Data?) -> Void) {
        size = Self.naturalSize(of: svg)
        self.completion = completion
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let frame = NSRect(origin: .zero, size: size)
        webView = WKWebView(frame: frame, configuration: config)
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)
        webView.navigationDelegate = self
        let data = Data(svg.utf8).base64EncodedString()
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;background:#fff}img{display:block;width:\(size.width)px;height:\(size.height)px}</style>
        </head><body><img src="data:image/svg+xml;base64,\(data)"></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Un respiro para que el <img> termine de decodificar antes de la captura.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(origin: .zero, size: size)
            // snapshotWidth va en puntos: en pantallas Retina ya sale al doble de píxeles.
            let scale = window.backingScaleFactor
            config.snapshotWidth = NSNumber(value: Double(size.width * 2 / max(1, scale)))
            webView.takeSnapshot(with: config) { [self] image, _ in
                var png: Data?
                if let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                }
                finish(png)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }

    private func finish(_ data: Data?) {
        window.orderOut(nil)
        window.close()
        completion(data)
        Self.active.remove(self)
    }

    /// Ancho del atributo width y alto según la proporción del viewBox.
    private static func naturalSize(of svg: String) -> NSSize {
        // Solo la etiqueta <svg …>: más adentro cualquier <rect width="…"> engañaría.
        let tag = svg.range(of: "<svg[^>]*>", options: .regularExpression).map { String(svg[$0]) } ?? svg
        func number(_ pattern: String) -> [Double] {
            guard let range = tag.range(of: pattern, options: .regularExpression) else { return [] }
            return tag[range].split(whereSeparator: { !"0123456789.-".contains($0) }).compactMap { Double($0) }
        }
        let viewBox = number(#"viewBox="[-\d. ]+""#)
        let width = number(#"\swidth="[\d.]+""#).first ?? (viewBox.count == 4 ? viewBox[2] : 800)
        let height = viewBox.count == 4 && viewBox[2] > 0 ? width * viewBox[3] / viewBox[2] : 600
        return NSSize(width: max(1, min(width, 4000)), height: max(1, min(height, 4000)))
    }
}
