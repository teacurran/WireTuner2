import AppKit

/// The target of every menu item whose command is a closure: it validates the item from the
/// command's validation and runs the command.  Responder-chain commands bypass it (their items
/// have a nil target and the standard selector).
@MainActor
final class CommandMenuTarget: NSObject, NSMenuItemValidation {
    let registry: CommandRegistry

    init(registry: CommandRegistry) {
        self.registry = registry
    }

    static func commandID(of item: NSMenuItem) -> CommandID? {
        item.representedObject as? CommandID
    }

    @objc func performCommand(_ sender: NSMenuItem) {
        guard let id = Self.commandID(of: sender) else { return }
        perform(id)
    }

    /// Runs `id` as the menu would, responder-chain commands included.
    @discardableResult
    func perform(_ id: CommandID) -> Bool {
        registry.perform(id) { selector in
            NSApp.sendAction(Selector(selector), to: nil, from: nil)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = Self.commandID(of: item), let command = registry.command(id) else { return false }
        let validation = command.validation()
        item.state = validation.isChecked ? .on : .off
        if !(item is FixedTitleMenuItem) { item.title = validation.title ?? command.title }
        item.toolTip = validation.isEnabled ? nil : validation.reason
        return validation.isEnabled
    }
}

/// A menu item whose title the context menu chose; validation leaves it alone.
final class FixedTitleMenuItem: NSMenuItem {}

/// Renders a `MenuTree` into `NSMenu`s.  Thin by design: the tree carries titles, keys and
/// order; this only creates AppKit objects.
@MainActor
enum MainMenuBuilder {
    static let windowMenuTitle = "Window"
    static let helpMenuTitle = "Help"

    /// The delegate of the menu at a path of titles (`["Text", "Font"]`, a context menu's
    /// `["Context", "Font"]`) whose items are read when it opens -- menu:Text[Font]'s families --
    /// or nil for the menus the tree fully describes.  The delegate must outlive the menu
    /// (`NSMenu.delegate` is weak).
    static var dynamicMenus: @MainActor ([String]) -> (any NSMenuDelegate)? = { _ in nil }

    static func accessibilityIdentifier(for commandID: CommandID) -> String {
        "menu.\(commandID.rawValue)"
    }

    /// The menu bar.  The Window and Help menus are also installed as `NSApp.windowsMenu` and
    /// `NSApp.helpMenu` so AppKit lists windows and adds Spotlight-for-help.
    static func menuBar(from tree: MenuTree, registry: CommandRegistry, target: CommandMenuTarget) -> NSMenu {
        let menuBar = NSMenu(title: "Main")
        for case let .submenu(title, items) in tree.menus {
            let menu = menu(title: title, nodes: items, registry: registry, target: target)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            menuBar.addItem(item)
            if title == windowMenuTitle { NSApp.windowsMenu = menu }
            if title == helpMenuTitle { NSApp.helpMenu = menu }
        }
        return menuBar
    }

    /// Builds the current menu bar from a registry and the active shortcut set.
    static func menuBar(registry: CommandRegistry, shortcuts: ShortcutSet, target: CommandMenuTarget) -> NSMenu {
        menuBar(from: MenuTreeBuilder.build(registry: registry, shortcuts: shortcuts), registry: registry, target: target)
    }

    static func menu(title: String, nodes: [MenuNode], registry: CommandRegistry, target: CommandMenuTarget, path: [String] = []) -> NSMenu {
        let menu = NSMenu(title: title)
        let path = path + [title]
        menu.delegate = dynamicMenus(path)
        for node in nodes {
            switch node {
            case .separator:
                menu.addItem(.separator())
            case let .submenu(title, items):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = self.menu(title: title, nodes: items, registry: registry, target: target, path: path)
                menu.addItem(item)
            case let .item(node):
                menu.addItem(menuItem(for: node, registry: registry, target: target))
            }
        }
        return menu
    }

    static func menuItem(for node: MenuItemNode, registry: CommandRegistry, target: CommandMenuTarget) -> NSMenuItem {
        let item = node.keepsTitle ? FixedTitleMenuItem(title: node.title, action: nil, keyEquivalent: "") : NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier(for: node.commandID))
        item.representedObject = node.commandID
        KeyEquivalentResolver.apply(node.key, to: item)
        if let selector = registry.command(node.commandID)?.action.responderSelectorName {
            item.action = Selector(selector)
        } else {
            item.target = target
            item.action = #selector(CommandMenuTarget.performCommand(_:))
        }
        return item
    }

    /// A context menu for `contexts` from the same registry, with the menu bar's keys.
    static func contextMenu(
        registry: CommandRegistry, contexts: Set<MenuContext>, shortcuts: ShortcutSet, target: CommandMenuTarget
    ) -> NSMenu {
        let nodes = ContextMenuBuilder.nodes(registry: registry, contexts: contexts, shortcuts: shortcuts)
        return menu(title: "Context", nodes: nodes, registry: registry, target: target)
    }
}
