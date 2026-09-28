import SwiftUI

struct SidebarView: View {
    @ObservedObject var fileTree: FileTreeViewModel
    let actions: DocumentActions
    let onOpenFile: (URL) -> Void
    /// Confirma un rename inline: URL vieja + nombre nuevo. Devuelve la URL destino si el
    /// rename se hizo, o nil si falló/se canceló (el llamador ya mostró el error). El
    /// Sidebar refresca el árbol después de invocarlo.
    let onRename: (URL, String) -> URL?
    @State private var hoveredID: URL?
    @State private var renamingID: URL?
    @State private var draftName: String = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
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
            // pendingRenameURL es la señal de Task 6 (crear archivo/carpeta nuevo) para
            // arrancar directo en modo rename en esa fila; se limpia acá una vez consumida.
            .onChange(of: fileTree.pendingRenameURL) { pending in
                guard let pending else { return }
                beginRename(for: pending)
                fileTree.pendingRenameURL = nil
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
            List {
                OutlineGroup(root, children: \.children) { node in
                    row(for: node, isRoot: node.id == root.id)
                }
            }
            .listStyle(.sidebar)
    }

    @ViewBuilder
    private func row(for node: FileNode, isRoot: Bool) -> some View {
        HStack {
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
        .background(hoveredID == node.id ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredID = isHovering ? node.id : (hoveredID == node.id ? nil : hoveredID)
        }
        .onTapGesture {
            // Mientras se edita el nombre, un tap no debe abrir el archivo — sería fácil
            // perder la edición en curso por un click apurado.
            guard renamingID == nil else { return }
            if !node.isDirectory {
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
                }
            } else {
                Button(L("Nuevo archivo aquí")) {
                    actions.newFile(in: node.url.deletingLastPathComponent())
                }
                Button(L("Renombrar")) {
                    beginRename(for: node.url)
                }
            }
        }
    }

    private func beginRename(for url: URL) {
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
