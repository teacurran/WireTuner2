import AppKit

/// One cluster on screen (D-077, magnetic panels): its columns of groups side by side on one
/// glass surface with the chrome's frost, thin dividers between columns (drag to resize the
/// column on the left) and between the groups of a column (`DockColumnView`).
///
/// Docked, it reads as attached to the window: flush with the edge, square corners on that side
/// and rounded corners on the canvas side, a hairline along the canvas side and a soft shadow over
/// the canvas.  Floating, it is rounded all round and its window casts the shadow.  Both stay
/// translucent (the *Panel transparency* preference and Reduce Transparency make them solid).
@MainActor
final class PanelClusterView: PanelEventBarrierView {
    enum Attachment: Equatable, Sendable {
        case docked(DockEdge)
        case floating

        var edge: DockEdge? {
            if case let .docked(edge) = self { return edge }
            return nil
        }
    }

    static let dockedCornerRadius: CGFloat = 12
    static let floatingCornerRadius: CGFloat = 14
    /// Above the first title bar and below the last group.
    static let verticalInset: CGFloat = 4

    private(set) var attachment: Attachment
    private(set) var clusterID: PanelCluster.ID?
    let chrome: PanelClusterChrome
    private(set) var columnViews: [DockColumnView] = []
    private(set) var columnDividers: [ClusterColumnDivider] = []
    /// The columns' widths as the layout has them.
    private(set) var widths: [CGFloat] = []
    /// Holds the columns and dividers over the chrome.
    private let content = ClusterContentView()
    /// The stored height of a group, or its default (Properties gets more).
    var preferredHeight: @MainActor (PanelGroup) -> Double = { $0.height ?? PanelLayout.defaultGroupHeight } {
        didSet { for column in columnViews { column.preferredHeight = preferredHeight } }
    }
    /// A group divider drag resized the expanded groups of a column: their content heights by id.
    var onResize: @MainActor ([PanelGroup.ID: Double]) -> Void = { _ in }
    /// A column divider drag: column `index`'s new width.
    var onColumnResize: @MainActor (Int, Double) -> Void = { _, _ in }

    init(attachment: Attachment, translucent: Bool) {
        self.attachment = attachment
        chrome = PanelClusterChrome(attachment: attachment, translucent: translucent)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        chrome.autoresizingMask = [.width, .height]
        chrome.frame = bounds
        addSubview(chrome)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelClusterView is built in code")
    }

    override var isFlipped: Bool { true }

    /// Every group view, column by column.
    var groupViews: [PanelGroupView] { columnViews.flatMap(\.groupViews) }

    var isTranslucent: Bool {
        get { chrome.isTranslucent }
        set { chrome.isTranslucent = newValue }
    }

    /// Shows `columns` (group views, top first) at `widths`, attached as `attachment`.
    func show(columns: [[PanelGroupView]], widths: [Double], attachment: Attachment, clusterID: PanelCluster.ID?) {
        self.clusterID = clusterID
        if attachment != self.attachment {
            self.attachment = attachment
            chrome.attachment = attachment
        }
        let prefix = Self.dividerPrefix(attachment: attachment, clusterID: clusterID)
        while columnViews.count > columns.count { columnViews.removeLast().removeFromSuperview() }
        while columnViews.count < columns.count {
            let column = DockColumnView(edge: attachment.edge ?? .right, identifierPrefix: prefix(columnViews.count))
            column.preferredHeight = preferredHeight
            column.onResize = { [weak self] heights in self?.onResize(heights) }
            content.addSubview(column)
            columnViews.append(column)
        }
        for (column, views) in zip(columnViews, columns) {
            column.identifierPrefix = prefix(columnViews.firstIndex(of: column) ?? 0)
            column.setGroupViews(views)
        }
        let needed = max(0, columns.count - 1)
        while columnDividers.count > needed { columnDividers.removeLast().removeFromSuperview() }
        while columnDividers.count < needed {
            let divider = ClusterColumnDivider(index: columnDividers.count)
            divider.cluster = self
            content.addSubview(divider)
            columnDividers.append(divider)
        }
        for divider in columnDividers { divider.setAccessibilityIdentifier("panel-column-divider.\(clusterID ?? "cluster").\(divider.index)") }
        self.widths = widths.map { CGFloat($0) }
        updateAccessibility()
        needsLayout = true
    }

    /// The accessibility identifiers of a column's group dividers: a docked cluster's edge column
    /// keeps the dock's (`panel-divider.<edge>.<n>`).
    private static func dividerPrefix(attachment: Attachment, clusterID: PanelCluster.ID?) -> (Int) -> String {
        { column in
            switch attachment {
            case let .docked(edge): column == 0 ? "panel-divider.\(edge.rawValue)" : "panel-divider.\(edge.rawValue).column\(column)"
            case .floating: "panel-divider.\(clusterID ?? "floating").column\(column)"
            }
        }
    }

    private func updateAccessibility() {
        switch attachment {
        case let .docked(edge): setAccessibilityLabel("Panels, docked at the \(edge.rawValue) edge")
        case .floating: setAccessibilityLabel("Floating panels")
        }
        setAccessibilityIdentifier("panel-cluster.\(clusterID ?? "none")")
    }

    // MARK: Layout

    /// The columns' frames and the dividers' in a cluster `size` big: the stored widths, the
    /// difference going to the column beside the canvas (docked) or the last one (floating).
    func frames(for size: CGSize) -> (columns: [CGRect], dividers: [CGRect]) {
        guard !widths.isEmpty else { return ([], []) }
        let gap = CGFloat(PanelCluster.columnDividerWidth)
        var fitted = widths
        let total = fitted.reduce(0, +) + gap * CGFloat(fitted.count - 1)
        let absorbing = attachment.edge == .right ? 0 : fitted.count - 1
        fitted[absorbing] = max(0, fitted[absorbing] + size.width - total)
        var x: CGFloat = 0
        var columns: [CGRect] = []
        var dividers: [CGRect] = []
        let height = max(0, size.height - 2 * Self.verticalInset)
        for (index, width) in fitted.enumerated() {
            columns.append(CGRect(x: x, y: Self.verticalInset, width: width, height: height))
            x += width
            if index < fitted.count - 1 {
                dividers.append(CGRect(x: x, y: Self.verticalInset, width: gap, height: height))
                x += gap
            }
        }
        return (columns, dividers)
    }

    override func layout() {
        super.layout()
        let frames = frames(for: bounds.size)
        for (column, frame) in zip(columnViews, frames.columns) { column.frame = frame }
        for (divider, frame) in zip(columnDividers, frames.dividers) { divider.frame = frame }
    }

    /// Lays the columns out again, sliding groups to their places.
    func animateLayout() {
        for column in columnViews { column.animateLayout() }
    }

    /// The height the cluster needs when every group of a column is collapsed (a floating
    /// cluster shrinks to it); nil when some column has an expanded group.
    static func collapsedHeight(of cluster: PanelCluster) -> CGFloat? {
        var tallest: CGFloat = 0
        for column in cluster.columns {
            guard column.groups.allSatisfy(\.collapsed) else { return nil }
            let titles = CGFloat(column.groups.count) * PanelGroupView.titleHeight
            let dividers = CGFloat(max(0, column.groups.count - 1)) * DockColumnView.dividerThickness
            tallest = max(tallest, titles + dividers)
        }
        return tallest + 2 * verticalInset
    }

    // MARK: Geometry for snapping

    /// This cluster's frame, columns and groups in screen points.
    func snapGeometry(id: PanelCluster.ID, edge: DockEdge?) -> PanelSnapScene.Cluster? {
        guard let window else { return nil }
        func screen(_ rect: NSRect, in view: NSView) -> CGRect { window.convertToScreen(view.convert(rect, to: nil)) }
        let columns = columnViews.map { column in
            PanelSnapScene.Column(frame: screen(column.bounds, in: column), groupFrames: column.groupViews.map { screen($0.bounds, in: $0) })
        }
        return PanelSnapScene.Cluster(id: id, edge: edge, frame: screen(bounds, in: self), columns: columns)
    }

    /// Every group's header (title bar and tab strip) in screen points.
    func snapHeaders() -> [PanelSnapScene.Header] {
        guard let window else { return [] }
        return groupViews.map { view in
            PanelSnapScene.Header(group: view.group.id, frame: window.convertToScreen(view.convert(view.headerRect, to: nil)))
        }
    }

    // MARK: Column dividers

    private var columnDragStart: CGFloat?

    func beginColumnDrag() { columnDragStart = nil }

    /// Moves column divider `index` by `delta` points to the right from where the drag began.
    func dragColumnDivider(_ index: Int, by delta: CGFloat) {
        guard columnViews.indices.contains(index) else { return }
        let start = columnDragStart ?? columnViews[index].frame.width
        columnDragStart = start
        onColumnResize(index, Double(max(CGFloat(PanelCluster.minimumColumnWidth), start + delta)).rounded())
    }

    func endColumnDrag() { columnDragStart = nil }
}

/// Holds a cluster's columns (flipped, so they lay out top first).
@MainActor
final class ClusterContentView: NSView {
    override var isFlipped: Bool { true }
}

/// The surface of a cluster: the glass, the chrome's frost over it, and -- docked -- a hairline
/// along the canvas side and a shadow cast on the canvas.  Docked, the glass extends past the
/// window edge by its corner radius and is clipped there, so the attached side has square
/// corners (the system glass rounds every corner alike).
@MainActor
final class PanelClusterChrome: NSView {
    var attachment: PanelClusterView.Attachment {
        didSet {
            guard attachment != oldValue else { return }
            applyAttachment()
        }
    }
    var isTranslucent: Bool {
        get { frost.isTranslucent }
        set { frost.isTranslucent = newValue }
    }
    /// Clips the glass at the attached edge.
    let clip = NSView()
    private(set) var glass: NSView
    let frost: PanelFrostView

    init(attachment: PanelClusterView.Attachment, translucent: Bool) {
        self.attachment = attachment
        glass = PanelGlass.surface(cornerRadius: PanelClusterView.floatingCornerRadius)
        frost = PanelFrostView(level: .chrome, translucent: translucent, cornerRadius: PanelClusterView.floatingCornerRadius)
        super.init(frame: .zero)
        setAccessibilityElement(false)
        wantsLayer = true
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.setAccessibilityElement(false)
        glass.setAccessibilityElement(false)
        clip.addSubview(glass)
        addSubview(clip)
        addSubview(frost)
        applyAttachment()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelClusterChrome is built in code")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The corner radius for the attachment.
    var cornerRadius: CGFloat {
        attachment.edge == nil ? PanelClusterView.floatingCornerRadius : PanelClusterView.dockedCornerRadius
    }

    private func applyAttachment() {
        let radius = cornerRadius
        if #available(macOS 26, *), let glass = glass as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            glass.layer?.cornerRadius = radius
        }
        frost.cornerRadius = radius
        frost.squareEdge = attachment.edge
        frost.strokesOutline = true
        // Docked, a soft shadow falls on the canvas; floating, the window casts it.
        if attachment.edge == nil {
            shadow = nil
        } else {
            let soft = NSShadow()
            soft.shadowColor = NSColor.black.withAlphaComponent(0.22)
            soft.shadowBlurRadius = 8
            soft.shadowOffset = .zero
            shadow = soft
        }
        needsLayout = true
    }

    /// The glass's frame: the bounds, extended past the attached edge by the corner radius.
    func glassFrame(in bounds: CGRect) -> CGRect {
        let radius = cornerRadius
        switch attachment.edge {
        case .right?: return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width + radius, height: bounds.height)
        case .left?: return CGRect(x: bounds.minX - radius, y: bounds.minY, width: bounds.width + radius, height: bounds.height)
        default: return bounds
        }
    }

    override func layout() {
        super.layout()
        clip.frame = bounds
        glass.frame = glassFrame(in: bounds)
        frost.frame = bounds
        layer?.shadowPath = attachment.edge == nil ? nil : PanelShape.path(in: bounds, radius: cornerRadius, squareEdge: attachment.edge).cgPath
    }
}

/// Rounded rectangles with square corners on one side (a docked cluster's attached edge).
@MainActor
enum PanelShape {
    /// `rect` with `radius` corners, square on `squareEdge`'s side.  Works in flipped and
    /// unflipped views alike (the corners are symmetric top and bottom).
    static func path(in rect: CGRect, radius: CGFloat, squareEdge: DockEdge?) -> NSBezierPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        let leftRadius: CGFloat = squareEdge == .left ? 0 : r
        let rightRadius: CGFloat = squareEdge == .right ? 0 : r
        let topRadius = squareEdge == .top ? 0 : nil as CGFloat?
        let bottomRadius = squareEdge == .bottom ? 0 : nil as CGFloat?
        let minYLeft = bottomRadius ?? leftRadius, minYRight = bottomRadius ?? rightRadius
        let maxYLeft = topRadius ?? leftRadius, maxYRight = topRadius ?? rightRadius
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + minYLeft, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - minYRight, y: rect.minY))
        if minYRight > 0 { path.appendArc(withCenter: CGPoint(x: rect.maxX - minYRight, y: rect.minY + minYRight), radius: minYRight, startAngle: 270, endAngle: 360) }
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - maxYRight))
        if maxYRight > 0 { path.appendArc(withCenter: CGPoint(x: rect.maxX - maxYRight, y: rect.maxY - maxYRight), radius: maxYRight, startAngle: 0, endAngle: 90) }
        path.line(to: CGPoint(x: rect.minX + maxYLeft, y: rect.maxY))
        if maxYLeft > 0 { path.appendArc(withCenter: CGPoint(x: rect.minX + maxYLeft, y: rect.maxY - maxYLeft), radius: maxYLeft, startAngle: 90, endAngle: 180) }
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + minYLeft))
        if minYLeft > 0 { path.appendArc(withCenter: CGPoint(x: rect.minX + minYLeft, y: rect.minY + minYLeft), radius: minYLeft, startAngle: 180, endAngle: 270) }
        path.close()
        return path
    }

    /// The outline without the attached side (the hairline a docked cluster draws along the canvas).
    static func outline(in rect: CGRect, radius: CGFloat, squareEdge: DockEdge?) -> NSBezierPath {
        guard let squareEdge, squareEdge.isVertical else { return path(in: rect, radius: radius, squareEdge: squareEdge) }
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        let path = NSBezierPath()
        if squareEdge == .right {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.line(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.appendArc(withCenter: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: 270, endAngle: 180, clockwise: true)
            path.line(to: CGPoint(x: rect.minX, y: rect.maxY - r))
            path.appendArc(withCenter: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: 180, endAngle: 90, clockwise: true)
            path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.line(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.appendArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: 270, endAngle: 360)
            path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.appendArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: 0, endAngle: 90)
            path.line(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        return path
    }
}

/// The divider between two columns of a cluster: a hairline; drag it to resize the column on its
/// left.  A splitter to accessibility, whose increment and decrement move it by 16 points.
@MainActor
final class ClusterColumnDivider: NSView {
    static let step: CGFloat = 16

    let index: Int
    weak var cluster: PanelClusterView?

    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize panel columns")
        setAccessibilityOrientation(.vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClusterColumnDivider is built in code")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: (bounds.width - 1) / 2, y: 10, width: 1, height: max(0, bounds.height - 20)).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    func move(by delta: CGFloat) {
        cluster?.beginColumnDrag()
        cluster?.dragColumnDivider(index, by: delta)
        cluster?.endColumnDrag()
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
        guard let window, let cluster else { return }
        let start = event.locationInWindow.x
        cluster.beginColumnDrag()
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            cluster.dragColumnDivider(index, by: next.locationInWindow.x - start)
            if next.type == .leftMouseUp { break }
        }
        cluster.endColumnDrag()
    }
}
