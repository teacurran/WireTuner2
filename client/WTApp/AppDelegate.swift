import AppKit
import Sparkle

/// The application delegate.  `@main` on an `NSApplicationDelegate` runs `NSApplicationMain`
/// and installs an instance of this class as the delegate; there is no storyboard, so the menu
/// bar and the windows are built in code from the command, panel and tool registries.
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
    let tools = ToolRegistry()
    let layout: PanelLayoutController
    let preferences: PreferenceStore
    let toolPalette = ToolPaletteModel()
    /// The front window's selection, published to the panels.
    let activeSelection = ActiveSelection()
    private(set) var documents: DocumentController!
    private(set) var preferencesWindowController: PreferencesWindowController?
    let launchEnvironment: LaunchEnvironment
    /// The signed-in account (APP-008).
    let account: AccountModel
    private(set) var accountWindowController: AccountWindowController?
    /// The UI tests' socket audit, running only when the launch asked for it (DEBUG builds).
    let socketMonitor: SocketMonitor?

    /// The active shortcut set; BASIC-026 makes it selectable.
    private(set) var shortcuts: ShortcutSet
    private(set) var menuTarget: CommandMenuTarget?

    /// - Parameters:
    ///   - layoutStore: where the panel layout persists; `nil` keeps it in memory (tests).
    ///   - defaults: the preferences' `UserDefaults`.
    ///   - windowStates: where document window state persists; `nil` keeps none (tests).
    init(
        layoutStore: PanelLayoutStore?, defaults: UserDefaults = PreferenceStore.makeDefaults(), windowStates: WindowStateStore? = nil,
        launchEnvironment: LaunchEnvironment = LaunchEnvironment(), account: AccountModel? = nil
    ) {
        layout = PanelLayoutController(registry: panels, store: layoutStore)
        preferences = PreferenceStore(defaults: defaults)
        self.launchEnvironment = launchEnvironment
        self.account = account ?? launchEnvironment.makeAccountModel(infoDictionary: Bundle.main.infoDictionary, defaults: defaults)
        socketMonitor = launchEnvironment.auditsSockets ? SocketMonitor() : nil
        shortcuts = ShortcutSet.builtInDefault(commands: [])
        super.init()
        var environment = DocumentEnvironment(
            commands: commands, panels: panels, layout: layout, tools: tools, preferences: preferences,
            windowStates: windowStates,
            shortcuts: { [weak self] in self?.shortcuts ?? ShortcutSet.builtInDefault(commands: []) },
            perform: { [weak self] id in self?.menuTarget?.perform(id) ?? false }
        )
        if let socketMonitor {
            environment.diagnostics = { socketMonitor.counts.accessibilityText }
        }
        documents = DocumentController(environment: environment)
        socketMonitor?.onChange = { [weak self] _ in self?.socketCountsDidChange() }
        socketMonitor?.start()
    }

    override convenience init() {
        self.init(layoutStore: PanelLayoutStore(url: PanelLayoutStore.defaultURL), windowStates: WindowStateStore(url: WindowStateStore.defaultURL))
    }

    /// The front document window (the one the View menu acts on).
    var activeDocumentWindow: DocumentWindowController? { documents.activeWindowController }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let updater = updaterController
        StandardCommands.register(
            into: commands,
            updates: StandardCommands.UpdateHooks(
                canCheckForUpdates: { updater.updater.canCheckForUpdates },
                checkForUpdates: { updater.checkForUpdates(nil) }
            )
        )
        let documents = documents!
        ViewCommands.install(
            into: commands,
            target: { documents.activeWindowController },
            newDocument: { documents.newDocument() }
        )
        PreferenceCommands.install(into: commands, store: preferences) { [weak self] in self?.showPreferences() }
        installTools()
        AccountCommands.install(into: commands, model: account) { [weak self] in self?.showAccount() }
        let account = account
        Task { await account.start() }

        PlaceholderPanels.register(into: panels, selection: activeSelection)
        panels.registerIfAbsent(ToolsPanel.descriptor(model: toolPalette))
        layout.load()
        panels.onChange = { [weak self] in self?.panelsDidChange() }
        panelsDidChange()

        documents.onChange = { [weak self] in self?.documentsDidChange() }
        documents.newDocument()
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        documents.saveAllStates()
    }

    private func installTools() {
        tools.registerBuiltIn()
        SelectionCommands.install(commands: commands, tools: tools)
        let documents = documents!
        let toolCommands = tools.commands(
            activate: { id in documents.activeWindowController?.toolManager.select(id) },
            activeTool: { documents.activeWindowController?.toolManager.activeToolID }
        )
        for command in toolCommands { commands.replace(command) }
        toolPalette.reload(from: tools)
        toolPalette.select = { id in documents.activeWindowController?.toolManager.select(id) }
    }

    /// A panel was registered: give it a layout slot and a Window menu item.
    func panelsDidChange() {
        layout.addRegisteredPanels()
        PanelCommands.sync(into: commands, panels: panels, layout: layout)
        rebuildMainMenu()
    }

    /// The key window or its tool changed: the Tools panel follows it.
    func documentsDidChange() {
        toolPalette.activeToolID = documents.activeWindowController?.toolManager.activeToolID
        activeSelection.model = documents.activeWindowController?.selection.model
    }

    func rebuildMainMenu() {
        shortcuts = ShortcutSet.builtInDefault(commands: commands.commands)
        let target = CommandMenuTarget(registry: commands)
        menuTarget = target
        NSApp.mainMenu = MainMenuBuilder.menuBar(registry: commands, shortcuts: shortcuts, target: target)
    }

    /// menu:WireTuner[Settings…] (`Cmd+,`).
    func showPreferences() {
        let controller = preferencesWindowController ?? PreferencesWindowController(
            model: PreferencesWindowModel(store: preferences) { [weak self] in self?.layout.resetToDefault() }
        )
        preferencesWindowController = controller
        controller.show()
    }

    /// The audit's counts changed: every canvas republishes its accessibility value.
    func socketCountsDidChange() {
        for controller in documents.windowControllers.values { controller.canvas.updateAccessibilityValue() }
    }

    /// menu:WireTuner[Account…].
    func showAccount() {
        let controller = accountWindowController ?? AccountWindowController(model: account)
        accountWindowController = controller
        controller.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
