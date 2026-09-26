import AppKit
import WTModel
import WTRender

/// The Eyedropper's colour leaving the canvas (applying-color.adoc, "The Eyedropper tool": "Drag to
/// the object, panel well, or Swatches panel"; COLOR-012's remainder): once a drag with a lifted
/// colour crosses the canvas's edge, it becomes an ordinary colour drag -- the `ColorRef` payload
/// and an `NSColor` -- so the Tools panel wells, the Swatches panel and every other colour drop
/// target take it by their own rules.  Nothing is written by the canvas; the drop is the change.
@MainActor
final class EyedropperDragOut: NSObject, NSDraggingSource {
    static let shared = EyedropperDragOut()
    /// Starts the AppKit dragging session (replaceable in tests, which have no mouse).
    var startSession: @MainActor (NSView, NSDraggingItem, NSEvent, NSDraggingSource) -> Void = { view, item, event, source in
        view.beginDraggingSession(with: [item], event: event, source: source)
    }
    /// The payload of the last drag that left a canvas.
    private(set) var payload: ColorRefPasteboard?

    /// The payload of `sample` lifted in `document`: a swatch travels as the swatch (with its
    /// tints as a library, for a drop in another document).
    static func payload(_ sample: EyedropperSample, in document: DocumentHandle) -> ColorRefPasteboard {
        ColorRefPasteboard(ref: sample.ref, list: SwatchList(document.state), document: document.id)
    }

    /// The pasteboard item a drag carries: the payload and, for other applications, its `NSColor`.
    static func item(_ payload: ColorRefPasteboard) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(payload.data(), forType: ColorDrag.type)
        if let foreign = ColorDrag.archived(payload.foreignColor) { item.setData(foreign, forType: .color) }
        return item
    }

    /// A drag of `window`'s Eyedropper that left the canvas at `event` becomes a colour drag; the
    /// tool's own drag ends without writing.  False when the Eyedropper is not dragging a colour.
    @discardableResult
    func begin(_ window: DocumentWindowController, event: NSEvent) -> Bool {
        guard let tool = window.toolManager.activeTool as? EyedropperTool, let sample = tool.sample, tool.isDragging else { return false }
        let payload = Self.payload(sample, in: window.documentHandle)
        self.payload = payload
        tool.cancel()
        // The session takes the mouse-up: the tool manager ends the press now.
        window.toolManager.mouseUp(window.canvas.canvasEvent(event))
        let item = NSDraggingItem(pasteboardWriter: Self.item(payload))
        let origin = window.canvas.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: origin.x - 8, y: origin.y - 8, width: 16, height: 16), contents: Self.chip(sample.color))
        startSession(window.canvas, item, event, self)
        return true
    }

    /// The dragged chip: a square of the colour.
    static func chip(_ color: RenderColor?) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            (color.map { NSColor(cgColor: $0.cgColor) ?? .clear } ?? .clear).setFill()
            rect.fill()
            NSColor.black.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }

    /// What a colour drag does wherever it lands: a copy.
    nonisolated static let operation: NSDragOperation = .copy

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operation
    }
}
