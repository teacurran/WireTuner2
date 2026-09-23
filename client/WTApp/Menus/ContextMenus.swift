import AppKit

extension ContextMenuBuilder {
    /// The menu for `target`: the catalog's layout for it, then any other registered command
    /// whose `contexts` include the target's (a feature's own additions, or a panel's commands,
    /// in menu-bar and registration order).  Disabled commands stay in the menu, greyed with
    /// their reason, so the menu's shape does not change with the selection.  Keys come from
    /// the active shortcut set, so every item shows the menu bar's shortcut.
    @MainActor
    static func nodes(
        for target: ContextMenuTarget, registry: CommandRegistry, shortcuts: ShortcutSet,
        menuOrder: [String] = MenuTreeBuilder.standardMenuOrder
    ) -> [MenuNode] {
        var nodes = render(ContextMenuCatalog.entries(for: target), target: target, registry: registry, shortcuts: shortcuts)
        let present = Set(nodes.flatMap(\.commandIDs))
        let extras = registry.commands(forContexts: target.contexts, menuOrder: menuOrder).filter { !present.contains($0.id) }
        if !extras.isEmpty {
            nodes.append(.separator)
            nodes += extras.map { node(for: $0, title: nil, target: target, shortcuts: shortcuts) }
        }
        return tidy(nodes)
    }

    @MainActor
    static func render(_ entries: [ContextMenuEntry], target: ContextMenuTarget, registry: CommandRegistry, shortcuts: ShortcutSet) -> [MenuNode] {
        entries.compactMap { entry -> MenuNode? in
            switch entry {
            case .separator:
                return .separator
            case let .command(id, title):
                return registry.command(id).map { node(for: $0, title: title, target: target, shortcuts: shortcuts) }
            case let .submenu(title, members):
                let items = tidy(render(members, target: target, registry: registry, shortcuts: shortcuts))
                return items.isEmpty ? nil : .submenu(title: title, items: items)
            }
        }
    }

    static func node(for command: Command, title: String?, target: ContextMenuTarget, shortcuts: ShortcutSet) -> MenuNode {
        var text = title ?? command.title
        if let name = target.name { text = text.replacingOccurrences(of: "<name>", with: name) }
        return .item(MenuItemNode(
            commandID: command.id, title: text, key: shortcuts.keyEquivalent(for: command.id), keepsTitle: text != command.title
        ))
    }

    /// Drops leading, trailing and doubled separators.
    static func tidy(_ nodes: [MenuNode]) -> [MenuNode] {
        var result: [MenuNode] = []
        for node in nodes {
            if node == .separator, result.last == .separator || result.isEmpty { continue }
            result.append(node)
        }
        if result.last == .separator { result.removeLast() }
        return result
    }
}

extension MainMenuBuilder {
    /// The context menu for `target` (BASIC-018, BASIC-019).
    static func contextMenu(
        for target: ContextMenuTarget, registry: CommandRegistry, shortcuts: ShortcutSet, menuTarget: CommandMenuTarget
    ) -> NSMenu {
        let nodes = ContextMenuBuilder.nodes(for: target, registry: registry, shortcuts: shortcuts)
        return menu(title: "Context", nodes: nodes, registry: registry, target: menuTarget)
    }
}
