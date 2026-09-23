import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// A tool that draws by one drag (the Polygon, Spiral and Arc tools): the press point and the
/// pointer, the modifiers read at every event, kbd:[Space] held mid-drag repositioning the shape,
/// kbd:[Esc] abandoning it.  The shape is previewed in the overlay and created by one command on
/// mouse-up (`command()`), then selected.
@MainActor
class DragDrawingTool: Tool, SpaceDragging, ToolInfoPublishing {
    class var id: ToolID { "polygon" }
    var toolID: ToolID { Self.id }
    private(set) var context: ToolContext?
    /// The press point, moved while Space repositions.
    private(set) var anchor: Point?
    private(set) var pointer: Point?
    private(set) var modifiers: KeyModifiers = []
    private var reposition: (pointer: Point, anchor: Point)?

    var cursor: NSCursor { .crosshair }
    var isDragging: Bool { anchor != nil }
    var statusMessage: String { "" }

    var info: ToolInfo {
        guard let anchor, let pointer else { return ToolInfo() }
        return ToolInfo(delta: pointer - anchor)
    }

    /// The drawing settings in effect.
    var settings: DrawingSettings { context?.drawing() ?? DrawingSettings() }
    /// The layer new objects go on.
    var activeLayer: OpID? { context?.objectEditing?.activeLayer }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(statusMessage)
    }

    func deactivate() {
        cancel()
        context = nil
    }

    func mouseDown(_ e: CanvasEvent) {
        let point = snapped(e.pasteboardPoint)
        anchor = point
        pointer = point
        modifiers = e.modifiers
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard anchor != nil else { return }
        let point = snapped(e.pasteboardPoint)
        if let reposition { anchor = reposition.anchor + (point - reposition.pointer) }
        pointer = point
        modifiers = e.modifiers
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let command = command() else { return }
        let task = context.commandSink.perform(command)
        let selection = context.selection
        Task { @MainActor in
            guard let created = await task.value?.createdObjects.first else { return }
            selection.model.set(Selection([SelectionID(created)]))
        }
    }

    func flagsChanged(_ e: CanvasEvent) {
        guard anchor != nil else { return }
        modifiers = e.modifiers
    }

    func keyDown(_ e: NSEvent) -> Bool { false }

    func spaceChanged(down: Bool) {
        guard let anchor, let pointer else { return }
        reposition = down ? (pointer, anchor) : nil
    }

    func cancel() {
        anchor = nil
        pointer = nil
        reposition = nil
        modifiers = []
    }

    private func snapped(_ point: Point) -> Point {
        guard let context else { return point }
        return context.snapping.snap(point, viewport: context.viewport)
    }

    /// The command mouse-up performs; nil when the drag draws nothing.
    func command() -> (any WTModel.Command)? { nil }

    /// The outline the overlay previews, pasteboard space.
    var preview: DisplayPath? { nil }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let preview else { return }
        let path = CGMutablePath()
        SelectionOverlay.add(preview, transform: viewport.pasteboardToView, to: path)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.strokePath()
    }

    /// A new path from `path`'s contours, labelled `label`.
    func createPath(_ path: VectorPath, label: String) -> CreatePath? {
        guard path.isRenderable else { return nil }
        return CreatePath(label: label, contours: path.contours.map { NewContour(closed: $0.closed, points: $0.points) },
                          fillWhenOpen: settings.fillWhenOpen, layer: activeLayer)
    }
}

/// The Polygon tool (polygons-stars.adoc, DRAW-011): drag from the centre; the distance is the
/// radius and the direction the first vertex's angle, kbd:[Shift] constraining it to the constrain
/// angle and every 45° from it.  kbd:[Option] changes nothing (polygons always draw from the
/// centre).  The Polygon Tool sheet's settings (sides, star, automatic or manual points) apply.
@MainActor
final class PolygonTool: DragDrawingTool {
    override class var id: ToolID { "polygon" }
    static let minimumRadius = 1.0

    override var statusMessage: String { "Drag from the center to draw a polygon; Shift constrains the angle, Space moves it" }

    /// The polygon being drawn (local space: centre at the origin) and its centre.
    var shape: (shape: PolygonShape, center: Point)? {
        guard let anchor, let pointer else { return nil }
        let delta = pointer - anchor
        var angle = delta.angle
        if modifiers.contains(.shift) { angle = settings.constraint.snappedAngle(angle) }
        return (settings.tools.polygonShape(radius: delta.length, rotation: angle), anchor)
    }

    override func command() -> (any WTModel.Command)? {
        guard let shape, shape.shape.radius >= Self.minimumRadius else { return nil }
        return CreatePolygon(shape.shape, center: shape.center, layer: activeLayer)
    }

    override var preview: DisplayPath? {
        guard let shape else { return nil }
        return DocumentDisplayListBuilder.display(ShapeGeometry.polygonPath(shape.shape)) { _ in true }.path
            .applying(.translation(Vector(dx: shape.center.x, dy: shape.center.y)))
    }
}

/// The Spiral tool (spirals-arcs.adoc, DRAW-014): the drag maps to a centre and an outer end by
/// *Draw from* (kbd:[Option] always from the centre), kbd:[Shift] constrains the outer end to the
/// constrain angle and every 45°; the Spiral sheet's settings shape it.  One change "Draw spiral".
@MainActor
final class SpiralTool: DragDrawingTool {
    override class var id: ToolID { "spiral" }

    override var statusMessage: String { "Drag to draw a spiral; Option draws from the center, Shift constrains, Space moves it" }

    /// The spiral's centre and outer end for the drag.
    var ends: (center: Point, outer: Point)? {
        guard let anchor, let pointer else { return nil }
        let from = modifiers.contains(.option) ? .center : settings.tools.spiralDrawFrom
        var center: Point, outer: Point
        switch from {
        case .center:
            (center, outer) = (anchor, pointer)
        case .edge:
            (center, outer) = (pointer, anchor)
        case .corner:
            center = Point.lerp(anchor, pointer, 0.5)
            let radius = min(abs(pointer.x - anchor.x), abs(pointer.y - anchor.y)) / 2
            let direction = (pointer - center).lengthSquared > 0 ? (pointer - center).normalized : Vector(dx: 1, dy: 0)
            outer = center + direction * radius
        }
        if modifiers.contains(.shift) { outer = settings.constraint.constrain(outer, from: center) }
        return (center, outer)
    }

    var path: VectorPath? {
        guard let ends else { return nil }
        return ShapeGeometry.spiralPath(settings.tools.spiral, center: ends.center, outer: ends.outer)
    }

    override func command() -> (any WTModel.Command)? {
        path.flatMap { createPath($0, label: "Draw spiral") }
    }

    override var preview: DisplayPath? {
        path.map { DocumentDisplayListBuilder.display($0) { _ in true }.path }
    }
}

/// The Arc tool (spirals-arcs.adoc, DRAW-015): the drag is the arc's box; kbd:[Shift] makes it a
/// quarter circle, kbd:[Option] flips it, kbd:[Cmd] closes it and kbd:[Control] makes it concave,
/// whatever the Arc sheet says, applied live.  One change "Arc".
@MainActor
final class ArcTool: DragDrawingTool {
    override class var id: ToolID { "arc" }

    override var statusMessage: String { "Drag to draw an arc; Shift: quarter circle, Option: flipped, Command: closed, Control: concave" }

    var path: VectorPath? {
        guard let anchor, var pointer else { return nil }
        if modifiers.contains(.shift) {
            let d = pointer - anchor
            let side = max(abs(d.dx), abs(d.dy))
            pointer = anchor + Vector(dx: d.dx < 0 ? -side : side, dy: d.dy < 0 ? -side : side)
        }
        let options = settings.tools
        let path = ShapeGeometry.arcPath(from: anchor, to: pointer, open: options.arcOpen && !modifiers.contains(.command),
                                         flipped: options.arcFlipped || modifiers.contains(.option),
                                         concave: options.arcConcave || modifiers.contains(.control))
        return path.isRenderable ? path : nil
    }

    override func command() -> (any WTModel.Command)? {
        path.flatMap { createPath($0, label: "Arc") }
    }

    override var preview: DisplayPath? {
        path.map { DocumentDisplayListBuilder.display($0) { _ in true }.path }
    }
}

/// What the DRAW and OBJ tool tasks install in place of their stubs: the Polygon, Spiral and Arc
/// tools (DRAW-011/014/015), the Pencil (DRAW-017), the Bezigon (DRAW-022) and the Rotate, Scale,
/// Skew and Reflect tools (OBJ-032).
@MainActor
enum DrawingTools {
    static func descriptors() -> [ToolDescriptor] {
        func delivered(_ id: ToolID, _ make: @escaping @MainActor @Sendable () -> any Tool) -> ToolDescriptor {
            ToolCatalog.all.first { $0.id == id }!.delivering(make)
        }
        return [
            delivered(PolygonTool.id) { PolygonTool() },
            delivered(SpiralTool.id) { SpiralTool() },
            delivered(ArcTool.id) { ArcTool() },
            PencilTool.descriptor,
            PenTool.bezigonDescriptor,
        ] + [TransformKind.rotate, .scale, .skew, .reflect].map(TransformTool.descriptor)
    }

    static func install(into tools: ToolRegistry) {
        for descriptor in descriptors() { tools.replace(descriptor) }
    }
}
