import SwiftUI
import Scintilla

/// Wrapper delgado: el ScintillaView es una sola instancia compartida por toda la app
/// (creada en NppMacPOCApp), no una por pestaña. El estado de "qué documento está activo"
/// lo maneja TabsViewModel vía SCI_SETDOCPOINTER, no esta vista.
struct ScintillaEditorView: NSViewRepresentable {
    let editor: ScintillaView
    @ObservedObject var statusBar: StatusBarViewModel
    var onContentChanged: (() -> Void)?
    var onScrolled: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(statusBar: statusBar, editor: editor)
    }

    /// Devuelve un contenedor NUEVO y le adopta el ScintillaView compartido, en vez de
    /// devolver el ScintillaView directo. Al alternar la vista previa, SwiftUI destruye
    /// este representable y crea otro; devolviendo la vista compartida tal cual, queda
    /// fuera de la jerarquía y no se re-inserta (mismo bug que tuvo el WKWebView de la
    /// preview). Con contenedor propio, el reparenting es explícito y ocurre siempre.
    func makeNSView(context: Context) -> NSView {
        let container = SharedEditorContainer()
        editor.delegate = context.coordinator
        adopt(into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.statusBar = statusBar
        context.coordinator.onContentChanged = onContentChanged
        context.coordinator.onScrolled = onScrolled
        if editor.delegate !== context.coordinator {
            editor.delegate = context.coordinator
        }
        adopt(into: container)
    }

    private func adopt(into container: NSView) {
        // Invalidar SIEMPRE, no solo al reparentar: en un cambio de pestaña normal el
        // editor ya está en este mismo container, y SCI_SETDOCPOINTER cambia el contenido
        // por debajo sin tocar geometría — si el frame resultante coincide con el actual,
        // AppKit no dispara needsDisplay solo.
        //
        // Pero hacerlo SÍNCRONO acá no alcanza cuando el container es nuevo (toggle de
        // preview, cambio entre Markdown y no-Markdown): en ese caso SwiftUI recién está
        // creando este NSViewRepresentable y el container todavía no tiene ventana —
        // needsDisplay en una vista sin ventana es un no-op que nadie vuelve a pedir una
        // vez que la ventana la adopta. Por eso la invalidación va en el mismo async que
        // ya usa el foco, después de que el container esté instalado de verdad.
        guard editor.superview !== container else {
            container.needsLayout = true
            editor.needsDisplay = true
            return
        }
        editor.removeFromSuperview()
        editor.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(editor)
        // Al reinsertarse pierde el foco: sin esto hay que hacer clic en el editor
        // para poder escribir después de abrir o cerrar la vista previa.
        DispatchQueue.main.async {
            container.needsLayout = true
            editor.needsDisplay = true
            container.window?.makeFirstResponder(editor)
        }
    }

    /// Recibe notificaciones nativas de Scintilla (SCNotification) y traduce SCN_UPDATEUI
    /// (movimiento de caret, cambio de selección, scroll) a valores publicados en
    /// StatusBarViewModel. No usamos NotificationCenter/SCIUpdateUINotification porque el
    /// delegate directo evita depender del runloop de notificaciones de AppKit.
    final class Coordinator: NSObject, ScintillaNotificationProtocol {
        var statusBar: StatusBarViewModel
        weak var editor: ScintillaView?
        /// Avisa a la preview de Markdown que el contenido cambió (no cursor/selección).
        var onContentChanged: (() -> Void)?
        /// Avisa que cambió el scroll vertical, para sincronizar la preview de Markdown.
        var onScrolled: (() -> Void)?

        init(statusBar: StatusBarViewModel, editor: ScintillaView?) {
            self.statusBar = statusBar
            self.editor = editor
        }

        deinit {
            if editor?.delegate === self {
                editor?.delegate = nil
            }
        }

        func notification(_ notification: UnsafeMutablePointer<SCNotification>!) {
            guard let notification, Int32(notification.pointee.nmhdr.code) == SCN_UPDATEUI else { return }
            updateCursorAndSelection()
            // SCN_UPDATEUI también se dispara por movimiento de caret/scroll sin cambio de
            // texto; filtrar por SC_UPDATE_CONTENT evita refrescar la preview de más.
            if Int(notification.pointee.updated) & SC_UPDATE_CONTENT != 0 {
                onContentChanged?()
            }
            if Int(notification.pointee.updated) & SC_UPDATE_V_SCROLL != 0 {
                onScrolled?()
            }
        }

        private func updateCursorAndSelection() {
            guard let editor = statusBar.editorRef else { return }
            let pos = ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0)
            let line = ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: UInt(pos), lParam: 0)
            let column = ScintillaView.directCall(editor, message: SCI_GETCOLUMN, wParam: UInt(pos), lParam: 0)
            let selStart = ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0)
            let selEnd = ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0)

            statusBar.line = Int(line) + 1
            statusBar.column = Int(column) + 1

            if selEnd > selStart {
                let selStartLine = ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: UInt(selStart), lParam: 0)
                let selEndLine = ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: UInt(selEnd), lParam: 0)
                statusBar.selectionCharCount = Int(selEnd - selStart)
                statusBar.selectionLineCount = Int(selEndLine - selStartLine) + 1
            } else {
                statusBar.selectionCharCount = 0
                statusBar.selectionLineCount = 0
            }
        }
    }
}

/// ScintillaView es una vista AppKit clásica: se dimensiona por frame, no por Auto Layout.
/// Adoptarla con constraints la dejaba sin tamaño válido al volver a la rama sin split y el
/// editor aparecía en blanco hasta que un cambio de pestaña forzaba un relayout. Este
/// contenedor le fija el frame en cada pase de layout, así que no depende de cuándo SwiftUI
/// llame a updateNSView ni de que el contenedor ya tenga bounds al crearse.
final class SharedEditorContainer: NSView {
    override func layout() {
        super.layout()
        for subview in subviews where subview.frame != bounds {
            subview.frame = bounds
        }
    }
}
