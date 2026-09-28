import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// Handle editing under the Pointer and Subselect tools (editing-paths.adoc, "Adjusting handles";
/// DRAW-025): the handles of the selected points and the near handles of their two neighbours
/// can be dragged.  How the other handle answers is the point type's (`SetHandles` linked): a
/// curve point's handles pivot together, a corner's move alone, a connector's only lengthens
/// along its line; kbd:[Option] during the drag moves the one handle alone.  The drag previews in
/// the overlay -- the path with the handle moved, the handle's line and knob, stroked like a point
/// drag's preview -- and writes one `SetHandles` on mouse-up (D-076: gestures write intent, not
/// input events); kbd:[Esc] clears the preview and writes nothing.
@MainActor
final class PointHandleLayer: CanvasHandleLayer {
    /// How near a handle's end (view points) a press takes it.
    static let radius = 5.0
    static let size = 6.0

    /// One draggable handle.
    struct Grab: Equatable {
        var node: OpID
        var contour: OpID
        var point: OpID
        /// The outgoing handle (else the incoming one).
        var out: Bool
        /// Local → pasteboard.
        var transform: WTGeometry.AffineTransform
        /// The point's anchor and the handle's end, local space.
        var anchor: Point
        var end: Point
        /// A neighbour's near handle (drawn here; the selected points' own are the overlay's).
        var neighbour: Bool
    }

    private(set) var dragging: Grab?
    /// The command the drag would write now (the last drag event's), nil before the first.
    private(set) var pending: SetHandles?
    /// The preview of the drag just written, drawn until its change has rendered (D-076).
    private(set) var lingering: Preview?
    private var lingerGeneration = 0

    /// What a handle drag previews (pasteboard space).
    struct Preview {
        var path: DisplayPath
        var anchor: Point
        var ends: [Point]
        var dragged: Point
    }

    init() {}

    /// Every draggable handle of the selection: each selected point's non-retracted handles and
    /// the facing handles of its neighbours.
    static func grabs(_ context: ToolContext) -> [Grab] {
        let selection = context.selection.selection
        return selection.ids.flatMap { id -> [Grab] in
            guard case let .points(points)? = selection.subSelection(of: id), let object = context.document.object(for: id),
                  PointEditing.editsPoints(of: object), let path = object.path else { return [] }
            var grabs: [Grab] = []
            for contour in path.contours where contour.isRenderable {
                let drawn = contour.drawn
                let selected = Set(drawn.indices.filter { points.contains(PointReference(node: id.node, contour: contour.id, point: drawn[$0].id)) })
                func add(_ index: Int, out: Bool, neighbour: Bool) {
                    let point = drawn[index]
                    let handle = out ? point.outHandle : point.inHandle
                    guard handle != .zero else { return }
                    let grab = Grab(node: object.id, contour: contour.id, point: point.id, out: out, transform: object.transform,
                                    anchor: point.anchor, end: point.anchor + handle, neighbour: neighbour)
                    if !grabs.contains(where: { $0.point == grab.point && $0.out == grab.out && $0.contour == grab.contour }) { grabs.append(grab) }
                }
                for index in selected.sorted() {
                    add(index, out: false, neighbour: false)
                    add(index, out: true, neighbour: false)
                }
                for index in selected.sorted() {
                    let previous = index > 0 ? index - 1 : (contour.closed ? drawn.count - 1 : nil)
                    let next = index < drawn.count - 1 ? index + 1 : (contour.closed ? 0 : nil)
                    if let previous, !selected.contains(previous) { add(previous, out: true, neighbour: true) }
                    if let next, !selected.contains(next) { add(next, out: false, neighbour: true) }
                }
            }
            return grabs
        }
    }

    /// The command a drag of `grab` to `e` writes: the handle's end under the pointer.
    static func command(dragging grab: Grab, to e: CanvasEvent) -> SetHandles {
        let local = (grab.transform.inverted() ?? .identity).apply(e.pasteboardPoint)
        let handle = local - grab.anchor
        return SetHandles(node: grab.node, contour: grab.contour, point: grab.point, in: grab.out ? nil : handle, out: grab.out ? handle : nil,
                          linked: !e.modifiers.contains(.option))
    }

    // MARK: CanvasHandleLayer

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        let viewport = context.viewport
        let hits = Self.grabs(context).filter { viewport.toView($0.transform.apply($0.end)).distance(to: e.viewPoint) <= Self.radius }
        // A press nearer the point than its handle's end is the point's.
        guard let hit = hits.first(where: { viewport.toView($0.transform.apply($0.anchor)).distance(to: e.viewPoint) > Self.radius }) else { return false }
        dragging = hit
        pending = nil
        lingering = nil
        return true
    }

    /// Previews the handle under the pointer; nothing is written.
    func drag(_ e: CanvasEvent, context: ToolContext) {
        guard let dragging else { return }
        pending = Self.command(dragging: dragging, to: e)
        context.host.setNeedsOverlayDisplay()
    }

    /// Writes the one change of the drag.
    func release(_ e: CanvasEvent, context: ToolContext) {
        guard dragging != nil else { return }
        drag(e, context: context)
        let command = pending
        let shown = preview(context)
        finish(context)
        guard let command else { return }
        lingerGeneration += 1
        let generation = lingerGeneration
        lingering = shown
        context.commandSink.perform(command)
        context.host.whenTilesCatchUp { [weak self] in
            guard let self, self.lingerGeneration == generation, self.lingering != nil else { return }
            self.lingering = nil
            context.host.setNeedsOverlayDisplay()
        }
    }

    func cancel(context: ToolContext) {
        finish(context)
    }

    private func finish(_ context: ToolContext) {
        guard dragging != nil else { return }
        dragging = nil
        pending = nil
        context.host.setNeedsOverlayDisplay()
    }

    /// What the drag in progress previews: the path with the dragged point's handles as the
    /// command sets them (pasteboard space), the point's anchor and its two handle ends.
    func preview(_ context: ToolContext) -> Preview? {
        guard let grab = dragging, let command = pending, let object = context.document.object(for: SelectionID(grab.node)),
              var path = object.path, let c = path.contours.firstIndex(where: { $0.id == grab.contour }),
              let p = path.contours[c].points.firstIndex(where: { $0.id == grab.point }) else { return nil }
        let handles = SetHandles.resolved(path.contours[c], point: grab.point, in: command.inHandle, out: command.outHandle, linked: command.linked)
        if let inHandle = handles.in { path.contours[c].points[p].inHandle = inHandle }
        if let outHandle = handles.out { path.contours[c].points[p].outHandle = outHandle }
        let point = path.contours[c].points[p]
        let transform = object.transform
        let outline = PointEditing.preview(path, moved: [grab.point], smoother: PointEditing.smoother()).applying(transform)
        let ends = [point.inHandle, point.outHandle].filter { $0 != .zero }.map { transform.apply(point.anchor + $0) }
        let dragged = transform.apply(point.anchor + (grab.out ? point.outHandle : point.inHandle))
        return Preview(path: outline, anchor: transform.apply(point.anchor), ends: ends, dragged: dragged)
    }

    /// The neighbours' near handles (the selected points' own come with the selection outline).
    func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext) {
        if let preview = preview(context) ?? lingering {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            let outline = CGMutablePath()
            SelectionOverlay.add(preview.path, transform: viewport.pasteboardToView, to: outline)
            ctx.addPath(outline)
            ctx.strokePath()
            let anchor = viewport.toView(preview.anchor)
            for end in preview.ends {
                ctx.strokeLineSegments(between: [anchor.cgPoint, viewport.toView(end).cgPoint])
            }
            CanvasHandleLayers.drawHandle(viewport.toView(preview.dragged), size: Self.size, hollow: false, in: ctx)
            ctx.restoreGState()
        }
        let neighbours = Self.grabs(context).filter(\.neighbour)
        guard !neighbours.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        for grab in neighbours {
            let anchor = viewport.toView(grab.transform.apply(grab.anchor)), end = viewport.toView(grab.transform.apply(grab.end))
            ctx.strokeLineSegments(between: [anchor.cgPoint, end.cgPoint])
            CanvasHandleLayers.drawHandle(end, size: Self.size, hollow: true, in: ctx)
        }
        ctx.restoreGState()
    }
}

/// The point gestures of the Pointer and Subselect tools besides dragging (editing-paths.adoc,
/// "Selecting and moving points"; DRAW-025): kbd:[Option]-click on a selected point toggles it
/// between corner and curve, kbd:[Option]-drag from a selected point with a retracted handle
/// pulls that handle out, and *Smoother editing* chooses what a point drag previews.
@MainActor
enum PointEditing {
    /// *Smoother editing*: a point drag previews the whole path (on) or only the segments that
    /// meet the moved points (off).
    static var smoother: @MainActor () -> Bool = { true }

    /// Whether the point gestures edit `object`'s points: a path's, or a live rectangle's, ellipse's
    /// or polygon's, which the edit converts to a path first (D-078, `ShapeConversion`).
    static func editsPoints(of object: SceneObject) -> Bool {
        object.kind == .path || ShapeConversion.kinds.contains(object.kind)
    }

    /// The one selected point under `e` (view), with its object.
    static func pressedPoint(_ e: CanvasEvent, context: ToolContext) -> (object: SceneObject, contour: VectorContour, point: VectorPoint)? {
        guard let (id, sub) = context.selection.pick(at: e.viewPoint, viewport: context.viewport, subselect: true),
              case let .points(points)? = sub, points.count == 1, let reference = points.first,
              case let .points(selected)? = context.selection.selection.subSelection(of: id), selected.contains(reference),
              let object = context.document.object(for: id), editsPoints(of: object), let contour = object.path?.contour(reference.contour),
              let point = contour.drawn.first(where: { $0.id == reference.point }) else { return nil }
        return (object, contour, point)
    }

    /// kbd:[Option]-click on a selected point: a curve point becomes a corner, any other a curve.
    static func toggleCommand(at e: CanvasEvent, context: ToolContext) -> SetPointKind? {
        guard e.modifiers.contains(.option), let pressed = pressedPoint(e, context: context) else { return nil }
        return SetPointKind(node: pressed.object.id, points: [(pressed.contour.id, pressed.point.id)], kind: pressed.point.kind == .curve ? .corner : .curve)
    }

    /// kbd:[Option]-drag from a selected point with a retracted handle by `delta` (pasteboard):
    /// the retracted handle (the outgoing one when both are) drawn out to the pointer, the other
    /// following as the point's type says.
    static func extendCommand(from start: CanvasEvent, delta: Vector, context: ToolContext) -> SetHandles? {
        guard start.modifiers.contains(.option), let pressed = pressedPoint(start, context: context),
              pressed.point.inHandle == .zero || pressed.point.outHandle == .zero,
              let inverse = pressed.object.transform.inverted() else { return nil }
        let handle = inverse.apply(delta)
        let out = pressed.point.outHandle == .zero
        return SetHandles(node: pressed.object.id, contour: pressed.contour.id, point: pressed.point.id, in: out ? nil : handle, out: out ? handle : nil)
    }

    /// The preview of `path` whose points `moved` (ids) were moved: the whole path with smoother
    /// editing, else only the segments with a moved end.
    static func preview(_ path: VectorPath, moved: Set<OpID>, smoother: Bool) -> DisplayPath {
        guard !smoother else { return DocumentDisplayListBuilder.display(path) { _ in true }.path }
        var pieces: [VectorContour] = []
        for contour in path.contours {
            let drawn = contour.drawn
            let count = drawn.count
            guard count >= 2 else { continue }
            let segments = contour.closed ? count : count - 1
            for index in 0..<segments {
                let a = drawn[index], b = drawn[(index + 1) % count]
                guard moved.contains(a.id) || moved.contains(b.id) else { continue }
                pieces.append(VectorContour(points: [a, b]))
            }
        }
        return DocumentDisplayListBuilder.display(VectorPath(contours: pieces)) { _ in true }.path
    }
}
