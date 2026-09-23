import Foundation
import WTGeometry

/// The Spiral sheet's settings (spirals-arcs.adoc, "Spirals"): what the geometry needs beyond the
/// centre and the outer end.
public struct SpiralOptions: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// Every turn the same distance from the previous one (Archimedean).
        case concentric
        /// Each turn wider than the one before by `expansion` percent (logarithmic).
        case expanding
    }

    public enum DrawBy: String, Hashable, Sendable, CaseIterable {
        /// Always `rotations` turns, whatever the size.
        case rotations
        /// A turn every `incrementWidth`, so dragging further adds turns.
        case increments
    }

    public var kind: Kind
    public var drawBy: DrawBy
    /// Number of rotations (draw by rotations), at least a quarter turn.
    public var rotations: Double
    /// Distance between turns (concentric, draw by increments), points.
    public var incrementWidth: Double
    /// The innermost turn's radius (expanding, draw by increments), points.
    public var startingRadius: Double
    /// Expansion per turn, 1...100 percent (expanding).
    public var expansion: Double
    /// Clockwise winding seen from the centre outward (on screen, y down).
    public var clockwise: Bool

    public init(kind: Kind = .concentric, drawBy: DrawBy = .rotations, rotations: Double = 3, incrementWidth: Double = 12,
                startingRadius: Double = 6, expansion: Double = 50, clockwise: Bool = true) {
        self.kind = kind
        self.drawBy = drawBy
        self.rotations = rotations
        self.incrementWidth = incrementWidth
        self.startingRadius = startingRadius
        self.expansion = expansion
        self.clockwise = clockwise
    }
}

extension ShapeGeometry {
    /// The most quarter turns a spiral takes (1,000 rotations).
    public static let maximumQuarterTurns = 4_000

    /// A spiral from `center` out to `outer` (spirals-arcs.adoc, "Client"): an open contour of
    /// curve points, one every quarter turn (and one at the outer end when the turns do not come
    /// out even), running from the centre outward; the outer end lies exactly on `outer`.  Each
    /// quarter-turn arc is one cubic whose handles follow the spiral's tangent, scaled by the
    /// circular-arc constant `4/3 · tan(Δθ/4)` so a turn of constant radius is a circle's
    /// standard approximation.  A 3-rotation concentric spiral has 13 points.  Empty when `outer`
    /// is on the centre.
    public static func spiralPath(_ options: SpiralOptions, center: Point, outer: Point) -> VectorPath {
        let radius = center.distance(to: outer)
        guard radius > 0, radius.isFinite else { return VectorPath(contours: []) }
        let sign: Double = options.clockwise ? 1 : -1
        let endAngle = atan2(outer.y - center.y, outer.x - center.x)
        // r(θ) for θ in 0...total, measured from the centre outward.
        let total: Double
        let r: (Double) -> Double
        let dr: (Double) -> Double
        switch (options.kind, options.drawBy) {
        case (.concentric, .rotations):
            total = 2 * .pi * max(options.rotations, 0.25)
            let a = radius / total
            r = { a * $0 }
            dr = { _ in a }
        case (.concentric, .increments):
            let a = max(options.incrementWidth, 0.001) / (2 * .pi)
            total = max(radius / a, .pi / 2)
            let scale = radius / (a * total)
            r = { a * scale * $0 }
            dr = { _ in a * scale }
        case (.expanding, let drawBy):
            let b = log(1 + min(max(options.expansion, 1), 100) / 100) / (2 * .pi)
            if drawBy == .rotations {
                total = 2 * .pi * max(options.rotations, 0.25)
            } else {
                let start = min(max(options.startingRadius, 0.001), radius)
                total = max(log(radius / start) / b, .pi / 2)
            }
            let r0 = radius / exp(b * total)
            r = { r0 * exp(b * $0) }
            dr = { b * r0 * exp(b * $0) }
        }
        let quarter = Double.pi / 2
        var angles: [Double] = []
        var theta = 0.0
        while theta < total - 1e-9, angles.count < maximumQuarterTurns {
            angles.append(theta)
            theta += quarter
        }
        angles.append(total)
        // The point at spiral angle θ turns by sign·(θ - total) from the outer end's direction.
        func position(_ theta: Double) -> Point {
            let phi = endAngle + sign * (theta - total)
            return Point(x: center.x + r(theta) * cos(phi), y: center.y + r(theta) * sin(phi))
        }
        func tangent(_ theta: Double) -> Vector {
            let phi = endAngle + sign * (theta - total)
            let radial = Vector(dx: cos(phi), dy: sin(phi))
            let around = Vector(dx: -sin(phi), dy: cos(phi)) * sign
            return radial * dr(theta) + around * r(theta)
        }
        var points = angles.map { VectorPoint(anchor: position($0), kind: .curve) }
        for index in 0..<(angles.count - 1) {
            let step = angles[index + 1] - angles[index]
            let factor = 4.0 / 3.0 * tan(step / 4)
            points[index].outHandle = tangent(angles[index]) * factor
            points[index + 1].inHandle = -(tangent(angles[index + 1]) * factor)
        }
        return VectorPath(contours: [VectorContour(points: points)])
    }

    /// A quarter-ellipse arc across the box from `start` to `end` (spirals-arcs.adoc, "Arcs"):
    /// one cubic with the quarter-circle constant.  The curve's centre is the box corner below
    /// `start` and level with `end` -- the other corner when `flipped` -- so it bulges away from
    /// that corner; `concave` centres it on the opposite corner so it bends toward it.  Open: two
    /// points; closed: a third point at the corner, joined by two straight sides.  Empty for a
    /// box without area.
    public static func arcPath(from start: Point, to end: Point, open: Bool, flipped: Bool, concave: Bool) -> VectorPath {
        guard start.x != end.x, start.y != end.y, start.isFinite, end.isFinite else { return VectorPath(contours: []) }
        let corner = flipped ? Point(x: end.x, y: start.y) : Point(x: start.x, y: end.y)
        let opposite = flipped ? Point(x: start.x, y: end.y) : Point(x: end.x, y: start.y)
        let center = concave ? opposite : corner
        // Each end's handle points along the side of the ellipse box it leaves toward the other end.
        let startHandle = (start - center).dx == 0 ? Vector(dx: end.x - center.x, dy: 0) : Vector(dx: 0, dy: end.y - center.y)
        let endHandle = (end - center).dx == 0 ? Vector(dx: start.x - center.x, dy: 0) : Vector(dx: 0, dy: start.y - center.y)
        var points = [
            VectorPoint(anchor: start, outHandle: startHandle * kappa),
            VectorPoint(anchor: end, inHandle: endHandle * kappa),
        ]
        if !open {
            points.append(VectorPoint(anchor: corner))
        }
        return VectorPath(contours: [VectorContour(closed: !open, points: points)])
    }
}
