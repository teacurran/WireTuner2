import AppKit

/// How docked groups share a side dock's height (D-077; panels.adoc, "To resize a floating
/// group"): every expanded group gets a part of the height left after the title bars, in
/// proportion to its stored height, never less than a minimum while the dock has room; a
/// divider drag moves height between the expanded groups on either side of it.  Pure, so the
/// rules are tested without views.
enum DockSizing {
    /// The smallest body an expanded group is given while the dock has room for it.
    static let minimumContentHeight: Double = 48

    /// The content heights of groups with `preferred` heights sharing `available` points.
    static func share(_ available: Double, preferred: [Double], minimum: Double = minimumContentHeight) -> [Double] {
        guard !preferred.isEmpty else { return [] }
        let available = max(0, available)
        let count = Double(preferred.count)
        if available <= minimum * count { return preferred.map { _ in available / count } }
        let weights = preferred.map { max($0, 1) }
        var pinned = Set<Int>()
        while true {
            let free = weights.indices.filter { !pinned.contains($0) }
            let remaining = available - minimum * Double(pinned.count)
            let total = free.reduce(0) { $0 + weights[$1] }
            let result = weights.indices.map { pinned.contains($0) ? minimum : remaining * weights[$0] / total }
            let short = free.filter { result[$0] < minimum }
            if short.isEmpty { return result }
            pinned.formUnion(short)
        }
    }

    /// The content heights after dragging divider `divider` (between group `divider` and the
    /// next) by `delta` points downwards, from `heights` (the heights on screen when the drag
    /// began; entries of collapsed groups are ignored).  The nearest expanded group above the
    /// divider grows by what the nearest expanded group below it gives up, both kept at least
    /// `minimum`.  Nil when there is no expanded group on one side or no room to move.
    static func drag(_ heights: [Double], expanded: [Bool], divider: Int, by delta: Double, minimum: Double = minimumContentHeight) -> [Double]? {
        guard heights.count == expanded.count, divider >= 0, divider + 1 < heights.count,
            let above = (0...divider).last(where: { expanded[$0] }),
            let below = ((divider + 1)..<heights.count).first(where: { expanded[$0] })
        else { return nil }
        let total = heights[above] + heights[below]
        guard total >= 2 * minimum else { return nil }
        var result = heights
        result[above] = min(max(heights[above] + delta, minimum), total - minimum)
        result[below] = total - result[above]
        return result
    }
}

/// A side dock's column of groups: each group at the height `DockSizing` gives it, a divider
/// between neighbours, and the insertion line a group dragged over the dock shows.  Lays its
/// subviews out by hand (flipped, top first): a group's frame is its title bar, tab strip and
/// its share of the body height, so nothing draws over the next group's title.
@MainActor
final class DockColumnView: NSView {
    static let dividerThickness: CGFloat = 7
    static let insertionThickness: CGFloat = 2

    let edge: DockEdge
    private(set) var groupViews: [PanelGroupView] = []
    private(set) var dividers: [DockDividerView] = []
    /// The content height each group had at the last layout (0 for a collapsed group).
    private(set) var contentHeights: [Double] = []
    /// The stored height of a group, or its default (Properties gets more).
    var preferredHeight: @MainActor (PanelGroup) -> Double = { $0.height ?? PanelLayout.defaultGroupHeight }
    /// A divider drag resized the expanded groups: their new content heights by group id.
    var onResize: @MainActor ([PanelGroup.ID: Double]) -> Void = { _ in }
    private var dragStart: [Double]?
    private(set) var insertionLine = NSView()

    /// Where a group dragged over the dock would land (before group `insertionIndex`); nil hides
    /// the line.
    var insertionIndex: Int? {
        didSet {
            guard insertionIndex != oldValue else { return }
            needsLayout = true
        }
    }

    init(edge: DockEdge) {
        self.edge = edge
        super.init(frame: .zero)
        insertionLine.wantsLayer = true
        insertionLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionLine.layer?.cornerRadius = Self.insertionThickness / 2
        insertionLine.isHidden = true
        insertionLine.setAccessibilityElement(false)
        addSubview(insertionLine)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DockColumnView is built in code")
    }

    override var isFlipped: Bool { true }

    /// Shows `views` top first, with a divider between each pair.
    func setGroupViews(_ views: [PanelGroupView]) {
        for view in groupViews where !views.contains(where: { $0 === view }) { view.removeFromSuperview() }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = true
            if view.superview !== self { addSubview(view, positioned: .below, relativeTo: insertionLine) }
        }
        groupViews = views
        let needed = max(0, views.count - 1)
        while dividers.count > needed { dividers.removeLast().removeFromSuperview() }
        while dividers.count < needed {
            let divider = DockDividerView(index: dividers.count, edge: edge)
            divider.column = self
            addSubview(divider, positioned: .below, relativeTo: insertionLine)
            dividers.append(divider)
        }
        needsLayout = true
    }

    // MARK: Layout

    /// Each group's frame and each divider's, for a column `height` points tall.
    func frames(forHeight height: CGFloat, width: CGFloat) -> (groups: [CGRect], dividers: [CGRect], content: [Double]) {
        let groups = groupViews.map(\.group)
        let fixed = groups.reduce(0.0) { $0 + Double(PanelGroupView.chromeHeight(of: $1)) }
            + Double(Self.dividerThickness) * Double(max(0, groups.count - 1))
        let expanded = groups.indices.filter { !groups[$0].collapsed }
        let shares = DockSizing.share(Double(height) - fixed, preferred: expanded.map { preferredHeight(groups[$0]) })
        var content = [Double](repeating: 0, count: groups.count)
        for (index, share) in zip(expanded, shares) { content[index] = share }
        var y: CGFloat = 0
        var groupFrames: [CGRect] = []
        var dividerFrames: [CGRect] = []
        for (index, group) in groups.enumerated() {
            let h = PanelGroupView.height(forContent: CGFloat(content[index]), collapsed: group.collapsed, tabs: PanelGroupView.showsTabs(group))
            groupFrames.append(CGRect(x: 0, y: y, width: width, height: h))
            y += h
            if index < groups.count - 1 {
                dividerFrames.append(CGRect(x: 0, y: y, width: width, height: Self.dividerThickness))
                y += Self.dividerThickness
            }
        }
        return (groupFrames, dividerFrames, content)
    }

    override func layout() {
        super.layout()
        applyFrames(animated: false)
    }

    /// Lays the column out again, sliding groups to their places (a group collapsed, expanded
    /// or resized) unless nothing is on screen or Reduce Motion is on.
    func animateLayout() {
        PanelGlass.animate(in: self) { self.applyFrames(animated: true) }
    }

    private func applyFrames(animated: Bool) {
        let frames = frames(forHeight: bounds.height, width: bounds.width)
        contentHeights = frames.content
        for (view, frame) in zip(groupViews, frames.groups) { (animated ? view.animator() : view).frame = frame }
        for (divider, frame) in zip(dividers, frames.dividers) {
            divider.frame = frame
            divider.isResizable = DockSizing.drag(frames.content, expanded: groupViews.map { !$0.group.collapsed }, divider: divider.index, by: 0) != nil
        }
        if let insertionIndex {
            let y: CGFloat
            if insertionIndex < frames.groups.count {
                y = frames.groups[insertionIndex].minY - (insertionIndex == 0 ? 0 : Self.dividerThickness / 2)
            } else {
                y = frames.groups.last?.maxY ?? 0
            }
            insertionLine.frame = CGRect(x: 8, y: max(0, min(bounds.height - Self.insertionThickness, y - Self.insertionThickness / 2)),
                                         width: max(0, bounds.width - 16), height: Self.insertionThickness)
            insertionLine.isHidden = false
        } else {
            insertionLine.isHidden = true
        }
    }

    // MARK: Dividers

    func beginDividerDrag() {
        dragStart = contentHeights
    }

    /// Moves divider `index` by `delta` points downwards from where the drag began.
    func dragDivider(_ index: Int, by delta: CGFloat) {
        let start = dragStart ?? contentHeights
        let expanded = groupViews.map { !$0.group.collapsed }
        guard let heights = DockSizing.drag(start, expanded: expanded, divider: index, by: Double(delta)) else { return }
        var resized: [PanelGroup.ID: Double] = [:]
        for (view, (height, isExpanded)) in zip(groupViews, zip(heights, expanded)) where isExpanded {
            resized[view.group.id] = height.rounded()
        }
        onResize(resized)
    }

    func endDividerDrag() {
        dragStart = nil
    }
}

/// The divider between two docked groups: drag it to change how they share the dock's height.
/// A splitter to accessibility, whose increment and decrement move it by 16 points.
@MainActor
final class DockDividerView: NSView {
    static let step: CGFloat = 16

    let index: Int
    weak var column: DockColumnView?
    /// False when no expanded group is on one side of it (it draws as a gap only).
    var isResizable = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    init(index: Int, edge: DockEdge) {
        self.index = index
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityIdentifier("panel-divider.\(edge.rawValue).\(index)")
        setAccessibilityLabel("Resize panel groups")
        setAccessibilityOrientation(.horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DockDividerView is built in code")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 10, y: (bounds.height - 1) / 2, width: max(0, bounds.width - 20), height: 1).fill()
    }

    override func resetCursorRects() {
        if isResizable { addCursorRect(bounds, cursor: .resizeUpDown) }
    }

    /// Moves the divider `delta` points down (a drag, or accessibility's increment).
    func move(by delta: CGFloat) {
        column?.beginDividerDrag()
        column?.dragDivider(index, by: delta)
        column?.endDividerDrag()
    }

    override func accessibilityPerformIncrement() -> Bool {
        move(by: Self.step)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        move(by: -Self.step)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, isResizable, let column else { return }
        let start = event.locationInWindow.y
        column.beginDividerDrag()
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            // Window coordinates point up; the column is flipped.
            column.dragDivider(index, by: start - next.locationInWindow.y)
            if next.type == .leftMouseUp { break }
        }
        column.endDividerDrag()
    }
}
