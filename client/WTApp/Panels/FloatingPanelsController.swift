import AppKit

/// The floating clusters of the layout, one `NSPanel` each (panels.adoc, "Client": utility
/// panels that hide when the app deactivates and ride along with the document window as its
/// child windows; D-077, magnetic panels: a cluster of groups moves as one window).  App-wide: the
/// layout is one for every window, so a floating cluster appears once, attached to the front
/// document window.
@MainActor
final class FloatingPanelsController {
    let panels: PanelRegistry
    let layoutController: PanelLayoutController
    let interaction: PanelInteraction
    /// The window floating clusters attach to.
    var parentWindow: @MainActor () -> NSWindow? = { nil }

    /// By cluster id (a group floated on its own gets a cluster of its id).
    private(set) var windows: [PanelCluster.ID: FloatingPanelWindow] = [:]
    private var bodies: [PanelID: NSView] = [:]
    private var observation: PanelLayoutController.ObservationToken?
    /// Reduce Transparency switched: floating clusters redraw solid or translucent.
    private var displayObserver: AccessibilityDisplayObserver?

    init(panels: PanelRegistry, layout: PanelLayoutController, interaction: PanelInteraction? = nil) {
        self.panels = panels
        self.layoutController = layout
        self.interaction = interaction ?? PanelInteraction(panels: panels, layout: layout)
        observation = layout.observe { [weak self] layout in self?.render(layout) }
        displayObserver = AccessibilityDisplayObserver { [weak self] in self?.appearanceDidChange() }
    }

    /// Re-renders with the current appearance.
    func appearanceDidChange() {
        for window in windows.values { window.close() }
        windows = [:]
        render(layoutController.layout)
    }

    func body(for panel: PanelID) -> NSView {
        if let existing = bodies[panel] { return existing }
        let body = panels.descriptor(for: panel)?.makeView() ?? NSView()
        bodies[panel] = body
        return body
    }

    /// The window of the floating cluster holding group `id`.
    func window(containing id: PanelGroup.ID) -> FloatingPanelWindow? {
        layoutController.layout.cluster(containing: id).flatMap { windows[$0.id] }
    }

    /// Opens a panel per floating cluster, updates the rest, closes those that docked or closed.
    func render(_ layout: PanelLayout) {
        let floating = Dictionary(layout.floatingClusters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, window) in windows where floating[id] == nil {
            window.close()
            windows[id] = nil
        }
        let appearance = interaction.appearance()
        for (id, cluster) in floating {
            let window = windows[id] ?? FloatingPanelWindow(clusterID: id, layout: layoutController, translucent: appearance.isTranslucent)
            windows[id] = window
            let existing = Dictionary((window.clusterView?.groupViews ?? []).map { ($0.group.id, $0) }, uniquingKeysWith: { first, _ in first })
            let columns = cluster.columns.map { column in
                column.groups.map { group -> PanelGroupView in
                    if let view = existing[group.id], view.canShow(group, appearance: appearance) {
                        view.show(group, body: body(for:))
                        return view
                    }
                    return interaction.makeGroupView(group, floating: true, body: body(for:))
                }
            }
            window.show(cluster, columns: columns, translucent: appearance.isTranslucent, parent: parentWindow())
        }
    }

    /// The front document window changed: floating clusters follow it.
    func reattach() {
        let parent = parentWindow()
        for window in windows.values { window.attach(to: parent) }
    }
}

/// One floating cluster's window: a utility panel whose content is the cluster on the system
/// glass with the chrome's frost, rounded all round, casting the window's shadow (D-077; solid
/// under *Panel transparency* Solid or Reduce Transparency) -- the window itself is clear --
/// without the standard title bar buttons (each group's title bar has its own close button, and
/// dragging a title bar moves the cluster).  Resizing it, or moving it by other means, writes the
/// frame into the layout.  A cluster whose groups are all collapsed shrinks to their title bars,
/// its top edge staying put and its stored frame keeping the full size.
@MainActor
final class FloatingPanelWindow: NSPanel, NSWindowDelegate {
    static let cornerRadius: CGFloat = PanelClusterView.floatingCornerRadius

    let clusterID: PanelCluster.ID
    let layoutController: PanelLayoutController
    private var isApplyingLayout = false
    /// A cluster drag is moving the window: its moves are not written into the layout (the drag
    /// writes the settled frame).
    var isTracking = false

    init(clusterID: PanelCluster.ID, layout: PanelLayoutController, translucent: Bool = true) {
        self.clusterID = clusterID
        self.layoutController = layout
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 320), styleMask: [.utilityWindow, .titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = NSSize(width: 120, height: PanelGroupView.titleHeight)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(button)?.isHidden = true }
        identifier = NSUserInterfaceItemIdentifier("floating-group.\(clusterID)")
        setAccessibilityIdentifier("floating-group.\(clusterID)")
        contentView = PanelClusterView(attachment: .floating, translucent: translucent)
        delegate = self
    }

    /// The cluster the window shows.
    var clusterView: PanelClusterView? { contentView as? PanelClusterView }

    /// Every group view of the cluster.
    var groupViews: [PanelGroupView] { clusterView?.groupViews ?? [] }

    /// Shows `cluster`'s `columns` of group views at its frame, attached to `parent`.
    func show(_ cluster: PanelCluster, columns: [[PanelGroupView]], translucent: Bool, parent: NSWindow?) {
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        let view = clusterView ?? PanelClusterView(attachment: .floating, translucent: translucent)
        if contentView !== view { contentView = view }
        view.isTranslucent = translucent
        view.preferredHeight = { [weak self] group in self?.preferredHeight(for: group) ?? PanelLayout.defaultGroupHeight }
        view.onResize = { [weak self] heights in
            self?.layoutController.update { layout in for (id, height) in heights { layout.setHeight(height, group: id) } }
        }
        view.onColumnResize = { [weak self] column, width in
            guard let self else { return }
            self.layoutController.update { $0.setColumnWidth(width, cluster: self.clusterID, column: column) }
        }
        view.show(columns: columns, widths: cluster.columns.map(\.width), attachment: .floating, clusterID: cluster.id)
        // The last column (which takes a change of width) keeps a usable width.
        let fixed = cluster.width - (cluster.columns.last?.width ?? 0)
        minSize = NSSize(width: CGFloat(fixed + PanelCluster.minimumColumnWidth), height: PanelGroupView.titleHeight)
        let frame = cluster.frame ?? LayoutRect(x: 200, y: 200, width: cluster.width, height: 320)
        var rect = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        if let collapsed = PanelClusterView.collapsedHeight(of: cluster), collapsed < rect.height {
            rect.origin.y = rect.maxY - collapsed
            rect.size.height = collapsed
        }
        if !isTracking { setFrame(rect, display: false) }
        view.needsLayout = true
        attach(to: parent)
        orderFront(nil)
        invalidateShadow()
    }

    /// The height a group asks for: its stored height, else its default group's.
    private func preferredHeight(for group: PanelGroup) -> Double {
        if let height = group.height { return height }
        let registry = layoutController.registry
        let defaults = registry.groupDefaults.first { PanelGroup.id(forName: $0.key) == group.id }?.value
        return defaults?.height ?? PanelLayout.defaultGroupHeight
    }

    func attach(to parent: NSWindow?) {
        guard self.parent !== parent else { return }
        self.parent?.removeChildWindow(self)
        parent?.addChildWindow(self, ordered: .above)
    }

    var layoutFrame: LayoutRect {
        LayoutRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }

    /// The user moved or resized the panel.
    func frameDidChange() {
        guard !isApplyingLayout, !isTracking, let cluster = layoutController.layout.cluster(clusterID), let stored = cluster.frame else { return }
        var frame = layoutFrame
        if PanelClusterView.collapsedHeight(of: cluster) != nil {
            // Collapsed, the window is the title bars: keep the stored height, move the top edge.
            frame = LayoutRect(x: frame.x, y: frame.maxY - stored.height, width: frame.width, height: stored.height)
        }
        layoutController.update { $0.setFrame(frame, cluster: clusterID) }
    }

    func windowDidMove(_ notification: Notification) { frameDidChange() }
    func windowDidEndLiveResize(_ notification: Notification) { frameDidChange() }
}
