import AppKit

/// Renders one edge of a `PanelLayout` into a dock: a column of `PanelGroupView`s, each with a
/// title bar, a tab strip and the front panel's body.  Every user gesture becomes one layout
/// operation on the controller; the view is rebuilt from the layout it observes.  Thin by
/// design: the decisions are in `PanelLayout`.
@MainActor
final class PanelDockController: NSViewController, NSDraggingSource {
    static let accessibilityIdentifier = "panel-dock"
    nonisolated static let pasteboardType = NSPasteboard.PasteboardType("com.villagecompute.wiretuner.panel-id")
    static let defaultWidth: CGFloat = 280

    let panels: PanelRegistry
    let layoutController: PanelLayoutController
    let edge: DockEdge

    private let stack = NSStackView()
    private(set) var groupViews: [PanelGroupView] = []
    private var bodies: [PanelID: NSView] = [:]
    private(set) var widthConstraint: NSLayoutConstraint?
    private var observation: PanelLayoutController.ObservationToken?

    init(panels: PanelRegistry, layout: PanelLayoutController, edge: DockEdge = .right) {
        self.panels = panels
        self.layoutController = layout
        self.edge = edge
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelDockController is built in code")
    }

    override func loadView() {
        let dock = DockDropView()
        dock.controller = self
        dock.translatesAutoresizingMaskIntoConstraints = false
        dock.wantsLayer = true
        dock.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        dock.setAccessibilityElement(true)
        dock.setAccessibilityRole(.group)
        dock.setAccessibilityIdentifier(Self.accessibilityIdentifier)
        dock.setAccessibilityLabel("Panels")

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        dock.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: dock.topAnchor),
            stack.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: dock.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: dock.bottomAnchor),
        ])
        let width = dock.widthAnchor.constraint(equalToConstant: Self.defaultWidth)
        width.isActive = true
        widthConstraint = width
        view = dock
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = layoutController.observe { [weak self] layout in self?.render(layout) }
        render(layoutController.layout)
    }

    /// Rebuilds the column from `layout`.
    func render(_ layout: PanelLayout) {
        for subview in stack.views { stack.removeView(subview) }
        groupViews = (layout.docks[edge] ?? []).map(makeGroupView)
        for groupView in groupViews {
            stack.addView(groupView, in: .top)
            groupView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let hidden = layout.hiddenDocks.contains(edge)
        view.isHidden = hidden
        widthConstraint?.constant = hidden ? 0 : CGFloat(layout.dockWidth[edge] ?? Double(Self.defaultWidth))
    }

    private func makeGroupView(_ group: PanelGroup) -> PanelGroupView {
        let groupView = PanelGroupView(group: group, title: panels.title(for:), body: body(for:))
        groupView.onSelectTab = { [weak self] panel in
            self?.layoutController.update { $0.activate(panel) }
        }
        groupView.onToggleCollapse = { [weak self] in
            self?.layoutController.update { $0.toggleCollapsed(group: group.id) }
        }
        groupView.onDropPanel = { [weak self] panel in
            self?.layoutController.update { $0.movePanel(panel, toGroup: group.id) }
        }
        groupView.onDragTab = { [weak self] button, event in
            self?.beginDrag(of: button.panelID, from: button, event: event)
        }
        return groupView
    }

    /// The panel's body view, created once and reused across renders.
    func body(for panel: PanelID) -> NSView {
        if let existing = bodies[panel] { return existing }
        let body = panels.descriptor(for: panel)?.makeView() ?? NSView()
        bodies[panel] = body
        return body
    }

    // MARK: Drag and drop

    /// A drop on the dock background splits the panel into a new group at the drop position.
    func handleDrop(of panel: PanelID, atDockPoint point: CGPoint) {
        let y = stack.convert(point, from: view).y
        let index = Self.insertionIndex(forY: y, groupFrames: groupViews.map(\.frame))
        layoutController.update { $0.movePanel(panel, toNewGroupAt: edge, index: index) }
    }

    /// The group index a drop at `y` lands before: the number of groups whose middle is above
    /// it (AppKit's y axis points up, and the first group is at the top).
    static func insertionIndex(forY y: CGFloat, groupFrames: [CGRect]) -> Int {
        groupFrames.filter { $0.midY > y }.count
    }

    static func panelID(on pasteboard: NSPasteboard) -> PanelID? {
        pasteboard.string(forType: pasteboardType).map(PanelID.init(rawValue:))
    }

    func beginDrag(of panel: PanelID, from view: NSView, event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(panel.rawValue, forType: Self.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: view.bounds.size, flipped: false) { rect in
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            rect.fill()
            return true
        }
        draggingItem.setDraggingFrame(view.bounds, contents: image)
        view.beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }
}

/// The dock's background: a drop target for panels dragged out of their groups.
@MainActor
final class DockDropView: NSView {
    weak var controller: PanelDockController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([PanelDockController.pasteboardType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DockDropView is built in code")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PanelDockController.panelID(on: sender.draggingPasteboard) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let panel = PanelDockController.panelID(on: sender.draggingPasteboard), let controller else { return false }
        controller.handleDrop(of: panel, atDockPoint: convert(sender.draggingLocation, from: nil))
        return true
    }
}

/// One group in the dock: gripper, disclosure triangle and title; a tab per panel; the front
/// panel's body.  Reports gestures through closures and never touches the layout itself.
@MainActor
final class PanelGroupView: NSView {
    let group: PanelGroup
    private(set) var titleLabel: NSTextField
    private(set) var disclosure: NSButton
    private(set) var tabButtons: [PanelTabButton] = []
    private(set) var contentView = NSView()

    var onSelectTab: ((PanelID) -> Void)?
    var onToggleCollapse: (() -> Void)?
    var onDropPanel: ((PanelID) -> Void)?
    var onDragTab: ((PanelTabButton, NSEvent) -> Void)?

    init(group: PanelGroup, title: (PanelID) -> String, body: (PanelID) -> NSView) {
        self.group = group
        titleLabel = NSTextField(labelWithString: group.displayName(titles: title))
        titleLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        disclosure = NSButton(title: "", target: nil, action: nil)
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.state = group.collapsed ? .off : .on
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("panel-group.\(group.id)")
        registerForDraggedTypes([PanelDockController.pasteboardType])
        disclosure.target = self
        disclosure.action = #selector(toggleCollapse(_:))
        disclosure.setAccessibilityIdentifier("panel-group.\(group.id).disclosure")

        let gripper = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Gripper")!)
        gripper.contentTintColor = .tertiaryLabelColor
        let titleBar = NSStackView(views: [gripper, disclosure, titleLabel])
        titleBar.orientation = .horizontal
        titleBar.spacing = 4
        titleBar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

        let active = group.effectiveActivePanel
        tabButtons = group.panels.map { panel in
            let button = PanelTabButton(panelID: panel, title: title(panel))
            button.state = panel == active ? .on : .off
            button.target = self
            button.action = #selector(selectTab(_:))
            button.onDrag = { [weak self] button, event in self?.onDragTab?(button, event) }
            return button
        }
        let tabBar = NSStackView(views: tabButtons)
        tabBar.orientation = .horizontal
        tabBar.spacing = 2
        tabBar.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 2, right: 6)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.heightAnchor.constraint(equalToConstant: CGFloat(group.height ?? PanelLayout.defaultGroupHeight)).isActive = true
        if let active {
            let bodyView = body(active)
            bodyView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(bodyView)
            NSLayoutConstraint.activate([
                bodyView.topAnchor.constraint(equalTo: contentView.topAnchor),
                bodyView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                bodyView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                bodyView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
        }
        contentView.isHidden = group.collapsed

        let column = NSStackView(views: [titleBar, tabBar, contentView])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleBar.widthAnchor.constraint(equalTo: column.widthAnchor),
            tabBar.widthAnchor.constraint(equalTo: column.widthAnchor),
            contentView.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelGroupView is built in code")
    }

    var isCollapsed: Bool { contentView.isHidden }

    @objc func selectTab(_ sender: PanelTabButton) {
        onSelectTab?(sender.panelID)
    }

    @objc func toggleCollapse(_ sender: Any?) {
        onToggleCollapse?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PanelDockController.panelID(on: sender.draggingPasteboard) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let panel = PanelDockController.panelID(on: sender.draggingPasteboard) else { return false }
        onDropPanel?(panel)
        return true
    }
}

/// A tab in a group's strip.  A click selects the tab; a drag hands the panel to the dock's
/// dragging session.
@MainActor
final class PanelTabButton: NSButton {
    let panelID: PanelID
    var onDrag: ((PanelTabButton, NSEvent) -> Void)?

    init(panelID: PanelID, title: String) {
        self.panelID = panelID
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .recessed
        setButtonType(.pushOnPushOff)
        font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        setAccessibilityIdentifier("panel-tab.\(panelID.rawValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelTabButton is built in code")
    }

    override func mouseDown(with event: NSEvent) {
        guard let window,
            let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: true)
        else { return }
        if next.type == .leftMouseDragged {
            onDrag?(self, event)
        } else {
            performClick(nil)
        }
    }
}
