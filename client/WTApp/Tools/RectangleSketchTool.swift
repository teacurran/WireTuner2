import AppKit
import WTGeometry
import WTRender

/// The sample drawing tool that proves the "one change per drag" pattern: it previews the
/// rectangle in the overlay while dragging, reacts to modifier changes mid-drag (Shift makes
/// a square, Option draws from the centre, as the Rectangle tool page describes), and submits
/// exactly one edit on mouse-up.  OBJ's rectangle task replaces it with the real tool writing
/// a `WTModel` command.
@MainActor
final class RectangleSketchTool: Tool {
    static let id: ToolID = .rectangle
    static let editLabel = "Rectangle"
    static let fillColor = Color(red: 0.55, green: 0.75, blue: 0.95)
    static let strokeColor = Color.black

    private var context: ToolContext?
    private(set) var anchor: Point?
    private(set) var current: CanvasEvent?

    init() {}

    var cursor: NSCursor { .crosshair }

    /// The rectangle being previewed, in pasteboard coordinates.
    var previewRect: Rect? {
        guard let anchor, let current else { return nil }
        return Self.rect(anchor: anchor, to: current.pasteboardPoint, modifiers: current.modifiers)
    }

    /// The rectangle from the press point to `point`: Shift constrains to a square (the
    /// longer side wins), Option makes the press point the centre.
    static func rect(anchor: Point, to point: Point, modifiers: KeyModifiers) -> Rect {
        var dx = point.x - anchor.x
        var dy = point.y - anchor.y
        if modifiers.contains(.shift) {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if modifiers.contains(.option) {
            return Rect(Point(x: anchor.x - dx, y: anchor.y - dy), Point(x: anchor.x + dx, y: anchor.y + dy))
        }
        return Rect(anchor, Point(x: anchor.x + dx, y: anchor.y + dy))
    }

    /// The display items a committed rectangle adds: one path painted by a fill and a stroke,
    /// so the rectangle is one object to hit test and select.
    static func items(for rect: Rect) -> [DisplayItem] {
        [.path(PathItem(path: DisplayPath(rect: rect), appearance: .fillAndStroke(fill: fillColor, stroke: strokeColor)))]
    }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage("Drag to draw a rectangle; Shift constrains, Option draws from the center")
    }

    func deactivate() {
        cancel()
        context = nil
    }

    func mouseDown(_ e: CanvasEvent) {
        anchor = context.map { $0.snapping.snap(e.pasteboardPoint, viewport: $0.viewport) } ?? e.pasteboardPoint
        current = e
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard anchor != nil else { return }
        current = e
    }

    func mouseUp(_ e: CanvasEvent) {
        defer { cancel() }
        guard let anchor, let context else { return }
        let rect = Self.rect(anchor: anchor, to: e.pasteboardPoint, modifiers: e.modifiers)
        guard rect.width > 0, rect.height > 0 else { return }
        context.commandSink.submit(DocumentEdit(label: Self.editLabel, insertedItems: Self.items(for: rect)))
    }

    /// Mid-drag: the same pointer, new constraint.
    func flagsChanged(_ e: CanvasEvent) {
        guard anchor != nil, let current else { return }
        self.current = current.with(modifiers: e.modifiers, timestamp: e.timestamp)
    }

    func keyDown(_ e: NSEvent) -> Bool { false }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let rect = previewRect else { return }
        let corners = [
            Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY),
            Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY),
        ].map { viewport.toView($0).cgPoint }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.addLines(between: corners)
        ctx.closePath()
        ctx.strokePath()
    }

    func cancel() {
        anchor = nil
        current = nil
    }
}
