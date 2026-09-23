import AppKit

/// The Main toolbar (toolbars.adoc, "The Main toolbar"; BASIC-010): the document window's own
/// `NSToolbar`, whose items are the command registry's commands, so the standard customization
/// sheet (menu:View[Customize Toolbar…]) offers every command in the application.  An item runs
/// its command exactly as the menu does and is enabled exactly when the command validates.
/// The configuration autosaves under the toolbar's identifier, so every window shares it and a
/// customized set survives relaunch.
@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    static let identifier = NSToolbar.Identifier("com.villagecompute.wiretuner.main")
    static let itemPrefix = "command."

    /// The default set, left to right.
    static let defaultCommands: [CommandID] = [
        StandardCommands.ID.new, StandardCommands.ID.open, MainToolbarController.saveVersion, MainToolbarController.importFile,
        StandardCommands.ID.print, ContextMenuCatalog.ID.lock, ContextMenuCatalog.ID.unlock,
        PanelCommands.ID.show("findReplace"), PanelCommands.ID.show("align"), PanelCommands.ID.show("transform"),
        PanelCommands.ID.show("library"), PanelCommands.ID.show("object"), PanelCommands.ID.show("colorMixer"),
        PanelCommands.ID.show("swatches"), PanelCommands.ID.show("layers"), ContextMenuCatalog.ID.share,
    ]
    static let saveVersion = StandardCommands.ID.saveVersion
    static let importFile = StandardCommands.ID.importFile

    /// The toolbar's own labels where the command's title is a menu wording.
    static let labels: [CommandID: String] = [
        saveVersion: "Save Version", importFile: "Import", StandardCommands.ID.print: "Print", StandardCommands.ID.open: "Open",
        PanelCommands.ID.show("findReplace"): "Find & Replace", ContextMenuCatalog.ID.share: "Share",
    ]

    static let symbols: [CommandID: String] = [
        StandardCommands.ID.new: "doc.badge.plus", StandardCommands.ID.open: "folder", saveVersion: "clock.badge.checkmark",
        importFile: "square.and.arrow.down", StandardCommands.ID.print: "printer", ContextMenuCatalog.ID.lock: "lock",
        ContextMenuCatalog.ID.unlock: "lock.open", PanelCommands.ID.show("findReplace"): "magnifyingglass",
        PanelCommands.ID.show("align"): "align.horizontal.left", PanelCommands.ID.show("transform"): "arrow.up.and.down.and.arrow.left.and.right",
        PanelCommands.ID.show("library"): "books.vertical", PanelCommands.ID.show("object"): "square.on.circle",
        PanelCommands.ID.show("colorMixer"): "paintpalette", PanelCommands.ID.show("swatches"): "swatchpalette",
        PanelCommands.ID.show("layers"): "square.3.layers.3d", ContextMenuCatalog.ID.share: "square.and.arrow.up",
    ]

    let environment: DocumentEnvironment
    let toolbar: NSToolbar

    init(environment: DocumentEnvironment, window: NSWindow?, identifier: NSToolbar.Identifier = MainToolbarController.identifier) {
        self.environment = environment
        toolbar = NSToolbar(identifier: identifier)
        super.init()
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .unifiedCompact
    }

    static func itemIdentifier(for id: CommandID) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(itemPrefix + id.rawValue)
    }

    static func commandID(of identifier: NSToolbarItem.Identifier) -> CommandID? {
        guard identifier.rawValue.hasPrefix(itemPrefix) else { return nil }
        return CommandID(String(identifier.rawValue.dropFirst(itemPrefix.count)))
    }

    /// The commands the toolbar may show: every registered command (menu and palette alike).
    var availableCommands: [Command] { environment.commands.commands }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultCommands.map(Self.itemIdentifier(for:))
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let commands = availableCommands.map { Self.itemIdentifier(for: $0.id) }
        let defaults = toolbarDefaultItemIdentifiers(toolbar).filter { !commands.contains($0) }
        return defaults + commands + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let id = Self.commandID(of: itemIdentifier) else { return nil }
        return item(for: id)
    }

    /// The item for `id`: its label, symbol and tooltip (name and shortcut), running the
    /// command.  An id no command has yet (a feature not installed) is a disabled item.
    func item(for id: CommandID) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.itemIdentifier(for: id))
        let command = environment.commands.command(id)
        let title = Self.labels[id] ?? command.map { $0.title.replacingOccurrences(of: "…", with: "") } ?? id.rawValue
        item.label = title
        item.paletteLabel = title
        let key = environment.shortcuts().keyEquivalent(for: id)
        item.toolTip = key.map { "\(title) (\($0.displayString))" } ?? title
        item.image = NSImage(systemSymbolName: Self.symbols[id] ?? "command", accessibilityDescription: title)
        item.target = self
        item.action = #selector(runItem(_:))
        item.autovalidates = true
        return item
    }

    @objc func runItem(_ sender: NSToolbarItem) {
        guard let id = Self.commandID(of: sender.itemIdentifier) else { return }
        _ = environment.perform(id)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let id = Self.commandID(of: item.itemIdentifier), let validation = environment.commands.validate(id) else { return false }
        if !validation.isEnabled, let reason = validation.reason { item.toolTip = "\(item.label) — \(reason)" }
        return validation.isEnabled
    }
}
