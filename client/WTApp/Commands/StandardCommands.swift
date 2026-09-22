import Foundation

/// The application, File, Edit, View, Window and Help commands every build has.  Standard
/// AppKit behavior goes through the responder chain; commands a later task delivers are
/// placeholders (in the menu, disabled with a reason).  Panel commands come from
/// `PanelCommands`, which fills the View and Window sections left free here.
enum StandardCommands {
    enum ID {
        static let about: CommandID = "app.about"
        static let checkForUpdates: CommandID = "app.checkForUpdates"
        static let settings: CommandID = "app.settings"
        static let hide: CommandID = "app.hide"
        static let hideOthers: CommandID = "app.hideOthers"
        static let showAll: CommandID = "app.showAll"
        static let quit: CommandID = "app.quit"

        static let new: CommandID = "file.new"
        static let open: CommandID = "file.open"
        static let close: CommandID = "file.close"
        static let export: CommandID = "file.export"
        static let pageSetup: CommandID = "file.pageSetup"
        static let print: CommandID = "file.print"

        static let undo: CommandID = "edit.undo"
        static let redo: CommandID = "edit.redo"
        static let cut: CommandID = "edit.cut"
        static let copy: CommandID = "edit.copy"
        static let paste: CommandID = "edit.paste"
        static let delete: CommandID = "edit.delete"
        static let selectAll: CommandID = "edit.selectAll"
        static let keyboardShortcuts: CommandID = "edit.keyboardShortcuts"

        static let zoomIn: CommandID = "view.zoomIn"
        static let zoomOut: CommandID = "view.zoomOut"
        static let fitPage: CommandID = "view.fitPage"
        static let fitAll: CommandID = "view.fitAll"
        static let fitSelection: CommandID = "view.fitSelection"
        static func magnification(_ percent: Int) -> CommandID { CommandID("view.magnification.\(percent)") }
        static let keyline: CommandID = "view.keyline"
        static let fastMode: CommandID = "view.fastMode"
        static let smartGuides: CommandID = "view.smartGuides"

        static let minimize: CommandID = "window.minimize"
        static let zoomWindow: CommandID = "window.zoom"
        static let bringAllToFront: CommandID = "window.bringAllToFront"

        static let help: CommandID = "help.wireTunerHelp"
        static let commandPalette: CommandID = "help.commandPalette"
    }

    /// Menu titles.  The application menu's title is replaced by the app name at run time.
    enum Menu {
        static let application = "WireTuner"
        static let file = "File"
        static let edit = "Edit"
        static let view = "View"
        static let window = "Window"
        static let help = "Help"
        static let magnification = "Magnification"
    }

    /// Sections of the View and Window menus that `PanelCommands` fills.
    enum Section {
        static let viewPanels = 4
        static let windowPanels = 1
        static let windowLayout = 2
        static let windowArrange = 3
    }

    /// The Sparkle hooks, passed as closures so the registry has no Sparkle dependency and
    /// tests can register the commands without an updater.
    struct UpdateHooks: Sendable {
        var canCheckForUpdates: @MainActor @Sendable () -> Bool
        var checkForUpdates: @MainActor @Sendable () -> Void

        static let unavailable = UpdateHooks(canCheckForUpdates: { false }, checkForUpdates: {})
    }

    /// 25% has no default key: the documented Cmd+Shift+5 is macOS's screenshot toolbar, which
    /// the conflict report flags as reserved (Q-011 reconciles the page).
    static let magnificationLevels: [(percent: Int, key: KeyEquivalent?)] = [
        (25, nil), (50, KeyEquivalent("5", .command)),
        (100, KeyEquivalent("1", .command)), (200, KeyEquivalent("2", .command)),
        (400, KeyEquivalent("4", .command)), (800, KeyEquivalent("8", .command)),
    ]

    static func commands(updates: UpdateHooks = .unavailable) -> [Command] {
        applicationCommands(updates: updates) + fileCommands() + editCommands() + viewCommands()
            + windowCommands() + helpCommands()
    }

    /// Registers every standard command that is not already registered.
    @MainActor
    static func register(into registry: CommandRegistry, updates: UpdateHooks = .unavailable) {
        for command in commands(updates: updates) { registry.registerIfAbsent(command) }
    }

    private static func applicationCommands(updates: UpdateHooks) -> [Command] {
        let menu = Menu.application
        return [
            .responder(id: ID.about, title: "About WireTuner", menu: MenuPath(menu), selector: "orderFrontStandardAboutPanel:"),
            Command(
                id: ID.checkForUpdates, title: "Check for Updates…", menu: MenuPath(menu), keywords: ["sparkle", "version"],
                validation: { updates.canCheckForUpdates() ? .enabled : .disabled("Updates are not configured in this build") },
                action: .perform { updates.checkForUpdates() }
            ),
            .placeholder(id: ID.settings, title: "Settings…", key: KeyEquivalent(",", .command), menu: MenuPath(menu, section: 1), keywords: ["preferences"]),
            .responder(id: ID.hide, title: "Hide WireTuner", key: KeyEquivalent("h", .command), menu: MenuPath(menu, section: 2), selector: "hide:"),
            .responder(id: ID.hideOthers, title: "Hide Others", key: KeyEquivalent("h", [.command, .option]), menu: MenuPath(menu, section: 2), selector: "hideOtherApplications:"),
            .responder(id: ID.showAll, title: "Show All", menu: MenuPath(menu, section: 2), selector: "unhideAllApplications:"),
            .responder(id: ID.quit, title: "Quit WireTuner", key: KeyEquivalent("q", .command), menu: MenuPath(menu, section: 3), selector: "terminate:"),
        ]
    }

    private static func fileCommands() -> [Command] {
        let menu = Menu.file
        return [
            .placeholder(id: ID.new, title: "New", key: KeyEquivalent("n", .command), menu: MenuPath(menu), keywords: ["document"]),
            .placeholder(id: ID.open, title: "Open…", key: KeyEquivalent("o", .command), menu: MenuPath(menu), keywords: ["document", "library"]),
            .responder(id: ID.close, title: "Close", key: KeyEquivalent("w", .command), menu: MenuPath(menu, section: 1), selector: "performClose:"),
            .placeholder(id: ID.export, title: "Export…", key: KeyEquivalent("e", [.command, .shift]), menu: MenuPath(menu, section: 2)),
            .placeholder(id: ID.pageSetup, title: "Page Setup…", key: KeyEquivalent("p", [.command, .shift]), menu: MenuPath(menu, section: 3)),
            .placeholder(id: ID.print, title: "Print…", key: KeyEquivalent("p", .command), menu: MenuPath(menu, section: 3)),
        ]
    }

    private static func editCommands() -> [Command] {
        let menu = Menu.edit
        return [
            .responder(id: ID.undo, title: "Undo", key: KeyEquivalent("z", .command), menu: MenuPath(menu), selector: "undo:"),
            .responder(id: ID.redo, title: "Redo", key: KeyEquivalent("z", [.command, .shift]), menu: MenuPath(menu), selector: "redo:"),
            .responder(id: ID.cut, title: "Cut", key: KeyEquivalent("x", .command), menu: MenuPath(menu, section: 1), contexts: [.path, .text, .bitmap, .group, .multiple, .textEditing], selector: "cut:"),
            .responder(id: ID.copy, title: "Copy", key: KeyEquivalent("c", .command), menu: MenuPath(menu, section: 1), contexts: [.path, .text, .bitmap, .group, .multiple, .textEditing], selector: "copy:"),
            .responder(id: ID.paste, title: "Paste", key: KeyEquivalent("v", .command), menu: MenuPath(menu, section: 1), contexts: [.pasteboard, .page, .textEditing], selector: "paste:"),
            .responder(id: ID.delete, title: "Delete", key: KeyEquivalent("delete"), menu: MenuPath(menu, section: 1), contexts: [.path, .text, .bitmap, .group, .multiple, .guide], selector: "delete:"),
            .responder(id: ID.selectAll, title: "Select All", key: KeyEquivalent("a", .command), menu: MenuPath(menu, section: 1), contexts: [.pasteboard, .page, .textEditing], selector: "selectAll:"),
            .placeholder(id: ID.keyboardShortcuts, title: "Keyboard Shortcuts…", menu: MenuPath(menu, section: 2), keywords: ["keys", "bindings"]),
        ]
    }

    private static func viewCommands() -> [Command] {
        let menu = Menu.view
        var commands: [Command] = [
            .placeholder(id: ID.zoomIn, title: "Zoom In", key: KeyEquivalent("=", .command), menu: MenuPath(menu), contexts: [.pasteboard, .page], keywords: ["magnify"]),
            .placeholder(id: ID.zoomOut, title: "Zoom Out", key: KeyEquivalent("-", .command), menu: MenuPath(menu), contexts: [.pasteboard, .page], keywords: ["magnify"]),
            .placeholder(id: ID.fitPage, title: "Fit to Page", key: KeyEquivalent("w", [.command, .shift]), menu: MenuPath(menu)),
            .placeholder(id: ID.fitAll, title: "Fit All", key: KeyEquivalent("w", [.command, .option, .shift]), menu: MenuPath(menu)),
            .placeholder(id: ID.fitSelection, title: "Fit Selection", key: KeyEquivalent("0", [.command, .option]), menu: MenuPath(menu)),
        ]
        for level in magnificationLevels {
            commands.append(.placeholder(
                id: ID.magnification(level.percent), title: "\(level.percent)%", key: level.key,
                menu: MenuPath(menu, Menu.magnification, section: 1), keywords: ["zoom", "magnification"]
            ))
        }
        commands += [
            .placeholder(id: ID.keyline, title: "Keyline", key: KeyEquivalent("k", .command), menu: MenuPath(menu, section: 2), keywords: ["preview", "mode"]),
            .placeholder(id: ID.fastMode, title: "Fast Mode", key: KeyEquivalent("k", [.command, .shift]), menu: MenuPath(menu, section: 2)),
            .placeholder(id: ID.smartGuides, title: "Smart Guides", key: KeyEquivalent("u", .command), menu: MenuPath(menu, section: 3), keywords: ["snap", "align"]),
        ]
        return commands
    }

    private static func windowCommands() -> [Command] {
        let menu = Menu.window
        return [
            .responder(id: ID.minimize, title: "Minimize", key: KeyEquivalent("m", .command), menu: MenuPath(menu), selector: "performMiniaturize:"),
            .responder(id: ID.zoomWindow, title: "Zoom", menu: MenuPath(menu), selector: "performZoom:"),
            .responder(id: ID.bringAllToFront, title: "Bring All to Front", menu: MenuPath(menu, section: Section.windowArrange), selector: "arrangeInFront:"),
        ]
    }

    private static func helpCommands() -> [Command] {
        let menu = Menu.help
        return [
            .responder(id: ID.help, title: "WireTuner Help", key: KeyEquivalent("?", .command), menu: MenuPath(menu), keywords: ["guide", "manual"], selector: "showHelp:"),
            .placeholder(id: ID.commandPalette, title: "Command Palette…", key: KeyEquivalent("/", .command), menu: MenuPath(menu, section: 1), keywords: ["search", "run"]),
        ]
    }
}
