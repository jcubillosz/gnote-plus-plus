import AppKit
import SwiftUI
import WebKit
import Scintilla

/// Estado y motor de la vista previa de Markdown: WKWebView único, debounce del
/// render y navegación restringida. Mismo patrón que FindViewModel (ObservableObject
/// anidado en TabsViewModel, ContentView lo observa aparte porque objectWillChange
/// no se reenvía desde el padre).
final class MarkdownPreviewViewModel: NSObject, ObservableObject {
    /// Los tres modos de vista de un documento Markdown. `.editor` es el default: abrir
    /// un .md no debe imponerle al usuario una vista previa que no pidió.
    enum PreviewMode: String {
        case editor, split, preview
    }

    /// Persistido para que el modo elegido sobreviva a relanzar la app (brief Task 7).
    @Published var mode: PreviewMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "preview.mode") }
    }

    /// Solo lectura: `true` en `.split`/`.preview`. El código que antes escribía
    /// `isVisible` ahora asigna `mode` directamente (toolbar, menú Vista).
    var isVisible: Bool { mode != .editor }

    // Toggle expuesto por la toolbar. La sincronización real de scroll editor→preview
    // es un paso aparte (SCN_UPDATEUI + SC_UPDATE_V_SCROLL); acá solo persiste la
    // preferencia del usuario.
    @Published var syncScroll: Bool {
        didSet { UserDefaults.standard.set(syncScroll, forKey: "preview.syncScroll") }
    }

    /// Callback hacia ContentView: doble-click en la preview resuelto a una línea de
    /// origen (1-based). ContentView decide el cambio de modo y mueve el caret del editor
    /// — este ViewModel no conoce a TabsViewModel/ScintillaView.
    var onJumpToSourceLine: ((Int) -> Void)?

    /// Creado una sola vez acá, no en el NSViewRepresentable: SwiftUI recrea structs
    /// a cada render, y un WebView nuevo por render sería un proceso de contenido
    /// nuevo cada vez.
    let webView: WKWebView
    private let handler = MarkdownPreviewSchemeHandler()
    private var pendingRefresh: DispatchWorkItem?

    override init() {
        self.mode = UserDefaults.standard.string(forKey: "preview.mode").flatMap(PreviewMode.init(rawValue:)) ?? .editor
        self.syncScroll = UserDefaults.standard.object(forKey: "preview.syncScroll") as? Bool ?? true
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

        // Doble-click → saltar al fuente. `delaysPrimaryMouseButtonEvents = false`: sin
        // esto AppKit retiene el primer click esperando ver si llega un segundo, y la
        // selección de palabra del click simple en la preview queda con un delay perceptible.
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        webView.addGestureRecognizer(doubleClick)
    }

    /// `allowsContentJavaScript = false` bloquea el JS embebido en el HTML renderizado,
    /// no las llamadas que la app misma hace vía evaluateJavaScript — por eso esto funciona
    /// (verificado con un .app real, ver comentario de refreshNow).
    @objc private func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
        guard mode != .editor else { return }
        // WKWebView es flipped=true en macOS (origen arriba-izquierda), igual que el
        // sistema de coordenadas CSS, así que location(in:) mapea directo a px de
        // viewport sin invertir Y. pageZoom no lo toca esta app (queda en 1.0 salvo
        // que se agregue zoom de usuario a futuro), pero se divide para no romper si
        // eso cambia.
        let point = recognizer.location(in: webView)
        let zoom = webView.pageZoom
        let x = point.x / zoom
        let y = point.y / zoom
        let js = "(function(){var e=document.elementFromPoint(\(x), \(y));e=e&&e.closest('[data-sourcepos]');return e?e.getAttribute('data-sourcepos'):null})()"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let sourcepos = result as? String,
                  let line = MarkdownPreviewViewModel.startLine(fromSourcepos: sourcepos) else { return }
            self.onJumpToSourceLine?(line)
        }
    }

    /// Parsea el `data-sourcepos` de cmark-gfm, formato `"L:C-L:C"` (línea:columna inicio -
    /// línea:columna fin, ambos 1-based). Devuelve la línea de inicio.
    static func startLine(fromSourcepos sourcepos: String) -> Int? {
        guard let dashIndex = sourcepos.firstIndex(of: "-") else { return nil }
        let start = sourcepos[sourcepos.startIndex..<dashIndex]
        guard let colonIndex = start.firstIndex(of: ":") else { return nil }
        return Int(start[start.startIndex..<colonIndex])
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

    /// Scroll proporcional (no por anclas): fraction = primera línea visible / líneas
    /// totales desplazables. Una tabla larga o una imagen grande desalinean las dos
    /// mitades — mapear línea de origen a elemento renderizado exigiría instrumentar
    /// el renderer de cmark-gfm con data-line, y es su propio paso, no éste.
    ///
    /// Throttle a ~50ms cancelando el work item pendiente: sin esto cada notch de la
    /// rueda dispara un evaluateJavaScript (mismo bug que tuvo el debounce de 300ms de
    /// refreshNow, corregido para cambio de pestaña / close(at:)).
    func scheduleScrollSync(editor: ScintillaView) {
        guard isVisible, syncScroll else { return }
        pendingScrollSync?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.syncScrollNow(editor: editor)
        }
        pendingScrollSync = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    /// Cancela el sync de scroll pendiente sin ejecutarlo — al cambiar de pestaña o
    /// cerrar la preview, un work item viejo no debe mover la preview del documento nuevo.
    func cancelPendingScrollSync() {
        pendingScrollSync?.cancel()
        pendingScrollSync = nil
    }

    private func syncScrollNow(editor: ScintillaView) {
        let firstVisible = ScintillaView.directCall(editor, message: SCI_GETFIRSTVISIBLELINE, wParam: 0, lParam: 0)
        let linesOnScreen = ScintillaView.directCall(editor, message: SCI_LINESONSCREEN, wParam: 0, lParam: 0)
        let lineCount = ScintillaView.directCall(editor, message: SCI_GETLINECOUNT, wParam: 0, lParam: 0)
        let denominator = max(1, Int(lineCount) - Int(linesOnScreen))
        let fraction = Double(firstVisible) / Double(denominator)
        webView.evaluateJavaScript(
            "window.scrollTo(0, \(fraction) * (document.body.scrollHeight - window.innerHeight))"
        )
    }

    private var pendingScrollSync: DispatchWorkItem?

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
            sourcePositions: true,
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
