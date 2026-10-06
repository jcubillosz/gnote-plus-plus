import AppKit
import SwiftUI

/// Split editor | vista previa con anchos calculados explícitamente por modo, en vez de
/// HSplitView. HSplitView (NSSplitView + un NSHostingView por pane) causaba dos bugs
/// reales de QA manual: (1) en solo-vista-previa el pane del editor conservaba su ancho
/// viejo aunque su contenido midiera 0, el split quedaba más ancho que la columna de
/// detalle y SwiftUI lo centraba desbordando por debajo del sidebar; (2) al salir de
/// solo-vista-previa NSSplitView redimensionaba los panes dentro del mismo pase de
/// constraints y los NSHostingView anidados pedían otro update → NSException
/// `_postWindowNeedsUpdateConstraints` y crash (confirmado con el .ips).
///
/// Ambos hijos están SIEMPRE en el árbol en la misma posición estructural: el oculto
/// queda con ancho 0, sin opacidad ni hit-testing. Así ni el ScintillaView compartido
/// ni el WKWebView de la preview se reparentan al cambiar de modo.
struct EditorPreviewSplit<Editor: View, Preview: View>: View {
    let mode: MarkdownPreviewViewModel.PreviewMode
    @ViewBuilder let editor: () -> Editor
    @ViewBuilder let preview: () -> Preview

    @AppStorage("preview.splitFraction") private var fraction: Double = 0.5
    /// Fracción al empezar el arrastre: DragGesture reporta traslación acumulada, no delta.
    @State private var dragStartFraction: Double?

    private static var minPaneWidth: CGFloat { 240 }
    private static var dividerHitWidth: CGFloat { 6 }

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let widths = paneWidths(total: total)
            HStack(spacing: 0) {
                editor()
                    .frame(width: widths.editor)
                    .clipped()
                    .opacity(widths.editor > 0 ? 1 : 0)
                    .allowsHitTesting(widths.editor > 0)

                divider(total: total)
                    .frame(width: mode == .split ? Self.dividerHitWidth : 0)
                    .opacity(mode == .split ? 1 : 0)
                    .allowsHitTesting(mode == .split)

                preview()
                    .frame(width: widths.preview)
                    .clipped()
                    .opacity(widths.preview > 0 ? 1 : 0)
                    .allowsHitTesting(widths.preview > 0)
            }
            .frame(width: total, height: geometry.size.height, alignment: .leading)
        }
        .clipped()
    }

    private func paneWidths(total: CGFloat) -> (editor: CGFloat, preview: CGFloat) {
        switch mode {
        case .editor:
            return (total, 0)
        case .preview:
            return (0, total)
        case .split:
            let available = max(0, total - Self.dividerHitWidth)
            let editorWidth = (available * clampedFraction(available: available)).rounded()
            return (editorWidth, available - editorWidth)
        }
    }

    /// Mínimo de 240pt por lado mientras entre; en ventanas más angostas que eso cae a
    /// la fracción pedida tal cual (nunca anchos negativos).
    private func clampedFraction(available: CGFloat) -> Double {
        guard available > Self.minPaneWidth * 2 else { return min(max(fraction, 0), 1) }
        let minFraction = Double(Self.minPaneWidth / available)
        return min(max(fraction, minFraction), 1 - minFraction)
    }

    private func divider(total: CGFloat) -> some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let available = max(1, total - Self.dividerHitWidth)
                    let start = dragStartFraction ?? clampedFraction(available: available)
                    if dragStartFraction == nil { dragStartFraction = start }
                    fraction = min(max(start + Double(value.translation.width / available), 0), 1)
                }
                .onEnded { _ in
                    let available = max(1, total - Self.dividerHitWidth)
                    fraction = clampedFraction(available: available)
                    dragStartFraction = nil
                }
        )
    }
}
