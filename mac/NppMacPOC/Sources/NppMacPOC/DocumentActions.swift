import AppKit
import UniformTypeIdentifiers

/// Acciones de documento reutilizadas por menús y toolbar. Struct sin estado propio
/// (no ObservableObject): agrupa acciones sobre objetos que ya son observables, sin
/// sumar un nivel más a la trampa de objectWillChange no reenviado entre ObservableObject
/// anidados.
struct DocumentActions {
    let tabs: TabsViewModel
    let fileTree: FileTreeViewModel
    let recentFiles: RecentPathsViewModel
    let recentFolders: RecentPathsViewModel
    let preferences: EditorPreferences

    func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            tabs.open(url: url)
        }
    }

    /// HTML del documento activo: renderizado si es Markdown, coloreado si no.
    /// `rendered` distingue "Imprimir" (fuente coloreado) de "Imprimir vista previa"
    /// y de exportar un .md, que sí van renderizados.
    func documentHTML(rendered: Bool) -> (html: String, title: String)? {
        guard let document = tabs.activeDocument else { return nil }
        if rendered {
            let markdown = currentText(tabs.editor)
            // imageSource .file: el HTML resultante se abre desde disco, no por el
            // esquema del panel de vista previa.
            let html = renderMarkdownDocument(markdown, title: document.displayName, theme: .light, imageSource: .file)
            return (html, document.displayName)
        }
        let html = styledHTMLDocument(editor: tabs.editor, document: document, preferences: preferences)
        return (html, document.displayName)
    }

    func printDocument() {
        guard let doc = documentHTML(rendered: false) else { return }
        printHTML(doc.html, jobTitle: doc.title, bodyFontSize: printBodyFontSize(preferences: preferences))
    }

    func printMarkdownPreview() {
        guard let doc = documentHTML(rendered: true) else { return }
        let baseURL = tabs.activeDocument?.url?.deletingLastPathComponent()
        printMarkdownHTML(doc.html, baseURL: baseURL, jobTitle: doc.title)
    }

    func export(asPDF: Bool) {
        guard let document = tabs.activeDocument else { return }
        // Un .md se exporta renderizado; cualquier otro archivo, con su coloreado.
        guard let doc = documentHTML(rendered: tabs.activeDocumentIsMarkdown) else { return }

        let panel = NSSavePanel()
        let base = (document.displayName as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + (asPDF ? ".pdf" : ".html")
        // Sin esto, borrar la extension en el panel escribe un PDF llamado "notas".
        panel.allowedContentTypes = [asPDF ? .pdf : .html]
        if let current = document.url {
            panel.directoryURL = current.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if asPDF {
            if tabs.activeDocumentIsMarkdown {
                let baseURL = document.url?.deletingLastPathComponent()
                saveMarkdownPDF(html: doc.html, baseURL: baseURL, to: url) { success in
                    if !success {
                        presentPrintError(detail: L("No se pudo escribir el PDF en la ubicación elegida."))
                    }
                }
            } else if !savePDF(from: doc.html, to: url, jobTitle: doc.title, bodyFontSize: printBodyFontSize(preferences: preferences)) {
                presentPrintError(detail: L("No se pudo escribir el PDF en la ubicación elegida."))
            }
        } else {
            do {
                try doc.html.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                presentPrintError(detail: error.localizedDescription)
            }
        }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url: url)
        }
    }

    /// Extraído de `openFolder()` (Task 12, drag&drop): setea el árbol sin pasar por
    /// NSOpenPanel, para reusarlo tanto al soltar una carpeta desde Finder como en la
    /// restauración de sesión (Task 13).
    func openFolder(url: URL) {
        fileTree.openFolder(url)
        recentFolders.add(url)
    }

    // MARK: - Crear archivo/carpeta (Task 6, árbol de archivos)

    /// Crea un archivo vacío con nombre único (`sin título.txt`, `sin título 2.txt`, ...) en
    /// `dir`, refresca el árbol y arranca el rename inline sobre él. `fileTree.createdFileAwaitingOpen`
    /// es la señal que consume el Sidebar para abrir el archivo (con `tabs.open(url:)`) apenas
    /// ese rename termine, confirmado o cancelado — Finder también abre/conserva el archivo
    /// nuevo aunque se cancele el rename.
    func newFile(in dir: URL) {
        let url = uniqueURL(in: dir, baseName: L("sin título"), ext: "txt")
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            presentAlert(L("No se pudo crear el archivo."), detail: L("No se pudo escribir en \(dir.lastPathComponent)."))
            return
        }
        fileTree.refresh()
        fileTree.createdFileAwaitingOpen = url
        fileTree.pendingRenameURL = url
    }

    /// Crea una carpeta con nombre único (`nueva carpeta`, `nueva carpeta 2`, ...) en `dir`,
    /// refresca el árbol y arranca el rename inline sobre ella. A diferencia de `newFile`, una
    /// carpeta nunca se "abre", así que no toca `createdFileAwaitingOpen`.
    func newFolder(in dir: URL) {
        let url = uniqueURL(in: dir, baseName: L("nueva carpeta"), ext: nil)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            presentAlert(L("No se pudo crear la carpeta."), detail: error.localizedDescription)
            return
        }
        fileTree.refresh()
        fileTree.pendingRenameURL = url
    }

    /// Primer nombre libre en `dir` con base `baseName` (y extensión `ext` si corresponde):
    /// `baseName.ext`, luego `baseName 2.ext`, `baseName 3.ext`, etc.
    private func uniqueURL(in dir: URL, baseName: String, ext: String?) -> URL {
        func candidate(_ name: String) -> URL {
            if let ext { return dir.appendingPathComponent(name).appendingPathExtension(ext) }
            return dir.appendingPathComponent(name)
        }
        var url = candidate(baseName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = candidate("\(baseName) \(suffix)")
            suffix += 1
        }
        return url
    }
}

/// Alert modal genérico para errores de acciones de archivo (crear/etc). Mismo patrón que
/// `presentPrintError` en Printing.swift: una función global evita duplicar un helper privado
/// por cada tipo que necesita mostrar un NSAlert de error.
func presentAlert(_ message: String, detail: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = detail
    alert.addButton(withTitle: L("OK"))
    alert.runModal()
}
