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
        for (id, floater) in floating {
            let window = windows[id] ?? FloatingPanelWindow(groupID: id, layout: layoutController)
            windows[id] = window
            let groupView = interaction.makeGroupView(floater.group, floating: true, body: body(for:))
            window.show(groupView, frame: floater.frame, parent: parentWindow())
        }
    }

    /// The front document window changed: floating groups follow it.
    func reattach() {
        let parent = parentWindow()
        for window in windows.values { window.attach(to: parent) }
    }
}

/// One floating group's window.  Moving or resizing it writes the frame into the layout.
@MainActor
final class FloatingPanelWindow: NSPanel, NSWindowDelegate {
    let groupID: PanelGroup.ID
    let layoutController: PanelLayoutController
    private var isApplyingLayout = false

    init(groupID: PanelGroup.ID, layout: PanelLayoutController) {
        self.groupID = groupID
        self.layoutController = layout
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 320), styleMask: [.utilityWindow, .titled, .resizable, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        identifier = NSUserInterfaceItemIdentifier("floating-group.\(groupID)")
        setAccessibilityIdentifier("floating-group.\(groupID)")
        delegate = self
    }

    /// Shows `groupView` at `frame`, attached to `parent`.
    func show(_ groupView: PanelGroupView, frame: LayoutRect, parent: NSWindow?) {
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        contentView = groupView
        setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
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
        let frame = layoutFrame
        layoutController.update { $0.setFrame(frame, floatingGroup: groupID) }
    }

    func windowDidMove(_ notification: Notification) { frameDidChange() }
    func windowDidEndLiveResize(_ notification: Notification) { frameDidChange() }
}
