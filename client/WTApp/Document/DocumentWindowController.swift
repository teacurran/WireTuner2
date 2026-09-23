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
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    /// Kept from APP-004 so UI tests find the window: every document window carries it.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("main-window")
    static let tabbingIdentifier = NSWindow.TabbingIdentifier("com.villagecompute.wiretuner.document")
    static let defaultContentSize = NSSize(width: 1200, height: 800)

    let documentHandle: DocumentHandle
    let environment: DocumentEnvironment
    let canvas: CanvasView
    let rulerHost: RulerHostView
    let statusBar = StatusBarView()
    let dock: PanelDockController
    private(set) var toolManager: ToolManager!

    private(set) var viewMode: ViewMode = .preview {
        didSet { statusBar.show(mode: viewMode) }
    }

    /// Called when the window closes, becomes main, or its tool changes.
    var onClose: (@MainActor (DocumentWindowController) -> Void)?
    var onBecomeMain: (@MainActor (DocumentWindowController) -> Void)?
    var onToolChange: (@MainActor (DocumentWindowController, ToolID) -> Void)?

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
        dock = PanelDockController(panels: environment.panels, layout: environment.layout)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = document.title
        window.identifier = Self.windowIdentifier
        window.setAccessibilityIdentifier(Self.windowIdentifier.rawValue)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 320)
        super.init(window: window)
        window.delegate = self

        buildContent(in: window)
        let preferences = environment.preferences
        let context = ToolContext(document: document, host: canvas, snapping: SnappingContext(
            snapDistance: { Double(preferences[PreferenceCatalog.General.snapDistance]) },
            pickDistance: { Double(preferences[PreferenceCatalog.General.pickDistance]) },
            smartGuidesEnabled: { preferences[PreferenceCatalog.General.smartGuides] }
        ))
        let manager = ToolManager(registry: environment.tools, context: context, initialTool: initialTool) { [environment] key in
            environment.runShortcut(key)
        }
        manager.onToolChange = { [weak self] id in
            guard let self else { return }
            self.onToolChange?(self, id)
        }
        toolManager = manager
        canvas.toolManager = manager
        canvas.onViewportChange = { [weak self] viewport in self?.viewportDidChange(viewport) }
        canvas.onStatusMessage = { [weak self] message in self?.statusBar.show(message: message) }
        statusBar.onMagnification = { [weak self] text in self?.enterMagnification(text) }
        statusBar.onViewMode = { [weak self] mode in self?.setViewMode(mode) }
        rulerHost.onHorizontalScroll = { [weak self] value in self?.scrollHorizontally(to: value) }
        rulerHost.onVerticalScroll = { [weak self] value in self?.scrollVertically(to: value) }

        window.center()
        restoreState()
        viewportDidChange(canvas.viewport)
        statusBar.show(mode: viewMode)
        isLoaded = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DocumentWindowController is built in code")
    }

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        rulerHost.translatesAutoresizingMaskIntoConstraints = false
        let dockView = dock.view
        for view in [rulerHost, statusBar, dockView] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            rulerHost.topAnchor.constraint(equalTo: content.topAnchor),
            rulerHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rulerHost.trailingAnchor.constraint(equalTo: dockView.leadingAnchor),
            rulerHost.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            rulerHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: dockView.leadingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            dockView.topAnchor.constraint(equalTo: content.topAnchor),
            dockView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            dockView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = content
        content.layoutSubtreeIfNeeded()
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

    /// Fit Selection: zooms to `selection` (APP-006 supplies the selection's bounds).
    func fit(selection: Rect?) {
        guard let selection else { return }
        setViewport(navigation.fit(viewport, rect: selection))
    }

    /// The magnification field: a percentage, a multiplier or a Fit entry; invalid or clamped
    /// input beeps and shows the resulting value.
    func enterMagnification(_ text: String) {
        switch text {
        case StatusBarView.fitPageTitle: fitPage()
        case StatusBarView.fitAllTitle: fitAll()
        case StatusBarView.fitSelectionTitle: beep()
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
        return DocumentWindowState(frame: frame, viewport: viewport, viewMode: viewMode)
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
