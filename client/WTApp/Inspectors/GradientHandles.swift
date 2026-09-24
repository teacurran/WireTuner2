import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The handles of the selected objects' gradient fills on the canvas (gradients.adoc, "Gradient
/// types" and "Handles"; ATTR-026): a start point and one end point, or two for Radial and
/// Rectangle, in each visible Gradient fill's own set -- the fill selected in the Object panel in
/// full colour, the others dimmed -- hidden under Auto size.  Dragging the start moves the whole
/// gradient; an end changes its length and angle (kbd:[Shift]: 45° steps; kbd:[Option] on a
/// Radial or Rectangle end: both ends together).  A drag writes the ATOMIC `axis` on every move
/// inside one undo group: one undo step, one coalesced write.
@MainActor
final class GradientHandles: CanvasHandleLayer {
    static let radius = 6.0
    static let size = 8.0

    struct Handle: Equatable {
        enum Which: Equatable {
            case start, end, end2
        }

        var node: OpID
        var row: AppearanceRow
        var type: Wiretuner_Doc_V1_GradientType
        var point: Which
        var axis: Gradient.Axis
        /// Local → pasteboard.
        var transform: WTGeometry.AffineTransform
        /// The fill the Object panel is editing.
        var focused: Bool

        /// The handle's position in the fill's local space.
        var local: WTGeometry.Point {
            switch point {
            case .start: axis.start
            case .end: axis.end
            case .end2: axis.end2 ?? axis.end
            }
        }
    }

    let focus: InspectorFocus
    private(set) var dragging: Handle?
    private var wrote = false

    init(focus: InspectorFocus = .shared) {
        self.focus = focus
    }

    /// Every handle of every visible gradient fill of the selected objects.
    func handles(_ context: ToolContext) -> [Handle] {
        let document = context.document
        let selection = context.selection.selection
        let state = document.state
        let targets = AttributesListModel.targets(selection, in: state)
        let focusedRow = focus.row(for: targets)
        let focusedTargets = focusedRow.flatMap { AttributesListModel(document: document, selection: selection).item($0)?.targets } ?? []
        return targets.flatMap { node -> [Handle] in
            guard case .path(let item)? = document.object(for: SelectionID(node))?.item else { return [] }
            return AppearanceEditing.entries(node, in: state).flatMap { entry -> [Handle] in
                guard entry.kind == .fill(.gradient), !entry.hidden else { return [] }
                let focused = focusedTargets.contains(AttributeTarget(node: node, row: entry.row))
                return Self.handles(node: node, row: entry.row, gradient: entry.fill.settings.gradient, transform: item.transform, focused: focused)
            }
        }
    }

    /// The handles of one gradient fill; none under Auto size.
    static func handles(node: OpID, row: AppearanceRow, gradient: Wiretuner_Doc_V1_GradientFill, transform: WTGeometry.AffineTransform, focused: Bool) -> [Handle] {
        let normalized = GradientReading.normalized(gradient)
        guard normalized.behavior != .autoSize, let axis = normalized.axis else { return [] }
        let points: [Handle.Which] = axis.end2 == nil ? [.start, .end] : [.start, .end, .end2]
        return points.map { Handle(node: node, row: row, type: normalized.type, point: $0, axis: axis, transform: transform, focused: focused) }
    }

    static func position(_ handle: Handle, viewport: Viewport) -> WTGeometry.Point {
        viewport.toView(handle.transform.apply(handle.local))
    }

    /// The axis a drag of `handle` to the local point `to` gives.
    static func axis(dragging handle: Handle, to: WTGeometry.Point, modifiers: KeyModifiers) -> Gradient.Axis {
        var axis = handle.axis
        switch handle.point {
        case .start:
            let delta = to - axis.start
            return Gradient.Axis(start: to, end: axis.end + delta, end2: axis.end2.map { $0 + delta })
        case .end, .end2:
            let old = handle.local - axis.start
            var moved = to - axis.start
            if modifiers.contains(.shift) { moved = constrained(moved) }
            if handle.point == .end { axis.end = axis.start + moved } else { axis.end2 = axis.start + moved }
            // Option on a Radial or Rectangle end: the other end scales and turns with it.
            if modifiers.contains(.option), let end2 = handle.axis.end2 {
                let other = handle.point == .end ? end2 - axis.start : handle.axis.end - axis.start
                let scale = old.length > 0 ? moved.length / old.length : 1
                let turn = atan2(moved.dy, moved.dx) - atan2(old.dy, old.dx)
                let turned = Vector(dx: (other.dx * cos(turn) - other.dy * sin(turn)) * scale, dy: (other.dx * sin(turn) + other.dy * cos(turn)) * scale)
                if handle.point == .end { axis.end2 = axis.start + turned } else { axis.end = axis.start + turned }
            }
            return axis
        }
    }

    /// `vector` turned to the nearest 45° step, its length kept.
    static func constrained(_ vector: Vector) -> Vector {
        let step = Double.pi / 4
        let angle = (atan2(vector.dy, vector.dx) / step).rounded() * step
        return Vector(dx: cos(angle) * vector.length, dy: sin(angle) * vector.length)
    }

    static func command(dragging handle: Handle, to e: CanvasEvent) -> any WTModel.Command {
        let local = (handle.transform.inverted() ?? .identity).apply(e.pasteboardPoint)
        let axis = axis(dragging: handle, to: local, modifiers: e.modifiers)
        return EditGradient.axis([(node: handle.node, row: handle.row)], start: axis.start, end: axis.end, end2: axis.end2)
    }

    // MARK: CanvasHandleLayer

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        // The fill being edited wins where handles overlap.
        let all = handles(context).sorted { $0.focused && !$1.focused }
        guard let hit = all.first(where: { Self.position($0, viewport: context.viewport).distance(to: e.viewPoint) <= Self.radius }) else { return false }
        dragging = hit
        wrote = false
        context.document.beginGroup()
        return true
    }

    func drag(_ e: CanvasEvent, context: ToolContext) {
        guard let dragging else { return }
        wrote = true
        context.commandSink.perform(Self.command(dragging: dragging, to: e))
    }

    func release(_ e: CanvasEvent, context: ToolContext) {
        drag(e, context: context)
        finish(context, undo: false)
    }

    func cancel(context: ToolContext) {
        finish(context, undo: wrote)
    }

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
        let accent = NSColor.controlAccentColor
        ctx.setLineWidth(1)
        for handle in handles(context) {
            let color = (handle.focused ? accent : accent.withAlphaComponent(0.35)).cgColor
            ctx.setStrokeColor(color)
            ctx.setFillColor(color)
            let at = Self.position(handle, viewport: viewport)
            if handle.point == .start {
                CanvasHandleLayers.drawHandle(at, size: Self.size, in: ctx)
            } else {
                let start = viewport.toView(handle.transform.apply(handle.axis.start))
                ctx.strokeLineSegments(between: [start.cgPoint, at.cgPoint])
                CanvasHandleLayers.drawHandle(at, size: Self.size, hollow: true, in: ctx)
            }
        }
    }
}
