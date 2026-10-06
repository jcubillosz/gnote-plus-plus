import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var fileTree: FileTreeViewModel
    let actions: DocumentActions
    let onOpenFile: (URL) -> Void
    /// Confirma un rename inline: URL vieja + nombre nuevo. Devuelve la URL destino si el
    /// rename se hizo, o nil si falló/se canceló (el llamador ya mostró el error). El
    /// Sidebar refresca el árbol después de invocarlo.
    let onRename: (URL, String) -> URL?
    /// Mueve (origen, carpeta destino) dentro del árbol; devuelve la URL nueva o nil.
    let onMove: (URL, URL) -> URL?
    /// Copia (origen, carpeta destino): archivos soltados desde fuera del árbol (Finder).
    let onCopy: (URL, URL) -> URL?
    // Observados directo: ObservableObjects anidados en TabsViewModel (ver CLAUDE.md).
    @ObservedObject var outline: OutlineViewModel
    @ObservedObject var statusBar: StatusBarViewModel
    /// Click en un título del esquema: línea 0-based del documento activo.
    let onJumpToLine: (Int) -> Void
    @ObservedObject var findInFiles: FindInFilesViewModel
    /// Texto actual de documentos abiertos con cambios sin guardar (Buscar en archivos).
    let findOverrides: () -> [URL: String]
    let onOpenMatch: (URL, Int, Int, Int) -> Void
    @State private var hoveredID: URL?
    @State private var renamingID: URL?
    /// Fila sobre la que se está arrastrando algo (resaltada como destino).
    @State private var dropTargetID: URL?
    @State private var expandedFolders: Set<URL> = []
    @State private var draftName: String = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("Esquema"), selection: $outline.sidebarTab) {
                Text(L("Archivos")).tag(SidebarTab.files)
                Text(L("Esquema")).tag(SidebarTab.outline)
                Text(L("Buscar")).tag(SidebarTab.search)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            switch outline.sidebarTab {
            case .files:
                filesPane
            case .outline:
                OutlineSectionView(outline: outline, statusBar: statusBar, onJumpToLine: onJumpToLine)
            case .search:
                FindInFilesView(model: findInFiles, root: fileTree.root?.url, overrides: findOverrides, onOpenMatch: onOpenMatch)
            }
        }
        // pendingRenameURL es la señal de Task 6 (crear archivo/carpeta nuevo) para
        // arrancar directo en modo rename en esa fila; se limpia acá una vez consumida.
        // Vive fuera de filesPane para no perderse si el sidebar está en la pestaña Esquema.
        .onChange(of: fileTree.pendingRenameURL) { pending in
            guard let pending else { return }
            outline.sidebarTab = .files
            beginRename(for: pending)
            fileTree.pendingRenameURL = nil
        }
    }

    @ViewBuilder
    private var filesPane: some View {
        if let root = fileTree.root {
            VStack(spacing: 0) {
                HStack {
                    Text(root.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        fileTree.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Refrescar"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                Divider()
                fileList(root: root)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(L("Abre una carpeta para navegar sus archivos"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    @ViewBuilder
    private func fileList(root: FileNode) -> some View {
            // Árbol plano propio en vez de OutlineGroup: en las filas de carpeta de
            // OutlineGroup (las que llevan el triángulo de despliegue) SwiftUI no entrega el
            // onDrop, así que no se podía soltar nada sobre una carpeta (bug de QA: aparecía
            // el "+" pero no se movía). Con filas planas cada carpeta es un destino normal.
            List {
                ForEach(visibleRows(root, depth: 0), id: \.node.id) { entry in
                    row(for: entry.node, isRoot: entry.node.id == root.id, depth: entry.depth)
                }
            }
            .listStyle(.sidebar)
    }

    /// Filas visibles en orden: la raíz siempre desplegada y cada carpeta según
    /// expandedFolders. `children` relee el disco, igual que con OutlineGroup.
    private func visibleRows(_ node: FileNode, depth: Int) -> [(node: FileNode, depth: Int)] {
        var rows = [(node: node, depth: depth)]
        guard depth == 0 || expandedFolders.contains(node.id) else { return rows }
        for child in node.children ?? [] {
            rows += visibleRows(child, depth: depth + 1)
        }
        return rows
    }

    private func toggleExpanded(_ url: URL) {
        if expandedFolders.contains(url) { expandedFolders.remove(url) } else { expandedFolders.insert(url) }
    }

    @ViewBuilder
    private func row(for node: FileNode, isRoot: Bool, depth: Int) -> some View {
        HStack(spacing: 4) {
            if depth > 1 {
                Spacer().frame(width: CGFloat(depth - 1) * 14)
            }
            if node.isDirectory && !isRoot {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expandedFolders.contains(node.id) ? 90 : 0))
                    .frame(width: 12)
            } else if depth > 0 {
                Spacer().frame(width: 12)
            }
            if renamingID == node.id {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($renameFieldFocused)
                    .onSubmit {
                        commitRename(for: node)
                    }
                    .onExitCommand {
                        cancelRename()
                    }
                    .onChange(of: renameFieldFocused) { focused in
                        // Perder el foco (click afuera, cambio de pestaña, etc.) cancela en
                        // vez de confirmar: coincide con el comportamiento de Finder y evita
                        // renombrar por accidente al alejar el foco sin querer.
                        if !focused, renamingID == node.id {
                            cancelRename()
                        }
                    }
            } else {
                Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            dropTargetID == node.id ? Color.accentColor.opacity(0.35)
                : hoveredID == node.id ? Color.accentColor.opacity(0.15) : Color.clear
        )
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: node.url as NSURL)
        }
        // Soltar sobre un archivo cuenta como soltar en su carpeta.
        .onDrop(of: [.fileURL], isTargeted: Binding(
            get: { dropTargetID == node.id },
            set: { targeted in
                dropTargetID = targeted ? node.id : (dropTargetID == node.id ? nil : dropTargetID)
            }
        )) { providers in
            handleDrop(providers, into: node.isDirectory ? node.url : node.url.deletingLastPathComponent())
        }
        .onHover { isHovering in
            hoveredID = isHovering ? node.id : (hoveredID == node.id ? nil : hoveredID)
        }
        .onTapGesture {
            // Mientras se edita el nombre, un tap no debe abrir el archivo — sería fácil
            // perder la edición en curso por un click apurado.
            guard renamingID == nil else { return }
            if node.isDirectory {
                if !isRoot { toggleExpanded(node.id) }
            } else {
                onOpenFile(node.url)
            }
        }
        .contextMenu {
            if node.isDirectory {
                Button(L("Nuevo archivo")) {
                    actions.newFile(in: node.url)
                }
                Button(L("Nueva carpeta")) {
                    actions.newFolder(in: node.url)
                }
                if !isRoot {
                    Button(L("Renombrar")) {
                        beginRename(for: node.url)
                    }
                    Button(L("Mover a…")) {
                        chooseMoveDestination(for: node.url)
                    }
                }
            } else {
                Button(L("Nuevo archivo aquí")) {
                    actions.newFile(in: node.url.deletingLastPathComponent())
                }
                Button(L("Renombrar")) {
                    beginRename(for: node.url)
                }
                Button(L("Mover a…")) {
                    chooseMoveDestination(for: node.url)
                }
            }
        }
    }

    /// Lo que viene de dentro del árbol se mueve; lo que viene de afuera (Finder) se copia,
    /// para no sacarle archivos a otra ubicación por un arrastre.
    private func handleDrop(_ providers: [NSItemProvider], into folder: URL) -> Bool {
        dropTargetID = nil
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: NSURL.self) }
        guard !fileProviders.isEmpty, let rootURL = fileTree.root?.url else { return false }
        let rootPrefix = rootURL.standardizedFileURL.path + "/"
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let source = (object as? NSURL) as URL? else { return }
                // Con un respiro y no en el mismo ciclo: mientras termina la sesión de
                // arrastre, NSAlert.runModal vuelve al instante y la alerta (destino inválido,
                // nombre ya existente) nunca se veía.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let isInternal = source.standardizedFileURL.path.hasPrefix(rootPrefix)
                    let result = isInternal ? onMove(source, folder) : onCopy(source, folder)
                    if result != nil { fileTree.refresh() }
                }
            }
        }
        return true
    }

    private func chooseMoveDestination(for url: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Mover aquí")
        panel.message = L("Mover \(url.lastPathComponent) a…")
        panel.directoryURL = fileTree.root?.url ?? url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        if onMove(url, folder) != nil { fileTree.refresh() }
    }

    private func beginRename(for url: URL) {
        // Un archivo/carpeta recién creado dentro de una carpeta plegada tiene que verse para
        // editar su nombre: se despliegan sus carpetas ancestro.
        if let rootPath = fileTree.root?.url.standardizedFileURL.path {
            var parent = url.deletingLastPathComponent()
            while parent.standardizedFileURL.path.hasPrefix(rootPath + "/") {
                expandedFolders.insert(parent)
                parent = parent.deletingLastPathComponent()
            }
        }
        renamingID = url
        // El campo edita el nombre completo, extensión incluida — igual que el renombrado
        // del menú Archivo (renameActive). Antes se sacaba la extensión acá y commitRename
        // la volvía a pegar sin mirar lo que el usuario haya escrito, así que cambiar la
        // extensión desde el árbol no tenía efecto (bug real reportado en QA manual: crear
        // "prueba.php" terminaba guardado como "prueba.php.txt").
        draftName = url.lastPathComponent
        renameFieldFocused = true
    }

    private func commitRename(for node: FileNode) {
        guard renamingID == node.id else { return }
        let fullName = draftName
        renamingID = nil
        let trimmedFull = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedURL = node.url
        if trimmedFull != node.name, !trimmedFull.isEmpty {
            // onRename devuelve nil si el move falló (nombre inválido, ya existe, etc.): el
            // archivo original sigue ahí sin tocar, así que resolvedURL se queda en node.url.
            if let renamed = onRename(node.url, fullName) {
                resolvedURL = renamed
            }
            fileTree.refresh()
        }
        openCreatedFileIfNeeded(originalURL: node.url, resolvedURL: resolvedURL)
    }

    private func cancelRename() {
        let cancelledURL = renamingID
        renamingID = nil
        if let cancelledURL {
            openCreatedFileIfNeeded(originalURL: cancelledURL, resolvedURL: cancelledURL)
        }
    }

    /// Si el rename que acaba de terminar (confirmado, sin cambios, o cancelado) era sobre el
    /// archivo recién creado por "Nuevo archivo" (Task 6), lo abre en una pestaña. Cancelar el
    /// rename no cancela la creación del archivo (mismo criterio que Finder), por eso este
    /// camino se recorre también desde cancelRename.
    private func openCreatedFileIfNeeded(originalURL: URL, resolvedURL: URL) {
        guard fileTree.createdFileAwaitingOpen == originalURL else { return }
        fileTree.createdFileAwaitingOpen = nil
        onOpenFile(resolvedURL)
    }
}

/// Pestaña "Esquema": títulos del documento Markdown activo, indentados por nivel, con la
/// sección que contiene al caret resaltada.
private struct OutlineSectionView: View {
    @ObservedObject var outline: OutlineViewModel
    @ObservedObject var statusBar: StatusBarViewModel
    let onJumpToLine: (Int) -> Void
    @State private var hoveredLine: Int?

    var body: some View {
        if outline.mode == .unsupported || outline.items.isEmpty {
            Text(emptyMessage)
                .foregroundStyle(.secondary)
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
        } else {
            let current = outline.currentIndex(forLine: statusBar.line - 1)
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(outline.items.enumerated()), id: \.element.id) { index, item in
                        row(item, isCurrent: index == current)
                            .id(item.id)
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: current) { newValue in
                    guard let newValue, outline.items.indices.contains(newValue) else { return }
                    proxy.scrollTo(outline.items[newValue].id)
                }
            }
        }
    }

    private var emptyMessage: String {
        switch outline.mode {
        case .markdown: return L("Sin títulos")
        case .code: return L("Sin funciones")
        case .unsupported: return L("Sin reglas de esquema para este lenguaje")
        }
    }

    private func row(_ item: OutlineItem, isCurrent: Bool) -> some View {
        Text(item.title)
            .font(item.level == 1 ? .body.weight(.semibold) : .body)
            .foregroundStyle(item.level > 2 ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, CGFloat(item.level - 1) * 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isCurrent ? Color.accentColor.opacity(0.25)
                          : hoveredLine == item.line ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                hoveredLine = hovering ? item.line : (hoveredLine == item.line ? nil : hoveredLine)
            }
            .onTapGesture { onJumpToLine(item.line) }
            .help(item.title)
    }
}
