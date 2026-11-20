import SwiftUI
import Scintilla

// Editor de columna (Notepad++: Alt+C). Inserta texto o una secuencia numérica en cada
// fila de la selección rectangular / múltiple, o bajo el caret hasta el final del documento.

enum ColumnNumberFormat: CaseIterable {
    case dec, hex, oct, bin

    var radix: Int {
        switch self {
        case .dec: return 10
        case .hex: return 16
        case .oct: return 8
        case .bin: return 2
        }
    }

    var label: String {
        switch self {
        case .dec: return L("Decimal")
        case .hex: return L("Hexadecimal")
        case .oct: return L("Octal")
        case .bin: return L("Binario")
        }
    }
}

/// Secuencia para `count` filas: el valor sube `step` cada `repeatEach` filas. Todos salen del
/// mismo ancho (el del más largo, signo incluido); con ceros, el signo va antes del relleno.
/// nil si algún valor se sale de Int (los campos del diálogo aceptan cualquier entero y la
/// aritmética normal de Swift abortaría la app).
func columnNumbers(count: Int, start: Int, step: Int, repeatEach: Int, leadingZeros: Bool, format: ColumnNumberFormat) -> [String]? {
    guard count > 0 else { return [] }
    let each = max(1, repeatEach)
    var raw: [(negative: Bool, digits: String)] = []
    raw.reserveCapacity(count)
    for i in 0..<count {
        let offset = (i / each).multipliedReportingOverflow(by: step)
        guard !offset.overflow else { return nil }
        let value = start.addingReportingOverflow(offset.partialValue)
        guard !value.overflow else { return nil }
        raw.append((value.partialValue < 0, String(value.partialValue.magnitude, radix: format.radix, uppercase: true)))
    }
    let width = raw.map { ($0.negative ? 1 : 0) + $0.digits.count }.max() ?? 0
    return raw.map { item in
        let sign = item.negative ? "-" : ""
        let pad = width - sign.count - item.digits.count
        guard pad > 0 else { return sign + item.digits }
        return leadingZeros
            ? sign + String(repeating: "0", count: pad) + item.digits
            : String(repeating: " ", count: pad) + sign + item.digits
    }
}

private func colCall(_ editor: ScintillaView, _ message: UInt32, _ w: Int = 0, _ l: Int = 0) -> Int {
    Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(w), lParam: sptr_t(l)))
}

private func colInsert(_ editor: ScintillaView, at pos: Int, _ text: String) {
    guard !text.isEmpty else { return }
    text.withCString { cstr in
        _ = ScintillaView.directCall(editor, message: SCI_INSERTTEXT, wParam: uptr_t(pos), lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
    }
}

/// Cantidad de filas a rellenar con la selección actual (para calcular la secuencia numérica).
func columnInsertRowCount(editor: ScintillaView) -> Int {
    let mode = colCall(editor, SCI_GETSELECTIONMODE)
    let selections = colCall(editor, SCI_GETSELECTIONS)
    if mode == SC_SEL_RECTANGLE || mode == SC_SEL_THIN || selections > 1 { return selections }
    return columnLinesFromCaret(editor).count
}

/// Líneas desde la del caret hasta la última; la última vacía por terminar en EOL se omite
/// (como Notepad++), salvo que el caret esté justo ahí.
private func columnLinesFromCaret(_ editor: ScintillaView) -> [Int] {
    let caret = colCall(editor, SCI_GETCURRENTPOS)
    let first = colCall(editor, SCI_LINEFROMPOSITION, caret)
    var last = colCall(editor, SCI_GETLINECOUNT) - 1
    if last > first, colCall(editor, SCI_POSITIONFROMLINE, last) == colCall(editor, SCI_GETLENGTH) { last -= 1 }
    return Array(first...max(first, last))
}

/// `values(i)` = texto de la fila i. Una sola acción de deshacer.
func applyColumnInsert(editor: ScintillaView, values: (Int) -> String) {
    _ = colCall(editor, SCI_BEGINUNDOACTION)
    defer { _ = colCall(editor, SCI_ENDUNDOACTION) }

    let mode = colCall(editor, SCI_GETSELECTIONMODE)
    let selections = colCall(editor, SCI_GETSELECTIONS)
    if mode == SC_SEL_RECTANGLE || mode == SC_SEL_THIN || selections > 1 {
        struct Piece { var start: Int; var end: Int; var virtualSpace: Int }
        var pieces: [Piece] = (0..<selections).map { n in
            let start = colCall(editor, SCI_GETSELECTIONNSTART, n)
            let end = colCall(editor, SCI_GETSELECTIONNEND, n)
            // El espacio virtual solo importa en selecciones vacías (fila más corta que el rectángulo).
            let vs = start == end
                ? max(colCall(editor, SCI_GETSELECTIONNCARETVIRTUALSPACE, n), colCall(editor, SCI_GETSELECTIONNANCHORVIRTUALSPACE, n))
                : 0
            return Piece(start: start, end: end, virtualSpace: vs)
        }
        // Scintilla no garantiza orden de línea; de la última a la primera no corre posiciones.
        pieces.sort { $0.start < $1.start }
        for (i, piece) in pieces.enumerated().reversed() {
            let text = String(repeating: " ", count: piece.virtualSpace) + values(i)
            _ = colCall(editor, SCI_SETTARGETRANGE, piece.start, piece.end)
            text.withCString { cstr in
                _ = ScintillaView.directCall(editor, message: SCI_REPLACETARGET, wParam: uptr_t(strlen(cstr)), lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
            }
        }
        return
    }

    let caret = colCall(editor, SCI_GETCURRENTPOS)
    let column = colCall(editor, SCI_GETCOLUMN, caret)
    let lines = columnLinesFromCaret(editor)
    for (i, line) in lines.enumerated().reversed() {
        let pos = colCall(editor, SCI_FINDCOLUMN, line, column)
        // FINDCOLUMN devuelve el fin de línea si es más corta: se completa con espacios.
        let reached = colCall(editor, SCI_GETCOLUMN, pos)
        let pad = reached < column ? String(repeating: " ", count: column - reached) : ""
        colInsert(editor, at: pos, pad + values(i))
    }
}

private enum ColumnEditorKeys {
    static let mode = "columnEditor.mode"
    static let text = "columnEditor.text"
    static let start = "columnEditor.start"
    static let step = "columnEditor.step"
    static let repeatEach = "columnEditor.repeat"
    static let zeros = "columnEditor.zeros"
    static let format = "columnEditor.format"
}

struct ColumnEditorSheet: View {
    let editor: ScintillaView
    let onClose: () -> Void

    @AppStorage(ColumnEditorKeys.mode) private var numbersMode = false
    @AppStorage(ColumnEditorKeys.text) private var text = ""
    @AppStorage(ColumnEditorKeys.start) private var start = 1
    @AppStorage(ColumnEditorKeys.step) private var step = 1
    @AppStorage(ColumnEditorKeys.repeatEach) private var repeatEach = 1
    @AppStorage(ColumnEditorKeys.zeros) private var leadingZeros = false
    @AppStorage(ColumnEditorKeys.format) private var formatIndex = 0

    private var format: ColumnNumberFormat {
        let all = ColumnNumberFormat.allCases
        return all.indices.contains(formatIndex) ? all[formatIndex] : .dec
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $numbersMode) {
                Text(L("Texto")).tag(false)
                Text(L("Números")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if numbersMode {
                Form {
                    TextField(L("Número inicial"), value: $start, format: .number)
                    TextField(L("Incremento"), value: $step, format: .number)
                    TextField(L("Repetir"), value: $repeatEach, format: .number)
                    Toggle(L("Ceros a la izquierda"), isOn: $leadingZeros)
                    Picker(L("Formato"), selection: $formatIndex) {
                        ForEach(Array(ColumnNumberFormat.allCases.enumerated()), id: \.offset) { index, item in
                            Text(item.label).tag(index)
                        }
                    }
                }
            } else {
                TextField(L("Texto a insertar"), text: $text)
            }

            HStack {
                Spacer()
                Button(L("Cancelar"), role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Insertar")) { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func apply() {
        if numbersMode {
            let count = columnInsertRowCount(editor: editor)
            guard let numbers = columnNumbers(count: count, start: start, step: step, repeatEach: max(1, repeatEach), leadingZeros: leadingZeros, format: format) else {
                NSSound.beep()
                return
            }
            applyColumnInsert(editor: editor) { numbers.indices.contains($0) ? numbers[$0] : "" }
        } else {
            let value = text
            applyColumnInsert(editor: editor) { _ in value }
        }
        onClose()
    }
}
