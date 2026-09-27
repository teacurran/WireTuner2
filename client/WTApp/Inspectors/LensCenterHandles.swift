import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The lens centerpoint handle (fill-attributes.adoc, "Lens fills", *Centerpoint*; ATTR-022): drawn
/// over the Pointer and Subselect tools on each selected object whose lens fill shows its
/// centerpoint -- at `centerpoint` in the object's own space, or the centre of its bounds while
/// that is unset -- and hidden when the object is deselected.  Dragging it previews on the canvas
/// and writes `centerpoint` once on mouse-up (D-076), so the drag is one undo step; kbd:[Shift]-click clears it (the
/// handle returns to the centre).
@MainActor
final class LensCenterHandles: CanvasHandleLayer {
    /// How near the handle (view points) a press takes it.
    static let radius = 6.0
    static let size = 9.0

    /// One handle: a lens fill row on one object.
    struct Handle: Equatable {
        var node: OpID
        var row: AppearanceRow
        /// Local → pasteboard.
        var transform: WTGeometry.AffineTransform
        /// The handle in local space.
        var center: Point
    }

    private(set) var dragging: Handle?
    /// The drag's preview and its one change (D-076).
    private var edit: GestureEdit?

    init() {}

    /// The handles of every selected object's shown lens centerpoints.
    func handles(_ context: ToolContext) -> [Handle] {
        let document = context.document
        return context.selection.selection.ids.flatMap { Self.handles($0.opID, in: document) }
    }

    static func handles(_ node: OpID, in document: DocumentHandle) -> [Handle] {
        guard case .path(let item)? = document.object(for: SelectionID(node))?.item else { return [] }
        let bounds = EffectCenterHandles.ownBounds(item.path)
        return AppearanceEditing.entries(node, in: document.shownState).compactMap { entry in
            let lens = entry.fill.settings.lens
            guard entry.row.list == .fills, !entry.hidden, entry.fill.settings.kind == .lens, lens.centerpointShown else { return nil }
            let center = lens.hasCenterpoint ? Point(x: lens.centerpoint.x, y: lens.centerpoint.y) : (bounds.isNull ? .zero : bounds.center)
            return Handle(node: node, row: entry.row, transform: item.transform, center: center)
        }
    }

    static func position(_ handle: Handle, viewport: Viewport) -> Point {
        viewport.toView(handle.transform.apply(handle.center))
    }

    /// The command a drag of `handle` to `e` writes: the local point under the pointer.
    static func command(dragging handle: Handle, to e: CanvasEvent) -> any WTModel.Command {
        let local = (handle.transform.inverted() ?? .identity).apply(e.pasteboardPoint)
        return EditAttribute.fill([(handle.node, handle.row)], "Move lens centerpoint", [AttributeFields.Lens.centerpoint]) {
            $0.lens.centerpoint = .with { point in
                point.x = local.x
                point.y = local.y
            }
        }
    }

    /// kbd:[Shift]-click: `centerpoint` cleared, so the lens looks from the object's centre again.
    static func reset(_ handle: Handle) -> any WTModel.Command {
        EditAttribute.fill([(handle.node, handle.row)], "Reset lens centerpoint", [AttributeFields.Lens.centerpoint]) { _ in }
    }

    // MARK: CanvasHandleLayer

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        guard let hit = handles(context).first(where: { Self.position($0, viewport: context.viewport).distance(to: e.viewPoint) <= Self.radius }) else { return false }
        if e.modifiers.contains(.shift) {
            context.commandSink.perform(Self.reset(hit))
            return true
        }
        dragging = hit
        edit = GestureEdit(document: context.document)
        return true
    }

    func drag(_ e: CanvasEvent, context: ToolContext) {
        guard let dragging else { return }
        edit?.update(Self.command(dragging: dragging, to: e))
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
        ctx.setStrokeColor(NSColor.systemTeal.cgColor)
        ctx.setLineWidth(1.5)
        for handle in handles(context) {
            let at = Self.position(handle, viewport: viewport)
            CanvasHandleLayers.drawHandle(at, size: Self.size, hollow: true, in: ctx)
            ctx.strokeLineSegments(between: [CGPoint(x: at.x - 3, y: at.y), CGPoint(x: at.x + 3, y: at.y), CGPoint(x: at.x, y: at.y - 3), CGPoint(x: at.x, y: at.y + 3)])
        }
    }
}
