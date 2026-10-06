import Foundation
import Scintilla

// Funciones de edición de Notepad++: historial de cambios en el margen (Preferencias →
// Márgenes → "Change History"), autocierre de paréntesis/comillas (Auto-Completion →
// "Auto-Insert") y recortar espacios finales al guardar (Edit → Blank Operations).

let SCI_SETCHANGEHISTORY: UInt32 = 2780
let SC_CHANGE_HISTORY_ENABLED: Int = 1
let SC_CHANGE_HISTORY_MARKERS: Int = 2
let SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN: Int = 21
let SC_MARKNUM_HISTORY_SAVED: Int = 22
let SC_MARKNUM_HISTORY_MODIFIED: Int = 23
let SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED: Int = 24
/// Margen 3, a la derecha del de plegado: la barra queda pegada al texto, como en VSCode.
let MARGIN_CHANGE_HISTORY: Int = 3
let SCI_INSERTTEXT: UInt32 = 2003
let SCI_DELETERANGE: UInt32 = 2645

private func call(_ editor: ScintillaView, _ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
    Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
}

// MARK: - Historial de cambios

func configureChangeHistoryMargin(_ editor: ScintillaView) {
    let historyMask = (SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN...SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED)
        .reduce(0) { $0 | (1 << $1) }
    _ = call(editor, SCI_SETMARGINTYPEN, MARGIN_CHANGE_HISTORY, SC_MARGIN_SYMBOL)
    _ = call(editor, SCI_SETMARGINMASKN, MARGIN_CHANGE_HISTORY, historyMask)
    // El margen 1 (números) trae de Scintilla la máscara ~SC_MASK_FOLDERS, que incluye los
    // markers del historial: sin esto pintaba un bloque naranja sobre los números de línea.
    _ = call(editor, SCI_SETMARGINMASKN, 1, 0)
    // Colores de Notepad++ (BGR): naranja = modificado sin guardar, verde = guardado,
    // celeste/amarillo = revertido por deshacer.
    let colors: [(Int, Int)] = [
        (SC_MARKNUM_HISTORY_MODIFIED, 0x0080FF),
        (SC_MARKNUM_HISTORY_SAVED, 0x00A000),
        (SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN, 0xC0A040),
        (SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED, 0x00C0C0),
    ]
    for (marker, color) in colors {
        _ = call(editor, SCI_MARKERSETFORE, marker, color)
        _ = call(editor, SCI_MARKERSETBACK, marker, color)
    }
}

/// Reinicia el historial del documento activo. Llamar justo después de SCI_EMPTYUNDOBUFFER:
/// Scintilla solo lo crea con el undo vacío (CellBuffer::ChangeHistorySet), y si ya existía
/// marcaría como "modificada" cada línea recién cargada. El historial vive en el documento,
/// así que cada pestaña conserva el suyo.
func resetChangeHistory(_ editor: ScintillaView) {
    _ = call(editor, SCI_SETCHANGEHISTORY, 0)
    _ = call(editor, SCI_SETCHANGEHISTORY, SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS)
}

// MARK: - Autocierre

enum AutoClose {
    private static let pairs: [Int: Int] = [
        Int(UInt8(ascii: "(")): Int(UInt8(ascii: ")")),
        Int(UInt8(ascii: "[")): Int(UInt8(ascii: "]")),
        Int(UInt8(ascii: "{")): Int(UInt8(ascii: "}")),
        Int(UInt8(ascii: "\"")): Int(UInt8(ascii: "\"")),
        Int(UInt8(ascii: "'")): Int(UInt8(ascii: "'")),
    ]
    private static let quotes: Set<Int> = [Int(UInt8(ascii: "\"")), Int(UInt8(ascii: "'"))]
    /// Cierres después de los cuales tiene sentido autocerrar ("f(|)" → "f((|))").
    private static let followers: Set<Int> = Set(")]},;:".utf8.map { Int($0) })

    /// Último cierre insertado automáticamente: escribir ese mismo carácter justo ahí lo
    /// "pisa" en vez de duplicarlo. Solo esos, no cualquier cierre que ya estuviera escrito.
    private static var pending: (document: Int, position: Int, character: Int)?

    /// Las comillas solo en código: en prosa el apóstrofo ("don't", "l'eau") es frecuente.
    static func charAdded(_ character: Int, editor: ScintillaView, isCode: Bool) {
        guard call(editor, SCI_GETSELECTIONS) == 1 else { return }
        let caret = call(editor, SCI_GETCURRENTPOS)
        let document = call(editor, SCI_GETDOCPOINTER)
        let next = call(editor, SCI_GETCHARAT, caret)

        if let pending, pending.document == document, pending.position == caret,
           pending.character == character, next == character {
            _ = call(editor, SCI_DELETERANGE, caret, 1)
            self.pending = nil
            return
        }
        pending = nil

        guard let closer = pairs[character] else { return }
        if quotes.contains(character) {
            guard isCode else { return }
            // Antes de la comilla: si hay una letra/dígito o la misma comilla, es un
            // apóstrofo o el cierre de un string, no una apertura.
            let previous = caret >= 2 ? call(editor, SCI_GETCHARAT, caret - 2) : 0
            if isWordByte(previous) || previous == character { return }
        }
        let nextIsFree = next == 0 || next == 0x20 || next == 0x09 || next == 0x0A || next == 0x0D
            || followers.contains(next)
        guard nextIsFree else { return }

        var text = [CChar(closer), 0]
        _ = text.withUnsafeMutableBufferPointer { buffer in
            ScintillaView.directCall(editor, message: SCI_INSERTTEXT, wParam: uptr_t(caret),
                                     lParam: sptr_t(bitPattern: UInt(bitPattern: buffer.baseAddress)))
        }
        pending = (document, caret, closer)
    }

    private static func isWordByte(_ byte: Int) -> Bool {
        // SCI_GETCHARAT devuelve char con signo: los bytes UTF-8 > 127 llegan negativos y
        // son parte de letras acentuadas.
        if byte < 0 || byte > 127 { return true }
        let scalar = Unicode.Scalar(UInt8(byte))
        return CharacterSet.alphanumerics.contains(scalar) || byte == Int(UInt8(ascii: "_"))
    }
}

// MARK: - Recortar espacios finales

/// Borra espacios y tabs al final de cada línea como una sola acción de deshacer.
func trimTrailingWhitespace(_ editor: ScintillaView) {
    let lineCount = call(editor, SCI_GETLINECOUNT)
    _ = call(editor, SCI_BEGINUNDOACTION)
    defer { _ = call(editor, SCI_ENDUNDOACTION) }
    // De abajo hacia arriba: borrar no corre las posiciones de las líneas que faltan.
    for line in stride(from: lineCount - 1, through: 0, by: -1) {
        let start = call(editor, SCI_POSITIONFROMLINE, line)
        let end = call(editor, SCI_GETLINEENDPOSITION, line)
        guard start >= 0, end > start else { continue }
        var trimFrom = end
        while trimFrom > start {
            let byte = call(editor, SCI_GETCHARAT, trimFrom - 1)
            guard byte == 0x20 || byte == 0x09 else { break }
            trimFrom -= 1
        }
        if trimFrom < end {
            _ = call(editor, SCI_DELETERANGE, trimFrom, end - trimFrom)
        }
    }
}
