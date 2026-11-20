import AppKit

/// Una de las dos versiones que se comparan. Todas refieren a un documento abierto.
enum CompareSource: Hashable {
    /// Texto actual de la pestaña (incluye cambios sin guardar).
    case document(UUID)
    /// Versión del archivo en HEAD de git.
    case head(UUID)
    /// Versión guardada en disco.
    case disk(UUID)

    var documentID: UUID {
        switch self {
        case .document(let id), .head(let id), .disk(let id): return id
        }
    }
}

/// Texto ya cargado de una fuente, listo para alinear.
struct CompareText {
    let title: String
    let text: String
}

enum CompareLoader {
    /// Carga el texto de `source`; el IO (git, disco) va fuera del hilo principal y `completion`
    /// siempre vuelve en el principal. El error es el mensaje para la alerta.
    static func load(_ source: CompareSource, tabs: TabsViewModel,
                     completion: @escaping (Result<CompareText, CompareLoadError>) -> Void) {
        guard let document = tabs.documents.first(where: { $0.id == source.documentID }) else {
            completion(.failure(CompareLoadError(L("La pestaña ya no está abierta."))))
            return
        }
        let name = document.displayName
        func finish(_ text: String, _ title: String) {
            let text = withoutLeadingBOM(text)
            if compareTooLarge(text) || gitLines(text).count > compareMaxLines {
                completion(.failure(CompareLoadError(L("El archivo es demasiado grande para comparar (más de 5 MB o 50 000 líneas)."))))
            } else {
                completion(.success(CompareText(title: title, text: text)))
            }
        }
        switch source {
        case .document:
            finish(tabs.text(of: document), name)
        case .disk:
            guard let url = document.url else {
                completion(.failure(CompareLoadError(L("El documento no tiene versión guardada."))))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let data = try? Data(contentsOf: url)
                let decoded = data.map { decodeWithDetectedEncoding($0).text }
                DispatchQueue.main.async {
                    if let decoded {
                        finish(decoded, L("\(name) (guardado)"))
                    } else {
                        completion(.failure(CompareLoadError(L("No se pudo leer el archivo del disco."))))
                    }
                }
            }
        case .head:
            let noHead = CompareLoadError(L("No hay versión en HEAD"))
            guard let url = document.url else { completion(.failure(noHead)); return }
            let encoding = document.encoding
            GitTool.repoRoot(for: url.deletingLastPathComponent()) { root in
                guard let root, let relative = GitTool.relativePath(of: url, in: root) else {
                    completion(.failure(noHead))
                    return
                }
                GitTool.lookupHeadBlob(repo: root, relativePath: relative) { result in
                    guard case .blob(let data) = result else {
                        DispatchQueue.main.async { completion(.failure(noHead)) }
                        return
                    }
                    // Mismo decodificado que GitGutter.decodeBase: encoding del documento.
                    DispatchQueue.global(qos: .userInitiated).async {
                        let text = String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
                        DispatchQueue.main.async { finish(text, L("\(name) (HEAD)")) }
                    }
                }
            }
        }
    }

    private static func withoutLeadingBOM(_ text: String) -> String {
        text.unicodeScalars.first == "\u{FEFF}" ? String(text.unicodeScalars.dropFirst()) : text
    }
}

struct CompareLoadError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension TabsViewModel {
    func compareActiveWithHead() {
        guard let document = activeDocument, document.url != nil else { return }
        CompareWindowController.show(left: .head(document.id), right: .document(document.id), tabs: self)
    }

    func compareActiveWithDisk() {
        guard let document = activeDocument, document.url != nil else { return }
        CompareWindowController.show(left: .disk(document.id), right: .document(document.id), tabs: self)
    }

    /// `other` a la izquierda, la pestaña activa a la derecha (la activa es "la nueva").
    func compareActive(with other: UUID) {
        guard let document = activeDocument, document.id != other else { return }
        CompareWindowController.show(left: .document(other), right: .document(document.id), tabs: self)
    }
}
