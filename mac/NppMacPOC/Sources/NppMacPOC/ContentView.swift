import SwiftUI
import Scintilla

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
    @ObservedObject var htmlPreview: HTMLPreviewViewModel
    @ObservedObject var csvTable: CSVTableViewModel
    // Mismo motivo: SpellCheckViewModel es otro ObservableObject anidado — sin esto,
    // togglear "Revisar ortografía"/idioma desde el menú no dispararía onChange acá.
    @ObservedObject var spellCheck: SpellCheckViewModel
    // Mismo motivo: OutlineViewModel es otro ObservableObject anidado en TabsViewModel.
    @ObservedObject var outline: OutlineViewModel
    @ObservedObject var recentFiles: RecentPathsViewModel
    @ObservedObject var recentFolders: RecentPathsViewModel
    // Observado: el toggle de la minimapa cambia el layout del editor.
    @ObservedObject var preferences: EditorPreferences
    @Environment(\.colorScheme) private var colorScheme
    // Colapsado al iniciar: sin carpeta abierta, el panel solo ocupa espacio vacío.
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    // @State y no @StateObject: ContentView no debe redibujarse con cada movimiento del caret.
    @State private var breadcrumbCaret = BreadcrumbCaret()
    // Se incrementa al clickear "Apoyar el proyecto" desde la toolbar para
    // forzar que SwiftUI relea DonationPrompt.shouldShowInToolbar y oculte
    // el botón sin esperar otro evento de estado.
    @State private var donationPromptRefreshToken = 0
    // Escala del ícono de candado: 1.0 en reposo. pulseLock() la sube y la anima de vuelta a
    // 1.0; reiniciar el mismo valor en cada intento (en vez de un booleano que se togglea)
    // hace que escribir repetido sobre un documento bloqueado reinicie la animación en
    // curso — un pulso continuo, no alertas — sin acumular work items.
    @State private var lockPulseScale: CGFloat = 1.0
    // Debounce de 500ms para la revisión ortográfica (task-10-brief.md): se agenda un
    // DispatchWorkItem por disparador y se cancela el anterior, mismo patrón que
    // MarkdownPreview.scheduleRefresh/scheduleScrollSync.
    @State private var pendingSpellCheck: DispatchWorkItem?
    @State private var pendingSmartHighlight: DispatchWorkItem?
    @State private var pendingCSSColors: DispatchWorkItem?
    @State private var pendingGitGutter: DispatchWorkItem?
    /// Task 12: borde de acento mientras se arrastra algo de Finder sobre la ventana.
    @State private var isDropTargeted = false
    /// Último previewModeKey visto (macOS 13: onChange no da el valor anterior).
    @State private var lastPreviewModeKey: PreviewModeKey?

    init(tabs: TabsViewModel, fileTree: FileTreeViewModel, recentFiles: RecentPathsViewModel, recentFolders: RecentPathsViewModel, preferences: EditorPreferences) {
        self.tabs = tabs
        self.fileTree = fileTree
        self.find = tabs.find
        self.preview = tabs.preview
        self.htmlPreview = tabs.htmlPreview
        self.csvTable = tabs.csvTable
        self.spellCheck = tabs.spellCheck
        self.outline = tabs.outline
        self.recentFiles = recentFiles
        self.recentFolders = recentFolders
        self.preferences = preferences
    }

    /// "GNote++ — archivo.md", con • si tiene cambios sin guardar. Aprovecha el espacio del
    /// título de la ventana, que solo mostraba el nombre de la app.
    private var windowTitle: String {
        guard let document = tabs.activeDocument else { return "GNote++" }
        return "GNote++ — \(document.displayName)\(document.isDirty ? " •" : "")"
    }

    private var actions: DocumentActions {
        DocumentActions(tabs: tabs, fileTree: fileTree, recentFiles: recentFiles, recentFolders: recentFolders, preferences: preferences)
    }

    private struct ActiveDocumentKey: Equatable {
        let id: UUID?
        let lexerName: String?
        let languageName: String?
    }

    /// El índice no sirve de disparador: al cerrar la pestaña activa el vecino cae en el mismo
    /// índice y el onChange no se enteraba del documento nuevo.
    private var activeDocumentKey: ActiveDocumentKey {
        let doc = tabs.activeDocument
        return ActiveDocumentKey(id: doc?.id, lexerName: doc?.languageProfile.lexerName, languageName: doc?.languageProfile.languageName)
    }

    /// Lo que cambia el encabezado fijo además del scroll: esquema, tema, fuente y modo de vista.
    private struct StickyHeaderKey: Equatable {
        let enabled: Bool
        let mode: MarkdownPreviewViewModel.PreviewMode
        let items: [OutlineItem]
        let documentID: UUID?
        let itemsDocument: sptr_t?
        let fontName: String
        let fontSize: Double
        let dark: Bool
    }

    private var stickyHeaderKey: StickyHeaderKey {
        StickyHeaderKey(enabled: preferences.stickyScroll, mode: tabs.activePreviewMode, items: outline.items,
                        documentID: tabs.activeDocument?.id, itemsDocument: outline.itemsDocument,
                        fontName: preferences.fontName, fontSize: preferences.fontSize, dark: colorScheme == .dark)
    }

    private func refreshStickyHeader() {
        // Tras el ciclo actual: el tema/fuente se aplican al editor en otros onChange del mismo pase.
        DispatchQueue.main.async {
            // Al cambiar de pestaña el esquema todavía es del documento anterior: sus líneas leídas
            // en el documento nuevo darían texto ajeno, así que se oculta hasta que llegue el nuevo.
            guard preferences.stickyScroll, tabs.activePreviewMode != .preview, let document = tabs.activeDocument,
                  !outline.items.isEmpty, outline.itemsDocument == document.pointer else {
                StickyHeaderView.shared.hide()
                return
            }
            StickyHeaderView.shared.update(editor: tabs.editor, items: outline.items,
                                           theme: tabs.currentTheme, fontName: preferences.fontName)
        }
    }

    private struct PreviewModeKey: Equatable {
        let document: ActiveDocumentKey
        let mode: MarkdownPreviewViewModel.PreviewMode
    }

    /// El modo efectivo cambia también al cambiar de pestaña (cada HTML tiene el suyo); con el
    /// documento en la clave, onChange(of: previewModeKey) distingue eso de un cambio de modo.
    private var previewModeKey: PreviewModeKey {
        PreviewModeKey(document: activeDocumentKey, mode: tabs.activePreviewMode)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(fileTree: fileTree, actions: actions, onOpenFile: { tabs.open(url: $0) }, onRename: { url, newName in
                // fileTree.refresh() ya lo dispara el Sidebar después de este callback; acá
                // solo se hace el move + rebase de pestañas y se propaga el resultado para
                // que Task 6 pueda abrir el archivo recién creado tras su rename inicial.
                tabs.renameItem(at: url, to: newName)
            }, onMove: { tabs.moveItem(at: $0, toFolder: $1) },
            onCopy: { tabs.copyItem(at: $0, toFolder: $1) },
            outline: outline, statusBar: tabs.statusBar, onJumpToLine: { jumpToOutlineLine($0) },
            findInFiles: tabs.findInFiles,
            findOverrides: { unsavedActiveText() },
            onOpenMatch: { url, line, byteStart, byteLength in openFindMatch(url: url, line: line, byteStart: byteStart, byteLength: byteLength) },
            onOpenDocumentMatch: { id, line, byteStart, byteLength in openDocumentMatch(id: id, line: line, byteStart: byteStart, byteLength: byteLength) },
            onReplaceInFiles: { tabs.confirmAndReplaceInFiles(rerun: { tabs.findInFiles.search(in: $0, overrides: unsavedActiveText()) }) })
        } detail: {
            VStack(spacing: 0) {
                // Prioridad de layout: el editor es flexible y nunca debe comprimir la barra
                // de pestañas (alto fijo) cuando el VStack recalcula alturas.
                if tabs.activeDocumentIsMarkdown {
                    MarkdownFormatBar(tabs: tabs, preferences: preferences)
                        .layoutPriority(1)
                    Divider()
                }
                TabBarView(tabs: tabs)
                    .layoutPriority(1)
                Divider()
                if preferences.showBreadcrumbs, let document = tabs.activeDocument {
                    BreadcrumbBar(outline: outline, caret: breadcrumbCaret, file: document.url,
                                  fileName: document.displayName, root: fileTree.root?.url,
                                  onRevealFolder: { folder in
                                      columnVisibility = .all
                                      fileTree.revealRequest = folder
                                  },
                                  onJumpToLine: { jumpToOutlineLine($0) })
                        .layoutPriority(1)
                        .onAppear { breadcrumbCaret.updateNow(editor: tabs.editor) }
                        .onChange(of: document.id) { _ in breadcrumbCaret.updateNow(editor: tabs.editor) }
                    Divider()
                }
                ZStack {
                    if tabs.activeDocument != nil {
                        editorArea
                    } else {
                        Text(L("Abre un archivo para empezar"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                // Paneles flotantes sobre el contenedor de AMBAS ramas: dentro de editorArea no
                // existían sin pestañas (carpeta abierta, ninguna pestaña) y ⌘T/⇧⌘P quedaban
                // "visibles" sin dibujarse ni poder cerrarse con Esc. Sobre el área entera y no sobre
                // el editor: en solo-vista-previa el editor mide 0 pt y en dividida angosta se
                // recortaban. Encima de la barra de búsqueda, que es overlay del editor.
                .overlay(alignment: .top) {
                    ClipboardHistoryPickerHost(
                        history: tabs.clipboardHistory,
                        onShown: { tabs.quickPanel.close(restoreFocus: false) },
                        onPaste: { text in
                            tabs.clipboardHistory.pickerVisible = false
                            if let document = tabs.activeDocument, !document.isLocked {
                                pasteFromHistory(text, editor: tabs.editor)
                            }
                            applyFocusForCurrentMode()
                        },
                        onClose: { restoreFocus in
                            tabs.clipboardHistory.pickerVisible = false
                            if restoreFocus { applyFocusForCurrentMode() }
                        })
                }
                .overlay(alignment: .top) {
                    QuickPanelHost(model: tabs.quickPanel, onShown: { tabs.clipboardHistory.pickerVisible = false },
                                   onClose: { applyFocusForCurrentMode() })
                }
                if tabs.activeDocument != nil {
                    Divider()
                    StatusBarView(statusBar: tabs.statusBar, macros: tabs.macros)
                }
            }
            // Cubre tab bar / status bar / el "abre un archivo" vacío. Sobre el área del
            // editor esto NO se dispara: ScintillaView ya se registra para
            // NSPasteboardTypeFileURL y AppKit le entrega el drop a él (el hit-test más
            // profundo bajo el cursor), antes de que este .onDrop lo vea — por eso ese caso
            // se atiende vía SCN_URIDROPPED (ver onURIDropped arriba y ScintillaEditorView).
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDroppedProviders(providers)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
        }
        .navigationTitle(windowTitle)
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
                Button {
                    tabs.toggleLockActive()
                } label: {
                    Image(systemName: tabs.activeDocument?.isLocked == true ? "lock.fill" : "lock.open")
                        .scaleEffect(lockPulseScale)
                }
                .help(tabs.activeDocument?.isLocked == true ? L("Desbloquear edición") : L("Bloquear edición"))
                .disabled(tabs.activeIndex == nil)
            }

            // donationPromptRefreshToken no se lee acá, pero SwiftUI no
            // recorta el toolbar de forma reactiva ante un simple UserDefaults
            // — leerlo fuerza que este bloque se reevalúe tras markClicked().
            if donationPromptRefreshToken >= 0, DonationPrompt.shouldShowInToolbar {
                ToolbarItemGroup {
                    Button {
                        NSWorkspace.shared.open(donationURL)
                        DonationPrompt.markClicked()
                        donationPromptRefreshToken += 1
                    } label: {
                        Text("☕")
                    }
                    .help(L("Apoyar el proyecto"))
                    .accessibilityLabel(L("Apoyar el proyecto"))
                }
            }

            if tabs.activeDocumentHasPreview {
                ToolbarItemGroup {
                    Picker(L("Modo de vista"), selection: $tabs.activePreviewMode) {
                        Image(systemName: "doc.plaintext").tag(MarkdownPreviewViewModel.PreviewMode.editor)
                        Image(systemName: "rectangle.split.2x1").tag(MarkdownPreviewViewModel.PreviewMode.split)
                        Image(systemName: "doc.richtext").tag(MarkdownPreviewViewModel.PreviewMode.preview)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help(L("Modo de vista"))
                    .frame(width: 120)

                    // El scroll sincronizado es proporcional por líneas de Markdown; en HTML no aplica.
                    if tabs.activeDocumentIsMarkdown {
                        Button {
                            preview.syncScroll.toggle()
                        } label: {
                            Image(systemName: "arrow.up.arrow.down.square")
                        }
                        .help(L("Sincronizar scroll"))
                        .foregroundStyle(preview.syncScroll ? Color.accentColor : Color.primary)
                    }
                }
            }
        }
        .onChange(of: fileTree.root == nil) { isNil in
            // Sin panel colapsado, "Abrir carpeta…" no da ninguna señal visible.
            if !isNil { columnVisibility = .all }
        }
        .onChange(of: preferences.showDocumentMap) { _ in
            DocumentMapView.applyMargin(to: tabs.editor, visible: preferences.showDocumentMap)
            refreshStickyHeader()
        }
        .onChange(of: stickyHeaderKey) { _ in refreshStickyHeader() }
        .onChange(of: colorScheme) { newValue in
            tabs.applyTheme(editorTheme(for: newValue))
            refreshPreview()
        }
        .onChange(of: activeDocumentKey) { _ in
            preview.cancelPendingScrollSync()
            refreshPreview()
            applyFocusForCurrentMode()
            // Cambio de pestaña: el indicador vive en el ScintillaView compartido, así que
            // los squiggles de la pestaña anterior seguirían pintados sobre el documento
            // nuevo hasta la próxima revisión si no se limpian y recalculan ahora mismo.
            scheduleSpellCheck()
            outline.refreshNow(editor: tabs.editor, profile: tabs.activeDocument?.languageProfile)
            scheduleSmartHighlight()
            scheduleCSSColors()
            RegexTesterPanel.shared.model.documentChanged()
            // Al activar se vuelve a pedir el blob: HEAD pudo cambiar mientras estaba en el fondo.
            if let document = tabs.activeDocument {
                tabs.gitGutter.invalidate(document)
                tabs.gitBlame.invalidate(document)
            }
            refreshGitGutterNow()
            tabs.gitBlame.caretMoved(document: tabs.activeDocument, editor: tabs.editor)
        }
        .onChange(of: windowTitle) { _ in
            updateRepresentedURL()
        }
        .onChange(of: outline.showRequestToken) { _ in
            columnVisibility = .all
        }
        .onChange(of: spellCheck.enabled) { enabled in
            if enabled {
                scheduleSpellCheck()
            } else {
                pendingSpellCheck?.cancel()
                SpellChecker.clearAll(editor: tabs.editor)
            }
        }
        .onChange(of: spellCheck.language) { _ in
            guard spellCheck.enabled else { return }
            scheduleSpellCheck()
        }
        .onChange(of: previewModeKey) { key in
            let previous = lastPreviewModeKey
            lastPreviewModeKey = key
            // Cambio de pestaña o de lenguaje: lo atiende onChange(of: activeDocumentKey); repetirlo
            // acá recargaría la página HTML (y su JS) dos veces.
            guard previous?.document == key.document else { return }
            if key.mode == .editor {
                preview.cancelPendingRefresh()
                preview.cancelPendingScrollSync()
                htmlPreview.unload()
            } else {
                refreshPreview()
            }
            applyFocusForCurrentMode()
        }
        .sheet(isPresented: $tabs.showColumnEditor) {
            ColumnEditorSheet(editor: tabs.editor) { tabs.showColumnEditor = false }
        }
        .onAppear {
            tabs.applyTheme(editorTheme(for: colorScheme))
            preview.onJumpToSourceLine = { line in jumpToSourceLine(line) }
            MarkdownImages.installPasteMonitor(tabs: tabs)
            TabKeyRouter.install(tabs: tabs)
            preview.onToggleTask = { line in
                guard tabs.activeDocument?.isLocked == false,
                      MarkdownEditing.toggleTask(editor: tabs.editor, line: line - 1) else {
                    NSSound.beep()
                    return
                }
            }
            lastPreviewModeKey = previewModeKey
            refreshPreview()
            applyFocusForCurrentMode()
            scheduleSpellCheck()
            scheduleCSSColors()
            refreshGitGutterNow()
            outline.refreshNow(editor: tabs.editor, profile: tabs.activeDocument?.languageProfile)
            deferPastCurrentLayoutPass { updateRepresentedURL() }
        }
    }

    /// Ícono proxy del archivo activo en la barra de título (cmd+click muestra la ruta, se
    /// puede arrastrar). Vía NSWindow y no .navigationDocument: ese modificador reemplaza el
    /// título por el nombre del archivo y se perdería el "GNote++ — " de windowTitle.
    private func updateRepresentedURL() {
        tabs.editor.window?.representedURL = tabs.activeDocument?.url
    }

    /// Único punto que decide el first responder según el modo EFECTIVO (mode +
    /// si el doc activo tiene vista previa: Markdown o HTML; sin documento, la ventana). Se llama desde cada disparador relevante —
    /// cambio de modo, cambio de pestaña y arranque — en vez de solo en el borde
    /// "entrando a .preview": ese borde se pierde en (1) arranque con .preview
    /// restaurado de UserDefaults (el editor puede robar el foco al crearse, antes
    /// de que este código corra), (2) cambiar de una pestaña MD a otra con el modo
    /// ya en .preview (onChange(of: previewModeKey) ignora los cambios de pestaña),
    /// (3) cambiar de una pestaña no-MD (modo efectivo .editor) a una MD con
    /// preview.mode ya en .preview (mismo motivo).
    /// Se difiere al próximo runloop porque en (1)/(2)/(3) ScintillaEditorView
    /// puede reclamar el foco de forma asíncrona al reparentar/crearse (ver su
    /// propio `DispatchQueue.main.async` en adopt(into:)) — sin este defer, esa
    /// llamada posterior le gana a esta y el foco vuelve al editor oculto.
    private func applyFocusForCurrentMode() {
        let hasDocument = tabs.activeDocument != nil
        let isHTML = tabs.activeDocumentShowsHTMLPreview
        let isTable = tabs.activeDocumentIsTable
        let effectiveMode = tabs.activePreviewMode
        // deferPastCurrentLayoutPass, no DispatchQueue.main.async: cambiar de modo cambia el
        // frame/opacity del editor (mostrarlo u ocultarlo), lo que dispara un paso de
        // auto-layout de AppKit. makeFirstResponder programado con .async podía ejecutarse
        // todavía dentro de ese mismo paso y AppKit lo rechazaba con una NSException
        // ("no se puede pedir actualizar constraints mientras ya se está actualizando"),
        // crasheando la app al cambiar el modo de vista previa (bug real de QA manual).
        deferPastCurrentLayoutPass {
            if !hasDocument {
                // Sin pestañas el editor no está en la ventana: el foco vuelve a la ventana (los
                // atajos de menú siguen andando) en vez de quedar en el panel flotante ya cerrado.
                // mainWindow primero: con un panel flotante (colores, Buscar) al frente, keyWindow
                // es ese panel y no la ventana del editor.
                (NSApp.mainWindow ?? NSApp.keyWindow)?.makeFirstResponder(nil)
            } else if effectiveMode == .preview {
                let target: NSView = isTable ? csvTable.tableView : (isHTML ? htmlPreview.webView : preview.webView)
                target.window?.makeFirstResponder(target)
            } else {
                tabs.editor.window?.makeFirstResponder(tabs.editor)
            }
        }
    }

    @ViewBuilder
    private var editorArea: some View {
        // El editor y la preview NUNCA pueden vivir dentro de una rama if/else: SwiftUI
        // identifica las vistas por posición estructural, no por referencia — alternar
        // ramas destruye el NSViewRepresentable entero (no solo lo oculta) y obliga a
        // reparentar el ScintillaView/WKWebView compartidos. EditorPreviewSplit mantiene
        // ambos hijos siempre presentes y solo cambia sus anchos según el modo.
        // Un documento sin vista previa (ni Markdown ni HTML) se comporta siempre como .editor,
        // aunque `preview.mode` (persistido, de Markdown) esté en .split/.preview.
        let effectiveMode = tabs.activePreviewMode

        EditorPreviewSplit(mode: effectiveMode) {
            HStack(spacing: 0) {
                ScintillaEditorView(
                    editor: tabs.editor,
                    statusBar: tabs.statusBar,
                    document: tabs.activeDocument,
                    spellCheck: spellCheck,
                    onContentChanged: {
                        tabs.activeDocument?.backupPending = true
                        tabs.documentMap.refresh()
                        scheduleRefresh()
                        scheduleSpellCheck()
                        outline.scheduleRefresh(editor: tabs.editor, profile: tabs.activeDocument?.languageProfile)
                        CSSColorPicker.shared.editorContentChanged()
                        scheduleCSSColors()
                        scheduleGitGutter()
                        RegexTesterPanel.shared.model.documentChanged()
                    },
                    onScrolled: {
                        tabs.documentMap.refresh()
                        if preferences.stickyScroll { StickyHeaderView.shared.schedule { refreshStickyHeader() } }
                        // Solo Markdown: con un HTML activo movería la preview Markdown oculta.
                        if tabs.activeDocumentIsMarkdown { preview.scheduleScrollSync(editor: tabs.editor) }
                        scheduleSpellCheck()
                        scheduleCSSColors()
                    },
                    onSavePointLeft: { tabs.setActiveDirty(true) },
                    onSavePointReached: { tabs.setActiveDirty(false) },
                    onModifyAttemptReadOnly: { pulseLock() },
                    onSpellCheckAction: { recheckSpellingNow() },
                    onURIDropped: { handleDroppedURLs([$0]) },
                    onSelectionChanged: {
                        SnippetSession.current?.reconcile()
                        BraceMatcher.updateBraces(editor: tabs.editor)
                        scheduleSmartHighlight()
                        CSSColorPicker.shared.editorSelectionChanged()
                        if preferences.showBreadcrumbs { breadcrumbCaret.schedule(editor: tabs.editor) }
                        tabs.gitBlame.caretMoved(document: tabs.activeDocument, editor: tabs.editor)
                    },
                    onCharAdded: { character in
                        // Lo que estas funciones insertan no se graba en la macro: al reproducir se
                        // re-dispara este mismo manejador tras cada carácter tecleado (Macros.swift).
                        tabs.macros.noteCharAdded(character)
                        tabs.macros.suppressing { tabs.handleCharAdded(character) }
                        SnippetSession.current?.reconcile()
                    },
                    onMacroRecord: { tabs.macros.record(message: $0, wParam: $1, lParam: $2) }
                )
                .overlay(alignment: .trailing) {
                    // Franja acotada al borde derecho (minimapa + scroller legacy, ≤ 24 pt):
                    // el resto del editor no queda debajo de ninguna vista, así los clics y el
                    // cursor no dependen del hitTest del contenedor.
                    if preferences.showDocumentMap && tabs.activeIndex != nil {
                        DocumentMapRepresentable(map: tabs.documentMap)
                            .frame(width: DocumentMapView.width + 24)
                    }
                }
                .overlay(alignment: .top) {
                    // Después del minimapa para quedar encima, y corrida a su izquierda: la barra
                    // se alinea a la derecha y sus botones caían debajo de la franja del minimapa.
                    if find.isVisible {
                        FindBarView(editor: tabs.editor, find: find, isLocked: tabs.activeDocument?.isLocked == true,
                                    onFindAll: { findAll(allDocuments: $0) })
                            .padding(.trailing, preferences.showDocumentMap && tabs.activeIndex != nil ? DocumentMapView.width + 24 : 0)
                    }
                }
            }
        } preview: {
            // Las dos vistas siempre presentes (misma razón que EditorPreviewSplit): alternar con
            // if/else entre una pestaña .md y una .html destruiría y reparentaría los WKWebView.
            // La inactiva se oculta con isHidden (ver MarkdownPreviewView.isActive), no con opacidad.
            ZStack {
                MarkdownPreviewView(preview: preview, isActive: !tabs.activeDocumentIsHTML && !tabs.activeDocumentIsTable)
                HTMLPreviewView(preview: htmlPreview, isActive: tabs.activeDocumentShowsHTMLPreview)
                CSVTableView(model: csvTable, isActive: tabs.activeDocumentIsTable,
                             isLocked: tabs.activeDocument?.isLocked == true,
                             onSortDocument: { sortDocumentByColumn($0) },
                             onJump: { jumpToTableCell(byteOffset: $0) })
            }
        }
    }

    private func scheduleRefresh() {
        guard tabs.activePreviewMode != .editor, let document = tabs.activeDocument else { return }
        if tabs.activeDocumentIsTable {
            csvTable.scheduleRefresh(editor: tabs.editor, document: document)
        } else if tabs.activeDocumentIsHTML {
            let editor = tabs.editor
            htmlPreview.scheduleRefresh(text: currentText(editor), baseDirectory: document.url?.deletingLastPathComponent(),
                                        documentID: document.id)
        } else if tabs.activeDocumentIsMarkdown {
            preview.scheduleRefresh(editor: tabs.editor, document: document, theme: markdownTheme(for: colorScheme))
        }
    }

    private func refreshPreview() {
        let previewVisible = tabs.activePreviewMode != .editor
        if previewVisible, let document = tabs.activeDocument, tabs.activeDocumentIsTable {
            csvTable.refreshNow(editor: tabs.editor, document: document)
        } else {
            csvTable.clear()
        }
        if previewVisible, let document = tabs.activeDocument, tabs.activeDocumentShowsHTMLPreview {
            htmlPreview.refreshNow(text: currentText(tabs.editor), baseDirectory: document.url?.deletingLastPathComponent(),
                                   documentID: document.id)
        } else {
            htmlPreview.unload()
        }
        guard previewVisible, let document = tabs.activeDocument, tabs.activeDocumentIsMarkdown,
              !tabs.activeDocumentIsTable else { return }
        preview.refreshNow(editor: tabs.editor, document: document, theme: markdownTheme(for: colorScheme))
    }

    /// "Ordenar documento por esta columna": reordena las filas crudas en una acción de deshacer.
    private func sortDocumentByColumn(_ column: Int) {
        guard let document = tabs.activeDocument, !document.isLocked else { NSSound.beep(); return }
        let editor = tabs.editor
        let text = currentText(editor)
        let table = parseCSV(text, delimiter: csvTable.delimiter)
        let skipHeader = csvTable.hasHeader
        // Misma dirección que la vista: si el usuario la ve descendente, el documento queda igual.
        let ascending = csvTable.sortColumn == column ? csvTable.sortAscending : true
        guard let order = documentSortOrder(table, column: column, ascending: ascending, skipHeader: skipHeader) else {
            NSSound.beep(); return
        }
        let eol = [0: "\r\n", 1: "\r", 2: "\n"][Int(ScintillaView.directCall(editor, message: SCI_GETEOLMODE, wParam: 0, lParam: 0))] ?? "\n"
        let sorted = reorderedDocument(text, table: table, order: order, skipHeader: skipHeader, eol: eol)
        guard sorted != text else { return }
        _ = ScintillaView.directCall(editor, message: SCI_BEGINUNDOACTION, wParam: 0, lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_TARGETWHOLEDOCUMENT, wParam: 0, lParam: 0)
        sorted.withCString { cstr in
            _ = ScintillaView.directCall(editor, message: SCI_REPLACETARGET, wParam: uptr_t(strlen(cstr)),
                                         lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
        }
        _ = ScintillaView.directCall(editor, message: SCI_ENDUNDOACTION, wParam: 0, lParam: 0)
        csvTable.refreshNow(editor: editor, document: document)
    }

    /// Doble clic en una celda: lleva el caret al inicio del campo (en solo-vista-previa pasa a dividida).
    private func jumpToTableCell(byteOffset: Int) {
        if tabs.activePreviewMode == .preview { tabs.activePreviewMode = .split }
        _ = ScintillaView.directCall(tabs.editor, message: SCI_GOTOPOS, wParam: uptr_t(max(0, byteOffset)), lParam: 0)
        _ = ScintillaView.directCall(tabs.editor, message: SCI_SCROLLCARET, wParam: 0, lParam: 0)
        deferPastCurrentLayoutPass { tabs.editor.window?.makeFirstResponder(tabs.editor) }
    }

    /// Debounce de 500ms sobre SpellChecker.check(), agendado desde contenido/scroll/cambio
    /// de pestaña. Cancela cualquier revisión pendiente antes de agendar la nueva, igual que
    /// MarkdownPreview.scheduleRefresh — sin esto, escribir rápido dispararía una revisión
    /// (NSSpellChecker + recorrido del rango visible) por cada tecla.
    private func scheduleSpellCheck() {
        guard spellCheck.enabled, let document = tabs.activeDocument else { return }
        pendingSpellCheck?.cancel()
        let item = DispatchWorkItem { [tabs, spellCheck] in
            SpellChecker.check(editor: tabs.editor, document: document, spellCheck: spellCheck)
        }
        pendingSpellCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Debounce corto (150ms) del smart highlight: arrastrar una selección dispara
    /// SC_UPDATE_SELECTION en cada movimiento. Con la barra de Find visible no se pinta, para
    /// no mezclar su "resaltar todo" con este resaltado.
    private func scheduleSmartHighlight() {
        pendingSmartHighlight?.cancel()
        let item = DispatchWorkItem { [tabs, find] in
            guard let document = tabs.activeDocument else { return }
            BraceMatcher.updateTags(editor: tabs.editor, lexerName: document.languageProfile.lexerName)
            if find.isVisible {
                SmartHighlighter.clear(editor: tabs.editor)
            } else {
                SmartHighlighter.update(editor: tabs.editor)
            }
        }
        pendingSmartHighlight = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    /// Subrayados de color CSS (indicador 15) con el mismo debounce de 150ms que el smart
    /// highlight: scroll y tipeo los disparan en ráfaga y el cálculo es del rango visible.
    private func scheduleCSSColors() {
        pendingCSSColors?.cancel()
        let item = DispatchWorkItem { [tabs] in
            guard let document = tabs.activeDocument else { return }
            updateCSSColorIndicators(editor: tabs.editor, lexerName: document.languageProfile.lexerName)
        }
        pendingCSSColors = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    /// Margen de git: 500 ms tras la última edición (el diff es de todo el documento).
    private func scheduleGitGutter() {
        pendingGitGutter?.cancel()
        let item = DispatchWorkItem { [tabs] in
            tabs.gitGutter.refreshNow(document: tabs.activeDocument, editor: tabs.editor)
        }
        pendingGitGutter = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func refreshGitGutterNow() {
        pendingGitGutter?.cancel()
        tabs.gitGutter.refreshNow(document: tabs.activeDocument, editor: tabs.editor)
    }

    /// Revisión inmediata (sin debounce) tras una acción del menú de corrector (Task 11):
    /// reemplazo de palabra, aprender o ignorar. El usuario espera ver el squiggle
    /// actualizado al instante, no 500ms después.
    private func recheckSpellingNow() {
        guard spellCheck.enabled, let document = tabs.activeDocument else { return }
        pendingSpellCheck?.cancel()
        SpellChecker.check(editor: tabs.editor, document: document, spellCheck: spellCheck)
    }

    /// Callback de MarkdownPreviewViewModel.onJumpToSourceLine: doble-click en la preview
    /// resolvió una línea de origen (1-based). En solo-vista-previa no hay editor visible
    /// para saltar, así que primero se pasa a dividida.
    private func jumpToSourceLine(_ line: Int) {
        guard tabs.activeDocumentIsMarkdown else { return }
        if preview.mode == .preview {
            preview.mode = .split
        }
        let targetLine = uptr_t(max(0, line - 1))
        _ = ScintillaView.directCall(tabs.editor, message: SCI_GOTOLINE, wParam: targetLine, lParam: 0)
        _ = ScintillaView.directCall(tabs.editor, message: SCI_ENSUREVISIBLEENFORCEPOLICY, wParam: targetLine, lParam: 0)
        tabs.editor.window?.makeFirstResponder(tabs.editor)
    }

    /// Click en un ítem del esquema (línea 0-based): título de Markdown o función de código.
    /// En Markdown, a diferencia de jumpToSourceLine, no cambia el modo de vista: en
    /// solo-vista-previa desplaza la preview a esa sección; en dividida mueve el editor y
    /// también la preview (el sync de scroll es proporcional y no alinea secciones con precisión).
    private func jumpToOutlineLine(_ line: Int) {
        guard tabs.activeDocument != nil else { return }
        let isMarkdown = tabs.activeDocumentIsMarkdown
        let targetLine = uptr_t(max(0, line))
        _ = ScintillaView.directCall(tabs.editor, message: SCI_GOTOLINE, wParam: targetLine, lParam: 0)
        _ = ScintillaView.directCall(tabs.editor, message: SCI_ENSUREVISIBLEENFORCEPOLICY, wParam: targetLine, lParam: 0)
        if isMarkdown, preview.mode != .editor {
            preview.cancelPendingScrollSync()
            preview.scrollToSourceLine(line + 1)
        }
        // En solo-vista-previa (Markdown o HTML) el editor está oculto: no se le da el foco.
        if tabs.activePreviewMode != .preview {
            tabs.editor.window?.makeFirstResponder(tabs.editor)
        }
    }

    /// Para Buscar en archivos: si el documento activo tiene cambios sin guardar, se busca en
    /// su texto actual (el editor es uno solo: de los inactivos solo se tiene la versión de disco).
    private func unsavedActiveText() -> [URL: String] {
        tabs.syncDirtyFlagOfActiveDocument()
        guard let document = tabs.activeDocument, document.isDirty, let url = document.url else { return [:] }
        return [url: currentText(tabs.editor)]
    }

    /// Click en un resultado de Buscar en archivos: abre (o activa) el archivo y selecciona la
    /// coincidencia. Diferido un ciclo porque open(url:) cambia de documento y SwiftUI
    /// reconstruye la vista del editor en el mismo pase.
    private func openFindMatch(url: URL, line: Int, byteStart: Int, byteLength: Int) {
        guard tabs.open(url: url) else { return }
        selectMatchAfterTabSwitch(line: line, byteStart: byteStart, byteLength: byteLength)
    }

    /// Resultado de Buscar todo: activa la pestaña por id; si ya se cerró, avisa con un beep.
    private func openDocumentMatch(id: UUID, line: Int, byteStart: Int, byteLength: Int) {
        guard let index = tabs.documents.firstIndex(where: { $0.id == id }) else {
            NSSound.beep()
            return
        }
        if tabs.activeIndex != index { tabs.activate(at: index) }
        selectMatchAfterTabSwitch(line: line, byteStart: byteStart, byteLength: byteLength)
    }

    /// Buscar todo desde la barra: muestra los resultados en la pestaña Buscar del sidebar.
    private func findAll(allDocuments: Bool) {
        let find = tabs.find
        guard !find.findText.isEmpty else { return }
        let targets: [Document] = allDocuments ? tabs.documents : (tabs.activeDocument.map { [$0] } ?? [])
        let inputs = targets.map { (id: $0.id, title: $0.displayName, text: tabs.text(of: $0)) }
        let scope = allDocuments ? L("Resultados en documentos abiertos")
            : L("Resultados en \(tabs.activeDocument?.displayName ?? "")")
        tabs.findInFiles.showResults(forDocuments: inputs, query: find.findText, matchCase: find.matchCase,
                                     wholeWord: find.wholeWord, useRegex: find.useRegex,
                                     scope: allDocuments ? .openDocuments : .document, scopeDescription: scope)
        tabs.outline.sidebarTab = .search
        tabs.outline.showRequestToken += 1
    }

    private func selectMatchAfterTabSwitch(line: Int, byteStart: Int, byteLength: Int) {
        DispatchQueue.main.async {
            let lineStart = Int(ScintillaView.directCall(tabs.editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(line), lParam: 0))
            guard lineStart >= 0 else { return }
            let start = lineStart + byteStart
            _ = ScintillaView.directCall(tabs.editor, message: SCI_ENSUREVISIBLEENFORCEPOLICY, wParam: uptr_t(line), lParam: 0)
            _ = ScintillaView.directCall(tabs.editor, message: SCI_SETSEL, wParam: uptr_t(start), lParam: sptr_t(start + byteLength))
            _ = ScintillaView.directCall(tabs.editor, message: SCI_SCROLLCARET, wParam: 0, lParam: 0)
            tabs.editor.window?.makeFirstResponder(tabs.editor)
        }
    }

    /// Pulso breve del ícono de candado ante SCN_MODIFYATTEMPTRO. Reinicia el valor de
    /// partida en cada llamada (en vez de encadenar animaciones) para que escribir
    /// repetido sobre un documento bloqueado reinicie el pulso en curso, no lo acumule.
    /// Resuelve los NSItemProvider del .onDrop (asíncrono, uno por ítem arrastrado) a URLs
    /// y los procesa en main. Devuelve true si al menos hay un provider de tipo fileURL,
    /// como pide la firma de .onDrop — la resolución real llega después, por callback.
    @discardableResult
    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    handleDroppedURLs([url])
                }
            }
        }
        return true
    }

    /// Único punto que decide qué hacer con una URL soltada (desde el .onDrop del
    /// contenedor o desde SCN_URIDROPPED sobre el editor, Task 12): carpeta -> árbol,
    /// archivo -> pestaña nueva. Compartido para que ambos caminos de entrada se
    /// comporten igual, incluidos varios archivos sueltos a la vez.
    private func handleDroppedURLs(_ urls: [URL]) {
        // Imágenes soltadas sobre un Markdown: se enlazan en vez de abrirse como texto.
        if let document = tabs.activeDocument, document.languageProfile.lexerName == "markdown",
           !document.isLocked, !urls.isEmpty, urls.allSatisfy(MarkdownImages.isImage) {
            MarkdownImages.dropImages(urls, editor: tabs.editor, document: document)
            return
        }
        var isDirectory: ObjCBool = false
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                actions.openFolder(url: url)
            } else {
                tabs.open(url: url)
            }
        }
    }

    private func pulseLock() {
        lockPulseScale = 1.4
        withAnimation(.easeOut(duration: 0.4)) {
            lockPulseScale = 1.0
        }
    }
}

private func markdownTheme(for colorScheme: ColorScheme) -> MarkdownTheme {
    colorScheme == .dark ? .dark : .light
}
