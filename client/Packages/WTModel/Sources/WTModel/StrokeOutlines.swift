import Foundation
import WTGeometry

/// WTGeometry contours as path points (drawing order, pasteboard space): one point per segment
/// start, handles from the cubic controls, a closing straight segment when the contour does not
/// end where it began.  Junctions with collinear handles are curve points.
public enum ContourPoints {
    public static func points(_ contour: Contour) -> [VectorPoint] {
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

    public static func smooth(_ inHandle: Vector, _ outHandle: Vector) -> Bool {
        guard inHandle.lengthSquared > 0, outHandle.lengthSquared > 0 else { return false }
        return inHandle.normalized.dot(outHandle.normalized) < -0.9998
    }

    /// The segments of path points (drawing order), closed or open.
    public static func segments(_ points: [VectorPoint], closed: Bool) -> [CubicBezier] {
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
public enum VariableStrokeOutline {
    /// The samples of a stroke: positions and the width at each.
    public struct Sample: Equatable, Sendable {
        public var point: Point
        public var width: Double

        public init(point: Point, width: Double) {
            self.point = point
            self.width = width
        }
    }

    /// Fit tolerance of the outline, points (well under the 0.1 pt the width is held to).
    public static let tolerance = 0.03

    /// The width at fraction `fraction` (0...1) of the samples' polyline length.
    public static func width(at fraction: Double, samples: [Sample]) -> Double {
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
    public static func outline(centerline: [VectorPoint], samples: [Sample]) -> Contour? {
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
    public static func direction(_ tangent: Vector, otherwise: Vector) -> Vector {
        tangent.lengthSquared > 0 ? tangent.normalized : otherwise
    }

    /// The semicircle from `start` around `center`, bulging along `forward` (the stroke's
    /// direction at that end), without its end points.
    public static func cap(center: Point, from start: Point, forward: Vector) -> [Point] {
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
    public static func removingOverlap(_ outline: Contour) -> [Contour] {
        Boolean.normalize(FilledPath(outline)).contours.filter { !$0.isEmpty }
    }
}

/// The Calligraphic Pen's outline (freeform.adoc, "Calligraphic Pen"; DRAW-019): each sample's
/// width is `base · |sin(θ_stroke − θ_nib)|`, at least half a point, where `base` is the fixed
/// width or the pressure- or bracket-set width; the fitted centreline is offset by half of it on
/// each side and the ends are cut flat.
public enum CalligraphicOutline {
    /// The narrowest a stroke gets, points.
    public static let minimumWidth = 0.5

    /// The width of a stroke moving along `direction` with a nib at `nibAngle` (degrees) and full
    /// width `base`.
    public static func width(base: Double, direction: Vector, nibAngle: Double) -> Double {
        guard direction.lengthSquared > 0 else { return max(base, minimumWidth) }
        // Pasteboard y runs down; the nib angle is measured counter-clockwise on the page.
        let stroke = atan2(-direction.dy, direction.dx)
        let nib = nibAngle * .pi / 180
        return max(base * abs(sin(stroke - nib)), minimumWidth)
    }

    /// The samples with their widths from each one's direction of travel.
    public static func samples(_ points: [Point], bases: [Double], nibAngle: Double) -> [VariableStrokeOutline.Sample] {
        points.indices.map { index in
            let from = points[max(index - 1, 0)], to = points[min(index + 1, points.count - 1)]
            return VariableStrokeOutline.Sample(point: points[index], width: width(base: bases[min(index, bases.count - 1)], direction: to - from, nibAngle: nibAngle))
        }
    }

    /// The outline of `centerline` with the widths of `samples`, flat at both ends; nil for a
    /// stroke too short to draw.
    public static func outline(centerline: [VectorPoint], samples: [VariableStrokeOutline.Sample]) -> Contour? {
        let segments = ContourPoints.segments(centerline, closed: false)
        guard !segments.isEmpty else { return nil }
        let lengths = segments.map { $0.length(tolerance: 1e-4) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return nil }
        var left: [Point] = [], right: [Point] = []
        var travelled = 0.0
        var last = Vector(dx: 1, dy: 0)
        for (segment, length) in zip(segments, lengths) where length > 0 {
            let steps = max(8, Int((length / 1.5).rounded(.up)))
            for step in 0...steps where step > 0 || left.isEmpty {
                let t = Double(step) / Double(steps)
                let direction = VariableStrokeOutline.direction(segment.tangent(t), otherwise: last)
                last = direction
                let arc = travelled + segment.length(from: 0, to: t, tolerance: 1e-4)
                let half = VariableStrokeOutline.width(at: arc / total, samples: samples) / 2
                let point = segment.evaluate(t)
                left.append(point + direction.perpendicular * half)
                right.append(point - direction.perpendicular * half)
            }
            travelled += length
        }
        return flatEnded(left: left, right: right)
    }

    /// The closed contour through `left` then `right` reversed, fitted with a corner at each of
    /// the four cap corners.  The fitter's own corner test merges adjacent corners into one, so
    /// on its own it would keep only the left corner of the end cap and round the right one
    /// outwards (about a point past the last sample with the nib across the stroke).
    public static func flatEnded(left: [Point], right: [Point]) -> Contour {
        let ring = left + right.reversed() + [left[0]]
        var points: [Point] = [], capCorner: [Bool] = []
        for (index, point) in ring.enumerated() {
            let corner = index == left.count - 1 || index == left.count || index == ring.count - 2
            if let previous = points.last, previous == point {
                capCorner[capCorner.count - 1] = capCorner[capCorner.count - 1] || corner
            } else {
                points.append(point)
                capCorner.append(corner)
            }
        }
        let fitter = CurveFitter(maxError: VariableStrokeOutline.tolerance, cornerAngle: 1.2)
        let detected = CurveFitter.corners(in: points, angle: fitter.cornerAngle, window: fitter.cornerWindow)
        let corners = Set(detected + capCorner.indices.filter { capCorner[$0] }).sorted()
        return fitter.fitContour(points, corners: corners, closed: true)
    }
}
