import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Rotate, Scale, Skew and Reflect tools (transforming.adoc, OBJ-032): the press sets the
/// centre, the drag sets the amount relative to where it first leaves the centre, kbd:[Shift]
/// constrains it (rotation and the reflection axis to the constrain angle and every 45°, scaling to
/// uniform, skewing to one axis), kbd:[Option] transforms a copy, kbd:[Esc] abandons it.  The
/// selected objects' outlines preview the result; mouse-up performs one `TransformObjects` (or,
/// for selected points, one `TransformPoints` per path).
@MainActor
final class TransformTool: Tool {
    let kind: TransformKind
    let toolID: ToolID
    static var id: ToolID { "rotate" }
    /// The smallest scale factor a drag writes (transforming.adoc: "scale is clamped to ±0.01%").
    static let minimumScale = 0.0001
    /// Drags shorter than this from the centre (view points) set no reference yet.
    static let referenceThreshold = 3.0

    static func descriptor(_ kind: TransformKind) -> ToolDescriptor {
        let id = ToolID(kind.rawValue)
        return ToolCatalog.all.first { $0.id == id }!.delivering { TransformTool(kind) }
    }

    private var context: ToolContext?
    private(set) var center: CanvasEvent?
    private(set) var reference: Point?
    private(set) var current: CanvasEvent?

    init(_ kind: TransformKind) {
        self.kind = kind
        toolID = ToolID(kind.rawValue)
    }

    var cursor: NSCursor { .crosshair }

    var statusMessage: String {
        "Press at the center, then drag to \(kind.title.lowercased()); Shift constrains, Option transforms a copy"
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
        center = e
        current = e
        reference = nil
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard let center else { return }
        current = e
        if reference == nil, e.viewPoint.distance(to: center.viewPoint) >= Self.referenceThreshold { reference = e.pasteboardPoint }
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let command = command() else { return }
        let task = context.commandSink.perform(command)
        guard let transform = command as? TransformObjects, transform.copies > 0 else { return }
        let model = context.selection.model
        Task { @MainActor in
            guard let created = await task.value?.createdRoots, !created.isEmpty else { return }
            model.set(Selection(created.map { SelectionID($0) }))
        }
    }

    func flagsChanged(_ e: CanvasEvent) {
        guard let current else { return }
        self.current = current.with(modifiers: e.modifiers, timestamp: e.timestamp)
    }

    func keyDown(_ e: NSEvent) -> Bool { false }

    func cancel() {
        center = nil
        current = nil
        reference = nil
    }

    /// The pasteboard-space matrix of the drag so far (about the origin; the centre is applied by
    /// the command); nil before the drag leaves the centre.
    var matrix: WTGeometry.AffineTransform? {
        guard let center, let reference, let current, let context else { return nil }
        let c = center.pasteboardPoint, from = reference - c, to = current.pasteboardPoint - c
        let constrained = current.modifiers.contains(.shift)
        let constraint = context.drawing().constraint
        switch kind {
        case .rotate:
            var angle = to.angle - from.angle
            if constrained { angle = constraint.snappedRotation(angle) }
            return .rotation(radians: angle)
        case .scale:
            func factor(_ a: Double, _ b: Double) -> Double {
                guard a != 0 else { return 1 }
                let value = b / a
                return abs(value) < Self.minimumScale ? (value < 0 ? -Self.minimumScale : Self.minimumScale) : value
            }
            var sx = factor(from.dx, to.dx), sy = factor(from.dy, to.dy)
            if constrained {
                let uniform = max(abs(sx), abs(sy))
                (sx, sy) = (uniform, uniform)
            }
            return .scale(x: sx, y: sy)
        case .skew:
            var kx = from.dy != 0 ? (to.dx - from.dx) / from.dy : 0
            var ky = from.dx != 0 ? (to.dy - from.dy) / from.dx : 0
            if constrained { abs(kx) >= abs(ky) ? (ky = 0) : (kx = 0) }
            return .shear(x: kx, y: ky)
        case .reflect:
            var angle = to.angle
            if constrained { angle = constraint.snappedAngle(angle) }
            let cosine = cos(2 * angle), sine = sin(2 * angle)
            return WTGeometry.AffineTransform(a: cosine, b: sine, c: sine, d: -cosine, tx: 0, ty: 0)
        case .move:
            return .translation(to - from)
        }
    }

    /// The command the drag so far performs.
    func command() -> (any WTModel.Command)? {
        guard let context, let matrix, let center, matrix.isInvertible else { return nil }
        let selection = context.selection.selection
        let about = center.pasteboardPoint
        var pointCommands: [any WTModel.Command] = []
        for id in selection.ids {
            if case let .points(points)? = selection.subSelection(of: id), !points.isEmpty {
                pointCommands.append(TransformPoints(node: id.opID, points: points.sorted().map { ($0.contour, $0.point) }, matrix: matrix, about: about, kind: kind))
            }
        }
        if !pointCommands.isEmpty { return CommandBatch(pointCommands[0].label, pointCommands) }
        let nodes = selection.ids.map(\.opID)
        guard !nodes.isEmpty else { return nil }
        let copy = current?.modifiers.contains(.option) == true
        return TransformObjects(nodes, matrix: matrix, about: about, kind: kind, copies: copy ? 1 : 0)
    }

    /// The selected objects' outlines as the drag would leave them, pasteboard space.
    var preview: [DisplayPath] {
        guard let context, let matrix, let center else { return [] }
        let m = TransformObjects([], matrix: matrix, about: center.pasteboardPoint, kind: kind).effectiveMatrix
        return context.selection.selection.ids.compactMap { id in
            guard let object = context.document.object(for: id) else { return nil }
            guard let path = object.path else { return object.bounds.map { DisplayPath(rect: $0).applying(m) } }
            return DocumentDisplayListBuilder.display(path) { _ in true }.path.applying(object.transform.concatenating(m))
        }
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let center else { return }
        let toView = viewport.pasteboardToView
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        let c = toView.apply(center.pasteboardPoint)
        ctx.strokeEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
        let path = CGMutablePath()
        for outline in preview { SelectionOverlay.add(outline, transform: toView, to: path) }
        ctx.addPath(path)
        ctx.strokePath()
    }
}
