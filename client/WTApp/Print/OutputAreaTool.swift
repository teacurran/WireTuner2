import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The geometry of the Output Area tool (output-area.adoc, "Defining an output area", "Adjusting an
/// output area"), pure so the gestures are testable without events.
enum OutputAreaGeometry {
    /// The eight handles: corners and side midpoints, clockwise from the top-left.
    enum Handle: Int, CaseIterable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var isCorner: Bool { rawValue % 2 == 0 }

        /// Where the handle sits on `rect` (pasteboard, y down).
        func point(on rect: Rect) -> Point {
            let xs = [rect.minX, rect.midX, rect.maxX, rect.maxX, rect.maxX, rect.midX, rect.minX, rect.minX]
            let ys = [rect.minY, rect.minY, rect.minY, rect.midY, rect.maxY, rect.maxY, rect.maxY, rect.midY]
            return Point(x: xs[rawValue], y: ys[rawValue])
        }

        /// The handle across the rectangle (the fixed point of a resize).
        var opposite: Handle { Handle(rawValue: (rawValue + 4) % 8)! }
    }

    /// The rectangle dragged from `anchor` to `point`: kbd:[Shift] a square, kbd:[Option] from the
    /// centre.
    static func defined(from anchor: Point, to point: Point, square: Bool, fromCenter: Bool) -> Rect {
        var dx = point.x - anchor.x, dy = point.y - anchor.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if fromCenter {
            return Rect(Point(x: anchor.x - dx, y: anchor.y - dy), Point(x: anchor.x + dx, y: anchor.y + dy))
        }
        return Rect(anchor, Point(x: anchor.x + dx, y: anchor.y + dy))
    }

    /// `rect` with `handle` dragged to `point`: a corner changes both dimensions, a side one;
    /// kbd:[Shift] keeps the proportions, kbd:[Option] resizes about the centre.
    static func resized(_ rect: Rect, handle: Handle, to point: Point, proportional: Bool, aboutCenter: Bool) -> Rect {
        let anchor = aboutCenter ? Point(x: rect.midX, y: rect.midY) : handle.opposite.point(on: rect)
        let grabbed = handle.point(on: rect)
        let horizontal = handle != .top && handle != .bottom
        let vertical = handle != .left && handle != .right
        var sx = horizontal ? (point.x - anchor.x) / (grabbed.x - anchor.x) : 1
        var sy = vertical ? (point.y - anchor.y) / (grabbed.y - anchor.y) : 1
        if proportional {
            let scale = handle.isCorner ? max(abs(sx), abs(sy)) : horizontal ? abs(sx) : abs(sy)
            sx = sx < 0 ? -scale : scale
            sy = sy < 0 ? -scale : scale
        }
        func mapped(_ p: Point) -> Point { Point(x: anchor.x + (p.x - anchor.x) * sx, y: anchor.y + (p.y - anchor.y) * sy) }
        return Rect(mapped(Point(x: rect.minX, y: rect.minY)), mapped(Point(x: rect.maxX, y: rect.maxY)))
    }

    /// The handle within `distance` view points of `viewPoint`, if any.
    static func handle(at viewPoint: Point, on rect: Rect, viewport: Viewport, distance: Double) -> Handle? {
        Handle.allCases.first { viewport.toView($0.point(on: rect)).distance(to: viewPoint) <= distance }
    }

    /// Whether `viewPoint` is on the dashed boundary or inside the area (a drag there moves it).
    static func isOnArea(_ viewPoint: Point, rect: Rect, viewport: Viewport, distance: Double) -> Bool {
        let corners = [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.maxY)].map(viewport.toView)
        let view = Rect(corners[0], corners[1])
        return view.insetBy(dx: -distance, dy: -distance).contains(viewPoint)
    }
}

/// The Output Area tool (output-area.adoc; PRINT-011): drag outside the area defines a new one
/// (kbd:[Shift] square, kbd:[Option] from the centre), a handle resizes it, the boundary or inside
/// moves it, the arrow keys nudge it by one document unit (kbd:[Shift]: ten), a click outside or
/// kbd:[Delete] removes it.  Every gesture is one change on mouse-up writing the one register.
@MainActor
final class OutputAreaTool: Tool, PointerTracking {
    static let id: ToolID = "outputArea"
    static let statusMessage = "Drag to define the output area; drag a handle to resize it, its edge to move it; click outside to remove it"
    /// A press that moves less than this (view points) is a click.
    static let dragThreshold = 3.0
    /// How near a handle or the edge counts, in view points.
    static let reach = 5.0

    enum Gesture: Equatable {
        case defining(anchor: Point)
        case moving(start: Point, rect: Rect)
        case resizing(OutputAreaGeometry.Handle, rect: Rect)
    }

    private(set) var context: ToolContext?
    private(set) var gesture: Gesture?
    private(set) var pressPoint: Point?
    private(set) var current: CanvasEvent?
    /// Where the pointer rests (the cursor).
    private(set) var hover: Gesture?

    static var descriptor: ToolDescriptor {
        ToolCatalog.all.first { $0.id == id }!.delivering { OutputAreaTool() }
    }

    var area: Rect? { context.map { OutputArea.read($0.document.state) } ?? nil }

    var cursor: NSCursor {
        switch gesture ?? hover {
        case .moving?: .openHand
        case .resizing?: .crosshair
        default: .crosshair
        }
    }

    var hasSomethingToCancel: Bool { gesture != nil }

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

    /// The gesture a press at `viewPoint` starts.
    func gesture(at e: CanvasEvent, context: ToolContext) -> Gesture {
        if let area {
            if let handle = OutputAreaGeometry.handle(at: e.viewPoint, on: area, viewport: context.viewport, distance: Self.reach) {
                return .resizing(handle, rect: area)
            }
            if OutputAreaGeometry.isOnArea(e.viewPoint, rect: area, viewport: context.viewport, distance: Self.reach) {
                return .moving(start: e.pasteboardPoint, rect: area)
            }
        }
        return .defining(anchor: context.snapping.snap(e.pasteboardPoint, viewport: context.viewport))
    }

    func pointerMoved(_ e: CanvasEvent) {
        guard let context, gesture == nil else { return }
        let next = gesture(at: e, context: context)
        let changed: Bool
        switch (hover, next) {
        case (.moving?, .moving), (.resizing?, .resizing), (.defining?, .defining): changed = false
        default: changed = true
        }
        hover = next
        if changed { context.host.toolCursorDidChange() }
    }

    func mouseDown(_ e: CanvasEvent) {
        guard let context else { return }
        gesture = gesture(at: e, context: context)
        pressPoint = e.viewPoint
        current = e
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard gesture != nil else { return }
        current = e
        context?.host.setNeedsOverlayDisplay()
    }

    var isDragging: Bool {
        guard let pressPoint, let current else { return false }
        return current.viewPoint.distance(to: pressPoint) >= Self.dragThreshold
    }

    /// The rectangle the gesture in progress would write, nil for a click.
    var preview: Rect? {
        guard let gesture, let current, let context, isDragging else { return nil }
        let point = context.snapping.snap(current.pasteboardPoint, viewport: context.viewport)
        let shift = current.modifiers.contains(.shift), option = current.modifiers.contains(.option)
        switch gesture {
        case .defining(let anchor):
            return OutputAreaGeometry.defined(from: anchor, to: point, square: shift, fromCenter: option)
        case .moving(let start, let rect):
            let delta = context.snapping.snapDrag(of: Point(x: rect.minX, y: rect.minY), by: current.pasteboardPoint - start, viewport: context.viewport)
            return rect.offset(by: delta)
        case .resizing(let handle, let rect):
            return OutputAreaGeometry.resized(rect, handle: handle, to: point, proportional: shift, aboutCenter: option)
        }
    }

    func mouseUp(_ e: CanvasEvent) {
        current = e
        defer {
            gesture = nil
            pressPoint = nil
            current = nil
            context?.host.setNeedsOverlayDisplay()
        }
        guard let context, let gesture else { return }
        guard let rect = preview else {
            // A click outside the area removes it; a click on it does nothing.
            if case .defining = gesture, area != nil { context.commandSink.perform(SetOutputArea(nil)) }
            return
        }
        guard rect.width > 0, rect.height > 0 else { return }
        switch gesture {
        case .defining: context.commandSink.perform(SetOutputArea(rect, kind: .define))
        case .moving: context.commandSink.perform(SetOutputArea(rect, kind: .move))
        case .resizing: context.commandSink.perform(SetOutputArea(rect, kind: .resize))
        }
    }

    func flagsChanged(_ e: CanvasEvent) {
        guard gesture != nil, let current else { return }
        self.current = current.with(modifiers: e.modifiers)
        context?.host.setNeedsOverlayDisplay()
    }

    /// Arrow keys nudge by one document unit (kbd:[Shift]: ten); kbd:[Delete] removes the area.
    func keyDown(_ e: NSEvent) -> Bool {
        handleKey(keyCode: e.keyCode, shift: e.modifierFlags.contains(.shift))
    }

    @discardableResult
    func handleKey(keyCode: UInt16, shift: Bool) -> Bool {
        guard let context, let area else { return false }
        if keyCode == 51 || keyCode == 117 {
            context.commandSink.perform(SetOutputArea(nil))
            return true
        }
        let unit = context.document.unitConverter.pointsPerUnit(context.document.units)
        guard let delta = ObjectEditing.nudgeDelta(keyCode: keyCode, distance: unit * (shift ? 10 : 1)) else { return false }
        context.commandSink.perform(SetOutputArea(area.offset(by: delta), kind: .move))
        return true
    }

    func cancel() {
        gesture = nil
        pressPoint = nil
        current = nil
        context?.host.setNeedsOverlayDisplay()
    }

    /// The handles of the area (and the drag's preview) while the tool is active; the dashed
    /// boundary itself is drawn for every tool by the window's output area overlay.
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let rect = preview ?? area else { return }
        if preview != nil { OutputAreaOverlay.drawBoundary(rect, in: ctx, viewport: viewport) }
        ctx.saveGState()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        for handle in OutputAreaGeometry.Handle.allCases {
            let p = viewport.toView(handle.point(on: rect))
            let box = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
            ctx.fill(box)
            ctx.stroke(box)
        }
        ctx.restoreGState()
    }
}

/// The output area's dashed rectangle over the canvas in every tool (1 px, the accent colour),
/// hidden while the window's *Show* is off.
enum OutputAreaOverlay {
    static func drawBoundary(_ rect: Rect, in ctx: CGContext, viewport: Viewport) {
        let corners = [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY), Point(x: rect.maxX, y: rect.maxY),
                       Point(x: rect.minX, y: rect.maxY)].map(viewport.toView)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.addLines(between: corners.map { CGPoint(x: $0.x, y: $0.y) })
        ctx.closePath()
        ctx.strokePath()
        ctx.restoreGState()
    }
}
