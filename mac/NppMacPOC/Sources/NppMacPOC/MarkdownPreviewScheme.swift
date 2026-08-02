import Foundation
import WebKit

// `WKWebView.loadFileURL(_:allowingReadAccessTo:)` no sirve para la preview:
// `allowingReadAccessTo` da acceso a un directorio, pero el archivo cargado
// tiene que estar DENTRO de ese mismo directorio, y el HTML renderizado nunca
// lo está (no es un archivo real del proyecto, es texto generado en memoria).
// La alternativa de escribirlo a un temporal ensucia el disco y falla en
// carpetas de solo lectura. Por eso un esquema propio: el documento se carga
// desde `gnote-res://preview/index.html`, así que una imagen relativa
// `./foo.png` del Markdown resuelve sola a `gnote-res://preview/foo.png` y
// este handler la mapea a `<carpeta del .md>/foo.png`, sin tocar el HTML.

let markdownPreviewScheme = "gnote-res"
let markdownPreviewURL = URL(string: "\(markdownPreviewScheme)://preview/index.html")!

/// Maneja las cargas del esquema `gnote-res://` para la vista previa de
/// Markdown: sirve el HTML generado en memoria y, para cualquier otro path,
/// un archivo relativo a `baseDirectory` (la carpeta del documento).
final class MarkdownPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    /// HTML servido para `index.html`, actualizado por el ViewModel antes de
    /// cada recarga.
    var html: String = ""
    /// Carpeta del documento activo, contra la que se resuelven las rutas de
    /// imágenes relativas. `nil` si el documento no está guardado en disco.
    var baseDirectory: URL?

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, .badURL)
            return
        }

        if url.path == "/index.html" {
            let data = Data(html.utf8)
            let response = URLResponse(
                url: url,
                mimeType: "text/html",
                expectedContentLength: data.count,
                textEncodingName: "utf-8"
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            return
        }

        serveFile(for: url, task: urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // No hay trabajo async pendiente que cancelar: las cargas se resuelven
        // sincrónicamente en `start`.
    }

    private func serveFile(for url: URL, task: WKURLSchemeTask) {
        guard let baseDirectory else {
            // Documento sin guardar: no hay carpeta contra la cual resolver
            // rutas relativas.
            fail(task, .fileDoesNotExist)
            return
        }

        let relativePath = String(url.path.dropFirst()) // quita el "/" inicial
        let base = baseDirectory.standardizedFileURL
        let resolved = base.appendingPathComponent(relativePath).standardizedFileURL

        // Guard de path traversal: sin esto, un Markdown de terceros con
        // `![](../../../../etc/passwd)` haría que la app lea y muestre
        // archivos fuera de la carpeta del documento. `standardizedFileURL`
        // colapsa los `..` antes de comparar, así que la comparación de
        // prefijo es confiable.
        guard resolved.path == base.path || resolved.path.hasPrefix(base.path + "/") else {
            fail(task, .noPermissionsToReadFile)
            return
        }

        guard let data = try? Data(contentsOf: resolved) else {
            fail(task, .fileDoesNotExist)
            return
        }

        let response = URLResponse(
            url: url,
            mimeType: mimeType(for: resolved.pathExtension),
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, _ code: URLError.Code) {
        // Una task que ni termina ni falla deja a WebKit esperando para
        // siempre: todo camino de error tiene que pasar por acá.
        task.didFailWithError(URLError(code))
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        default: return "application/octet-stream"
        }
    }
}
