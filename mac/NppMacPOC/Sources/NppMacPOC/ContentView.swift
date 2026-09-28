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
    // Mismo motivo: SpellCheckViewModel es otro ObservableObject anidado — sin esto,
    // togglear "Revisar ortografía"/idioma desde el menú no dispararía onChange acá.
    @ObservedObject var spellCheck: SpellCheckViewModel
    @ObservedObject var recentFiles: RecentPathsViewModel
    @ObservedObject var recentFolders: RecentPathsViewModel
    let preferences: EditorPreferences
    @Environment(\.colorScheme) private var colorScheme
    // Colapsado al iniciar: sin carpeta abierta, el panel solo ocupa espacio vacío.
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
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
    /// Task 12: borde de acento mientras se arrastra algo de Finder sobre la ventana.
    @State private var isDropTargeted = false

    init(tabs: TabsViewModel, fileTree: FileTreeViewModel, recentFiles: RecentPathsViewModel, recentFolders: RecentPathsViewModel, preferences: EditorPreferences) {
        self.tabs = tabs
        self.fileTree = fileTree
        self.find = tabs.find
        self.preview = tabs.preview
        self.spellCheck = tabs.spellCheck
        self.recentFiles = recentFiles
        self.recentFolders = recentFolders
        self.preferences = preferences
    }

    private var actions: DocumentActions {
        DocumentActions(tabs: tabs, fileTree: fileTree, recentFiles: recentFiles, recentFolders: recentFolders, preferences: preferences)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(fileTree: fileTree, actions: actions, onOpenFile: { tabs.open(url: $0) }, onRename: { url, newName in
                // fileTree.refresh() ya lo dispara el Sidebar después de este callback; acá
                // solo se hace el move + rebase de pestañas y se propaga el resultado para
                // que Task 6 pueda abrir el archivo recién creado tras su rename inicial.
                tabs.renameItem(at: url, to: newName)
            })
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

            if tabs.activeDocumentIsMarkdown {
                ToolbarItemGroup {
                    Picker(L("Modo de vista"), selection: $preview.mode) {
                        Image(systemName: "doc.plaintext").tag(MarkdownPreviewViewModel.PreviewMode.editor)
                        Image(systemName: "rectangle.split.2x1").tag(MarkdownPreviewViewModel.PreviewMode.split)
                        Image(systemName: "doc.richtext").tag(MarkdownPreviewViewModel.PreviewMode.preview)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help(L("Modo de vista"))
                    .frame(width: 120)

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
                        Divider()
                        Button(L("Negrita")) { insertMarkdownBold(editor: tabs.editor) }
                        Button(L("Cursiva")) { insertMarkdownItalic(editor: tabs.editor) }
                        Button(L("Tachado")) { insertMarkdownStrikethrough(editor: tabs.editor) }
                        Button(L("Código en línea")) { insertMarkdownInlineCode(editor: tabs.editor) }
                    } label: {
                        Image(systemName: "textformat.size")
                    }
                    .help(L("Insertar título"))
                    .disabled(tabs.activeDocument?.isLocked == true)

                    Menu {
                        Button(L("Lista con viñeta")) { insertMarkdownBulletList(editor: tabs.editor) }
                        Button(L("Lista numerada")) { insertMarkdownNumberedList(editor: tabs.editor) }
                        Button(L("Lista de tareas")) { insertMarkdownChecklist(editor: tabs.editor) }
                        Button(L("Cita")) { insertMarkdownBlockquote(editor: tabs.editor) }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .help(L("Insertar lista o cita"))
                    .disabled(tabs.activeDocument?.isLocked == true)

                    Button {
                        insertMarkdownTable(editor: tabs.editor)
                    } label: { Image(systemName: "tablecells") }
                    .help(L("Insertar tabla"))
                    .disabled(tabs.activeDocument?.isLocked == true)

                    Button {
                        insertMarkdownImage(editor: tabs.editor, document: tabs.activeDocument)
                    } label: { Image(systemName: "photo") }
                    .help(L("Insertar imagen"))
                    .disabled(tabs.activeDocument?.isLocked == true)

                    Button {
                        insertMarkdownCodeBlock(editor: tabs.editor)
                    } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                    .help(L("Insertar bloque de código"))
                    .disabled(tabs.activeDocument?.isLocked == true)
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
            applyFocusForCurrentMode()
            // Cambio de pestaña: el indicador vive en el ScintillaView compartido, así que
            // los squiggles de la pestaña anterior seguirían pintados sobre el documento
            // nuevo hasta la próxima revisión si no se limpian y recalculan ahora mismo.
            scheduleSpellCheck()
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
        .onChange(of: preview.mode) { mode in
            if mode == .editor {
                preview.cancelPendingRefresh()
                preview.cancelPendingScrollSync()
            } else {
                refreshPreview()
            }
            applyFocusForCurrentMode()
        }
        .onAppear {
            tabs.applyTheme(editorTheme(for: colorScheme))
            preview.onJumpToSourceLine = { line in jumpToSourceLine(line) }
            refreshPreview()
            applyFocusForCurrentMode()
            scheduleSpellCheck()
        }
    }

    /// Único punto que decide el first responder según el modo EFECTIVO (mode +
    /// si el doc activo es Markdown). Se llama desde cada disparador relevante —
    /// cambio de modo, cambio de pestaña y arranque — en vez de solo en el borde
    /// "entrando a .preview": ese borde se pierde en (1) arranque con .preview
    /// restaurado de UserDefaults (el editor puede robar el foco al crearse, antes
    /// de que este código corra), (2) cambiar de una pestaña MD a otra con el modo
    /// ya en .preview (no hay onChange(of: preview.mode) porque el modo no cambió),
    /// (3) cambiar de una pestaña no-MD (modo efectivo .editor) a una MD con
    /// preview.mode ya en .preview (tampoco dispara onChange(of: preview.mode)).
    /// Se difiere al próximo runloop porque en (1)/(2)/(3) ScintillaEditorView
    /// puede reclamar el foco de forma asíncrona al reparentar/crearse (ver su
    /// propio `DispatchQueue.main.async` en adopt(into:)) — sin este defer, esa
    /// llamada posterior le gana a esta y el foco vuelve al editor oculto.
    private func applyFocusForCurrentMode() {
        let effectiveMode: MarkdownPreviewViewModel.PreviewMode =
            tabs.activeDocumentIsMarkdown ? preview.mode : .editor
        // deferPastCurrentLayoutPass, no DispatchQueue.main.async: cambiar de modo cambia el
        // frame/opacity del editor (mostrarlo u ocultarlo), lo que dispara un paso de
        // auto-layout de AppKit. makeFirstResponder programado con .async podía ejecutarse
        // todavía dentro de ese mismo paso y AppKit lo rechazaba con una NSException
        // ("no se puede pedir actualizar constraints mientras ya se está actualizando"),
        // crasheando la app al cambiar el modo de vista previa (bug real de QA manual).
        deferPastCurrentLayoutPass {
            if effectiveMode == .preview {
                preview.webView.window?.makeFirstResponder(preview.webView)
            } else {
                tabs.editor.window?.makeFirstResponder(tabs.editor)
            }
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
        // Un documento no-Markdown se comporta siempre como .editor, aunque `preview.mode`
        // (persistido, compartido entre pestañas) esté en .split/.preview de una pestaña MD.
        let isMarkdown = tabs.activeDocumentIsMarkdown
        let effectiveMode: MarkdownPreviewViewModel.PreviewMode = isMarkdown ? preview.mode : .editor
        let editorHidden = effectiveMode == .preview

        HSplitView {
            ScintillaEditorView(
                editor: tabs.editor,
                statusBar: tabs.statusBar,
                document: tabs.activeDocument,
                spellCheck: spellCheck,
                onContentChanged: { scheduleRefresh(); scheduleSpellCheck() },
                onScrolled: { preview.scheduleScrollSync(editor: tabs.editor); scheduleSpellCheck() },
                onSavePointLeft: { tabs.setActiveDirty(true) },
                onSavePointReached: { tabs.setActiveDirty(false) },
                onModifyAttemptReadOnly: { pulseLock() },
                onSpellCheckAction: { recheckSpellingNow() },
                onURIDropped: { handleDroppedURLs([$0]) }
            )
            .overlay(alignment: .top) {
                if find.isVisible {
                    FindBarView(editor: tabs.editor, find: find, isLocked: tabs.activeDocument?.isLocked == true)
                }
            }
            // El editor NUNCA sale del árbol (ver comentario arriba): en modo solo-vista-previa
            // queda con ancho 0, invisible y sin hit-testing, no removido.
            .frame(width: editorHidden ? 0 : nil)
            .frame(minWidth: editorHidden ? 0 : 240)
            .opacity(editorHidden ? 0 : 1)
            .allowsHitTesting(!editorHidden)

            if effectiveMode != .editor, isMarkdown {
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
