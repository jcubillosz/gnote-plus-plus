// Menús de la app (Commands de SwiftUI) y atajos de teclado de función.
import SwiftUI
import AppKit
import Scintilla

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    @AppStorage(SmartHighlighter.enabledDefaultsKey) private var smartHighlightEnabled = true

    /// Hay documento activo y no está bloqueado — requisito de las operaciones que editan texto.
    private var canEditActive: Bool {
        tabs.activeIndex != nil && tabs.activeDocument?.isLocked != true
    }

    @ObservedObject var tabs: TabsViewModel
    @ObservedObject var fileTree: FileTreeViewModel
    // RecentPathsViewModel vive anidado dentro de TabsViewModel, pero un ObservableObject
    // anidado no reenvía objectWillChange al padre: hay que observarlo directo acá para
    // que el menú se refresque cuando cambian los recientes.
    @ObservedObject var recentFiles: RecentPathsViewModel
    // Las carpetas recientes son otra instancia y otro ObservableObject: necesita su
    // propia suscripción o el menú no se refresca al abrir una carpeta.
    @ObservedObject var recentFolders: RecentPathsViewModel
    // Mismo motivo: el check del toggle de la preview depende de preview.isVisible, que
    // vive en un ObservableObject anidado y no publica a través de `tabs`.
    @ObservedObject var preview: MarkdownPreviewViewModel
    // Idem: los checks del menú Ortografía (enabled/language) viven en otro
    // ObservableObject anidado.
    @ObservedObject var spellCheck: SpellCheckViewModel
    // Idem: los checks del menú Vista leen preferences.wordWrap/showLineNumbers/
    // showWhitespace, que viven en otro ObservableObject anidado.
    @ObservedObject var preferences: EditorPreferences
    // Idem: el título de grabar/detener y la lista de macros guardadas.
    @ObservedObject var macros: MacroRecorder
    @ObservedObject var clipboardHistory: ClipboardHistory

    private let commonEncodings = ["UTF-8", "UTF-16LE", "UTF-16BE", "ISO-8859-1", "Windows-1252"]

    private var actions: DocumentActions {
        DocumentActions(tabs: tabs, fileTree: fileTree, recentFiles: recentFiles, recentFolders: recentFolders, preferences: preferences)
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("Acerca de GNote++")) { openWindow(id: aboutWindowID) }
        }

        CommandGroup(replacing: .newItem) {
            Button(L("Nuevo")) { tabs.newDocument() }
                .keyboardShortcut("n", modifiers: .command)
            Button(L("Abrir archivo…")) { actions.openFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button(L("Abrir carpeta…")) { actions.openFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button(L("Abrir rápido…")) {
                showQuickOpen(tabs.quickPanel, tabs: tabs, index: tabs.fileIndex, root: fileTree.root?.url)
            }
            .keyboardShortcut("t", modifiers: .command)
            Menu(L("Abrir recientes")) {
                ForEach(recentFiles.urls, id: \.self) { url in
                    Button(url.lastPathComponent) { tabs.open(url: url) }
                        .help(url.path)
                }
                Divider()
                Button(L("Restaurar archivo cerrado")) { tabs.reopenLastClosed() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button(L("Vaciar lista de recientes")) { recentFiles.clear() }
            }
            .disabled(recentFiles.urls.isEmpty)
            Menu(L("Abrir carpetas recientes")) {
                ForEach(recentFolders.urls, id: \.self) { url in
                    // add() ademas de openFolder: sin esto, elegir una carpeta del menu
                    // no la sube al tope y la lista deja de reflejar el uso real.
                    Button(url.lastPathComponent) {
                        fileTree.openFolder(url)
                        recentFolders.add(url)
                    }
                    .help(url.path)
                }
                Divider()
                Button(L("Vaciar lista de carpetas")) { recentFolders.clear() }
            }
            .disabled(recentFolders.urls.isEmpty)
            Divider()
            Button(L("Cerrar pestaña")) {
                if let index = tabs.activeIndex { tabs.close(at: index) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(tabs.activeIndex == nil)
            Button(L("Cerrar todas")) { tabs.closeAll() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(tabs.activeIndex == nil)
            Button(L("Guardar")) { tabs.saveActive() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(tabs.activeIndex == nil)
            Button(L("Guardar como…")) { tabs.saveActiveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(tabs.activeIndex == nil)
            Button(L("Guardar todo")) { tabs.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(tabs.activeIndex == nil)
            Button(L("Renombrar…")) {
                tabs.renameActive()
                // renameActive() no refresca el árbol por sí solo; el watcher lo haría
                // igual en ~0.3s, pero el usuario espera ver el nombre nuevo al instante.
                fileTree.refresh()
            }
            .disabled(tabs.activeDocument?.url == nil)
            Divider()
            // Tamaño de papel (carta, legal, A4…): el PDF de Markdown se pagina con él.
            Button(L("Ajustar página…")) { NSPageLayout().runModal(with: NSPrintInfo.shared) }
                .keyboardShortcut("p", modifiers: [.command, .shift, .option])
            Button(L("Imprimir…")) { actions.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(tabs.activeIndex == nil)
            if preview.isVisible, tabs.activeDocumentIsMarkdown {
                Button(L("Imprimir vista previa…")) { actions.printMarkdownPreview() }
            }
            Button(L("Exportar a HTML…")) { actions.export(asPDF: false) }
                .disabled(tabs.activeIndex == nil)
            Button(L("Exportar a PDF…")) { actions.export(asPDF: true) }
                .disabled(tabs.activeIndex == nil)
            Button(L("Abrir en el navegador")) { tabs.openActiveInBrowser() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(!tabs.activeDocumentIsHTML || tabs.activeDocument?.url == nil)
        }

        CommandGroup(after: .textEditing) {
            Button(L("Buscar…")) {
                tabs.find.isVisible = true
                tabs.find.showReplace = false
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(tabs.activeIndex == nil)

            Button(L("Buscar y reemplazar…")) {
                tabs.find.isVisible = true
                tabs.find.showReplace = true
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(tabs.activeIndex == nil)

            Button(L("Buscar siguiente")) {
                if tabs.find.isVisible || !tabs.find.findText.isEmpty {
                    findNext(editor: tabs.editor, find: tabs.find)
                }
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(tabs.activeIndex == nil)

            Button(L("Buscar anterior")) {
                if tabs.find.isVisible || !tabs.find.findText.isEmpty {
                    findPrevious(editor: tabs.editor, find: tabs.find)
                }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(tabs.activeIndex == nil)

            Button(L("Probar expresión regular…")) {
                RegexTesterPanel.shared.show(tabs: tabs)
            }
            .keyboardShortcut("x", modifiers: [.command, .control])
            .disabled(tabs.activeIndex == nil)

            Button(L("Buscar en archivos…")) {
                tabs.outline.sidebarTab = .search
                tabs.outline.showRequestToken += 1
                tabs.findInFiles.focusRequestToken += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button(L("Reemplazar en archivos…")) {
                tabs.outline.sidebarTab = .search
                tabs.outline.showRequestToken += 1
                tabs.findInFiles.showReplace = true
                tabs.findInFiles.focusRequestToken += 1
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button(L("Ir a símbolo del proyecto…")) {
                showQuickOpen(tabs.quickPanel, tabs: tabs, index: tabs.fileIndex, root: fileTree.root?.url,
                              initialQuery: "#")
            }
            .keyboardShortcut("o", modifiers: [.command, .option])

            Button(L("Ir a la línea…")) { goToLine(editor: tabs.editor) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(tabs.activeIndex == nil)

            Button(L("Pegar desde el historial…")) { clipboardHistory.pickerVisible = true }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!canEditActive || clipboardHistory.entries.isEmpty)

            Menu(L("Marcadores")) {
                Button(L("Alternar marcador")) { toggleBookmark(editor: tabs.editor) }
                    .keyboardShortcut(functionKey(2), modifiers: .command)
                Button(L("Siguiente marcador")) { goToBookmark(editor: tabs.editor, forward: true) }
                    .keyboardShortcut(functionKey(2), modifiers: [])
                Button(L("Marcador anterior")) { goToBookmark(editor: tabs.editor, forward: false) }
                    .keyboardShortcut(functionKey(2), modifiers: .shift)
                Divider()
                Button(L("Borrar todos los marcadores")) { clearBookmarks(editor: tabs.editor) }
                Divider()
                Button(L("Cortar líneas con marcador")) { cutBookmarkedLines(tabs.editor) }
                    .disabled(!canEditActive)
                Button(L("Copiar líneas con marcador")) { copyBookmarkedLines(tabs.editor) }
                Button(L("Pegar reemplazando líneas con marcador")) { pasteReplacingBookmarkedLines(tabs.editor) }
                    .disabled(!canEditActive)
                Button(L("Eliminar líneas con marcador")) { deleteLines(tabs.editor, bookmarked: true) }
                    .disabled(!canEditActive)
                Button(L("Eliminar líneas sin marcador")) { deleteLines(tabs.editor, bookmarked: false) }
                    .disabled(!canEditActive)
                Button(L("Invertir marcadores")) { invertBookmarks(tabs.editor) }
            }
            .disabled(tabs.activeIndex == nil)

            Divider()
            Menu(L("Operaciones de línea")) {
                Button(L("Duplicar línea")) { duplicateSelectionOrLine(editor: tabs.editor) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button(L("Eliminar línea")) { deleteCurrentLine(editor: tabs.editor) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button(L("Mover línea arriba")) { moveSelectedLines(editor: tabs.editor, up: true) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button(L("Mover línea abajo")) { moveSelectedLines(editor: tabs.editor, up: false) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button(L("Unir líneas")) { joinLines(editor: tabs.editor) }
                    .keyboardShortcut("j", modifiers: [.command, .control])
                Divider()
                Button(L("Ordenar líneas (A→Z)")) { transformLines(editor: tabs.editor, .sortAscending) }
                Button(L("Ordenar líneas (Z→A)")) { transformLines(editor: tabs.editor, .sortDescending) }
                Button(L("Quitar duplicadas consecutivas")) { transformLines(editor: tabs.editor, .removeConsecutiveDuplicates) }
                Button(L("Quitar todas las duplicadas")) { transformLines(editor: tabs.editor, .removeAllDuplicates) }
                Button(L("Quitar líneas vacías")) { transformLines(editor: tabs.editor, .removeEmptyLines) }
                Divider()
                Button(L("Invertir orden")) { transformLines(editor: tabs.editor, .reverse) }
                Button(L("Orden aleatorio")) { transformLines(editor: tabs.editor, .shuffle) }
                Button(L("Ordenar sin distinguir mayúsculas")) { transformLines(editor: tabs.editor, .sortCaseInsensitive) }
                Button(L("Ordenar numérico")) { transformLines(editor: tabs.editor, .sortNumeric) }
                Button(L("Ordenar por largo")) { transformLines(editor: tabs.editor, .sortByLength) }
                Divider()
                Button(L("Insertar línea en blanco arriba")) { insertBlankLine(editor: tabs.editor, above: true) }
                Button(L("Insertar línea en blanco abajo")) { insertBlankLine(editor: tabs.editor, above: false) }
            }
            .disabled(!canEditActive)
            Menu(L("Espacios en blanco")) {
                Button(L("Tabs a espacios")) { convertTabsToSpaces(editor: tabs.editor, tabWidth: preferences.tabWidth) }
                Button(L("Espacios iniciales a tabs")) { convertLeadingSpacesToTabs(editor: tabs.editor, tabWidth: preferences.tabWidth) }
                Divider()
                Button(L("Recortar espacios finales")) { transformLines(editor: tabs.editor, .trimTrailing) }
                Button(L("Recortar espacios iniciales")) { transformLines(editor: tabs.editor, .trimLeading) }
                Button(L("Recortar ambos")) { transformLines(editor: tabs.editor, .trimBoth) }
                Button(L("Fin de línea a espacio")) { joinLinesWithSpace(editor: tabs.editor) }
                Divider()
                Button(L("Reindentar")) {
                    let lexer = tabs.activeDocument?.languageProfile.lexerName ?? "null"
                    if !reindent(editor: tabs.editor, family: IndentFamily(lexerName: lexer), lexerName: lexer) { NSSound.beep() }
                }
            }
            .disabled(!canEditActive)
            Menu(L("Insertar fecha y hora")) {
                Button(L("Corta")) { insertDateTime(editor: tabs.editor, style: .short) }
                Button(L("Larga")) { insertDateTime(editor: tabs.editor, style: .long) }
                Button(L("ISO 8601")) { insertDateTime(editor: tabs.editor, style: .iso8601) }
            }
            .disabled(!canEditActive)
            Menu(L("Selección múltiple")) {
                Button(L("Agregar siguiente coincidencia")) { addNextOccurrence(editor: tabs.editor, all: false) }
                    .keyboardShortcut("d", modifiers: .command)
                Button(L("Seleccionar todas las coincidencias")) { addNextOccurrence(editor: tabs.editor, all: true) }
                    .keyboardShortcut("g", modifiers: [.command, .control])
                Button(L("Agregar cursor arriba")) { addCursorVertically(editor: tabs.editor, up: true) }
                    .keyboardShortcut(.upArrow, modifiers: [.control, .shift])
                Button(L("Agregar cursor abajo")) { addCursorVertically(editor: tabs.editor, up: false) }
                    .keyboardShortcut(.downArrow, modifiers: [.control, .shift])
            }
            .disabled(!canEditActive)
            Menu(L("Convertir mayúsculas/minúsculas")) {
                Button(L("MAYÚSCULAS")) { convertCase(editor: tabs.editor, upper: true) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button(L("minúsculas")) { convertCase(editor: tabs.editor, upper: false) }
                    .keyboardShortcut("u", modifiers: [.command, .control])
                Button(L("Tipo Título")) { convertToTitleCase(editor: tabs.editor) }
                Button(L("Tipo oración")) { convertToSentenceCase(editor: tabs.editor) }
                Button(L("Invertir mayúsculas/minúsculas")) { invertCase(editor: tabs.editor) }
            }
            .disabled(!canEditActive)
            Menu(L("Markdown")) {
                Button(L("Negrita")) { insertMarkdownBold(editor: tabs.editor) }
                    .keyboardShortcut("b", modifiers: .command)
                Button(L("Cursiva")) { insertMarkdownItalic(editor: tabs.editor) }
                    .keyboardShortcut("i", modifiers: .command)
            }
            .disabled(!canEditActive || !tabs.activeDocumentIsMarkdown)
            Button(tabs.activeDocumentIsMarkdown ? L("Insertar enlace") : L("Comentar/descomentar")) {
                if tabs.activeDocumentIsMarkdown {
                    insertMarkdownLink(editor: tabs.editor)
                } else if let syntax = tabs.activeDocument?.languageProfile.comment {
                    toggleComment(editor: tabs.editor, syntax: syntax)
                }
            }
            // ⌘K como el Ctrl+K de Notepad++: ⌘/ caía en la misma tecla física que ⌘− (zoom)
            // con teclado español.
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!canEditActive || (!tabs.activeDocumentIsMarkdown && tabs.activeDocument?.languageProfile.comment.isAvailable != true))
            Button(L("Editor de columna…")) { tabs.showColumnEditor = true }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!canEditActive)
            Button(L("Ir a la llave pareja")) {
                if !BraceMatcher.goToMatchingBrace(editor: tabs.editor, select: false) { NSSound.beep() }
            }
            .keyboardShortcut("b", modifiers: [.command, .control])
            .disabled(tabs.activeIndex == nil)
            Button(L("Seleccionar hasta la llave pareja")) {
                if !BraceMatcher.goToMatchingBrace(editor: tabs.editor, select: true) { NSSound.beep() }
            }
            .keyboardShortcut("b", modifiers: [.command, .control, .shift])
            .disabled(tabs.activeIndex == nil)
            Button(L("Renombrar etiqueta")) { tabs.renameTag() }
                .keyboardShortcut("r", modifiers: [.command, .control])
                .disabled(!canEditActive || !["hypertext", "xml"].contains(tabs.activeDocument?.languageProfile.lexerName ?? ""))
            Button(L("Expandir abreviatura")) {
                if !expandEmmetAtCaret(editor: tabs.editor) { NSSound.beep() }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!canEditActive || !["hypertext", "xml", "markdown"].contains(tabs.activeDocument?.languageProfile.lexerName ?? ""))
            Menu(L("Fragmentos")) {
                Button(L("Insertar fragmento…")) { tabs.showSnippetPicker() }
                    .keyboardShortcut("i", modifiers: [.command, .control])
                    .disabled(!canEditActive)
                Toggle(L("Expandir fragmentos con Tab"), isOn: $preferences.snippetsEnabled)
                Divider()
                Button(L("Administrar fragmentos…")) { SnippetManagerWindow.show() }
                Button(L("Abrir snippets.json")) { tabs.openSnippetsFile() }
            }
            Button(L("Elegir color…")) { pickCSSColor(editor: tabs.editor) }
                .disabled(!canEditActive)
            Button(L("Formatear tabla Markdown")) {
                if !MarkdownEditing.formatTable(editor: tabs.editor) { NSSound.beep() }
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(!canEditActive || tabs.activeDocument?.languageProfile.lexerName != "markdown")

            Divider()
            Toggle(L("Bloquear edición"), isOn: Binding(
                get: { tabs.activeDocument?.isLocked ?? false },
                // El valor nuevo lo decide toggleLockActive() (invierte lo que ya tenía el
                // documento activo, no lo que llegó acá) — un Binding normal alcanza porque
                // Toggle en un menú solo necesita algo que asignar para mostrar el checkmark.
                set: { _ in tabs.toggleLockActive() }
            ))
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(tabs.activeIndex == nil)

            Divider()
            Menu(L("Ortografía")) {
                Toggle(L("Revisar ortografía"), isOn: $spellCheck.enabled)
                    .keyboardShortcut(";", modifiers: [.command, .shift])
                Divider()
                Toggle(L("Español"), isOn: Binding(
                    get: { spellCheck.language == "es" },
                    set: { if $0 { spellCheck.language = "es" } }
                ))
                Toggle(L("Inglés"), isOn: Binding(
                    get: { spellCheck.language == "en" },
                    set: { if $0 { spellCheck.language = "en" } }
                ))
                Toggle(L("Automático"), isOn: Binding(
                    get: { spellCheck.language == "auto" },
                    set: { if $0 { spellCheck.language = "auto" } }
                ))
            }
        }

        CommandMenu(L("Lenguaje")) {
            ForEach(languageMenuGroups(), id: \.label) { group in
                Menu(group.label) {
                    ForEach(group.names, id: \.self) { name in
                        Button(name) { tabs.forceLanguage(name) }
                            .disabled(tabs.activeIndex == nil)
                    }
                }
            }
        }

        CommandMenu(L("Codificación")) {
            ForEach(commonEncodings, id: \.self) { encoding in
                Button(L("Recargar como \(encoding)")) { tabs.reload(activeDocumentWithEncoding: encoding) }
                    .disabled(tabs.activeIndex == nil || tabs.activeDocument?.isLocked == true || tabs.activeDocument?.url == nil)
            }
            Divider()
            Button(L("Convertir fin de línea a Windows (CRLF)")) { tabs.convertActiveEOL(to: .crlf) }
                .disabled(tabs.activeIndex == nil || tabs.activeDocument?.isLocked == true)
            Button(L("Convertir fin de línea a Unix (LF)")) { tabs.convertActiveEOL(to: .lf) }
                .disabled(tabs.activeIndex == nil || tabs.activeDocument?.isLocked == true)
            Button(L("Convertir fin de línea a Mac clásico (CR)")) { tabs.convertActiveEOL(to: .cr) }
                .disabled(tabs.activeIndex == nil || tabs.activeDocument?.isLocked == true)
        }

        CommandMenu(L("Vista")) {
            Button(L("Paleta de comandos…")) { showCommandPalette(tabs.quickPanel) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button(L("Resumen…")) { showDocumentSummary(editor: tabs.editor) }
                .disabled(tabs.activeIndex == nil)
            Divider()
            Toggle(L("Ajuste de línea"), isOn: Binding(
                get: { preferences.wordWrap },
                set: { preferences.wordWrap = $0; preferences.applyEditingOptions(to: tabs.editor) }
            ))
            Toggle(L("Números de línea"), isOn: Binding(
                get: { preferences.showLineNumbers },
                set: { preferences.showLineNumbers = $0; preferences.applyEditingOptions(to: tabs.editor) }
            ))
            Toggle(L("Resaltar coincidencias de la selección"), isOn: Binding(
                get: { smartHighlightEnabled },
                set: { smartHighlightEnabled = $0; SmartHighlighter.update(editor: tabs.editor) }
            ))
            Button(L("Acercar")) { preferences.zoom = min(preferences.zoom + 1, 20); preferences.applyEditingOptions(to: tabs.editor) }
                .keyboardShortcut("+", modifiers: .command)
            Button(L("Alejar")) { preferences.zoom = max(preferences.zoom - 1, -10); preferences.applyEditingOptions(to: tabs.editor) }
                .keyboardShortcut("-", modifiers: .command)
            Button(L("Tamaño real")) { preferences.zoom = 0; preferences.applyEditingOptions(to: tabs.editor) }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Toggle(L("Autocompletar"), isOn: Binding(
                get: { preferences.autoComplete },
                set: { preferences.autoComplete = $0 }
            ))
            Toggle(L("Mostrar minimapa"), isOn: Binding(
                get: { preferences.showDocumentMap },
                set: { preferences.showDocumentMap = $0 }
            ))
            .keyboardShortcut("m", modifiers: [.command, .control])
            Toggle(L("Mostrar ruta de navegación"), isOn: Binding(
                get: { preferences.showBreadcrumbs },
                set: { preferences.showBreadcrumbs = $0 }
            ))
            Toggle(L("Encabezado fijo"), isOn: Binding(
                get: { preferences.stickyScroll },
                set: { preferences.stickyScroll = $0 }
            ))
            Toggle(L("Margen de plegado"), isOn: Binding(
                get: { preferences.showFoldMargin },
                set: { preferences.showFoldMargin = $0; preferences.applyEditingOptions(to: tabs.editor) }
            ))
            Button(L("Plegar todo")) { foldAll(editor: tabs.editor, expand: false) }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(tabs.activeIndex == nil)
            Button(L("Desplegar todo")) { foldAll(editor: tabs.editor, expand: true) }
                .keyboardShortcut("0", modifiers: [.command, .option, .shift])
                .disabled(tabs.activeIndex == nil)
            Toggle(L("Mostrar espacios en blanco"), isOn: Binding(
                get: { preferences.showWhitespace },
                set: { preferences.showWhitespace = $0; preferences.applyEditingOptions(to: tabs.editor) }
            ))
            Toggle(L("Resaltar línea actual"), isOn: Binding(
                get: { preferences.highlightCurrentLine },
                set: { preferences.highlightCurrentLine = $0; tabs.applyCaretLine() }
            ))
            Toggle(L("Mostrar fin de línea"), isOn: Binding(
                get: { preferences.showEOL },
                set: { preferences.showEOL = $0; preferences.applyEditingOptions(to: tabs.editor) }
            ))
            Toggle(L("Guías de indentación"), isOn: Binding(
                get: { preferences.showIndentGuides },
                set: { preferences.showIndentGuides = $0; preferences.applyEditingOptions(to: tabs.editor) }
            ))
            Toggle(L("Línea de margen"), isOn: Binding(
                get: { preferences.showEdge },
                set: { preferences.showEdge = $0; preferences.applyEditingOptions(to: tabs.editor) }
            ))
            Toggle(L("Historial de cambios en el margen"), isOn: Binding(
                get: { preferences.showChangeHistory },
                set: { preferences.showChangeHistory = $0; preferences.applyEditingOptions(to: tabs.editor) }
            ))
            Toggle(L("Mostrar cambios de git"), isOn: Binding(
                get: { preferences.showGitGutter },
                set: { preferences.showGitGutter = $0; tabs.gitGutter.refreshNow(document: tabs.activeDocument, editor: tabs.editor) }
            ))
            Toggle(L("Blame en línea"), isOn: Binding(
                get: { preferences.showInlineBlame },
                set: { preferences.showInlineBlame = $0; tabs.gitBlame.caretMoved(document: tabs.activeDocument, editor: tabs.editor) }
            ))
            .keyboardShortcut("l", modifiers: [.control, .command])
            Toggle(L("Autocerrar paréntesis y comillas"), isOn: Binding(
                get: { preferences.autoCloseBrackets },
                set: { preferences.autoCloseBrackets = $0 }
            ))
            Toggle(L("Indentación automática"), isOn: Binding(
                get: { preferences.autoIndent },
                set: { preferences.autoIndent = $0 }
            ))
            Toggle(L("Barra Markdown grande"), isOn: Binding(
                get: { preferences.markdownLargeToolbar },
                set: { preferences.markdownLargeToolbar = $0 }
            ))
            Toggle(L("Recortar espacios finales al guardar"), isOn: Binding(
                get: { preferences.trimTrailingWhitespaceOnSave },
                set: { preferences.trimTrailingWhitespaceOnSave = $0 }
            ))
            Divider()
            Toggle(L("Solo editor"), isOn: Binding(
                get: { tabs.activePreviewMode == .editor },
                set: { if $0 { tabs.activePreviewMode = .editor } }
            ))
            .keyboardShortcut("1", modifiers: [.command, .option])
            .disabled(!tabs.activeDocumentHasPreview)
            Toggle(L("Dividida"), isOn: Binding(
                get: { tabs.activePreviewMode == .split },
                set: { if $0 { tabs.activePreviewMode = .split } }
            ))
            .keyboardShortcut("2", modifiers: [.command, .option])
            .disabled(!tabs.activeDocumentHasPreview)
            Toggle(L("Solo vista previa"), isOn: Binding(
                get: { tabs.activePreviewMode == .preview },
                set: { if $0 { tabs.activePreviewMode = .preview } }
            ))
            .keyboardShortcut("3", modifiers: [.command, .option])
            .disabled(!tabs.activeDocumentHasPreview)
            // ⌥⌘P conserva la función previa (Task 7 brief): alterna solo entre editor y
            // dividida, sin pasar nunca a solo-vista-previa desde el atajo histórico.
            Button(L("Alternar vista dividida")) {
                tabs.activePreviewMode = tabs.activePreviewMode == .split ? .editor : .split
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!tabs.activeDocumentHasPreview)
            Toggle(L("Ver como tabla"), isOn: Binding(
                get: { tabs.activeDocumentIsTable && tabs.activePreviewMode != .editor },
                set: { _ in tabs.toggleTableView() }
            ))
            .keyboardShortcut("t", modifiers: [.command, .control])
            .disabled(tabs.activeDocument == nil)
            Divider()
            Button(L("Mostrar esquema")) {
                tabs.outline.sidebarTab = .outline
                tabs.outline.showRequestToken += 1
            }
            .keyboardShortcut("o", modifiers: [.command, .control])
            Divider()
            Button(L("Pestaña siguiente")) { tabs.activateAdjacent(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(tabs.documents.count < 2)
            Button(L("Pestaña anterior")) { tabs.activateAdjacent(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(tabs.documents.count < 2)
        }

        CommandMenu(L("Herramientas")) {
            Button(L("MD5")) { showHash(.md5, editor: tabs.editor) }
                .disabled(tabs.activeIndex == nil)
            Button(L("SHA-1")) { showHash(.sha1, editor: tabs.editor) }
                .disabled(tabs.activeIndex == nil)
            Button(L("SHA-256")) { showHash(.sha256, editor: tabs.editor) }
                .disabled(tabs.activeIndex == nil)
            Divider()
            Button(L("Codificar Base64")) { base64Transform(editor: tabs.editor, encode: true) }
                .disabled(!canEditActive)
            Button(L("Decodificar Base64")) { base64Transform(editor: tabs.editor, encode: false) }
                .disabled(!canEditActive)
            Divider()
            Button(L("Formatear JSON")) {
                let indent = preferences.useTabs ? "\t" : String(repeating: " ", count: max(1, preferences.tabWidth))
                applyFormatter(editor: tabs.editor) { try formatJSON($0, indent: indent) }
            }
            .disabled(!canEditActive)
            Button(L("Minificar JSON")) { applyFormatter(editor: tabs.editor) { try minifyJSON($0) } }
                .disabled(!canEditActive)
            Button(L("Formatear XML")) {
                let indent = preferences.useTabs ? "\t" : String(repeating: " ", count: max(1, preferences.tabWidth))
                applyFormatter(editor: tabs.editor) { try formatXML($0, indent: indent) }
            }
                .disabled(!canEditActive)
            Button(L("Formatear con herramienta externa")) { formatWithExternalTool(tabs: tabs) }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
                .disabled(!canEditActive)
            Divider()
            Button(L("Codificar URL")) {
                webTransform(editor: tabs.editor, title: L("Codificar URL"), errorDetail: "") { urlEncode($0) }
            }
            .disabled(!canEditActive)
            Button(L("Decodificar URL")) {
                webTransform(editor: tabs.editor, title: L("Decodificar URL"), errorDetail: L("El texto no es una URL codificada válida.")) { urlDecode($0) }
            }
            .disabled(!canEditActive)
            Button(L("Codificar entidades HTML")) {
                webTransform(editor: tabs.editor, title: L("Codificar entidades HTML"), errorDetail: "") { htmlEntitiesEncode($0) }
            }
            .disabled(!canEditActive)
            Button(L("Decodificar entidades HTML")) {
                webTransform(editor: tabs.editor, title: L("Decodificar entidades HTML"), errorDetail: "") { htmlEntitiesDecode($0) }
            }
            .disabled(!canEditActive)
            Divider()
            Menu(L("Comparar")) {
                Button(L("Con HEAD")) { tabs.compareActiveWithHead() }
                    .keyboardShortcut("k", modifiers: [.command, .control])
                    .disabled(tabs.activeDocument?.url == nil)
                Button(L("Con la versión guardada")) { tabs.compareActiveWithDisk() }
                    .keyboardShortcut("k", modifiers: [.command, .control, .shift])
                    .disabled(tabs.activeDocument?.url == nil)
                Menu(L("Con pestaña")) {
                    ForEach(tabs.documents.filter { $0 !== tabs.activeDocument }, id: \.id) { other in
                        Button(other.displayName) { tabs.compareActive(with: other.id) }
                    }
                }
                .disabled(tabs.documents.count < 2 || tabs.activeDocument == nil)
            }
            Divider()
            Button(L("Decodificar JWT")) { decodeJWTToNewDocument(tabs: tabs) }
                .disabled(tabs.activeIndex == nil)
            Button(L("Timestamp → fecha")) {
                webTransform(editor: tabs.editor, title: L("Timestamp → fecha"), errorDetail: L("El texto no es un timestamp de 10 dígitos (segundos) o 13 (milisegundos)."),
                             keepTrailingEOL: true) {
                    timestampToISO($0, timeZone: .current)
                }
            }
            .disabled(!canEditActive)
            Button(L("Fecha → timestamp")) {
                webTransform(editor: tabs.editor, title: L("Fecha → timestamp"), errorDetail: L("El texto no es una fecha ISO 8601 (por ejemplo 2018-01-18T01:30:22Z)."),
                             keepTrailingEOL: true) {
                    isoToTimestamp($0).map { String($0) }
                }
            }
            .disabled(!canEditActive)
        }

        CommandMenu(L("Macro")) {
            Button(macros.isRecording ? L("Detener grabación") : L("Iniciar grabación")) {
                if macros.isRecording { macros.stop(editor: tabs.editor) } else { macros.start(editor: tabs.editor) }
            }
            .keyboardShortcut("r", modifiers: [.control, .shift])
            .disabled(!macros.isRecording && tabs.activeIndex == nil)
            Button(L("Reproducir")) { tabs.playMacro(macros.current, times: 1) }
                .keyboardShortcut("p", modifiers: [.control, .shift])
                .disabled(!tabs.canPlayMacro || macros.current.isEmpty)
            Button(L("Reproducir varias veces…")) { playMacroMultipleTimesDialog(tabs: tabs) }
                .disabled(!tabs.canPlayMacro || macros.current.isEmpty)
            Button(L("Guardar macro actual…")) { saveCurrentMacroDialog(macros: macros) }
                .disabled(macros.current.isEmpty || macros.isRecording)
            if !macros.saved.isEmpty {
                Divider()
                ForEach(macros.saved) { macro in
                    Button(macro.name) { tabs.playMacro(macro.steps, times: 1) }
                        .disabled(!tabs.canPlayMacro)
                }
            }
            Divider()
            Menu(L("Eliminar macro")) {
                ForEach(macros.saved) { macro in
                    Button(macro.name) { macros.delete(id: macro.id) }
                }
            }
            .disabled(macros.saved.isEmpty)
        }
    }

}

/// Tecla de función como KeyEquivalent de SwiftUI (F1 = NSF1FunctionKey = 0xF704).
func functionKey(_ number: Int) -> KeyEquivalent {
    KeyEquivalent(Character(UnicodeScalar(0xF704 + number - 1)!))
}
