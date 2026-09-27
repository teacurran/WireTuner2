import AppKit
import WTInterchange

extension AppDelegate {
    /// The editors and overlays of the client-ui remainders delivered together (PRINT-010,
    /// PRINT-012, DRAW-023, DRAW-025, OBJ-039, FX-047 and the rest): each registers itself here.
    func installEditorExtras() {
        let documents = documents!
        OutputAreaEditor.register(into: InspectorRegistry.standard)
        ImageColorSection.register(into: InspectorRegistry.standard)
        installExternalEditing()
        installHistory()
        commands.replace(PathClosing.command { documents.activeWindowController?.objectEditing })
        let preferences = preferences
        MeasurementLink.shared.enabled = { preferences[PreferenceCatalog.General.optionMeasurements] }
        PointEditing.smoother = { preferences[PreferenceCatalog.General.smootherEditing] }
        let defaults = preferences.defaults
        let web = web
        LayerFrames.playingLayer = { document in web.front.flatMap { $0.window.documentHandle === document ? $0.web.currentLayer : nil } }
        CornerWidgetLayer.isShown = { CornerWidgetCommands.isShown(defaults) }
        CornerWidgetLayer.showPanel = { [weak self] in self?.layout.showPanel("object") }
        EmbossFeatures.install(extensions: toolbars.extensions, store: preferences, target: { documents.activeWindowController?.objectEditing },
                               presenter: SheetPresenter())
        let raster = RasterEffectSettingsFeatures.shared
        raster.window = { documents.activeWindowController }
        commands.replace(raster.command())
        var object = PlaceholderPanels.objectPanel(selection: activeSelection)
        object.optionsMenu = { [raster] in [raster.objectMenuItem()] }
        _ = panels.registerIfAbsent(object)
        commands.replace(CornerWidgetCommands.command(defaults: defaults) {
            for window in documents.allWindowControllers { window.canvas.setNeedsOverlayDisplay() }
        })
    }

    /// A document window opened: its keywords in the library cache, the raster preview, the
    /// History panel's and the Library's change following.
    func attachEditorExtras(_ window: DocumentWindowController) {
        RasterEffectSettingsFeatures.follow(window, preferences: preferences)
        HistoryPanelModel.shared.follow(window)
        SymbolChangeLog.follow(window) { [weak window] replica in window?.session?.author(of: replica)?.name }
        let library = library
        DocumentKeywordIndex.attach(window) { id, keywords in library.recordKeywords(id, keywords) }
    }

    /// Edit With…: the submenu, the Object panel button, the panel, the blob cache; files left by
    /// a session the app did not finish are removed.
    func installExternalEditing() {
        let documents = documents!
        let external = ExternalEditing.shared
        external.window = { documents.activeWindowController }
        external.preferences = preferences
        let blobs = imports.blobs
        external.cached = { blobs.cached($0) }
        external.store = { blob, document in try await blobs.store([blob], for: document) }
        external.showPanel = { window in _ = EditingInPanel.show(for: window, editing: external) }
        try? FileManager.default.removeItem(at: external.directory())
        for command in external.commands() { commands.replace(command) }
        ExternalEditing.register(into: InspectorRegistry.standard)
        let imports = imports
        SvgAnimationFileActions.convert = { url in try await imports.convert(url, context: ImportContext()) }
        SvgAnimationFileActions.storeBlobs = { scene, document in try await imports.storeBlobs(of: scene, for: document) }
    }

    /// The History panel, menu:File[Show History] and menu:File[Name This Version…], and
    /// menu:File[Branch > Merge…].
    func installHistory() {
        let documents = documents!
        let history = HistoryPanelModel.shared
        history.window = { documents.activeWindowController }
        history.features = collaborationUI
        let configuration = AuthConfiguration(infoDictionary: Bundle.main.infoDictionary)
        let caller = GRPCUnaryCaller(api: configuration.api, clientVersion: LaunchEnvironment.clientVersion(Bundle.main.infoDictionary),
                                     deviceID: DeviceIdentity.current(defaults: preferences.defaults))
        let auth = account.auth
        let client = GRPCHistoryClient(caller: caller) { try await auth.validAccessToken() }
        let testing = launchEnvironment.isTesting, account = account, library = library
        history.client = { !testing && account.isSignedIn && library.isOnline ? client : nil }
        let merging = GRPCBranchMerging(caller: caller) { try await auth.validAccessToken() }
        let features = collaborationUI
        commands.replace(BranchMergeCommand.command(features: features, merging: { !testing && account.isSignedIn && library.isOnline ? merging : nil },
                                                    window: { documents.activeWindowController }))
        BranchMergeCommand.parentSeq = { id in
            guard let store = documents.windowControllers[id]?.session?.store else { return 0 }
            return await store.lastServerSeq
        }
        panels.groupDefaults[HistoryPanelModel.group] = panels.groupDefaults[HistoryPanelModel.group] ?? PanelGroupDefaults(position: 13, isOpen: false)
        _ = panels.registerIfAbsent(HistoryPanel.descriptor(model: history))
        let layout = layout, versions = versions
        history.queuedVersions = { window in await versions.saver(for: window.documentHandle).pendingVersions() }
        versions.versionsChanged = { _ in Task { await history.load() } }
        for command in HistoryPanel.commands(show: { layout.showPanel(HistoryPanelModel.panelID) },
                                             nameVersion: { if let window = documents.activeWindowController { _ = versions.saveVersion(from: window) } },
                                             window: { documents.activeWindowController }) {
            commands.replace(command)
        }
    }
}
