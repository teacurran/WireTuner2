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
        static let saveVersion: CommandID = "file.saveVersion"
        static let importFile: CommandID = "file.import"
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
        static let customNew: CommandID = "view.custom.new"
        static let customEdit: CommandID = "view.custom.edit"
        static let customPrevious: CommandID = "view.custom.previous"
        static let rotateClockwise: CommandID = "view.rotate.clockwise"
        static let rotateCounterClockwise: CommandID = "view.rotate.counterClockwise"
        static let rotateReset: CommandID = "view.rotate.reset"
        static let previewInBrowser: CommandID = "view.previewInBrowser"
        static let toolbars: CommandID = "view.toolbars"
        static let customizeToolbar: CommandID = "view.customizeToolbar"
        static let showTabBar: CommandID = "view.showTabBar"
        static let pageRulers: CommandID = "view.pageRulers.show"
        static let pageRulerUnits: CommandID = "view.pageRulers.editUnits"
        static let textRulers: CommandID = "view.textRulers"
        static let showGrid: CommandID = "view.grid.show"
        static let snapToGrid: CommandID = "view.snap.grid"
        static let editGrid: CommandID = "view.grid.edit"
        static let showGuides: CommandID = "view.guides.show"
        static let lockGuides: CommandID = "view.guides.lock"
        static let snapToGuides: CommandID = "view.snap.guides"
        static let editGuides: CommandID = "view.guides.edit"
        static let snapToPoint: CommandID = "view.snap.point"
        static let snapToObject: CommandID = "view.snap.object"
        static let perspectiveShow: CommandID = "view.perspective.show"
        static let perspectiveDefine: CommandID = "view.perspective.define"
        static let showAllObjects: CommandID = "view.showAll"
        static let hideSelection: CommandID = "view.hideSelection"

        static let minimize: CommandID = "window.minimize"
        static let zoomWindow: CommandID = "window.zoom"
        static let newWindow: CommandID = "window.newWindow"
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
        static let custom = "Custom"
        static let rotateCanvas = "Rotate Canvas"
        static let pageRulers = "Page Rulers"
        static let grid = "Grid"
        static let guides = "Guides"
        static let perspectiveGrid = "Perspective Grid"
    }

    /// Sections of the View and Window menus.  The View menu follows the page's table
    /// (document-view.adoc, "The View menu"): zoom, named views and rotation, Preview in
    /// Browser, drawing modes, panels and toolbars, rulers and grids, snapping, the perspective
    /// grid, show and hide.
    enum Section {
        static let viewZoom = 0
        static let viewPlaces = 1
        static let viewBrowser = 2
        static let viewModes = 3
        static let viewPanels = 4
        static let viewRulers = 5
        static let viewSnap = 6
        static let viewPerspective = 7
        static let viewVisibility = 8
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
        ContextMenuCatalog.register(into: registry)
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
            .placeholder(id: ID.saveVersion, title: "Save Version…", key: KeyEquivalent("s", .command), menu: MenuPath(menu, section: 1), keywords: ["save", "history"]),
            .placeholder(id: ID.importFile, title: "Import…", menu: MenuPath(menu, section: 2), keywords: ["place"]),
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
            .responder(id: ID.delete, title: "Clear", key: KeyEquivalent("delete"), menu: MenuPath(menu, section: 1), contexts: [.path, .text, .bitmap, .group, .multiple], keywords: ["delete"], selector: "delete:"),
            .responder(id: ID.selectAll, title: "Select All", key: KeyEquivalent("a", .command), menu: MenuPath(menu, section: 1), contexts: [.pasteboard, .page], selector: "selectAll:"),
            .placeholder(id: ID.keyboardShortcuts, title: "Keyboard Shortcuts…", menu: MenuPath(menu, section: 2), keywords: ["keys", "bindings"]),
        ]
    }

    private static func viewCommands() -> [Command] {
        let menu = Menu.view
        let zoom = Section.viewZoom
        var commands: [Command] = [
            .placeholder(id: ID.fitSelection, title: "Fit Selection", key: KeyEquivalent("0", [.command, .option]), menu: MenuPath(menu, section: zoom)),
            .placeholder(id: ID.fitPage, title: "Fit to Page", key: KeyEquivalent("w", [.command, .shift]), menu: MenuPath(menu, section: zoom), contexts: [.pasteboard, .page]),
            .placeholder(id: ID.fitAll, title: "Fit All", key: KeyEquivalent("w", [.command, .option, .shift]), menu: MenuPath(menu, section: zoom), contexts: [.pasteboard, .page]),
        ]
        for level in magnificationLevels {
            commands.append(.placeholder(
                id: ID.magnification(level.percent), title: "\(level.percent)%", key: level.key,
                menu: MenuPath(menu, Menu.magnification, section: zoom), keywords: ["zoom", "magnification"]
            ))
        }
        commands += [
            .placeholder(id: ID.zoomIn, title: "Zoom In", key: KeyEquivalent("=", .command), menu: MenuPath(menu, section: zoom), keywords: ["magnify"]),
            .placeholder(id: ID.zoomOut, title: "Zoom Out", key: KeyEquivalent("-", .command), menu: MenuPath(menu, section: zoom), keywords: ["magnify"]),
            .placeholder(id: ID.customNew, title: "New…", menu: MenuPath(menu, Menu.custom, section: Section.viewPlaces), keywords: ["named view", "custom view"]),
            .placeholder(id: ID.customEdit, title: "Edit…", menu: MenuPath(menu, Menu.custom, section: Section.viewPlaces), keywords: ["named view", "custom view"]),
            .placeholder(id: ID.customPrevious, title: "Previous", menu: MenuPath(menu, Menu.custom, section: Section.viewPlaces, subsection: 1), keywords: ["named view", "custom view"]),
            .placeholder(id: ID.rotateClockwise, title: "Rotate Clockwise", menu: MenuPath(menu, Menu.rotateCanvas, section: Section.viewPlaces), keywords: ["turn", "canvas"]),
            .placeholder(id: ID.rotateCounterClockwise, title: "Rotate Counter-clockwise", menu: MenuPath(menu, Menu.rotateCanvas, section: Section.viewPlaces), keywords: ["turn", "canvas"]),
            .placeholder(id: ID.rotateReset, title: "Reset", menu: MenuPath(menu, Menu.rotateCanvas, section: Section.viewPlaces, subsection: 1), keywords: ["straighten", "canvas"]),
            .placeholder(id: ID.previewInBrowser, title: "Preview in Browser", key: KeyEquivalent("return", .command), menu: MenuPath(menu, section: Section.viewBrowser), keywords: ["web", "html", "svg"]),
            .placeholder(id: ID.keyline, title: "Keyline", key: KeyEquivalent("k", .command), menu: MenuPath(menu, section: Section.viewModes), keywords: ["preview", "mode"]),
            .placeholder(id: ID.fastMode, title: "Fast Mode", key: KeyEquivalent("k", [.command, .shift]), menu: MenuPath(menu, section: Section.viewModes)),
            .placeholder(id: PanelCommands.ID.togglePanels, title: "Panels", menu: MenuPath(menu, section: Section.viewPanels)),
            .placeholder(id: ID.toolbars, title: "Toolbars", menu: MenuPath(menu, section: Section.viewPanels), keywords: ["hide", "show"]),
            .placeholder(id: ID.showTabBar, title: "Show Tab Bar", menu: MenuPath(menu, section: Section.viewPanels), keywords: ["tabs"]),
            .responder(id: ID.customizeToolbar, title: "Customize Toolbar…", menu: MenuPath(menu, section: Section.viewPanels), keywords: ["main toolbar", "buttons"], selector: "runToolbarCustomizationPalette:"),
            .placeholder(id: ID.pageRulers, title: "Show", menu: MenuPath(menu, Menu.pageRulers, section: Section.viewRulers), keywords: ["rulers"]),
            .placeholder(id: ID.pageRulerUnits, title: "Edit Units…", menu: MenuPath(menu, Menu.pageRulers, section: Section.viewRulers, subsection: 1), keywords: ["rulers", "units"]),
            .placeholder(id: ID.textRulers, title: "Text Rulers", menu: MenuPath(menu, section: Section.viewRulers), keywords: ["rulers", "tabs"]),
            .placeholder(id: ID.showGrid, title: "Show", menu: MenuPath(menu, Menu.grid, section: Section.viewRulers), keywords: ["grid"]),
            .placeholder(id: ID.snapToGrid, title: "Snap to Grid", key: KeyEquivalent("g", [.command, .option]), menu: MenuPath(menu, Menu.grid, section: Section.viewRulers), keywords: ["snap"]),
            .placeholder(id: ID.editGrid, title: "Edit Grid…", menu: MenuPath(menu, Menu.grid, section: Section.viewRulers, subsection: 1), keywords: ["grid"]),
            .placeholder(id: ID.showGuides, title: "Show", menu: MenuPath(menu, Menu.guides, section: Section.viewRulers), keywords: ["guides"]),
            .placeholder(id: ID.lockGuides, title: "Lock", menu: MenuPath(menu, Menu.guides, section: Section.viewRulers), keywords: ["guides"]),
            .placeholder(id: ID.snapToGuides, title: "Snap to Guides", key: KeyEquivalent(";", [.command, .option]), menu: MenuPath(menu, Menu.guides, section: Section.viewRulers), keywords: ["snap"]),
            .placeholder(id: ID.editGuides, title: "Edit…", menu: MenuPath(menu, Menu.guides, section: Section.viewRulers, subsection: 1), contexts: [.guide], keywords: ["guides"]),
            .placeholder(id: ID.snapToPoint, title: "Snap to Point", key: KeyEquivalent("'", .command), menu: MenuPath(menu, section: Section.viewSnap), keywords: ["snap"]),
            .placeholder(id: ID.snapToObject, title: "Snap to Object", key: KeyEquivalent("'", [.command, .shift]), menu: MenuPath(menu, section: Section.viewSnap), keywords: ["snap"]),
            .placeholder(id: ID.smartGuides, title: "Smart Guides", key: KeyEquivalent("u", .command), menu: MenuPath(menu, section: Section.viewSnap), keywords: ["snap", "align"]),
            .placeholder(id: ID.perspectiveShow, title: "Show", menu: MenuPath(menu, Menu.perspectiveGrid, section: Section.viewPerspective), keywords: ["perspective"]),
            .placeholder(id: ID.perspectiveDefine, title: "Define Grids…", menu: MenuPath(menu, Menu.perspectiveGrid, section: Section.viewPerspective, subsection: 1), keywords: ["perspective"]),
            .placeholder(id: ID.showAllObjects, title: "Show All", key: KeyEquivalent("h", [.command, .shift, .option]), menu: MenuPath(menu, section: Section.viewVisibility), contexts: [.pasteboard, .page], keywords: ["hidden", "unhide"]),
            .placeholder(id: ID.hideSelection, title: "Hide Selection", key: KeyEquivalent("h", [.command, .shift]), menu: MenuPath(menu, section: Section.viewVisibility), contexts: ContextMenuCatalog.objectContexts, keywords: ["hide"]),
        ]
        return commands
    }

    private static func windowCommands() -> [Command] {
        let menu = Menu.window
        return [
            .responder(id: ID.minimize, title: "Minimize", key: KeyEquivalent("m", .command), menu: MenuPath(menu), selector: "performMiniaturize:"),
            .responder(id: ID.zoomWindow, title: "Zoom", menu: MenuPath(menu), selector: "performZoom:"),
            .placeholder(id: ID.newWindow, title: "New Window", menu: MenuPath(menu), keywords: ["view", "another view"]),
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
