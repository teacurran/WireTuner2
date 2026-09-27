import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The contents handle (clipping-paths.adoc, "Editing the contents"; OBJ-028's app half): a
/// small circle at the centre of the contents of the one selected clip group, drawn over the
/// Pointer and Subselect tools (`ContentsHandle.position`).  Dragging it slides the contents behind
/// the clip path -- one change "Move contents" on release (`MoveContents`), previewed as the
/// handle and the contents' outline moving -- and a double-click on it subselects everything
/// inside.  Deviation: the handle shows whenever one clip group is selected, not only while the
/// Object panel's *Contents* row is selected (the panel has no row selection to follow).
@MainActor
final class ClipContentsHandle: CanvasHandleLayer {
    static let size = 9.0

    /// The drag in progress: the group, where it started and where the pointer is.
    private(set) var dragging: (group: OpID, start: Point, current: Point)?

    init() {}

    /// The one selected clip group and its handle (pasteboard), if any.
    static func handle(_ context: ToolContext) -> (group: OpID, position: Point)? {
        let ids = context.selection.selection.ids
        guard ids.count == 1, context.selection.selection.subSelection(of: ids[0]) == nil else { return nil }
        let group = ids[0].opID
        let document = context.document
        return ContentsHandle.position(of: group, in: document.scene, state: document.state).map { (group, $0) }
    }

    static func tolerance(_ context: ToolContext) -> Double {
        max(context.selection.pickDistance(), size / 2) / context.viewport.zoom
    }

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        guard let (group, position) = Self.handle(context),
              ContentsHandle.hits(e.pasteboardPoint, handle: position, tolerance: Self.tolerance(context)) else { return false }
        if e.clickCount >= 2 {
            let contents = ClipGroups.contents(of: group, in: context.document.state)
            if !contents.isEmpty { context.selection.model.set(Selection(contents.map { SelectionID($0) })) }
            return true
        }
        dragging = (group, e.pasteboardPoint, e.pasteboardPoint)
        return true
    }

    func drag(_ e: CanvasEvent, context: ToolContext) {
        dragging?.current = e.pasteboardPoint
    }

    func release(_ e: CanvasEvent, context: ToolContext) {
        guard let drag = dragging else { return }
        dragging = nil
        let delta = e.pasteboardPoint - drag.start
        if delta != .zero { context.commandSink.perform(MoveContents(drag.group, by: delta)) }
    }

    func cancel(context: ToolContext) {
        dragging = nil
    }

    func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext) {
        guard let (group, position) = Self.handle(context) else { return }
        var at = position
        if let dragging, dragging.group == group {
            let delta = dragging.current - dragging.start
            at = position + delta
            // The contents' outlines where they would land.
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            for content in ClipGroups.contents(of: group, in: context.document.state) {
                guard let bounds = context.document.scene.object(content)?.bounds else { continue }
                let moved = bounds.applying(.translation(delta))
                let a = viewport.toView(Point(x: moved.minX, y: moved.minY)), b = viewport.toView(Point(x: moved.maxX, y: moved.maxY))
                ctx.stroke(Rect(a, b).cgRect)
            }
        }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        let view = viewport.toView(at)
        CanvasHandleLayers.drawHandle(view, size: Self.size, in: ctx)
        CanvasHandleLayers.drawHandle(view, size: Self.size, hollow: true, in: ctx)
    }
}

/// A polygon's diamond and a star's circle handle (polygons-stars.adoc, "Editing polygons and
/// stars"; DRAW-010's app half): drawn with the Subselect tool on each selected polygon
/// (`PolygonHandles.positions`).  Dragging the diamond moves every vertex -- its distance from the
/// centre the radius, its angle the rotation -- and the circle every inner point; kbd:[Shift]
/// keeps the angle.  The drag previews on the canvas and writes one `SetPolygonFields` on mouse-up
/// (D-076), so it is one undo step; kbd:[Esc] drops the preview.
@MainActor
final class PolygonShapeHandles: CanvasHandleLayer {
    static let size = 9.0
    static let tool: ToolID = "subselect"

    /// The window's active tool (the handles show with the Subselect tool).
    var activeTool: @MainActor () -> ToolID? = { nil }
    private(set) var dragging: (node: OpID, handle: PolygonHandles.Handle)?
    /// The drag's preview and its one change (D-076).
    private var edit: GestureEdit?

    init() {}

    /// The selected polygons (the handles show with the Subselect tool only).
    func polygons(_ context: ToolContext) -> [OpID] {
        guard activeTool() == Self.tool else { return [] }
        let state = context.document.state
        return context.selection.selection.ids.map(\.opID).filter { state.nodeKind($0) == .polygon && !Objects.isEffectivelyLocked($0, in: state) }
    }

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        let tolerance = max(context.selection.pickDistance(), Self.size / 2) / context.viewport.zoom
        for node in polygons(context) {
            if let handle = PolygonHandles.hit(e.pasteboardPoint, on: node, tolerance: tolerance, in: context.document.state) {
                dragging = (node, handle)
                edit = GestureEdit(document: context.document)
                return true
            }
        }
        return false
    }

    func drag(_ e: CanvasEvent, context: ToolContext) {
        guard let dragging,
              let command = PolygonHandles.drag(dragging.handle, of: dragging.node, to: e.pasteboardPoint, keepAngle: e.modifiers.contains(.shift),
                                                in: context.document.state) else { return }
        edit?.update(command)
    }

    func release(_ e: CanvasEvent, context: ToolContext) {
        drag(e, context: context)
        edit?.commit()
        finish(context)
    }

    func cancel(context: ToolContext) {
        edit?.cancel()
        finish(context)
    }

    /// Ends the drag: the change was written (or the preview dropped) already.
    private func finish(_ context: ToolContext) {
        dragging = nil
        edit = nil
    }

    func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext) {
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        let half = Self.size / 2
        for node in polygons(context) {
            guard let positions = PolygonHandles.positions(of: node, in: context.document.shownState) else { continue }
            let peak = viewport.toView(positions.peak)
            let diamond = CGMutablePath()
            diamond.addLines(between: [CGPoint(x: peak.x, y: peak.y - half), CGPoint(x: peak.x + half, y: peak.y), CGPoint(x: peak.x, y: peak.y + half),
                                       CGPoint(x: peak.x - half, y: peak.y)])
            diamond.closeSubpath()
            ctx.addPath(diamond)
            ctx.drawPath(using: .fillStroke)
            if let valley = positions.valley {
                let at = viewport.toView(valley)
                CanvasHandleLayers.drawHandle(at, size: Self.size, in: ctx)
                CanvasHandleLayers.drawHandle(at, size: Self.size, hollow: true, in: ctx)
            }
        }
    }
}

/// kbd:[Option]-drag resizing of an image in printer-resolution steps (bitmaps.adoc, "Resizing";
/// IMG-004's app half): with kbd:[Option] held, a press on a corner of the one selected image's
/// frame (Pointer or Subselect tool) takes the drag; the image scales about the opposite corner to
/// the step nearest the pointer (`ImageResolution.snapped`: 100%, 50%, 33.3%, 25% ... of a 300 ppi
/// image on a 600 dpi document), previewed as its frame, and one "Scale" change lands on release.
@MainActor
final class ImageResolutionHandles: CanvasHandleLayer {
    static let radius = 6.0

    /// The drag in progress.
    struct Drag: Equatable {
        var node: OpID
        /// The pressed corner and the opposite one (pasteboard).
        var corner: Point
        var anchor: Point
        /// The image's scale when the drag began.
        var scale: Double
        var factor = 1.0
    }

    private(set) var dragging: Drag?

    init() {}

    /// The one selected image, if that is the selection.
    static func image(_ context: ToolContext) -> OpID? {
        let ids = context.selection.selection.ids
        guard ids.count == 1, context.document.state.nodeKind(ids[0].opID) == .image,
              !Objects.isEffectivelyLocked(ids[0].opID, in: context.document.state) else { return nil }
        return ids[0].opID
    }

    /// The image's frame corners in pasteboard space, in order round the frame.
    static func corners(of node: OpID, in state: EngineState) -> [Point]? {
        guard case .image(let image)? = state.props(node).kind else { return nil }
        let natural = ImageItem.naturalRect(pixelWidth: Int(image.pixels.pixelWidth), pixelHeight: Int(image.pixels.pixelHeight), dpiX: image.dpiX, dpiY: image.dpiY)
        let transform = Objects.pasteboardTransform(of: node, in: state)
        return [Point(x: natural.minX, y: natural.minY), Point(x: natural.maxX, y: natural.minY), Point(x: natural.maxX, y: natural.maxY),
                Point(x: natural.minX, y: natural.maxY)].map(transform.apply)
    }

    /// The factor a drag to `point` scales by: the proposed scale snapped to the image's steps,
    /// over its scale when the drag began.
    static func factor(_ drag: Drag, to point: Point, in state: EngineState) -> Double {
        let reach = drag.corner.distance(to: drag.anchor)
        guard reach > 0, drag.scale > 0 else { return 1 }
        let proposed = drag.scale * point.distance(to: drag.anchor) / reach
        let snapped = ImageResolution.snapped(max(proposed, 1e-6), for: drag.node, in: state) ?? proposed
        return snapped / drag.scale
    }

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        guard e.modifiers.contains(.option), let node = Self.image(context), let corners = Self.corners(of: node, in: context.document.state),
              let scale = ImageResolution.scale(of: node, in: context.document.state),
              let index = corners.firstIndex(where: { context.viewport.toView($0).distance(to: e.viewPoint) <= Self.radius }) else { return false }
        dragging = Drag(node: node, corner: corners[index], anchor: corners[(index + 2) % 4], scale: scale)
        return true
    }

    func drag(_ e: CanvasEvent, context: ToolContext) {
        guard let drag = dragging else { return }
        dragging?.factor = Self.factor(drag, to: e.pasteboardPoint, in: context.document.state)
    }

    func release(_ e: CanvasEvent, context: ToolContext) {
        drag(e, context: context)
        guard let drag = dragging else { return }
        dragging = nil
        guard abs(drag.factor - 1) > 1e-9 else { return }
        context.commandSink.perform(TransformObjects([drag.node], matrix: .scale(drag.factor), about: drag.anchor, kind: .scale))
    }

    func cancel(context: ToolContext) {
        dragging = nil
    }

    func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext) {
        guard let drag = dragging, let corners = Self.corners(of: drag.node, in: context.document.state) else { return }
        let m = AffineTransform.translation(Vector(dx: -drag.anchor.x, dy: -drag.anchor.y)).concatenating(.scale(drag.factor))
            .concatenating(.translation(Vector(dx: drag.anchor.x, dy: drag.anchor.y)))
        let path = CGMutablePath()
        path.addLines(between: corners.map { viewport.toView(m.apply($0)).cgPoint })
        path.closeSubpath()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.strokePath()
        let percent = (drag.scale * drag.factor * 100 * 10).rounded() / 10
        let label = NSAttributedString(string: "\(percent.formatted())%", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        let at = viewport.toView(m.apply(drag.corner))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        label.draw(at: NSPoint(x: at.x + 8, y: at.y + 8))
        NSGraphicsContext.restoreGraphicsState()
    }
}
