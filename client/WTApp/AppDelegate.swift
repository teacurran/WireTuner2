import AppKit
import Sparkle

/// The application delegate.  `@main` on an `NSApplicationDelegate` runs `NSApplicationMain`
/// and installs an instance of this class as the delegate; there is no storyboard, so the menu
/// bar and the window are built in code from the command and panel registries.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sparkle.  Not started until the distribution task ships an `SUPublicEDKey`; starting
    /// the updater without one is a fatal Sparkle error.  The menu item stays disabled until
    /// then because its command validates against `canCheckForUpdates`.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    let commands = CommandRegistry()
    let panels = PanelRegistry()
    let layout: PanelLayoutController

    /// The active shortcut set; BASIC-026 makes it selectable.
    private(set) var shortcuts: ShortcutSet
    private(set) var menuTarget: CommandMenuTarget?
    private(set) var mainWindowController: MainWindowController?

    /// - Parameter layoutStore: where the panel layout persists; `nil` keeps it in memory (tests).
    init(layoutStore: PanelLayoutStore?) {
        layout = PanelLayoutController(registry: panels, store: layoutStore)
        shortcuts = ShortcutSet.builtInDefault(commands: [])
        super.init()
    }

    override convenience init() {
        self.init(layoutStore: PanelLayoutStore(url: PanelLayoutStore.defaultURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let updater = updaterController
        StandardCommands.register(
            into: commands,
            updates: StandardCommands.UpdateHooks(
                canCheckForUpdates: { updater.updater.canCheckForUpdates },
                checkForUpdates: { updater.checkForUpdates(nil) }
            )
        )
        PlaceholderPanels.register(into: panels)
        layout.load()
        panels.onChange = { [weak self] in self?.panelsDidChange() }
        panelsDidChange()

        let controller = MainWindowController(panels: panels, layout: layout)
        controller.showWindow(nil)
        mainWindowController = controller
        NSApp.activate()
    }

    /// A panel was registered: give it a layout slot and a Window menu item.
    func panelsDidChange() {
        layout.addRegisteredPanels()
        PanelCommands.sync(into: commands, panels: panels, layout: layout)
        rebuildMainMenu()
    }

    func rebuildMainMenu() {
        shortcuts = ShortcutSet.builtInDefault(commands: commands.commands)
        let target = CommandMenuTarget(registry: commands)
        menuTarget = target
        NSApp.mainMenu = MainMenuBuilder.menuBar(registry: commands, shortcuts: shortcuts, target: target)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
