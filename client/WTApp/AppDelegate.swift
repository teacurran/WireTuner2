import AppKit
import Sparkle

/// The application delegate.  There is no main nib or storyboard, so `NSApplicationMain` would
/// never instantiate a delegate: `main()` creates one, holds it (`NSApplication.delegate` is
/// weak) and runs the app.  The menu bar and the windows are built in code from the command,
/// panel and tool registries.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The running app's delegate, kept alive for the life of the process.
    private static var running: AppDelegate?

    /// Unit tests host inside the app and build their own delegates, so a unit-test launch runs
    /// without one (it would otherwise open a window of its own); UI tests get the real launch.
    static func main() {
        let app = NSApplication.shared
        if !LaunchEnvironment().isUnitTesting {
            let delegate = AppDelegate()
            running = delegate
            app.delegate = delegate
        }
        app.run()
    }

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
    /// The Layers panel's selection and editing state (LIB-004).
    let layersPanel = LayersPanelState()
    private(set) var documents: DocumentController!
    private(set) var preferencesWindowController: PreferencesWindowController?
    let launchEnvironment: LaunchEnvironment
    /// The signed-in account (APP-008).
    let account: AccountModel
    private(set) var accountWindowController: AccountWindowController?
    /// The document library (APP-009).
    let library: LibraryModel
    private(set) var libraryWindowController: LibraryWindowController?
    /// Teams and sharing (SEC-003, COLLAB-013).
    let collaboration: CollaborationServices
    /// The Share sheet (menu:File[Share…], the toolbar's Share).
    let sharePresenter: SharePresenter
    /// The UI tests' socket audit, running only when the launch asked for it (DEBUG builds).
    let socketMonitor: SocketMonitor?
    /// menu:View[Preview in Browser]'s exports (BASIC-017); the exporter arrives with WEB-029.
    let browserPreview = BrowserPreview()
    /// The Sounds preferences' playback (BASIC-025).
    let snapSounds: SnapSoundPlayer
    /// The dockable toolbars and the extensions (BASIC-011, 029, 031, 032).
    let toolbars: ToolbarFeatures
    /// menu:Window[Panel Layout]'s saved layouts (BASIC-030).
    let namedLayouts: NamedLayoutController

    /// The active shortcut set, resolved against the registry (BASIC-026).
    private(set) var shortcuts: ShortcutSet
    /// The shortcut sets and which is active (BASIC-026).
    let shortcutSets: ShortcutSetStore
    /// menu:Edit[Keyboard Shortcuts…] (BASIC-027).
    var keyboardShortcutsWindowController: KeyboardShortcutsWindowController?
    /// The command palette (BASIC-033).
    let palette: CommandPaletteController
    /// Every open document's sync session, closed windows still uploading and the launch's
    /// headless uploads (IO-001, IO-007).
    let sessions: DocumentSessions
    /// The quit sheet (IO-007).
    let quit: QuitCoordinator
    /// Where the launch looks for stores to upload headlessly (the documents folder in the app).
    let storesDirectory: @Sendable () throws -> URL
    private(set) var menuTarget: CommandMenuTarget?
    /// The effects, brush and colour-adjustment UI (FX-003 ... COLOR-017).
    private(set) var effects: EffectFeatures?
    /// The colour panels, sheets and commands (COLOR, CMS epics).
    private(set) lazy var colors = ColorFeatures(
        selection: activeSelection, preferences: preferences, defaults: preferences.defaults,
        libraryClient: launchEnvironment.makeColorLibraryClient(account: account, infoDictionary: Bundle.main.infoDictionary, defaults: preferences.defaults),
        teams: { [weak self] in self?.library.cache.teams.map { TeamLibrariesModel.Team(id: $0.id, name: $0.name) } ?? [] }
    )
    /// menu:File[Import…] and files dropped on a canvas (IMG-005, IMG-008, WEB-025).
    private(set) lazy var imports = ImportController(preferences: preferences)
    /// menu:File[Export a Package…], menu:File[Open Package…] and packages opened from the Finder
    /// (IO-005, IO-006).
    private(set) lazy var packages = PackageController()
    /// menu:File[Export…] and menu:File[Export Again] (IO-014).
    private(set) lazy var exports = ExportController(defaults: preferences.defaults)
    /// The Missing Fonts sheet, the substitutions and each document's embedded fonts (DOC-024).
    private(set) lazy var fonts = DocumentFonts(preferences: preferences)

    /// - Parameters:
    ///   - layoutStore: where the panel layout persists; `nil` keeps it in memory (tests).
    ///   - defaults: the preferences' `UserDefaults`.
    ///   - windowStates: where document window state persists; `nil` keeps none (tests).
    ///   - syncConnector: the documents' sync connector; `nil` makes the app's (none in test launches).
    ///   - storesDirectory: where the launch's headless uploads look for stores.
    init(
        layoutStore: PanelLayoutStore?, defaults: UserDefaults = PreferenceStore.makeDefaults(), windowStates: WindowStateStore? = nil,
        launchEnvironment: LaunchEnvironment = LaunchEnvironment(), account: AccountModel? = nil,
        libraryStore: LibraryCacheStore? = nil, thumbnailDirectory: URL? = nil, library: LibraryModel? = nil,
        sessionStore: SessionStore? = nil, toolbarStore: ToolbarStore? = nil, layoutsDirectory: URL? = nil,
        shortcutSetsURL: URL? = nil, paletteHistoryURL: URL? = nil, collaboration: CollaborationServices? = nil,
        syncConnector: (any SyncConnecting)? = nil, storesDirectory: @escaping @Sendable () throws -> URL = { try HeadlessUploads.defaultDirectory() }
    ) {
        self.storesDirectory = storesDirectory
        layout = PanelLayoutController(registry: panels, store: layoutStore)
        preferences = PreferenceStore(defaults: defaults)
        snapSounds = SnapSoundPlayer(preferences: preferences)
        floatingPanels = FloatingPanelsController(panels: panels, layout: layout)
        self.sessionStore = sessionStore
        self.launchEnvironment = launchEnvironment
        self.account = account ?? launchEnvironment.makeAccountModel(infoDictionary: Bundle.main.infoDictionary, defaults: defaults)
        let account = self.account
        self.library = library ?? launchEnvironment.makeLibraryModel(
            account: account, infoDictionary: Bundle.main.infoDictionary, defaults: defaults, store: libraryStore,
            thumbnails: ThumbnailCache(directory: thumbnailDirectory)
        )
        let collaboration = collaboration ?? launchEnvironment.makeCollaborationServices(
            account: account, infoDictionary: Bundle.main.infoDictionary, defaults: defaults
        )
        self.collaboration = collaboration
        let libraryModel = self.library
        libraryModel.collaboration = collaboration
        sharePresenter = SharePresenter(
            services: collaboration,
            accountID: { libraryModel.cache.personalSpaceID ?? account.profile?.accountID },
            isOnline: { libraryModel.isOnline && account.isSignedIn }
        )
        socketMonitor = launchEnvironment.auditsSockets ? SocketMonitor() : nil
        shortcuts = ShortcutSet.builtInDefault(commands: [])
        toolbars = ToolbarFeatures(commands: commands, layout: layout, tools: tools, defaults: defaults, store: toolbarStore)
        namedLayouts = NamedLayoutController(
            layout: layout, store: NamedLayoutStore(directory: layoutsDirectory ?? FileManager.default.temporaryDirectory.appending(path: "WireTunerLayouts-\(UUID().uuidString)")),
            commands: commands
        )
        shortcutSets = ShortcutSetStore(url: shortcutSetsURL)
        palette = CommandPaletteController(model: CommandPaletteModel(history: PaletteHistory(url: paletteHistoryURL)))
        let accountModel = self.account
        let sessions = DocumentSessions(
            connector: syncConnector ?? launchEnvironment.makeSyncConnector(account: accountModel, infoDictionary: Bundle.main.infoDictionary, defaults: defaults, preferences: preferences),
            localUserID: { accountModel.profile?.accountID ?? "" }
        )
        self.sessions = sessions
        let preferenceStore = preferences
        quit = QuitCoordinator(sessions: sessions, warns: { preferenceStore[PreferenceCatalog.Document.warnUnsyncedQuit] })
        super.init()
        var environment = DocumentEnvironment(
            commands: commands, panels: panels, layout: layout, tools: tools, preferences: preferences,
            windowStates: windowStates,
            shortcuts: { [weak self] in self?.shortcuts ?? ShortcutSet.builtInDefault(commands: []) },
            perform: { [weak self] id in self?.menuTarget?.perform(id) ?? false }
        )
        environment.showHelp = { [weak self] descriptor in self?.showHelp(for: descriptor) }
        environment.snapSounds = snapSounds
        let opener = DocumentOpener.opener(for: launchEnvironment, preferences: preferences)
        environment.openModel = { id in
            // A closed window's upload or a headless one still holding the store gives it up first.
            await sessions.release(id)
            return try await opener(id)
        }
        environment.makePasteboard = { SystemObjectPasteboard() }
        environment.importFiles = { [weak self] window, urls, point in self?.imports.drop(urls, on: window, at: point) ?? false }
        environment.pasteImport = PasteImport(
            canPaste: { [weak self] in self?.imports.canPaste(from: .general) ?? false },
            paste: { [weak self] window in Task { await self?.imports.paste(from: .general, on: window) } }
        )
        environment.session = { sessions.session(for: $0) }
        environment.documentDidClose = { [weak self] document in
            sessions.documentDidClose(document)
            self?.fonts.documentDidClose(document)
        }
        environment.documentDidOpen = { [weak self] window in Task { await self?.fonts.documentDidOpen(window) } }
        environment.userName = { accountModel.profile?.displayName ?? "" }
        let reviewWork = launchEnvironment.makeReviewWork(account: accountModel, infoDictionary: Bundle.main.infoDictionary, defaults: defaults)
        environment.reviewWork = { accountModel.isSignedIn ? reviewWork : nil }
        environment.openDocument = { [weak self] id, name in
            guard let documents = self?.documents else { return }
            documents.open(documents.environment.makeDocument(id: id, title: name))
        }
        sessions.onSignIn = { [weak self] in self?.showAccount() }
        sessions.onExportPackage = { [weak self] in _ = self?.menuTarget?.perform(CommandID("file.exportPackage")) }
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
            sessionStore: SessionStore(url: SessionStore.defaultURL), toolbarStore: ToolbarStore(url: ToolbarStore.defaultURL),
            layoutsDirectory: NamedLayoutStore.defaultDirectory, shortcutSetsURL: ShortcutSetStore.defaultURL,
            paletteHistoryURL: PaletteHistory.defaultURL
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
            for document in opened {
                documents.open(documents.environment.makeDocument(id: document.id, title: document.name, isNew: document.isPendingUpload))
            }
        }
        let preferences = preferences
        ViewCommands.install(
            into: commands,
            target: { documents.activeWindowController },
            hooks: ViewCommands.Hooks(
                newDocument: { library.createDocument() }, documents: documents, browserPreview: browserPreview,
                previewBrowser: { PreferenceBookmarks(store: preferences).url(for: PreferenceCatalog.Export.previewBrowser.erased) }
            )
        )
        LibraryCommands.install(into: commands) { [weak self] in self?.showLibrary() }
        ShareCommands.install(into: commands, canShare: { documents.activeWindowController != nil }) { [weak self] in self?.showShare() }
        installImports()
        CollaborationCommands.install(into: commands, window: { documents.activeWindowController }, preferences: preferences)
        PreferenceCommands.install(into: commands, store: preferences) { [weak self] in self?.showPreferences() }
        installTools()
        installShortcutsAndPalette()
        AccountCommands.install(into: commands, model: account) { [weak self] in self?.showAccount() }
        let account = account
        Task { await account.start() }

        installContextMenus()
        layersPanel.clickMoves = { preferences[PreferenceCatalog.Panels.layerClickMoves] }
        colors.install(commands: commands, panels: panels, extensions: toolbars.extensions) { documents.documents }
        PanelCatalog.register(into: panels, selection: activeSelection, help: helpModel, layers: layersPanel)
        panels.registerIfAbsent(ToolsPanel.descriptor(model: toolPalette))
        installToolbars()
        layout.load()
        panels.onChange = { [weak self] in self?.panelsDidChange() }
        panelsDidChange()
        connectFloatingPanels()

        documents.onChange = { [weak self] in self?.documentsDidChange() }
        let sessions = sessions
        if let connector = sessions.connector, let directory = try? storesDirectory() {
            // Stores with changes still waiting upload in the background before any window opens.
            Task { [weak self] in
                await HeadlessUploads.begin(in: directory, connector: connector, sessions: sessions) { id in
                    library.cache.documents[id]?.name ?? "Untitled"
                }
                self?.openWindowsAtLaunch()
            }
        } else {
            openWindowsAtLaunch()
        }
        NSApp.activate()
    }

    /// The last session's windows, or a new document.
    func openWindowsAtLaunch() {
        if restoreSession().isEmpty { documents.newDocument() }
    }

    /// Quitting with changes waiting shows the quit sheet (IO-007).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quit.shouldTerminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        browserPreview.cleanUp()
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
        DrawingTools.install(into: tools)
        ToolOptionSheets.install(into: tools, store: preferences)
        let documents = documents!
        ObjectMenuCommands.install(into: commands) { documents.activeWindowController?.objectEditing }
        ConnectorCommands.install(commands: commands, tools: tools) { documents.activeWindowController?.objectEditing }
        tools.replace(TextTool.descriptor)
        let effects = EffectFeatures(target: { documents.activeWindowController?.objectEditing }, tools: { documents.activeWindowController?.toolManager })
        effects.install(commands: commands, tools: tools, extensions: toolbars.extensions)
        colors.colorControl = { effects.colorControlMenuItem() }
        self.effects = effects
        let palette = toolPalette
        let toolCommands = tools.commands(
            activate: { id in palette.pressShortcut(id) },
            activeTool: { documents.activeWindowController?.toolManager.activeToolID }
        )
        for command in toolCommands { commands.replace(command) }
        ToolPanelCommands.install(into: commands, palette: palette) { documents.activeWindowController }
        UndoCommands.install(into: commands) { documents.activeWindowController }
        WindowTabCommands.install(into: commands)
        toolPalette.reload(from: tools)
        toolPalette.select = { id in documents.activeWindowController?.toolManager.select(id) }
        toolPalette.presentOptions = { descriptor in _ = documents.activeWindowController?.presentToolOptions(descriptor) }
        toolPalette.perform = { [weak self] id in _ = self?.menuTarget?.perform(id) }
        let layout = layout
        toolPalette.slotStore = (get: { layout.flyoutSlot($0) }, set: { layout.setFlyoutSlot($0, to: $1) })
        toolPalette.coloring = ToolWellColoring(swatches: colors.swatchesPanel)
    }

    /// Panel menus (BASIC-019) come from the registry with the active shortcut set.
    private func installContextMenus() {
        let commands = commands
        PanelContextMenus.nodes = { [weak self] context in
            ContextMenuBuilder.nodes(for: .panel(context), registry: commands, shortcuts: self?.shortcuts ?? ShortcutSet.builtInDefault(commands: []))
        }
        PanelContextMenus.perform = { [weak self] id in _ = self?.menuTarget?.perform(id) }
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
        activeSelection.document = window?.documentHandle
        activeSelection.editing = window?.objectEditing
        activeSelection.presence = window?.presence
        activeSelection.preferences = preferences
        floatingPanels.reattach()
        toolbarsDocumentsDidChange()
    }

    func rebuildMainMenu() {
        shortcuts = shortcutSets.activeSet
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
        for controller in documents.allWindowControllers { controller.canvas.updateAccessibilityValue() }
    }

    /// menu:File[Open…], menu:Window[Library].
    @discardableResult
    func showLibrary() -> Task<Void, Never> {
        let controller = libraryWindowController ?? LibraryWindowController(model: library)
        libraryWindowController = controller
        return controller.show()
    }

    /// menu:File[Share…] and the toolbar's Share: the sheet for the front document.
    @discardableResult
    func showShare() -> ShareSheetModel? {
        guard let controller = activeDocumentWindow, let window = controller.window else { return nil }
        let handle = controller.documentHandle
        let entry = library.cache.documents[handle.id]
        let document = ShareDocument(
            id: handle.id, name: entry?.name ?? handle.title, isUploaded: entry.map { !$0.isPendingUpload } ?? false, libraryRole: entry?.role
        )
        return sharePresenter.present(document, on: window)
    }

    /// `wiretuner://invite/<token>` (and an invitation's web link handed to the app): the
    /// library comes forward with the Join Team sheet.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url) }
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        if PackageController.opens(url) {
            Task { await packages.openFile(url) }
            return true
        }
        guard InviteLink.token(in: url) != nil else { return false }
        showLibrary()
        library.showJoinTeam(link: url.absoluteString)
        return true
    }

    /// The import and package commands over the open windows' blob queues and the library.
    func installImports() {
        let documents = documents!
        let library = library
        let account = account
        imports.blobs.queue = { documents.windowControllers[$0.id]?.session?.client?.blobs }
        packages.blobs.queue = imports.blobs.queue
        packages.account = { (account.profile?.accountID ?? "", account.profile?.displayName ?? "") }
        packages.createDocument = { title in documents.document(id: library.createDocument(name: title).id) }
        fonts.closeDocument = { documents.close($0.documentHandle.id) }
        if let client = launchEnvironment.makeFontLibraryClient(account: account, infoDictionary: Bundle.main.infoDictionary, defaults: preferences.defaults) {
            fonts.team = TeamFontLibraryConnection(client: client, library: library, account: account)
        }
        ImportCommands.install(into: commands, hooks: ImportCommands.hooks(imports: imports, packages: packages) { documents.activeWindowController })
        installExports()
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
