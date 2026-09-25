import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// One point of an envelope's outline changed: its anchor and, when given, its handles in drawing
/// orientation (path-effects.adoc, "Envelopes": the envelope is edited as any path, its contour
/// merging point by point).  Written to the envelope's own `contours` registers (`EnvelopeFields`),
/// in the envelope's space; a handle set by hand leaves *Automatic*.  Labelled "Move Point" or
/// "Move Handle", as on a path.
struct EditEnvelopePoint: WTModel.Command {
    let node: OpID
    let contour: OpID
    let point: OpID
    var anchor: Point?
    var inHandle: Vector?
    var outHandle: Vector?

    var label: String { anchor != nil ? "Move Point" : "Move Handle" }

    enum Failure: Error, Equatable {
        case notAnEnvelope
        case noSuchPoint
        case invalidValue
    }

    static func proto(_ point: Point) -> Wiretuner_Doc_V1_Point {
        var value = Wiretuner_Doc_V1_Point()
        value.x = point.x
        value.y = point.y
        return value
    }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.nodeKind(node) == .envelope, state.isLive(node) else { throw Failure.notAnEnvelope }
        guard let stored = EnvelopeReading.path(node, in: state).contours.first(where: { $0.id == contour }),
              let current = stored.points.first(where: { $0.id == point }) else { throw Failure.noSuchPoint }
        let values = [anchor.map { [$0.x, $0.y] }, inHandle.map { [$0.dx, $0.dy] }, outHandle.map { [$0.dx, $0.dy] }].compactMap { $0 }.flatMap { $0 }
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { throw Failure.invalidValue }
        var value = Wiretuner_Doc_V1_PathPoint()
        var fields: [RegisterPath] = []
        let base = EnvelopeFields.points(contour).element(point)
        if let anchor {
            value.anchor = Self.proto(anchor)
            fields.append(base.child(2))
        }
        // Stored in/out are the drawing orientation's out/in on a reversed contour.
        let (arriving, leaving) = stored.reversed ? (outHandle, inHandle) : (inHandle, outHandle)
        if let arriving {
            value.inHandle = Self.proto(Point(x: arriving.dx, y: arriving.dy))
            fields.append(base.child(3))
        }
        if let leaving {
            value.outHandle = Self.proto(Point(x: leaving.dx, y: leaving.dy))
            fields.append(base.child(4))
        }
        if (inHandle != nil || outHandle != nil) && current.automatic {
            value.automatic = false
            fields.append(base.child(6))
        }
        var props = Wiretuner_Doc_V1_NodeProps()
        var written = Wiretuner_Doc_V1_Contour()
        written.points = [value]
        props.envelope.contours = [written]
        builder.append(Ops.set(node, fields, values: props))
    }
}

/// The envelope outline's points and handles on the canvas (path-effects.adoc, "Envelopes": "Edit
/// the envelope as you would any path -- drag its points and handles"; FX-039's remainder): drawn
/// over every selected envelope with the Pointer and Subselect tools, the outline dashed, each
/// anchor a square and each curve handle a dot on its line.  Dragging an anchor or a handle
/// previews the outline and writes one change on release (`EditEnvelopePoint`); kbd:[Shift]
/// constrains the drag to 45° steps; kbd:[Esc] abandons it.
@MainActor
final class EnvelopeOutlineHandles: CanvasHandleLayer {
    /// How near a point or handle (view points) a press takes it.
    static let radius = 5.0
    static let size = 6.0

    /// What a press took.
    enum Part: Equatable {
        case anchor
        case inHandle
        case outHandle
    }

    /// One selected envelope's outline: its first live contour in drawing order, and its space to
    /// the pasteboard.
    struct Outline: Equatable {
        let node: OpID
        let contour: VectorContour
        let transform: WTGeometry.AffineTransform

        init?(_ node: OpID, in state: EngineState) {
            guard state.nodeKind(node) == .envelope, state.isLive(node), let contour = EnvelopeReading.contour(node, in: state) else { return nil }
            self.node = node
            self.contour = contour
            transform = Objects.pasteboardTransform(of: node, in: state)
        }

        /// The outline with the point `point`'s `part` moved to `location` (envelope space).
        func moving(_ point: OpID, _ part: Part, to location: Point) -> [VectorPoint] {
            contour.drawn.map { drawn in
                guard drawn.id == point else { return drawn }
                var moved = drawn
                switch part {
                case .anchor: moved.anchor = location
                case .inHandle: moved.inHandle = location - drawn.anchor
                case .outHandle: moved.outHandle = location - drawn.anchor
                }
                return moved
            }
        }
    }

    struct Drag: Equatable {
        let outline: Outline
        /// The point pressed, as it was.
        let original: VectorPoint
        let part: Part
        /// Pasteboard → envelope space.
        let inverse: WTGeometry.AffineTransform
        let start: Point
        var current: Point
        var constrained = false

        var point: OpID { original.id }

        /// Where the dragged part is, envelope space (kbd:[Shift]: the drag in 45° steps).
        var location: Point {
            var delta = current - start
            if constrained { delta = AngleConstraint.degrees(0).constrain(delta) }
            let origin: Point
            switch part {
            case .anchor: origin = original.anchor
            case .inHandle: origin = original.anchor + original.inHandle
            case .outHandle: origin = original.anchor + original.outHandle
            }
            return origin + inverse.apply(delta)
        }
    }

    private(set) var drag: Drag?

    init() {}

    func outlines(_ context: ToolContext) -> [Outline] {
        let state = context.document.state
        return context.selection.selection.ids.compactMap { id in
            guard context.document.object(for: id)?.isEffectivelyLocked != true else { return nil }
            return Outline(id.opID, in: state)
        }
    }

    /// The part of `outline` under view point `point`: anchors before handles.
    static func hit(_ outline: Outline, at point: Point, viewport: Viewport) -> (point: VectorPoint, part: Part)? {
        let toView = outline.transform.concatenating(viewport.pasteboardToView)
        for drawn in outline.contour.drawn where toView.apply(drawn.anchor).distance(to: point) <= radius {
            return (drawn, .anchor)
        }
        for drawn in outline.contour.drawn {
            if drawn.inHandle != .zero, toView.apply(drawn.anchor + drawn.inHandle).distance(to: point) <= radius { return (drawn, .inHandle) }
            if drawn.outHandle != .zero, toView.apply(drawn.anchor + drawn.outHandle).distance(to: point) <= radius { return (drawn, .outHandle) }
        }
        return nil
    }

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        for outline in outlines(context) {
            guard let (point, part) = Self.hit(outline, at: e.viewPoint, viewport: context.viewport), let inverse = outline.transform.inverted() else { continue }
            drag = Drag(outline: outline, original: point, part: part, inverse: inverse, start: e.pasteboardPoint, current: e.pasteboardPoint,
                        constrained: e.modifiers.contains(.shift))
            return true
        }
        return false
    }

    func drag(_ e: CanvasEvent, context: ToolContext) {
        guard drag != nil else { return }
        drag?.current = e.pasteboardPoint
        drag?.constrained = e.modifiers.contains(.shift)
        context.host.setNeedsOverlayDisplay()
    }

    /// The change a finished drag writes; nil when it did not move.
    static func command(_ drag: Drag) -> EditEnvelopePoint? {
        guard drag.current != drag.start else { return nil }
        let location = drag.location, original = drag.original
        var command = EditEnvelopePoint(node: drag.outline.node, contour: drag.outline.contour.id, point: drag.point)
        switch drag.part {
        case .anchor: command.anchor = location
        case .inHandle: command.inHandle = location - original.anchor
        case .outHandle: command.outHandle = location - original.anchor
        }
        return command
    }

    func release(_ e: CanvasEvent, context: ToolContext) {
        guard var drag else { return }
        drag.current = e.pasteboardPoint
        drag.constrained = e.modifiers.contains(.shift)
        self.drag = nil
        if let command = Self.command(drag) { context.commandSink.perform(command) }
        context.host.setNeedsOverlayDisplay()
    }

    func cancel(context: ToolContext) {
        drag = nil
        context.host.setNeedsOverlayDisplay()
    }

    /// The outline as drawn: `points` (envelope space, drawing order) through `transform`.
    static func outlinePath(_ points: [VectorPoint], closed: Bool, transform: WTGeometry.AffineTransform) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: transform.apply(first.anchor).cgPoint)
        let count = closed ? points.count : points.count - 1
        for index in 0..<count {
            let from = points[index], to = points[(index + 1) % points.count]
            path.addCurve(to: transform.apply(to.anchor).cgPoint, control1: transform.apply(from.anchor + from.outHandle).cgPoint,
                          control2: transform.apply(to.anchor + to.inHandle).cgPoint)
        }
        if closed { path.closeSubpath() }
        return path
    }

    func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext) {
        let accent = NSColor.controlAccentColor.cgColor
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(accent)
        ctx.setFillColor(accent)
        ctx.setLineWidth(1)
        for outline in outlines(context) {
            let toView = outline.transform.concatenating(viewport.pasteboardToView)
            var points = outline.contour.drawn
            if let drag, drag.outline.node == outline.node {
                points = outline.moving(drag.point, drag.part, to: drag.location)
            }
            ctx.setLineDash(phase: 0, lengths: [3, 2])
            ctx.addPath(Self.outlinePath(points, closed: outline.contour.closed, transform: toView))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            for point in points {
                let anchor = toView.apply(point.anchor)
                for handle in [point.inHandle, point.outHandle] where handle != .zero {
                    let end = toView.apply(point.anchor + handle)
                    ctx.move(to: anchor.cgPoint)
                    ctx.addLine(to: end.cgPoint)
                    ctx.strokePath()
                    CanvasHandleLayers.drawHandle(end, size: Self.size - 2, in: ctx)
                }
                ctx.fill(CGRect(x: anchor.x - Self.size / 2, y: anchor.y - Self.size / 2, width: Self.size, height: Self.size))
            }
        }
    }
}
