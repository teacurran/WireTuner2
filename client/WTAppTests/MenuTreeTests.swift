import AppKit
import Foundation
import Testing
@testable import WireTuner

@Suite @MainActor struct MenuTreeTests {
    private func standardRegistry() -> (CommandRegistry, ShortcutSet) {
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        return (registry, ShortcutSet.builtInDefault(commands: registry.commands))
    }

    @Test func buildsTheStandardMenuBar() {
        let (registry, shortcuts) = standardRegistry()
        let tree = MenuTreeBuilder.build(registry: registry, shortcuts: shortcuts)
        #expect(tree.titles == Self.menusWithoutExtensions)
        // Every command with a menu path is in the tree; the context menu's extra
        // magnifications are palette- and context-only.
        #expect(Set(tree.commandIDs) == Set(registry.commands.filter { $0.menuPath != nil }.map(\.id)))
        #expect(tree.items(inMenu: "Nope") == nil)

        // The View menu follows the page's table.
        let view = tree.items(inMenu: "View")!
        #expect(view.map(\.title) == Self.viewMenuTitles)
        #expect(view[0] == .item(MenuItemNode(commandID: StandardCommands.ID.fitSelection, title: "Fit Selection", key: KeyEquivalent("0", [.command, .option]))))
        guard case let .submenu(title, levels) = view[3] else { Issue.record("expected the Magnification submenu"); return }
        #expect(title == "Magnification")
        #expect(levels.map(\.title) == ["25%", "50%", "100%", "200%", "400%", "800%"])
        #expect(levels[2].commandID == StandardCommands.ID.magnification(100))
        #expect(view.filter { $0 == .separator }.count == 8)

        let app = tree.items(inMenu: "WireTuner")!
        #expect(app.map(\.title) == ["About WireTuner", "Check for Updates…", nil, "Settings…", nil, "Hide WireTuner", "Hide Others", "Show All", nil, "Quit WireTuner"])
        #expect(tree.items(inMenu: "Edit")!.last == .item(MenuItemNode(commandID: StandardCommands.ID.keyboardShortcuts, title: "Keyboard Shortcuts…", key: nil)))
    }

    // Font and Glyph come with the typeface commands (TypefaceFeatures), not the standard registry.
    static let menusWithoutExtensions = MenuTreeBuilder.standardMenuOrder.filter { !["Extensions", "Font", "Glyph", "Scripts"].contains($0) }
    static let viewMenuTitles: [String?] = [
        "Fit Selection", "Fit to Page", "Fit All", "Magnification", "Zoom In", "Zoom Out", nil,
        "Custom", "Rotate Canvas", nil, "Preview in Browser", nil, "Keyline", "Fast Mode", nil,
        "Panels", "Toolbars", "Show Tab Bar", "Customize Toolbar…", nil, "Page Rulers", "Text Rulers", "Grid", "Guides", nil,
        "Snap to Point", "Snap to Object", "Smart Guides", nil, "Perspective Grid", nil, "Show All", "Hide Selection", "Collaborators",
    ]

    @Test func usesTheActiveShortcutSet() {
        let (registry, shortcuts) = standardRegistry()
        var custom = shortcuts.copy(name: "Custom")
        custom.bind(KeyEquivalent("j", .command), to: StandardCommands.ID.zoomIn)
        // The first key of a binding is the one the menu shows.
        var tree = MenuTreeBuilder.build(registry: registry, shortcuts: custom)
        #expect(tree.items(inMenu: "View")![4] == .item(MenuItemNode(commandID: StandardCommands.ID.zoomIn, title: "Zoom In", key: KeyEquivalent("=", .command))))
        custom.unbind(KeyEquivalent("=", .command), from: StandardCommands.ID.zoomIn)
        tree = MenuTreeBuilder.build(registry: registry, shortcuts: custom)
        #expect(tree.items(inMenu: "View")![4] == .item(MenuItemNode(commandID: StandardCommands.ID.zoomIn, title: "Zoom In", key: KeyEquivalent("j", .command))))
    }

    @Test func ordersUnknownMenusAfterTheStandardOnes() throws {
        let (registry, shortcuts) = standardRegistry()
        try registry.register(Command(id: "x.a", title: "A", menu: MenuPath("Extras"), action: .perform(Command.noop)))
        try registry.register(Command(id: "x.b", title: "B", menu: MenuPath("Extras", "Deep", "Deeper", section: 1), action: .perform(Command.noop)))
        let tree = MenuTreeBuilder.build(registry: registry, shortcuts: shortcuts)
        #expect(tree.titles.last == "Extras")
        let extras = tree.items(inMenu: "Extras")!
        #expect(extras.count == 3)
        #expect(extras[2] == .submenu(title: "Deep", items: [.submenu(title: "Deeper", items: [.item(MenuItemNode(commandID: "x.b", title: "B", key: nil))])]))
        #expect(extras[2].commandIDs == ["x.b"])
        #expect(MenuTreeBuilder.orderedMenuTitles(["Z", "File", "A"], preferring: ["File", "Edit"]) == ["File", "Z", "A"])
        #expect(MenuNode.separator.commandID == nil)
        #expect(MenuNode.separator.title == nil)
    }

    @Test func skipsEmptyMenus() {
        let registry = CommandRegistry()
        let tree = MenuTreeBuilder.build(registry: registry, shortcuts: ShortcutSet.builtInDefault(commands: []))
        #expect(tree.menus.isEmpty)
    }

    @Test func buildsContextMenusFromContexts() throws {
        let (registry, shortcuts) = standardRegistry()
        try registry.register(Command(id: "obj.disabled", title: "Never", menu: MenuPath("Edit"), contexts: [.path], validation: { .disabled("no") }, action: .perform(Command.noop)))
        try registry.register(Command(id: "obj.dyn", title: "Static", menu: MenuPath("Help"), contexts: [.path], validation: { CommandValidation(title: "Dynamic") }, action: .perform(Command.noop)))
        let nodes = ContextMenuBuilder.nodes(registry: registry, contexts: [.path], shortcuts: shortcuts)
        #expect(nodes.map(\.title) == ["Cut", "Copy", "Clear", nil, "Dynamic"])
        #expect(nodes[0] == .item(MenuItemNode(commandID: StandardCommands.ID.cut, title: "Cut", key: KeyEquivalent("x", .command))))
        #expect(ContextMenuBuilder.nodes(registry: registry, contexts: [.swatch], shortcuts: shortcuts).isEmpty)
        let pasteboard = ContextMenuBuilder.nodes(registry: registry, contexts: [.pasteboard], shortcuts: shortcuts)
        #expect(pasteboard.compactMap(\.commandID) == [StandardCommands.ID.paste, StandardCommands.ID.selectAll].filter { id in
            registry.validate(id)!.isEnabled
        })
    }

    @Test func rendersNSMenusWithIdentifiersKeysAndTargets() {
        let (registry, shortcuts) = standardRegistry()
        let target = CommandMenuTarget(registry: registry)
        let menuBar = MainMenuBuilder.menuBar(registry: registry, shortcuts: shortcuts, target: target)
        #expect(menuBar.items.map(\.title) == Self.menusWithoutExtensions)
        #expect(NSApp.windowsMenu?.title == "Window")
        #expect(NSApp.helpMenu?.title == "Help")

        let edit = menuBar.item(withTitle: "Edit")!.submenu!
        let redo = edit.items[1]
        #expect(redo.title == "Redo")
        #expect(redo.identifier?.rawValue == "menu.edit.redo")
        #expect(redo.keyEquivalent == "z")
        #expect(redo.keyEquivalentModifierMask == [.command, .shift])
        #expect(redo.target == nil)
        #expect(redo.action == Selector(("redo:")))
        #expect(edit.items[2].isSeparatorItem)
        #expect(CommandMenuTarget.commandID(of: redo) == StandardCommands.ID.redo)

        let view = menuBar.item(withTitle: "View")!.submenu!
        let zoomIn = view.items[0]
        #expect(zoomIn.target === target)
        #expect(zoomIn.action == #selector(CommandMenuTarget.performCommand(_:)))
        #expect(view.item(withTitle: "Magnification")?.submenu?.items.count == 6)
        #expect(view.item(withTitle: "Magnification")?.submenu?.item(withTitle: "100%")?.keyEquivalent == "1")
    }

    @Test func targetValidatesAndPerforms() throws {
        let registry = CommandRegistry()
        let counter = Counter()
        try registry.register(Command(id: "go", title: "Go", menu: MenuPath("File"), validation: { .checked(counter.count > 0) }, action: .perform { counter.bump() }))
        try registry.register(Command(id: "renamed", title: "Plain", menu: MenuPath("File"), validation: { CommandValidation(title: "Fancy") }, action: .perform(Command.noop)))
        try registry.register(Command.placeholder(id: "later", title: "Later", menu: MenuPath("File")))
        let target = CommandMenuTarget(registry: registry)
        let menu = MainMenuBuilder.menuBar(registry: registry, shortcuts: ShortcutSet.builtInDefault(commands: registry.commands), target: target)
        let file = menu.item(withTitle: "File")!.submenu!
        let go = file.items[0], renamed = file.items[1], later = file.items[2]

        #expect(target.validateMenuItem(go))
        #expect(go.state == .off)
        target.performCommand(go)
        #expect(counter.count == 1)
        #expect(target.validateMenuItem(go))
        #expect(go.state == .on)

        #expect(target.validateMenuItem(renamed))
        #expect(renamed.title == "Fancy")

        #expect(!target.validateMenuItem(later))
        #expect(later.toolTip == Command.placeholderReason)
        target.performCommand(later)

        let orphan = NSMenuItem(title: "Orphan", action: nil, keyEquivalent: "")
        #expect(!target.validateMenuItem(orphan))
        target.performCommand(orphan)
        orphan.representedObject = CommandID("missing")
        #expect(!target.validateMenuItem(orphan))
        #expect(counter.count == 1)

        try registry.register(Command.responder(id: "nowhere", title: "Nowhere", selector: "noSuchSelectorAnywhere:"))
        #expect(!target.perform("nowhere"))
        #expect(target.perform("go"))
        #expect(counter.count == 2)
    }

    @Test func rendersContextMenus() {
        let (registry, shortcuts) = standardRegistry()
        let target = CommandMenuTarget(registry: registry)
        let menu = MainMenuBuilder.contextMenu(registry: registry, contexts: [.textEditing], shortcuts: shortcuts, target: target)
        #expect(menu.items.map(\.title) == ["Cut", "Copy", "Paste"])
        #expect(menu.items[0].identifier?.rawValue == MainMenuBuilder.accessibilityIdentifier(for: StandardCommands.ID.cut))
        #expect(menu.items[0].keyEquivalent == "x")
    }
}
