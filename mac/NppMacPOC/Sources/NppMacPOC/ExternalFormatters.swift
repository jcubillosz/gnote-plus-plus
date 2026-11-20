import Foundation
import AppKit
import Scintilla

// MARK: - Candidatos (lógica pura)

struct FormatterSpec {
    let tool: String
    /// Argumentos dado el nombre de archivo (real o ficticio) que el formateador usa para
    /// deducir el lenguaje y buscar su configuración; el texto siempre va por stdin.
    let args: (String) -> [String]
    /// Comando sugerido para instalarlo (no se traduce).
    let installHint: String
}

/// Nombre canónico: acepta el `languageName` de langs.model.xml ("cpp", "javascript.js") y
/// nombres legibles ("C++", "JavaScript").
private func canonicalLanguage(_ name: String, fileExtension: String) -> String {
    let lower = name.lowercased()
    let aliases: [String: String] = [
        "c++": "cpp", "javascript.js": "javascript", "js": "javascript", "ts": "typescript",
        "objective-c": "objc", "golang": "go", "py": "python", "rs": "rust",
    ]
    if let alias = aliases[lower] { return alias }
    if !lower.isEmpty { return lower }
    let byExtension: [String: String] = [
        "js": "javascript", "mjs": "javascript", "jsx": "javascript", "ts": "typescript", "tsx": "typescript",
        "css": "css", "scss": "scss", "less": "less", "html": "html", "htm": "html", "json": "json",
        "yml": "yaml", "yaml": "yaml", "md": "markdown", "py": "python", "go": "go", "rs": "rust",
        "c": "c", "h": "cpp", "cpp": "cpp", "cc": "cpp", "hpp": "cpp", "m": "objc", "mm": "objc",
        "java": "java", "swift": "swift",
    ]
    return byExtension[fileExtension.lowercased()] ?? ""
}

private let prettierLanguages: Set<String> = ["javascript", "typescript", "css", "scss", "less", "html", "json", "yaml", "markdown", "vue"]
private let clangLanguages: Set<String> = ["c", "cpp", "objc", "java"]

/// Formateadores posibles para el lenguaje, en orden de preferencia.
func formatterCandidates(forLanguage name: String, fileExtension: String) -> [FormatterSpec] {
    let language = canonicalLanguage(name, fileExtension: fileExtension)
    if prettierLanguages.contains(language) {
        return [FormatterSpec(tool: "prettier", args: { ["--stdin-filepath", $0] },
                              installHint: "npm install --save-dev prettier")]
    }
    if clangLanguages.contains(language) {
        return [FormatterSpec(tool: "clang-format", args: { ["--assume-filename=\($0)"] },
                              installHint: "brew install clang-format")]
    }
    switch language {
    case "python":
        return [FormatterSpec(tool: "black", args: { ["--quiet", "--stdin-filename", $0, "-"] },
                              installHint: "pipx install black"),
                FormatterSpec(tool: "ruff", args: { ["format", "--stdin-filename", $0, "-"] },
                              installHint: "brew install ruff")]
    case "go":
        return [FormatterSpec(tool: "gofmt", args: { _ in [] }, installHint: "brew install go")]
    case "rust":
        return [FormatterSpec(tool: "rustfmt", args: { _ in ["--emit", "stdout"] },
                              installHint: "rustup component add rustfmt")]
    case "swift":
        return [FormatterSpec(tool: "swift-format", args: { ["format", "--assume-filename", $0] },
                              installHint: "brew install swift-format"),
                FormatterSpec(tool: "swiftformat", args: { ["--stdinpath", $0] },
                              installHint: "brew install swiftformat")]
    default:
        return []
    }
}

/// Extensión para el nombre ficticio de un documento sin título.
func defaultFormatterExtension(forLanguage name: String) -> String {
    let extensions: [String: String] = [
        "javascript": "js", "typescript": "ts", "css": "css", "scss": "scss", "less": "less", "html": "html",
        "json": "json", "yaml": "yaml", "markdown": "md", "vue": "vue", "c": "c", "cpp": "cpp", "objc": "m",
        "java": "java", "python": "py", "go": "go", "rust": "rs", "swift": "swift",
    ]
    return extensions[canonicalLanguage(name, fileExtension: "")] ?? "txt"
}

/// Primeras `count` líneas de un texto (para mostrar stderr sin desbordar la alerta).
func firstLines(_ text: String, _ count: Int) -> String {
    text.split(separator: "\n", maxSplits: count, omittingEmptySubsequences: false).prefix(count).joined(separator: "\n")
}

// FIN-PURO

// MARK: - Localizar herramientas

enum ToolLocator {
    private static let fixedDirectories: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", home + "/.cargo/bin", home + "/go/bin", home + "/.local/bin"]
    }()

    private static let lock = NSLock()
    private static var cachedLoginPath: [String]?

    /// PATH del login shell: una app lanzada desde el Finder hereda un PATH mínimo, sin Homebrew
    /// ni lo que el usuario agregó en su perfil. Bloquea hasta 2 s: llamar fuera del hilo principal.
    private static func loginShellPath() -> [String] {
        lock.lock()
        if let cachedLoginPath { lock.unlock(); return cachedLoginPath }
        lock.unlock()
        dispatchPrecondition(condition: .notOnQueue(.main))
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String] = []
        ExternalProcess.run(URL(fileURLWithPath: "/bin/zsh"), args: ["-lc", "printf %s \"$PATH\""], stdin: nil,
                            cwd: nil, timeout: 2) { outcome in
            if case .success(let output) = outcome, output.status == 0 {
                // El perfil puede imprimir cosas antes: el PATH es la última línea.
                let text = String(decoding: output.stdout, as: UTF8.self)
                let last = text.split(separator: "\n").last.map(String.init) ?? ""
                result = last.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
            }
            semaphore.signal()
        }
        // El completion va al hilo principal; margen extra por si el timeout tarda en cerrar.
        if semaphore.wait(timeout: .now() + 4) == .timedOut { result = [] }
        lock.lock(); cachedLoginPath = result; lock.unlock()
        return result
    }

    /// Bloquea como `loginShellPath`: llamar fuera del hilo principal.
    static func searchPath(for executable: URL) -> String {
        composeToolSearchPath(executableDirectory: executable.deletingLastPathComponent().path,
                              fixed: fixedDirectories, login: loginShellPath())
    }

    static func find(_ tool: String, near fileURL: URL?, projectRoot: URL?) -> URL? {
        let fm = FileManager.default
        func executable(in dir: String) -> URL? {
            let path = (dir as NSString).appendingPathComponent(tool)
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        if tool == "prettier", let fileURL {
            // El prettier del proyecto (con su versión y plugins) gana sobre uno global.
            let stop = (projectRoot ?? fm.homeDirectoryForCurrentUser).standardizedFileURL.path
            var dir = fileURL.deletingLastPathComponent().standardizedFileURL
            while true {
                if let found = executable(in: dir.appendingPathComponent("node_modules/.bin").path) { return found }
                if dir.path == stop || dir.path == "/" { break }
                dir = dir.deletingLastPathComponent()
            }
        }
        for dir in fixedDirectories {
            if let found = executable(in: dir) { return found }
        }
        for dir in loginShellPath() {
            if let found = executable(in: dir) { return found }
        }
        return nil
    }
}

// MARK: - Integración

private let formatterTimeout: TimeInterval = 15

func formatWithExternalTool(tabs: TabsViewModel) {
    guard let document = tabs.activeDocument, !document.isLocked else { return }
    let editor = tabs.editor
    let languageName = document.languageProfile.languageName
    let fileURL = document.url
    let fileExtension = fileURL?.pathExtension ?? ""
    let candidates = formatterCandidates(forLanguage: languageName, fileExtension: fileExtension)
    guard !candidates.isEmpty else {
        presentAlert(L("Formatear con herramienta externa"),
                     detail: L("No hay un formateador conocido para este lenguaje."))
        return
    }
    let fileName = fileURL?.lastPathComponent ?? "sin-titulo.\(defaultFormatterExtension(forLanguage: languageName))"
    let original = currentText(editor)
    let documentID = document.id

    DispatchQueue.global(qos: .userInitiated).async {
        var chosen: (spec: FormatterSpec, url: URL)?
        for spec in candidates {
            if let url = ToolLocator.find(spec.tool, near: fileURL, projectRoot: nil) { chosen = (spec, url); break }
        }
        let searchPath = chosen.map { ToolLocator.searchPath(for: $0.url) }
        DispatchQueue.main.async {
            guard let (spec, executable) = chosen else {
                let hints = candidates.map { "\($0.tool): \($0.installHint)" }.joined(separator: "\n")
                presentAlert(L("No se encontró un formateador instalado"), detail: hints)
                return
            }
            ExternalProcess.run(executable, args: spec.args(fileName), stdin: Data(original.utf8),
                                cwd: fileURL?.deletingLastPathComponent(), env: ["PATH": searchPath ?? ""],
                                timeout: formatterTimeout) { result in
                switch result {
                case .failure(.timeout):
                    presentAlert(L("Formatear con herramienta externa"),
                                 detail: L("\(spec.tool) no respondió a tiempo; el documento no se modificó."))
                case .failure(.launchFailed(let message)):
                    presentAlert(L("Formatear con herramienta externa"), detail: message)
                case .success(let output) where output.status != 0:
                    let stderr = firstLines(String(decoding: output.stderr, as: UTF8.self), 20)
                    presentAlert(L("\(spec.tool) devolvió un error"), detail: stderr)
                case .success(let output):
                    applyFormatterOutput(output.stdout, original: original, documentID: documentID, tabs: tabs)
                }
            }
        }
    }
}

private func applyFormatterOutput(_ data: Data, original: String, documentID: UUID, tabs: TabsViewModel) {
    let editor = tabs.editor
    // Mientras corría el formateador el usuario pudo cambiar de pestaña, editar o bloquear:
    // aplicar la salida pisaría eso.
    guard let document = tabs.activeDocument, document.id == documentID, !document.isLocked,
          currentText(editor) == original else {
        presentAlert(L("Formatear con herramienta externa"),
                     detail: L("El documento cambió mientras se formateaba; no se aplicó el resultado."))
        return
    }
    // Un byte 0 cortaría el reemplazo (se pasa como C string): se rechaza como salida inválida.
    guard !data.contains(0), var formatted = String(data: data, encoding: .utf8),
          !(formatted.isEmpty && !original.isEmpty) else {
        presentAlert(L("Formatear con herramienta externa"), detail: L("El formateador devolvió una salida vacía o inválida."))
        return
    }
    // Los formateadores escriben LF: respetar el fin de línea del documento.
    formatted = formatted.replacingOccurrences(of: "\r\n", with: "\n")
    switch ScintillaView.directCall(editor, message: SCI_GETEOLMODE, wParam: 0, lParam: 0) {
    case 0: formatted = formatted.replacingOccurrences(of: "\n", with: "\r\n")
    case 1: formatted = formatted.replacingOccurrences(of: "\n", with: "\r")
    default: break
    }
    guard formatted != original else { return }

    let caretPos = ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0)
    let caretLine = Int(ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(caretPos), lParam: 0))
    let firstLine = firstVisibleDocumentLine(editor)

    _ = ScintillaView.directCall(editor, message: SCI_BEGINUNDOACTION, wParam: 0, lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_TARGETWHOLEDOCUMENT, wParam: 0, lParam: 0)
    formatted.withCString { cstr in
        _ = ScintillaView.directCall(editor, message: SCI_REPLACETARGET, wParam: uptr_t(strlen(cstr)),
                                     lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
    }
    _ = ScintillaView.directCall(editor, message: SCI_ENDUNDOACTION, wParam: 0, lParam: 0)

    let lineCount = Int(ScintillaView.directCall(editor, message: SCI_GETLINECOUNT, wParam: 0, lParam: 0))
    let targetLine = min(caretLine, max(0, lineCount - 1))
    _ = ScintillaView.directCall(editor, message: SCI_GOTOLINE, wParam: uptr_t(targetLine), lParam: 0)
    let visible = ScintillaView.directCall(editor, message: SCI_VISIBLEFROMDOCLINE,
                                           wParam: uptr_t(min(firstLine, max(0, lineCount - 1))), lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_SETFIRSTVISIBLELINE, wParam: uptr_t(max(0, visible)), lParam: 0)
}
