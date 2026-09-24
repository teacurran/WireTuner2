import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Freeform tool's settings (editing-paths.adoc, "Reshaping with the Freeform tool").
struct FreeformSettings: Equatable, Sendable {
    enum Mode: String, Sendable { case pushPull, reshape }
    enum Bend: String, Sendable { case length, points }

    var mode = Mode.pushPull
    /// Push pointer diameter and pull length, view pixels.
    var pushSize = 40.0
    var pushPrecision = PrecisionSetting(5)
    var bend = Bend.length
    var length = 100.0
    var pressureSize = false
    var pressureLength = false
    /// Reshape pointer diameter, view pixels; strength 1...100 %.
    var reshapeSize = 60.0
    var strength = 50.0
    var reshapePrecision = PrecisionSetting(5)

    init() {}

    /// Stored values; anything unknown reads as the default.
    static func mode(_ raw: String) -> Mode { Mode(rawValue: raw) ?? .pushPull }
    static func bend(_ raw: String) -> Bend { Bend(rawValue: raw) ?? .length }

    @MainActor init(preferences: PreferenceStore) {
        typealias P = PathToolPreferences
        mode = Self.mode(preferences[P.freeformMode])
        pushSize = preferences[P.pushSize]
        pushPrecision = PrecisionSetting(preferences[P.pushPrecision])
        bend = Self.bend(preferences[P.pullBend])
        length = preferences[P.pullLength]
        pressureSize = preferences[P.pressureSize]
        pressureLength = preferences[P.pressureLength]
        reshapeSize = preferences[P.reshapeSize]
        strength = preferences[P.reshapeStrength]
        reshapePrecision = PrecisionSetting(preferences[P.reshapePrecision])
    }
}

/// One contour being reshaped (pasteboard space): its drawn points and a dense sampling of it,
/// each sample remembering where it started and which point (if any) it is; the deformations move
/// samples, and `result` refits the stretches that moved between the nearest points that did not
/// (DRAW-027, editing-paths.adoc "Client": "refits that stretch with GEO-004 at the chosen
/// precision").  Points outside the stretches keep their ids, so a concurrent edit of them
/// survives; points inside are replaced.
struct FreeformContour: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        var point: Point
        let original: Point
        /// The drawn point this sample is, if it is one.
        let owner: Int?
        /// Arc length from the contour's first point.
        let arc: Double
    }

    let node: OpID
    let contour: OpID
    let closed: Bool
    let points: [VectorPoint]
    private(set) var samples: [Sample]
    /// Samples per point of arc length (the refit's input density).
    static let spacing = 1.0

    init(node: OpID, contour: OpID, closed: Bool, points: [VectorPoint]) {
        self.node = node
        self.contour = contour
        self.closed = closed
        self.points = points
        var samples: [Sample] = []
        var arc = 0.0
        for (index, segment) in ContourPoints.segments(points, closed: closed).enumerated() {
            let length = segment.length(tolerance: 1e-4)
            let steps = max(4, Int((length / Self.spacing).rounded(.up)))
            for step in 0..<steps {
                let t = Double(step) / Double(steps)
                let point = segment.evaluate(t)
                samples.append(Sample(point: point, original: point, owner: step == 0 ? index : nil, arc: arc + length * t))
            }
            arc += length
        }
        if !closed, let last = points.last { samples.append(Sample(point: last.anchor, original: last.anchor, owner: points.count - 1, arc: arc)) }
        self.samples = samples
        totalLength = arc
    }

    let totalLength: Double

    /// The sample nearest `point` and its distance.
    func nearest(_ point: Point) -> (index: Int, distance: Double)? {
        samples.indices.map { ($0, samples[$0].point.distance(to: point)) }.min { $0.1 < $1.1 }
    }

    var hasMoved: Bool { samples.contains { $0.point.distance(to: $0.original) > 1e-6 } }

    // MARK: Deformations

    /// Pull *By length*: the stretch `length` long around sample `grab` follows `delta`, fully at
    /// the grab point and fading (a cosine) to nothing at the stretch's ends.
    mutating func pull(from grab: Int, by delta: Vector, length: Double) {
        let half = max(length / 2, 1e-6), center = samples[grab].arc
        for index in samples.indices {
            var distance = abs(samples[index].arc - center)
            if closed { distance = min(distance, totalLength - distance) }
            guard distance < half else { samples[index].point = samples[index].original; continue }
            let weight = 0.5 * (1 + cos(.pi * distance / half))
            samples[index].point = samples[index].original + delta * weight
        }
    }

    /// Push: every sample inside the circle of `radius` around `center` is shoved out to its edge.
    mutating func push(at center: Point, radius: Double) {
        guard radius > 0 else { return }
        for index in samples.indices {
            let offset = samples[index].point - center
            let distance = offset.length
            guard distance < radius else { continue }
            let direction = distance > 1e-9 ? offset.normalized : Vector(dx: 0, dy: -1)
            samples[index].point = center + direction * radius
        }
    }

    /// Reshape: samples within `radius` of `center` move by `delta` times `strength` (0...1)
    /// with a Gaussian falloff over the radius.
    mutating func reshape(at center: Point, by delta: Vector, radius: Double, strength: Double) {
        guard radius > 0 else { return }
        for index in samples.indices {
            let distance = samples[index].point.distance(to: center)
            guard distance < radius else { continue }
            let falloff = exp(-4.5 * (distance / radius) * (distance / radius))
            samples[index].point = samples[index].point + delta * (strength * falloff)
        }
    }

    // MARK: Result

    /// The contour after the deformation (drawing order, pasteboard space): unmoved points as they
    /// were (same ids), each moved stretch refitted within `tolerance` between the nearest
    /// unmoved points; nil when nothing moved.
    func result(tolerance: Double) -> [VectorPoint]? {
        let moved = samples.map { $0.point.distance(to: $0.original) > 1e-6 }
        guard moved.contains(true) else { return nil }
        let owners = samples.indices.compactMap { index in samples[index].owner.map { (point: $0, sample: index) } }
        let fitter = CurveFitter(maxError: max(tolerance, 1e-3))
        if closed {
            // Start the walk at a point that did not move; every point moved: refit the whole ring.
            guard let anchor = owners.first(where: { !moved[$0.sample] }) else {
                let ring = samples.map(\.point)
                return ContourPoints.points(fitter.fitContour(ring + [ring[0]], closed: true))
            }
            let rotated = Array(samples[anchor.sample...] + samples[..<anchor.sample]) + [samples[anchor.sample]]
            let open = Self.refit(rotated, points: points, fitter: fitter)
            return Array(open.dropLast())
        }
        return Self.refit(samples, points: points, fitter: fitter)
    }

    /// Walks samples (an open run; the owners index `points`), keeping unmoved points and refitting
    /// moved stretches between the nearest unmoved points (an end point that moved moves with its
    /// stretch).
    static func refit(_ samples: [Sample], points: [VectorPoint], fitter: CurveFitter) -> [VectorPoint] {
        let moved = samples.map { $0.point.distance(to: $0.original) > 1e-6 }
        let owners = samples.indices.filter { samples[$0].owner != nil }
        /// Whether the samples after owner `position`, up to the next owner, moved.
        func segmentMoved(_ position: Int) -> Bool {
            let from = owners[position] + 1, to = position + 1 < owners.count ? owners[position + 1] : samples.count
            return from < to && moved[from..<to].contains(true)
        }
        var result: [VectorPoint] = []
        var position = 0
        while position < owners.count {
            let start = owners[position]
            var point = points[samples[start].owner!]
            point.anchor = samples[start].point
            guard position + 1 < owners.count, segmentMoved(position) else {
                result.append(point)
                position += 1
                continue
            }
            // The stretch runs to the first point after it whose next segment did not move.
            var endPosition = position + 1
            while endPosition + 1 < owners.count, segmentMoved(endPosition) { endPosition += 1 }
            let end = owners[endPosition]
            let fitted = fitter.fit(samples[start...end].map(\.point))
            // Samples that collapsed onto one place leave a straight segment.
            let segments = fitted.isEmpty ? [CubicBezier(line: Line(start: samples[start].point, end: samples[end].point))] : fitted
            point.outHandle = segments[0].p1 - segments[0].p0
            result.append(point)
            for (index, segment) in segments.enumerated() where index + 1 < segments.count {
                let next = segments[index + 1]
                var added = VectorPoint(anchor: segment.p3, inHandle: segment.p2 - segment.p3, outHandle: next.p1 - next.p0, kind: .corner)
                if ContourPoints.smooth(added.inHandle, added.outHandle) { added.kind = .curve }
                result.append(added)
            }
            var last = points[samples[end].owner!]
            last.anchor = samples[end].point
            last.inHandle = segments[segments.count - 1].p2 - segments[segments.count - 1].p3
            result.append(last)
            position = endPosition + 1
        }
        return result.map(fixKind)
    }

    /// A curve point whose handles no longer line up is a corner.
    static func fixKind(_ point: VectorPoint) -> VectorPoint {
        guard point.kind == .curve, !ContourPoints.smooth(point.inHandle, point.outHandle), point.inHandle != .zero, point.outHandle != .zero else { return point }
        var copy = point
        copy.kind = .corner
        return copy
    }

    /// The preview polyline.
    var preview: [Point] { samples.map(\.point) + (closed ? [samples[0].point] : []) }
}

/// The Freeform tool (editing-paths.adoc, "Reshaping with the Freeform tool"; DRAW-027).
/// *Push/Pull*: pressing on a selected path pulls it -- a stretch *Length* long fading around the
/// grab point, or with *Between points* the segment's two handles so the grabbed point follows --
/// and pressing beside it pushes it with the circle pointer.  *Reshape area*: the two circles bend
/// what they cross, strongest at the centre, fading as the drag goes on.  Keys: kbd:[Shift]
/// constrains the pointer's movement; kbd:[Option] before the press swaps the pull bend, after it
/// reshapes a copy (the original stays); kbd:[{startsb}] / kbd:[{endsb}] shrink and grow the
/// pointer; kbd:[Up] / kbd:[Down] raise and lower the strength (Reshape).  Pen pressure scales the
/// size or length when the sheet says so.  One change on release: "Freeform" (or "Clone" for a
/// copy).
@MainActor
final class FreeformTool: Tool, PointerTracking {
    static let id: ToolID = "freeform"
    static let statusMessage = "Drag on a selected path to pull it or beside it to push; Option first swaps the bend, Option while dragging reshapes a copy"

    enum Gesture: Equatable {
        case pull(bend: FreeformSettings.Bend)
        case push
        case reshape
    }

    let settings: @MainActor () -> FreeformSettings
    private var context: ToolContext?
    private(set) var gesture: Gesture?
    private(set) var contours: [FreeformContour] = []
    private(set) var clone = false
    private(set) var pointer: Point?
    /// The pull's grab: which contour, which sample, and the press point.
    private(set) var grab: (contour: Int, sample: Int, press: Point)?
    private var last: Point?
    private var dragged = 0.0
    /// kbd:[Option] was down at the press (it swapped the bend); only a later kbd:[Option] clones.
    private var optionAtPress = false
    /// The size and strength as the bracket and arrow keys left them (view pixels, percent).
    private(set) var sizeAdjustment = 0.0
    private(set) var strengthAdjustment = 0.0
    static let sizeStep = 5.0
    static let strengthStep = 5.0

    init(settings: @escaping @MainActor () -> FreeformSettings = { FreeformSettings() }) {
        self.settings = settings
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

    func pointerMoved(_ e: CanvasEvent) {
        pointer = e.pasteboardPoint
        context?.host.setNeedsOverlayDisplay()
    }

    /// The pointer's diameter in view pixels (the sheet's size, the keys, pen pressure).
    func size(_ e: CanvasEvent? = nil) -> Double {
        let current = settings()
        var base = (current.mode == .reshape ? current.reshapeSize : current.pushSize) + sizeAdjustment
        if current.pressureSize, let e, e.isTablet { base *= max(e.pressure, 0.05) }
        return min(max(base, 1), 1000)
    }

    /// The strength, 0...1.
    var strength: Double { min(max(settings().strength + strengthAdjustment, 1), 100) / 100 }

    /// The pull length in pasteboard units at the zoom.
    func length(_ e: CanvasEvent?, zoom: Double) -> Double {
        let current = settings()
        var value = current.length
        if current.pressureLength, let e, e.isTablet { value *= max(e.pressure, 0.05) }
        return min(max(value, 1), 1000) / max(zoom, 1e-9)
    }

    /// The selected paths' contours, ready to deform.
    func targets() -> [FreeformContour] {
        guard let context else { return [] }
        let state = context.document.state
        return PathSplitting.targets(context.selection.selection, document: context.document).flatMap { target in
            target.contours.filter { $0.drawn.count >= 2 }.map { contour in
                FreeformContour(node: target.node, contour: contour.id, closed: contour.closed, points: PathSplitting.map(contour.drawn, target.transform))
            }
        }.filter { state.isLive($0.node) }
    }

    func mouseDown(_ e: CanvasEvent) {
        guard let context else { return }
        contours = targets()
        clone = false
        dragged = 0
        optionAtPress = e.modifiers.contains(.option)
        last = e.pasteboardPoint
        pointer = e.pasteboardPoint
        let current = settings()
        if current.mode == .reshape {
            gesture = .reshape
            return
        }
        let pick = context.selection.pickDistance() / context.viewport.zoom
        let hits = contours.indices.compactMap { index in contours[index].nearest(e.pasteboardPoint).map { (index, $0.index, $0.distance) } }
        if let (index, sample, distance) = hits.min(by: { $0.2 < $1.2 }), distance <= pick {
            var bend = current.bend
            if e.modifiers.contains(.option) { bend = bend == .length ? .points : .length }
            gesture = .pull(bend: bend)
            grab = (index, sample, e.pasteboardPoint)
        } else {
            gesture = .push
        }
    }

    /// Shift keeps the pointer's movement to the constrain angle and every 45° from it.
    func constrained(_ e: CanvasEvent) -> Point {
        guard e.modifiers.contains(.shift), let context, let origin = grab?.press ?? last else { return e.pasteboardPoint }
        return context.drawing().constraint.constrain(e.pasteboardPoint, from: origin)
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard let gesture, let context, let previous = last else { return }
        if e.modifiers.contains(.option), !optionAtPress { clone = true }
        let point = constrained(e)
        let zoom = context.viewport.zoom
        switch gesture {
        case .pull(let bend):
            if bend == .length, let grab {
                contours[grab.contour].pull(from: grab.sample, by: point - grab.press, length: length(e, zoom: zoom))
            }
        case .push:
            let radius = size(e) / 2 / zoom
            let steps = max(1, Int((previous.distance(to: point) / max(radius / 2, 1e-6)).rounded(.up)))
            for step in 1...steps {
                let center = Point.lerp(previous, point, Double(step) / Double(steps))
                for index in contours.indices { contours[index].push(at: center, radius: radius) }
            }
        case .reshape:
            let radius = size(e) / 2 / zoom
            let decay = exp(-dragged / max(3 * radius, 1e-6))
            for index in contours.indices { contours[index].reshape(at: previous, by: point - previous, radius: radius, strength: strength * decay) }
        }
        dragged += previous.distance(to: point)
        last = point
        pointer = point
        context.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { finishGesture() }
        guard let context, let command = command(release: constrained(e)) else { return }
        context.commandSink.perform(command)
    }

    private func finishGesture() {
        gesture = nil
        grab = nil
        contours = []
        clone = false
        last = nil
        dragged = 0
    }

    /// The fit tolerance at the zoom, from the mode's precision.
    func tolerance() -> Double {
        let current = settings()
        let precision = current.mode == .reshape ? current.reshapePrecision : current.pushPrecision
        return precision.tolerance(zoom: context?.viewport.zoom ?? 1)
    }

    /// The gesture's change: each reshaped contour rewritten (its unmoved points keep their ids),
    /// or with kbd:[Option] a reshaped copy of each path above it.
    func command(release: Point? = nil) -> (any WTModel.Command)? {
        guard let context, let gesture else { return nil }
        let state = context.document.state
        var edited: [(node: OpID, contour: OpID, points: [VectorPoint], closed: Bool)] = []
        if case .pull(.points) = gesture, let grab, let release {
            if let points = Self.bendSegment(contours[grab.contour], grab: grab.sample, by: release - grab.press) {
                edited.append((contours[grab.contour].node, contours[grab.contour].contour, points, contours[grab.contour].closed))
            }
        } else {
            for contour in contours {
                guard let points = contour.result(tolerance: tolerance()) else { continue }
                edited.append((contour.node, contour.contour, points, contour.closed))
            }
        }
        guard !edited.isEmpty else { return nil }
        var commands: [any WTModel.Command] = []
        for node in Set(edited.map(\.node)).sorted() {
            guard let inverse = Objects.pasteboardTransform(of: node, in: state).inverted(), let path = context.document.object(for: SelectionID(node))?.path else { continue }
            let mine = edited.filter { $0.node == node }
            if clone {
                // The copy: every contour, the reshaped ones replaced; the original is left alone.
                let contours = path.contours.map { contour -> NewContour in
                    if let edit = mine.first(where: { $0.contour == contour.id }) { return NewContour(closed: edit.closed, points: PathSplitting.map(edit.points, inverse)) }
                    return NewContour(closed: contour.closed, points: contour.drawn)
                }
                commands.append(RewritePath(node: node, pieces: [contours], label: "Clone"))
            } else {
                let edits = mine.map { edit in
                    RewritePath.ContourEdit(contour: edit.contour, points: PathSplitting.restored(PathSplitting.map(edit.points, inverse), from: path.contour(edit.contour)?.drawn ?? []),
                                            closed: edit.closed)
                }
                commands.append(RewritePath(node: node, edits: edits, label: "Freeform"))
            }
        }
        guard !commands.isEmpty else { return nil }
        return commands.count == 1 ? commands[0] : CompositeCommand(clone ? "Clone" : "Freeform", commands)
    }

    /// Pull *Between points*: the segment holding sample `grab` bends so the grabbed point moves by
    /// `delta` -- its two handles move, its points stay (so nothing else of the path changes).
    static func bendSegment(_ contour: FreeformContour, grab: Int, by delta: Vector) -> [VectorPoint]? {
        guard delta.lengthSquared > 0 else { return nil }
        let segments = ContourPoints.segments(contour.points, closed: contour.closed)
        // Which segment and where on it: the point sample at or before the grabbed one (the first
        // sample is always a point), and the arc fraction; an open contour's end point belongs to
        // its last segment.
        let samples = contour.samples
        let lastStart = samples.lastIndex { $0.owner == segments.count - 1 }!
        let ownerSample = min(samples[...grab].lastIndex { $0.owner != nil }!, lastStart)
        let index = samples[ownerSample].owner!
        let segment = segments[index]
        let length = segment.length(tolerance: 1e-4)
        let t = min(max(length > 0 ? (samples[grab].arc - samples[ownerSample].arc) / length : 0.5, 0.1), 0.9)
        let scale = 1 / (3 * t * (1 - t) * ((1 - t) * (1 - t) + t * t))
        var points = contour.points
        let next = (index + 1) % points.count
        points[index].outHandle = points[index].outHandle + delta * ((1 - t) * scale)
        points[next].inHandle = points[next].inHandle + delta * (t * scale)
        points[index] = FreeformContour.fixKind(points[index])
        points[next] = FreeformContour.fixKind(points[next])
        return points
    }

    func flagsChanged(_ e: CanvasEvent) {
        if gesture != nil, e.modifiers.contains(.option), !optionAtPress { clone = true }
    }

    /// kbd:[{startsb}] / kbd:[{endsb}] resize the pointer; kbd:[Up] / kbd:[Down] change the strength.
    func keyDown(_ e: NSEvent) -> Bool {
        if let wider = StrokeWidthControl.bracket(e.charactersIgnoringModifiers) {
            sizeAdjustment += wider ? Self.sizeStep : -Self.sizeStep
            context?.host.setNeedsOverlayDisplay()
            return true
        }
        switch e.keyCode {
        case 126: strengthAdjustment += Self.strengthStep
        case 125: strengthAdjustment -= Self.strengthStep
        default: return false
        }
        return true
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        for contour in contours where contour.hasMoved {
            let path = CGMutablePath()
            SelectionOverlay.add(DisplayPath(polygon: contour.preview, closed: false), transform: viewport.pasteboardToView, to: path)
            ctx.addPath(path)
            ctx.strokePath()
        }
        guard let pointer else { return }
        let center = viewport.toView(pointer)
        let radius = size() / 2
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        if settings().mode == .reshape {
            let inner = radius * strength
            ctx.strokeEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
        } else if case .pull? = gesture {
            // The small "s" of pull mode.
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.controlAccentColor]
            NSAttributedString(string: "s", attributes: attributes).draw(at: CGPoint(x: center.x + radius, y: center.y + radius))
        }
    }

    func cancel() {
        finishGesture()
    }

    var hasSomethingToCancel: Bool { gesture != nil }
}
