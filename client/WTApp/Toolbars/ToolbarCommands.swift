import AppKit
import SwiftUI

/// The toolbars' menu items (toolbars.adoc, "Showing, hiding, docking"; customizing.adoc):
/// menu:Window[Toolbars > <name>] checked while shown, Customize… and Reset Toolbars, and
/// menu:View[Toolbars] hiding and restoring every visible toolbar.
enum ToolbarCommands {
    enum ID {
        static let toggleAll: CommandID = "view.toolbars"
        static let customize: CommandID = "toolbars.customize"
        static let reset: CommandID = "toolbars.reset"

        static func show(_ toolbar: ToolbarID) -> CommandID { CommandID("toolbar.show.\(toolbar.rawValue)") }
    }

    static let submenu = "Toolbars"

    @MainActor
    static func commands(controller: ToolbarController, customize: @escaping @MainActor @Sendable () -> Void) -> [Command] {
        let window = StandardCommands.Menu.window
        let section = StandardCommands.Section.windowLayout
        var commands = ToolbarID.dockable.map { toolbar in
            Command(
                id: ID.show(toolbar), title: toolbar.title, menu: MenuPath(window, submenu, section: section), keywords: ["toolbar", "show", "hide"],
                validation: { .checked(controller.isVisible(toolbar)) },
                action: .perform { controller.toggle(toolbar) }
            )
        }
        commands += [
            Command(
                id: ID.customize, title: "Customize…", menu: MenuPath(window, submenu, section: section, subsection: 1), keywords: ["toolbar", "buttons"],
                action: .perform(customize)
            ),
            Command(
                id: ID.reset, title: "Reset Toolbars", menu: MenuPath(window, submenu, section: section, subsection: 1), keywords: ["toolbar", "factory"],
                action: .perform { controller.reset() }
            ),
            Command(
                id: ID.toggleAll, title: "Toolbars", menu: MenuPath(StandardCommands.Menu.view, section: StandardCommands.Section.viewPanels),
                keywords: ["hide", "show", "toolbar"],
                validation: { .checked(!controller.areHiddenByViewMenu) },
                action: .perform { controller.toggleAll() }
            ),
        ]
        return commands
    }
}

/// The dockable toolbars as panels of the panel framework (like the Tools panel, BASIC-009):
/// each is a one-panel group docked in the top strip when shown, closed in the factory layout,
/// floating or docked at any edge like any group, and listed under menu:Window[Toolbars]
/// rather than with the panels.
enum ToolbarPanels {
    static let firstPosition = 20

    @MainActor
    static func descriptors(controller: ToolbarController) -> [PanelDescriptor] {
        ToolbarID.dockable.enumerated().map { index, toolbar in
            var descriptor = PanelDescriptor(
                id: toolbar.panelID, title: toolbar.title, icon: "menubar.rectangle", defaultGroup: toolbar.defaultGroup,
                menuOrder: 100 + index, helpSlug: "toolbars"
            ) {
                ToolbarView(controller: controller, toolbar: toolbar)
            }
            descriptor.showsInWindowMenu = false
            return descriptor
        }
    }

    static var groupDefaults: [String: PanelGroupDefaults] {
        Dictionary(uniqueKeysWithValues: ToolbarID.dockable.enumerated().map { index, toolbar in
            (toolbar.defaultGroup, PanelGroupDefaults(position: firstPosition + index, isOpen: false, edge: .top))
        })
    }

    @MainActor
    static func register(into registry: PanelRegistry, controller: ToolbarController) {
        registry.groupDefaults.merge(groupDefaults) { current, _ in current }
        for descriptor in descriptors(controller: controller) { registry.registerIfAbsent(descriptor) }
    }
}

/// Everything the toolbars and extensions add to the app, installed by `AppDelegate` in one
/// call: the extension menu and registry, the toolbar panels and commands, the Customize
/// Toolbars window, Manage Extensions, and the Tools panel's customized buttons.
@MainActor
final class ToolbarFeatures {
    let extensions: ExtensionRegistry
    let controller: ToolbarController
    let manageExtensions: ManageExtensionsController
    private(set) var customizeWindow: CustomizeToolbarsWindowController?
    /// The window sheets attach to (the front document window).
    var parentWindow: @MainActor () -> NSWindow? = { nil }
    /// The menu bar must be rebuilt (an extension turned off or on).
    var onMenuChange: @MainActor () -> Void = {}

    init(commands: CommandRegistry, layout: PanelLayoutController, tools: ToolRegistry, defaults: UserDefaults?, store: ToolbarStore?) {
        extensions = ExtensionRegistry(defaults: defaults)
        controller = ToolbarController(commands: commands, layout: layout, extensions: extensions, tools: tools, store: store)
        manageExtensions = ManageExtensionsController(registry: extensions)
    }

    /// Registers the commands and panels.  `perform` runs a command as its menu item would.
    func install(commands: CommandRegistry, panels: PanelRegistry, palette: ToolPaletteModel, preferences: PreferenceStore, perform: @escaping @MainActor (CommandID) -> Bool) {
        controller.perform = perform
        for placeholder in ToolbarCatalog.placeholders { commands.registerIfAbsent(placeholder) }
        let extensions = extensions
        let showManage: @MainActor @Sendable () -> Void = { [weak self] in self?.showManageExtensions() }
        let sync: @MainActor () -> Void = { ExtensionCommands.sync(into: commands, registry: extensions, showManage: showManage) }
        sync()
        extensions.onChange = { [weak self] in
            sync()
            self?.controller.notify()
            self?.onMenuChange()
        }
        for command in ToolbarCommands.commands(controller: controller, customize: { [weak self] in self?.showCustomize() }) { commands.replace(command) }
        ToolbarPanels.register(into: panels, controller: controller)
        let controller = controller
        palette.extraItems = { AnyView(ToolbarViewRepresentable(controller: controller, toolbar: .tools)) }
        controller.showsTooltips = preferences[PreferenceCatalog.Panels.showTooltips]
        preferences.observe { [weak self] change in
            guard change.id == PreferenceCatalog.Panels.showTooltips.id else { return }
            self?.controller.showsTooltips = preferences[PreferenceCatalog.Panels.showTooltips]
        }
    }

    @discardableResult
    func showManageExtensions() -> NSWindow {
        manageExtensions.show(attachedTo: parentWindow())
    }

    @discardableResult
    func showCustomize() -> CustomizeToolbarsWindowController {
        let window = customizeWindow ?? CustomizeToolbarsWindowController(controller: controller)
        customizeWindow = window
        window.show()
        return window
    }
}
