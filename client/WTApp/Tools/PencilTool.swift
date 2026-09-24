import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The pointer samples of one stroke (freeform.adoc, "Input pipeline"; DRAW-016): freehand runs,
/// and a straight span from where kbd:[Option] went down to where it went up (kbd:[Shift] with it
/// constraining the span to the constrain angle and every 45°).
struct StrokeCapture: Equatable, Sendable {
    /// Finished spans.
    private(set) var spans: [StrokeFit.Span] = []
    /// The freehand run in progress.
    private(set) var samples: [Point] = []
    /// Where the straight span in progress started.
    private(set) var straightStart: Point?
    /// The pointer at the last sample.
    private(set) var last: Point?

    init(start: Point, straight: Bool = false) {
        last = start
        if straight { straightStart = start } else { samples = [start] }
    }

    /// A pointer sample; `straight` while Option is held, `constraint` with Shift.
    mutating func add(_ point: Point, straight: Bool, constraint: AngleConstraint?) {
        if straight {
            if straightStart == nil {
                endFreehand()
                straightStart = last ?? point
            }
            last = constraint.map { $0.constrain(point, from: straightStart!) } ?? point
        } else {
            if let start = straightStart {
                spans.append(.straight(start, last ?? point))
                straightStart = nil
                samples = [last ?? point]
            }
            samples.append(point)
            last = point
        }
    }

    private mutating func endFreehand() {
        if samples.count >= 2 { spans.append(.freehand(samples)) }
        samples = []
    }

    /// Every span, the one in progress included.
    var allSpans: [StrokeFit.Span] {
        var result = spans
        if let start = straightStart, let last { result.append(.straight(start, last)) }
        if samples.count >= 2 { result.append(.freehand(samples)) }
        return result
    }

    /// The trail the overlay draws: every sample in order.
    var trail: [Point] {
        var points: [Point] = []
        for span in allSpans {
            switch span {
            case .freehand(let run): points += run
            case .straight(let a, let b): points += [a, b]
            }
        }
        return points
    }
}

/// The Pencil (freeform.adoc, "Pencil"; DRAW-017): drag to draw; the stroke is fitted on release
/// at the sheet's *Precision* (the tolerance scaled by the zoom, so precision is in screen terms)
/// and becomes an open path in one change "Pencil".  Starting on an end point of a selected open
/// path continues that path instead (a "+" beside the pointer shows it); if the path has been
/// deleted meanwhile, the stroke becomes a new path.
@MainActor
final class PencilTool: Tool, PointerTracking {
    static let id: ToolID = "pencil"
    static let statusMessage = "Drag to draw; Option draws a straight segment, Shift constrains it; start on a selected end point to continue"

    static var descriptor: ToolDescriptor {
        ToolCatalog.all.first { $0.id == id }!.delivering { PencilTool() }
    }

    /// The end of a selected path a stroke continues.
    struct Continuation: Equatable {
        var node: OpID
        var contour: OpID
        var end: ContourEnd
    }

    private var context: ToolContext?
    private(set) var capture: StrokeCapture?
    private(set) var continuation: Continuation?
    private(set) var hoverContinues = false

    init() {}

    var cursor: NSCursor { hoverContinues ? PenCursors.add : .crosshair }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        cancel()
        context = nil
    }

    /// The selected open path end within the pick distance of `point`, if any.
    func continuation(at point: Point) -> Continuation? {
        guard let context else { return nil }
        let tolerance = context.snapping.pickDistance() / context.viewport.zoom
        for id in context.selection.selection.ids {
            guard let object = context.document.object(for: id), object.kind == .path, let path = object.path else { continue }
            for contour in path.contours where !contour.closed {
                guard let ends = contour.ends else { continue }
                if object.transform.apply(ends.last.anchor).distance(to: point) <= tolerance {
                    return Continuation(node: id.opID, contour: contour.id, end: .end)
                }
                if object.transform.apply(ends.first.anchor).distance(to: point) <= tolerance {
                    return Continuation(node: id.opID, contour: contour.id, end: .start)
                }
            }
        }
        return nil
    }

    func pointerMoved(_ e: CanvasEvent) {
        let continues = continuation(at: e.pasteboardPoint) != nil
        if continues != hoverContinues {
            hoverContinues = continues
            context?.host.toolCursorDidChange()
        }
    }

    func mouseDown(_ e: CanvasEvent) {
        continuation = continuation(at: e.pasteboardPoint)
        capture = StrokeCapture(start: e.pasteboardPoint, straight: e.modifiers.contains(.option))
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard capture != nil, let context else { return }
        let constraint = e.modifiers.contains(.shift) ? context.drawing().constraint : nil
        capture?.add(e.pasteboardPoint, straight: e.modifiers.contains(.option), constraint: constraint)
        context.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let command = command() else { return }
        let task = context.commandSink.perform(command)
        let selection = context.selection
        Task { @MainActor in
            guard let created = await task.value?.createdObjects.first else { return }
            selection.model.set(Selection([SelectionID(created)]))
        }
    }

    /// The command the stroke so far would perform: a continuation of the path it started on
    /// (while that path is live), else a new path.
    func command() -> (any WTModel.Command)? {
        guard let context, let capture else { return nil }
        let settings = context.drawing()
        let points = StrokeFit.points(capture.allSpans, precision: settings.tools.pencilPrecision, zoom: context.viewport.zoom)
        guard points.count >= 2 else { return nil }
        if let continuation, context.document.state.isLive(continuation.node),
           let object = context.document.object(for: SelectionID(continuation.node)), let inverse = object.transform.inverted() {
            let local = points.map { point -> VectorPoint in
                var copy = point
                copy.anchor = inverse.apply(point.anchor)
                copy.inHandle = inverse.apply(point.inHandle)
                copy.outHandle = inverse.apply(point.outHandle)
                return copy
            }
            return ContinuePath(node: continuation.node, contour: continuation.contour, end: continuation.end, points: local)
        }
        return CreatePath(label: "Pencil", contours: [NewContour(points: points)], appearance: context.newObjectAppearance(),
                          fillWhenOpen: settings.fillWhenOpen, layer: context.objectEditing?.activeLayer)
    }

    func flagsChanged(_ e: CanvasEvent) {}

    func keyDown(_ e: NSEvent) -> Bool { false }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let capture, let context, capture.trail.count >= 2 else { return }
        let path = CGMutablePath()
        SelectionOverlay.add(DisplayPath(polygon: capture.trail, closed: false), transform: viewport.pasteboardToView, to: path)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        if context.drawing().tools.pencilDotted { ctx.setLineDash(phase: 0, lengths: [1, 3]) }
        ctx.addPath(path)
        ctx.strokePath()
    }

    func cancel() {
        capture = nil
        continuation = nil
    }
}
