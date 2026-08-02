import Foundation
import Scintilla

/// Estado publicado para la barra de estado inferior. Lo actualiza el Coordinator de
/// ScintillaEditorView (en cada SCN_UPDATEUI) y TabsViewModel (encoding, al cambiar de tab).
final class StatusBarViewModel: ObservableObject {
    @Published var line: Int = 1
    @Published var column: Int = 1
    @Published var selectionCharCount: Int = 0
    @Published var selectionLineCount: Int = 0
    @Published var encoding: String = "UTF-8"
    /// Por qué se eligió ese encoding, cuando la detección no fue directa. Se
    /// muestra como tooltip; nil cuando uchardet acertó sin ayuda.
    @Published var encodingNote: String?
    @Published var eol: String = EOLMode.lf.displayName
    weak var editorRef: ScintillaView?

    func reset() {
        line = 1
        column = 1
        selectionCharCount = 0
        selectionLineCount = 0
        // Sin esto la barra sigue mostrando el encoding y el EOL del último
        // archivo después de cerrar la última pestaña.
        encoding = "UTF-8"
        encodingNote = nil
        eol = EOLMode.lf.displayName
    }
}
