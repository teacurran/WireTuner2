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
    /// The cluster drag in flight or last run (D-077, magnetic panels).
    var clusterDrag: PanelClusterDrag?
    /// Runs a cluster drag's mouse loop (replaceable in tests, which have no mouse).
    var runClusterDrag: @MainActor (PanelClusterDrag) -> Void = { PanelClusterDrag.track($0) }
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
            self.beginClusterDrag(from: groupView, event: event)
        }
        groupView.onRename = { [weak self] name in self?.update { $0.rename(group: id, to: name) } }
        groupView.onClose = { [weak self] in self?.update { $0.close(group: id) } }
        groupView.onOptions = { [weak self, weak groupView] button in
            guard let self, let groupView, let panel = groupView.group.effectiveActivePanel else { return }
            self.presentMenu(self.optionsMenu(for: panel, in: groupView), button)
        }
        groupView.tabMenu = { [weak self, weak groupView] panel in
            guard let self, let groupView else { return nil }
            return self.tabMenu(for: panel, in: groupView)
        }
    }

    /// A panel tab's context menu (context-menus.adoc, "Any panel tab"; BASIC-019): *Group
    /// <panel> With ▸*, *Rename Panel Group…*, *Float Group* or *Dock Group*, and *Help for
    /// <panel>* -- the framework's part of the Options menu, without the panel's own items.
    func tabMenu(for panel: PanelID, in groupView: PanelGroupView) -> NSMenu {
        let options = optionsMenu(for: panel, in: groupView)
        let menu = NSMenu(title: options.title)
        let kept = options.items.filter { item in
            guard let target = item.representedObject as? OptionTarget else { return item.submenu != nil }
            switch target.option {
            case .rename, .float, .dock, .help: return true
            default: return false
            }
        }
        for item in kept {
            options.removeItem(item)
            menu.addItem(item)
        }
        return menu
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

    /// A panel dropped on a dock splits into a new group there; a group docks there (in
    /// `column` of the docked cluster, its edge column unless given).
    func drop(_ payload: PanelDragPayload, onDock edge: DockEdge, at index: Int, column: Int? = nil) {
        switch payload {
        case let .panel(panel): update { $0.movePanel(panel, toNewGroupAt: edge, index: index, column: column) }
        case let .group(group): update { $0.dock(group: group, at: edge, index: index, column: column) }
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
        let rect = Self.dragRect(of: view)
        item.setDraggingFrame(rect, contents: Self.dragImage(of: view, rect: rect))
        startDragSession(view, item, event, self)
    }

    /// What a drag shows: the whole tab, or a group's title bar and tab strip.
    static func dragRect(of view: NSView) -> NSRect {
        guard let group = view as? PanelGroupView else { return view.bounds }
        let header = PanelGroupView.chromeHeight(collapsed: group.isCollapsed, tabs: group.showsTabs) - (group.isCollapsed ? 0 : PanelGroupView.margin)
        let height = min(view.bounds.height, header)
        return NSRect(x: 0, y: group.isFlipped ? 0 : view.bounds.height - height, width: view.bounds.width, height: height)
    }

    /// The drag image: a picture of `rect` of `view` on a rounded card, so the tab or group
    /// seems lifted out of its strip.
    static func dragImage(of view: NSView, rect: NSRect) -> NSImage {
        var snapshot: NSImage?
        if rect.width >= 1, rect.height >= 1, let rep = view.bitmapImageRepForCachingDisplay(in: rect) {
            view.cacheDisplay(in: rect, to: rep)
            let image = NSImage(size: rect.size)
            image.addRepresentation(rep)
            snapshot = image
        }
        return NSImage(size: NSSize(width: max(rect.width, 1), height: max(rect.height, 1)), flipped: false) { bounds in
            let radius = min(10, bounds.height / 2)
            let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            card.fill()
            snapshot?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            card.lineWidth = 1
            card.stroke()
            return true
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    /// A drag released outside every target floats what it carried there, so the image does
    /// not slide back first.
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
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


/// Renders one edge of a `PanelLayout` into the document window.  A side edge (left, right) shows
/// the cluster docked there (D-077, magnetic panels): a `PanelClusterView` flush with the window
/// edge -- square corners on that side, rounded ones and a hairline and shadow on the canvas side
/// -- running the height of the content area, translucent over the canvas, which runs beneath it.
/// Without a docked cluster the edge is empty.  A strip (top, bottom) is a row of groups.  Group
/// views are kept while their panels stay the same -- choosing a tab, collapsing or resizing
/// updates them in place, so the selection slides, the column animates and the keyboard focus
/// stays -- and panel bodies are created once and reused, so a re-render never closes a panel.
@MainActor
final class PanelDockController: NSViewController {
    static let accessibilityIdentifier = "panel-dock"
    nonisolated static let pasteboardType = PanelDragPayload.panelType
    static let defaultWidth: CGFloat = 280
    /// Between a docked cluster and the window's edges: none, it is flush (D-077, magnetic panels).
    static let inset: CGFloat = 0
    static let cornerRadius: CGFloat = PanelClusterView.dockedCornerRadius

    let panels: PanelRegistry
    let layoutController: PanelLayoutController
    let edge: DockEdge
    let interaction: PanelInteraction

    private let stack = NSStackView()
    /// The side dock's cluster (unused by a strip).
    let clusterView: PanelClusterView
    private(set) var groupViews: [PanelGroupView] = []
    private var bodies: [PanelID: NSView] = [:]
    /// Width for a side dock, height for a strip.
    private(set) var sizeConstraint: NSLayoutConstraint?
    private var observation: PanelLayoutController.ObservationToken?
    /// Reduce Transparency switched: the dock redraws solid or translucent.
    private var displayObserver: AccessibilityDisplayObserver?
    /// A column that stands in for the edge column while nothing is docked.
    private let emptyColumn: DockColumnView

    init(panels: PanelRegistry, layout: PanelLayoutController, edge: DockEdge = .right, interaction: PanelInteraction? = nil) {
        self.panels = panels
        self.layoutController = layout
        self.edge = edge
        let interaction = interaction ?? PanelInteraction(panels: panels, layout: layout)
        self.interaction = interaction
        clusterView = PanelClusterView(attachment: .docked(edge), translucent: interaction.appearance().isTranslucent)
        emptyColumn = DockColumnView(edge: edge)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelDockController is built in code")
    }

    /// The width constraint of a side dock (nil for a strip).
    var widthConstraint: NSLayoutConstraint? { edge.isVertical ? sizeConstraint : nil }

    /// The docked cluster's column at the window edge (a side dock).
    var column: DockColumnView {
        guard let cluster = layoutController.layout.dockedCluster(edge), clusterView.columnViews.indices.contains(cluster.edgeColumnIndex) else {
            return clusterView.columnViews.first ?? emptyColumn
        }
        return clusterView.columnViews[cluster.edgeColumnIndex]
    }

    /// The side dock's glass and the chrome's frost on it (nil for a strip).
    var glass: NSView? { edge.isVertical ? clusterView.chrome.glass : nil }
    var frost: PanelFrostView? { edge.isVertical ? clusterView.chrome.frost : nil }

    override func loadView() {
        let dock = DockDropView()
        dock.controller = self
        dock.translatesAutoresizingMaskIntoConstraints = false
        dock.wantsLayer = true
        // A strip is opaque (it sits between the toolbar and the canvas); a side dock is clear
        // around its cluster, so the canvas shows beside it.
        dock.layer?.backgroundColor = edge.isVertical ? nil : NSColor.windowBackgroundColor.cgColor
        dock.setAccessibilityElement(true)
        dock.setAccessibilityRole(.group)
        dock.setAccessibilityIdentifier(edge == .right ? Self.accessibilityIdentifier : "\(Self.accessibilityIdentifier).\(edge.rawValue)")
        dock.setAccessibilityLabel("Panels")

        if edge.isVertical {
            clusterView.frame = dock.bounds
            clusterView.autoresizingMask = [.width, .height]
            clusterView.preferredHeight = { [weak self] group in self?.preferredHeight(for: group) ?? PanelLayout.defaultGroupHeight }
            clusterView.onResize = { [weak self] heights in self?.resize(heights) }
            clusterView.onColumnResize = { [weak self] column, width in self?.resizeColumn(column, to: width) }
            dock.addSubview(clusterView)
        } else {
            stack.orientation = .horizontal
            stack.alignment = .top
            stack.spacing = 1
            stack.translatesAutoresizingMaskIntoConstraints = false
            dock.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: dock.topAnchor),
                stack.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: dock.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: dock.bottomAnchor),
            ])
        }
        let size = edge.isVertical ? dock.widthAnchor.constraint(equalToConstant: Self.defaultWidth) : dock.heightAnchor.constraint(equalToConstant: 0)
        size.isActive = true
        sizeConstraint = size
        view = dock
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = layoutController.observe { [weak self] layout in self?.render(layout) }
        displayObserver = AccessibilityDisplayObserver { [weak self] in self?.appearanceDidChange() }
        render(layoutController.layout)
    }

    /// Re-renders with the current appearance (a *Panels* preference changed).
    func appearanceDidChange() {
        render(layoutController.layout)
    }

    /// Brings the dock up to date with `layout`.
    func render(_ layout: PanelLayout) {
        if edge.isVertical {
            clusterView.isTranslucent = interaction.appearance().isTranslucent
            let cluster = layout.dockedCluster(edge)
            renderCluster(cluster)
            let hidden = layout.hiddenDocks.contains(edge) || cluster == nil
            view.isHidden = hidden
            sizeConstraint?.constant = hidden ? 0 : CGFloat(cluster?.width ?? 0)
        } else {
            let groups = layout.docks[edge] ?? []
            renderStrip(groups)
            let hidden = layout.hiddenDocks.contains(edge) || groups.isEmpty
            view.isHidden = hidden
            let size = layout.dockWidth[edge] ?? 44
            sizeConstraint?.constant = hidden ? 0 : CGFloat(max(size, Self.stripHeight(for: groups)))
        }
    }

    private func renderCluster(_ cluster: PanelCluster?) {
        let appearance = interaction.appearance()
        let existing = Dictionary(groupViews.map { ($0.group.id, $0) }, uniquingKeysWith: { first, _ in first })
        let columns = (cluster?.columns ?? []).map { column in
            column.groups.map { group -> PanelGroupView in
                if let view = existing[group.id], view.canShow(group, appearance: appearance) {
                    view.show(group, body: body(for:))
                    return view
                }
                let view = interaction.makeGroupView(group, floating: false, body: body(for:))
                view.dock = self
                return view
            }
        }
        let views = columns.flatMap { $0 }
        let kept = views.map(ObjectIdentifier.init) == groupViews.map(ObjectIdentifier.init)
        groupViews = views
        clusterView.show(columns: columns, widths: cluster?.columns.map(\.width) ?? [], attachment: .docked(edge), clusterID: cluster?.id)
        view.needsLayout = true
        if kept { clusterView.animateLayout() }
    }

    private func renderStrip(_ groups: [PanelGroup]) {
        for subview in stack.views { stack.removeView(subview) }
        groupViews = groups.map { interaction.makeGroupView($0, floating: false, body: body(for:)) }
        for groupView in groupViews {
            groupView.dock = self
            stack.addView(groupView, in: .top)
            groupView.widthAnchor.constraint(equalToConstant: 320).isActive = true
            groupView.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }
    }

    /// A strip is as tall as its tallest group.
    static func stripHeight(for groups: [PanelGroup]) -> Double {
        groups.map { Double(PanelGroupView.height(forContent: CGFloat($0.height ?? PanelLayout.defaultGroupHeight), collapsed: $0.collapsed, tabs: PanelGroupView.showsTabs($0))) }.max() ?? 0
    }

    /// The height a docked group asks for: its stored height, else its default group's
    /// (Properties asks for more than the others), else the framework's default.
    func preferredHeight(for group: PanelGroup) -> Double {
        if let height = group.height { return height }
        let defaults = panels.groupDefaults.first { PanelGroup.id(forName: $0.key) == group.id }?.value
        return defaults?.height ?? PanelLayout.defaultGroupHeight
    }

    /// A divider drag: the expanded groups' new heights go into the layout (and so into the
    /// saved layout file).
    func resize(_ heights: [PanelGroup.ID: Double]) {
        layoutController.update { layout in
            for (id, height) in heights { layout.setHeight(height, group: id) }
        }
    }

    /// A column divider drag: column `column` of the docked cluster becomes `width` wide.
    func resizeColumn(_ column: Int, to width: Double) {
        guard let id = layoutController.layout.dockedCluster(edge)?.id else { return }
        layoutController.update { $0.setColumnWidth(width, cluster: id, column: column) }
    }

    /// The panel's body view, created once and reused across renders.
    func body(for panel: PanelID) -> NSView {
        if let existing = bodies[panel] { return existing }
        let body = panels.descriptor(for: panel)?.makeView() ?? NSView()
        bodies[panel] = body
        return body
    }

    // MARK: Drag and drop

    /// The column and group index a drop at `point` (in the dock view) lands before: the column
    /// under the point (else the edge column) and the number of its groups whose middle is above.
    func insertionTarget(atDockPoint point: CGPoint) -> (column: Int, index: Int) {
        let columns = clusterView.columnViews
        let under = columns.firstIndex { column in
            let frame = view.convert(column.frame, from: column.superview)
            return point.x >= frame.minX && point.x < frame.maxX
        }
        let index = under ?? layoutController.layout.dockedCluster(edge)?.edgeColumnIndex ?? 0
        guard columns.indices.contains(index) else { return (0, 0) }
        let frames = columns[index].groupViews.map { view.convert($0.frame, from: columns[index]) }
        return (index, Self.insertionIndex(forY: point.y, groupFrames: frames))
    }

    /// The group index a drop at `point` (in the dock view) lands before.
    func insertionIndex(atDockPoint point: CGPoint) -> Int {
        if edge.isVertical { return insertionTarget(atDockPoint: point).index }
        return Self.tabIndex(forX: stack.convert(point, from: view).x, frames: groupViews.map(\.frame))
    }

    /// A panel or group dragged over the dock at `point`: the insertion line shows where it
    /// would land.  Nil hides it.
    func showInsertion(atDockPoint point: CGPoint?) {
        let target = point.map(insertionTarget(atDockPoint:))
        for (index, column) in clusterView.columnViews.enumerated() {
            column.insertionIndex = target?.column == index ? target?.index : nil
        }
    }

    /// A drop on the dock background: a panel splits into a new group at the drop position, a
    /// group docks there.
    func handleDrop(_ payload: PanelDragPayload, atDockPoint point: CGPoint) {
        let target = edge.isVertical ? insertionTarget(atDockPoint: point) : (column: 0, index: insertionIndex(atDockPoint: point))
        showInsertion(atDockPoint: nil)
        interaction.drop(payload, onDock: edge, at: target.index, column: edge.isVertical ? target.column : nil)
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

    // MARK: Snapping geometry

    /// The docked cluster (or, for a strip, nothing) as snapping sees it, in screen points.  A
    /// hidden dock still takes its edge, with no area to click to.
    func snapCluster() -> PanelSnapScene.Cluster? {
        guard edge.isVertical, let cluster = layoutController.layout.dockedCluster(edge) else { return nil }
        guard !view.isHidden, let geometry = clusterView.snapGeometry(id: cluster.id, edge: edge) else {
            return PanelSnapScene.Cluster(id: cluster.id, edge: edge, frame: .zero, columns: [])
        }
        return geometry
    }

    /// The strip's area in screen points (nil for a side dock or a hidden strip).
    func snapStrip() -> CGRect? {
        guard !edge.isVertical, !view.isHidden, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// The headers of the groups shown here, in screen points.
    func snapHeaders() -> [PanelSnapScene.Header] {
        guard !view.isHidden, let window = view.window else { return [] }
        return groupViews.map { PanelSnapScene.Header(group: $0.group.id, frame: window.convertToScreen($0.convert($0.headerRect, to: nil))) }
    }
}

/// The dock's background: a drop target for panels and groups dragged into it, showing the
/// insertion line while one is over it.
@MainActor
final class DockDropView: PanelEventBarrierView {
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
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard PanelDragPayload.read(from: sender.draggingPasteboard) != nil else { return [] }
        controller?.showInsertion(atDockPoint: convert(sender.draggingLocation, from: nil))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.showInsertion(atDockPoint: nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        controller?.showInsertion(atDockPoint: nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = PanelDragPayload.read(from: sender.draggingPasteboard), let controller else { return false }
        controller.handleDrop(payload, atDockPoint: convert(sender.draggingLocation, from: nil))
        return true
    }
}

/// The thin handle between the canvas and a side dock (panels.adoc, "To show or hide the whole
/// dock"): a click hides or shows the dock, a drag resizes the docked cluster's column beside the
/// canvas.  Drawn as a small grabber; absent while nothing is docked at its edge.
@MainActor
final class DockHandleView: PanelEventBarrierView {
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
        // Clear: the canvas runs beneath it (D-077, revised); only the grabber draws.
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityIdentifier("dock-handle.\(edge.rawValue)")
        setAccessibilityLabel("Show or hide the panels")
        toolTip = "Click to show or hide the panels; drag to resize"
        // An edge with no docked cluster has no handle.
        isHidden = layout.layout.dockedCluster(edge) == nil
        layout.observe { [weak self] layout in
            guard let self else { return }
            let hidden = layout.dockedCluster(self.edge) == nil
            if self.isHidden != hidden { self.isHidden = hidden }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DockHandleView is built in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        // A frosted pill under the grabber keeps it visible over any artwork.
        let pill = NSRect(x: (bounds.width - 5) / 2, y: (bounds.height - 36) / 2, width: 5, height: 36)
        PanelFrost.chrome.color(translucent: true).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 2.5, yRadius: 2.5).fill()
        let grabber = NSRect(x: (bounds.width - 3) / 2, y: (bounds.height - 32) / 2, width: 3, height: 32)
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(roundedRect: grabber, xRadius: 1.5, yRadius: 1.5).fill()
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
        let layout = layoutController.layout
        let startWidth = layout.dockedCluster(edge).map { $0.columns[$0.innerColumnIndex].width } ?? layout.dockWidth[edge] ?? Double(PanelDockController.defaultWidth)
        var dx: CGFloat = 0
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            dx = next.locationInWindow.x - start
            if next.type == .leftMouseUp { break }
            drag(startWidth: startWidth, by: dx)
        }
        finish(totalDelta: dx)
    }
}
