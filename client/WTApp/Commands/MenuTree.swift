import Foundation

/// A menu item as data: the command it runs, the title to show and the key from the active
/// shortcut set.  `MainMenuBuilder` turns it into an `NSMenuItem`.
struct MenuItemNode: Equatable, Sendable {
    let commandID: CommandID
    let title: String
    let key: KeyEquivalent?
    /// A context menu's own wording ("Object Panel", "Follow Ana"): validation keeps it
    /// instead of the command's menu-bar title.
    var keepsTitle = false
}

/// One node of the menu tree.
indirect enum MenuNode: Equatable, Sendable {
    case item(MenuItemNode)
    case separator
    case submenu(title: String, items: [MenuNode])

    var title: String? {
        switch self {
        case let .item(item): item.title
        case .separator: nil
        case let .submenu(title, _): title
        }
    }

    var commandID: CommandID? {
        if case let .item(item) = self { return item.commandID }
        return nil
    }

    /// Every command id under this node, depth first.
    var commandIDs: [CommandID] {
        switch self {
        case let .item(item): [item.commandID]
        case .separator: []
        case let .submenu(_, items): items.flatMap(\.commandIDs)
        }
    }
}

/// The menu bar as a pure value: one `.submenu` per top-level menu.  Built by
/// `MenuTreeBuilder`, rendered by `MainMenuBuilder`, asserted on by tests.
struct MenuTree: Equatable, Sendable {
    var menus: [MenuNode]

    var titles: [String] { menus.compactMap(\.title) }

    /// The items of the top-level menu titled `title`.
    func items(inMenu title: String) -> [MenuNode]? {
        // A plain loop: `for case ... where` with an early return makes the Swift coverage
        // counters wrap negative, which the lcov converter rejects.
        for node in menus {
            if case let .submenu(menuTitle, items) = node, menuTitle == title { return items }
        }
        return nil
    }

    var commandIDs: [CommandID] { menus.flatMap(\.commandIDs) }
}

/// Builds `MenuTree`s from a registry and a shortcut set.  No AppKit.
enum MenuTreeBuilder {
    /// The order of the standard menus; menus the registry adds beyond these follow in the
    /// order they were first registered.
    static let standardMenuOrder = ["WireTuner", "File", "Edit", "View", "Modify", "Text", "Object", "Font", "Glyph", "Extensions", "Window", "Help"]

    @MainActor
    static func build(
        registry: CommandRegistry, shortcuts: ShortcutSet, menuOrder: [String] = standardMenuOrder
    ) -> MenuTree {
        let titles = orderedMenuTitles(registry.menuTitles, preferring: menuOrder)
        let menus = titles.compactMap { title -> MenuNode? in
            let items = nodes(for: registry.commands(inMenu: title), depth: 1, shortcuts: shortcuts)
            return items.isEmpty ? nil : .submenu(title: title, items: items)
        }
        return MenuTree(menus: menus)
    }

    static func orderedMenuTitles(_ titles: [String], preferring order: [String]) -> [String] {
        let present = Set(titles)
        return order.filter(present.contains) + titles.filter { !order.contains($0) }
    }

    /// Lays out `commands` (all sharing the first `depth` path components) as items,
    /// submenus and separators.  Sections are separated by a line; a command whose path is
    /// deeper than `depth` goes into a submenu named by its next component, placed where its
    /// first member appears.
    static func nodes(for commands: [Command], depth: Int, shortcuts: ShortcutSet) -> [MenuNode] {
        let sections = Dictionary(grouping: commands) { $0.menuPath?.section(atDepth: depth) ?? 0 }
        var result: [MenuNode] = []
        for section in sections.keys.sorted() {
            if !result.isEmpty { result.append(.separator) }
            result.append(contentsOf: sectionNodes(sections[section]!, depth: depth, shortcuts: shortcuts))
        }
        return result
    }

    private static func sectionNodes(_ commands: [Command], depth: Int, shortcuts: ShortcutSet) -> [MenuNode] {
        var result: [MenuNode] = []
        var submenuIndex: [String: Int] = [:]
        var submenuMembers: [String: [Command]] = [:]
        for command in commands {
            let components = command.menuPath?.components ?? []
            if components.count > depth {
                let title = components[depth]
                if submenuIndex[title] == nil {
                    submenuIndex[title] = result.count
                    result.append(.separator)  // placeholder, replaced below
                }
                submenuMembers[title, default: []].append(command)
            } else {
                result.append(.item(MenuItemNode(
                    commandID: command.id, title: command.title, key: shortcuts.keyEquivalent(for: command.id)
                )))
            }
        }
        for (title, index) in submenuIndex {
            let members = submenuMembers[title]!
            result[index] = .submenu(title: title, items: nodes(for: members, depth: depth + 1, shortcuts: shortcuts))
        }
        return result
    }
}

/// Context menus from the same registry (Context menus page).  The items of a context menu
/// are the registry's commands for the target's contexts that validate as enabled, in menu-bar
/// order, with a separator between commands from different top-level menus.
enum ContextMenuBuilder {
    @MainActor
    static func nodes(
        registry: CommandRegistry, contexts: Set<MenuContext>, shortcuts: ShortcutSet,
        menuOrder: [String] = MenuTreeBuilder.standardMenuOrder
    ) -> [MenuNode] {
        var result: [MenuNode] = []
        var previousMenu: String?
        for command in registry.commands(forContexts: contexts, menuOrder: menuOrder) {
            let validation = command.validation()
            guard validation.isEnabled else { continue }
            let menu = command.menuPath?.menu
            if !result.isEmpty, menu != previousMenu { result.append(.separator) }
            previousMenu = menu
            result.append(.item(MenuItemNode(
                commandID: command.id, title: validation.title ?? command.title,
                key: shortcuts.keyEquivalent(for: command.id)
            )))
        }
        return result
    }
}
