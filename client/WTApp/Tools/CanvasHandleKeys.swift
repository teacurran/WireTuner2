import WTGeometry
import WTModel

/// A handle layer whose handles take the keys an object takes (glyph-editing.adoc, "Components",
/// "Anchors"; FONT-012, FONT-013): with no object selected, the arrow keys move the handle last
/// pressed and kbd:[Delete] removes it.
@MainActor
protocol CanvasHandleKeys: AnyObject {
    /// Moves the picked handle by `delta` (pasteboard points); false when nothing is picked.
    func nudge(by delta: Vector, context: ToolContext) -> Bool
    /// What kbd:[Delete] removes, nil when nothing is picked.
    func deletionCommand(context: ToolContext) -> (any WTModel.Command)?
}

extension ToolManager {
    /// The picked handle's removal, when no object is selected.
    func handleDeletion() -> (any WTModel.Command)? {
        guard context.selection.model.isEmpty else { return nil }
        return handleLayers.lazy.compactMap { ($0 as? any CanvasHandleKeys)?.deletionCommand(context: self.context) }.first
    }

    /// An arrow key moves the picked handle when no object is selected.
    func nudgeHandle(by delta: Vector) -> Bool {
        guard context.selection.model.isEmpty else { return false }
        return handleLayers.contains { ($0 as? any CanvasHandleKeys)?.nudge(by: delta, context: context) == true }
    }
}
