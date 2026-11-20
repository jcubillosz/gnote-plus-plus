// Único monitor de Tab del editor: sesión de fragmento → fragmento → Emmet → Scintilla.
import AppKit
import Scintilla

enum TabKeyRouter {
    private static var monitor: Any?

    /// Un solo monitor para que la prioridad sea determinista (dos monitores locales no garantizan
    /// orden entre sí). Si nadie hace nada, el evento sigue y Scintilla indenta como siempre.
    static func install(tabs: TabsViewModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak tabs] event in
            guard let tabs else { return event }
            let session = SnippetSession.current
            // Esc termina la sesión pero sigue su camino (cierra el autocompletado, etc.).
            if event.keyCode == 53, let session, editorHasFocus(tabs, event) {
                session.end()
                return event
            }
            guard event.keyCode == 48, editorHasFocus(tabs, event) else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty || (mods == .shift && session != nil) else { return event }
            // Con la lista de autocompletado abierta, Tab la acepta (Scintilla).
            guard ScintillaView.directCall(tabs.editor, message: SCI_AUTOCACTIVE, wParam: 0, lParam: 0) == 0 else { return event }

            if let session {
                session.reconcile()
                if session.isActive {
                    if mods == .shift { session.previous() } else { session.next() }
                    return nil
                }
                if mods == .shift { return event }
            }
            // Grabando o reproduciendo una macro, Tab llega a Scintilla y se graba como tabulación.
            if tabs.preferences.snippetsEnabled, !tabs.macros.isRecording, !tabs.macros.isPlaying,
               tabs.expandSnippetAtCaret() {
                return nil
            }
            return EmmetTabTrigger.tryExpand(tabs: tabs) ? nil : event
        }
    }

    private static func editorHasFocus(_ tabs: TabsViewModel, _ event: NSEvent) -> Bool {
        guard event.window === NSApp.keyWindow, let content = tabs.editor.content() else { return false }
        return event.window?.firstResponder === content && !content.hasMarkedText()
    }
}
