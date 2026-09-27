import AppKit

/// The floating groups of the layout, one `NSPanel` each (panels.adoc, "Client": utility
/// panels that hide when the app deactivates and ride along with the document window as its
/// child windows).  App-wide: the layout is one for every window, so a floating group appears
/// once, attached to the front document window.
@MainActor
final class FloatingPanelsController {
    let panels: PanelRegistry
    let layoutController: PanelLayoutController
    let interaction: PanelInteraction
    /// The window floating groups attach to.
    var parentWindow: @MainActor () -> NSWindow? = { nil }

    private(set) var windows: [PanelGroup.ID: FloatingPanelWindow] = [:]
    private var bodies: [PanelID: NSView] = [:]
    private var observation: PanelLayoutController.ObservationToken?

    init(panels: PanelRegistry, layout: PanelLayoutController, interaction: PanelInteraction? = nil) {
        self.panels = panels
        self.layoutController = layout
        self.interaction = interaction ?? PanelInteraction(panels: panels, layout: layout)
        observation = layout.observe { [weak self] layout in self?.render(layout) }
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

    /// Opens a panel per floating group, updates the rest, closes those that docked or closed.
    func render(_ layout: PanelLayout) {
        let floating = Dictionary(layout.floating.map { ($0.group.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, window) in windows where floating[id] == nil {
            window.close()
            windows[id] = nil
        }
        let appearance = interaction.appearance()
        for (id, floater) in floating {
            let window = windows[id] ?? FloatingPanelWindow(groupID: id, layout: layoutController)
            windows[id] = window
            if let current = window.contentView as? PanelGroupView, current.canShow(floater.group, appearance: appearance) {
                current.show(floater.group, body: body(for:))
                window.show(current, frame: floater.frame, parent: parentWindow())
            } else {
                window.show(interaction.makeGroupView(floater.group, floating: true, body: body(for:)), frame: floater.frame, parent: parentWindow())
            }
        }
    }

    /// The front document window changed: floating groups follow it.
    func reattach() {
        let parent = parentWindow()
        for window in windows.values { window.attach(to: parent) }
    }
}

/// One floating group's window: a utility panel on the system glass (D-077) -- the window
/// itself is clear and the group view draws the glass -- without the standard title bar
/// buttons (the group's title bar has its own close button and moves the window).  Moving or
/// resizing it writes the frame into the layout.
@MainActor
final class FloatingPanelWindow: NSPanel, NSWindowDelegate {
    static let cornerRadius: CGFloat = 14

    let groupID: PanelGroup.ID
    let layoutController: PanelLayoutController
    private var isApplyingLayout = false

    init(groupID: PanelGroup.ID, layout: PanelLayoutController) {
        self.groupID = groupID
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
        minSize = NSSize(width: 180, height: PanelGroupView.titleHeight)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(button)?.isHidden = true }
        identifier = NSUserInterfaceItemIdentifier("floating-group.\(groupID)")
        setAccessibilityIdentifier("floating-group.\(groupID)")
        delegate = self
    }

    /// Shows `groupView` at `frame`, attached to `parent`.
    func show(_ groupView: PanelGroupView, frame: LayoutRect, parent: NSWindow?) {
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        if contentView !== groupView { contentView = groupView }
        var rect = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        if groupView.isCollapsed {
            // A collapsed floating group is its title bar; its stored frame keeps the full size.
            rect.origin.y = rect.maxY - PanelGroupView.titleHeight
            rect.size.height = PanelGroupView.titleHeight
        }
        setFrame(rect, display: false)
        attach(to: parent)
        orderFront(nil)
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
        guard !isApplyingLayout else { return }
        var frame = layoutFrame
        if (contentView as? PanelGroupView)?.isCollapsed == true,
            case let .floating(index)? = layoutController.layout.location(of: groupID)
        {
            // Collapsed, the window is the title bar: keep the stored height, move the top edge.
            let stored = layoutController.layout.floating[index].frame.height
            frame = LayoutRect(x: frame.x, y: frame.maxY - stored, width: frame.width, height: stored)
        }
        layoutController.update { $0.setFrame(frame, floatingGroup: groupID) }
    }

    func windowDidMove(_ notification: Notification) { frameDidChange() }
    func windowDidEndLiveResize(_ notification: Notification) { frameDidChange() }
}
