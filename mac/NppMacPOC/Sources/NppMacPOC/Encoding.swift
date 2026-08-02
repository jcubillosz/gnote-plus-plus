import Foundation
import CUchardet

/// Fin de línea del archivo. Los valores crudos son los de Scintilla (SC_EOL_*),
/// así que se pasan directo a SCI_SETEOLMODE sin traducir.
enum EOLMode: Int {
    case crlf = 0
    case cr = 1
    case lf = 2

    var displayName: String {
        switch self {
        case .crlf: return "CRLF"
        case .cr: return "CR"
        case .lf: return "LF"
        }
    }
}

/// Un archivo leído de disco, con todo lo necesario para volver a escribirlo igual.
struct DecodedFile {
    let text: String
    /// El encoding real, para round-trip al guardar. Separado de `encodingName`
    /// porque ese es para mostrar y a veces lleva una aclaración entre paréntesis.
    let encoding: String.Encoding
    let encodingName: String
    /// Aclaración sobre por qué se eligió este encoding, cuando la detección no
    /// fue directa. Se muestra como tooltip; nil si uchardet acertó sin ayuda.
    let note: String?
    let eol: EOLMode
}

// Detección de encoding vía uchardet real (PowerEditor/src/uchardet, portado sin cambios de lógica).
//
// Limitación conocida — el BOM no se maneja todavía:
//  - UTF-8 con BOM: Foundation no lo saca al decodificar, así que el U+FEFF queda
//    como un carácter editable en la posición 0 (Ln 1 Col 1 es en realidad la
//    columna 2) y se puede borrar sin querer. El round-trip de bytes igual da
//    igual porque al codificar se vuelve a emitir.
//  - UTF-16: Foundation sí saca el BOM al decodificar y agrega uno al codificar,
//    pero no preserva el endianness, así que un archivo UTF-16BE se guarda como
//    UTF-16LE. El contenido sobrevive; los bytes no.
// Resolverlo requiere guardar el BOM aparte del texto, y es su propio paso.
func decodeWithDetectedEncoding(_ data: Data) -> DecodedFile {
    let handle = uchardet_new()
    defer { uchardet_delete(handle) }

    data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
        guard let base = rawBuffer.bindMemory(to: CChar.self).baseAddress else { return }
        _ = uchardet_handle_data(handle, base, data.count)
    }
    uchardet_data_end(handle)

    let charsetName = String(cString: uchardet_get_charset(handle))

    guard !charsetName.isEmpty else {
        // uchardet no siempre puede clasificar muestras chicas o mayormente-ASCII con pocos bytes altos
        // (limitación estadística real del detector, no bug de integración). Antes de rendirnos:
        // preferimos UTF-8 si es válido, y si no, Latin-1 (decodifica cualquier byte sin corromper,
        // a diferencia de forzar UTF-8 con reemplazo por U+FFFD).
        if let utf8 = String(data: data, encoding: .utf8) {
            return decoded(utf8, .utf8, "UTF-8",
                           note: L("No se detectó un encoding específico, pero el contenido es UTF-8 válido."))
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return decoded(latin1, .isoLatin1, "ISO-8859-1",
                           note: L("No se detectó encoding y el contenido no era UTF-8 válido."))
        }
        return decoded(String(decoding: data, as: UTF8.self), .utf8, "UTF-8",
                       note: L("No se pudo determinar el encoding; se forzó UTF-8 reemplazando los bytes inválidos."))
    }

    let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charsetName as CFString)
    if cfEncoding != kCFStringEncodingInvalidId {
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        let encoding = String.Encoding(rawValue: nsEncoding)
        if let text = String(data: data, encoding: encoding) {
            return decoded(text, encoding, charsetName, note: nil)
        }
    }

    // Fallback si el mapeo IANA→String.Encoding falla o el decode no es válido para ese charset.
    if let utf8 = String(data: data, encoding: .utf8) {
        return decoded(utf8, .utf8, "UTF-8",
                       note: L("Se detectó \(charsetName), pero el contenido no decodificaba como tal; se usó UTF-8."))
    }
    return decoded(String(decoding: data, as: UTF8.self), .utf8, "UTF-8",
                   note: L("Se detectó \(charsetName), pero no se pudo decodificar; se forzó UTF-8 reemplazando los bytes inválidos."))
}

private func decoded(_ text: String, _ encoding: String.Encoding, _ name: String, note: String?) -> DecodedFile {
    DecodedFile(text: text, encoding: encoding, encodingName: name, note: note, eol: detectEOL(text))
}

/// Detecta el fin de línea por la PRIMERA aparición: un archivo de EOL mezclado
/// se trata como si fuera del tipo con el que empieza, que es lo que hace
/// Notepad++. No se convierte nada al abrir — convertir en silencio modificaría
/// el archivo sin que el usuario lo pida.
func detectEOL(_ text: String) -> EOLMode {
    let bytes = text.utf8
    var i = bytes.startIndex
    while i < bytes.endIndex {
        switch bytes[i] {
        case 0x0D: // CR, solo o seguido de LF
            let next = bytes.index(after: i)
            return (next < bytes.endIndex && bytes[next] == 0x0A) ? .crlf : .cr
        case 0x0A:
            return .lf
        default:
            i = bytes.index(after: i)
        }
    }
    // Archivo de una sola línea o vacío: LF, el default de macOS.
    return .lf
}
