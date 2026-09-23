import AppKit
import WTGeometry
import WTRender

/// What every document window shares: the app's registries, preferences and stores.
@MainActor
struct DocumentEnvironment {
    let commands: CommandRegistry
    let panels: PanelRegistry
    let layout: PanelLayoutController
    let tools: ToolRegistry
    let preferences: PreferenceStore
    /// Where window state persists; nil keeps it in memory (tests).
    let windowStates: WindowStateStore?
    /// The active shortcut set, read when a key reaches the canvas.
    var shortcuts: @MainActor () -> ShortcutSet
    /// Runs a command as the menu would (responder-chain commands included).
    var perform: @MainActor (CommandID) -> Bool
    /// A fresh tile cache per window.
    var makeTileCache: @MainActor () -> TileCache = { TileCache(renderer: CoreGraphicsRenderer()) }
    /// Appended to each canvas's accessibility value (the socket audit's counts).
    var diagnostics: @MainActor () -> String? = { nil }
    /// The presence source per window; the stub (nobody else) until SYNC-009.
    var makePresence: @MainActor (DocumentHandle) -> any PresenceProviding = { _ in StubPresenceModel() }
    /// The sync state per window; always *synced* until SYNC-001.
    var makeSyncStatus: @MainActor (DocumentHandle) -> any SyncStatusProviding = { _ in StubSyncStatus() }
    /// *Help for <panel>* (the Help panel, BASIC-007).
    var showHelp: @MainActor (PanelDescriptor) -> Void = { _ in }

    /// The command bound to `key` in the active set, run through the registry.
    func runShortcut(_ key: KeyEquivalent) -> Bool {
        for id in shortcuts().commandIDs(for: key) where perform(id) { return true }
        return false
    }
}

/// One document window (client.adoc, "The document window"): rulers, canvas and scroll bars,
/// the status bar below them, the panel dock at the right edge.  Owns the canvas's tool
/// manager and the window's view state; zoom commands act on the key window's controller.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// Kept from APP-004 so UI tests find the window: every document window carries it.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("main-window")
    static let tabbingIdentifier = NSWindow.TabbingIdentifier("com.villagecompute.wiretuner.document")
    static let defaultContentSize = NSSize(width: 1200, height: 800)

    let documentHandle: DocumentHandle
    let environment: DocumentEnvironment
    let canvas: CanvasView
    let rulerHost: RulerHostView
    let statusBar = StatusBarView()
    /// The right dock (panel groups).
    let dock: PanelDockController
    /// The left dock (the Tools panel) and the top and bottom strips.
    let leftDock: PanelDockController
    let topDock: PanelDockController
    let bottomDock: PanelDockController
    let leftHandle: DockHandleView
    let rightHandle: DockHandleView
    let panelInteraction: PanelInteraction
    let selection: SelectionController
    let presence: any PresenceProviding
    let syncStatus: any SyncStatusProviding
    private(set) var toolManager: ToolManager!

    private(set) var viewMode: ViewMode = .preview {
        didSet {
            statusBar.show(mode: viewMode)
            onViewStateChange?(self)
        }
    }

    /// The four snap toggles (`ViewState.snap_*`, local only).
    private(set) var snap = SnapSettings() {
        didSet { onViewStateChange?(self) }
    }

    /// Called when the window closes, becomes main, or its tool changes.
    var onClose: (@MainActor (DocumentWindowController) -> Void)?
    var onBecomeMain: (@MainActor (DocumentWindowController) -> Void)?
    var onToolChange: (@MainActor (DocumentWindowController, ToolID) -> Void)?
    /// Called after the selection changes (the app republishes it to the panels).
    var onSelectionChange: (@MainActor (DocumentWindowController) -> Void)?
    /// Called after the drawing mode or a snap toggle changes (the Tools panel follows).
    var onViewStateChange: (@MainActor (DocumentWindowController) -> Void)?

    /// False until the saved state has been applied: window moves during setup (`center()`)
    /// must not overwrite the state about to be restored.
    private(set) var isLoaded = false

    /// Beeps on rejected magnification input; replaceable in tests.
    var beep: @MainActor () -> Void = { NSSound.beep() }

    init(document: DocumentHandle, environment: DocumentEnvironment, initialTool: ToolID = .pointer) {
        self.documentHandle = document
        self.environment = environment
        canvas = CanvasView(document: document, cache: environment.makeTileCache())
        rulerHost = RulerHostView(canvas: canvas)
        let preferences = environment.preferences
        let interaction = PanelInteraction(panels: environment.panels, layout: environment.layout)
        interaction.appearance = { PanelAppearance(preferences: preferences) }
        interaction.onHelp = environment.showHelp
        panelInteraction = interaction
        dock = PanelDockController(panels: environment.panels, layout: environment.layout, edge: .right, interaction: interaction)
        leftDock = PanelDockController(panels: environment.panels, layout: environment.layout, edge: .left, interaction: interaction)
        topDock = PanelDockController(panels: environment.panels, layout: environment.layout, edge: .top, interaction: interaction)
        bottomDock = PanelDockController(panels: environment.panels, layout: environment.layout, edge: .bottom, interaction: interaction)
        leftHandle = DockHandleView(edge: .left, layout: environment.layout)
        rightHandle = DockHandleView(edge: .right, layout: environment.layout)
        selection = SelectionController(
            document: document,
            contactSensitive: { preferences[SelectionToolOptions.contactSensitive] },
            pickDistance: { Double(preferences[PreferenceCatalog.General.pickDistance]) }
        )
        presence = environment.makePresence(document)
        syncStatus = environment.makeSyncStatus(document)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = DocumentTitle.format(name: document.title, state: syncStatus.state)
        window.identifier = Self.windowIdentifier
        window.setAccessibilityIdentifier(Self.windowIdentifier.rawValue)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 320)
        super.init(window: window)
        window.delegate = self

        buildContent(in: window)
        let context = ToolContext(document: document, host: canvas, snapping: SnappingContext(
            snapDistance: { Double(preferences[PreferenceCatalog.General.snapDistance]) },
            pickDistance: { Double(preferences[PreferenceCatalog.General.pickDistance]) },
            smartGuidesEnabled: { preferences[PreferenceCatalog.General.smartGuides] }
        ), selection: selection)
        let manager = ToolManager(registry: environment.tools, context: context, initialTool: initialTool) { [environment] key in
            environment.runShortcut(key)
        }
        manager.onToolChange = { [weak self] id in
            guard let self else { return }
            self.onToolChange?(self, id)
        }
        toolManager = manager
        canvas.toolManager = manager
        canvas.selectionController = selection
        canvas.presence = presence
        canvas.showsRemoteSelections = { preferences[PreferenceCatalog.Sync.showSelections] }
        canvas.diagnostics = environment.diagnostics
        canvas.updateAccessibilityValue()
        selection.model.observe { [weak self] _ in
            guard let self else { return }
            self.canvas.selectionDidChange()
            self.onSelectionChange?(self)
        }
        presence.observe { [weak self] in self?.presenceDidChange() }
        syncStatus.observe { [weak self] in self?.updateTitle() }
        document.observeStructure { [weak self] in self?.structureDidChange() }
        preferences.observe { [weak self] change in
            if PanelAppearance.isAppearancePreference(change.id) { self?.panelAppearanceDidChange() }
        }
        interaction.floatingFrame = { [weak window] in Self.floatingFrame(near: window?.frame) }
        canvas.onViewportChange = { [weak self] viewport in self?.viewportDidChange(viewport) }
        canvas.onStatusMessage = { [weak self] message in self?.statusBar.show(message: message) }
        statusBar.onMagnification = { [weak self] text in self?.enterMagnification(text) }
        statusBar.onViewMode = { [weak self] mode in self?.setViewMode(mode) }
        statusBar.onAddPage = { [weak self] in self?.addPage() }
        statusBar.onPage = { [weak self] index in self?.goToPage(index) }
        statusBar.onPageText = { [weak self] text in self?.enterPage(text) }
        statusBar.onUnits = { [weak self] units in self?.documentHandle.setUnits(units) }
        rulerHost.onHorizontalScroll = { [weak self] value in self?.scrollHorizontally(to: value) }
        rulerHost.onVerticalScroll = { [weak self] value in self?.scrollVertically(to: value) }

        window.center()
        restoreState()
        viewportDidChange(canvas.viewport)
        statusBar.show(mode: viewMode)
        structureDidChange()
        presenceDidChange()
        statusBar.show(sync: syncStatus.state)
        isLoaded = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DocumentWindowController is built in code")
    }

    /// The top strip across the window; the left dock and its handle, the canvas column
    /// (rulers and canvas, the bottom strip, the status bar), the right handle and dock.
    private func buildContent(in window: NSWindow) {
        let content = NSView()
        rulerHost.translatesAutoresizingMaskIntoConstraints = false
        let right = dock.view, left = leftDock.view, top = topDock.view, bottom = bottomDock.view
        for view in [top, left, leftHandle, rulerHost, bottom, statusBar, rightHandle, right] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            left.topAnchor.constraint(equalTo: top.bottomAnchor),
            left.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            leftHandle.topAnchor.constraint(equalTo: top.bottomAnchor),
            leftHandle.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            leftHandle.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            leftHandle.widthAnchor.constraint(equalToConstant: DockHandleView.thickness),
            rulerHost.topAnchor.constraint(equalTo: top.bottomAnchor),
            rulerHost.leadingAnchor.constraint(equalTo: leftHandle.trailingAnchor),
            rulerHost.trailingAnchor.constraint(equalTo: rightHandle.leadingAnchor),
            rulerHost.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            rulerHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            bottom.leadingAnchor.constraint(equalTo: leftHandle.trailingAnchor),
            bottom.trailingAnchor.constraint(equalTo: rightHandle.leadingAnchor),
            bottom.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leftHandle.trailingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: rightHandle.leadingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            rightHandle.topAnchor.constraint(equalTo: top.bottomAnchor),
            rightHandle.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            rightHandle.trailingAnchor.constraint(equalTo: right.leadingAnchor),
            rightHandle.widthAnchor.constraint(equalToConstant: DockHandleView.thickness),
            right.topAnchor.constraint(equalTo: top.bottomAnchor),
            right.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            right.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = content
        content.layoutSubtreeIfNeeded()
    }

    /// Where *Float Group* puts a group: near the top right of the window (`frame`).
    static func floatingFrame(near frame: NSRect?) -> LayoutRect {
        guard let frame else { return LayoutRect(x: 200, y: 200, width: 260, height: 320) }
        return LayoutRect(x: frame.maxX - 300, y: frame.maxY - 420, width: 260, height: 320)
    }

    /// Every dock of the window, right first.
    var docks: [PanelDockController] { [dock, leftDock, topDock, bottomDock] }

    /// *Label panel tabs with* or *Show tooltips* changed: every strip re-renders, no panel
    /// closes.
    func panelAppearanceDidChange() {
        for dock in docks { dock.appearanceDidChange() }
    }

    // MARK: Title, presence, pages, units

    /// "<name>", "<name> — Syncing", ... (BASIC-003).
    func updateTitle() {
        window?.title = DocumentTitle.format(name: documentHandle.title, state: syncStatus.state)
        statusBar.show(sync: syncStatus.state)
    }

    /// The tab's collaborator dots and the status bar's avatars follow presence.
    func presenceDidChange() {
        canvas.selectionDidChange()
        let participants = presence.participants
        statusBar.show(participants: participants)
        window?.tab.accessoryView = participants.isEmpty ? nil : TabPresenceDotsView(participants: participants)
    }

    /// Pages, the current page, units or the title changed (locally or remotely).
    func structureDidChange() {
        let document = documentHandle
        statusBar.show(pages: document.pages.count, current: document.currentPageIndex)
        statusBar.show(units: document.units)
        updateTitle()
    }

    /// btn:[Add Page]: adds a page after the current one and scrolls to it.
    func addPage() {
        documentHandle.addPage()
        showCurrentPage()
    }

    /// The page arrows and pop-up.
    func goToPage(_ index: Int) {
        documentHandle.selectPage(index)
        showCurrentPage()
    }

    /// A typed page number or name; anything else beeps and shows the current page again.
    func enterPage(_ text: String) {
        if let index = PageSelection.parse(text, pageCount: documentHandle.pages.count) {
            goToPage(index)
        } else {
            beep()
        }
        statusBar.pageField.abortEditing()
        structureDidChange()
    }

    /// Scrolls the current page to the centre at the current zoom.
    func showCurrentPage() {
        guard let page = documentHandle.currentPage else { return }
        setViewport(navigation.clamped(navigation.centring(viewport, on: page.center)))
    }

    /// The colours of the first selected object, for the Tools panel's wells; nil with
    /// nothing selected.
    var selectionWells: WellColors? {
        selection.model.ids.lazy.compactMap { self.documentHandle.item(for: $0) }.first.flatMap(WellColors.of)
    }

    // MARK: Snap and tool options

    func toggleSnap(_ kind: SnapSettings.Kind) {
        snap[kind].toggle()
    }

    /// A tool's options sheet on this window (double-click in the Tools panel).
    @discardableResult
    func presentToolOptions(_ descriptor: ToolDescriptor) -> NSWindow? {
        guard let options = descriptor.options, let window else { return nil }
        let sheet = NSWindow(contentViewController: options())
        sheet.identifier = NSUserInterfaceItemIdentifier("tool-options.\(descriptor.id.rawValue)")
        window.beginSheet(sheet)
        return sheet
    }

    // MARK: View state

    var viewport: Viewport { canvas.viewport }

    private func viewportDidChange(_ viewport: Viewport) {
        let scroller = canvas.navigation.scroller
        rulerHost.update(horizontal: scroller.horizontal(viewport), vertical: scroller.vertical(viewport), viewport: viewport)
        statusBar.show(zoom: viewport.zoom)
    }

    func setViewport(_ viewport: Viewport) {
        canvas.setViewport(viewport)
    }

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
    }

    func toggleKeyline() { viewMode = viewMode.togglingKeyline }
    func toggleFastMode() { viewMode = viewMode.togglingFast }

    // MARK: Zoom commands

    private var navigation: CanvasNavigation { canvas.navigation }

    func zoomIn() { setViewport(navigation.zoomIn(viewport)) }
    func zoomOut() { setViewport(navigation.zoomOut(viewport)) }
    func zoom(toPercent percent: Double) { setViewport(navigation.zoom(viewport, to: percent / 100)) }

    func fitPage() {
        guard let page = documentHandle.currentPage else { return }
        setViewport(navigation.fit(viewport, rect: page))
    }

    func fitAll() {
        guard let pages = documentHandle.allPagesBounds else { return }
        setViewport(navigation.fit(viewport, rect: pages))
    }

    /// Fit Selection: zooms to `selection`.
    func fit(selection: Rect?) {
        guard let selection else { return }
        setViewport(navigation.fit(viewport, rect: selection))
    }

    /// menu:View[Fit Selection]: zooms to the selection's bounds; beeps with nothing selected.
    func fitSelection() {
        guard let bounds = selection.selectedBounds else {
            beep()
            return
        }
        fit(selection: bounds)
    }

    // MARK: Select commands (responder chain; `SelectionCommands`)

    override func selectAll(_ sender: Any?) { selection.selectAll() }
    @objc func selectNone(_ sender: Any?) { selection.selectNone() }
    @objc func invertSelection(_ sender: Any?) { selection.invert() }

    /// Whether a text field has key focus in this window (its field editor is first
    /// responder); kbd:[Tab] must then reach the field, not deselect.
    var isEditingText: Bool { window?.firstResponder is NSText }

    /// Validation of the select commands.  Select All reaches this controller only when no
    /// text view took it first.
    func validate(selector: Selector) -> Bool {
        switch selector {
        case #selector(selectAll(_:)), #selector(invertSelection(_:)):
            return selection.canSelectAll
        case #selector(selectNone(_:)):
            return !isEditingText && !selection.model.isEmpty
        default:
            return true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        return validate(selector: action)
    }

    /// The magnification field: a percentage, a multiplier or a Fit entry; invalid or clamped
    /// input beeps and shows the resulting value.
    func enterMagnification(_ text: String) {
        switch text {
        case StatusBarView.fitPageTitle: fitPage()
        case StatusBarView.fitAllTitle: fitAll()
        case StatusBarView.fitSelectionTitle: fitSelection()
        default:
            if let parsed = MagnificationFormat.parse(text) {
                if parsed.wasClamped { beep() }
                setViewport(navigation.zoom(viewport, to: parsed.zoom))
            } else {
                beep()
            }
        }
        statusBar.show(zoom: viewport.zoom)
    }

    func scrollHorizontally(to value: Double) {
        setViewport(navigation.scroller.scrolled(viewport, horizontalValue: value))
    }

    func scrollVertically(to value: Double) {
        setViewport(navigation.scroller.scrolled(viewport, verticalValue: value))
    }

    // MARK: Persistence

    var currentState: DocumentWindowState {
        let frame = window.map { LayoutRect(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height) }
        var state = DocumentWindowState(frame: frame, viewport: viewport, viewMode: viewMode)
        state.snap = snap
        return state
    }

    /// Applies the saved state honouring *Restore view when opening document* and *Remember
    /// window size and location*; without a saved view the page is fitted.
    func restoreState() {
        let preferences = environment.preferences
        let saved = environment.windowStates?.state(for: documentHandle.id)
        if let saved, preferences[PreferenceCatalog.Document.rememberWindow], let frame = saved.frame, let window {
            window.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        if let saved, preferences[PreferenceCatalog.Document.restoreView] {
            viewMode = saved.viewMode
            snap = saved.snap ?? SnapSettings()
            setViewport(saved.viewport(size: canvas.viewport.size))
        } else {
            fitPage()
        }
    }

    /// Writes the window's state for this document.
    func saveState() {
        guard isLoaded else { return }
        try? environment.windowStates?.save(currentState, for: documentHandle.id)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        saveState()
        onClose?(self)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        onBecomeMain?(self)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveState()
    }

    func windowDidMove(_ notification: Notification) {
        saveState()
    }
}
