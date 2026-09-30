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
        let environment = LaunchEnvironment()
        environment.applyProcessDefaults()
        let app = NSApplication.shared
        if !environment.isUnitTesting {
            let delegate = AppDelegate()
            running = delegate
            app.delegate = delegate
        }
        app.run()
    }

    /// Sparkle.  Started in `applicationDidFinishLaunching` only when the build carries an
    /// `SUPublicEDKey` and an https `SUFeedURL` (`make release` builds; releasing.adoc): starting
    /// the updater without a key is a fatal Sparkle error.  Otherwise the menu item stays disabled
    /// because its command validates against `canCheckForUpdates`.
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
    /// Local mode: the app without a server or without an account (D-079).
    let localMode: LocalMode
    /// The work the last change of Local mode started (`localModeDidChange`).
    var localModeChange: Task<Void, Never>?
    private(set) var accountWindowController: AccountWindowController?
    /// The document library (APP-009).
    let library: LibraryModel
    private(set) var libraryWindowController: LibraryWindowController?
    /// Teams and sharing (SEC-003, COLLAB-013).
    let collaboration: CollaborationServices
    /// The Share sheet (menu:File[Share…], the toolbar's Share).
    let sharePresenter: SharePresenter
    /// btn:[Share]'s badge: pending access requests (COLLAB-013).
    let shareRequests: ShareRequestBadges
    /// Share links handed to the app (`OpenLink`, the password and request pages; COLLAB-013).
    let shareLinks: ShareLinkOpener
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
    /// Team libraries and style import/export (LIB-016, LIB-022).
    var libraryTransfer: (teams: TeamLibraryFeatures, styles: StyleTransferModel)?
    /// The colour panels, sheets and commands (COLOR, CMS epics).
    private(set) lazy var colors = ColorFeatures(
        selection: activeSelection, preferences: preferences, defaults: preferences.defaults,
        libraryClient: launchEnvironment.makeColorLibraryClient(account: account, infoDictionary: Bundle.main.infoDictionary, defaults: preferences.defaults),
        teams: { [weak self] in self?.library.cache.teams.map { TeamLibrariesModel.Team(id: $0.id, name: $0.name) } ?? [] }
    )
    /// menu:File[Import…] and files dropped on a canvas (IMG-005, IMG-008, WEB-025).
    private(set) lazy var imports = ImportController(preferences: preferences)
    /// The document setup features: Page tool, Document panel, grid, guides, units, links (DOC).
    private(set) lazy var documentSetup = DocumentSetupFeatures(preferences: preferences, device: DeviceIdentity.current(defaults: preferences.defaults))
    /// menu:File[Save a Copy As…], menu:File[Open File…] and packages opened from the Finder
    /// (IO-005, IO-006, D-082).
    private(set) lazy var packages = PackageController()
    /// Foreign files (Illustrator, PDF, SVG, EPS, DXF) opened as new documents (IO-040).
    private(set) lazy var foreignFiles = ForeignFileOpener(imports: imports)
    /// menu:File[Export…] and menu:File[Export Again] (IO-014).
    private(set) lazy var exports = ExportController(defaults: preferences.defaults)
    /// The Missing Fonts sheet, the substitutions and each document's embedded fonts (DOC-024).
    private(set) lazy var fonts = DocumentFonts(preferences: preferences)
    /// The data merge panel, sheets and commands, and the record preview (DATA epic).
    private(set) lazy var dataMerge = DataFeatures(preferences: preferences)
    /// The Scripts menu and the Script Editor (DATA-013, DATA-014).
    let scripts = ScriptFeatures()
    /// Typeface documents: New Typeface, the glyph grid and tabs, Font Info, Metrics, Generate Fonts (FONT).
    private(set) lazy var typeface = TypefaceFeatures(preferences: preferences)
    /// menu:File[Save Version…] and menu:File[Duplicate] (IO-003, IO-004).
    let versions = VersionFeatures()
    /// Comment pins, the Comment tool, the thread popover and the Comments panel (COLLAB-027..029).
    private(set) lazy var comments = CommentsFeatures(preferences: preferences)
    /// Branches, compare mode, Restore Version, Inspect mode and the access bar (COLLAB).
    let collaborationUI = CollaborationFeatures()
    /// The Navigation and Animation panels, Release to Layers, Publish as HTML (WEB).
    private(set) lazy var web = WebFeatures(preferences: preferences)
    /// Image pixels and marks, the Trace tool and the share inbox (IMG).
    private(set) lazy var images = ImageFeatures(preferences: preferences)
    /// Handoff and Spotlight continuations (IO-035, IO-036).
    let continuity = ContinuityOpener()
    /// *Remove Local Copy* (IO-035).
    let localCopyRemoval = LocalCopyRemoval()
    let deepLinks = DeepLinkFeatures()
    /// The Align, Transform and Find & Replace panels and their menu items (OBJ-019, OBJ-033, TYPE-022).
    private(set) lazy var editingPanels = EditingPanels(defaults: preferences.defaults)
    /// The Spotlight items of the documents on this Mac (IO-035).
    let spotlight: SpotlightIndexer
    /// The Output Area tool, Page Setup, Print and the Halftones panel (PRINT-002, PRINT-010, PRINT-011).
    private(set) lazy var printing = PrintFeatures(defaults: preferences.defaults)
    /// The Edit and Modify menus' object commands and the clipboard formats (OBJ-014 ... OBJ-039).
    private(set) lazy var editMenu = EditFeatures(preferences: preferences)
    /// menu:File[Document Info…] (IO-011).
    let documentInfo = DocumentInfoFeatures()
    /// *Storage almost full* and the retry when space frees (IO-009).
    let storage = StorageMonitor()
    /// Envelopes, text on a path, perspective, Show Links, the path clean-ups and the Inspect
    /// panel (FX-039, TYPE-017, FX-043, FX-044, WEB-004, DRAW-030, COLLAB-036).
    private(set) lazy var modelGlue = ModelGlueFeatures(preferences: preferences)
    /// Master page tabs, named views, Select Similar, Combine, the canvas handles, team libraries
    /// and the Profiles sheet (commit cbda22a's app half: DOC-012, BASIC-015, OBJ-042, OBJ-025 ...).
    private(set) lazy var documentGlue = DocumentGlueFeatures(preferences: preferences) { [weak self] in self?.activeDocumentWindow }
    /// The template gallery, New from the default template and Save as Template (DOC-019, 029, 030).
    private(set) lazy var templates = TemplateFeatures(library: library, preferences: preferences)
    /// Open Recent and the Window menu's documents (DOC-020).
    private(set) lazy var documentMenus = DocumentMenuFeatures(library: library, preferences: preferences)

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
        syncConnector: (any SyncConnecting)? = nil, storesDirectory: @escaping @Sendable () throws -> URL = { try HeadlessUploads.defaultDirectory() },
        spotlight: SpotlightIndexer = SpotlightIndexer(index: NoSpotlightIndex()), localMode: LocalMode? = nil
    ) {
        let localMode = localMode ?? LocalMode(infoDictionary: Bundle.main.infoDictionary, defaults: defaults)
        self.localMode = localMode
        self.storesDirectory = storesDirectory
        self.spotlight = spotlight
        layout = PanelLayoutController(registry: panels, store: layoutStore)
        preferences = PreferenceStore(defaults: defaults, backend: AccountPreferenceBackend())
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
        shareRequests = ShareRequestBadges(
            services: collaboration, isOwner: { libraryModel.cache.documents[$0]?.role == .owner },
            isOnline: { !libraryModel.isLocal() && libraryModel.isOnline && account.isSignedIn }
        )
        shareLinks = ShareLinkOpener(services: collaboration)
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
        // A Local mode build has no server to connect to (D-079).
        let connector = syncConnector ?? (localMode.isLocalBuild ? nil : launchEnvironment.makeSyncConnector(
            account: accountModel, infoDictionary: Bundle.main.infoDictionary, defaults: defaults, preferences: preferences
        ))
        let sessions = DocumentSessions(connector: connector, localUserID: { accountModel.profile?.accountID ?? "" }, isLocal: { localMode.isActive })
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
            canPaste: { [weak self] in (self?.imports.canPaste(from: .general) ?? false) || (self?.editMenu.takesPaste(from: .general) ?? false) },
            paste: { [weak self] window in
                Task {
                    // SVG, rich text and plain text are the clipboard reader's; files, PDF and images the importer's.
                    if self?.editMenu.takesPaste(from: EditFeatures.pasteboard(of: window)) == true {
                        await self?.editMenu.pasteRichest(on: window)
                    } else {
                        await self?.imports.paste(from: .general, on: window)
                    }
                }
            }
        )
        environment.session = { sessions.session(for: $0) }
        environment.documentDidClose = { [weak self] document in
            if let spotlight = self?.spotlight { Task { await spotlight.documentDidClose(document) } }
            sessions.documentDidClose(document)
            self?.fonts.documentDidClose(document)
        }
        environment.documentDidOpen = { [weak self] window in
            Task { await self?.fonts.documentDidOpen(window) }
            self?.documentSetup.documentDidOpen(window)
            self?.versions.documentDidOpen(window)
            self?.comments.attach(window)
            self?.shareRequests.attach(window)
            self?.collaborationUI.attach(window)
            self?.web.attach(window)
            self?.images.attach(window)
            ProfileBlobGlue.shared?.watch(window.documentHandle)
            self?.printing.attach(window)
            self?.editMenu.attach(window)
            self?.attachWindowGlue(window)
            self?.attachEditorExtras(window)
            self?.attachModelGlue(window)
            self?.attachDocumentGlue(window)
            self?.attachTypeAndDrawingFeatures(window)
            self?.attachExtras(window)
            self?.attachImageLinkAndAccessibility(window)
            self?.attachPackageGlue(window)
            self?.attachReachability(window)
        }
        environment.userName = { accountModel.profile?.displayName ?? "" }
        let palette = toolPalette
        environment.currentColors = { palette.currentChoices }
        environment.writeSelectionPDF = { [weak self] window, url in await self?.writeSelectionPDF(of: window, to: url) ?? false }
        let reviewWork = launchEnvironment.makeReviewWork(account: accountModel, infoDictionary: Bundle.main.infoDictionary, defaults: defaults)
        environment.reviewWork = { accountModel.isSignedIn ? reviewWork : nil }
        environment.openDocument = { [weak self] id, name in
            guard let documents = self?.documents else { return }
            documents.open(documents.environment.makeDocument(id: id, title: name))
        }
        sessions.onSignIn = { [weak self] in self?.showAccount() }
        sessions.onExportPackage = { [weak self] in _ = self?.menuTarget?.perform(ImportCommands.ID.saveCopy) }
        if let socketMonitor {
            environment.diagnostics = { socketMonitor.counts.accessibilityText }
        }
        documents = DocumentController(environment: environment)
        installLocalMode()
        socketMonitor?.onChange = { [weak self] _ in self?.socketCountsDidChange() }
        socketMonitor?.start()
    }

    override convenience init() {
        self.init(
            layoutStore: PanelLayoutStore(url: PanelLayoutStore.defaultURL), windowStates: WindowStateStore(url: WindowStateStore.defaultURL),
            libraryStore: LibraryCacheStore(url: LibraryCacheStore.defaultURL), thumbnailDirectory: ThumbnailCache.defaultDirectory,
            sessionStore: SessionStore(url: SessionStore.defaultURL), toolbarStore: ToolbarStore(url: ToolbarStore.defaultURL),
            layoutsDirectory: NamedLayoutStore.defaultDirectory, shortcutSetsURL: ShortcutSetStore.defaultURL,
            paletteHistoryURL: PaletteHistory.defaultURL, spotlight: SpotlightIndexer(index: DefaultSpotlightIndex(), url: SpotlightIndexer.defaultURL)
        )
    }

    /// The front document window (the one the View menu acts on).
    var activeDocumentWindow: DocumentWindowController? { documents.activeWindowController }

    /// Whether an Info.plist configures Sparkle: a non-empty `SUPublicEDKey` and an https
    /// `SUFeedURL`.  Debug and test builds carry an empty key (Config/Distribution.xcconfig).
    nonisolated static func updatesConfigured(_ info: [String: Any]?) -> Bool {
        let key = (info?["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let feed = (info?["SUFeedURL"] as? String).flatMap(URL.init(string:))
        return !key.isEmpty && feed?.scheme == "https" && feed?.host != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.updatesConfigured(Bundle.main.infoDictionary) {
            updaterController.startUpdater()
        }
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
                documents.open(documents.environment.makeDocument(
                    id: document.id, title: document.name, isNew: document.isPendingUpload, template: library.takeTemplate(for: document.id)
                ))
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
        installVersions()
        installContinuity()
        installDeepLinks()
        CollaborationCommands.install(into: commands, window: { documents.activeWindowController }, preferences: preferences)
        PreferenceCommands.install(into: commands, store: preferences) { [weak self] in self?.showPreferences() }
        installTools()
        installShortcutsAndPalette()
        // A Local mode build offers no sign-in at all (D-079).
        if localMode.offersSignIn {
            AccountCommands.install(into: commands, model: account) { [weak self] in self?.showAccount() }
            let account = account
            Task { await account.start() }
        }

        installContextMenus()
        layersPanel.clickMoves = { preferences[PreferenceCatalog.Panels.layerClickMoves] }
        installDocumentSetup()
        installDataMerge()
        installTypeface()
        editingPanels.showPanel = { [weak self] in self?.layout.showPanel($0) }
        editingPanels.install(panels: panels, commands: commands, selection: activeSelection) { documents.activeWindowController?.objectEditing }
        TextFeatures.install(into: commands) { documents.activeWindowController }
        installTextStyles()
        installComments()
        installCollaborationUI()
        installLibraryBranches()
        installWeb()
        installImages()
        installPrinting()
        installEditing()
        installWindowGlue()
        installEditorExtras()
        installModelGlue()
        installTypeAndDrawingFeatures()
        colors.install(commands: commands, panels: panels, extensions: toolbars.extensions) { documents.documents }
        installDocumentGlue()
        installDocumentMenus()
        installScripting()
        installLibraryTransfer()
        installSubjectCommands()
        installReachability()
        installPointTypeCommands()
        PanelCatalog.register(into: panels, selection: activeSelection, help: helpModel, layers: layersPanel)
        panels.registerIfAbsent(ToolsPanel.descriptor(model: toolPalette))
        installToolbars()
        installExtras()
        installImageLinkAndAccessibility()
        installPackageGlue()
        installLocalCopyRemoval()
        layout.load()
        panels.onChange = { [weak self] in self?.panelsDidChange() }
        panelsDidChange()
        connectFloatingPanels()

        documents.onChange = { [weak self] in self?.documentsDidChange() }
        let sessions = sessions
        if let connector = sessions.connector, !localMode.isActive, let directory = try? storesDirectory() {
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
        if restoreSession().isEmpty { openUntitledAtLaunch() }
    }

    /// Quitting with changes waiting shows the quit sheet (IO-007).  Local changes not written
    /// yet (D-076: at most 250 ms of them) are written before the app goes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = quit.shouldTerminate()
        guard reply == .terminateNow, let documents, !documents.modelsWithPendingWrites.isEmpty else { return reply }
        Task { @MainActor in
            await documents.flushAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Deactivating writes every document's pending local changes (D-076).
    func applicationDidResignActive(_ notification: Notification) {
        guard let documents else { return }
        Task { @MainActor in await documents.flushAll() }
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
        VisibilityCommands.install(into: commands) { documents.activeWindowController }
        ObjectMenuCommands.install(into: commands) { documents.activeWindowController?.objectEditing }
        ConnectorCommands.install(commands: commands, tools: tools) { documents.activeWindowController?.objectEditing }
        tools.replace(TextTool.descriptor)
        let effects = EffectFeatures(target: { documents.activeWindowController?.objectEditing }, tools: { documents.activeWindowController?.toolManager })
        effects.install(commands: commands, tools: tools, extensions: toolbars.extensions)
        PathEditingFeatures.install(tools: tools, commands: commands, store: preferences) { documents.activeWindowController?.objectEditing }
        installEffectTools()
        installEyedropper()
        installProfileBlobs()
        installSymbolLibrary()
        installStyles()
        installGraphicHose()
        installArrowheadEditor()
        installModelGlueTools()
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
        let localMode = localMode
        toolPalette.select = { id in
            // A tool that needs the server (the Comment tool) says why in Local mode (D-079).
            if let refusal = localMode.gate(ToolRegistry.commandID(for: id)) {
                documents.activeWindowController?.statusBar.show(message: refusal.reason ?? LocalMode.needsAccount)
                return
            }
            documents.activeWindowController?.toolManager.select(id)
        }
        toolPalette.presentOptions = { descriptor in _ = documents.activeWindowController?.presentToolOptions(descriptor) }
        toolPalette.presentOptions = editingPanels.toolOptions(previous: toolPalette.presentOptions)
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
        let defaults = window?.documentWells
        toolPalette.documentWells = defaults?.wells
        toolPalette.documentChoices = defaults?.choices
        activeSelection.model = window?.selection.model
        activeSelection.document = window?.documentHandle
        activeSelection.editing = window?.objectEditing
        activeSelection.presence = window?.presence
        activeSelection.preferences = preferences
        activeSelection.activeToolID = window?.toolManager.activeToolID
        floatingPanels.reattach()
        toolbarsDocumentsDidChange()
        documentMenusDidChange()
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
        library.refreshStorage()
        return controller.show()
    }

    /// menu:File[Share…] and the toolbar's Share: the sheet for the front document.
    @discardableResult
    func showShare() -> ShareSheetModel? {
        guard let controller = activeDocumentWindow, let window = controller.window else { return nil }
        let handle = controller.documentHandle
        let entry = library.cache.documents[handle.id]
        let document = ShareDocument(
            id: handle.id, name: entry?.name ?? handle.title, isUploaded: entry.map { !$0.isPendingUpload } ?? false, libraryRole: entry?.role,
            spaceID: entry?.spaceID
        )
        return sharePresenter.present(document, on: window)
    }

    /// `wiretuner://invite/<token>` (and an invitation's web link handed to the app): the
    /// library comes forward with the Join Team sheet.  A deep link (`wiretuner://doc/…`, COLLAB-038)
    /// opens its document there.  A file double-clicked in the Finder or dropped on the Dock icon
    /// -- a package, or an Illustrator, PDF, SVG, EPS or DXF file (IO-040) -- opens as a new
    /// document (`PackageController.openFile`).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url) }
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        if images.inbox.opens(url) { return true }
        if SymbolTransferFeatures.opens(url) { return true }
        if StyleTransferModel.opens(url) { return true }
        if typeface.opens(url) { return true }
        if shareLinks.opens(url) != nil { return true }
        if deepLinks.opens(url) != nil { return true }
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
        let packages = packages
        let foreignFiles = foreignFiles
        imports.blobs.queue = { documents.windowControllers[$0.id]?.session?.client?.blobs }
        packages.blobs.queue = imports.blobs.queue
        packages.account = { (account.profile?.accountID ?? "", account.profile?.displayName ?? "") }
        packages.createDocument = { title in documents.document(id: library.createDocument(name: title).id) }
        foreignFiles.createDocument = { title, template in documents.document(id: library.createDocument(name: title, template: template).id) }
        foreignFiles.window = { documents.windowControllers[$0.id]?.window }
        packages.importAsDocument = { url in await foreignFiles.open(url) }
        library.openFile = { Task { await packages.openPackage() } }
        library.openFiles = { urls in
            let opening = urls.filter { PackageController.opens($0) }
            for url in opening { Task { await packages.openFile(url) } }
            return !opening.isEmpty
        }
        fonts.closeDocument = { documents.close($0.documentHandle.id) }
        if !localMode.isLocalBuild, let client = launchEnvironment.makeFontLibraryClient(account: account, infoDictionary: Bundle.main.infoDictionary, defaults: preferences.defaults) {
            fonts.team = TeamFontLibraryConnection(client: client, library: library, account: account)
        }
        ImportCommands.install(into: commands, hooks: ImportCommands.hooks(imports: imports, packages: packages) { documents.activeWindowController })
        ConvertToEditableCommand.install(into: commands, imports: imports) { documents.activeWindowController }
        imports.openLibraryFile = { StyleTransferModel.opens($0) || SymbolTransferFeatures.opens($0) }
        installExports()
    }

    /// Save Version and Duplicate over the library's deferred creation (IO-003, IO-004).
    func installVersions() {
        let documents = documents!
        let library = library
        let preferences = preferences
        let configuration = AuthConfiguration(infoDictionary: Bundle.main.infoDictionary)
        versions.client = GRPCVersionClient(api: configuration.api, clientVersion: LaunchEnvironment.clientVersion(Bundle.main.infoDictionary),
                                            deviceID: DeviceIdentity.current(defaults: preferences.defaults))
        versions.accessToken = collaboration.accessToken
        versions.asksForName = { preferences[PreferenceCatalog.Document.askVersionName] }
        versions.recordDocument = { name, source in library.recordDocument(name: name, like: source).id }
        versions.openDocument = { id, name in documents.open(documents.environment.makeDocument(id: id, title: name)).documentHandle }
        versions.install(into: commands) { documents.activeWindowController }
    }

    /// Handoff and Spotlight continuations open documents through the library; Spotlight follows
    /// trashing (IO-035, IO-036).
    func installContinuity() {
        let documents = documents!
        let library = library
        continuity.window = { documents.views(of: $0).first }
        continuity.entry = { await library.document(withID: $0) }
        continuity.isOnline = { library.isOnline }
        continuity.open = { id, name in documents.open(documents.environment.makeDocument(id: id, title: name)) }
        continuity.showLibrary = { [weak self] message in
            self?.showLibrary()
            library.show(message: message)
        }
        spotlight.thumbnail = { id in library.cache.documents[id]?.thumbnail.flatMap(library.thumbnails.data(for:)) }
        let spotlight = spotlight
        library.onTrashed = { id in Task { await spotlight.remove(id) } }
        // The open documents' items follow the stores' snapshots too (IO-035's rest).
        let preferences = preferences
        spotlight.startRefreshing(every: { .seconds(60 * max(preferences[PreferenceCatalog.Sync.snapshotIntervalMinutes], 1)) },
                                  documents: { documents.documents })
    }

    /// A Handoff from another Mac or a Spotlight result (IO-035, IO-036).
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        continuity.continueActivity(userActivity) != nil
    }

    /// A PDF of `window`'s selection at `url` (objects dragged to the Finder, OBJ-013).
    func writeSelectionPDF(of window: DocumentWindowController, to url: URL) async -> Bool {
        var settings = ExportSettings()
        settings.what = .selection
        if case .exported = await exports.perform(settings, to: url, from: window) { return true }
        return false
    }

    /// menu:WireTuner[Account…].
    func showAccount() {
        let controller = accountWindowController ?? AccountWindowController(model: account, localMode: localMode.offersSignIn ? localMode : nil)
        accountWindowController = controller
        controller.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
