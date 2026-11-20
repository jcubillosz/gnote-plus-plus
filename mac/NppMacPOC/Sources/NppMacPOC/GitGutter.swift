import Foundation
import Scintilla

/// Margen 4: líneas agregadas, modificadas y borradas respecto de HEAD. La base (el blob de
/// HEAD) se cachea por documento y se invalida al guardar y al activar la pestaña; el diff
/// corre en segundo plano y un resultado viejo o de otro documento se descarta.
final class GitGutter {
    static let maxBytes = 5 * 1024 * 1024
    static let maxLines = 50_000

    private enum Base {
        case loading(token: Int)
        /// Fuera de un repo, ignorado, binario, muy grande o git no respondió: no se marca nada.
        case skip
        /// En el repo pero no en HEAD: todo "agregado".
        case untracked
        case lines([Substring])
    }

    private let preferences: EditorPreferences
    private var bases: [UUID: Base] = [:]
    private var generation = 0
    private var nextToken = 0
    private var marginVisible = false
    /// Último diff aplicado por documento (para el blame y restaurar bloque). Se borra al
    /// invalidar la base y al ocultar el margen: un resultado viejo mapearía mal las líneas.
    private var hunks: [UUID: [DiffHunk]] = [:]
    /// Tras aplicar un diff nuevo del documento activo.
    var onHunksUpdated: ((Document) -> Void)?

    init(preferences: EditorPreferences) {
        self.preferences = preferences
    }

    /// Al guardar, al activar y al cerrar: el próximo refresh vuelve a pedir el blob a git
    /// (HEAD pudo cambiar por un commit o checkout hecho afuera).
    func invalidate(_ document: Document) {
        bases[document.id] = nil
        hunks[document.id] = nil
    }

    func lastHunks(for id: UUID) -> [DiffHunk]? { hunks[id] }

    func baseLines(for id: UUID) -> [Substring]? {
        switch bases[id] {
        case .lines(let lines)?: return lines
        case .untracked?: return []
        default: return nil
        }
    }

    /// Mira el tamaño en Scintilla antes de copiar el texto: con un archivo enorme ni se lee.
    func refreshNow(document: Document?, editor: ScintillaView) {
        guard let document, preferences.showGitGutter, document.url != nil,
              call(editor, SCI_GETLENGTH) <= Self.maxBytes,
              call(editor, SCI_GETLINECOUNT) <= Self.maxLines else {
            generation += 1
            if let document { hunks[document.id] = nil }
            hide(editor)
            return
        }
        refresh(document: document, editor: editor, text: currentText(editor))
    }

    /// `text` es el del documento activo, leído en el hilo principal.
    func refresh(document: Document, editor: ScintillaView, text: String) {
        generation += 1
        let currentGeneration = generation
        guard preferences.showGitGutter, let url = document.url, text.utf8.count <= Self.maxBytes else {
            hunks[document.id] = nil
            hide(editor)
            return
        }
        let old: [Substring]?
        switch bases[document.id] {
        case nil:
            load(document: document, url: url, editor: editor)
            return
        case .loading?:
            // La carga en curso recalcula al terminar, con el texto de ese momento.
            return
        case .skip?:
            hunks[document.id] = nil
            hide(editor)
            return
        case .untracked?:
            old = nil
        case .lines(let lines)?:
            old = lines
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let new = gitLines(withoutBOM(text))
            let result: [DiffHunk]?
            if new.count > Self.maxLines {
                result = nil
            } else if let old {
                result = diffHunks(old: old, new: new)
            } else {
                result = [DiffHunk(oldRange: 0..<0, newRange: 0..<new.count)]
            }
            DispatchQueue.main.async {
                guard let self, currentGeneration == self.generation, self.isShowing(document, in: editor) else { return }
                self.hunks[document.id] = result
                if let result { self.apply(lineChanges(result), editor: editor) } else { self.hide(editor) }
                self.onHunksUpdated?(document)
            }
        }
    }

    private func load(document: Document, url: URL, editor: ScintillaView) {
        nextToken += 1
        let token = nextToken
        bases[document.id] = .loading(token: token)
        let encoding = document.encoding
        let finish: (Base) -> Void = { [weak self] base in
            guard let self, case .loading(let current)? = self.bases[document.id], current == token else { return }
            self.bases[document.id] = base
            if self.isShowing(document, in: editor) { self.refreshNow(document: document, editor: editor) }
        }
        GitTool.repoRoot(for: url.deletingLastPathComponent()) { root in
            guard let root, let relative = GitTool.relativePath(of: url, in: root) else {
                finish(.skip)
                return
            }
            GitTool.lookupHeadBlob(repo: root, relativePath: relative) { result in
                switch result {
                case .blob(let data):
                    DispatchQueue.global(qos: .utility).async {
                        let base = Self.decodeBase(data, encoding: encoding)
                        DispatchQueue.main.async { finish(base) }
                    }
                case .notInHead:
                    GitTool.isIgnored(repo: root, relativePath: relative) { ignored in
                        finish(ignored ? .skip : .untracked)
                    }
                case .unavailable:
                    finish(.skip)
                }
            }
        }
    }

    private static func decodeBase(_ data: Data, encoding: String.Encoding) -> Base {
        guard data.count <= maxBytes, !data.contains(0) else { return .skip }
        let text = String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
        let lines = gitLines(withoutBOM(text))
        return lines.count > maxLines ? .skip : .lines(lines)
    }

    private func isShowing(_ document: Document, in editor: ScintillaView) -> Bool {
        call(editor, SCI_GETDOCPOINTER) == document.pointer
    }

    private func apply(_ changes: [LineChange], editor: ScintillaView) {
        if !marginVisible {
            marginVisible = true
            setGitMarginVisible(editor, true)
        }
        clearMarkers(editor)
        let lineCount = call(editor, SCI_GETLINECOUNT)
        func mark(_ lines: Range<Int>, _ marker: Int) {
            for line in lines.clamped(to: 0..<lineCount) { _ = call(editor, SCI_MARKERADD, line, marker) }
        }
        for change in changes {
            switch change {
            case .added(let lines): mark(lines, MARKER_GIT_ADDED)
            case .modified(let lines): mark(lines, MARKER_GIT_MODIFIED)
            // Borrar al final del archivo no deja línea siguiente: se marca la última.
            case .deleted(let line): _ = call(editor, SCI_MARKERADD, min(line, lineCount - 1), MARKER_GIT_DELETED)
            }
        }
    }

    private func hide(_ editor: ScintillaView) {
        clearMarkers(editor)
        if marginVisible {
            marginVisible = false
            setGitMarginVisible(editor, false)
        }
    }

    private func clearMarkers(_ editor: ScintillaView) {
        for marker in [MARKER_GIT_ADDED, MARKER_GIT_MODIFIED, MARKER_GIT_DELETED] {
            _ = call(editor, SCI_MARKERDELETEALL, marker)
        }
    }

    private func call(_ editor: ScintillaView, _ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
        Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
    }
}

/// Un BOM al principio (de la base o del documento) haría distinta la primera línea.
private func withoutBOM(_ text: String) -> String {
    text.unicodeScalars.first == "\u{FEFF}" ? String(text.unicodeScalars.dropFirst()) : text
}
