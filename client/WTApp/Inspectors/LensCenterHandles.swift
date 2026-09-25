import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The lens centerpoint handle (fill-attributes.adoc, "Lens fills", *Centerpoint*; ATTR-022): drawn
/// over the Pointer and Subselect tools on each selected object whose lens fill shows its
/// centerpoint -- at `centerpoint` in the object's own space, or the centre of its bounds while
/// that is unset -- and hidden when the object is deselected.  Dragging it writes `centerpoint` on
/// each move inside one undo group, so the drag is one undo step; kbd:[Shift]-click clears it (the
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
    private var wrote = false

    init() {}

    /// The handles of every selected object's shown lens centerpoints.
    func handles(_ context: ToolContext) -> [Handle] {
        let document = context.document
        return context.selection.selection.ids.flatMap { Self.handles($0.opID, in: document) }
    }

    static func handles(_ node: OpID, in document: DocumentHandle) -> [Handle] {
        guard case .path(let item)? = document.object(for: SelectionID(node))?.item else { return [] }
        let bounds = EffectCenterHandles.ownBounds(item.path)
        return AppearanceEditing.entries(node, in: document.state).compactMap { entry in
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
        ctx.setStrokeColor(NSColor.systemTeal.cgColor)
        ctx.setLineWidth(1.5)
        for handle in handles(context) {
            let at = Self.position(handle, viewport: viewport)
            CanvasHandleLayers.drawHandle(at, size: Self.size, hollow: true, in: ctx)
            ctx.strokeLineSegments(between: [CGPoint(x: at.x - 3, y: at.y), CGPoint(x: at.x + 3, y: at.y), CGPoint(x: at.x, y: at.y - 3), CGPoint(x: at.x, y: at.y + 3)])
        }
    }
}
