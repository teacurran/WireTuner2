import Foundation

/// The commands the panel framework contributes to the registry: one Window menu item per
/// registered panel (checked while the panel is in front), menu:View[Panels] and
/// menu:Window[Panel Layout > Reset to Default].
enum PanelCommands {
    enum ID {
        static let togglePanels: CommandID = "view.panels"
        static let resetLayout: CommandID = "panels.resetLayout"

        static func show(_ panel: PanelID) -> CommandID { CommandID("panel.show.\(panel.rawValue)") }
    }

    static let layoutSubmenu = "Panel Layout"

    @MainActor
    static func showCommand(for descriptor: PanelDescriptor, layout: PanelLayoutController) -> Command {
        let panel = descriptor.id
        return Command(
            id: ID.show(panel), title: descriptor.title,
            menu: MenuPath(StandardCommands.Menu.window, section: StandardCommands.Section.windowPanels),
            keywords: ["panel", "show", descriptor.defaultGroup],
            validation: { .checked(layout.isVisible(panel)) },
            action: .perform { layout.togglePanel(panel) }
        )
    }

    @MainActor
    static func frameworkCommands(layout: PanelLayoutController) -> [Command] {
        [
            Command(
                id: ID.togglePanels, title: "Panels",
                menu: MenuPath(StandardCommands.Menu.view, section: StandardCommands.Section.viewPanels),
                keywords: ["hide", "show", "dock"],
                validation: { .checked(!layout.panelsHidden) },
                action: .perform { layout.toggleAllPanels() }
            ),
            Command(
                id: ID.resetLayout, title: "Reset to Default",
                menu: MenuPath(StandardCommands.Menu.window, layoutSubmenu, section: StandardCommands.Section.windowLayout),
                keywords: ["panel", "layout", "factory"],
                action: .perform { layout.resetToDefault() }
            ),
        ]
    }

    @MainActor
    static func commands(panels: PanelRegistry, layout: PanelLayoutController) -> [Command] {
        panels.descriptors.map { showCommand(for: $0, layout: layout) } + frameworkCommands(layout: layout)
    }

    /// Registers the panel commands that are not registered yet; returns the ids added.
    /// Idempotent, so it runs again whenever a panel is registered.
    @discardableResult
    @MainActor
    static func sync(into registry: CommandRegistry, panels: PanelRegistry, layout: PanelLayoutController) -> [CommandID] {
        commands(panels: panels, layout: layout).filter { registry.registerIfAbsent($0) }.map(\.id)
    }
}
