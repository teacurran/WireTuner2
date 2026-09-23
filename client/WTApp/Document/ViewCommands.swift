import Foundation
import WTRender

/// The View, File and Window commands the document window delivers in place of the standard
/// placeholders (document-view.adoc, "The View menu"): Zoom In/Out, the Fit commands, every
/// magnification preset (the menu bar's 25%–800% and the context menu's 6%–25,600%), New View,
/// the Rotate Canvas commands, Preview in Browser, Keyline and Fast Mode, Page Rulers, Lock and
/// Unlock (disabled while nothing is selected), Add Page, New Window, the tab menu's Close Tab
/// and Close Other Tabs, and File > New.  Each acts on the key document window.
enum ViewCommands {
    static let noDocument = "No document is open"
    static let nothingSelected = "Nothing is selected"
    static let namedViewsPending = "Named views arrive with the named-view commands"
    static let lockPending = "Locking arrives with the object commands"

    /// What the commands need beyond the key window.
    struct Hooks {
        var newDocument: @MainActor @Sendable () -> Void = {}
        /// menu:Window[New Window]; nil leaves the placeholder.
        var documents: DocumentController?
        var browserPreview: BrowserPreview?
        /// The *Preview browser* preference's application, if one is chosen.
        var previewBrowser: @MainActor @Sendable () -> URL? = { nil }
    }

    @MainActor
    static func commands(target: @escaping @MainActor @Sendable () -> DocumentWindowController?, hooks: Hooks) -> [Command] {
        let ids = StandardCommands.ID.self
        let menu = StandardCommands.Menu.view
        let zoom = StandardCommands.Section.viewZoom
        let places = StandardCommands.Section.viewPlaces
        let needsWindow: @MainActor @Sendable () -> CommandValidation = { target() == nil ? .disabled(noDocument) : .enabled }
        func windowCommand(
            _ id: CommandID, _ title: String, _ key: KeyEquivalent?, menu path: MenuPath?, keywords: [String] = [],
            _ run: @escaping @MainActor @Sendable (DocumentWindowController) -> Void
        ) -> Command {
            Command(
                id: id, title: title, key: key, menu: path, keywords: keywords,
                validation: needsWindow, action: .perform { if let window = target() { run(window) } }
            )
        }
        var commands: [Command] = [
            windowCommand(ids.zoomIn, "Zoom In", KeyEquivalent("=", .command), menu: MenuPath(menu, section: zoom), keywords: ["magnify"]) { $0.zoomIn() },
            windowCommand(ids.zoomOut, "Zoom Out", KeyEquivalent("-", .command), menu: MenuPath(menu, section: zoom), keywords: ["magnify"]) { $0.zoomOut() },
            windowCommand(ids.fitPage, "Fit to Page", KeyEquivalent("w", [.command, .shift]), menu: MenuPath(menu, section: zoom)) { $0.fitPage() },
            windowCommand(ids.fitAll, "Fit All", KeyEquivalent("w", [.command, .option, .shift]), menu: MenuPath(menu, section: zoom)) { $0.fitAll() },
            Command(
                id: ids.fitSelection, title: "Fit Selection", key: KeyEquivalent("0", [.command, .option]), menu: MenuPath(menu, section: zoom),
                validation: {
                    guard let window = target() else { return .disabled(noDocument) }
                    return window.selection.model.isEmpty ? .disabled(nothingSelected) : .enabled
                },
                action: .perform { target()?.fitSelection() }
            ),
        ]
        for percent in ContextMenuCatalog.contextMagnifications {
            let level = StandardCommands.magnificationLevels.first { $0.percent == percent }
            let value = Double(percent)
            commands.append(Command(
                id: ids.magnification(percent), title: "\(percent)%", key: level?.key,
                menu: level.map { _ in MenuPath(menu, StandardCommands.Menu.magnification, section: zoom) }, keywords: ["zoom", "magnification"],
                validation: {
                    guard let window = target() else { return .disabled(noDocument) }
                    return .checked(abs(window.viewport.zoom * 100 - value) < 0.005)
                },
                action: .perform { target()?.zoom(toPercent: value) }
            ))
        }
        commands += [
            windowCommand(ids.customNew, "New…", nil, menu: MenuPath(menu, StandardCommands.Menu.custom, section: places), keywords: ["named view", "custom view"]) {
                $0.presentNamedViewSheet(target: $0.viewport)
            },
            .placeholder(id: ids.customEdit, title: "Edit…", menu: MenuPath(menu, StandardCommands.Menu.custom, section: places), keywords: ["named view"]).disabled(namedViewsPending),
            .placeholder(id: ids.customPrevious, title: "Previous", menu: MenuPath(menu, StandardCommands.Menu.custom, section: places, subsection: 1), keywords: ["named view"]).disabled(namedViewsPending),
            windowCommand(ids.rotateClockwise, "Rotate Clockwise", nil, menu: MenuPath(menu, StandardCommands.Menu.rotateCanvas, section: places), keywords: ["turn", "canvas"]) {
                $0.rotateCanvas(steps: -1)
            },
            windowCommand(ids.rotateCounterClockwise, "Rotate Counter-clockwise", nil, menu: MenuPath(menu, StandardCommands.Menu.rotateCanvas, section: places), keywords: ["turn", "canvas"]) {
                $0.rotateCanvas(steps: 1)
            },
            Command(
                id: ids.rotateReset, title: "Reset", menu: MenuPath(menu, StandardCommands.Menu.rotateCanvas, section: places, subsection: 1), keywords: ["straighten", "canvas"],
                validation: { target() == nil ? .disabled(noDocument) : .enabled },
                action: .perform { target()?.resetRotation() }
            ),
            previewCommand(target: target, hooks: hooks),
            Command(
                id: ids.keyline, title: "Keyline", key: KeyEquivalent("k", .command), menu: MenuPath(menu, section: StandardCommands.Section.viewModes), keywords: ["preview", "mode"],
                validation: { target().map { .checked($0.viewMode.isKeyline) } ?? .disabled(noDocument) },
                action: .perform { target()?.toggleKeyline() }
            ),
            Command(
                id: ids.fastMode, title: "Fast Mode", key: KeyEquivalent("k", [.command, .shift]), menu: MenuPath(menu, section: StandardCommands.Section.viewModes),
                validation: { target().map { .checked($0.viewMode.isFast) } ?? .disabled(noDocument) },
                action: .perform { target()?.toggleFastMode() }
            ),
            Command(
                id: ids.pageRulers, title: "Show", menu: MenuPath(menu, StandardCommands.Menu.pageRulers, section: StandardCommands.Section.viewRulers), keywords: ["rulers"],
                validation: { target().map { .checked($0.pageRulersVisible) } ?? .disabled(noDocument) },
                action: .perform { target()?.togglePageRulers() }
            ),
            lockCommand(ContextMenuCatalog.ID.lock, "Lock", KeyEquivalent("l", .command), target: target),
            lockCommand(ContextMenuCatalog.ID.unlock, "Unlock", KeyEquivalent("l", [.command, .shift]), target: target),
            windowCommand(ContextMenuCatalog.ID.addPage, "Add Page", nil, menu: MenuPath(ContextMenuCatalog.Menu.object, "Page", section: 2), keywords: ["page"]) {
                $0.addPage()
            },
            Command(
                id: ids.new, title: "New", key: KeyEquivalent("n", .command), menu: MenuPath(StandardCommands.Menu.file), keywords: ["document"],
                action: .perform(hooks.newDocument)
            ),
            .responder(id: ContextMenuCatalog.ID.closeTab, title: "Close Tab", menu: MenuPath(StandardCommands.Menu.window, section: StandardCommands.Section.windowArrange), keywords: ["tab"], selector: "performClose:"),
            windowCommand(ContextMenuCatalog.ID.closeOtherTabs, "Close Other Tabs", nil, menu: MenuPath(StandardCommands.Menu.window, section: StandardCommands.Section.windowArrange), keywords: ["tab"]) {
                $0.closeOtherTabs()
            },
        ]
        if let documents = hooks.documents {
            commands.append(Command(
                id: ids.newWindow, title: "New Window", menu: MenuPath(StandardCommands.Menu.window), keywords: ["view", "another view"],
                validation: {
                    guard let window = target() else { return .disabled(noDocument) }
                    return documents.canOpenView(of: window.documentHandle.id) ? .enabled : .disabled(DocumentController.tooManyViews)
                },
                action: .perform { documents.newView() }
            ))
        }
        return commands
    }

    @MainActor
    private static func previewCommand(target: @escaping @MainActor @Sendable () -> DocumentWindowController?, hooks: Hooks) -> Command {
        let preview = hooks.browserPreview
        let browser = hooks.previewBrowser
        return Command(
            id: StandardCommands.ID.previewInBrowser, title: "Preview in Browser", key: KeyEquivalent("return", .command),
            menu: MenuPath(StandardCommands.Menu.view, section: StandardCommands.Section.viewBrowser), keywords: ["web", "html", "svg"],
            validation: { preview?.validation(hasDocument: target() != nil) ?? .disabled(BrowserPreview.unavailableReason) },
            action: .perform {
                guard let preview, let window = target() else { return }
                _ = try? preview.preview(window.documentHandle, pageIndex: window.documentHandle.currentPageIndex, browser: browser())
            }
        )
    }

    /// Lock and Unlock: disabled with no selection (and, until the object commands land,
    /// disabled with a reason when something is selected).
    @MainActor
    private static func lockCommand(_ id: CommandID, _ title: String, _ key: KeyEquivalent, target: @escaping @MainActor @Sendable () -> DocumentWindowController?) -> Command {
        Command(
            id: id, title: title, key: key, menu: MenuPath(ContextMenuCatalog.Menu.modify, section: 1),
            validation: {
                guard let window = target() else { return .disabled(noDocument) }
                return window.selection.model.isEmpty ? .disabled(nothingSelected) : .disabled(lockPending)
            },
            action: .perform(Command.noop)
        )
    }

    @MainActor
    static func install(into registry: CommandRegistry, target: @escaping @MainActor @Sendable () -> DocumentWindowController?, hooks: Hooks) {
        for command in commands(target: target, hooks: hooks) { registry.replace(command) }
    }

    /// APP-002's form: the key window and File > New.
    @MainActor
    static func install(into registry: CommandRegistry, target: @escaping @MainActor @Sendable () -> DocumentWindowController?, newDocument: @escaping @MainActor @Sendable () -> Void) {
        install(into: registry, target: target, hooks: Hooks(newDocument: newDocument))
    }
}

extension Command {
    /// The same command, disabled with `reason` (a placeholder with a specific explanation).
    func disabled(_ reason: String) -> Command {
        var copy = self
        copy.validation = { .disabled(reason) }
        return copy
    }
}
