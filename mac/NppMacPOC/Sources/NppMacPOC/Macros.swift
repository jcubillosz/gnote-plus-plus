// Macros: grabar con SCI_STARTRECORD/SCN_MACRORECORD, reproducir con directCall, guardar con
// nombre en <carpeta de datos>/macros.json.
import AppKit
import Scintilla

/// Un paso grabado. `text` copia el string de lParam en el momento (el puntero que manda
/// Scintilla no vive después de la notificación). `typedChar` marca un carácter escrito con el
/// teclado: al reproducirlo se re-dispara el mismo manejador de SCN_CHARADDED, porque
/// SCI_REPLACESEL no lo dispara.
struct MacroStep: Codable, Equatable {
    let message: UInt32
    let wParam: Int
    let text: String?
    let typedChar: Int?
}

struct SavedMacro: Codable, Identifiable {
    var id: UUID
    var name: String
    var steps: [MacroStep]
}

final class MacroRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// Última macro grabada (persiste entre aperturas).
    @Published private(set) var current: [MacroStep] = []
    @Published private(set) var saved: [SavedMacro] = []
    /// Lo que hacen las funciones propias dentro de SCN_CHARADDED (autocierre, autoindentación,
    /// listas, sobretipeo) no se graba: se reproduce re-disparando el manejador (ver typedChar).
    private var suppressDepth = 0
    private(set) var isPlaying = false
    /// Los pasos se juntan acá y se publican en `current` al detener: publicar en cada tecla
    /// re-evaluaría todos los menús (AppCommands observa este objeto).
    private var buffer: [MacroStep] = []
    /// Último SCN_CHARADDED sin consumir. Scintilla solo notifica SCI_REPLACESEL propios desde
    /// InsertCharacter y NewLine, y ambos llaman antes a NotifyChar (Editor.cxx); un REPLACESEL
    /// sin este carácter delante viene de un comando de GNote++ (negrita, fecha…) que además
    /// mueve la selección con mensajes que no se notifican, así que no se graba.
    private var pendingTypedChar: Int?

    static let maxIterations = 100_000

    private static var fileURL: URL { appDataDirectory().appendingPathComponent("macros.json") }

    private struct MacroFile: Codable {
        var current: [MacroStep]
        var saved: [SavedMacro]
    }

    init() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let file = try? JSONDecoder().decode(MacroFile.self, from: data) else { return }
        current = file.current
        saved = file.saved
    }

    // MARK: - Lógica pura

    /// Lo que depende de una posición absoluta del documento no se graba: reproducido en otro
    /// lugar insertaría o saltaría a la posición vieja. CLEARALL/ADDTEXT/APPENDTEXT nunca salen
    /// de la entrada del usuario, solo de código (loadText al abrir o recargar un archivo mientras
    /// se graba): reproducidos borrarían el documento actual.
    static func isRecordable(_ message: UInt32) -> Bool {
        ![SCI_INSERTTEXT, SCI_GOTOPOS, SCI_GOTOLINE, SCI_SEARCHANCHOR, SCI_SEARCHNEXT, SCI_SEARCHPREV,
          SCI_CLEARALL, SCI_ADDTEXT, SCI_APPENDTEXT]
            .contains(message)
    }

    /// "Hasta el final del archivo": seguir solo si el caret avanzó (si no, sería un bucle
    /// infinito), no llegó al final y no se pasó del tope.
    static func shouldContinueToEnd(previousPos: Int, newPos: Int, docLength: Int, iterations: Int) -> Bool {
        iterations < maxIterations && newPos > previousPos && newPos < docLength
    }

    // MARK: - Grabación

    func start(editor: ScintillaView) {
        guard !isRecording, !isPlaying else { return }
        buffer = []
        isRecording = true
        // Una lista de autocompletado abierta cambia lo que hacen Enter/flechas y aceptarla no
        // pasa por WndProc: no grabaría lo que se ve.
        _ = ScintillaView.directCall(editor, message: SCI_AUTOCCANCEL, wParam: 0, lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_STARTRECORD, wParam: 0, lParam: 0)
    }

    func stop(editor: ScintillaView) {
        guard isRecording else { return }
        _ = ScintillaView.directCall(editor, message: SCI_STOPRECORD, wParam: 0, lParam: 0)
        isRecording = false
        // Detener sin haber grabado nada no borra la última macro.
        if !buffer.isEmpty {
            current = buffer
            persist()
        }
        buffer = []
    }

    func suppressing<T>(_ body: () -> T) -> T {
        suppressDepth += 1
        defer { suppressDepth -= 1 }
        return body()
    }

    /// Llamar en SCN_CHARADDED, antes del manejador (que corre suprimido).
    func noteCharAdded(_ character: Int) {
        guard isRecording else { return }
        pendingTypedChar = character
        // Si no llega el REPLACESEL (entrada tentativa de un IME), que no quede para un
        // REPLACESEL posterior de un comando: la grabación real ocurre en esta misma pila.
        DispatchQueue.main.async { [weak self] in self?.pendingTypedChar = nil }
    }

    /// Carácter tecleado que corresponde a un REPLACESEL: solo si es un único escalar igual al
    /// último SCN_CHARADDED.
    static func typedCharacter(text: String, pending: Int?) -> Int? {
        guard let pending, text.unicodeScalars.count == 1,
              Int(text.unicodeScalars.first!.value) == pending else { return nil }
        return pending
    }

    func record(message: UInt32, wParam: Int, lParam: Int) {
        guard isRecording, suppressDepth == 0, Self.isRecordable(message) else { return }
        let pending = pendingTypedChar
        pendingTypedChar = nil
        var text: String?
        var typedChar: Int?
        switch message {
        case SCI_REPLACESEL:
            guard let pointer = UnsafePointer<CChar>(bitPattern: lParam) else { return }
            let replaced = String(cString: pointer)
            guard let typed = Self.typedCharacter(text: replaced, pending: pending) else { return }
            text = replaced
            typedChar = typed
        default:
            break
        }
        buffer.append(MacroStep(message: message, wParam: wParam, text: text, typedChar: typedChar))
    }

    // MARK: - Reproducción

    /// `times == nil` = hasta el final del archivo. Todas las repeticiones son una sola acción
    /// de deshacer.
    func play(_ steps: [MacroStep], editor: ScintillaView, times: Int?, charAdded: (Int) -> Void) {
        guard !steps.isEmpty, !isRecording, !isPlaying else { return }
        isPlaying = true
        defer { isPlaying = false }
        func call(_ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
            Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: lParam))
        }
        // Con una lista de autocompletado abierta, Enter/flechas reproducidos la manejarían a ella.
        _ = call(SCI_AUTOCCANCEL)
        func runOnce() {
            for step in steps {
                if let text = step.text {
                    text.withCString { cstr in
                        _ = call(step.message, step.wParam, sptr_t(bitPattern: UInt(bitPattern: cstr)))
                    }
                } else {
                    _ = call(step.message, step.wParam)
                }
                if let typed = step.typedChar { charAdded(typed) }
            }
        }
        suppressing {
            _ = call(SCI_BEGINUNDOACTION)
            defer { _ = call(SCI_ENDUNDOACTION) }
            if let times {
                for _ in 0..<min(max(0, times), Self.maxIterations) { runOnce() }
            } else {
                var iterations = 0
                while true {
                    let before = call(SCI_GETCURRENTPOS)
                    runOnce()
                    iterations += 1
                    if !Self.shouldContinueToEnd(previousPos: before, newPos: call(SCI_GETCURRENTPOS),
                                                 docLength: call(SCI_GETLENGTH), iterations: iterations) { break }
                }
            }
        }
    }

    // MARK: - Macros guardadas

    /// Un nombre repetido reemplaza los pasos de la macro existente.
    func save(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !current.isEmpty else { return }
        if let index = saved.firstIndex(where: { $0.name == trimmed }) {
            saved[index].steps = current
        } else {
            saved.append(SavedMacro(id: UUID(), name: trimmed, steps: current))
        }
        persist()
    }

    func delete(id: UUID) {
        saved.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(MacroFile(current: current, saved: saved)) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

extension TabsViewModel {
    /// Manejador de SCN_CHARADDED, compartido por el editor (ContentView) y la reproducción de
    /// macros: así un carácter reproducido produce lo mismo que al grabarlo.
    func handleCharAdded(_ character: Int) {
        guard let document = activeDocument, !document.isLocked else { return }
        let lexer = document.languageProfile.lexerName
        if lexer == "markdown" {
            MarkdownEditing.charAdded(character, editor: editor)
        }
        if preferences.autoIndent && lexer != "markdown" {
            AutoIndent.charAdded(character, editor: editor, lexerName: lexer, tabWidth: preferences.tabWidth)
        }
        if preferences.autoCloseBrackets {
            AutoClose.charAdded(character, editor: editor, isCode: AutoComplete.isEnabled(for: document.languageProfile))
            autoCloseTag(character: character, lexerName: lexer)
        }
        // Sin autocompletado al grabar ni al reproducir: aceptar una sugerencia no pasa por
        // WndProc (no se graba) y una lista abierta al reproducir cambia lo que hace Enter.
        guard preferences.autoComplete, !macros.isRecording, !macros.isPlaying,
              AutoComplete.isEnabled(for: document.languageProfile) else { return }
        AutoComplete.charAdded(character, editor: editor, document: document)
    }

    var canPlayMacro: Bool {
        activeIndex != nil && activeDocument?.isLocked != true && !macros.isRecording
    }

    func playMacro(_ steps: [MacroStep], times: Int?) {
        guard canPlayMacro else { return }
        macros.play(steps, editor: editor, times: times) { handleCharAdded($0) }
    }
}

/// "Reproducir varias veces…": N veces o hasta el final del archivo.
func playMacroMultipleTimesDialog(tabs: TabsViewModel) {
    let field = NSTextField(string: "1")
    let toEnd = NSButton(checkboxWithTitle: L("Hasta el final del archivo"), target: nil, action: nil)
    let stack = NSStackView(views: [field, toEnd])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 220, height: 52)
    field.frame.size.width = 220

    let alert = NSAlert()
    alert.messageText = L("Reproducir varias veces")
    alert.informativeText = L("Cantidad de repeticiones")
    alert.addButton(withTitle: L("OK"))
    alert.addButton(withTitle: L("Cancelar"))
    alert.accessoryView = stack
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    if toEnd.state == .on {
        tabs.playMacro(tabs.macros.current, times: nil)
    } else if let times = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), times > 0 {
        tabs.playMacro(tabs.macros.current, times: times)
    } else {
        NSSound.beep()
    }
}

func saveCurrentMacroDialog(macros: MacroRecorder) {
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    let alert = NSAlert()
    alert.messageText = L("Guardar macro actual")
    alert.informativeText = L("Nombre de la macro")
    alert.addButton(withTitle: L("Guardar"))
    alert.addButton(withTitle: L("Cancelar"))
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    if field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        NSSound.beep()
        return
    }
    macros.save(name: field.stringValue)
}
