import AppKit
import Scintilla

extension TabsViewModel {
    /// Vuelve a leer los .editorconfig del documento si cambió su ruta o el mtime/tamaño de alguna
    /// fuente. Sin esto, activar una pestaña recorrería el disco cada vez.
    func refreshEditorConfig(of document: Document, force: Bool = false) {
        guard let url = document.url else {
            document.editorConfig = nil
            document.editorConfigSources = []
            document.editorConfigStamps = []
            document.editorConfigResolvedURL = nil
            return
        }
        if !force, document.editorConfigResolvedURL == url,
           document.editorConfigSources.map({ FileStamp.of($0) }) == document.editorConfigStamps {
            return
        }
        let loaded = loadEditorConfig(for: url)
        document.editorConfig = loaded.props.isEmpty ? nil : loaded.props
        document.editorConfigSources = loaded.sources
        document.editorConfigStamps = loaded.sources.map { FileStamp.of($0) }
        document.editorConfigResolvedURL = url
    }

    /// Modo de EOL de Scintilla: el de .editorconfig si lo define, si no el del archivo. Solo
    /// afecta líneas nuevas; nunca se convierte el contenido existente al abrir.
    func editorConfigEOLMode(for document: Document) -> EOLMode {
        switch document.editorConfig?.endOfLine {
        case "crlf": return .crlf
        case "cr": return .cr
        case "lf": return .lf
        default: return document.eol
        }
    }

    func editorConfigTooltip(of document: Document) -> String? {
        guard !document.editorConfigSources.isEmpty else { return nil }
        let props = document.editorConfig?.summary ?? []
        let files = document.editorConfigSources.map { $0.path }
        return (props + [""] + files).joined(separator: "\n")
    }

    /// Reaplica tabs/indentación/EOL del documento activo tras cambiar su ruta (Guardar como).
    func reapplyEditorConfigToActive() {
        guard let document = activeDocument else { return }
        refreshEditorConfig(of: document, force: true)
        preferences.activeEditorConfig = document.editorConfig
        preferences.applyEditingOptions(to: editor)
        _ = ScintillaView.directCall(editor, message: SCI_SETEOLMODE, wParam: uptr_t(editorConfigEOLMode(for: document).rawValue), lParam: 0)
        publishFileInfo(of: document)
    }

    /// `charset` de .editorconfig solo si coincide con una codificación que la app ya maneja.
    static func encoding(forEditorConfigCharset charset: String) -> (String.Encoding, String)? {
        switch charset {
        case "utf-8": return (.utf8, "UTF-8")
        case "latin1": return (.isoLatin1, "ISO-8859-1")
        case "utf-16le": return (.utf16LittleEndian, "UTF-16 LE")
        case "utf-16be": return (.utf16BigEndian, "UTF-16 BE")
        default: return nil
        }
    }

    /// Agrega el EOL del documento al final si falta; va dentro de la acción de deshacer del llamador.
    func ensureFinalNewline() {
        let length = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
        guard length > 0 else { return }
        let last = ScintillaView.directCall(editor, message: SCI_GETCHARAT, wParam: uptr_t(length - 1), lParam: 0)
        guard last != 0x0A && last != 0x0D else { return }
        let mode = Int(ScintillaView.directCall(editor, message: SCI_GETEOLMODE, wParam: 0, lParam: 0))
        let eol = mode == EOLMode.crlf.rawValue ? "\r\n" : mode == EOLMode.cr.rawValue ? "\r" : "\n"
        eol.withCString { cstr in
            _ = ScintillaView.directCall(editor, message: SCI_APPENDTEXT, wParam: uptr_t(eol.utf8.count), lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
        }
    }
}
