import SwiftUI
import Scintilla

// MARK: - Lógica pura

/// Cadena de símbolos que contienen a `caretLine`: cada ítem anterior o igual al caret entra
/// en la cadena y desplaza a los de nivel ≥ al suyo (un hermano o un tío cierra los anteriores).
func enclosingSymbols(items: [OutlineItem], caretLine: Int) -> [OutlineItem] {
    var chain: [OutlineItem] = []
    for item in items {
        guard item.line <= caretLine else { break }
        while let last = chain.last, last.level >= item.level { chain.removeLast() }
        chain.append(item)
    }
    return chain
}

/// Símbolos con el mismo padre y nivel que `item` (incluido él), en orden del documento.
func symbolSiblings(of item: OutlineItem, in items: [OutlineItem]) -> [OutlineItem] {
    guard let index = items.firstIndex(of: item) else { return [item] }
    var start = index
    while start > 0, items[start - 1].level >= item.level { start -= 1 }
    var end = index
    while end + 1 < items.count, items[end + 1].level >= item.level { end += 1 }
    return items[start...end].filter { $0.level == item.level }
}

/// Segmentos de ruta de `file` relativos a `root`; sin raíz o fuera de ella, solo el nombre.
func pathSegments(file: URL, root: URL?) -> [String] {
    let filePath = file.standardizedFileURL.path
    guard let root else { return [file.lastPathComponent] }
    let rootPath = root.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard filePath.hasPrefix(prefix) else { return [file.lastPathComponent] }
    return filePath.dropFirst(prefix.count).split(separator: "/").map(String.init)
}

// MARK: - Vista

/// Línea del caret para la barra, con debounce: `onSelectionChanged` llega en cada tecla y
/// en cada movimiento del cursor. Vive fuera de ContentView para que solo se redibuje la barra.
final class BreadcrumbCaret: ObservableObject {
    @Published private(set) var line = 0
    private var pending: DispatchWorkItem?

    func schedule(editor: ScintillaView) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.updateNow(editor: editor)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    func updateNow(editor: ScintillaView) {
        let pos = ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0)
        let newLine = Int(ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(max(pos, 0)), lParam: 0))
        if newLine != line { line = newLine }
    }
}

struct BreadcrumbBar: View {
    // Observados directo: anidados en TabsViewModel no reenvían cambios (ver CLAUDE.md).
    @ObservedObject var outline: OutlineViewModel
    @ObservedObject var caret: BreadcrumbCaret
    let file: URL?
    let fileName: String
    let root: URL?
    let onRevealFolder: (URL) -> Void
    let onJumpToLine: (Int) -> Void

    static let height: CGFloat = 22

    var body: some View {
        let chain = enclosingSymbols(items: outline.items, caretLine: caret.line)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(folders, id: \.url) { folder in
                    Button(folder.name) { onRevealFolder(folder.url) }
                        .buttonStyle(.borderless)
                        .help(folder.url.path)
                    separator
                }
                Menu {
                    ForEach(topLevelSymbols) { item in
                        Button(item.title) { onJumpToLine(item.line) }
                    }
                } label: {
                    Text(fileName).fontWeight(.medium)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(topLevelSymbols.isEmpty)
                ForEach(chain) { symbol in
                    separator
                    Menu {
                        ForEach(symbolSiblings(of: symbol, in: outline.items)) { item in
                            Button(item.title) { onJumpToLine(item.line) }
                        }
                    } label: {
                        Text(symbol.title)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var separator: some View {
        Text("›").foregroundStyle(.secondary)
    }

    /// Carpetas entre la raíz y el archivo, cada una con su URL para revelarla en el árbol.
    private var folders: [(name: String, url: URL)] {
        guard let file, let root else { return [] }
        let segments = pathSegments(file: file, root: root)
        guard segments.count > 1 else { return [] }
        var url = root
        return segments.dropLast().map { name in
            url = url.appendingPathComponent(name, isDirectory: true)
            return (name, url)
        }
    }

    /// Símbolos del nivel más externo: las reglas de functionList no siempre empiezan en 1.
    private var topLevelSymbols: [OutlineItem] {
        guard let minLevel = outline.items.map(\.level).min() else { return [] }
        return outline.items.filter { $0.level == minLevel }
    }
}
