import SwiftUI
import Scintilla

/// Barra Markdown grande (estilo Word): ícono de 20 pt con el nombre debajo y desplegables
/// propios (popover, no Menu) para poder mostrar muestras de cada formato.
struct MarkdownLargeFormatBar: View {
    @ObservedObject var tabs: TabsViewModel
    @ObservedObject var preferences: EditorPreferences
    @Environment(\.colorScheme) private var colorScheme
    @State private var open: Popup?

    enum Popup: Hashable { case heading, more, list, quote, table, diagram }

    private var locked: Bool { tabs.activeDocument?.isLocked == true }
    private var editor: ScintillaView { tabs.editor }

    var body: some View {
        HStack(spacing: 6) {
            // El scroll envuelve solo los botones: el de alternar queda siempre visible.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    popupButton(.heading, L("Título"), "textformat.size") { headingMenu }
                    action(L("Negrita"), "bold") { insertMarkdownBold(editor: editor) }
                    action(L("Cursiva"), "italic") { insertMarkdownItalic(editor: editor) }
                    popupButton(.more, L("Más formato"), "textformat") { moreMenu }
                    Divider().frame(height: 34).padding(.horizontal, 4)
                    popupButton(.list, L("Lista"), "list.bullet") { listMenu }
                    popupButton(.quote, L("Cita"), "text.quote") { quoteMenu }
                    Divider().frame(height: 34).padding(.horizontal, 4)
                    action(L("Enlace"), "link") { insertMarkdownLink(editor: editor) }
                    popupButton(.table, L("Tabla"), "tablecells") { TableGridPicker(pick: tablePicked, format: alignTable) }
                    action(L("Imagen"), "photo") { insertMarkdownImage(editor: editor, document: tabs.activeDocument) }
                    action(L("Código"), "chevron.left.forwardslash.chevron.right") { insertMarkdownCodeBlock(editor: editor) }
                    popupButton(.diagram, L("Diagrama"), "point.3.connected.trianglepath.dotted", disabledWhenLocked: false) {
                        VStack(alignment: .leading, spacing: 2) { DiagramActions(tabs: tabs, onPick: finish) }
                            .buttonStyle(.borderless).padding(8)
                    }
                }
                .padding(.horizontal, 2)
            }
            Button {
                preferences.markdownLargeToolbar = false
            } label: { Image(systemName: "rectangle.compress.vertical") }
            .buttonStyle(.borderless)
            .help(L("Barra compacta"))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: MarkdownFormatBar.height(large: true))
        // Closure, no `.background(.bar)`: ver el comentario de TabBarView sobre safe area.
        .background { Rectangle().fill(.bar) }
    }

    // MARK: Botones

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button { run(); refocus() } label: { LargeBarLabel(title: title, icon: icon, dropdown: false) }
            .buttonStyle(LargeBarButtonStyle())
            .disabled(locked)
    }

    private func popupButton<C: View>(_ popup: Popup, _ title: String, _ icon: String,
                                      disabledWhenLocked: Bool = true,
                                      @ViewBuilder content: @escaping () -> C) -> some View {
        Button { open = popup } label: { LargeBarLabel(title: title, icon: icon, dropdown: true) }
            .buttonStyle(LargeBarButtonStyle())
            .disabled(disabledWhenLocked && locked)
            .popover(isPresented: Binding(get: { open == popup }, set: { if !$0 && open == popup { open = nil } }),
                     arrowEdge: .bottom) { content() }
    }

    /// Cierra el popover y devuelve el foco al editor, que lo pierde al hacer clic en la barra.
    private func finish() { open = nil; refocus() }
    private func refocus() { editor.window?.makeFirstResponder(editor) }
    private func pick(_ run: () -> Void) { run(); finish() }

    private func tablePicked(_ columns: Int, _ rows: Int) {
        pick { insertMarkdownTable(columns: columns, rows: rows, editor: editor) }
    }

    private func alignTable(_ alignment: MarkdownEditing.Alignment?) {
        pick { if !MarkdownEditing.formatTable(editor: editor, align: alignment) { NSSound.beep() } }
    }

    // MARK: Desplegables

    private func row(_ run: @escaping () -> Void, @ViewBuilder _ label: () -> some View) -> some View {
        Button { pick(run) } label: {
            label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(PopupRowStyle())
    }

    private var headingMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(1...6, id: \.self) { level in
                row({ setMarkdownHeading(level: level, editor: editor) }) {
                    Text(L("Título \(level)")).font(.system(size: CGFloat(22 - level * 2), weight: level <= 2 ? .bold : .semibold))
                }
            }
            Divider().padding(.vertical, 4)
            row({ setMarkdownHeading(level: 0, editor: editor) }) { Text(L("Texto normal")) }
        }
        .padding(8).frame(width: 220)
    }

    private var moreMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            row({ insertMarkdownStrikethrough(editor: editor) }) { Text(L("Tachado")).strikethrough() }
            row({ insertMarkdownInlineCode(editor: editor) }) { Text(L("Código en línea")).font(.system(.body, design: .monospaced)) }
            row({ insertMarkdownTag("mark", editor: editor) }) {
                Text(L("Resaltado")).background(Color.yellow.opacity(0.5))
            }
            row({ insertMarkdownTag("kbd", editor: editor) }) {
                Text(L("Tecla")).font(.system(.callout, design: .monospaced)).padding(.horizontal, 5)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
            }
            row({ insertMarkdownTag("sub", editor: editor) }) {
                HStack(spacing: 0) { Text("H"); Text("2").font(.system(size: 9)).baselineOffset(-3); Text("  " + L("Subíndice")) }
            }
            row({ insertMarkdownTag("sup", editor: editor) }) {
                HStack(spacing: 0) { Text("x"); Text("2").font(.system(size: 9)).baselineOffset(5); Text("  " + L("Superíndice")) }
            }
        }
        .padding(8).frame(width: 220)
    }

    private var listMenu: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                listCard(L("Viñetas"), ["•  \(L("Uno"))", "•  \(L("Dos"))", "•  \(L("Tres"))"]) { insertMarkdownBulletList(editor: editor) }
                listCard(L("Numerada"), ["1.  \(L("Uno"))", "2.  \(L("Dos"))", "3.  \(L("Tres"))"]) { insertMarkdownNumberedList(editor: editor) }
                listCard(L("Tareas"), ["☑  \(L("Uno"))", "☐  \(L("Dos"))", "☐  \(L("Tres"))"]) { insertMarkdownChecklist(editor: editor) }
            }
            Divider()
            row({ toggleMarkdownTaskAtCaret(editor: editor) }) { Text(L("Marcar/desmarcar casilla")) }
        }
        .padding(10)
    }

    private func listCard(_ title: String, _ lines: [String], _ run: @escaping () -> Void) -> some View {
        Button { pick(run) } label: {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(lines, id: \.self) { Text($0).font(.system(size: 12)) }
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2)
            }
            .padding(8).frame(width: 84, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        }
        .buttonStyle(.plain)
    }

    private var quoteMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            row({ insertMarkdownBlockquote(editor: editor) }) { Text(L("Cita")) }
            row({ insertMarkdownHorizontalRule(editor: editor) }) { Text(L("Línea horizontal")) }
            row({ insertMarkdownDetails(editor: editor) }) { Text(L("Sección plegable")) }
            row({ insertMarkdownFootnote(editor: editor) }) { Text(L("Nota al pie")) }
            Divider().padding(.vertical, 4)
            alert("NOTE", L("Nota"), "0969da", "4493f8")
            alert("TIP", L("Consejo"), "1a7f37", "3fb950")
            alert("IMPORTANT", L("Importante"), "8250df", "ab7df8")
            alert("WARNING", L("Advertencia"), "9a6700", "d29922")
            alert("CAUTION", L("Precaución"), "d1242f", "f85149")
        }
        .padding(8).frame(width: 220)
    }

    /// Colores de `markdown-preview.css` (`--alert-color`, claro/oscuro): la muestra se ve igual que el preview.
    private func alert(_ kind: String, _ title: String, _ light: String, _ dark: String) -> some View {
        let color = Color(hex: colorScheme == .dark ? dark : light)
        return row({ insertMarkdownAlert(kind, editor: editor) }) {
            Text(title).fontWeight(.semibold).foregroundStyle(color)
                .padding(.vertical, 3).padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.14))
                .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        }
    }
}

// MARK: - Piezas

private extension Color {
    init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

private struct LargeBarLabel: View {
    let title: String
    let icon: String
    let dropdown: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 20)).frame(height: 24)
            HStack(spacing: 2) {
                Text(title).font(.system(size: 10)).lineLimit(1)
                if dropdown { Image(systemName: "chevron.down").font(.system(size: 6, weight: .bold)) }
            }
        }
        .frame(minWidth: 54, minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct LargeBarButtonStyle: ButtonStyle {
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover || configuration.isPressed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear)))
            .opacity(enabled ? 1 : 0.4)
            .onHover { hover = $0 }
    }
}

private struct PopupRowStyle: ButtonStyle {
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 4).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear)))
            .onHover { hover = $0 }
    }
}

/// Cuadrícula 8 × 6: al pasar el mouse resalta desde arriba a la izquierda hasta la celda.
private struct TableGridPicker: View {
    let pick: (Int, Int) -> Void
    let format: (MarkdownEditing.Alignment?) -> Void
    @State private var hover: (c: Int, r: Int)?

    static let columns = 8, rows = 6, cell: CGFloat = 20, gap: CGFloat = 3

    /// Posición del mouse -> (columnas, filas), o nil fuera de la cuadrícula.
    static func cellAt(_ p: CGPoint) -> (c: Int, r: Int)? {
        let step = cell + gap
        let c = Int(p.x / step) + 1, r = Int(p.y / step) + 1
        guard p.x >= 0, p.y >= 0, c <= columns, r <= rows else { return nil }
        return (c, r)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hover.map { L("\($0.c) columnas × \($0.r) filas") } ?? " ").font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(spacing: Self.gap) {
                ForEach(1...Self.rows, id: \.self) { r in
                    HStack(spacing: Self.gap) {
                        ForEach(1...Self.columns, id: \.self) { c in
                            let on = hover.map { c <= $0.c && r <= $0.r } ?? false
                            RoundedRectangle(cornerRadius: 3)
                                .fill(on ? AnyShapeStyle(Color.accentColor.opacity(0.55)) : AnyShapeStyle(.quaternary))
                                .frame(width: Self.cell, height: Self.cell)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = Self.cellAt(p)
                case .ended: hover = nil
                }
            }
            .onTapGesture { location in if let h = Self.cellAt(location) { pick(h.c, h.r) } }
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                tableRow(L("Formatear tabla"), nil)
                Divider().padding(.vertical, 3)
                tableRow(L("Alinear columna a la izquierda"), .left)
                tableRow(L("Centrar columna"), .center)
                tableRow(L("Alinear columna a la derecha"), .right)
                tableRow(L("Quitar alineación de columna"), MarkdownEditing.Alignment.none)
            }
        }
        .padding(10)
    }

    private func tableRow(_ title: String, _ a: MarkdownEditing.Alignment?) -> some View {
        Button { format(a) } label: {
            Text(title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(PopupRowStyle())
    }
}
