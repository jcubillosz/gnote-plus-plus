import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// Vista previa en vivo de documentos HTML (lexer "hypertext"). Mismo esquema propio que la de
// Markdown (ver MarkdownPreviewScheme.swift): `index.html` es el texto actual del editor, no lo
// guardado, y las rutas relativas (`css/a.css`, `img/x.png`) se sirven de la carpeta del
// documento. A diferencia de Markdown, acá el JavaScript de la página SÍ corre (una página real
// sin JS no se ve como en el navegador), así que el WKWebView es otro, separado del de Markdown,
// y sin ningún WKScriptMessageHandler: la página no tiene puente hacia la app.

let htmlPreviewScheme = "gnote-html"
let htmlPreviewURL = URL(string: "\(htmlPreviewScheme)://preview/index.html")!

// MARK: - Resolución de rutas

/// Ruta pedida por la página (percent-encoded, con "/" inicial) → archivo dentro de `base`, o nil
/// si no queda adentro. Decodifica ANTES de normalizar: si no, `%2e%2e` pasaría la normalización
/// como un nombre normal y recién al leer el disco valdría `..`. Un `..` que sube por encima de
/// `base` se rechaza en vez de recortarse (como haría un navegador con la raíz del sitio): con JS
/// y red habilitados, servir algo distinto de lo pedido no gana nada y oculta el intento.
/// Tampoco sirve nada con un componente oculto (`.ssh`, `.env`, `.git`): con un .html en la carpeta
/// de usuario, la página podría leer `~/.ssh/id_rsa` y mandarlo por red.
func resolvePreviewPath(_ requestPath: String, base: URL) -> URL? {
    guard let decoded = requestPath.removingPercentEncoding, !decoded.contains("\0") else { return nil }
    var parts: [String] = []
    for component in decoded.split(separator: "/", omittingEmptySubsequences: true) {
        switch component {
        case ".":
            continue
        case "..":
            guard !parts.isEmpty else { return nil }
            parts.removeLast()
        default:
            guard !component.hasPrefix(".") else { return nil }
            parts.append(String(component))
        }
    }
    guard !parts.isEmpty else { return nil }
    let root = base.standardizedFileURL
    let resolved = parts.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
    // Segunda barrera, independiente del recorrido de arriba.
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard resolved.path.hasPrefix(prefix) else { return nil }
    return resolved
}

/// Solo recursos web. Con JS y red habilitados, la página podría leer cualquier archivo de la
/// carpeta (un .pem, un .pdf, una base de datos) y mandarlo afuera; lo que una página real no
/// pediría como recurso da 404.
let servablePreviewExtensions: Set<String> = [
    "html", "htm", "xhtml", "css", "js", "mjs", "json", "map", "svg", "png", "jpg", "jpeg", "gif",
    "webp", "avif", "ico", "bmp", "woff", "woff2", "ttf", "otf", "eot", "mp3", "ogg", "wav", "m4a",
    "mp4", "webm", "ogv", "wasm", "txt", "xml", "csv",
]

func isServablePreviewExtension(_ pathExtension: String) -> Bool {
    servablePreviewExtensions.contains(pathExtension.lowercased())
}

// MARK: - Fin resolución

/// Sirve `gnote-html://preview/…`: `index.html` desde memoria; el resto, archivos de la carpeta
/// del documento vía `resolvePreviewPath`.
final class HTMLPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    var html = ""
    /// nil = documento sin guardar: solo existe `index.html`, sin recursos relativos.
    var baseDirectory: URL?

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        // El path ya decodificado de URL.path haría que `%252e` llegara como `%2e` y se
        // decodificara dos veces; resolvePreviewPath espera el path crudo.
        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        if rawPath == "/index.html" || rawPath == "/" || rawPath.isEmpty {
            respond(urlSchemeTask, url: url, data: Data(html.utf8), mimeType: "text/html", encoding: "utf-8")
            return
        }
        guard let baseDirectory, let fileURL = resolvePreviewPath(rawPath, base: baseDirectory),
              Self.isInsideAfterSymlinks(fileURL, base: baseDirectory) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        guard isServablePreviewExtension(fileURL.pathExtension) else {
            respondNotFound(urlSchemeTask, url: url)
            return
        }
        // mappedIfSafe: un video o una fuente grande no se copian enteros a memoria.
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        respond(urlSchemeTask, url: url, data: data, mimeType: Self.mimeType(for: fileURL.pathExtension), encoding: nil)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Todo se resuelve sincrónico en `start`: no hay nada pendiente que cancelar.
    }

    /// Un symlink dentro de la carpeta puede apuntar fuera (un .zip descargado los conserva), y
    /// con JS + red la página podría leerlo y mandarlo afuera. resolvePreviewPath es solo léxica;
    /// esto compara las rutas reales. resolvingSymlinksInPath quita `/private` en ambos lados.
    private static func isInsideAfterSymlinks(_ fileURL: URL, base: URL) -> Bool {
        let realBase = base.standardizedFileURL.resolvingSymlinksInPath().path
        let real = fileURL.resolvingSymlinksInPath().path
        return real.hasPrefix(realBase.hasSuffix("/") ? realBase : realBase + "/")
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mimeType: String, encoding: String?) {
        // HTTPURLResponse con 200 (no URLResponse a secas): `fetch()` de la página mira `ok`/`status`.
        var contentType = mimeType
        if let encoding { contentType += "; charset=\(encoding)" }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType, "Content-Length": "\(data.count)",
                                                      // Sin esto WebKit puede reusar el CSS/imagen de antes de editarlos.
                                                      "Cache-Control": "no-store"])
            ?? URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: encoding)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func respondNotFound(_ task: WKURLSchemeTask, url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/plain", "Content-Length": "0", "Cache-Control": "no-store"])
            ?? URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil)
        task.didReceive(response)
        task.didFinish()
    }

    /// Los módulos ES (`<script type="module">`) se rechazan si el MIME no es de JavaScript, y
    /// UTType no conoce `.mjs`: esos van fijos, el resto por UTType.
    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "wasm": return "application/wasm"
        default:
            return UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

/// Motor de la vista previa HTML: un WKWebView propio (con JS), debounce y conservación del
/// scroll entre recargas. El modo de vista (editor/dividida/vista previa) NO vive acá: es
/// `Document.htmlPreviewMode`, por documento (ver TabsViewModel.activePreviewMode).
final class HTMLPreviewViewModel: NSObject, ObservableObject {
    /// Vive acá, no en el NSViewRepresentable (mismo motivo que MarkdownPreviewViewModel). Solo se
    /// reemplaza si la página se colgó (ver queryScrollY); @Published para que la vista lo readopte.
    @Published private(set) var webView: WKWebView
    private let configuration: WKWebViewConfiguration
    private let handler = HTMLPreviewSchemeHandler()
    private var pendingRefresh: DispatchWorkItem?
    private var lastRenderedDocumentID: UUID?
    /// Scroll a restaurar en el próximo didFinish de `index.html`; nil = no tocar (navegación
    /// dentro de la página, about:blank).
    private var pendingScrollRestore: Double?
    /// Hay una página del documento cargada (no about:blank).
    private var showingDocument = false
    /// Scroll que tenía la página al descargarla, para volver a la misma altura.
    private var parkedScrollY: Double = 0
    /// Invalida callbacks async de evaluateJavaScript que llegan después de otra recarga o descarga.
    private var generation = 0
    /// Último scroll conocido de la página del documento: respaldo si la página no responde.
    private var lastKnownScrollY: Double = 0
    /// Cada consulta de scroll lo incrementa; la respuesta o el timeout que llegue segundo no hace nada.
    private var scrollQueryToken = 0
    /// Timeouts seguidos de la consulta de scroll; una respuesta lo vuelve a 0.
    private var consecutiveScrollTimeouts = 0
    /// Recargas tras la muerte del proceso web en esta generación (ver webViewWebContentProcessDidTerminate).
    private var terminationReloads = 0
    private var terminationReloadsGeneration = -1

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: htmlPreviewScheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Sin esto un `window.open()` al cargar llegaría a createWebViewWith en cada recarga.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = .nonPersistent()
        configuration = config
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// `window.scrollY` con timeout de 300 ms. Un `while (i < 10) {` a medio tipear cuelga el
    /// proceso web: el callback no llega nunca y la vista previa no se recargaría más. Un timeout
    /// suelto puede ser solo una página lenta (un script pesado al cargar): se sigue con el último
    /// scroll conocido en la misma vista. Recién el segundo seguido descarta el WKWebView (eso
    /// termina su proceso), porque recrearlo pierde el proceso y su caché en cada pausa al tipear.
    private func queryScrollY(_ completion: @escaping (Double) -> Void) {
        scrollQueryToken += 1
        let token = scrollQueryToken
        let current = generation
        webView.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
            guard let self, token == self.scrollQueryToken else { return }
            self.scrollQueryToken += 1
            self.consecutiveScrollTimeouts = 0
            guard current == self.generation else { return }
            self.lastKnownScrollY = (result as? Double) ?? self.lastKnownScrollY
            completion(self.lastKnownScrollY)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, token == self.scrollQueryToken else { return }
            self.scrollQueryToken += 1
            self.consecutiveScrollTimeouts += 1
            if self.consecutiveScrollTimeouts >= 2 {
                self.consecutiveScrollTimeouts = 0
                self.replaceHungWebView()
            }
            guard current == self.generation else { return }
            completion(self.lastKnownScrollY)
        }
    }

    /// No hay API pública para matar el proceso de contenido: soltar el WKWebView lo termina. Con
    /// la misma configuración (esquema y almacén de datos) y readoptado por HTMLPreviewView.
    private func replaceHungWebView() {
        let hung = webView
        hung.navigationDelegate = nil
        hung.uiDelegate = nil
        hung.removeFromSuperview()
        let fresh = WKWebView(frame: hung.frame, configuration: configuration)
        fresh.navigationDelegate = self
        fresh.uiDelegate = self
        webView = fresh
        showingDocument = false
    }

    /// Debounce de 500 ms. `text` es autoclosure: se lee recién al vencer el debounce, así que
    /// tipear en un HTML de 2 MB no copia el documento entero en cada tecla.
    func scheduleRefresh(text: @escaping @autoclosure () -> String, baseDirectory: URL?, documentID: UUID) {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refreshNow(text: text(), baseDirectory: baseDirectory, documentID: documentID)
        }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func cancelPendingRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    func refreshNow(text: String, baseDirectory: URL?, documentID: UUID) {
        // Un refresh agendado leería el editor (uno solo) después de un cambio de pestaña.
        cancelPendingRefresh()
        generation += 1
        handler.html = text
        handler.baseDirectory = baseDirectory

        let sameDocument = lastRenderedDocumentID == documentID
        lastRenderedDocumentID = documentID
        guard sameDocument else {
            load(scrollY: 0)
            return
        }
        guard showingDocument else {
            load(scrollY: parkedScrollY)
            return
        }
        queryScrollY { [weak self] y in self?.load(scrollY: y) }
    }

    /// Oculta (modo editor, pestaña que no es HTML, sin pestañas): la página tiene JS y quedaría
    /// corriendo escondida (timers, audio, red). Se reemplaza por about:blank recordando el scroll.
    func unload() {
        cancelPendingRefresh()
        generation += 1
        guard showingDocument else { return }
        showingDocument = false
        pendingScrollRestore = nil
        queryScrollY { [weak self] y in
            guard let self else { return }
            self.parkedScrollY = y
            // Si venció el timeout el WKWebView ya es uno nuevo y vacío; esto no le hace daño.
            self.webView.loadHTMLString("", baseURL: nil)
        }
    }

    private func load(scrollY: Double) {
        showingDocument = true
        pendingScrollRestore = scrollY
        webView.load(URLRequest(url: htmlPreviewURL, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    private static let externalSchemes: Set<String> = ["http", "https", "mailto"]
    private static let maxTerminationReloads = 2
}

extension HTMLPreviewViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let y = pendingScrollRestore, webView.url == htmlPreviewURL else { return }
        pendingScrollRestore = nil
        lastKnownScrollY = y
        webView.evaluateJavaScript("window.scrollTo(0, \(y))")
    }

    /// Si WebKit termina el proceso (memoria, cuelgue detectado) la vista queda en blanco: recargar.
    /// Con tope por generación (cada refresh o cambio de documento la incrementa): una página que
    /// mata su proceso al cargar (memoria sin límite) entraría en un bucle matar → recargar.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView, showingDocument else { return }
        if terminationReloadsGeneration != generation {
            terminationReloadsGeneration = generation
            terminationReloads = 0
        }
        guard terminationReloads < Self.maxTerminationReloads else {
            showingDocument = false
            return
        }
        terminationReloads += 1
        load(scrollY: lastKnownScrollY)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if scheme == htmlPreviewScheme || url.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        // iframes embebidos (videos, mapas, srcdoc): como en un navegador. Solo el marco
        // principal queda atado al documento.
        if !isMainFrame, ["http", "https", "about", "data", "blob"].contains(scheme) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        // Solo clics: un `location.href = "https://…"` del script se repetiría en cada recarga
        // (cada pausa al tipear) abriendo el navegador una y otra vez.
        if navigationAction.navigationType == .linkActivated, Self.externalSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
        }
    }
}

extension HTMLPreviewViewModel: WKUIDelegate {
    /// `target="_blank"` y "Abrir enlace en ventana nueva": no hay ventanas nuevas; una página
    /// propia se abre en la misma vista y un enlace externo en el navegador, este último solo
    /// tras un clic: un `window.open("https://…")` del script se repetiría en cada recarga.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == htmlPreviewScheme {
            webView.load(navigationAction.request)
        } else if navigationAction.navigationType == .linkActivated, Self.externalSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

/// Mismo contenedor y adopción que MarkdownPreviewView (ver su comentario): el WKWebView vive en
/// el ViewModel y se reparenta explícitamente en cada aparición.
struct HTMLPreviewView: NSViewRepresentable {
    @ObservedObject var preview: HTMLPreviewViewModel
    /// Ver MarkdownPreviewView.isActive: las dos vistas previas están superpuestas.
    var isActive = true

    func makeNSView(context: Context) -> NSView {
        let container = SharedEditorContainer()
        adopt(preview.webView, into: container)
        container.isHidden = !isActive
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        adopt(preview.webView, into: container)
        container.isHidden = !isActive
    }

    private func adopt(_ webView: WKWebView, into container: NSView) {
        guard webView.superview !== container else { return }
        // Un WKWebView reemplazado (página colgada) no debe quedar debajo del nuevo.
        for old in container.subviews where old is WKWebView { old.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = container.bounds
        container.addSubview(webView)
        container.needsLayout = true
    }
}

extension TabsViewModel {
    /// Mismo criterio que el coloreado: lexer "hypertext" (html/htm/xhtml y php, este último
    /// mostrado como HTML estático). XML no.
    var activeDocumentIsHTML: Bool {
        activeDocument?.languageProfile.lexerName == "hypertext"
    }

    /// Documentos con vista previa (Markdown o HTML): comparten atajos y botón, no el modo.
    var activeDocumentHasPreview: Bool {
        activeDocumentIsMarkdown || activeDocumentIsHTML || activeDocumentIsTable
    }

    /// CSV/TSV por extensión o forzado con ⌃⌘T. Tiene prioridad sobre Markdown/HTML.
    var activeDocumentIsTable: Bool {
        guard let document = activeDocument else { return false }
        if document.forcedTable { return true }
        let ext = document.url?.pathExtension.lowercased() ?? ""
        return ext == "csv" || ext == "tsv" || ext == "tab"
    }

    /// HTML cuya vista previa es la página (no la tabla forzada).
    var activeDocumentShowsHTMLPreview: Bool { activeDocumentIsHTML && !activeDocumentIsTable }

    /// ⌃⌘T: en .csv/.tsv alterna editor/dividida; en otros archivos alterna `forcedTable`.
    func toggleTableView() {
        guard let document = activeDocument else { return }
        objectWillChange.send()
        let ext = document.url?.pathExtension.lowercased() ?? ""
        if ["csv", "tsv", "tab"].contains(ext) {
            document.tablePreviewMode = document.tablePreviewMode == .editor ? .split : .editor
        } else {
            document.forcedTable.toggle()
            document.tablePreviewMode = document.forcedTable ? .split : .editor
        }
    }

    /// Modo de vista efectivo del documento activo, el que leen y escriben el botón, ⌥⌘1/2/3 y el
    /// layout. HTML: `Document.htmlPreviewMode` (por documento, arranca en `.editor`: la vista
    /// previa corre el JS de la página y no debe hacerlo solo por abrir el archivo). Markdown: el
    /// modo global persistido. Sin vista previa: siempre `.editor`.
    var activePreviewMode: MarkdownPreviewViewModel.PreviewMode {
        get {
            guard let document = activeDocument else { return .editor }
            if activeDocumentIsTable { return document.tablePreviewMode }
            if activeDocumentIsHTML { return document.htmlPreviewMode }
            return activeDocumentIsMarkdown ? preview.mode : .editor
        }
        set {
            guard let document = activeDocument else { return }
            if activeDocumentIsTable {
                guard document.tablePreviewMode != newValue else { return }
                objectWillChange.send()
                document.tablePreviewMode = newValue
            } else if activeDocumentIsHTML {
                guard document.htmlPreviewMode != newValue else { return }
                // Document no es observable: sin esto ni ContentView ni el menú se enteran.
                objectWillChange.send()
                document.htmlPreviewMode = newValue
            } else if activeDocumentIsMarkdown {
                preview.mode = newValue
            }
        }
    }

    /// Archivo → Abrir en el navegador. El navegador lee el disco, no el editor: con cambios sin
    /// guardar se pregunta qué versión abrir.
    func openActiveInBrowser() {
        guard let document = activeDocument, activeDocumentIsHTML, let url = document.url else {
            NSSound.beep()
            return
        }
        syncDirtyFlagOfActiveDocument()
        if document.isDirty {
            let alert = NSAlert()
            alert.messageText = L("\(document.displayName) tiene cambios sin guardar.")
            alert.informativeText = L("El navegador abre el archivo tal como está en disco.")
            alert.addButton(withTitle: L("Guardar y abrir"))
            alert.addButton(withTitle: L("Abrir la versión guardada"))
            let cancelButton = alert.addButton(withTitle: L("Cancelar"))
            // NSAlert solo asigna Escape a un botón titulado "Cancel"; en español Esc caía en otro.
            cancelButton.keyEquivalent = "\u{1b}"
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard saveActive() else { return }
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }
        // Con el navegador por defecto explícito: `open(url)` usa la app por defecto para .html/.php,
        // que en una máquina de desarrollo suele ser un editor (o GNote++ mismo).
        guard let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else {
            if !NSWorkspace.shared.open(url) { NSSound.beep() }
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { DispatchQueue.main.async { NSSound.beep() } }
        }
    }
}
