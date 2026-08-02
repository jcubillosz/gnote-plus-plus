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
    @ObservedObject var recentFiles: RecentPathsViewModel
    @ObservedObject var recentFolders: RecentPathsViewModel
    let preferences: EditorPreferences
    @Environment(\.colorScheme) private var colorScheme
    // Colapsado al iniciar: sin carpeta abierta, el panel solo ocupa espacio vacío.
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    init(tabs: TabsViewModel, fileTree: FileTreeViewModel, recentFiles: RecentPathsViewModel, recentFolders: RecentPathsViewModel, preferences: EditorPreferences) {
        self.tabs = tabs
        self.fileTree = fileTree
        self.find = tabs.find
        self.preview = tabs.preview
        self.recentFiles = recentFiles
        self.recentFolders = recentFolders
        self.preferences = preferences
    }

    private var actions: DocumentActions {
        DocumentActions(tabs: tabs, fileTree: fileTree, recentFiles: recentFiles, recentFolders: recentFolders, preferences: preferences)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
        .toolbar {
            ToolbarItemGroup {
                Button { tabs.newDocument() } label: { Image(systemName: "doc.badge.plus") }
                    .help(L("Nuevo"))
                Button { actions.openFile() } label: { Image(systemName: "folder") }
                    .help(L("Abrir"))
                Button { tabs.saveActive() } label: { Image(systemName: "square.and.arrow.down") }
                    .help(L("Guardar"))
                    .disabled(tabs.activeIndex == nil)
                Button {
                    tabs.find.isVisible = true
                    tabs.find.showReplace = false
                } label: { Image(systemName: "magnifyingglass") }
                .help(L("Buscar"))
                .disabled(tabs.activeIndex == nil)
            }

            if tabs.activeDocumentIsMarkdown {
                ToolbarItemGroup {
                    Button {
                        preview.isVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help(L("Mostrar/ocultar vista previa"))
                    .foregroundStyle(preview.isVisible ? Color.accentColor : Color.primary)

                    Button {
                        preview.syncScroll.toggle()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.square")
                    }
                    .help(L("Sincronizar scroll"))
                    .foregroundStyle(preview.syncScroll ? Color.accentColor : Color.primary)

                    Menu {
                        Button(L("Título 1")) { insertMarkdownHeading(level: 1, editor: tabs.editor) }
                        Button(L("Título 2")) { insertMarkdownHeading(level: 2, editor: tabs.editor) }
                        Button(L("Título 3")) { insertMarkdownHeading(level: 3, editor: tabs.editor) }
                    } label: {
                        Image(systemName: "textformat.size")
                    }
                    .help(L("Insertar título"))

                    Button {
                        insertMarkdownTable(editor: tabs.editor)
                    } label: { Image(systemName: "tablecells") }
                    .help(L("Insertar tabla"))

                    Button {
                        insertMarkdownImage(editor: tabs.editor, document: tabs.activeDocument)
                    } label: { Image(systemName: "photo") }
                    .help(L("Insertar imagen"))

                    Button {
                        insertMarkdownCodeBlock(editor: tabs.editor)
                    } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                    .help(L("Insertar bloque de código"))
                }
            }
        }
        .onChange(of: fileTree.root == nil) { isNil in
            // Sin panel colapsado, "Abrir carpeta…" no da ninguna señal visible.
            if !isNil { columnVisibility = .all }
        }
        .onChange(of: colorScheme) { newValue in
            tabs.applyTheme(editorTheme(for: newValue))
            refreshPreview()
        }
        .onChange(of: tabs.activeIndex) { _ in
            preview.cancelPendingScrollSync()
            refreshPreview()
        }
        .onChange(of: preview.isVisible) { visible in
            if visible {
                refreshPreview()
            } else {
                preview.cancelPendingRefresh()
                preview.cancelPendingScrollSync()
            }
        }
        .onAppear {
            tabs.applyTheme(editorTheme(for: colorScheme))
            refreshPreview()
        }
    }

    @ViewBuilder
    private var editorArea: some View {
        // editorView NUNCA puede vivir dentro de una rama if/else: aunque sea el mismo
        // `let` en Swift, SwiftUI identifica las vistas por posición estructural, no por
        // referencia — envolverlo unas veces en HSplitView y otras veces solo produce DOS
        // identidades distintas, y alternar entre ellas hace que SwiftUI destruya el
        // ScintillaEditorView entero (no solo lo oculte). Ningún truco de invalidación
        // async lo arregla del lado de adopt(): el problema es que se destruye, no que
        // se pinta tarde. HSplitView se mantiene SIEMPRE presente con sus 2 hijos fijos
        // (no admite hijos condicionales en cantidad) y solo el CONTENIDO del segundo
        // panel alterna entre la preview real y un placeholder vacío de ancho 0.
        HSplitView {
            ScintillaEditorView(
                editor: tabs.editor,
                statusBar: tabs.statusBar,
                onContentChanged: { scheduleRefresh() },
                onScrolled: { preview.scheduleScrollSync(editor: tabs.editor) }
            )
            .overlay(alignment: .top) {
                if find.isVisible {
                    FindBarView(editor: tabs.editor, find: find)
                }
            }
            .frame(minWidth: 240)

            if preview.isVisible, tabs.activeDocumentIsMarkdown {
                MarkdownPreviewView(preview: preview).frame(minWidth: 240)
            } else {
                Color.clear.frame(width: 0)
            }
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
