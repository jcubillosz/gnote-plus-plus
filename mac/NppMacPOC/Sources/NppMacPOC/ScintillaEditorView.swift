import SwiftUI
import Scintilla

/// Ejecuta `action` en una vuelta de RunLoop realmente posterior a la actual, no solo en el
/// próximo drenado de la cola de despacho de main. `DispatchQueue.main.async` no alcanza acá:
/// un cambio de first responder (`makeFirstResponder`) programado con `.async` justo después
/// de un cambio de geometría (mostrar/ocultar el editor al cambiar de vista de Markdown, o
/// reparentarlo entre containers) puede terminar ejecutándose todavía dentro del mismo paso de
/// auto-layout de AppKit — y `-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]`
/// no permite pedir una actualización de constraints mientras una ya está en curso: lanza una
/// NSException y la app crashea (bug real reportado en QA manual, reproducible al cambiar el
/// modo de vista previa de Markdown). Un `Timer` agregado al modo `.common` del RunLoop solo
/// dispara cuando el RunLoop vuelve a quedar libre para esperar el próximo evento, después de
/// que CoreAnimation terminó de aplicar la transacción de layout en curso.
func deferPastCurrentLayoutPass(_ action: @escaping () -> Void) {
    let timer = Timer(timeInterval: 0, repeats: false) { _ in action() }
    RunLoop.main.add(timer, forMode: .common)
}

/// Wrapper delgado: el ScintillaView es una sola instancia compartida por toda la app
/// (creada en NppMacPOCApp), no una por pestaña. El estado de "qué documento está activo"
/// lo maneja TabsViewModel vía SCI_SETDOCPOINTER, no esta vista.
struct ScintillaEditorView: NSViewRepresentable {
    let editor: ScintillaView
    @ObservedObject var statusBar: StatusBarViewModel
    /// Documento activo y estado del corrector (Task 11): el monitor de clic derecho los
    /// necesita para construir el menú de sugerencias/aprender/ignorar. Se actualizan en
    /// cada updateNSView, igual que los demás closures — no viven en el Coordinator solos
    /// porque cambian con cada cambio de pestaña sin que el NSViewRepresentable se recree.
    var document: Document?
    @ObservedObject var spellCheck: SpellCheckViewModel
    var onContentChanged: (() -> Void)?
    var onScrolled: (() -> Void)?
    /// El documento se alejó del savepoint (primer cambio real tras abrir/guardar).
    var onSavePointLeft: (() -> Void)?
    /// El documento volvió al savepoint (undo hasta el original, o recién guardado).
    var onSavePointReached: (() -> Void)?
    /// El usuario intentó editar un documento bloqueado (SCN_MODIFYATTEMPTRO). ContentView
    /// lo usa para un pulso breve del ícono de candado, sin alertas.
    var onModifyAttemptReadOnly: (() -> Void)?
    /// Se ejecutó una acción del menú de corrector (reemplazo/aprender/ignorar): dispara una
    /// revisión inmediata para que el squiggle se actualice sin esperar el debounce normal.
    var onSpellCheckAction: (() -> Void)?
    /// Se soltó un archivo/carpeta de Finder sobre el editor (Task 12, ver SCN_URIDROPPED).
    var onURIDropped: ((URL) -> Void)?
    /// Cambió la selección (SC_UPDATE_SELECTION): dispara el smart highlight.
    var onSelectionChanged: (() -> Void)?
    /// Se escribió un carácter (SCN_CHARADDED): dispara el autocompletado.
    var onCharAdded: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(statusBar: statusBar, editor: editor, document: document, spellCheck: spellCheck)
        coordinator.onURIDropped = onURIDropped
        return coordinator
    }

    /// Devuelve un contenedor NUEVO y le adopta el ScintillaView compartido, en vez de
    /// devolver el ScintillaView directo. Al alternar la vista previa, SwiftUI destruye
    /// este representable y crea otro; devolviendo la vista compartida tal cual, queda
    /// fuera de la jerarquía y no se re-inserta (mismo bug que tuvo el WKWebView de la
    /// preview). Con contenedor propio, el reparenting es explícito y ocurre siempre.
    func makeNSView(context: Context) -> NSView {
        let container = SharedEditorContainer()
        editor.delegate = context.coordinator
        context.coordinator.installContextMenuProvider()
        adopt(into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.statusBar = statusBar
        context.coordinator.document = document
        context.coordinator.spellCheck = spellCheck
        context.coordinator.onContentChanged = onContentChanged
        context.coordinator.onScrolled = onScrolled
        context.coordinator.onSavePointLeft = onSavePointLeft
        context.coordinator.onSavePointReached = onSavePointReached
        context.coordinator.onModifyAttemptReadOnly = onModifyAttemptReadOnly
        context.coordinator.onSpellCheckAction = onSpellCheckAction
        context.coordinator.onURIDropped = onURIDropped
        context.coordinator.onSelectionChanged = onSelectionChanged
        context.coordinator.onCharAdded = onCharAdded
        if editor.delegate !== context.coordinator {
            editor.delegate = context.coordinator
            context.coordinator.installContextMenuProvider()
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
        // para poder escribir después de abrir o cerrar la vista previa. Diferido con
        // deferPastCurrentLayoutPass (no DispatchQueue.main.async): ver su comentario —
        // reparentar dispara un layout de AppKit, y makeFirstResponder demasiado pronto
        // crasheaba la app al cambiar de vista previa (bug real reportado en QA manual).
        deferPastCurrentLayoutPass {
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
        var document: Document?
        var spellCheck: SpellCheckViewModel
        /// Avisa a la preview de Markdown que el contenido cambió (no cursor/selección).
        var onContentChanged: (() -> Void)?
        /// Avisa que cambió el scroll vertical, para sincronizar la preview de Markdown.
        var onScrolled: (() -> Void)?
        /// Avisa que el documento se alejó del savepoint (ver SCN_SAVEPOINTLEFT).
        var onSavePointLeft: (() -> Void)?
        /// Avisa que el documento volvió al savepoint (ver SCN_SAVEPOINTREACHED).
        var onSavePointReached: (() -> Void)?
        /// Avisa un intento de edición sobre un documento bloqueado (ver SCN_MODIFYATTEMPTRO).
        var onModifyAttemptReadOnly: (() -> Void)?
        /// Avisa que el menú de corrector ejecutó una acción (Task 11), para re-revisar ya.
        var onSpellCheckAction: (() -> Void)?
        /// Avisa que se soltó un archivo/carpeta sobre el editor (Task 12, ver SCN_URIDROPPED).
        var onURIDropped: ((URL) -> Void)?
        /// Avisa que cambió la selección (ver SC_UPDATE_SELECTION en SCN_UPDATEUI).
        var onSelectionChanged: (() -> Void)?
        /// Avisa el carácter recién escrito (ver SCN_CHARADDED).
        var onCharAdded: ((Int) -> Void)?

        init(statusBar: StatusBarViewModel, editor: ScintillaView?, document: Document? = nil, spellCheck: SpellCheckViewModel) {
            self.statusBar = statusBar
            self.editor = editor
            self.document = document
            self.spellCheck = spellCheck
            super.init()
        }

        deinit {
            if editor?.delegate === self {
                editor?.delegate = nil
                (editor as? ContextMenuScintillaView)?.contextMenuProvider = nil
            }
        }

        /// Se llama junto con cada asignación de `editor.delegate`: el coordinator vigente es
        /// el único que debe construir el menú contextual.
        func installContextMenuProvider() {
            (editor as? ContextMenuScintillaView)?.contextMenuProvider = { [weak self] event in
                self?.spellContextMenu(for: event)
            }
        }

        /// Menú del corrector si el clic derecho/ctrl+click cae sobre una palabra marcada
        /// (INDICATOR_SPELL); nil en cualquier otro caso, y Scintilla muestra su menú nativo.
        private func spellContextMenu(for event: NSEvent) -> NSMenu? {
            guard let editor, spellCheck.enabled, let document else { return nil }
            // Coordenadas de cliente de Scintilla: relativas al SCIContentView (flipped, sin
            // scroller) menos el origen visible del scroll, más el ancho de los márgenes —
            // en Cocoa los márgenes viven en un NSRulerView aparte, pero los mensajes
            // SCI_POSITIONFROMPOINT* siguen contando x desde el borde izquierdo de los
            // márgenes (ver MoveFindIndicatorWithBounce en scintilla/cocoa/ScintillaCocoa.mm).
            // Convertir al ScintillaView exterior (no flipped) invertía la Y y la posición casi
            // nunca caía sobre la palabra marcada, así que el menú de sugerencias no aparecía
            // (bug real de QA manual).
            guard let content = editor.content() else { return nil }
            let pointInContent = content.convert(event.locationInWindow, from: nil)
            guard content.visibleRect.contains(pointInContent) else { return nil }
            let scrollOrigin = content.enclosingScrollView?.contentView.bounds.origin ?? .zero
            let clientX = pointInContent.x - scrollOrigin.x + CGFloat(marginsWidth(editor))
            let clientY = pointInContent.y - scrollOrigin.y

            // POSITIONFROMPOINTCLOSE devuelve -1 fuera de un carácter (margen derecho, debajo
            // de la última línea), en vez de la posición más cercana.
            let pos = Int(ScintillaView.directCall(
                editor, message: SCI_POSITIONFROMPOINTCLOSE,
                wParam: uptr_t(max(0, Int(clientX))),
                lParam: sptr_t(max(0, Int(clientY)))
            ))
            guard pos >= 0 else { return nil }

            let indicatorValue = ScintillaView.directCall(
                editor, message: SCI_INDICATORVALUEAT, wParam: uptr_t(INDICATOR_SPELL), lParam: sptr_t(pos)
            )
            guard indicatorValue != 0 else { return nil }

            let wordStart = Int(ScintillaView.directCall(
                editor, message: SCI_INDICATORSTART, wParam: uptr_t(INDICATOR_SPELL), lParam: sptr_t(pos)
            ))
            let wordEnd = Int(ScintillaView.directCall(
                editor, message: SCI_INDICATOREND, wParam: uptr_t(INDICATOR_SPELL), lParam: sptr_t(pos)
            ))
            guard wordEnd > wordStart else { return nil }

            // Igual que NSTextView: el clic derecho selecciona la palabra bajo el cursor.
            _ = ScintillaView.directCall(editor, message: SCI_SETSEL, wParam: uptr_t(wordStart), lParam: sptr_t(wordEnd))

            return SpellCheckContextMenu.build(
                editor: editor, document: document, spellCheck: spellCheck,
                wordStart: wordStart, wordEnd: wordEnd,
                onAction: { [weak self] in self?.onSpellCheckAction?() }
            )
        }

        /// Equivalente a ViewStyle::fixedColumnWidth (marginInside es el default).
        private func marginsWidth(_ editor: ScintillaView) -> Int {
            var width = Int(ScintillaView.directCall(editor, message: SCI_GETMARGINLEFT, wParam: 0, lParam: 0))
            let count = Int(ScintillaView.directCall(editor, message: SCI_GETMARGINS, wParam: 0, lParam: 0))
            for margin in 0..<count {
                width += Int(ScintillaView.directCall(editor, message: SCI_GETMARGINWIDTHN, wParam: uptr_t(margin), lParam: 0))
            }
            return width
        }

        func notification(_ notification: UnsafeMutablePointer<SCNotification>!) {
            guard let notification else { return }
            switch Int32(notification.pointee.nmhdr.code) {
            case SCN_UPDATEUI:
                updateCursorAndSelection()
                if Int(notification.pointee.updated) & SC_UPDATE_V_SCROLL != 0 {
                    onScrolled?()
                }
                if Int(notification.pointee.updated) & SC_UPDATE_SELECTION != 0 {
                    onSelectionChanged?()
                }
            case SCN_MODIFIED:
                // SC_UPDATE_CONTENT (vía SCN_UPDATEUI) se disparaba también por el recoloreo
                // perezoso del lexer al hacer scroll del editor (líneas nuevas visibles que
                // recién se estilizan), sin que el texto cambiara — eso hacía que la vista
                // previa de Markdown se recargara sola al leer, saltando de vuelta al scroll
                // que tenía antes de la recarga (bug real reportado en QA manual). Filtrar por
                // SC_MOD_INSERTTEXT/SC_MOD_DELETETEXT en SCN_MODIFIED asegura que la preview y
                // el corrector ortográfico solo se refresquen ante una edición real de texto.
                let mod = Int(notification.pointee.modificationType)
                if mod & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT) != 0 {
                    onContentChanged?()
                }
            case SCN_SAVEPOINTLEFT:
                onSavePointLeft?()
            case SCN_SAVEPOINTREACHED:
                onSavePointReached?()
            case SCN_MODIFYATTEMPTRO:
                onModifyAttemptReadOnly?()
            case SCN_MARGINCLICK:
                // El margen de plegado lo maneja Scintilla (SC_AUTOMATICFOLD_CLICK); acá solo
                // el de marcadores.
                if Int(notification.pointee.margin) == MARGIN_BOOKMARKS, let editor {
                    let line = ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(notification.pointee.position), lParam: 0)
                    toggleBookmark(editor: editor, line: Int(line))
                }
            case SCN_CHARADDED:
                onCharAdded?(Int(notification.pointee.ch))
            case SCN_URIDROPPED:
                if let cString = notification.pointee.text {
                    let path = String(cString: cString)
                    onURIDropped?(URL(fileURLWithPath: path))
                }
            default:
                break
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

/// ScintillaView con gancho para el menú contextual. SCIContentView.menuForEvent: le pregunta
/// primero a su ScintillaView dueño (`[mOwner menuForEvent:]`, scintilla/cocoa/ScintillaView.mm)
/// y solo si devuelve nil arma el menú nativo de Scintilla. Sobrescribir `menu(for:)` acá
/// cubre clic derecho y ctrl+click por el camino normal de AppKit; un monitor local de
/// rightMouseDown (el mecanismo anterior) no veía ctrl+click y además, tras cerrar el menú
/// propio, AppKit igual mostraba el nativo encima.
final class ContextMenuScintillaView: ScintillaView {
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(event) ?? super.menu(for: event)
    }
}
