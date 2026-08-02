import SwiftUI

struct SidebarView: View {
    @ObservedObject var fileTree: FileTreeViewModel
    let onOpenFile: (URL) -> Void
    @State private var hoveredID: URL?

    var body: some View {
        if let root = fileTree.root {
            List {
                OutlineGroup(root, children: \.children) { node in
                    Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(hoveredID == node.id ? Color.accentColor.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            hoveredID = isHovering ? node.id : (hoveredID == node.id ? nil : hoveredID)
                        }
                        .onTapGesture {
                            if !node.isDirectory {
                                onOpenFile(node.url)
                            }
                        }
                }
            }
            .listStyle(.sidebar)
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
}
