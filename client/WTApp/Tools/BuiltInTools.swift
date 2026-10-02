import AppKit
import WTGeometry
import WTRender

/// The stand-in for a tool whose epic has not landed (toolbars.adoc, "Client"): selectable,
/// with a cursor, shows a "coming soon" HUD on mouse down and never writes a change.
@MainActor
final class UnimplementedTool: Tool, ToolInfoPublishing {
    static let id: ToolID = "unimplemented"

    let toolID: ToolID
    let title: String
    let cursor: NSCursor
    private var context: ToolContext?
    private(set) var pressCount = 0
    /// The Info toolbar readout of the drag in progress (`ToolReadout`).
    private(set) var info = ToolInfo()
    private var start: Point?

    init(id: ToolID, title: String, cursor: NSCursor = .arrow) {
        toolID = id
        self.title = title
        self.cursor = cursor
    }

    var message: String { "The \(title) tool is coming soon" }

    func activate(in context: ToolContext) { self.context = context }
    func deactivate() { context = nil }

    func mouseDown(_ e: CanvasEvent) {
        pressCount += 1
        start = e.pasteboardPoint
        info = ToolReadout.info(for: toolID, start: e.pasteboardPoint, current: e.pasteboardPoint)
        context?.host.showHUD(message)
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard let start else { return }
        info = ToolReadout.info(for: toolID, start: start, current: e.pasteboardPoint)
    }

    func mouseUp(_ e: CanvasEvent) { cancel() }
    func flagsChanged(_ e: CanvasEvent) {}
    func keyDown(_ e: NSEvent) -> Bool { false }
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {}

    func cancel() {
        start = nil
        info = ToolInfo()
    }
}

/// The Hand: dragging scrolls the pasteboard (Space pushes it over any tool).  Changes only
/// the view, never the document.
@MainActor
final class PanTool: Tool {
    static let id: ToolID = .hand

    private var context: ToolContext?
    private(set) var lastViewPoint: Point?

    init() {}

    var cursor: NSCursor { lastViewPoint == nil ? .openHand : .closedHand }

    func activate(in context: ToolContext) { self.context = context }

    func deactivate() {
        context = nil
        lastViewPoint = nil
    }

    func mouseDown(_ e: CanvasEvent) {
        lastViewPoint = e.viewPoint
        context?.host.toolCursorDidChange()
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard let context, let last = lastViewPoint else { return }
        context.host.setViewport(context.viewport.scrolled(byViewDelta: last - e.viewPoint))
        lastViewPoint = e.viewPoint
    }

    func mouseUp(_ e: CanvasEvent) {
        lastViewPoint = nil
        context?.host.toolCursorDidChange()
    }

    func flagsChanged(_ e: CanvasEvent) {}
    func keyDown(_ e: NSEvent) -> Bool { false }
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {}
    func cancel() { lastViewPoint = nil }
}

/// The Zoom tool (document-view.adoc, "Zooming"; BASIC-012): click zooms in one step about
/// the click, Option-click zooms out, a drag zooms to the dragged area, Option-drag fits the
/// window's current view into the dragged rectangle, Control-click jumps to the maximum and
/// Control+Option-click to the minimum, and Shift-drag zooms to the area and asks for a named
/// view of it.  Modifiers are read on mouse-up.
@MainActor
final class ZoomTool: Tool {
    static let id: ToolID = .zoom
    /// A drag shorter than this (view points) is a click.
    static let clickSlop = 3.0

    private var context: ToolContext?
    private(set) var start: CanvasEvent?
    private(set) var current: CanvasEvent?
    /// Unclamped: the canvas clamps the target to its extent and zoom floor.
    private let navigation = CanvasNavigation.unbounded

    init() {}

    var cursor: NSCursor { .crosshair }

    func activate(in context: ToolContext) { self.context = context }

    func deactivate() {
        context = nil
        cancel()
    }

    func mouseDown(_ e: CanvasEvent) {
        start = e
        current = e
    }

    func mouseDragged(_ e: CanvasEvent) { current = e }

    func mouseUp(_ e: CanvasEvent) {
        defer { cancel() }
        guard let context, let start else { return }
        let viewport = context.viewport
        let target = Self.target(viewport: viewport, start: start, end: e, navigation: navigation)
        context.host.setViewport(target)
        if Self.definesNamedView(start: start, end: e) {
            context.host.requestNamedView(context.host.viewport)
        }
    }

    /// Whether the gesture is a Shift-drag, which ends in the New View sheet.
    static func definesNamedView(start: CanvasEvent, end: CanvasEvent) -> Bool {
        end.modifiers.contains(.shift) && !end.modifiers.contains(.option) && end.viewPoint.distance(to: start.viewPoint) >= clickSlop
    }

    /// Where a zoom gesture from `start` to `end` lands.
    static func target(viewport: Viewport, start: CanvasEvent, end: CanvasEvent, navigation: CanvasNavigation = .unbounded) -> Viewport {
        let modifiers = end.modifiers
        if end.viewPoint.distance(to: start.viewPoint) < clickSlop {
            if modifiers.contains(.control) {
                let zoom = modifiers.contains(.option) ? Viewport.zoomRange.lowerBound : Viewport.zoomRange.upperBound
                return navigation.zoom(viewport, to: zoom, about: end.viewPoint)
            }
            let zoom = modifiers.contains(.option) ? ZoomLadder.zoomOut(from: viewport.zoom) : ZoomLadder.zoomIn(from: viewport.zoom)
            return navigation.zoom(viewport, to: zoom, about: end.viewPoint)
        }
        if modifiers.contains(.option) {
            return shrink(viewport, into: Rect(start.viewPoint, end.viewPoint), navigation: navigation)
        }
        return navigation.fit(viewport, rect: Rect(start.pasteboardPoint, end.pasteboardPoint))
    }

    /// Option-drag: zooms out so that what the window shows now fits the dragged rectangle
    /// (view points), at the rectangle's place.
    static func shrink(_ viewport: Viewport, into viewRect: Rect, navigation: CanvasNavigation = .unbounded) -> Viewport {
        let factor = min(viewRect.width / max(viewport.size.width, 1), viewRect.height / max(viewport.size.height, 1))
        guard factor > 0 else { return viewport }
        let centre = viewport.toPasteboard(viewport.viewCenter)
        let zoomed = viewport.zoomed(to: viewport.zoom * factor)
        return navigation.clamped(zoomed.scrolled(byViewDelta: zoomed.toView(centre) - viewRect.center))
    }

    func flagsChanged(_ e: CanvasEvent) {
        if current != nil { current = current?.with(modifiers: e.modifiers) }
    }

    func keyDown(_ e: NSEvent) -> Bool { false }

    /// The marquee while dragging.
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let start, let current, current.viewPoint.distance(to: start.viewPoint) >= Self.clickSlop else { return }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(Rect(start.viewPoint, current.viewPoint).cgRect)
    }

    func cancel() {
        start = nil
        current = nil
    }
}
