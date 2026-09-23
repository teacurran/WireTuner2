import AppKit
import WTGeometry
import WTRender

/// The Pointer (selecting.adoc, "The selection tools"): a click selects the object under the
/// pointer, a drag draws a marquee, Shift adds or removes, Option subselects (the Subselect
/// tool of OBJ-005 is this gesture with the flag always set).  Selection only: moving the
/// selection is OBJ-005's.  Hit testing is REND-003's through the window's
/// `SelectionController`, so a rotated or zoomed canvas selects the same way.
@MainActor
final class PointerTool: Tool {
    static let id: ToolID = .pointer
    /// A drag shorter than this (view points) is a click.
    static let dragThreshold = 3.0
    static let statusMessage = "Click to select, drag to select an area; Shift adds or removes, Option subselects"

    static var descriptor: ToolDescriptor {
        ToolCatalog.all.first { $0.id == .pointer }!.delivering { PointerTool() }
    }

    private var context: ToolContext?
    private(set) var start: CanvasEvent?
    private(set) var current: CanvasEvent?

    init() {}

    var cursor: NSCursor { .arrow }

    /// Whether the gesture in progress has moved far enough to be a marquee.
    var isMarquee: Bool {
        guard let start, let current else { return false }
        return current.viewPoint.distance(to: start.viewPoint) >= Self.dragThreshold
    }

    /// The marquee in view points while dragging.
    var marqueeRect: Rect? {
        guard isMarquee, let start, let current else { return nil }
        return Rect(start.viewPoint, current.viewPoint)
    }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        cancel()
        context = nil
    }

    func mouseDown(_ e: CanvasEvent) {
        start = e
        current = e
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard start != nil else { return }
        current = e
    }

    func mouseUp(_ e: CanvasEvent) {
        defer { cancel() }
        guard let context, let start else { return }
        current = e
        let subselect = e.modifiers.contains(.option)
        if let rect = marqueeRect {
            context.selection.marquee(rect, viewport: context.viewport, modifiers: e.modifiers, subselect: subselect)
        } else {
            context.selection.click(at: start.viewPoint, viewport: context.viewport, modifiers: e.modifiers, subselect: subselect)
        }
    }

    /// Shift or Option pressed mid-drag changes what the release does.
    func flagsChanged(_ e: CanvasEvent) {
        guard let current else { return }
        self.current = current.with(modifiers: e.modifiers, timestamp: e.timestamp)
    }

    func keyDown(_ e: NSEvent) -> Bool { false }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let rect = marqueeRect else { return }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(rect.cgRect)
    }

    func cancel() {
        start = nil
        current = nil
    }
}
