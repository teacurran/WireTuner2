import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// WTGeometry contours as path points (drawing order, pasteboard space): one point per segment
/// start, handles from the cubic controls, a closing straight segment when the contour does not
/// end where it began.  Junctions with collinear handles are curve points.
enum ContourPoints {
    static func points(_ contour: Contour) -> [VectorPoint] {
        let segments = contour.segments.filter { !$0.isDegenerate || $0.p0 != $0.p3 }
        guard let first = segments.first else { return [] }
        var points: [VectorPoint] = segments.map { VectorPoint(anchor: $0.p0, outHandle: $0.p1 - $0.p0, kind: .corner) }
        let last = segments[segments.count - 1]
        let closesItself = contour.isClosed && last.p3.distance(to: first.p0) < 1e-6
        if !closesItself { points.append(VectorPoint(anchor: last.p3, kind: .corner)) }
        for index in points.indices {
            // The segment arriving at point `index`.
            let arriving: CubicBezier? = index > 0 ? segments[index - 1] : (closesItself ? last : nil)
            if let arriving { points[index].inHandle = arriving.p2 - arriving.p3 }
            if index < segments.count, arriving != nil, smooth(points[index].inHandle, points[index].outHandle) { points[index].kind = .curve }
        }
        return points
    }

    static func smooth(_ inHandle: Vector, _ outHandle: Vector) -> Bool {
        guard inHandle.lengthSquared > 0, outHandle.lengthSquared > 0 else { return false }
        return inHandle.normalized.dot(outHandle.normalized) < -0.9998
    }

    /// The segments of path points (drawing order), closed or open.
    static func segments(_ points: [VectorPoint], closed: Bool) -> [CubicBezier] {
        guard points.count >= 2 else { return [] }
        var result = zip(points, points.dropFirst()).map { CubicBezier(from: $0.anchor, outHandle: $0.outHandle, inHandle: $1.inHandle, to: $1.anchor) }
        if closed, let last = points.last, let first = points.first {
            result.append(CubicBezier(from: last.anchor, outHandle: last.outHandle, inHandle: first.inHandle, to: first.anchor))
        }
        return result
    }
}

/// The Variable Stroke Pen's outline (freeform.adoc, "Variable Stroke Pen"; DRAW-018): the fitted
/// centreline offset by half the width on each side -- the width interpolated along the stroke
/// from the samples' widths by arc length -- with semicircular caps, as one closed contour fitted
/// within `tolerance` of the exact offset.
enum VariableStrokeOutline {
    /// The samples of a stroke: positions and the width at each.
    struct Sample: Equatable, Sendable {
        var point: Point
        var width: Double
    }

    /// Fit tolerance of the outline, points (well under the 0.1 pt the width is held to).
    static let tolerance = 0.03

    /// The width at fraction `fraction` (0...1) of the samples' polyline length.
    static func width(at fraction: Double, samples: [Sample]) -> Double {
        guard let first = samples.first else { return 0 }
        guard samples.count > 1 else { return first.width }
        var lengths = [0.0]
        for (a, b) in zip(samples, samples.dropFirst()) { lengths.append(lengths.last! + a.point.distance(to: b.point)) }
        let total = lengths.last!
        guard total > 0 else { return first.width }
        let target = min(max(fraction, 0), 1) * total
        for index in 1..<lengths.count where lengths[index] >= target {
            let span = lengths[index] - lengths[index - 1]
            let t = span > 0 ? (target - lengths[index - 1]) / span : 0
            return samples[index - 1].width + (samples[index].width - samples[index - 1].width) * t
        }
        return samples[samples.count - 1].width
    }

    /// The outline of the fitted centreline `centerline` (open, drawing order) with the widths of
    /// `samples`: nil when the stroke is too short or has no width.
    static func outline(centerline: [VectorPoint], samples: [Sample]) -> Contour? {
        let segments = ContourPoints.segments(centerline, closed: false)
        guard !segments.isEmpty, samples.contains(where: { $0.width > 0 }) else { return nil }
        let lengths = segments.map { $0.length(tolerance: 1e-4) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return nil }
        var left: [Point] = [], right: [Point] = []
        var travelled = 0.0
        var startTangent = Vector(dx: 1, dy: 0), endTangent = startTangent
        for (segment, length) in zip(segments, lengths) where length > 0 {
            let steps = max(8, Int((length / 1.5).rounded(.up)))
            for step in 0...steps {
                if step == 0, !left.isEmpty { continue }
                let t = Double(step) / Double(steps)
                let direction = Self.direction(segment.tangent(t), otherwise: endTangent)
                if left.isEmpty { startTangent = direction }
                endTangent = direction
                let arc = travelled + segment.length(from: 0, to: t, tolerance: 1e-4)
                let half = width(at: arc / total, samples: samples) / 2
                let point = segment.evaluate(t)
                left.append(point + direction.perpendicular * half)
                right.append(point - direction.perpendicular * half)
            }
            travelled += length
        }
        let endCenter = Point.lerp(left.last!, right.last!, 0.5), startCenter = Point.lerp(left.first!, right.first!, 0.5)
        let endCap = cap(center: endCenter, from: left.last!, forward: endTangent)
        let startCap = cap(center: startCenter, from: right.first!, forward: startTangent * -1)
        let ring = left + endCap + right.reversed() + startCap
        let fitter = CurveFitter(maxError: tolerance, cornerAngle: .pi)
        return fitter.fitContour(ring + [ring[0]], closed: true)
    }

    /// The unit direction of `tangent`, or `otherwise` where the curve has none (a cusp).
    static func direction(_ tangent: Vector, otherwise: Vector) -> Vector {
        tangent.lengthSquared > 0 ? tangent.normalized : otherwise
    }

    /// The semicircle from `start` around `center`, bulging along `forward` (the stroke's
    /// direction at that end), without its end points.
    static func cap(center: Point, from start: Point, forward: Vector) -> [Point] {
        let radius = start.distance(to: center)
        guard radius > 1e-9 else { return [] }
        let startAngle = atan2(start.y - center.y, start.x - center.x)
        // Sweep the half turn whose midpoint lies along `forward`.
        let midpoint = Point(x: center.x + cos(startAngle + .pi / 2) * radius, y: center.y + sin(startAngle + .pi / 2) * radius)
        let sign: Double = (midpoint - center).dot(forward) >= 0 ? 1 : -1
        let steps = max(8, Int((radius * .pi / 1.5).rounded(.up)))
        return (1..<steps).map { step in
            let angle = startAngle + sign * .pi * Double(step) / Double(steps)
            return Point(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
    }

    /// The outline redrawn without self-overlap (GEO-002's normalize): one or more contours.
    static func removingOverlap(_ outline: Contour) -> [Contour] {
        Boolean.normalize(FilledPath(outline)).contours.filter { !$0.isEmpty }
    }
}

/// The settings the pen reads at each stroke (its sheet, freeform.adoc).
struct VariableStrokeSettings: Equatable, Sendable {
    var precision = PrecisionSetting(5)
    var dotted = false
    var removeOverlap = false
    var min = 2.0
    var max = 12.0
    var pressureCurve = 1.0

    init() {}

    @MainActor init(preferences: PreferenceStore) {
        typealias P = PathToolPreferences
        precision = PrecisionSetting(preferences[P.strokePrecision])
        dotted = preferences[P.strokeDotted]
        removeOverlap = preferences[P.strokeRemoveOverlap]
        min = preferences[P.strokeMin]
        max = preferences[P.strokeMax]
        pressureCurve = preferences[P.pressureCurve]
    }
}

/// The Variable Stroke Pen (freeform.adoc; DRAW-018, with DRAW-020's pen input): drag to draw a
/// closed, filled outline whose width follows pen pressure between *Min* and *Max*, or with a
/// mouse the width kbd:[{startsb}] and kbd:[{endsb}] set; kbd:[Option] draws a straight span.  The
/// stroke is one change "Variable Stroke"; with *Auto remove overlap* the self-overlap is removed
/// off the main thread afterwards and written in the same undo group.
@MainActor
final class VariableStrokePen: Tool, PointerTracking {
    static let id: ToolID = "variableStrokePen"
    static let statusMessage = "Drag to draw a variable stroke; [ and ] narrow and widen it; Option draws a straight segment"

    let settings: @MainActor () -> VariableStrokeSettings
    private var context: ToolContext?
    private(set) var capture: StrokeCapture?
    private(set) var samples: [VariableStrokeOutline.Sample] = []
    private(set) var width: StrokeWidthControl
    /// The overlap cleanup in flight (tests wait for it).
    private(set) var cleanup: Task<Void, Never>?

    init(settings: @escaping @MainActor () -> VariableStrokeSettings = { VariableStrokeSettings() }) {
        self.settings = settings
        let current = settings()
        width = StrokeWidthControl(min: current.min, max: current.max, curve: current.pressureCurve)
    }

    var cursor: NSCursor { .crosshair }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        cancel()
        context = nil
    }

    func pointerMoved(_ e: CanvasEvent) {}

    /// Re-reads *Min*, *Max* and the curve, keeping the key width inside them.
    private func refreshWidth() {
        let current = settings()
        width = StrokeWidthControl(min: current.min, max: current.max, curve: current.pressureCurve, keyWidth: width.keyWidth)
    }

    func mouseDown(_ e: CanvasEvent) {
        refreshWidth()
        capture = StrokeCapture(start: e.pasteboardPoint, straight: e.modifiers.contains(.option))
        samples = [VariableStrokeOutline.Sample(point: e.pasteboardPoint, width: width.width(for: e))]
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard capture != nil, let context else { return }
        let straight = e.modifiers.contains(.option)
        let constraint = e.modifiers.contains(.shift) ? context.drawing().constraint : nil
        capture?.add(e.pasteboardPoint, straight: straight, constraint: constraint)
        let sample = VariableStrokeOutline.Sample(point: capture?.last ?? e.pasteboardPoint, width: width.width(for: e))
        if straight, samples.count > 1, capture?.straightStart != nil { samples[samples.count - 1] = sample } else { samples.append(sample) }
        context.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let command = command() else { return }
        let document = context.document
        let current = settings()
        if current.removeOverlap { document.beginGroup() }
        let task = context.commandSink.perform(command)
        let selection = context.selection
        let sink = context.commandSink
        cleanup = Task { @MainActor in
            let created = await task.value?.createdObjects.first
            if let created { selection.model.set(Selection([SelectionID(created)])) }
            if current.removeOverlap {
                if let created { _ = await Self.removeOverlap(created, document: document, sink: sink)?.value }
                await document.settle()
                document.endGroup()
            }
        }
    }

    /// The outline of the stroke so far as the pen draws it (pasteboard space).
    func outline() -> Contour? {
        guard let context, let capture else { return nil }
        let centerline = StrokeFit.points(capture.allSpans, precision: settings().precision, zoom: context.viewport.zoom)
        return VariableStrokeOutline.outline(centerline: centerline, samples: samples)
    }

    /// The stroke's change: a closed path with the new-object attributes.
    func command() -> (any WTModel.Command)? {
        guard let context, let outline = outline() else { return nil }
        let points = ContourPoints.points(outline)
        guard points.count >= 3 else { return nil }
        return CreatePath(label: "Variable Stroke", contours: [NewContour(closed: true, points: points)], appearance: context.newObjectAppearance(),
                          layer: context.objectEditing?.activeLayer)
    }

    /// The overlap cleanup of `node`, computed off the main thread: its contour replaced by the
    /// outline without self-overlap (every point new, so a concurrent point edit is *edit vs
    /// delete*); nil when the node is gone or nothing overlaps.
    static func removeOverlap(_ node: OpID, document: DocumentHandle, sink: any CommandSink) async -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard document.state.isLive(node), let path = document.object(for: SelectionID(node))?.path, let first = path.contours.first else { return nil }
        let local = Contour(segments: ContourPoints.segments(first.drawn, closed: true), closed: true)
        let cleaned = await Task.detached(priority: .userInitiated) { VariableStrokeOutline.removingOverlap(local) }.value
        guard document.state.isLive(node), !cleaned.isEmpty else { return nil }
        let contours = cleaned.map { ContourPoints.points($0) }.filter { $0.count >= 2 }
        guard let head = contours.first else { return nil }
        let command = RewritePath(node: node, edits: [.init(contour: first.id, points: head, closed: true)],
                                  added: contours.dropFirst().map { NewContour(closed: true, points: $0) }, label: "Remove Overlap")
        return sink.perform(command)
    }

    func flagsChanged(_ e: CanvasEvent) {}

    /// kbd:[{startsb}] and kbd:[{endsb}] step the width (ignored while a pen is in contact).
    func keyDown(_ e: NSEvent) -> Bool {
        guard let wider = StrokeWidthControl.bracket(e.charactersIgnoringModifiers) else { return false }
        width.bracket(wider: wider)
        return true
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let capture, capture.trail.count >= 2 else { return }
        let path = CGMutablePath()
        SelectionOverlay.add(DisplayPath(polygon: capture.trail, closed: false), transform: viewport.pasteboardToView, to: path)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(max(1, width.keyWidth * viewport.zoom))
        if settings().dotted { ctx.setLineDash(phase: 0, lengths: [1, 3]) }
        ctx.addPath(path)
        ctx.strokePath()
    }

    func cancel() {
        capture = nil
        samples = []
    }

    var hasSomethingToCancel: Bool { capture != nil }
}
