import Foundation

/// Persistencia de sesión (Task 13): pestañas abiertas (URL, orden, viewState), índice
/// activo y carpeta raíz del árbol, para restaurar todo al relanzar la app.
///
/// Sandboxing: la app corre SIN App Sandbox. `AppResources/GNotePP.entitlements` es un
/// plist vacío (sin `com.apple.security.app-sandbox`) — el comentario del propio archivo
/// dice explícitamente que es "el mínimo que exige el hardened runtime para notarizar" y
/// que el sandboxing quedaría para el futuro. `scripts/make_app_bundle.sh` firma ad-hoc
/// (`codesign --sign -`, sin perfil de distribución) y `scripts/release_notarize.sh` es
/// notarización de app fuera de la Mac App Store, que no exige sandbox. Por eso acá se
/// usan bookmarks PLANOS (`bookmarkData()` sin `.withSecurityScope`): ese flag solo
/// aplica (y solo hace falta) bajo App Sandbox. Un bookmark plano ya resuelve lo que pide
/// la task — que el archivo siga encontrándose si se movió mientras la app no corría.
enum SessionStore {
    private static let defaultsKey = "session.v1"

    struct Snapshot: Codable {
        struct Tab: Codable {
            var bookmark: Data?
            var viewState: ViewState?
            var backupFile: String?
            var untitledName: String?
            var encodingName: String?
            var eol: Int?
            var forcedLanguageName: String?
            var diskStamp: FileStamp?
        }
        var tabs: [Tab]
        var activeIndex: Int?
        var rootFolderBookmark: Data?
    }

    // MARK: - Guardar

    /// Al salir (applicationShouldTerminate / willTerminate) y, con respaldo activo, desde el
    /// tick de SessionBackup cuando cambian las pestañas o sus respaldos. Los sin título solo
    /// se guardan si tienen respaldo: sin él no hay nada que reabrir.
    static func save(tabs: TabsViewModel, fileTree: FileTreeViewModel) {
        // Vuelca selección/scroll vigentes del documento activo a su Document.viewState
        // antes de leerlo: SCI_SETDOCPOINTER solo lo hace al cambiar de pestaña, y acá
        // la pestaña activa nunca se "cambió".
        tabs.saveViewStateOfActive()

        var sessionTabs: [Snapshot.Tab] = []
        var activeIndexInSnapshot: Int?
        for (index, document) in tabs.documents.enumerated() {
            let bookmark: Data?
            if let url = document.url {
                guard let data = try? url.bookmarkData() else { continue }
                bookmark = data
            } else {
                // Sin título: solo vale reabrirlo si hay un respaldo con su texto.
                guard document.backupFileName != nil else { continue }
                bookmark = nil
            }
            if index == tabs.activeIndex {
                activeIndexInSnapshot = sessionTabs.count
            }
            sessionTabs.append(Snapshot.Tab(
                bookmark: bookmark,
                viewState: document.viewState,
                backupFile: document.backupFileName,
                untitledName: document.url == nil ? document.displayName : nil,
                encodingName: document.encodingName,
                eol: document.eol.rawValue,
                forcedLanguageName: document.forcedLanguageName,
                diskStamp: document.diskStamp
            ))
        }

        let rootBookmark = fileTree.root.flatMap { try? $0.url.bookmarkData() }

        let snapshot = Snapshot(tabs: sessionTabs, activeIndex: activeIndexInSnapshot, rootFolderBookmark: rootBookmark)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - Restaurar

    /// `finderURLs`: archivos pedidos por "Abrir con" del Finder al lanzar la app (pueden
    /// venir vacíos). Por brief: la sesión se restaura igual, y esos archivos se abren
    /// después, quedando como pestaña activa final (tabs.open(url:) siempre activa lo que
    /// abre). Si no hay sesión guardada ni finderURLs, se crea un documento "Nuevo" vacío
    /// — mismo comportamiento que la app tenía antes de esta task.
    static func restore(tabs: TabsViewModel, fileTree: FileTreeViewModel, actions: DocumentActions, finderURLs: [URL]) {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            // Sin sesión ninguna pestaña referencia respaldos: los que hubiera son de una
            // sesión perdida y nadie los borraría después.
            SessionBackup.deleteAll()
            for url in finderURLs { tabs.open(url: url) }
            if tabs.documents.isEmpty { tabs.newDocument() }
            return
        }

        if let rootBookmark = snapshot.rootFolderBookmark, let rootURL = resolvedURL(from: rootBookmark) {
            actions.openFolder(url: rootURL)
        }

        // El índice original del snapshot puede no corresponder ya a `documents` una vez
        // restaurado: pestañas cuyo bookmark no resuelve, o cuyo open() falla, se saltean. Por
        // eso se recuerda el Document restaurado desde la pestaña que estaba activa al guardar
        // (incluye sin título, que no tienen URL), nunca la posición numérica original.
        let backupEnabled = tabs.preferences.backupEnabled
        // Con la preferencia apagada no hay nada que recuperar: archivos desde disco y las
        // pestañas sin título se pierden, como antes del respaldo.
        if !backupEnabled { SessionBackup.deleteAll() }
        var activeDocument: Document?
        var referencedBackups = Set<String>()

        for (index, tab) in snapshot.tabs.enumerated() {
            let document: Document?
            if backupEnabled, let backupFile = tab.backupFile,
               let backupText = try? String(contentsOf: SessionBackup.directory.appendingPathComponent(backupFile), encoding: .utf8) {
                document = restoreFromBackup(tab, backupFile: backupFile, text: backupText, tabs: tabs)
            } else {
                // Respaldo inexistente (la escritura asíncrona pudo fallar): el archivo se abre
                // desde disco y un sin título no tiene nada que reabrir.
                document = restoreFromDisk(tab, tabs: tabs)
            }
            guard let document else { continue }
            if index == snapshot.activeIndex { activeDocument = document }
            if let name = document.backupFileName { referencedBackups.insert(name) }
        }
        if backupEnabled { SessionBackup.deleteOrphans(referenced: referencedBackups) }

        if let activeDocument, let index = tabs.documents.firstIndex(where: { $0 === activeDocument }) {
            let alreadyActive = tabs.activeIndex == index
            tabs.activate(at: index)
            // activate(at:) hace early-return si el índice pedido ya era el activo (caso
            // típico: la última pestaña abierta arriba también es la que estaba activa al
            // guardar la sesión) — reaplicar acá cubre ese caso; restoreViewState() es
            // idempotente.
            tabs.restoreViewState(of: activeDocument)
            // Por el mismo early-return, un conflicto de disco de la pestaña activa no se
            // preguntaría hasta salir de ella y volver.
            if alreadyActive { tabs.resolveDeferredExternalChange(of: activeDocument) }
        }

        for url in finderURLs {
            tabs.open(url: url)
        }

        if tabs.documents.isEmpty {
            tabs.newDocument()
        }
    }

    /// Pestaña sin respaldo: como siempre, abre el archivo desde disco.
    private static func restoreFromDisk(_ tab: Snapshot.Tab, tabs: TabsViewModel) -> Document? {
        // Bookmark no resuelve (archivo borrado/movido a un volumen no montado): se
        // omite sin error, tal como pide la verificación manual de la task.
        guard let bookmark = tab.bookmark, let url = resolvedURL(from: bookmark),
              tabs.open(url: url),
              let document = tabs.documents.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL })
        else { return nil }
        applyViewState(tab.viewState, to: document, tabs: tabs)
        return document
    }

    /// Pestaña con respaldo: base = disco (vacío si es sin título o ya no existe) y encima
    /// el texto respaldado, sucia y con ⌘Z a la versión base. Conserva nombre, encoding, EOL
    /// y lenguaje del snapshot.
    private static func restoreFromBackup(_ tab: Snapshot.Tab, backupFile: String, text: String, tabs: TabsViewModel) -> Document? {
        var url: URL?
        if let bookmark = tab.bookmark {
            guard let resolved = bookmarkedURL(bookmark) else { return nil }
            // Sesión con el mismo archivo dos veces: dos documentos del mismo archivo se pisarían.
            if tabs.documents.contains(where: { $0.url?.standardizedFileURL == resolved.standardizedFileURL }) { return nil }
            url = resolved
        }
        let savedEncoding = tab.encodingName.flatMap(stringEncoding(named:))
        var baseText = ""
        var encoding = savedEncoding ?? .utf8
        var encodingName = tab.encodingName ?? "UTF-8"
        var detectedEOL: EOLMode?
        if let url, let data = try? Data(contentsOf: url) {
            if let savedEncoding, let decoded = String(data: data, encoding: savedEncoding) {
                baseText = decoded
            } else {
                let file = decodeWithDetectedEncoding(data)
                baseText = file.text
                encoding = file.encoding
                encodingName = file.encodingName
                detectedEOL = file.eol
            }
        }
        let eol = tab.eol.flatMap(EOLMode.init(rawValue:)) ?? detectedEOL ?? .lf
        let profile = tab.forcedLanguageName.map { languageProfile(byLanguageName: $0, theme: tabs.currentTheme) }
            ?? languageProfile(forExtension: url?.pathExtension ?? "", theme: tabs.currentTheme)
        let displayName = url?.lastPathComponent ?? tab.untitledName ?? L("sin título")

        guard let document = tabs.restoreFromBackup(
            text: text,
            baseText: baseText,
            url: url,
            displayName: displayName,
            profile: profile,
            encoding: encoding,
            encodingName: encodingName,
            eol: eol,
            locked: url.map(LockedFiles.isLocked) ?? false
        ) else { return nil }
        document.forcedLanguageName = tab.forcedLanguageName
        document.backupFileName = backupFile

        if let url {
            if let current = FileStamp.of(url) {
                if let saved = tab.diskStamp, saved != current {
                    // Con el stamp viejo y la marca, ExternalFileChanges pregunta al activar la
                    // pestaña (recargar y perder el respaldo, o mantenerlo) como con cualquier
                    // conflicto de cambios propios + disco cambiado.
                    document.diskStamp = saved
                    document.pendingExternalConflict = true
                } else {
                    document.diskStamp = current
                }
            } else {
                // Pestaña tachada; guardar vuelve a crear el archivo con el texto respaldado.
                document.diskStamp = tab.diskStamp
                document.missingOnDisk = true
            }
        }
        applyViewState(tab.viewState, to: document, tabs: tabs)
        return document
    }

    private static func applyViewState(_ viewState: ViewState?, to document: Document, tabs: TabsViewModel) {
        document.viewState = viewState
        // La apertura activa el documento vía appendAndActivate, y ESE camino llama
        // saveViewStateOfActive() sobre la pestaña saliente ANTES de agregar la nueva —
        // es decir, antes de que exista un "editor" apuntando al doc recién restaurado.
        // Si no se reaplica acá inmediatamente, la PRÓXIMA apertura pisaría el
        // viewState recién asignado (lo sobreescribiría con el (0,0) que el editor
        // tiene en este instante) al capturarlo de vuelta en su propio
        // saveViewStateOfActive(). Reaplicarlo ahora hace que ese saveViewStateOfActive
        // posterior capture el valor correcto en vez de perderlo.
        tabs.restoreViewState(of: document)
    }

    /// Como resolvedURL, pero un archivo borrado devuelve igual su ruta, guardada dentro del
    /// bookmark: el respaldo se restaura en una pestaña tachada. Borrar desde el Finder es
    /// mover a la Papelera y el bookmark lo sigue hasta ahí; se trata como borrado, igual que
    /// con la app abierta (FSEvents ve desaparecer la ruta original).
    private static func bookmarkedURL(_ bookmark: Data) -> URL? {
        if let url = resolvedURL(from: bookmark), !url.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) { return url }
        guard let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func stringEncoding(named name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private static func resolvedURL(from bookmark: Data) -> URL? {
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
}
