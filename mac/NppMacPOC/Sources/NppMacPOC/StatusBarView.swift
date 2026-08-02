import SwiftUI

/// Barra fija debajo del editor: posición de cursor, selección (si hay), fin de
/// línea y encoding. Ver docs/superpowers/specs/2026-07-25-status-bar-design.md.
/// Tamaño de archivo y zoom quedan para una versión futura.
struct StatusBarView: View {
    @ObservedObject var statusBar: StatusBarViewModel

    var body: some View {
        HStack(spacing: 0) {
            Text(L("Ln \(statusBar.line), Col \(statusBar.column)"))
                .padding(.horizontal, 8)

            if statusBar.selectionCharCount > 0 {
                Divider()
                Text(L("Sel: \(statusBar.selectionCharCount) car, \(statusBar.selectionLineCount) líneas"))
                    .padding(.horizontal, 8)
            }

            Spacer()

            Divider()
            Text(statusBar.eol)
                .padding(.horizontal, 8)
                .help(L("Fin de línea del archivo"))

            Divider()
            Text(statusBar.encoding)
                .padding(.horizontal, 8)
                .help(statusBar.encodingNote ?? L("Codificación del archivo"))
        }
        .frame(height: 22)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .background(.bar)
    }
}
