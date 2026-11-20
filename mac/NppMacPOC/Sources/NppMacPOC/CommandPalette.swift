// Paleta de comandos (⇧⌘P): lista difusa de todos los ítems del menú principal.
import AppKit

struct MenuCommand {
    let title: String
    let path: [String]
    let shortcut: String?
    let isEnabled: Bool
    let isChecked: Bool
    weak var menu: NSMenu?
    let index: Int
    let item: NSMenuItem

    var key: String { (path + [title]).joined(separator: " › ") }
}

// BEGIN-PURE
func shortcutLabel(keyEquivalent: String, modifiers: NSEvent.ModifierFlags) -> String? {
    guard !keyEquivalent.isEmpty else { return nil }
    // Convención de AppKit: un keyEquivalent de letra en mayúscula ya implica ⇧ ("Z" + ⌘ = ⇧⌘Z).
    let upperLetter = keyEquivalent.count == 1 && keyEquivalent != keyEquivalent.lowercased()
    var out = ""
    if modifiers.contains(.control) { out += "⌃" }
    if modifiers.contains(.option) { out += "⌥" }
    if modifiers.contains(.shift) || upperLetter { out += "⇧" }
    if modifiers.contains(.command) { out += "⌘" }
    let special: [UInt32: String] = [
        0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→",
        0x0D: "↩", 0x03: "⌤", 0x09: "⇥", 0x1B: "⎋", 0x7F: "⌫", 0xF728: "⌦", 0x20: L("Espacio"),
        0xF729: "↖", 0xF72B: "↘", 0xF72C: "⇞", 0xF72D: "⇟",
    ]
    let scalar = keyEquivalent.unicodeScalars.first!.value
    if let s = special[scalar] {
        out += s
    } else if (0xF704...0xF70F).contains(scalar) {
        out += "F\(scalar - 0xF704 + 1)"
    } else {
        out += keyEquivalent.uppercased()
    }
    return out
}
// END-PURE

/// Las listas dinámicas largas (Recientes, Recargar como…) ensucian la paleta: se omiten si pasan de este tope.
private let maxDynamicSubmenuItems = 30

func collectMenuCommands(_ menu: NSMenu, path: [String] = []) -> [MenuCommand] {
    var result: [MenuCommand] = []
    // SwiftUI llena varios menús recién cuando se abren por primera vez (vía delegate): sin esto
    // la paleta abierta al arrancar veía ~90 de ~300 comandos.
    menu.delegate?.menuNeedsUpdate?(menu)
    menu.update()
    for (index, item) in menu.items.enumerated() {
        if item.isSeparatorItem || item.isHidden { continue }
        if let sub = item.submenu {
            sub.delegate?.menuNeedsUpdate?(sub)
            sub.update() // las listas dinámicas se pueblan aquí: el tope se cuenta después
            if sub.items.count > maxDynamicSubmenuItems { continue }
            result += collectMenuCommands(sub, path: path + [item.title])
        } else if item.action != nil {
            result.append(MenuCommand(
                title: item.title, path: path,
                shortcut: shortcutLabel(keyEquivalent: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask),
                isEnabled: item.isEnabled, isChecked: item.state == .on,
                menu: menu, index: index, item: item))
        }
    }
    return result
}

enum CommandPaletteRecents {
    private static let defaultsKey = "palette.recents"
    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [] }
    static func push(_ key: String) {
        var list = load().filter { $0 != key }
        list.insert(key, at: 0)
        UserDefaults.standard.set(Array(list.prefix(5)), forKey: defaultsKey)
    }
}

func showCommandPalette(_ panel: QuickPanelViewModel) {
    // Elegida desde el menú Vista, la acción corre mientras AppKit aún tiene el menú abierto y
    // recorrer `mainMenu` ahí no da ítems (la paleta salía vacía): se arma en el modo por
    // defecto del run loop, ya con el menú cerrado.
    RunLoop.main.perform(inModes: [.default]) { buildCommandPalette(panel) }
}

private func buildCommandPalette(_ panel: QuickPanelViewModel) {
    // El primer menú es el de la app (Acerca de, Salir…): fuera.
    let commands = (NSApp.mainMenu?.items.dropFirst() ?? []).flatMap { top -> [MenuCommand] in
        guard let sub = top.submenu else { return [] }
        return collectMenuCommands(sub, path: [top.title])
    }
    panel.show(placeholder: L("Buscar un comando…")) { query in
        func makeItem(_ c: MenuCommand, matched: [Int]) -> QuickPanelItem {
            // Dos ítems pueden compartir ruta y título (dos recientes "README.md"): el id de la fila
            // lleva además la identidad del NSMenuItem. Los recientes se siguen guardando por `key`.
            QuickPanelItem(id: "\(c.key)#\(ObjectIdentifier(c.item).hashValue)", title: c.title,
                           subtitle: c.path.joined(separator: " › "),
                           shortcut: c.shortcut, isEnabled: c.isEnabled, isChecked: c.isChecked,
                           matched: matched) {
                runMenuCommand(c)
            }
        }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            let byKey = Dictionary(commands.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let recents = CommandPaletteRecents.load().compactMap { byKey[$0] }
            let recentKeys = Set(recents.map(\.key))
            return (recents + commands.filter { !recentKeys.contains($0.key) }).map { makeItem($0, matched: []) }
        }
        return fuzzyRank(commands, query: query, key: { $0.title }, fileNameStart: { _ in nil },
                         limit: QuickPanelViewModel.maxRows)
            .map { makeItem($0.item, matched: $0.result.matched) }
    }
}

/// El menú de SwiftUI cambia con el estado: el índice del snapshot puede apuntar a otro ítem.
private func runMenuCommand(_ c: MenuCommand) {
    let item = c.item
    item.menu?.update()
    guard let action = item.action, item.isEnabled else { NSSound.beep(); return }
    CommandPaletteRecents.push(c.key)
    if let menu = c.menu, menu.items.indices.contains(c.index), menu.items[c.index] === item {
        menu.performActionForItem(at: c.index)
    } else {
        NSApp.sendAction(action, to: item.target, from: item)
    }
}
