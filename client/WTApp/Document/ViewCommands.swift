import Foundation

/// The View and File commands the document window delivers in place of the standard
/// placeholders: Zoom In/Out, Fit to Page, Fit All, Fit Selection (disabled while nothing is
/// selected), the Magnification presets, Keyline and Fast Mode (bound to the
/// window's `ViewMode`), and File > New.  Each acts on the key document window.
enum ViewCommands {
    static let noDocument = "No document is open"
    static let nothingSelected = "Nothing is selected"

    @MainActor
    static func commands(target: @escaping @MainActor @Sendable () -> DocumentWindowController?, newDocument: @escaping @MainActor @Sendable () -> Void) -> [Command] {
        let ids = StandardCommands.ID.self
        let menu = StandardCommands.Menu.view
        let needsWindow: @MainActor @Sendable () -> CommandValidation = { target() == nil ? .disabled(noDocument) : .enabled }
        func windowCommand(
            _ id: CommandID, _ title: String, _ key: KeyEquivalent?, section: Int = 0, contexts: Set<MenuContext> = [],
            keywords: [String] = [], _ run: @escaping @MainActor @Sendable (DocumentWindowController) -> Void
        ) -> Command {
            Command(
                id: id, title: title, key: key, menu: MenuPath(menu, section: section), contexts: contexts, keywords: keywords,
                validation: needsWindow, action: .perform { if let window = target() { run(window) } }
            )
        }
        var commands: [Command] = [
            windowCommand(ids.zoomIn, "Zoom In", KeyEquivalent("=", .command), contexts: [.pasteboard, .page], keywords: ["magnify"]) { $0.zoomIn() },
            windowCommand(ids.zoomOut, "Zoom Out", KeyEquivalent("-", .command), contexts: [.pasteboard, .page], keywords: ["magnify"]) { $0.zoomOut() },
            windowCommand(ids.fitPage, "Fit to Page", KeyEquivalent("w", [.command, .shift])) { $0.fitPage() },
            windowCommand(ids.fitAll, "Fit All", KeyEquivalent("w", [.command, .option, .shift])) { $0.fitAll() },
            Command(
                id: ids.fitSelection, title: "Fit Selection", key: KeyEquivalent("0", [.command, .option]), menu: MenuPath(menu),
                validation: {
                    guard let window = target() else { return .disabled(noDocument) }
                    return window.selection.model.isEmpty ? .disabled(nothingSelected) : .enabled
                },
                action: .perform { target()?.fitSelection() }
            ),
        ]
        for level in StandardCommands.magnificationLevels {
            let percent = Double(level.percent)
            commands.append(Command(
                id: ids.magnification(level.percent), title: "\(level.percent)%", key: level.key,
                menu: MenuPath(menu, StandardCommands.Menu.magnification, section: 1), keywords: ["zoom", "magnification"],
                validation: {
                    guard let window = target() else { return .disabled(noDocument) }
                    return .checked(abs(window.viewport.zoom * 100 - percent) < 0.005)
                },
                action: .perform { target()?.zoom(toPercent: percent) }
            ))
        }
        commands += [
            Command(
                id: ids.keyline, title: "Keyline", key: KeyEquivalent("k", .command), menu: MenuPath(menu, section: 2), keywords: ["preview", "mode"],
                validation: { target().map { .checked($0.viewMode.isKeyline) } ?? .disabled(noDocument) },
                action: .perform { target()?.toggleKeyline() }
            ),
            Command(
                id: ids.fastMode, title: "Fast Mode", key: KeyEquivalent("k", [.command, .shift]), menu: MenuPath(menu, section: 2),
                validation: { target().map { .checked($0.viewMode.isFast) } ?? .disabled(noDocument) },
                action: .perform { target()?.toggleFastMode() }
            ),
            Command(
                id: ids.new, title: "New", key: KeyEquivalent("n", .command), menu: MenuPath(StandardCommands.Menu.file), keywords: ["document"],
                action: .perform(newDocument)
            ),
        ]
        return commands
    }

    @MainActor
    static func install(into registry: CommandRegistry, target: @escaping @MainActor @Sendable () -> DocumentWindowController?, newDocument: @escaping @MainActor @Sendable () -> Void) {
        for command in commands(target: target, newDocument: newDocument) { registry.replace(command) }
    }
}
