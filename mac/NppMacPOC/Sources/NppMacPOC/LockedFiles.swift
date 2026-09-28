import Foundation

/// Persistencia de qué archivos están bloqueados para edición, por ruta. Mismo patrón que
/// RecentPathsViewModel: standardizedFileURL.path como clave, una sola key de UserDefaults.
/// No es un ObservableObject: nada en la UI necesita observar el conjunto completo, solo
/// consultar/mutar una ruta puntual (Document.isLocked es la fuente de verdad en memoria;
/// esto es solo lo que sobrevive a cerrar y reabrir la app).
enum LockedFiles {
    private static let defaultsKey = "lockedPaths"

    private static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    private static func persist(_ paths: Set<String>) {
        UserDefaults.standard.set(Array(paths), forKey: defaultsKey)
    }

    static func isLocked(_ url: URL) -> Bool {
        load().contains(url.standardizedFileURL.path)
    }

    static func set(_ url: URL, locked: Bool) {
        var paths = load()
        let path = url.standardizedFileURL.path
        if locked {
            paths.insert(path)
        } else {
            paths.remove(path)
        }
        persist(paths)
    }

    /// Un archivo bloqueado que se mueve o renombra (guardar-como, renombrar desde el menú,
    /// renombrar desde el árbol en una task futura) tiene que seguir bloqueado en la ruta
    /// nueva. No-op si `from` no estaba bloqueado.
    static func move(from: URL, to: URL) {
        guard isLocked(from) else { return }
        var paths = load()
        paths.remove(from.standardizedFileURL.path)
        paths.insert(to.standardizedFileURL.path)
        persist(paths)
    }

    /// Igual que `move`, pero para renombrar/mover una CARPETA: reubica todo path bloqueado
    /// que viva bajo `oldPrefix` a la ruta equivalente bajo `newPrefix`, tenga o no una pestaña
    /// abierta. Sin esto, un archivo bloqueado que no estaba abierto al renombrar su carpeta
    /// quedaba con la ruta vieja huérfana en `lockedPaths` — perdía el bloqueo en la práctica
    /// (nadie vuelve a consultar esa ruta) sin que nada lo haya desbloqueado explícitamente.
    static func moveTree(from oldPrefix: URL, to newPrefix: URL) {
        let oldBase = oldPrefix.standardizedFileURL.path
        let oldDirPrefix = oldBase + "/"
        let newBase = newPrefix.standardizedFileURL.path
        var paths = load()
        var changed = false
        for path in paths {
            guard path.hasPrefix(oldDirPrefix) else { continue }
            let suffix = String(path.dropFirst(oldDirPrefix.count))
            paths.remove(path)
            paths.insert(newBase + "/" + suffix)
            changed = true
        }
        if changed {
            persist(paths)
        }
    }
}
