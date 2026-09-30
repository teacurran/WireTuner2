import Foundation
import WTCRDT
import WTGeometry

/// One contour being reshaped (pasteboard space): its drawn points and a dense sampling of it,
/// each sample remembering where it started and which point (if any) it is; the deformations move
/// samples, and `result` refits the stretches that moved between the nearest points that did not
/// (DRAW-027, editing-paths.adoc "Client": "refits that stretch with GEO-004 at the chosen
/// precision").  Points outside the stretches keep their ids, so a concurrent edit of them
/// survives; points inside are replaced.
public struct FreeformContour: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public var point: Point
        public let original: Point
        /// The drawn point this sample is, if it is one.
        public let owner: Int?
        /// Arc length from the contour's first point.
        public let arc: Double

        public init(point: Point, original: Point, owner: Int?, arc: Double) {
            self.point = point
            self.original = original
            self.owner = owner
            self.arc = arc
        }
    }

    public let node: OpID
    public let contour: OpID
    public let closed: Bool
    public let points: [VectorPoint]
    public private(set) var samples: [Sample]
    /// Samples per point of arc length (the refit's input density).
    public static let spacing = 1.0

    public init(node: OpID, contour: OpID, closed: Bool, points: [VectorPoint]) {
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

    public let totalLength: Double

    /// The sample nearest `point` and its distance.
    public func nearest(_ point: Point) -> (index: Int, distance: Double)? {
        samples.indices.map { ($0, samples[$0].point.distance(to: point)) }.min { $0.1 < $1.1 }
    }

    public var hasMoved: Bool { samples.contains { $0.point.distance(to: $0.original) > 1e-6 } }

    // MARK: Deformations

    /// Pull *By length*: the stretch `length` long around sample `grab` follows `delta`, fully at
    /// the grab point and fading (a cosine) to nothing at the stretch's ends.
    public mutating func pull(from grab: Int, by delta: Vector, length: Double) {
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
    public mutating func push(at center: Point, radius: Double) {
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
    public mutating func reshape(at center: Point, by delta: Vector, radius: Double, strength: Double) {
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
    public func result(tolerance: Double) -> [VectorPoint]? {
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
    public static func refit(_ samples: [Sample], points: [VectorPoint], fitter: CurveFitter) -> [VectorPoint] {
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
    public static func fixKind(_ point: VectorPoint) -> VectorPoint {
        guard point.kind == .curve, !ContourPoints.smooth(point.inHandle, point.outHandle), point.inHandle != .zero, point.outHandle != .zero else { return point }
        var copy = point
        copy.kind = .corner
        return copy
    }

    /// The preview polyline.
    public var preview: [Point] { samples.map(\.point) + (closed ? [samples[0].point] : []) }
}
