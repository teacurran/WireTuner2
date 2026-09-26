import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The Link tool (interactivity.adoc, "The Link tool"; WEB-022): drag from an object to a page to
/// link it there -- the page under the pointer highlights and a connector follows -- and release
/// for one change ("Link to page N").  Dropping on the object's own page removes its link, or
/// with kbd:[Option] links it to that page.  The link badges show while the tool is selected, and
/// dragging a badge moves or removes that link the same way; the badge is taken before the object
/// under it.  kbd:[Space] pans mid-drag and the canvas auto-scrolls at its edges.  The pointer is
/// a chain over what it can link and "no" over a locked object or text being edited.  The rule
/// for a release is `WTModel.PageLinkDrag`.
@MainActor
final class LinkTool: Tool, SpaceDragging, PointerTracking {
    static let id: ToolID = "action"
    static let statusMessage = "Drag from an object to a page to link it there; drop on its own page to remove the link, Option to link to it"

    /// What is under the pointer.
    enum Hover: Equatable {
        case none
        /// An object or badge the tool can link.
        case linkable
        /// A locked object or text being edited.
        case refused
    }

    /// A drag in progress.
    struct Drag: Equatable {
        var source: OpID
        /// Started on the source's link badge.
        var fromBadge: Bool
        /// Where the connector starts (pasteboard).
        var anchor: Point
        var current: Point
        var option: Bool
        /// kbd:[Space] held: the drag pans.
        var panning = false
        var lastView: Point
    }

    private var context: ToolContext?
    private(set) var hover: Hover = .none
    private(set) var drag: Drag?

    init() {}

    static let chainCursor: NSCursor = {
        let image = NSImage(systemSymbolName: "link", accessibilityDescription: "Link") ?? NSImage(size: NSSize(width: 16, height: 16))
        return NSCursor(image: image, hotSpot: NSPoint(x: 1, y: 1))
    }()

    var cursor: NSCursor {
        switch hover {
        case .linkable: Self.chainCursor
        case .refused: .operationNotAllowed
        case .none: .arrow
        }
    }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
        context.host.setNeedsOverlayDisplay()
    }

    func deactivate() {
        drag = nil
        hover = .none
        context?.host.setNeedsOverlayDisplay()
        context = nil
    }

    // MARK: What is under the pointer

    /// A source the tool could drag from.
    enum Target: Equatable {
        case source(OpID, badge: Bool)
        case refused
    }

    /// The badge under `e` first, then the top-level object.
    static func target(at e: CanvasEvent, context: ToolContext) -> Target? {
        let document = context.document
        if let badge = LinkBadges.badges(document).last(where: { LinkBadges.rect($0, viewport: context.viewport).contains(e.viewPoint) }) {
            return .source(badge.node, badge: true)
        }
        let state = document.state
        for hit in context.selection.hitTester(viewport: context.viewport, subselect: false).hitTest(viewPoint: e.viewPoint) {
            guard let node = document.selectionID(atItemPath: hit.itemPath)?.opID else { continue }
            // Text being edited is a text range: ranges take links, not page targets.
            if hit.kind == .text, context.objectEditing?.textSession?.node == node { return .refused }
            return PageLinkDrag.isLinkable(node, in: state) ? .source(node, badge: false) : .refused
        }
        return nil
    }

    func pointerMoved(_ e: CanvasEvent) {
        guard let context else { return }
        let next: Hover = switch Self.target(at: e, context: context) {
        case .source?: .linkable
        case .refused?: .refused
        case nil: .none
        }
        guard next != hover else { return }
        hover = next
        context.host.toolCursorDidChange()
    }

    // MARK: Dragging

    func mouseDown(_ e: CanvasEvent) {
        guard let context else { return }
        pointerMoved(e)
        guard case .source(let node, let badge)? = Self.target(at: e, context: context) else { return }
        let bounds = Objects.bounds(of: node, in: context.document.state)
        let anchor = badge ? bounds.map { Point(x: $0.maxX, y: $0.maxY) } : bounds.map(\.center)
        drag = Drag(source: node, fromBadge: badge, anchor: anchor ?? e.pasteboardPoint, current: e.pasteboardPoint,
                    option: e.modifiers.contains(.option), lastView: e.viewPoint)
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard let context, var drag else { return }
        if drag.panning {
            context.host.setViewport(context.viewport.scrolled(byViewDelta: drag.lastView - e.viewPoint))
        } else {
            drag.current = e.pasteboardPoint
        }
        drag.lastView = e.viewPoint
        drag.option = e.modifiers.contains(.option)
        self.drag = drag
        context.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        guard let context, let current = drag else { return }
        drag = nil
        context.host.setNeedsOverlayDisplay()
        let point = current.panning ? current.current : e.pasteboardPoint
        let outcome = PageLinkDrag.outcome(source: current.source, drop: point, option: e.modifiers.contains(.option), in: context.document.state)
        guard let command = PageLinkDrag.command(source: current.source, outcome: outcome) else { return }
        context.commandSink.perform(command)
    }

    func flagsChanged(_ e: CanvasEvent) {
        guard drag != nil else { return }
        drag?.option = e.modifiers.contains(.option)
        context?.host.setNeedsOverlayDisplay()
    }

    func keyDown(_ e: NSEvent) -> Bool { false }

    var isDragging: Bool { drag != nil }

    func spaceChanged(down: Bool) {
        drag?.panning = down
    }

    func cancel() {
        drag = nil
        context?.host.setNeedsOverlayDisplay()
    }

    var hasSomethingToCancel: Bool { drag != nil }

    // MARK: Overlay

    /// The page a drop at the drag's point would target.
    func targetPage() -> Page? {
        guard let context, let drag else { return nil }
        return PageLinkDrag.page(at: drag.current, in: PageList(context.document.state))
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let context else { return }
        LinkBadges.draw(context.document, in: ctx, viewport: viewport)
        guard let drag else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let page = targetPage() {
            let r = page.rect
            let corners = [Point(x: r.minX, y: r.minY), Point(x: r.maxX, y: r.minY), Point(x: r.maxX, y: r.maxY), Point(x: r.minX, y: r.maxY)]
                .map { viewport.toView($0).cgPoint }
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2)
            ctx.addLines(between: corners + [corners[0]])
            ctx.drawPath(using: .fillStroke)
        }
        let from = viewport.toView(drag.anchor).cgPoint
        let to = viewport.toView(drag.current).cgPoint
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.strokeLineSegments(between: [from, to])
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.fillEllipse(in: CGRect(x: to.x - 3, y: to.y - 3, width: 6, height: 6))
    }
}
