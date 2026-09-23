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
    /// What the Help panel shows (*Help for <panel>*).
    let helpModel = HelpPanelModel()
    /// The floating panel groups (BASIC-005).
    let floatingPanels: FloatingPanelsController
    /// Where the open windows are saved at quit (BASIC-001); nil keeps none (tests).
    let sessionStore: SessionStore?
    /// The front window's selection, published to the panels.
    let activeSelection = ActiveSelection()
    private(set) var documents: DocumentController!
    private(set) var preferencesWindowController: PreferencesWindowController?
    let launchEnvironment: LaunchEnvironment
    /// The signed-in account (APP-008).
    let account: AccountModel
    private(set) var accountWindowController: AccountWindowController?
    /// The document library (APP-009).
    let library: LibraryModel
    private(set) var libraryWindowController: LibraryWindowController?
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
        launchEnvironment: LaunchEnvironment = LaunchEnvironment(), account: AccountModel? = nil,
        libraryStore: LibraryCacheStore? = nil, thumbnailDirectory: URL? = nil, library: LibraryModel? = nil,
        sessionStore: SessionStore? = nil
    ) {
        layout = PanelLayoutController(registry: panels, store: layoutStore)
        preferences = PreferenceStore(defaults: defaults)
        floatingPanels = FloatingPanelsController(panels: panels, layout: layout)
        self.sessionStore = sessionStore
        self.launchEnvironment = launchEnvironment
        self.account = account ?? launchEnvironment.makeAccountModel(infoDictionary: Bundle.main.infoDictionary, defaults: defaults)
        let account = self.account
        self.library = library ?? launchEnvironment.makeLibraryModel(
            account: account, infoDictionary: Bundle.main.infoDictionary, defaults: defaults, store: libraryStore,
            thumbnails: ThumbnailCache(directory: thumbnailDirectory)
        )
        socketMonitor = launchEnvironment.auditsSockets ? SocketMonitor() : nil
        shortcuts = ShortcutSet.builtInDefault(commands: [])
        super.init()
        var environment = DocumentEnvironment(
            commands: commands, panels: panels, layout: layout, tools: tools, preferences: preferences,
            windowStates: windowStates,
            shortcuts: { [weak self] in self?.shortcuts ?? ShortcutSet.builtInDefault(commands: []) },
            perform: { [weak self] id in self?.menuTarget?.perform(id) ?? false }
        )
        environment.showHelp = { [weak self] descriptor in self?.showHelp(for: descriptor) }
        if let socketMonitor {
            environment.diagnostics = { socketMonitor.counts.accessibilityText }
        }
        documents = DocumentController(environment: environment)
        socketMonitor?.onChange = { [weak self] _ in self?.socketCountsDidChange() }
        socketMonitor?.start()
    }

    override convenience init() {
        self.init(
            layoutStore: PanelLayoutStore(url: PanelLayoutStore.defaultURL), windowStates: WindowStateStore(url: WindowStateStore.defaultURL),
            libraryStore: LibraryCacheStore(url: LibraryCacheStore.defaultURL), thumbnailDirectory: ThumbnailCache.defaultDirectory,
            sessionStore: SessionStore(url: SessionStore.defaultURL)
        )
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
        let library = library
        library.onOpen = { opened in
            for document in opened { documents.open(DocumentHandle.placeholder(id: document.id, title: document.name)) }
        }
        ViewCommands.install(
            into: commands,
            target: { documents.activeWindowController },
            newDocument: { library.createDocument() }
        )
        LibraryCommands.install(into: commands) { [weak self] in self?.showLibrary() }
        PreferenceCommands.install(into: commands, store: preferences) { [weak self] in self?.showPreferences() }
        installTools()
        AccountCommands.install(into: commands, model: account) { [weak self] in self?.showAccount() }
        let account = account
        Task { await account.start() }

        PanelCatalog.register(into: panels, selection: activeSelection, help: helpModel)
        panels.registerIfAbsent(ToolsPanel.descriptor(model: toolPalette))
        layout.load()
        panels.onChange = { [weak self] in self?.panelsDidChange() }
        panelsDidChange()
        connectFloatingPanels()

        documents.onChange = { [weak self] in self?.documentsDidChange() }
        if restoreSession().isEmpty { documents.newDocument() }
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        documents.saveAllStates()
        try? sessionStore?.save(documents.sessionState())
    }

    /// Reopens the last session's windows when this launch restores sessions; a trashed
    /// document is skipped.
    @discardableResult
    func restoreSession() -> [DocumentWindowController] {
        guard launchEnvironment.restoresSession, let sessionStore else { return [] }
        let library = library
        return documents.restore(sessionStore.load()) { id in library.cache.documents[id]?.isTrashed != true }
    }

    private func connectFloatingPanels() {
        let preferences = preferences
        floatingPanels.interaction.appearance = { PanelAppearance(preferences: preferences) }
        floatingPanels.interaction.onHelp = { [weak self] descriptor in self?.showHelp(for: descriptor) }
        floatingPanels.parentWindow = { [weak self] in self?.activeDocumentWindow?.window }
        preferences.observe { [weak self] change in self?.preferenceDidChange(change) }
        toolPalette.showsTooltips = preferences[PreferenceCatalog.Panels.showTooltips]
    }

    private func preferenceDidChange(_ change: PreferenceChange) {
        guard PanelAppearance.isAppearancePreference(change.id) else { return }
        floatingPanels.appearanceDidChange()
        toolPalette.showsTooltips = preferences[PreferenceCatalog.Panels.showTooltips]
    }

    /// *Help for <panel>*: the Help panel comes forward showing the panel's page.
    func showHelp(for descriptor: PanelDescriptor) {
        helpModel.show(slug: descriptor.helpSlug ?? "", topic: descriptor.title)
        layout.showPanel("help")
    }

    private func installTools() {
        tools.registerBuiltIn()
        SelectionCommands.install(commands: commands, tools: tools)
        let documents = documents!
        let palette = toolPalette
        let toolCommands = tools.commands(
            activate: { id in palette.pressShortcut(id) },
            activeTool: { documents.activeWindowController?.toolManager.activeToolID }
        )
        for command in toolCommands { commands.replace(command) }
        ToolPanelCommands.install(into: commands, palette: palette) { documents.activeWindowController }
        WindowTabCommands.install(into: commands)
        toolPalette.reload(from: tools)
        toolPalette.select = { id in documents.activeWindowController?.toolManager.select(id) }
        toolPalette.presentOptions = { descriptor in _ = documents.activeWindowController?.presentToolOptions(descriptor) }
        toolPalette.perform = { [weak self] id in _ = self?.menuTarget?.perform(id) }
        let layout = layout
        toolPalette.slotStore = (get: { layout.flyoutSlot($0) }, set: { layout.setFlyoutSlot($0, to: $1) })
    }

    /// A panel was registered: give it a layout slot and a Window menu item.
    func panelsDidChange() {
        layout.addRegisteredPanels()
        PanelCommands.sync(into: commands, panels: panels, layout: layout)
        rebuildMainMenu()
    }

    /// The key window or its tool changed: the Tools panel follows it.
    func documentsDidChange() {
        let window = documents.activeWindowController
        toolPalette.activeToolID = window?.toolManager.activeToolID
        toolPalette.viewMode = window?.viewMode
        toolPalette.snap = window?.snap
        toolPalette.selectionWells = window?.selectionWells
        activeSelection.model = window?.selection.model
        floatingPanels.reattach()
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

    /// menu:File[Open…], menu:Window[Library].
    @discardableResult
    func showLibrary() -> Task<Void, Never> {
        let controller = libraryWindowController ?? LibraryWindowController(model: library)
        libraryWindowController = controller
        return controller.show()
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
