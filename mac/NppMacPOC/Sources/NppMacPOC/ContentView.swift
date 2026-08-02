import SwiftUI

struct ContentView: View {
    @ObservedObject var tabs: TabsViewModel
    @ObservedObject var fileTree: FileTreeViewModel
    // Observado directamente (no solo vía `tabs`): FindViewModel es un
    // ObservableObject anidado dentro de TabsViewModel y su objectWillChange
    // no se reenvía al padre, así que ContentView debe suscribirse a él
    // explícitamente para reaccionar a cambios de isVisible/showReplace.
    @ObservedObject var find: FindViewModel
    // Igual que find: hay un solo MarkdownPreviewViewModel, anidado en TabsViewModel,
    // y su objectWillChange no se reenvía al padre — ContentView se suscribe directo.
    @ObservedObject var preview: MarkdownPreviewViewModel
    @Environment(\.colorScheme) private var colorScheme

    init(tabs: TabsViewModel, fileTree: FileTreeViewModel) {
        self.tabs = tabs
        self.fileTree = fileTree
        self.find = tabs.find
        self.preview = tabs.preview
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(fileTree: fileTree, onOpenFile: { tabs.open(url: $0) })
        } detail: {
            VStack(spacing: 0) {
                TabBarView(tabs: tabs)
                Divider()
                if tabs.activeDocument != nil {
                    editorArea
                    Divider()
                    StatusBarView(statusBar: tabs.statusBar)
                } else {
                    Text(L("Abre un archivo para empezar"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: colorScheme) { newValue in
            tabs.applyTheme(editorTheme(for: newValue))
            refreshPreview()
        }
        .onChange(of: tabs.activeIndex) { _ in
            refreshPreview()
        }
        .onChange(of: preview.isVisible) { visible in
            if visible {
                refreshPreview()
            } else {
                preview.cancelPendingRefresh()
            }
        }
        .onAppear {
            tabs.applyTheme(editorTheme(for: colorScheme))
            refreshPreview()
        }
    }

    @ViewBuilder
    private var editorArea: some View {
        let editorView = ScintillaEditorView(
            editor: tabs.editor,
            statusBar: tabs.statusBar,
            onContentChanged: { scheduleRefresh() }
        )
        .overlay(alignment: .top) {
            if find.isVisible {
                FindBarView(editor: tabs.editor, find: find)
            }
        }

        // HSplitView no soporta hijos que aparecen y desaparecen: una vez que el panel se
        // saca del split, no vuelve aunque la condición se cumpla de nuevo (bug de QA:
        // la preview se perdía al cambiar de pestaña y no reaparecía nunca). Por eso hay
        // dos estructuras distintas y el split se construye entero cada vez.
        // Alternar entre ramas hace que SwiftUI destruya y recree los NSViewRepresentable,
        // pero eso ya es seguro: tanto ScintillaEditorView como MarkdownPreviewView
        // devuelven un contenedor propio y adoptan su vista compartida al aparecer.
        if preview.isVisible, tabs.activeDocumentIsMarkdown {
            HSplitView {
                editorView.frame(minWidth: 240)
                MarkdownPreviewView(preview: preview).frame(minWidth: 240)
            }
        } else {
            editorView
        }
    }

    private func scheduleRefresh() {
        guard preview.isVisible, let document = tabs.activeDocument, tabs.activeDocumentIsMarkdown else { return }
        preview.scheduleRefresh(editor: tabs.editor, document: document, theme: markdownTheme(for: colorScheme))
    }

    private func refreshPreview() {
        guard preview.isVisible, let document = tabs.activeDocument, tabs.activeDocumentIsMarkdown else { return }
        preview.refreshNow(editor: tabs.editor, document: document, theme: markdownTheme(for: colorScheme))
    }
}

private func markdownTheme(for colorScheme: ColorScheme) -> MarkdownTheme {
    colorScheme == .dark ? .dark : .light
}
