import SwiftUI

/// Barra de formato de Markdown: fila propia sobre las pestañas (antes iba en la toolbar
/// de la ventana, que ya no daba abasto). Solo aparece con un documento Markdown activo.
struct MarkdownFormatBar: View {
    @ObservedObject var tabs: TabsViewModel

    var body: some View {
        HStack(spacing: 4) {
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
                Label(L("Formato"), systemImage: "textformat.size")
            }
            .help(L("Insertar título"))
            .disabled(tabs.activeDocument?.isLocked == true)

            Menu {
                Button(L("Lista con viñeta")) { insertMarkdownBulletList(editor: tabs.editor) }
                Button(L("Lista numerada")) { insertMarkdownNumberedList(editor: tabs.editor) }
                Divider()
                Button(L("Insertar casilla de verificación")) { insertMarkdownChecklist(editor: tabs.editor) }
                Button(L("Marcar/desmarcar casilla")) { toggleMarkdownTaskAtCaret(editor: tabs.editor) }
            } label: {
                Label(L("Listas"), systemImage: "list.bullet")
            }
            .help(L("Insertar lista o casilla"))
            .disabled(tabs.activeDocument?.isLocked == true)

            Menu {
                Button(L("Cita")) { insertMarkdownBlockquote(editor: tabs.editor) }
                Button(L("Código en línea")) { insertMarkdownInlineCode(editor: tabs.editor) }
                Button(L("Bloque de código")) { insertMarkdownCodeBlock(editor: tabs.editor) }
                Divider()
                Button(L("Nota")) { insertMarkdownAlert("NOTE", editor: tabs.editor) }
                Button(L("Consejo")) { insertMarkdownAlert("TIP", editor: tabs.editor) }
                Button(L("Importante")) { insertMarkdownAlert("IMPORTANT", editor: tabs.editor) }
                Button(L("Advertencia")) { insertMarkdownAlert("WARNING", editor: tabs.editor) }
                Button(L("Precaución")) { insertMarkdownAlert("CAUTION", editor: tabs.editor) }
            } label: {
                Label(L("Citas y alertas"), systemImage: "text.quote")
            }
            .help(L("Insertar cita, código o alerta"))
            .disabled(tabs.activeDocument?.isLocked == true)

            Menu {
                Button(L("Insertar tabla")) { insertMarkdownTable(editor: tabs.editor) }
                Button(L("Formatear tabla Markdown")) {
                    if !MarkdownEditing.formatTable(editor: tabs.editor) { NSSound.beep() }
                }
                Divider()
                Button(L("Alinear columna a la izquierda")) { alignTableColumn(.left) }
                Button(L("Centrar columna")) { alignTableColumn(.center) }
                Button(L("Alinear columna a la derecha")) { alignTableColumn(.right) }
                Button(L("Quitar alineación de columna")) { alignTableColumn(.none) }
            } label: { Label(L("Tabla"), systemImage: "tablecells") }
            .help(L("Tabla"))
            .disabled(tabs.activeDocument?.isLocked == true)

            Button {
                insertMarkdownImage(editor: tabs.editor, document: tabs.activeDocument)
            } label: { Label(L("Imagen"), systemImage: "photo") }
            .help(L("Insertar imagen"))
            .disabled(tabs.activeDocument?.isLocked == true)

            Button {
                insertMarkdownCodeBlock(editor: tabs.editor)
            } label: { Label(L("Código"), systemImage: "chevron.left.forwardslash.chevron.right") }
            .help(L("Insertar bloque de código"))
            .disabled(tabs.activeDocument?.isLocked == true)

            Menu {
                ForEach(MermaidTemplates.all) { template in
                    Button(template.title) { MermaidTemplates.insert(template, editor: tabs.editor) }
                        .disabled(tabs.activeDocument?.isLocked == true)
                }
                Divider()
                Button(L("Guardar diagrama como PNG…")) { MermaidExport.save(.png, editor: tabs.editor, document: tabs.activeDocument) }
                Button(L("Guardar diagrama como SVG…")) { MermaidExport.save(.svg, editor: tabs.editor, document: tabs.activeDocument) }
                Button(L("Copiar diagrama como imagen")) { MermaidExport.copyImage(editor: tabs.editor) }
            } label: { Label(L("Diagramas"), systemImage: "point.3.connected.trianglepath.dotted") }
            .help(L("Insertar o exportar diagrama Mermaid"))
                        Spacer(minLength: 0)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .labelStyle(.titleAndIcon)
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .frame(height: MarkdownFormatBar.height)
        // Closure, no `.background(.bar)`: ver el comentario de TabBarView sobre safe area.
        .background { Rectangle().fill(.bar) }
    }

    static let height: CGFloat = 30

    private func alignTableColumn(_ alignment: MarkdownEditing.Alignment) {
        if !MarkdownEditing.formatTable(editor: tabs.editor, align: alignment) { NSSound.beep() }
    }
}
