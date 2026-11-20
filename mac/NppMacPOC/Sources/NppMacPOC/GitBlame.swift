import Foundation
import Scintilla

/// Autor, fecha y resumen del commit de la línea del cursor, como anotación al final de la línea.
/// El blame es contra HEAD; las líneas desplazadas por cambios sin guardar se traducen con los
/// hunks del último diff de `GitGutter`.
final class GitBlame {
    static let timeout: TimeInterval = 10
    static let styleOffset = 512

    private struct Entry {
        let head: String
        let lines: [BlameLine]
        /// Al guardar/activar: antes de usarla se compara HEAD (un `rev-parse` cuesta menos que un blame).
        var stale = false
    }

    private let preferences: EditorPreferences
    private let gutter: GitGutter
    private var cache: [String: Entry] = [:]
    private var loading: Set<String> = []
    private var requests: [String: Int] = [:]
    private var debounce: DispatchWorkItem?
    /// Sube con cada movimiento del cursor: una carga que termina después ya no muestra nada.
    private var generation = 0
    /// Documento (con referencia propia) que tiene la anotación puesta.
    private var annotatedDocument: Int = 0
    /// Las anotaciones viven en el documento: para borrar la de una pestaña que ya no está activa
    /// se usa una vista propia, nunca la compartida.
    private lazy var cleaner = ScintillaView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))

    init(preferences: EditorPreferences, gutter: GitGutter) {
        self.preferences = preferences
        self.gutter = gutter
    }

    func caretMoved(document: Document?, editor: ScintillaView) {
        debounce?.cancel()
        generation += 1
        guard preferences.showInlineBlame else { clear(editor: editor); return }
        let work = DispatchWorkItem { [weak self] in self?.show(document: document, editor: editor) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func invalidate(_ document: Document) {
        guard let url = document.url else { return }
        cache[canonicalFilePath(url)]?.stale = true
    }

    /// Al cerrar la pestaña: el blame guarda todas las líneas del archivo, no se deja toda la sesión.
    func forget(_ document: Document) {
        guard let url = document.url else { return }
        let path = canonicalFilePath(url)
        cache[path] = nil
        // Una carga en curso tampoco debe volver a cachearlo al terminar.
        requests[path] = nil
    }

    func clear(editor: ScintillaView) {
        debounce?.cancel()
        guard annotatedDocument != 0 else { return }
        let pointer = annotatedDocument
        annotatedDocument = 0
        if call(editor, SCI_GETDOCPOINTER) == pointer {
            _ = call(editor, SCI_EOLANNOTATIONCLEARALL)
        } else {
            _ = call(cleaner, SCI_SETDOCPOINTER, 0, pointer)
            _ = call(cleaner, SCI_EOLANNOTATIONCLEARALL)
            _ = call(cleaner, SCI_SETDOCPOINTER, 0, 0)
        }
        _ = call(editor, SCI_RELEASEDOCUMENT, 0, pointer)
    }

    private func show(document: Document?, editor: ScintillaView) {
        clear(editor: editor)
        guard preferences.showInlineBlame, let document, let url = document.url,
              call(editor, SCI_GETDOCPOINTER) == document.pointer,
              call(editor, SCI_GETSELECTIONS) == 1,
              call(editor, SCI_GETLENGTH) <= GitGutter.maxBytes else { return }
        let line = call(editor, SCI_LINEFROMPOSITION, call(editor, SCI_GETCURRENTPOS))
        let baseLine: Int?
        if let hunks = gutter.lastHunks(for: document.id) {
            baseLine = mapLineToBase(line, hunks: hunks)
        } else if !document.isDirty {
            baseLine = line
        } else {
            // Modificado y sin diff todavía: el número de línea de HEAD sería un invento.
            return
        }
        let path = canonicalFilePath(url)
        guard let entry = cache[path], !entry.stale else {
            load(path: path, url: url, document: document, editor: editor)
            return
        }
        let blame: BlameLine?
        if let baseLine {
            guard baseLine < entry.lines.count else { return }
            blame = entry.lines[baseLine]
        } else {
            blame = nil
        }
        annotate(line: line, text: "  " + blameText(blame, now: Date(), locale: .current), document: document, editor: editor)
    }

    private func annotate(line: Int, text: String, document: Document, editor: ScintillaView) {
        // STYLECLEARALL (cada tema) pisa el estilo 512: se recalcula siempre. Gris = mitad entre
        // el texto y el fondo del tema, así se lee atenuado en claro y oscuro.
        let fore = call(editor, SCI_STYLEGETFORE, STYLE_DEFAULT), back = call(editor, SCI_STYLEGETBACK, STYLE_DEFAULT)
        var mixed = 0
        for shift in [0, 8, 16] {
            mixed |= ((((fore >> shift) & 0xFF) + ((back >> shift) & 0xFF)) / 2) << shift
        }
        _ = call(editor, SCI_STYLESETFORE, Self.styleOffset, mixed)
        _ = call(editor, SCI_STYLESETITALIC, Self.styleOffset, 1)
        _ = call(editor, SCI_EOLANNOTATIONSETSTYLEOFFSET, Self.styleOffset)
        _ = call(editor, SCI_EOLANNOTATIONSETVISIBLE, EOLANNOTATION_STANDARD)
        text.withCString { cstr in
            _ = ScintillaView.directCall(editor, message: SCI_EOLANNOTATIONSETTEXT, wParam: uptr_t(line),
                                         lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
        }
        _ = call(editor, SCI_EOLANNOTATIONSETSTYLE, line, 0)
        _ = call(editor, SCI_ADDREFDOCUMENT, 0, document.pointer)
        annotatedDocument = document.pointer
    }

    private func load(path: String, url: URL, document: Document, editor: ScintillaView) {
        // Un pedido que llega con la carga en curso solo actualiza la generación esperada.
        requests[path] = generation
        guard loading.insert(path).inserted else { return }
        let previous = cache[path]
        let finish: (Entry?) -> Void = { [weak self] entry in
            guard let self else { return }
            self.loading.remove(path)
            defer { self.requests[path] = nil }
            // Sin respuesta (timeout, sin git): no se cachea nada y no se muestra. Sin pedido
            // pendiente, la pestaña se cerró mientras cargaba.
            guard let entry, self.requests[path] != nil else { return }
            self.cache[path] = entry
            // Si el cursor se movió o cambió la pestaña, ese caretMoved ya agendó lo suyo: re-mostrar
            // acá borraría la anotación de la pestaña activa.
            guard self.requests.removeValue(forKey: path) == self.generation,
                  self.call(editor, SCI_GETDOCPOINTER) == document.pointer else { return }
            self.show(document: document, editor: editor)
        }
        GitTool.repoRoot(for: url.deletingLastPathComponent()) { root in
            guard let root, let relative = GitTool.relativePath(of: url, in: root) else { finish(nil); return }
            GitTool.run(["rev-parse", "HEAD"], cwd: root) { result in
                guard case .success(let output)? = result, output.status == 0 else { finish(nil); return }
                let head = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if let previous, previous.head == head {
                    finish(Entry(head: head, lines: previous.lines))
                    return
                }
                GitTool.run(["blame", "--porcelain", head, "--", relative], cwd: root, timeout: Self.timeout) { result in
                    guard case .success(let output)? = result else { finish(nil); return }
                    // Archivo fuera de HEAD: git falla y todo es "sin commitear" vía los hunks.
                    guard output.status == 0 else { finish(Entry(head: head, lines: [])); return }
                    DispatchQueue.global(qos: .utility).async {
                        let lines = parseBlamePorcelain(output.stdout)
                        DispatchQueue.main.async { finish(Entry(head: head, lines: lines)) }
                    }
                }
            }
        }
    }

    private func call(_ editor: ScintillaView, _ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
        Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
    }
}
