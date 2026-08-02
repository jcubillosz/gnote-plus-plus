import AppKit
import SwiftUI
import WebKit
import Scintilla

/// Estado y motor de la vista previa de Markdown: WKWebView único, debounce del
/// render y navegación restringida. Mismo patrón que FindViewModel (ObservableObject
/// anidado en TabsViewModel, ContentView lo observa aparte porque objectWillChange
/// no se reenvía desde el padre).
final class MarkdownPreviewViewModel: NSObject, ObservableObject {
    @Published var isVisible = false

    /// Creado una sola vez acá, no en el NSViewRepresentable: SwiftUI recrea structs
    /// a cada render, y un WebView nuevo por render sería un proceso de contenido
    /// nuevo cada vez.
    let webView: WKWebView
    private let handler = MarkdownPreviewSchemeHandler()
    private var pendingRefresh: DispatchWorkItem?

    override init() {
        let config = WKWebViewConfiguration()
        // `setURLSchemeHandler` lanza una excepción de Objective-C si el mismo
        // esquema se registra dos veces en la misma config: se registra acá, una
        // sola vez, antes de crear el WebView.
        config.setURLSchemeHandler(handler, forURLScheme: markdownPreviewScheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    /// Debounce de 300 ms: cancela el work item pendiente antes de agendar uno nuevo.
    /// Sin esto cada tecla deja un work item vivo y el render corre N veces (mismo bug
    /// ya corregido una vez en este repo para el highlight de Find, commit 608a563).
    func scheduleRefresh(editor: ScintillaView, document: Document, theme: MarkdownTheme) {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refreshNow(editor: editor, document: document, theme: theme)
        }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Cancela cualquier refresh pendiente sin ejecutarlo — al ocultar la preview o
    /// cerrar la última pestaña no tiene sentido seguir renderizando en 300ms.
    func cancelPendingRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    func refreshNow(editor: ScintillaView, document: Document, theme: MarkdownTheme) {
        // Un refresh pendiente quedó agendado con el documento de ANTES: si llegara a
        // correr después de este, tomaría el texto del buffer nuevo (el editor es uno
        // solo y ya cambió de docpointer) pero con la carpeta base del documento viejo,
        // sirviendo sus imágenes. Cancelarlo acá cubre el cambio de pestaña y el cierre.
        cancelPendingRefresh()

        // El scroll solo se preserva entre re-renders del MISMO documento: restaurar el
        // offset de un archivo largo sobre uno corto deja la preview en cualquier lado.
        let sameDocument = (lastRenderedDocumentID == document.id)
        lastRenderedDocumentID = document.id

        let markdown = currentText(editor)
        let html = renderMarkdownDocument(
            markdown,
            title: document.displayName,
            theme: theme,
            imageSource: .previewScheme
        )
        handler.html = html
        handler.baseDirectory = document.url?.deletingLastPathComponent()

        // Preservar la posición de scroll entre re-renders: JS del contenido está
        // deshabilitado (allowsContentJavaScript = false), pero evaluateJavaScript
        // llamado desde la app sí corre — verificado con un .app real.
        guard sameDocument else {
            load(scrollY: 0)
            return
        }
        webView.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
            let scrollY = (result as? Double) ?? 0
            self?.load(scrollY: scrollY)
        }
    }

    private func load(scrollY: Double) {
        pendingScrollRestore = scrollY
        webView.load(URLRequest(url: markdownPreviewURL))
    }

    private var pendingScrollRestore: Double = 0
    private var lastRenderedDocumentID: UUID?
}

extension MarkdownPreviewViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let y = pendingScrollRestore
        webView.evaluateJavaScript("window.scrollTo(0, \(y))")
    }

    /// La preview nunca navega: solo permite la carga del propio documento generado.
    /// Cualquier otro esquema (http/https/mailto de un link del Markdown) se cancela
    /// y se abre en la app externa correspondiente.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url == markdownPreviewURL {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
            NSWorkspace.shared.open(url)
        }
    }
}

/// El WKWebView es único y vive en el ViewModel, pero esta vista devuelve un contenedor
/// NUEVO cada vez y le adopta el WebView como subvista.
///
/// Devolver el WebView compartido directo desde makeNSView no funciona: al cambiar a una
/// pestaña que no es Markdown, SwiftUI destruye el NSViewRepresentable y saca el WebView
/// de la jerarquía; al volver, makeNSView devuelve la misma instancia pero ya no se
/// re-inserta y el panel queda en blanco para siempre (bug encontrado en QA manual). Con
/// un contenedor propio, el reparenting es explícito y ocurre en cada aparición.
struct MarkdownPreviewView: NSViewRepresentable {
    @ObservedObject var preview: MarkdownPreviewViewModel

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        adopt(preview.webView, into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        adopt(preview.webView, into: container)
    }

    private func adopt(_ webView: WKWebView, into container: NSView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}
