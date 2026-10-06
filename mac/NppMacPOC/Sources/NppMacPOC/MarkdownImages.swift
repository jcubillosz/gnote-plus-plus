import AppKit
import UniformTypeIdentifiers
import Scintilla

// Pegar y arrastrar imágenes en documentos Markdown (como VSCode): la imagen se referencia
// con una ruta relativa al .md. Una imagen pegada sin archivo (captura de pantalla) se
// guarda como PNG en "images/" junto al documento.

let SCI_POSITIONFROMPOINT: UInt32 = 2022

enum MarkdownImages {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic"]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    private static var pasteMonitor: Any?

    /// ⌘V con una imagen en el portapapeles. Monitor de teclado y no un override de paste:
    /// el paste: es del SCIContentView de Scintilla (ObjC) y el ítem Pegar del menú queda
    /// deshabilitado cuando el portapapeles no tiene texto, así que nunca llegaría.
    static func installPasteMonitor(tabs: TabsViewModel) {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak tabs] event in
            guard let tabs,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  let responder = event.window?.firstResponder as? NSView,
                  responder.isDescendant(of: tabs.editor),
                  let document = tabs.activeDocument,
                  document.languageProfile.lexerName == "markdown", !document.isLocked,
                  pasteImage(editor: tabs.editor, document: document) else { return event }
            return nil
        }
    }

    /// Devuelve false si el portapapeles no trae imagen (y el pegado sigue normal).
    private static func pasteImage(editor: ScintillaView, document: Document) -> Bool {
        let pasteboard = NSPasteboard.general
        // Archivos de imagen copiados en Finder: se enlazan, no se copian.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, urls.allSatisfy(isImage) {
            if let local = localCopies(of: urls, for: document) {
                insertLinks(to: local, editor: editor, document: document, at: nil)
            }
            return true
        }
        // Con texto en el portapapeles gana el texto (copiar desde un navegador trae ambos).
        guard pasteboard.string(forType: .string) == nil,
              let image = NSImage(pasteboard: pasteboard) else { return false }
        guard let documentURL = document.url else {
            alert(L("Guarda el documento antes de pegar una imagen."),
                  detail: L("La imagen se guarda en una carpeta \"images\" junto al archivo Markdown."))
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        let folder = documentURL.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var target = folder.appendingPathComponent("imagen-\(formatter.string(from: Date())).png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("imagen-\(formatter.string(from: Date()))-\(suffix).png")
            suffix += 1
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: target, options: .atomic)
        } catch {
            alert(L("No se pudo guardar la imagen pegada."), detail: error.localizedDescription)
            return true
        }
        insertLinks(to: [target], editor: editor, document: document, at: nil)
        return true
    }

    /// Archivos de imagen soltados sobre el editor: enlace en el punto donde se soltaron.
    static func dropImages(_ urls: [URL], editor: ScintillaView, document: Document) {
        let position = dropPosition(editor)
        guard let local = localCopies(of: urls, for: document) else { return }
        insertLinks(to: local, editor: editor, document: document, at: position)
    }

    /// Imágenes listas para enlazar desde el documento: las que ya están dentro de su
    /// carpeta se usan tal cual; las de afuera se copian a "images/". La preview solo sirve
    /// archivos dentro de la carpeta del .md (MarkdownPreviewSchemeHandler, para que un
    /// "![](../../etc/passwd)" no lea el disco), así que un link "../Downloads/x.png" no se
    /// veía. nil si el documento no está guardado (no hay carpeta) o falló la copia.
    static func localCopies(of urls: [URL], for document: Document) -> [URL]? {
        guard let documentURL = document.url else {
            alert(L("Guarda el documento antes de insertar una imagen."),
                  detail: L("Las imágenes de fuera de la carpeta del documento se copian a una carpeta \"images\" junto al archivo Markdown."))
            return nil
        }
        let base = documentURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let folder = base.appendingPathComponent("images", isDirectory: true)
        var result: [URL] = []
        for url in urls {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            if resolved.path.hasPrefix(base.path + "/") {
                result.append(url)
                continue
            }
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var target = folder.appendingPathComponent(url.lastPathComponent)
            var suffix = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(name)-\(suffix)").appendingPathExtension(ext)
                suffix += 1
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: target)
            } catch {
                alert(L("No se pudo copiar la imagen."), detail: error.localizedDescription)
                return nil
            }
            result.append(target)
        }
        return result
    }

    /// Botón "Insertar imagen" de la toolbar.
    static func chooseAndInsert(editor: ScintillaView, document: Document?) {
        guard let document else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, !panel.urls.isEmpty,
              let local = localCopies(of: panel.urls, for: document) else { return }
        insertLinks(to: local, editor: editor, document: document, at: nil)
    }

    private static func insertLinks(to urls: [URL], editor: ScintillaView, document: Document, at position: Int?) {
        // Con symlinks resueltos en ambos lados: si no, /tmp contra /private/tmp no
        // comparte prefijo y el link salía absoluto.
        let base = document.url?.deletingLastPathComponent().resolvingSymlinksInPath()
        let links = urls.map { url -> String in
            let path = base.flatMap { url.resolvingSymlinksInPath().relativePath(from: $0) } ?? url.path
            // Espacios y paréntesis rompen el destino de un link de Markdown: <...> los admite.
            let destination = path.contains(where: { " ()".contains($0) }) ? "<\(path)>" : path
            return "![\(url.deletingPathExtension().lastPathComponent)](\(destination))"
        }.joined(separator: "\n")
        if let position {
            _ = ScintillaView.directCall(editor, message: SCI_SETSEL, wParam: uptr_t(position), lParam: sptr_t(position))
        }
        links.withCString { cstr in
            _ = ScintillaView.directCall(editor, message: SCI_REPLACESEL, wParam: 0, lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
        }
        editor.window?.makeFirstResponder(editor.content())
    }

    /// Posición del documento bajo el mouse (mismas coordenadas que el menú del corrector,
    /// ver spellContextMenu en ScintillaEditorView.swift).
    private static func dropPosition(_ editor: ScintillaView) -> Int? {
        guard let content = editor.content(), let window = content.window else { return nil }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard content.visibleRect.contains(point) else { return nil }
        let origin = content.enclosingScrollView?.contentView.bounds.origin ?? .zero
        var margins = Int(ScintillaView.directCall(editor, message: SCI_GETMARGINLEFT, wParam: 0, lParam: 0))
        for margin in 0..<Int(ScintillaView.directCall(editor, message: SCI_GETMARGINS, wParam: 0, lParam: 0)) {
            margins += Int(ScintillaView.directCall(editor, message: SCI_GETMARGINWIDTHN, wParam: uptr_t(margin), lParam: 0))
        }
        let x = max(0, Int(point.x - origin.x) + margins)
        let y = max(0, Int(point.y - origin.y))
        let position = Int(ScintillaView.directCall(editor, message: SCI_POSITIONFROMPOINT, wParam: uptr_t(x), lParam: sptr_t(y)))
        return position >= 0 ? position : nil
    }

    static func alert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

extension URL {
    /// Ruta relativa de este archivo respecto de la carpeta `base`, o nil si no comparten
    /// prefijo.
    func relativePath(from base: URL) -> String? {
        let baseComponents = base.standardizedFileURL.pathComponents
        let selfComponents = standardizedFileURL.pathComponents
        var common = 0
        while common < baseComponents.count, common < selfComponents.count, baseComponents[common] == selfComponents[common] {
            common += 1
        }
        guard common > 1 else { return nil }
        let ups = Array(repeating: "..", count: baseComponents.count - common)
        return (ups + selfComponents[common...]).joined(separator: "/")
    }
}
