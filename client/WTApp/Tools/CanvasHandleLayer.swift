import AppKit
import WTGeometry
import WTRender

/// Handles a feature draws on the canvas over the selection tools, pressed before the tool sees
/// the press: the centre handles and Duet axis of the effect selected in the Object panel
/// (live-effects.adoc, "Controls") and the handles of the selected objects' gradient fills
/// (gradients.adoc, "Handles"), and the lens centerpoints (ATTR-022).  A drag is one undo step;
/// the tool never hears it.
@MainActor
protocol CanvasHandleLayer: AnyObject {
    /// Takes a press on one of the layer's handles (true) or leaves it to the tool.
    func press(_ e: CanvasEvent, context: ToolContext) -> Bool
    func drag(_ e: CanvasEvent, context: ToolContext)
    func release(_ e: CanvasEvent, context: ToolContext)
    /// kbd:[Esc] during the drag: what was written is undone with the drag's undo step.
    func cancel(context: ToolContext)
    /// Draws the handles in view points.
    func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext)
}

/// The layers every canvas has, and the tools they work with.
@MainActor
enum CanvasHandleLayers {
    /// The tools the handles show with: the Pointer and the Subselect tool.
    static let tools: Set<ToolID> = [.pointer, "subselect"]

    /// A fresh set for one canvas.
    static func standard() -> [any CanvasHandleLayer] {
        [EffectCenterHandles(), GradientHandles(), TextPathHandle(), LensCenterHandles()]
    }

    /// A round handle of `size` view points at `point`: filled, or outlined when `hollow`.
    static func drawHandle(_ point: Point, size: Double, hollow: Bool = false, in ctx: CGContext) {
        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        if hollow {
            ctx.strokeEllipse(in: rect)
        } else {
            ctx.fillEllipse(in: rect)
        }
    }
}
