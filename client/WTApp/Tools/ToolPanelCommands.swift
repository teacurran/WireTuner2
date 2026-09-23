import Foundation

/// The Tools panel's controls that are commands rather than tools (toolbars.adoc, "Colors
/// section" and "Snap section"): Swap, None and Default (palette-only, with shortcuts), and the
/// four snap toggles (View menu, checked, acting on the key window's `ViewState`).
enum ToolPanelCommands {
    enum ID {
        static let swap: CommandID = "colors.swap"
        static let none: CommandID = "colors.none"
        static let restoreDefault: CommandID = "colors.default"
    }

    static func snapCommandID(_ kind: SnapSettings.Kind) -> CommandID {
        CommandID("view.snap.\(kind.rawValue)")
    }

    static func snapKey(_ kind: SnapSettings.Kind) -> KeyEquivalent {
        switch kind {
        case .point: KeyEquivalent("'", .command)
        case .object: KeyEquivalent("'", [.command, .shift])
        case .grid: KeyEquivalent("g", [.command, .option])
        case .guides: KeyEquivalent(";", [.command, .option])
        }
    }

    @MainActor
    static func commands(palette: ToolPaletteModel, target: @escaping @MainActor @Sendable () -> DocumentWindowController?) -> [Command] {
        let wellValidation: @MainActor @Sendable () -> CommandValidation = {
            palette.canEditWells ? .enabled : .disabled("Changing the selection's colors arrives with the appearance commands")
        }
        var commands = [
            Command(id: ID.swap, title: "Swap Stroke and Fill", key: KeyEquivalent("x", .shift), keywords: ["colors", "wells"], validation: wellValidation, action: .perform { palette.swapWells() }),
            Command(id: ID.none, title: "None", key: KeyEquivalent("/"), keywords: ["colors", "no color"], validation: wellValidation, action: .perform { palette.setActiveWellToNone() }),
            Command(id: ID.restoreDefault, title: "Default Colors", key: KeyEquivalent("d", .shift), keywords: ["colors", "black", "white"], validation: wellValidation, action: .perform { palette.restoreDefaultWells() }),
        ]
        for kind in SnapSettings.Kind.allCases {
            commands.append(Command(
                id: snapCommandID(kind), title: kind.title, key: snapKey(kind), menu: MenuPath(StandardCommands.Menu.view, section: 3), keywords: ["snap"],
                validation: { target().map { .checked($0.snap[kind]) } ?? .disabled(ViewCommands.noDocument) },
                action: .perform { target()?.toggleSnap(kind) }
            ))
        }
        return commands
    }

    @MainActor
    static func install(into registry: CommandRegistry, palette: ToolPaletteModel, target: @escaping @MainActor @Sendable () -> DocumentWindowController?) {
        for command in commands(palette: palette, target: target) { registry.replace(command) }
    }
}

/// Native window tabbing's commands (workspace.adoc, "Tabs"; BASIC-001): menu:View[Show Tab
/// Bar], Control+Tab and Control+Shift+Tab, menu:Window[Move Tab to New Window] and
/// menu:Window[Merge All Windows].  AppKit implements and validates all of them on the
/// window.
enum WindowTabCommands {
    enum ID {
        static let showTabBar: CommandID = "view.showTabBar"
        static let nextTab: CommandID = "window.nextTab"
        static let previousTab: CommandID = "window.previousTab"
        static let moveTabToNewWindow: CommandID = "window.moveTabToNewWindow"
        static let mergeAllWindows: CommandID = "window.mergeAllWindows"
    }

    static func commands() -> [Command] {
        let window = StandardCommands.Menu.window
        let arrange = StandardCommands.Section.windowArrange
        return [
            .responder(id: ID.showTabBar, title: "Show Tab Bar", menu: MenuPath(StandardCommands.Menu.view, section: 5), keywords: ["tabs"], selector: "toggleTabBar:"),
            .responder(id: ID.nextTab, title: "Show Next Tab", key: KeyEquivalent("tab", .control), menu: MenuPath(window, section: arrange), keywords: ["tab", "document"], selector: "selectNextTab:"),
            .responder(id: ID.previousTab, title: "Show Previous Tab", key: KeyEquivalent("tab", [.control, .shift]), menu: MenuPath(window, section: arrange), keywords: ["tab", "document"], selector: "selectPreviousTab:"),
            .responder(id: ID.moveTabToNewWindow, title: "Move Tab to New Window", menu: MenuPath(window, section: arrange), keywords: ["tab"], selector: "moveTabToNewWindow:"),
            .responder(id: ID.mergeAllWindows, title: "Merge All Windows", menu: MenuPath(window, section: arrange), keywords: ["tab"], selector: "mergeAllWindows:"),
        ]
    }

    @MainActor
    static func install(into registry: CommandRegistry) {
        for command in commands() { registry.replace(command) }
    }
}
