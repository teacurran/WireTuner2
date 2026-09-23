import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The Lasso (selecting.adoc, "The selection tools"; OBJ-005): drag a freehand loop around what to
/// select.  Objects wholly inside the loop are selected -- with *Contact-sensitive selection*,
/// objects the loop touches -- and every anchor inside the loop is selected on its path, so the
/// Lasso also picks points.  kbd:[Shift] adds to (or removes from) the selection.  Selection only:
/// the Lasso writes nothing.
@MainActor
final class LassoTool: Tool {
    static let id: ToolID = "lasso"
    static let statusMessage = "Drag around objects or points to select them; Shift adds or removes"

    static var descriptor: ToolDescriptor {
        ToolCatalog.all.first { $0.id == id }!.delivering { LassoTool() }
    }

    private var context: ToolContext?
    /// The loop so far, pasteboard space.
    private(set) var loop: [Point] = []
    private var modifiers: KeyModifiers = []

    init() {}

    var cursor: NSCursor { .crosshair }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        cancel()
        context = nil
    }

    func mouseDown(_ e: CanvasEvent) {
        loop = [e.pasteboardPoint]
        modifiers = e.modifiers
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard !loop.isEmpty else { return }
        loop.append(e.pasteboardPoint)
        modifiers = e.modifiers
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, loop.count >= 3 else { return }
        let (picked, sub) = Self.pick(loop: loop, in: context.document, contactSensitive: context.selection.lassoContactSensitive())
        context.selection.model.apply(picked, sub: sub, mode: SelectionController.mode(for: modifiers))
    }

    /// The objects and points the closed `loop` selects in `document`.
    static func pick(loop: [Point], in document: DocumentHandle, contactSensitive: Bool) -> ([SelectionID], [SelectionID: SubSelection]) {
        var picked: [SelectionID] = []
        var sub: [SelectionID: SubSelection] = [:]
        for id in document.selectableIDs() {
            guard let object = document.object(for: id), let bounds = object.bounds else { continue }
            var corners = [Point(x: bounds.minX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.minY),
                           Point(x: bounds.maxX, y: bounds.maxY), Point(x: bounds.minX, y: bounds.maxY)]
            var anchors: Set<PointReference> = []
            if let path = object.path {
                corners = []
                for contour in path.contours where contour.isRenderable {
                    for point in contour.points {
                        let at = object.transform.apply(point.anchor)
                        corners.append(at)
                        if contains(loop, at) { anchors.insert(PointReference(node: id.node, contour: contour.id, point: point.id)) }
                    }
                }
            }
            let inside = corners.filter { contains(loop, $0) }.count
            let selected = contactSensitive ? inside > 0 || loop.contains(where: { bounds.contains($0) }) : inside == corners.count && inside > 0
            if !anchors.isEmpty, !selected || anchors.count < corners.count {
                sub[id] = .points(anchors)
                picked.append(id)
            } else if selected {
                picked.append(id)
            }
        }
        return (picked, sub)
    }

    /// Whether `point` is inside the closed polygon `loop` (even-odd).
    static func contains(_ loop: [Point], _ point: Point) -> Bool {
        var inside = false
        var j = loop.count - 1
        for i in loop.indices {
            let a = loop[i], b = loop[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    func flagsChanged(_ e: CanvasEvent) {
        if !loop.isEmpty { modifiers = e.modifiers }
    }

    func keyDown(_ e: NSEvent) -> Bool { false }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard loop.count >= 2 else { return }
        let path = CGMutablePath()
        SelectionOverlay.add(DisplayPath(polygon: loop, closed: false), transform: viewport.pasteboardToView, to: path)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.addPath(path)
        ctx.strokePath()
    }

    func cancel() {
        loop = []
        modifiers = []
    }
}
