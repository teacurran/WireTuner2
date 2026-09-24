import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The Page tool (pages.adoc, "Selecting pages", "Duplicating, removing and moving pages" and
/// "Modifying, resizing and rotating pages"; DOC-007).  A click selects a page (kbd:[Shift] adds
/// or removes it); a drag on empty pasteboard selects the pages the marquee touches.  Dragging a
/// selected page moves the selection with its objects -- kbd:[Cmd], sampled on every event, moves
/// the frames alone -- snapping to the grid and to guides, kbd:[Shift] constraining to horizontal
/// or vertical; kbd:[Option]-drag duplicates the page where it is released.  The eight handles of
/// a selected page resize it (kbd:[Shift] keeps the proportions, kbd:[Option] resizes about the
/// centre); just outside them the page rotates, snapping between portrait and landscape at 45°.
/// A child of a master shows dimmed handles and refuses both.  kbd:[Delete] removes the selected
/// pages (asking first when they hold objects); kbd:[Option]-double-click opens *Modify Page*.
/// Every gesture is one change and one undo step.
@MainActor
final class PageTool: Tool {
    static let id: ToolID = "page"
    /// Handle size and how near one a press takes it, view points (the standard handle size).
    static let handleSize = 8.0
    /// The rotate zone: this far outside a corner handle, view points.
    static let rotateZone = 12.0
    /// A drag shorter than this (view points) is a click.
    static let dragThreshold = 3.0
    static let statusMessage = "Click a page to select it; drag to move it with its objects (Cmd: the page alone, Option: a copy); drag a handle to resize"
    static let childMessage = "This page follows a master page: change the master instead"
    static let lastPageMessage = "A document keeps at least one page"

    static var descriptor: ToolDescriptor {
        ToolCatalog.all.first { $0.id == id }!.delivering { PageTool() }
    }

    /// What the press in progress does.
    enum Gesture: Equatable {
        case move(pages: [OpID])
        case resize(page: OpID, handle: HandleAnchor)
        case rotate(page: OpID)
        case marquee
    }

    private var context: ToolContext?
    private(set) var gesture: Gesture?
    private(set) var start: CanvasEvent?
    private(set) var current: CanvasEvent?

    init() {}

    var cursor: NSCursor { .arrow }
    var hasSomethingToCancel: Bool { gesture != nil }

    var isDragging: Bool {
        guard let start, let current else { return false }
        return start.viewPoint.distance(to: current.viewPoint) >= Self.dragThreshold
    }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
        context.host.setNeedsOverlayDisplay()
    }

    func deactivate() {
        cancel()
        context?.host.setNeedsOverlayDisplay()
        context = nil
    }

    // MARK: Hit testing

    /// The handle of a selected page within reach of `viewPoint`.
    func handle(at viewPoint: Point, viewport: Viewport, document: DocumentHandle) -> (page: Page, anchor: HandleAnchor)? {
        for page in document.selectedPages {
            for anchor in HandleAnchor.allCases {
                let point = viewport.toView(Self.point(anchor, of: page.rect))
                if abs(point.x - viewPoint.x) <= Self.handleSize / 2 + 1, abs(point.y - viewPoint.y) <= Self.handleSize / 2 + 1 { return (page, anchor) }
            }
        }
        return nil
    }

    /// A selected page whose rotate zone (just outside a corner handle) holds `viewPoint`.
    func rotateZone(at viewPoint: Point, viewport: Viewport, document: DocumentHandle) -> Page? {
        let corners: [HandleAnchor] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        return document.selectedPages.first { page in
            let point = viewport.toPasteboard(viewPoint)
            guard !page.rect.contains(point) else { return false }
            return corners.contains { viewport.toView(Self.point($0, of: page.rect)).distance(to: viewPoint) <= Self.handleSize / 2 + Self.rotateZone }
        }
    }

    /// Where handle `anchor` sits on `rect` (pasteboard).
    static func point(_ anchor: HandleAnchor, of rect: Rect) -> Point {
        let x = anchor.column == 0 ? rect.minX : anchor.column == 1 ? rect.midX : rect.maxX
        let y = anchor.row == 0 ? rect.minY : anchor.row == 1 ? rect.midY : rect.maxY
        return Point(x: x, y: y)
    }

    // MARK: Events

    func mouseDown(_ e: CanvasEvent) {
        guard let context else { return }
        let document = context.document
        start = e
        current = e
        if let (page, anchor) = handle(at: e.viewPoint, viewport: context.viewport, document: document) {
            gesture = page.isChild ? nil : .resize(page: page.id, handle: anchor)
            if page.isChild { context.host.showStatusMessage(Self.childMessage) }
            return
        }
        if let page = rotateZone(at: e.viewPoint, viewport: context.viewport, document: document) {
            gesture = page.isChild ? nil : .rotate(page: page.id)
            if page.isChild { context.host.showStatusMessage(Self.childMessage) }
            return
        }
        guard let page = document.pageList.page(containing: e.pasteboardPoint) else {
            if !e.modifiers.contains(.shift) { document.selectPages([]) }
            gesture = .marquee
            return
        }
        if e.clickCount >= 2, e.modifiers.contains(.option) {
            gesture = nil
            context.modifyPage?(page.id)
            return
        }
        var selected = document.selectedPageIDs
        if e.modifiers.contains(.shift) {
            if let index = selected.firstIndex(of: page.id) { selected.remove(at: index) } else { selected.append(page.id) }
        } else if !selected.contains(page.id) {
            selected = [page.id]
        }
        document.selectPages(selected)
        gesture = selected.contains(page.id) ? .move(pages: e.modifiers.contains(.option) ? [page.id] : selected) : nil
        context.host.setNeedsOverlayDisplay()
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard gesture != nil else { return }
        current = e
        context?.host.setNeedsOverlayDisplay()
    }

    func flagsChanged(_ e: CanvasEvent) {
        guard gesture != nil, let current else { return }
        self.current = current.with(modifiers: e.modifiers)
        context?.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        guard let context, let gesture else { return reset() }
        current = e
        let document = context.document
        defer { reset() }
        switch gesture {
        case .marquee:
            guard isDragging, let start else { return }
            let rect = Rect(start.pasteboardPoint, e.pasteboardPoint)
            let hit = document.pageList.pages(intersecting: rect).map(\.id)
            document.selectPages(e.modifiers.contains(.shift) ? document.selectedPageIDs + hit.filter { !document.selectedPageIDs.contains($0) } : hit)
        case .move(let pages):
            guard isDragging, let delta = moveDelta(pages: pages, document: document), delta != .zero else { return }
            if e.modifiers.contains(.option), let page = pages.first {
                duplicate(page, by: delta, in: context)
            } else {
                let moves = pages.map { MovePage($0, by: delta, withContents: !e.modifiers.contains(.command)) }
                context.commandSink.perform(moves.count == 1 ? moves[0] : CommandBatch("Move \(moves.count) pages", moves))
            }
        case .resize(let id, let anchor):
            guard isDragging, let page = document.pageList[id], let rect = resizedRect(page, anchor: anchor, to: e) else { return }
            context.commandSink.perform(Self.resizeCommand(page, to: rect))
        case .rotate(let id):
            guard isDragging, let start, let page = document.pageList[id], Self.rotates(page.rect.center, from: start.pasteboardPoint, to: e.pasteboardPoint) else { return }
            context.commandSink.perform(RotatePages([id]))
        }
    }

    func keyDown(_ e: NSEvent) -> Bool {
        guard let context, e.keyCode == 51 || e.keyCode == 117 else { return false }
        removeSelected(in: context)
        return true
    }

    /// kbd:[Delete]: removes the selected pages, asking first when objects go with them; the only
    /// page is kept.
    func removeSelected(in context: ToolContext) {
        let document = context.document
        let pages = document.selectedPages
        guard pages.count < document.pageList.pages.count else {
            context.host.showStatusMessage(Self.lastPageMessage)
            return
        }
        let state = document.state
        let objects = pages.reduce(0) { $0 + PageObjects.objects(on: $1, in: state, pages: document.pageList).count }
        if objects > 0 {
            let noun = pages.count == 1 ? "page" : "\(pages.count) pages"
            let things = objects == 1 ? "the object" : "the \(objects) objects"
            guard context.confirm("Remove the \(noun) and \(things) on \(pages.count == 1 ? "it" : "them")?",
                                  "Objects that also reach onto another page or the pasteboard are kept.") else { return }
        }
        context.commandSink.perform(RemovePages(pages.map(\.id), in: state))
    }

    func cancel() {
        reset()
        context?.host.setNeedsOverlayDisplay()
    }

    private func reset() {
        gesture = nil
        start = nil
        current = nil
    }

    // MARK: Geometry

    /// How far the dragged pages move: kbd:[Shift] keeps it horizontal or vertical; otherwise the
    /// first page's top-left corner snaps (grid, guides).
    func moveDelta(pages: [OpID], document: DocumentHandle) -> Vector? {
        guard let start, let current, let context, let first = pages.first.flatMap({ document.pageList[$0] }) else { return nil }
        let raw = current.pasteboardPoint - start.pasteboardPoint
        if current.modifiers.contains(.shift) {
            return abs(raw.dx) >= abs(raw.dy) ? Vector(dx: raw.dx, dy: 0) : Vector(dx: 0, dy: raw.dy)
        }
        let delta = context.snapping.snapDrag(of: first.origin, by: raw, viewport: context.viewport)
        // Pages stay on the pasteboard.
        let moved = Pasteboard.clamp(first.rect.offset(by: delta))
        return Vector(dx: moved.minX - first.rect.minX, dy: moved.minY - first.rect.minY)
    }

    /// The page rectangle a handle drag to `e` makes: the opposite edge fixed (kbd:[Option]: the
    /// centre), kbd:[Shift] keeping the proportions, snapped edges; nil for a degenerate page.
    func resizedRect(_ page: Page, anchor: HandleAnchor, to e: CanvasEvent) -> Rect? {
        guard let context else { return nil }
        let point = e.modifiers.contains(.control) ? e.pasteboardPoint : context.snapping.snap(e.pasteboardPoint, viewport: context.viewport)
        return Self.resize(page.rect, anchor: anchor, to: point, proportional: e.modifiers.contains(.shift), fromCenter: e.modifiers.contains(.option))
    }

    /// `rect` with handle `anchor` dragged to `point`.
    static func resize(_ rect: Rect, anchor: HandleAnchor, to point: Point, proportional: Bool, fromCenter: Bool) -> Rect? {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let center = rect.center
        if anchor.column == 0 { minX = point.x; if fromCenter { maxX = 2 * center.x - point.x } }
        if anchor.column == 2 { maxX = point.x; if fromCenter { minX = 2 * center.x - point.x } }
        if anchor.row == 0 { minY = point.y; if fromCenter { maxY = 2 * center.y - point.y } }
        if anchor.row == 2 { maxY = point.y; if fromCenter { minY = 2 * center.y - point.y } }
        var result = Rect(Point(x: minX, y: minY), Point(x: maxX, y: maxY))
        if proportional, rect.width > 0, rect.height > 0 {
            let scale = anchor.column == 1 ? result.height / rect.height : anchor.row == 1 ? result.width / rect.width
                : max(result.width / rect.width, result.height / rect.height)
            let size = Size(width: rect.width * scale, height: rect.height * scale)
            let fixed = fromCenter ? center : Self.point(anchor.opposite, of: rect)
            let x = fromCenter ? fixed.x - size.width / 2 : (anchor.column == 0 ? fixed.x - size.width : anchor.column == 2 ? fixed.x : center.x - size.width / 2)
            let y = fromCenter ? fixed.y - size.height / 2 : (anchor.row == 0 ? fixed.y - size.height : anchor.row == 2 ? fixed.y : center.y - size.height / 2)
            result = Rect(x: x, y: y, width: size.width, height: size.height)
        }
        guard result.width >= 1, result.height >= 1, PageGeometry(width: result.width, height: result.height).isValid else { return nil }
        return result
    }

    /// The change a resize to `rect` writes: the geometry (now *Custom*), and the origin when the
    /// top or left edge moved -- one change, "Change page size".
    static func resizeCommand(_ page: Page, to rect: Rect) -> any WTModel.Command {
        let geometry = SetPageGeometry([page.id], to: PageGeometry(width: rect.width, height: rect.height))
        let moved = Vector(dx: rect.minX - page.rect.minX, dy: rect.minY - page.rect.minY)
        guard moved != .zero else { return geometry }
        return CommandBatch(geometry.label, [MovePage(page.id, by: moved, withContents: false), geometry])
    }

    /// Whether a rotate drag about `center` from `start` to `end` turned the page past 45°.
    static func rotates(_ center: Point, from start: Point, to end: Point) -> Bool {
        let a = atan2(start.y - center.y, start.x - center.x), b = atan2(end.y - center.y, end.x - center.x)
        var turn = abs(b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if turn > .pi { turn = 2 * .pi - turn }
        return turn >= .pi / 4 && turn <= 3 * .pi / 4
    }

    /// kbd:[Option]-drag: "Duplicate page", then the copy (the page after it in page order) moves,
    /// objects and all, to where the drag ended -- two changes, one undo step.
    private func duplicate(_ id: OpID, by delta: Vector, in context: ToolContext) {
        let document = context.document
        guard let original = document.pageList[id] else { return }
        let target = original.origin + delta
        document.beginGroup()
        let duplicated = context.commandSink.perform(DuplicatePage(id))
        Task { @MainActor in
            defer { document.endGroup() }
            guard await duplicated.value != nil, let copy = document.pageList.page(number: original.number + 1) else { return }
            _ = await context.commandSink.perform(MovePage(copy.id, by: target - copy.origin)).value
        }
    }

    // MARK: Drawing

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let context else { return }
        let document = context.document
        let toView = viewport.pasteboardToView
        ctx.setLineWidth(1)
        for page in document.selectedPages {
            let dimmed = page.isChild
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(dimmed ? 0.35 : 1).cgColor)
            let corners = [Point(x: page.rect.minX, y: page.rect.minY), Point(x: page.rect.maxX, y: page.rect.minY),
                           Point(x: page.rect.maxX, y: page.rect.maxY), Point(x: page.rect.minX, y: page.rect.maxY)].map { toView.apply($0).cgPoint }
            ctx.addLines(between: corners + [corners[0]])
            ctx.strokePath()
            ctx.setFillColor(NSColor.white.withAlphaComponent(dimmed ? 0.5 : 1).cgColor)
            for anchor in HandleAnchor.allCases {
                let point = toView.apply(Self.point(anchor, of: page.rect))
                let rect = CGRect(x: point.x - Self.handleSize / 2, y: point.y - Self.handleSize / 2, width: Self.handleSize, height: Self.handleSize)
                ctx.fill(rect)
                ctx.stroke(rect)
            }
        }
        guard isDragging, let gesture, let start, let current else { return }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        switch gesture {
        case .marquee:
            ctx.stroke(Rect(start.viewPoint, current.viewPoint).cgRect)
        case .move(let pages):
            if let delta = moveDelta(pages: pages, document: document) {
                for page in pages.compactMap({ document.pageList[$0] }) { strokeRect(page.rect.offset(by: delta), toView: toView, in: ctx) }
            }
        case .resize(let id, let anchor):
            if let page = document.pageList[id], let rect = resizedRect(page, anchor: anchor, to: current) { strokeRect(rect, toView: toView, in: ctx) }
        case .rotate(let id):
            if let page = document.pageList[id], Self.rotates(page.rect.center, from: start.pasteboardPoint, to: current.pasteboardPoint) {
                let turned = Rect(x: page.rect.center.x - page.rect.height / 2, y: page.rect.center.y - page.rect.width / 2, width: page.rect.height, height: page.rect.width)
                strokeRect(turned, toView: toView, in: ctx)
            }
        }
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private func strokeRect(_ rect: Rect, toView: WTGeometry.AffineTransform, in ctx: CGContext) {
        let corners = [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY), Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY)]
            .map { toView.apply($0).cgPoint }
        ctx.addLines(between: corners + [corners[0]])
        ctx.strokePath()
    }
}

extension HandleAnchor {
    /// 0 left, 1 centre, 2 right.
    var column: Int { Int(unit.x * 2) }
    /// 0 top, 1 middle, 2 bottom.
    var row: Int { Int(unit.y * 2) }

    /// The handle across the bounds.
    var opposite: HandleAnchor {
        switch self {
        case .topLeft: .bottomRight
        case .top: .bottom
        case .topRight: .bottomLeft
        case .right: .left
        case .bottomRight: .topLeft
        case .bottom: .top
        case .bottomLeft: .topRight
        case .left: .right
        }
    }
}
