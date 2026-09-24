import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The centre handles of the Bend, Duet and Transform effect selected in the Object panel, and
/// the Duet's axis arm (live-effects.adoc, "Controls"; FX-003): drawn on each selected object
/// that carries the effect, at its centre -- stored relative to the centre of the object's own
/// bounds, y up -- and dragged to move it.  Dragging the arm's end turns the Duet axis.  Every
/// drag writes on each move inside one undo group, so it is one undo step.
@MainActor
final class EffectCenterHandles: CanvasHandleLayer {
    /// How near a handle (view points) a press takes it.
    static let radius = 6.0
    static let size = 9.0
    /// The arm's length, view points.
    static let armLength = 40.0

    /// One handle on one object.
    struct Handle: Equatable {
        enum Part: Equatable {
            case center
            case axis
        }

        var node: OpID
        var row: AppearanceRow
        var kind: Wiretuner_Doc_V1_EffectKind
        var part: Part
        /// The object's own bounds in its local space (what centres are measured from).
        var reference: Rect
        /// Local → pasteboard.
        var transform: WTGeometry.AffineTransform
        /// The centre in local space.
        var center: Point
        /// The Duet axis, degrees counterclockwise.
        var axis: Double
    }

    let focus: InspectorFocus
    private(set) var dragging: Handle?
    private var wrote = false

    init(focus: InspectorFocus = .shared) {
        self.focus = focus
    }

    /// The effect handles of the focused row on every selected object.
    func handles(_ context: ToolContext) -> [Handle] {
        let document = context.document
        let selection = context.selection.selection
        let targets = AttributesListModel.targets(selection, in: document.state)
        guard let row = focus.row(for: targets), row.list == .effects else { return [] }
        let list = AttributesListModel(document: document, selection: selection)
        guard let item = list.item(row) else { return [] }
        return item.targets.flatMap { target in Self.handles(target, in: document) }
    }

    /// The handles of effect `target` on its object: its centre, and a Duet's axis arm.
    static func handles(_ target: AttributeTarget, in document: DocumentHandle) -> [Handle] {
        guard let entry = EffectReading.entries(target.node, in: document.state).first(where: { $0.row == target.row }), !entry.effect.hidden,
              let offset = centerOffset(entry.effect.settings),
              case .path(let item)? = document.object(for: SelectionID(target.node))?.item else { return [] }
        let reference = Self.ownBounds(item.path)
        let center = centerPoint(reference, offset: offset)
        let kind = entry.effect.settings.kind
        let handle = Handle(node: target.node, row: target.row, kind: kind, part: .center, reference: reference, transform: item.transform,
                            center: center, axis: entry.effect.settings.duet.axisAngle)
        guard kind == .duet else { return [handle] }
        var arm = handle
        arm.part = .axis
        return [handle, arm]
    }

    /// The tight bounds of a path in its own space (what effect centres are measured from).
    static func ownBounds(_ path: DisplayPath) -> Rect {
        path.contours.reduce(Rect.null) { $0.union($1.bounds) }
    }

    /// The stored centre of a kind with one (Bend, Duet, Transform).
    static func centerOffset(_ settings: Wiretuner_Doc_V1_EffectSettings) -> Point? {
        switch settings.kind {
        case .bend: Point(x: settings.bend.center.x, y: settings.bend.center.y)
        case .duet: Point(x: settings.duet.center.x, y: settings.duet.center.y)
        case .transform: Point(x: settings.transform.center.x, y: settings.transform.center.y)
        default: nil
        }
    }

    /// The local point `offset` (y up) from the centre of `reference`.
    static func centerPoint(_ reference: Rect, offset: Point) -> Point {
        let base = reference.isNull ? Point.zero : reference.center
        return Point(x: base.x + offset.x, y: base.y - offset.y)
    }

    /// The stored offset of the local point `point`.
    static func offset(_ reference: Rect, point: Point) -> Point {
        let base = reference.isNull ? Point.zero : reference.center
        return Point(x: point.x - base.x, y: base.y - point.y)
    }

    /// Where `handle` is drawn, view points.
    static func position(_ handle: Handle, viewport: Viewport) -> Point {
        let center = viewport.toView(handle.transform.apply(handle.center))
        guard handle.part == .axis else { return center }
        let radians = handle.axis * .pi / 180
        return Point(x: center.x + cos(radians) * armLength, y: center.y - sin(radians) * armLength)
    }

    // MARK: CanvasHandleLayer

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        // The arm's end first: it may sit over another object's centre.
        let all = handles(context).sorted { $0.part == .axis && $1.part == .center }
        guard let hit = all.first(where: { Self.position($0, viewport: context.viewport).distance(to: e.viewPoint) <= Self.radius }) else { return false }
        dragging = hit
        wrote = false
        context.document.beginGroup()
        return true
    }

    /// The command a drag of `handle` to `e` writes.
    static func command(dragging handle: Handle, to e: CanvasEvent, viewport: Viewport) -> any WTModel.Command {
        let pair = [(node: handle.node, row: handle.row)]
        if handle.part == .axis {
            let center = viewport.toView(handle.transform.apply(handle.center))
            let degrees = atan2(center.y - e.viewPoint.y, e.viewPoint.x - center.x) * 180 / .pi
            let snapped = e.modifiers.contains(.shift) ? (degrees / 15).rounded() * 15 : degrees
            return EditEffect(pair, label: "Rotate duet axis", fields: [EffectField.duet(3)]) { $0.duet.axisAngle = snapped }
        }
        let local = (handle.transform.inverted() ?? .identity).apply(e.pasteboardPoint)
        let offset = offset(handle.reference, point: local)
        let point = EffectEditorModel.point(offset.x, offset.y)
        switch handle.kind {
        case .duet: return EditEffect(pair, label: "Move duet center", fields: [EffectField.duet(2)]) { $0.duet.center = point }
        case .transform: return EditEffect(pair, label: "Move transform center", fields: [EffectField.transform(8)]) { $0.transform.center = point }
        default: return EditEffect(pair, label: "Move bend center", fields: [EffectField.bend(2)]) { $0.bend.center = point }
        }
    }

    func drag(_ e: CanvasEvent, context: ToolContext) {
        guard let dragging else { return }
        wrote = true
        context.commandSink.perform(Self.command(dragging: dragging, to: e, viewport: context.viewport))
    }

    func release(_ e: CanvasEvent, context: ToolContext) {
        drag(e, context: context)
        finish(context, undo: false)
    }

    func cancel(context: ToolContext) {
        finish(context, undo: wrote)
    }

    /// Ends the drag's undo group once its writes have landed; a cancelled drag is undone.
    private func finish(_ context: ToolContext, undo: Bool) {
        guard dragging != nil else { return }
        dragging = nil
        let document = context.document
        Task { @MainActor in
            await document.settle()
            document.endGroup()
            if undo { _ = await document.undo().value }
        }
    }

    func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext) {
        let accent = NSColor.systemOrange.cgColor
        ctx.setStrokeColor(accent)
        ctx.setFillColor(accent)
        ctx.setLineWidth(1)
        for handle in handles(context) {
            let at = Self.position(handle, viewport: viewport)
            if handle.part == .axis {
                let center = viewport.toView(handle.transform.apply(handle.center))
                ctx.strokeLineSegments(between: [center.cgPoint, at.cgPoint])
                CanvasHandleLayers.drawHandle(at, size: Self.size - 2, hollow: true, in: ctx)
            } else {
                CanvasHandleLayers.drawHandle(at, size: Self.size, in: ctx)
            }
        }
    }
}
