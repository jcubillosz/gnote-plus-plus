import AppKit
import WebKit

/// Diagramas Mermaid para la vista previa sin habilitarle JavaScript.
///
/// La preview sigue con allowsContentJavaScript = false. Los diagramas los dibuja este
/// WKWebView aparte, oculto, que carga solo mermaid.min.js (incluido en la app, vía
/// WKUserScript) sobre una página vacía con CSP `default-src 'none'`: sin red, sin
/// navegación (el delegado cancela todo), y sin acceso a los archivos ni al Markdown más
/// allá del texto del diagrama. El SVG resultante entra a la preview como
/// <img src="data:image/svg+xml…">: un SVG dentro de <img> nunca ejecuta scripts ni carga
/// recursos, aunque mermaid lo hubiera generado con algo raro.
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()
    /// Avisa que terminó una tanda de diagramas: la preview vuelve a renderizar.
    nonisolated static let didRenderNotification = Notification.Name("MermaidRendererDidRender")
    /// Diagramas enormes no se dibujan (la preview muestra el código).
    static let sourceByteLimit = 50_000

    enum Entry {
        case svg(String)
        case failed(String)
    }

    private var cache: [String: Entry] = [:]
    private var queue: [(key: String, source: String, dark: Bool)] = []
    private var webView: WKWebView?
    private var isReady = false
    private var isRendering = false
    private var counter = 0

    /// Sin espacios ni saltos finales: la preview entrega el código como lo da cmark (con
    /// "\n" final) y la exportación como sale del editor (sin él). Con claves distintas el
    /// diagrama ya dibujado no se encontraba al exportar.
    private func key(_ source: String, _ dark: Bool) -> String {
        var trimmed = source
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        return (dark ? "d:" : "l:") + trimmed
    }

    /// Quien espera un diagrama puntual (exportar): se le avisa apenas termina.
    private var waiters: [String: [(Entry) -> Void]] = [:]

    /// Entrega el diagrama: al instante si está en caché; si no, lo dibuja y avisa.
    func render(_ source: String, dark: Bool, completion: @escaping (Entry) -> Void) {
        if let entry = cached(source, dark: dark) {
            completion(entry)
            return
        }
        guard source.utf8.count <= Self.sourceByteLimit else {
            completion(.failed(L("El diagrama es demasiado grande.")))
            return
        }
        waiters[key(source, dark), default: []].append(completion)
        enqueue(source, dark: dark)
    }

    private func store(_ entry: Entry, for key: String) {
        cache[key] = entry
        for waiter in waiters.removeValue(forKey: key) ?? [] { waiter(entry) }
    }

    func cached(_ source: String, dark: Bool) -> Entry? {
        cache[key(source, dark)]
    }

    func enqueue(_ source: String, dark: Bool) {
        let key = key(source, dark)
        guard cache[key] == nil, source.utf8.count <= Self.sourceByteLimit,
              !queue.contains(where: { $0.key == key }) else { return }
        // Cada tecla dentro de un diagrama es una variante nueva: sin tope el caché crecería
        // con toda la historia de edición.
        if cache.count > 200 { cache.removeAll() }
        queue.append((key, source, dark))
        startIfNeeded()
    }

    private func startIfNeeded() {
        if webView == nil {
            guard let url = Bundle.module.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "mermaid"),
                  let script = try? String(contentsOf: url, encoding: .utf8) else {
                for item in queue { store(.failed(L("No se encontró mermaid.min.js")), for: item.key) }
                queue.removeAll()
                return
            }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
            // Tamaño real: mermaid mide el texto (getBBox) y necesita layout.
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: config)
            view.navigationDelegate = self
            webView = view
            let page = """
            <!DOCTYPE html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
            </head><body></body></html>
            """
            view.loadHTMLString(page, baseURL: nil)
            return
        }
        guard isReady, !isRendering, !queue.isEmpty else { return }
        renderNext()
    }

    private func renderNext() {
        guard let webView, !queue.isEmpty else {
            isRendering = false
            NotificationCenter.default.post(name: Self.didRenderNotification, object: nil)
            return
        }
        isRendering = true
        let item = queue.removeFirst()
        counter += 1
        let js = """
        mermaid.initialize({startOnLoad: false, securityLevel: 'strict', theme: theme,
                            flowchart: {htmlLabels: false}, fontFamily: '-apple-system, Helvetica, sans-serif'});
        const result = await mermaid.render(id, source);
        return result.svg;
        """
        webView.callAsyncJavaScript(
            js,
            arguments: ["source": item.source, "theme": item.dark ? "dark" : "default", "id": "mmd\(counter)"],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                if let svg = value as? String, !svg.isEmpty {
                    self.store(.svg(Self.postProcess(svg, dark: item.dark)), for: item.key)
                } else {
                    self.store(.failed(L("Mermaid no devolvió un diagrama")), for: item.key)
                }
            case .failure(let error):
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                    ?? error.localizedDescription
                self.store(.failed(message), for: item.key)
            }
            self.renderNext()
        }
    }

    /// Mermaid emite width="100%" + style="max-width: Npx": dentro de un <img> eso estira
    /// cualquier diagrama angosto a todo el ancho de la preview. Se fija el ancho natural.
    private static func postProcess(_ svg: String, dark: Bool) -> String {
        // <switch><foreignObject>HTML</foreignObject><text>…</text></switch>: dentro de un
        // <img> WebKit elige la rama HTML pero no la pinta, y el texto desaparecía (tareas
        // del diagrama de recorrido). Sin la rama HTML queda el <text> de respaldo.
        let withoutSwitchHTML = svg.replacingOccurrences(
            of: #"<switch>\s*<foreignObject\b.*?</foreignObject>"#, with: "<switch>",
            options: .regularExpression
        )
        // Ese <text> de respaldo lleva la misma clase que su caja (p. ej. "journey-section
        // section-type-0") y el CSS de mermaid le pone el mismo fill: quedaba invisible
        // (las secciones del diagrama de recorrido). Color explícito en el style inline.
        let readable = withoutSwitchHTML.replacingOccurrences(
            of: "<switch><text style=\"",
            with: "<switch><text style=\"fill: \(dark ? "#e6edf3" : "#1f2328"); "
        )
        return naturalSize(readable)
    }

    private static func naturalSize(_ svg: String) -> String {
        guard let range = svg.range(of: #"max-width:\s*([\d.]+)px"#, options: .regularExpression) else { return svg }
        let width = svg[range].replacingOccurrences(of: #"[^\d.]"#, with: "", options: .regularExpression)
        guard let open = svg.range(of: "width=\"100%\""), let w = Double(width) else { return svg }
        var sized = svg.replacingCharacters(in: open, with: "width=\"\(width)\"")
        // También el alto (proporción del viewBox): sin él, un SVG guardado o arrastrado
        // fuera de la app se abría con un lienzo enorme y el diagrama arriba a la izquierda.
        if let tagRange = sized.range(of: "<svg[^>]*>", options: .regularExpression),
           !sized[tagRange].contains(" height="),
           let vbRange = sized[tagRange].range(of: #"viewBox="[-\d. ]+""#, options: .regularExpression) {
            let numbers = sized[vbRange].split(whereSeparator: { !"0123456789.-".contains($0) }).compactMap { Double($0) }
            if numbers.count == 4, numbers[2] > 0 {
                let height = (w * numbers[3] / numbers[2] * 100).rounded() / 100
                sized.insert(contentsOf: " height=\"\(height)\"", at: sized.index(tagRange.lowerBound, offsetBy: 4))
            }
        }
        return sized
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        startIfNeeded()
    }

    /// Solo la carga inicial de la página vacía; ninguna otra navegación.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(isReady ? .cancel : .allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // El proceso de contenido murió (memoria, crash de mermaid): se recrea a demanda.
        self.webView = nil
        isReady = false
        isRendering = false
    }
}

/// HTML del diagrama ya dibujado, o nil si todavía no está (queda encolado y la preview
/// muestra el código mientras tanto).
@MainActor
func mermaidDiagramHTML(source: String, dark: Bool, attributes: String) -> String? {
    // También en el otro tema, en segundo plano: exportar/imprimir usa siempre el claro, y
    // si solo se dibujara el de la preview (oscuro) el PDF saldría con el código.
    MermaidRenderer.shared.enqueue(source, dark: !dark)
    switch MermaidRenderer.shared.cached(source, dark: dark) {
    case .svg(let svg):
        let data = Data(svg.utf8).base64EncodedString()
        return "<div class=\"mermaid-diagram\"\(attributes)><img alt=\"\(escapeHTMLText(L("Diagrama Mermaid")))\" src=\"data:image/svg+xml;base64,\(data)\"></div>"
    case .failed(let message):
        return "<div class=\"mermaid-error\"\(attributes)><strong>Mermaid:</strong> \(escapeHTMLText(message))</div>"
            + "<pre><code>\(escapeHTMLText(source))</code></pre>"
    case nil:
        MermaidRenderer.shared.enqueue(source, dark: dark)
        return nil
    }
}
