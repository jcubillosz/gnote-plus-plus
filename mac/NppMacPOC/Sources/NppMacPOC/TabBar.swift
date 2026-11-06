import SwiftUI

struct TabBarView: View {
    @ObservedObject var tabs: TabsViewModel
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    /// Pestaña que las flechas ‹ › dejan pegada al borde izquierdo. SwiftUI no expone el
    /// offset de un ScrollView en macOS 13, así que se desplaza por pestañas con scrollTo.
    @State private var scrollAnchor = 0

    private var isOverflowing: Bool { contentWidth > viewportWidth + 1 }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                if isOverflowing {
                    arrowButton("chevron.left", help: L("Desplazar pestañas a la izquierda")) {
                        scroll(proxy, to: scrollAnchor - 1)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabs.documents.enumerated()), id: \.element.id) { index, document in
                            TabButton(
                                title: document.displayName,
                                fullPath: document.missingOnDisk
                                    ? "\(document.url?.path ?? document.displayName) — \(L("eliminado del disco"))"
                                    : document.url?.path ?? document.displayName,
                                isMissing: document.missingOnDisk,
                                isActive: index == tabs.activeIndex,
                                isDirty: document.isDirty,
                                onSelect: { tabs.activate(at: index) },
                                onClose: { tabs.close(at: index) },
                                onMiddleClick: { withIndex(of: document) { tabs.close(at: $0) } }
                            )
                            .id(document.id)
                            .contextMenu { tabContextMenu(for: document) }
                            .onDrag {
                                // Tipo privado solo dentro del proceso: con texto plano el
                                // editor aceptaba el drop e insertaba el UUID.
                                let provider = NSItemProvider()
                                provider.registerDataRepresentation(forTypeIdentifier: tabDragType, visibility: .ownProcess) {
                                    $0(Data(document.id.uuidString.utf8), nil); return nil
                                }
                                return provider
                            }
                            .onDrop(of: [tabDragType], delegate: TabDropDelegate(target: document, tabs: tabs))
                        }
                    }
                    .background { WidthReader { contentWidth = $0 } }
                }
                .background { WidthReader { viewportWidth = $0 } }
                if isOverflowing {
                    arrowButton("chevron.right", help: L("Desplazar pestañas a la derecha")) {
                        scroll(proxy, to: scrollAnchor + 1)
                    }
                    documentListMenu(proxy)
                }
            }
            // La pestaña activa siempre a la vista: al activar desde el menú, el árbol, un
            // atajo o al abrir un archivo nuevo (que entra al final, fuera de pantalla).
            .onChange(of: tabs.activeIndex) { _ in revealActive(proxy) }
            .onChange(of: tabs.documents.count) { _ in revealActive(proxy) }
            .onChange(of: isOverflowing) { _ in revealActive(proxy) }
        }
        .frame(height: TabBarView.height)
        .clipped()
        // Forma con closure, no `.background(.bar)`: la variante con ShapeStyle ignora la safe
        // area por defecto (ignoresSafeAreaEdges: .all) y, con la toolbar transparente de
        // macOS 26, pintaba hacia arriba hasta el borde de la ventana (bug intermitente de QA:
        // "el color de la pestaña activa se extiende hasta arriba").
        .background { Rectangle().fill(.bar) }
        .background { TabBarGeometryProbe() }
    }

    static let height: CGFloat = 32

    /// El índice se resuelve al ejecutar la acción: el menú puede quedar abierto mientras
    /// cambian las pestañas.
    @ViewBuilder
    private func tabContextMenu(for document: Document) -> some View {
        let url = document.url
        Button(L("Cerrar")) { withIndex(of: document) { tabs.close(at: $0) } }
        Button(L("Cerrar las demás")) { withIndex(of: document) { tabs.closeOthers(keeping: $0) } }
        Button(L("Cerrar las de la derecha")) { withIndex(of: document) { tabs.closeToTheRight(of: $0) } }
            .disabled(tabs.documents.last === document)
        Button(L("Cerrar todas")) { tabs.closeAll() }
        Divider()
        Button(L("Guardar")) {
            withIndex(of: document) {
                tabs.activate(at: $0)
                tabs.saveActive()
            }
        }
        Divider()
        Button(L("Copiar ruta completa")) { copyToPasteboard(url?.path) }
            .disabled(url == nil)
        Button(L("Copiar nombre del archivo")) { copyToPasteboard(document.displayName) }
        Button(L("Copiar ruta de la carpeta")) { copyToPasteboard(url?.deletingLastPathComponent().path) }
            .disabled(url == nil)
        Divider()
        Button(L("Mostrar en Finder")) {
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .disabled(url == nil)
        Button(L("Abrir carpeta en Terminal")) {
            guard let folder = url?.deletingLastPathComponent(),
                  let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            else { return }
            NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
        .disabled(url == nil)
    }

    private func withIndex(of document: Document, _ action: (Int) -> Void) {
        guard let index = tabs.documents.firstIndex(where: { $0 === document }) else { return }
        action(index)
    }

    private func copyToPasteboard(_ string: String?) {
        guard let string else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func arrowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: TabBarView.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Lista de todas las pestañas (Notepad++: "Lista de documentos"), para llegar a las
    /// que no entran en la barra.
    private func documentListMenu(_ proxy: ScrollViewProxy) -> some View {
        Menu {
            ForEach(Array(tabs.documents.enumerated()), id: \.element.id) { index, document in
                Button {
                    tabs.activate(at: index)
                    revealActive(proxy)
                } label: {
                    let name = document.isDirty ? "\(document.displayName) •" : document.displayName
                    if index == tabs.activeIndex {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .help(L("Todas las pestañas"))
    }

    private func scroll(_ proxy: ScrollViewProxy, to index: Int) {
        guard !tabs.documents.isEmpty else { return }
        scrollAnchor = min(max(index, 0), tabs.documents.count - 1)
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(tabs.documents[scrollAnchor].id, anchor: .leading)
        }
    }

    private func revealActive(_ proxy: ScrollViewProxy) {
        guard let index = tabs.activeIndex, tabs.documents.indices.contains(index) else { return }
        scrollAnchor = index
        // Diferido: tras abrir un documento la pestaña nueva todavía no tiene layout.
        DispatchQueue.main.async {
            guard tabs.documents.indices.contains(index) else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(tabs.documents[index].id)
            }
        }
    }
}

/// Mide el ancho de la vista a la que se pone de fondo. Con onAppear/onChange y no con
/// PreferenceKey: una preferencia emitida dentro del ScrollView horizontal no llegaba al
/// onPreferenceChange de afuera (los anchos quedaban en 0 y las flechas nunca aparecían).
private struct WidthReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.size.width) }
                .onChange(of: proxy.size.width) { onChange($0) }
        }
    }
}

/// Diagnóstico temporal del bug intermitente de la barra de pestañas (no reproducible a
/// demanda): si la barra deja de medir su alto fijo o se desplaza verticalmente respecto de
/// la primera medición, lo deja en stderr (correr el binario directo para verlo). Quitar
/// cuando se identifique la causa.
private struct TabBarGeometryProbe: View {
    @State private var initialMinY: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear
                .onAppear { initialMinY = frame.minY }
                .onChange(of: frame) { newFrame in
                    let shifted = initialMinY.map { abs($0 - newFrame.minY) > 0.5 } ?? false
                    guard shifted || abs(newFrame.height - TabBarView.height) > 0.5 else { return }
                    let message = "[DEBUG-TABBAR] frame=\(newFrame) initialMinY=\(initialMinY ?? -1) window=\(NSApp.keyWindow?.frame ?? .zero)\n"
                    FileHandle.standardError.write(message.data(using: .utf8)!)
                }
        }
    }
}

private struct TabButton: View {
    let title: String
    let fullPath: String
    /// El archivo ya no existe en disco (borrado o movido por otro programa).
    let isMissing: Bool
    let isActive: Bool
    let isDirty: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onMiddleClick: () -> Void

    @State private var isCloseHovering: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 12))
                .italic(isMissing)
                .strikethrough(isMissing)
                .foregroundStyle(isMissing ? .secondary : .primary)
                .frame(maxWidth: 180)
            if isDirty {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(isCloseHovering ? Color.primary.opacity(0.1) : Color.clear)
            .clipShape(Circle())
            .onHover { isCloseHovering = $0 }
        }
        .padding(.horizontal, 10)
        .frame(height: TabBarView.height)
        // Closure, no `.background(Color)`: ver el comentario de la barra sobre safe area.
        .background { Rectangle().fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear) }
        .contentShape(Rectangle())
        .help(fullPath)
        .onTapGesture(perform: onSelect)
        .background { MiddleClickCatcher(action: onMiddleClick) }
    }
}

private let tabDragType = "cl.jcubillos.gnotepp.tab"

/// Reordena al soltar sobre otra pestaña. El origen se resuelve por el UUID del payload y los
/// índices por identidad al soltar; soltar sobre sí misma o fuera no hace nada. Se usa el
/// identificador como String (sin UTType exportado) para no depender del Info.plist.
private struct TabDropDelegate: DropDelegate {
    let target: Document
    let tabs: TabsViewModel

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [tabDragType]) }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [tabDragType]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: tabDragType) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async {
                guard let from = tabs.documents.firstIndex(where: { $0.id == id }),
                      let to = tabs.documents.firstIndex(where: { $0 === target }), from != to else { return }
                tabs.moveDocument(from: from, to: to)
            }
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

/// Clic del medio para cerrar. macOS 13 no tiene gesto de botón central en SwiftUI; un monitor
/// local de otherMouseDown acotado a los límites de esta vista (que va de fondo) no interfiere
/// con clic, arrastre ni tooltips de la pestaña.
private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                guard let self, event.window === self.window, event.buttonNumber == 2,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.action?()
                return nil
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}
