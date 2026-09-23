import AppKit

/// What every host of panel groups (a dock edge, a floating panel) does with the gestures of
/// its group views: one layout operation per gesture, the Options menu, drags between hosts.
/// The decisions are in `PanelLayout` and `PanelOption`; this only wires them.
@MainActor
final class PanelInteraction: NSObject, NSDraggingSource, NSMenuItemValidation {
    let panels: PanelRegistry
    let layoutController: PanelLayoutController
    /// *Label panel tabs with* and *Show tooltips*, read at every render.
    var appearance: @MainActor () -> PanelAppearance = { .standard }
    /// *Help for <panel>*.
    var onHelp: @MainActor (PanelDescriptor) -> Void = { _ in }
    /// Where a group floats when *Float Group* is chosen (near the document window).
    var floatingFrame: @MainActor () -> LayoutRect = { LayoutRect(x: 200, y: 200, width: 260, height: 320) }
    /// The drag in flight, so a drop outside every target can float it.
    private(set) var currentDrag: PanelDragPayload?
    /// Starts the AppKit dragging session (replaceable in tests, which have no mouse).
    var startDragSession: @MainActor (NSView, NSDraggingItem, NSEvent, NSDraggingSource) -> Void = { view, item, event, source in
        view.beginDraggingSession(with: [item], event: event, source: source)
    }
    /// Shows the Options menu under its button (a modal tracking loop; replaceable in tests).
    var presentMenu: @MainActor (NSMenu, NSButton) -> Void = { menu, button in
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    init(panels: PanelRegistry, layout: PanelLayoutController) {
        self.panels = panels
        self.layoutController = layout
    }

    private func update(_ change: (inout PanelLayout) -> Void) { layoutController.update(change) }

    /// Wires `groupView`'s gestures to layout operations.
    func connect(_ groupView: PanelGroupView) {
        let id = groupView.group.id
        groupView.onSelectTab = { [weak self] panel in self?.update { $0.activate(panel) } }
        groupView.onToggleCollapse = { [weak self] in self?.update { $0.toggleCollapsed(group: id) } }
        groupView.onDrop = { [weak self] payload, index in self?.drop(payload, onGroup: id, at: index) }
        groupView.onDragTab = { [weak self] button, event in self?.beginDrag(.panel(button.panelID), from: button, event: event) }
        groupView.onDragGroup = { [weak self, weak groupView] event in
            guard let self, let groupView else { return }
            self.beginDrag(.group(id), from: groupView, event: event)
        }
        groupView.onRename = { [weak self] name in self?.update { $0.rename(group: id, to: name) } }
        groupView.onClose = { [weak self] in self?.update { $0.close(group: id) } }
        groupView.onOptions = { [weak self, weak groupView] button in
            guard let self, let groupView, let panel = groupView.group.effectiveActivePanel else { return }
            self.presentMenu(self.optionsMenu(for: panel, in: groupView), button)
        }
    }

    // MARK: Drops

    /// A panel dropped on a group's tab strip joins it at `index` (or moves there, within the
    /// same group); a group dropped on it merges into it.
    func drop(_ payload: PanelDragPayload, onGroup target: PanelGroup.ID, at index: Int?) {
        switch payload {
        case let .panel(panel):
            let sameGroup = layoutController.layout.group(containing: panel)?.id == target
            update { layout in
                if sameGroup, let index {
                    layout.reorderPanel(panel, to: index)
                } else {
                    layout.movePanel(panel, toGroup: target, at: index)
                }
            }
        case let .group(group):
            update { $0.merge(group: group, into: target) }
        }
    }

    /// A panel dropped on a dock splits into a new group there; a group docks there.
    func drop(_ payload: PanelDragPayload, onDock edge: DockEdge, at index: Int) {
        switch payload {
        case let .panel(panel): update { $0.movePanel(panel, toNewGroupAt: edge, index: index) }
        case let .group(group): update { $0.dock(group: group, at: edge, index: index) }
        }
    }

    /// A drag that ended outside every target floats what it carried at `screenPoint` (the
    /// frame's top-left).
    func dropOutside(_ payload: PanelDragPayload, at screenPoint: NSPoint) {
        let size = floatingFrame()
        let frame = LayoutRect(x: screenPoint.x, y: screenPoint.y - size.height, width: size.width, height: size.height)
        switch payload {
        case let .panel(panel): update { $0.floatPanel(panel, frame: frame) }
        case let .group(group):
            update { layout in
                if layout.edge(of: group) != nil {
                    layout.float(group: group, frame: frame)
                } else {
                    layout.setFrame(frame, floatingGroup: group)
                }
            }
        }
    }

    // MARK: Drags

    /// Remembers what is being dragged, for `dragEnded`.
    func beginTracking(_ payload: PanelDragPayload) {
        currentDrag = payload
    }

    func beginDrag(_ payload: PanelDragPayload, from view: NSView, event: NSEvent) {
        beginTracking(payload)
        let item = NSDraggingItem(pasteboardWriter: payload.pasteboardItem)
        let image = NSImage(size: view.bounds.size, flipped: false) { rect in
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            rect.fill()
            return true
        }
        item.setDraggingFrame(view.bounds, contents: image)
        startDragSession(view, item, event, self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragEnded(at: screenPoint, operation: operation)
    }

    /// No drop target took the drag: float it.
    func dragEnded(at screenPoint: NSPoint, operation: NSDragOperation) {
        defer { currentDrag = nil }
        guard operation.isEmpty, let payload = currentDrag else { return }
        dropOutside(payload, at: screenPoint)
    }

    // MARK: Options menu

    /// The Options menu of `panel` (the front tab of `groupView`).
    func optionsMenu(for panel: PanelID, in groupView: PanelGroupView) -> NSMenu {
        let sections = PanelOption.menu(for: panel, layout: layoutController.layout, registry: panels)
        let title = panels.title(for: panel)
        let menu = NSMenu(title: title)
        for option in sections.custom { menu.addItem(item(option, panel: panel, groupView: groupView)) }
        if !sections.custom.isEmpty { menu.addItem(.separator()) }
        let groupWith = NSMenuItem(title: PanelOption.groupWithTitle(title), action: nil, keyEquivalent: "")
        groupWith.submenu = NSMenu(title: groupWith.title)
        for option in sections.groupWith { groupWith.submenu?.addItem(item(option, panel: panel, groupView: groupView)) }
        groupWith.identifier = NSUserInterfaceItemIdentifier("panel-options.groupWith")
        menu.addItem(groupWith)
        for option in sections.tail {
            let entry = item(option, panel: panel, groupView: groupView)
            if case .help = option { entry.title = PanelOption.helpTitle(title) }
            menu.addItem(entry)
        }
        return menu
    }

    /// Carries what a menu item does.
    final class OptionTarget: NSObject {
        let option: PanelOption
        let panel: PanelID
        weak var groupView: PanelGroupView?

        init(option: PanelOption, panel: PanelID, groupView: PanelGroupView) {
            self.option = option
            self.panel = panel
            self.groupView = groupView
        }
    }

    private func item(_ option: PanelOption, panel: PanelID, groupView: PanelGroupView) -> NSMenuItem {
        let item = NSMenuItem(title: option.title, action: #selector(performOption(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = OptionTarget(option: option, panel: panel, groupView: groupView)
        item.identifier = NSUserInterfaceItemIdentifier("panel-options.\(Self.identifier(of: option))")
        return item
    }

    static func identifier(of option: PanelOption) -> String {
        switch option {
        case let .custom(index, _, _): "custom.\(index)"
        case let .groupWith(group, _): "groupWith.\(group)"
        case .newGroup: "newGroup"
        case .rename: "rename"
        case .float: "float"
        case .dock: "dock"
        case .close: "close"
        case .collapse: "collapse"
        case .help: "help"
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let target = menuItem.representedObject as? OptionTarget else { return false }
        if case let .custom(_, _, isEnabled) = target.option { return isEnabled }
        return true
    }

    @objc func performOption(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? OptionTarget else { return }
        perform(target.option, panel: target.panel, groupView: target.groupView)
    }

    /// Runs one Options menu entry for `panel`.
    func perform(_ option: PanelOption, panel: PanelID, groupView: PanelGroupView?) {
        guard let group = layoutController.layout.group(containing: panel) else { return }
        switch option {
        case let .custom(index, _, _):
            let items = panels.descriptor(for: panel)?.optionsMenu() ?? []
            if items.indices.contains(index) { items[index].action() }
        case let .groupWith(target, _):
            update { $0.movePanel(panel, toGroup: target) }
        case .newGroup:
            let edge = layoutController.layout.edge(of: group.id) ?? layoutController.defaultEdge(for: group)
            update { $0.movePanel(panel, toNewGroupAt: edge) }
        case .rename:
            groupView?.beginRename()
        case .float:
            let frame = floatingFrame()
            update { $0.float(group: group.id, frame: frame) }
        case .dock:
            let edge = layoutController.defaultEdge(for: group)
            update { $0.dock(group: group.id, at: edge) }
        case .close:
            update { $0.close(group: group.id) }
        case .collapse:
            update { $0.setCollapsed(true, group: group.id) }
        case .help:
            if let descriptor = panels.descriptor(for: panel) { onHelp(descriptor) }
        }
    }

    /// A group view for `group` in this host's style.
    func makeGroupView(_ group: PanelGroup, floating: Bool, body: (PanelID) -> NSView) -> PanelGroupView {
        let registry = panels
        let view = PanelGroupView(
            group: group, title: registry.title(for:), icon: { registry.descriptor(for: $0)?.icon ?? "square.dashed" }, body: body,
            appearance: appearance(), isFloating: floating
        )
        connect(view)
        return view
    }
}

/// Renders one edge of a `PanelLayout` into a dock: a column (left, right) or row (top,
/// bottom) of `PanelGroupView`s.  The view is rebuilt from the layout it observes; panel bodies
/// are created once and reused, so a re-render (a preference change) never closes a panel.
@MainActor
final class PanelDockController: NSViewController {
    static let accessibilityIdentifier = "panel-dock"
    nonisolated static let pasteboardType = PanelDragPayload.panelType
    static let defaultWidth: CGFloat = 280

    let panels: PanelRegistry
    let layoutController: PanelLayoutController
    let edge: DockEdge
    let interaction: PanelInteraction

    private let stack = NSStackView()
    private(set) var groupViews: [PanelGroupView] = []
    private var bodies: [PanelID: NSView] = [:]
    /// Width for a side dock, height for a strip.
    private(set) var sizeConstraint: NSLayoutConstraint?
    private var observation: PanelLayoutController.ObservationToken?

    init(panels: PanelRegistry, layout: PanelLayoutController, edge: DockEdge = .right, interaction: PanelInteraction? = nil) {
        self.panels = panels
        self.layoutController = layout
        self.edge = edge
        self.interaction = interaction ?? PanelInteraction(panels: panels, layout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelDockController is built in code")
    }

    /// The width constraint of a side dock (nil for a strip).
    var widthConstraint: NSLayoutConstraint? { edge.isVertical ? sizeConstraint : nil }

    override func loadView() {
        let dock = DockDropView()
        dock.controller = self
        dock.translatesAutoresizingMaskIntoConstraints = false
        dock.wantsLayer = true
        dock.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        dock.setAccessibilityElement(true)
        dock.setAccessibilityRole(.group)
        dock.setAccessibilityIdentifier(edge == .right ? Self.accessibilityIdentifier : "\(Self.accessibilityIdentifier).\(edge.rawValue)")
        dock.setAccessibilityLabel("Panels")

        stack.orientation = edge.isVertical ? .vertical : .horizontal
        stack.alignment = edge.isVertical ? .leading : .top
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        dock.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: dock.topAnchor),
            stack.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
            edge.isVertical ? stack.trailingAnchor.constraint(equalTo: dock.trailingAnchor) : stack.trailingAnchor.constraint(lessThanOrEqualTo: dock.trailingAnchor),
            edge.isVertical ? stack.bottomAnchor.constraint(lessThanOrEqualTo: dock.bottomAnchor) : stack.bottomAnchor.constraint(equalTo: dock.bottomAnchor),
        ])
        let size = edge.isVertical ? dock.widthAnchor.constraint(equalToConstant: Self.defaultWidth) : dock.heightAnchor.constraint(equalToConstant: 0)
        size.isActive = true
        sizeConstraint = size
        view = dock
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = layoutController.observe { [weak self] layout in self?.render(layout) }
        render(layoutController.layout)
    }

    /// Re-renders with the current appearance (a *Panels* preference changed).
    func appearanceDidChange() {
        render(layoutController.layout)
    }

    /// Rebuilds the dock from `layout`.
    func render(_ layout: PanelLayout) {
        for subview in stack.views { stack.removeView(subview) }
        let groups = layout.docks[edge] ?? []
        groupViews = groups.map { interaction.makeGroupView($0, floating: false, body: body(for:)) }
        for groupView in groupViews {
            stack.addView(groupView, in: .top)
            if edge.isVertical {
                groupView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else {
                groupView.widthAnchor.constraint(equalToConstant: 320).isActive = true
            }
        }
        let hidden = layout.hiddenDocks.contains(edge) || (!edge.isVertical && groups.isEmpty)
        view.isHidden = hidden
        let size = layout.dockWidth[edge] ?? (edge.isVertical ? Double(Self.defaultWidth) : 44)
        sizeConstraint?.constant = hidden ? 0 : CGFloat(edge.isVertical ? size : max(size, Self.stripHeight(for: groups)))
    }

    /// A strip is as tall as its tallest expanded group.
    static func stripHeight(for groups: [PanelGroup]) -> Double {
        groups.map { $0.collapsed ? 30 : ($0.height ?? PanelLayout.defaultGroupHeight) + 30 }.max() ?? 0
    }

    /// The panel's body view, created once and reused across renders.
    func body(for panel: PanelID) -> NSView {
        if let existing = bodies[panel] { return existing }
        let body = panels.descriptor(for: panel)?.makeView() ?? NSView()
        bodies[panel] = body
        return body
    }

    // MARK: Drag and drop

    /// A drop on the dock background: a panel splits into a new group at the drop position, a
    /// group docks there.
    func handleDrop(_ payload: PanelDragPayload, atDockPoint point: CGPoint) {
        let local = stack.convert(point, from: view)
        let index = edge.isVertical
            ? Self.insertionIndex(forY: local.y, groupFrames: groupViews.map(\.frame))
            : Self.tabIndex(forX: local.x, frames: groupViews.map(\.frame))
        interaction.drop(payload, onDock: edge, at: index)
    }

    func handleDrop(of panel: PanelID, atDockPoint point: CGPoint) {
        handleDrop(.panel(panel), atDockPoint: point)
    }

    /// The group index a drop at `y` lands before: the number of groups whose middle is above
    /// it (AppKit's y axis points up, and the first group is at the top).
    static func insertionIndex(forY y: CGFloat, groupFrames: [CGRect]) -> Int {
        groupFrames.filter { $0.midY > y }.count
    }

    /// The index a drop at `x` lands before in a row (tabs in a strip, groups in a toolbar strip).
    static func tabIndex(forX x: CGFloat, frames: [CGRect]) -> Int {
        frames.filter { $0.midX < x }.count
    }

    static func panelID(on pasteboard: NSPasteboard) -> PanelID? {
        if case let .panel(panel)? = PanelDragPayload.read(from: pasteboard) { return panel }
        return nil
    }

    func beginDrag(of panel: PanelID, from view: NSView, event: NSEvent) {
        interaction.beginDrag(.panel(panel), from: view, event: event)
    }
}

/// The dock's background: a drop target for panels and groups dragged into it.
@MainActor
final class DockDropView: NSView {
    weak var controller: PanelDockController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([PanelDragPayload.panelType, PanelDragPayload.groupType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DockDropView is built in code")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PanelDragPayload.read(from: sender.draggingPasteboard) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = PanelDragPayload.read(from: sender.draggingPasteboard), let controller else { return false }
        controller.handleDrop(payload, atDockPoint: convert(sender.draggingLocation, from: nil))
        return true
    }
}

/// The thin handle between the canvas and a side dock (panels.adoc, "To show or hide the whole
/// dock"): a click hides or shows the dock, a drag resizes it.
@MainActor
final class DockHandleView: NSView {
    static let thickness: CGFloat = 6
    /// A drag shorter than this (points) is a click.
    static let clickSlop: CGFloat = 3

    let edge: DockEdge
    let layoutController: PanelLayoutController

    init(edge: DockEdge, layout: PanelLayoutController) {
        self.edge = edge
        self.layoutController = layout
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.separatorColor.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityIdentifier("dock-handle.\(edge.rawValue)")
        setAccessibilityLabel("Show or hide the panels")
        toolTip = "Click to show or hide the panels; drag to resize"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DockHandleView is built in code")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    /// The dock width after dragging the handle `dx` points to the right from `width` (the
    /// right dock grows when dragged left).
    static func width(from width: Double, draggedBy dx: Double, edge: DockEdge) -> Double {
        max(PanelLayout.minimumDockWidth, edge == .right ? width - dx : width + dx)
    }

    /// Ends a gesture: a click toggles the dock, a drag has already resized it.
    func finish(totalDelta dx: CGFloat) {
        if abs(dx) < Self.clickSlop { layoutController.update { $0.toggleDockHidden(edge) } }
    }

    /// Resizes the dock during a drag that started at `startWidth`.
    func drag(startWidth: Double, by dx: CGFloat) {
        guard abs(dx) >= Self.clickSlop else { return }
        let width = Self.width(from: startWidth, draggedBy: Double(dx), edge: edge)
        layoutController.update { layout in
            layout.setDockHidden(false, edge: edge)
            layout.setDockWidth(width, edge: edge)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow.x
        let startWidth = layoutController.layout.dockWidth[edge] ?? Double(PanelDockController.defaultWidth)
        var dx: CGFloat = 0
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            dx = next.locationInWindow.x - start
            if next.type == .leftMouseUp { break }
            drag(startWidth: startWidth, by: dx)
        }
        finish(totalDelta: dx)
    }
}

/// One group: an optional close button (floating), the gripper, the disclosure triangle, the
/// title (or the rename field), the Options button; a tab per panel; the front panel's body.
/// Reports gestures through closures and never touches the layout itself.
@MainActor
final class PanelGroupView: NSView, NSTextFieldDelegate {
    let group: PanelGroup
    let isFloating: Bool
    let panelAppearance: PanelAppearance
    private(set) var titleLabel: NSTextField
    private(set) var renameField: NSTextField?
    private(set) var disclosure: NSButton
    private(set) var optionsButton: NSButton
    private(set) var closeButton: NSButton?
    private(set) var gripper: GripperView
    private(set) var tabButtons: [PanelTabButton] = []
    private(set) var tabBar: NSStackView
    private(set) var contentView = NSView()
    private var titleBar: NSStackView

    var onSelectTab: ((PanelID) -> Void)?
    var onToggleCollapse: (() -> Void)?
    /// A panel or group dropped on the tab strip, before tab `index` (nil: at the end).
    var onDrop: ((PanelDragPayload, Int?) -> Void)?
    var onDragTab: ((PanelTabButton, NSEvent) -> Void)?
    var onDragGroup: ((NSEvent) -> Void)?
    var onRename: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onOptions: ((NSButton) -> Void)?

    init(
        group: PanelGroup, title: (PanelID) -> String, icon: (PanelID) -> String = { _ in "square.dashed" }, body: (PanelID) -> NSView,
        appearance: PanelAppearance = .standard, isFloating: Bool = false
    ) {
        self.group = group
        self.isFloating = isFloating
        self.panelAppearance = appearance
        titleLabel = NSTextField(labelWithString: group.displayName(titles: title))
        titleLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        disclosure = NSButton(title: "", target: nil, action: nil)
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.state = group.collapsed ? .off : .on
        optionsButton = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Options")!, target: nil, action: nil)
        optionsButton.isBordered = false
        gripper = GripperView()
        titleBar = NSStackView()
        tabBar = NSStackView()
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("panel-group.\(group.id)")
        registerForDraggedTypes([PanelDragPayload.panelType, PanelDragPayload.groupType])
        disclosure.target = self
        disclosure.action = #selector(toggleCollapse(_:))
        disclosure.setAccessibilityIdentifier("panel-group.\(group.id).disclosure")
        optionsButton.target = self
        optionsButton.action = #selector(showOptions(_:))
        optionsButton.setAccessibilityIdentifier("panel-group.\(group.id).options")
        optionsButton.toolTip = appearance.showsTooltips ? "Options" : nil
        gripper.onDrag = { [weak self] event in self?.onDragGroup?(event) }
        gripper.setAccessibilityIdentifier("panel-group.\(group.id).gripper")

        var titleViews: [NSView] = []
        if isFloating {
            let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Group")!, target: self, action: #selector(closeGroup(_:)))
            close.isBordered = false
            close.setAccessibilityIdentifier("panel-group.\(group.id).close")
            closeButton = close
            titleViews.append(close)
        }
        titleViews += [gripper, disclosure, titleLabel, NSView(), optionsButton]
        titleBar.setViews(titleViews, in: .leading)
        titleBar.orientation = .horizontal
        titleBar.spacing = 4
        titleBar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

        let active = group.effectiveActivePanel
        tabButtons = group.panels.map { panel in
            let label = appearance.tabLabel(title: title(panel), icon: icon(panel))
            let button = PanelTabButton(panelID: panel, title: label.title, image: label.image)
            button.toolTip = appearance.showsTooltips ? title(panel) : nil
            button.setAccessibilityLabel(title(panel))
            button.state = panel == active ? .on : .off
            button.target = self
            button.action = #selector(selectTab(_:))
            button.onDrag = { [weak self] button, event in self?.onDragTab?(button, event) }
            return button
        }
        tabBar.setViews(tabButtons, in: .leading)
        tabBar.orientation = .horizontal
        tabBar.spacing = 2
        tabBar.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 2, right: 6)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.heightAnchor.constraint(equalToConstant: CGFloat(group.height ?? PanelLayout.defaultGroupHeight)).isActive = true
        if let active {
            let bodyView = body(active)
            bodyView.removeFromSuperview()
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

    @objc func showOptions(_ sender: NSButton) {
        onOptions?(sender)
    }

    @objc func closeGroup(_ sender: Any?) {
        onClose?()
    }

    // MARK: Renaming

    /// *Rename Panel Group…*: the title becomes a field holding the current name.
    func beginRename() {
        guard renameField == nil else { return }
        let field = NSTextField(string: titleLabel.stringValue)
        field.font = titleLabel.font
        field.delegate = self
        field.setAccessibilityIdentifier("panel-group.\(group.id).rename")
        renameField = field
        titleLabel.isHidden = true
        titleBar.insertView(field, at: (titleBar.views.firstIndex(of: titleLabel) ?? 0) + 1, in: .leading)
        window?.makeFirstResponder(field)
    }

    /// Ends renaming: commits a non-empty name when `committed`, otherwise changes nothing.
    func endRename(committed: Bool) {
        guard let field = renameField else { return }
        renameField = nil
        field.delegate = nil
        titleBar.removeView(field)
        titleLabel.isHidden = false
        if case let .commit(name) = GroupRename.outcome(text: field.stringValue, committed: committed) {
            titleLabel.stringValue = name
            onRename?(name)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endRename(committed: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endRename(committed: false)
            return true
        default:
            return false
        }
    }

    /// Clicking anywhere else cancels.
    func controlTextDidEndEditing(_ notification: Notification) {
        endRename(committed: false)
    }

    // MARK: Drops

    /// The tab index a drop at `point` (in this view) lands before.
    func tabIndex(at point: CGPoint) -> Int {
        let local = tabBar.convert(point, from: self)
        return PanelDockController.tabIndex(forX: local.x, frames: tabButtons.map(\.frame))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PanelDragPayload.read(from: sender.draggingPasteboard) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = PanelDragPayload.read(from: sender.draggingPasteboard) else { return false }
        onDrop?(payload, tabIndex(at: convert(sender.draggingLocation, from: nil)))
        return true
    }
}

/// The textured area at the left of a group's title bar: dragging it moves the group between
/// the dock and the pasteboard.
@MainActor
final class GripperView: NSImageView {
    var onDrag: ((NSEvent) -> Void)?

    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Gripper")
        contentTintColor = .tertiaryLabelColor
        setAccessibilityLabel("Gripper")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GripperView is built in code")
    }

    override func mouseDown(with event: NSEvent) {
        onDrag?(event)
    }
}

/// A tab in a group's strip.  A click selects the tab; a drag hands the panel to the host's
/// dragging session.
@MainActor
final class PanelTabButton: NSButton {
    let panelID: PanelID
    var onDrag: ((PanelTabButton, NSEvent) -> Void)?

    init(panelID: PanelID, title: String, image: NSImage? = nil) {
        self.panelID = panelID
        super.init(frame: .zero)
        self.title = title
        self.image = image
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
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
