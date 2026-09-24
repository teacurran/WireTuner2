import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Rectangle, Ellipse and Line tools (rectangles-ellipses-lines.adoc, DRAW-007): drag from one
/// corner (or end) to the other; kbd:[Shift] constrains (square, circle, the constrain angle and
/// every 45° for a line), kbd:[Option] draws from the centre, and both can change at any moment
/// before mouse-up; kbd:[Space] held mid-drag repositions the shape instead of sizing it; kbd:[Esc]
/// abandons it.  The shape is previewed in the overlay and created by one command on mouse-up with
/// the default attributes, then selected; a drag under 1 pt creates nothing.
///
/// Deviation: the spec creates the node on mouse-down and writes `size` per drag event, undoing a
/// drag under 1 pt locally; the tools follow client.adoc's "preview during a drag and emit exactly
/// one change on mouse-up" instead, which gives the same undo step and outbox (nothing for a tiny
/// drag) without creating and undoing a node.
@MainActor
class ShapeDragTool: Tool, SpaceDragging, ToolInfoPublishing {
    /// The smallest shape (points) a drag creates.
    static let minimumSize = 1.0

    enum Shape {
        case rectangle, ellipse, line
    }

    class var id: ToolID { .rectangle }
    let shape: Shape
    private(set) var context: ToolContext?
    /// The press point (after snapping), moved while Space repositions.
    private(set) var anchor: Point?
    /// The latest pointer, pasteboard space.
    private(set) var pointer: Point?
    private(set) var modifiers: KeyModifiers = []
    /// While Space is held: where the pointer and anchor were when it went down.
    private var reposition: (pointer: Point, anchor: Point)?

    init(shape: Shape) {
        self.shape = shape
    }

    var toolID: ToolID { Self.id }
    var cursor: NSCursor { .crosshair }
    var isDragging: Bool { anchor != nil }

    /// The Info toolbar's readout while dragging: the drag's delta.
    var info: ToolInfo {
        guard let anchor, let pointer else { return ToolInfo() }
        return ToolInfo(delta: pointer - anchor)
    }

    var statusMessage: String {
        let noun = switch shape {
        case .rectangle: "a rectangle"
        case .ellipse: "an ellipse"
        case .line: "a line"
        }
        return "Drag to draw \(noun); Shift constrains, Option draws from the center, Space moves it"
    }

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
        if let reposition {
            anchor = reposition.anchor + (point - reposition.pointer)
        }
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

    /// Shift or Option pressed or released mid-drag: the same pointer, a new constraint.
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

    private var constrainAngle: Double { context?.drawing().constrainAngle ?? 0 }

    // MARK: Geometry

    /// The rectangle or ellipse being drawn: its size and the transform placing its local frame
    /// (top-left at the origin), rotated by the constrain angle; nil while nothing is dragged.
    var frame: (size: Size, transform: WTGeometry.AffineTransform)? {
        guard let anchor, let pointer else { return nil }
        return Self.frame(anchor: anchor, pointer: pointer, modifiers: modifiers, constrainAngle: constrainAngle)
    }

    static func frame(anchor: Point, pointer: Point, modifiers: KeyModifiers, constrainAngle: Double) -> (size: Size, transform: WTGeometry.AffineTransform) {
        let angle = constrainAngle * .pi / 180
        var d = (pointer - anchor).rotated(by: -angle)
        if modifiers.contains(.shift) {
            let side = max(abs(d.dx), abs(d.dy))
            d = Vector(dx: d.dx < 0 ? -side : side, dy: d.dy < 0 ? -side : side)
        }
        let corner = modifiers.contains(.option) ? Vector(dx: -abs(d.dx), dy: -abs(d.dy)) : Vector(dx: min(d.dx, 0), dy: min(d.dy, 0))
        let size = modifiers.contains(.option) ? Size(width: 2 * abs(d.dx), height: 2 * abs(d.dy)) : Size(width: abs(d.dx), height: abs(d.dy))
        let transform = WTGeometry.AffineTransform.translation(corner)
            .concatenating(.rotation(radians: angle))
            .concatenating(.translation(Vector(dx: anchor.x, dy: anchor.y)))
        return (size, transform)
    }

    /// The line being drawn, start to end; nil while nothing is dragged.
    var line: (start: Point, end: Point)? {
        guard let anchor, let pointer else { return nil }
        return Self.line(anchor: anchor, pointer: pointer, modifiers: modifiers, constrainAngle: constrainAngle)
    }

    static func line(anchor: Point, pointer: Point, modifiers: KeyModifiers, constrainAngle: Double) -> (start: Point, end: Point) {
        let end = modifiers.contains(.shift) ? AngleConstraint.degrees(constrainAngle).constrain(pointer, from: anchor) : pointer
        let start = modifiers.contains(.option) ? anchor - (end - anchor) : anchor
        return (start, end)
    }

    /// The command mouse-up performs; nil for a drag under 1 pt.
    func command() -> (any WTModel.Command)? {
        switch shape {
        case .line:
            guard let line, line.start.distance(to: line.end) >= Self.minimumSize else { return nil }
            var command = CreatePath.line(from: line.start, to: line.end, appearance: context?.newObjectAppearance() ?? Appearances.standard)
            command.fillWhenOpen = context?.drawing().fillWhenOpen ?? false
            return command
        case .rectangle, .ellipse:
            guard let frame, frame.size.width >= Self.minimumSize, frame.size.height >= Self.minimumSize else { return nil }
            return CreateShape(shape == .rectangle ? .rectangle(CornerRadii()) : .ellipse, size: frame.size, transform: frame.transform,
                               appearance: context?.newObjectAppearance() ?? Appearances.standard)
        }
    }

    /// The outline the overlay previews, pasteboard space.
    var preview: DisplayPath? {
        switch shape {
        case .line:
            guard let line else { return nil }
            return DisplayPath(polygon: [line.start, line.end], closed: false)
        case .rectangle, .ellipse:
            guard let frame else { return nil }
            let path = shape == .rectangle ? ShapeGeometry.rectPath(size: frame.size) : ShapeGeometry.ellipsePath(size: frame.size)
            return DocumentDisplayListBuilder.display(path) { _ in true }.path.applying(frame.transform)
        }
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let preview else { return }
        let path = CGMutablePath()
        SelectionOverlay.add(preview, transform: viewport.pasteboardToView, to: path)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.strokePath()
    }
}

/// The Rectangle tool.
@MainActor
final class RectangleTool: ShapeDragTool {
    override class var id: ToolID { .rectangle }
    init() { super.init(shape: .rectangle) }
}

/// The Ellipse tool.
@MainActor
final class EllipseTool: ShapeDragTool {
    override class var id: ToolID { .ellipse }
    init() { super.init(shape: .ellipse) }
}

/// The Line tool.
@MainActor
final class LineTool: ShapeDragTool {
    override class var id: ToolID { .line }
    init() { super.init(shape: .line) }
}
