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
        printHTML(doc.html, jobTitle: doc.title)
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
            // Solo el camino coloreado (no-Markdown) fuerza el tamaño de impresión: el
            // renderizado de Markdown tiene su propia jerarquía tipográfica (títulos más
            // grandes que el cuerpo) y forzar un tamaño plano rompería esa jerarquía.
            let bodyFontSize = tabs.activeDocumentIsMarkdown ? nil : printBodyFontSize(preferences: preferences)
            if !savePDF(from: doc.html, to: url, jobTitle: doc.title, bodyFontSize: bodyFontSize) {
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
            fileTree.openFolder(url)
            recentFolders.add(url)
        }
    }
}
