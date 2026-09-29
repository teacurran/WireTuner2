import AppKit
import WTInterchange
import WTModel
import WTRender
import WTSync

/// The app glue of commit ef89c5d's package halves: the preferences sync and the team floor
/// (BASIC-023), Optimize Image (IMG-020) and Rasterize (IMG-024), publishing to a web link
/// (WEB-013), symbol import, export and paste (LIB-013), the Sync Activity window, the VoiceOver
/// announcement and the library badges (IO-001/IO-002 rest).  The review rows (DOC-013, FONT-007,
/// LIB-023) live in the review sheet, the print progress (PRINT-013) in the print feature, the
/// output colour context (CMS-011) in `ExportSnapshot`, and the thumbnail capture (DOC-032) in
/// the document session.
@MainActor
final class PackageHalvesGlue {
    enum ID {
        static let optimizeImage: CommandID = "modify.optimizeImage"
        static let rasterize: CommandID = "modify.rasterize"
    }

    static let optimizeSheet = "optimize-image-sheet"
    static let rasterizeSheet = "rasterize-sheet"

    let presenter = SheetPresenter()
    let syncActivity: SyncActivityWindow
    private(set) var announcers: [ObjectIdentifier: (announcer: SyncAnnouncer, token: UUID, status: SessionSyncStatus)] = [:]
    var window: @MainActor () -> DocumentWindowController? = { nil }
    /// Stores new blobs for a document (the import controller's placement).
    var storeBlobs: @MainActor ([ImportedBlob], DocumentHandle) async throws -> Void = { _, _ in }
    var blobs = BlobPlacement()
    /// The image store a window draws placed images from (rasterizing reads the same pixels).
    var imageStore: @MainActor (DocumentWindowController) -> ImageStore? = { _ in nil }
    /// *Downsample images larger than*, in pixels (nil: off).
    var downsampleLimit: @MainActor () -> Int? = { nil }

    init(sessions: DocumentSessions) {
        syncActivity = SyncActivityWindow(sessions: sessions)
    }

    // MARK: Commands

    func commands() -> [Command] {
        let modify = ContextMenuCatalog.Menu.modify
        return [
            Command(id: ID.optimizeImage, title: "Optimize Image…", menu: MenuPath(modify, section: 4), contexts: ContextMenuCatalog.objectContexts,
                    keywords: ["image", "compress", "resample", "grayscale", "format"],
                    validation: { [weak self] in
                        guard let window = self?.window() else { return .disabled("Open a document") }
                        let state = window.documentHandle.state
                        return window.selection.model.ids.contains { state.nodeKind($0.opID) == .image } ? .enabled : .disabled("Select an image")
                    },
                    action: .perform { [weak self] in self?.presentOptimize() }),
            Command(id: ID.rasterize, title: "Rasterize…", menu: MenuPath(modify, section: 4), contexts: ContextMenuCatalog.objectContexts,
                    keywords: ["bitmap", "pixels", "flatten"],
                    validation: { [weak self] in
                        guard let window = self?.window() else { return .disabled("Open a document") }
                        return window.objectEditing.hasSelection ? .enabled : .disabled("Select objects to rasterize")
                    },
                    action: .perform { [weak self] in self?.presentRasterize() }),
            syncActivity.command,
        ]
    }

    @discardableResult
    func presentOptimize() -> OptimizeImageModel? {
        guard let window = window() else { return nil }
        let items = OptimizeImageModel.items(in: window, blobs: blobs)
        guard !items.isEmpty else { return nil }
        let document = window.documentHandle
        let model = OptimizeImageModel(items: items, perform: { [weak window] command in
            window?.objectEditing.perform(command) ?? Task { nil }
        }, storeBlobs: { [weak self] blobs in try await self?.storeBlobs(blobs, document) })
        model.onClose = { [weak self] in self?.presenter.dismiss(Self.optimizeSheet) }
        presenter.present(OptimizeImageSheet(model: model), title: "Optimize Image", identifier: Self.optimizeSheet)
        model.optionsChanged()
        return model
    }

    @discardableResult
    func presentRasterize() -> RasterizeModel? {
        guard let window = window() else { return nil }
        let (nodes, list) = RasterizeModel.selection(in: window)
        guard !nodes.isEmpty else { return nil }
        let document = window.documentHandle
        var base = CoreGraphicsRenderer()
        base.imageStore = imageStore(window)
        let model = RasterizeModel(nodes: nodes, selection: list, downsampleLimit: downsampleLimit(), output: ExportSnapshot.outputContext(document.state),
                                   base: base, perform: { [weak window] command in window?.objectEditing.perform(command) ?? Task { nil } },
                                   storeBlob: { [weak self] blob in try await self?.storeBlobs([blob], document) })
        model.onClose = { [weak self] in self?.presenter.dismiss(Self.rasterizeSheet) }
        presenter.present(RasterizeSheet(model: model), title: "Rasterize", identifier: Self.rasterizeSheet)
        return model
    }

    // MARK: Windows

    /// VoiceOver hears `window`'s sync state when it changes.
    func attach(_ window: DocumentWindowController, status: SessionSyncStatus) {
        let key = ObjectIdentifier(window)
        guard announcers[key] == nil else { return }
        let announcer = SyncAnnouncer(element: window.window)
        announcer.update(status.state)
        let token = status.observe { [weak announcer, weak status] in
            if let status { announcer?.update(status.state) }
        }
        announcers[key] = (announcer, token, status)
        let previous = window.onClose
        window.onClose = { [weak self] closed in
            previous?(closed)
            self?.detach(closed)
        }
    }

    func detach(_ window: DocumentWindowController) {
        guard let entry = announcers.removeValue(forKey: ObjectIdentifier(window)) else { return }
        entry.status.stopObserving(entry.token)
    }

    func announcer(for window: DocumentWindowController) -> SyncAnnouncer? { announcers[ObjectIdentifier(window)]?.announcer }
}

extension AppDelegate {
    /// The one glue object of this app.
    var packageGlue: PackageHalvesGlue {
        if let existing = Self.packageGlues[ObjectIdentifier(self)] { return existing }
        let made = PackageHalvesGlue(sessions: sessions)
        Self.packageGlues[ObjectIdentifier(self)] = made
        return made
    }

    private static var packageGlues: [ObjectIdentifier: PackageHalvesGlue] = [:]

    func installPackageGlue() {
        let documents = documents!
        let glue = packageGlue
        let imports = imports
        let preferences = preferences
        glue.window = { documents.activeWindowController }
        glue.blobs = imports.blobs
        glue.imageStore = { [images] window in images.attach(window).store }
        glue.storeBlobs = { blobs, document in try await imports.blobs.store(blobs, for: document) }
        glue.downsampleLimit = {
            let megapixels = preferences[PreferenceCatalog.Import.downsampleMegapixels]
            return megapixels > 0 ? megapixels * 1_000_000 : nil
        }
        for command in glue.commands() { commands.replace(command) }

        // BASIC-023: synced preferences follow the account; the team floor shows in the window.
        ReviewFloors.shared.activeDocument = { documents.activeWindowController?.documentHandle.id }
        attachPreferenceSync(launchEnvironment.makePreferenceSync(account: account, infoDictionary: Bundle.main.infoDictionary,
                                                                  defaults: preferences.defaults, enabled: preferences.syncEnabled))

        // WEB-013.
        let localMode = localMode
        WebLinks.services = launchEnvironment.makeWebLinkServices(sessions: sessions, account: account, library: library,
                                                                  infoDictionary: Bundle.main.infoDictionary, defaults: preferences.defaults,
                                                                  isLocal: { localMode.isActive })

        // LIB-013.
        let transfer = SymbolTransferFeatures()
        let library = library
        let sessions = sessions
        let auth = account.auth
        transfer.window = { documents.activeWindowController }
        transfer.openDocuments = { documents.documents }
        transfer.libraryDocuments = {
            library.cache.documents.values.filter { !$0.isTrashed }.sorted { $0.name < $1.name }.map { (id: $0.id, name: $0.name) }
        }
        transfer.cloudState = { id in
            guard let transport = sessions.sessions.values.lazy.compactMap({ $0.connection?.transport }).first else { return nil }
            return try await SymbolSources.cloudState(documentID: id, transport: transport, token: try await auth.validAccessToken())
        }
        transfer.storeBlobs = { blobs, document in try await imports.blobs.store(blobs, for: document) }
        SymbolTransferFeatures.shared = transfer

        // IO-002: library badges.
        library.syncState = { id in (sessions.sessions[id] ?? sessions.background[id])?.status.state }
    }

    /// The preferences backend follows `sync` (none in test launches): refreshed on each sign-in,
    /// turned on and off with *Sync preferences with my account*.
    @discardableResult
    func attachPreferenceSync(_ sync: PreferenceSync?) -> Task<Void, Never>? {
        guard let backend = preferences.backend as? AccountPreferenceBackend else { return nil }
        backend.connect(shortcutSets)
        guard let sync else { return nil }
        let preferences = preferences
        let shortcutSets = shortcutSets
        account.signedInHandlers.append { Task { await backend.refresh() } }
        preferences.observe { change in
            guard change.id == PreferenceCatalog.Sync.enabled.id else { return }
            Task { await backend.setEnabled(preferences.syncEnabled) }
            // Turning sync on sends every set of this Mac (merged per set on the server).
            if preferences.syncEnabled { backend.enqueueWire([ShortcutSetSync.key: shortcutSets.syncValue]) }
        }
        if preferences.syncEnabled { backend.enqueueWire([ShortcutSetSync.key: shortcutSets.syncValue]) }
        return backend.attach(sync, enabled: preferences.syncEnabled)
    }

    func attachPackageGlue(_ window: DocumentWindowController) {
        packageGlue.attach(window, status: sessions.session(for: window.documentHandle).status)
    }
}
