// Builds `ImportedContour`s from the drawing operators every vector format shares: move, line,
// quadratic and cubic curves, close, and arcs (SVG's endpoint arcs, DXF's centre arcs and bulges),
// which become cubic Béziers of at most a quarter turn each (error below 3e-4 of the radius).

import Foundation
import WTGeometry

public struct ImportPathBuilder: Sendable {
    public private(set) var contours: [ImportedContour] = []
    private var current: ImportedContour?

    public init() {}

    /// The point the next segment starts from.
    public var currentPoint: Point? { current?.end ?? contours.last.map { $0.closed ? $0.start : $0.end } }

    /// Whether a contour is open for segments.
    public var hasCurrentContour: Bool { current != nil }

    public mutating func move(to point: Point) {
        finishContour()
        current = ImportedContour(start: point)
    }

    public mutating func line(to point: Point) {
        ensureContour()
        current?.segments.append(.line(to: point))
    }

    public mutating func cubic(_ control1: Point, _ control2: Point, _ end: Point) {
        ensureContour()
        current?.segments.append(.cubic(control1: control1, control2: control2, to: end))
    }

    /// A quadratic curve, raised exactly to a cubic.
    public mutating func quad(_ control: Point, _ end: Point) {
        ensureContour()
        let start = current!.end
        cubic(start + (control - start) * (2.0 / 3), end + (control - end) * (2.0 / 3), end)
    }

    /// Closes the contour; the next segment starts a new one at the same start point.
    public mutating func close() {
        guard var contour = current else {
            return
        }
        contour.closed = true
        contours.append(contour)
        current = nil
    }

    /// Ends the open contour without closing it.
    public mutating func finishContour() {
        if let contour = current {
            contours.append(contour)
        }
        current = nil
    }

    /// The contours built, the open one finished.
    public mutating func build() -> [ImportedContour] {
        finishContour()
        return contours
    }

    /// Continues from the last point, or from the last closed contour's start (SVG and PDF
    /// continue a path after `z`/`h` from the start point).
    private mutating func ensureContour() {
        guard current == nil else {
            return
        }
        current = ImportedContour(start: currentPoint ?? .zero)
    }

    // MARK: Arcs

    /// An arc of the ellipse centred at `center` with radii `rx`, `ry`, its x axis rotated by
    /// `rotation` radians, from angle `start` sweeping `sweep` radians (positive in the direction
    /// of increasing angle).  Starts a contour at the arc's start when none is open, else draws
    /// a line to it first.
    public mutating func arc(center: Point, rx: Double, ry: Double, rotation: Double = 0, start: Double, sweep: Double) {
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        func point(_ angle: Double) -> Point {
            let x = rx * cos(angle)
            let y = ry * sin(angle)
            return Point(x: center.x + x * cosR - y * sinR, y: center.y + x * sinR + y * cosR)
        }
        func derivative(_ angle: Double) -> Vector {
            let x = -rx * sin(angle)
            let y = ry * cos(angle)
            return Vector(dx: x * cosR - y * sinR, dy: x * sinR + y * cosR)
        }
        let first = point(start)
        if let here = current?.end {
            if !here.isApproximatelyEqual(to: first, tolerance: 1e-9) {
                line(to: first)
            }
        } else {
            move(to: first)
        }
        guard sweep != 0, sweep.isFinite else {
            return
        }
        let pieces = max(Int((abs(sweep) / (.pi / 2) - 1e-9).rounded(.up)), 1)
        let step = sweep / Double(pieces)
        let k = 4.0 / 3 * tan(step / 4)
        var angle = start
        for _ in 0..<pieces {
            let next = angle + step
            let p0 = point(angle)
            let p3 = point(next)
            cubic(p0 + derivative(angle) * k, p3 - derivative(next) * k, p3)
            angle = next
        }
    }

    /// SVG's endpoint arc (SVG 1.1 implementation notes F.6.5) from the current point to `end`.
    public mutating func svgArc(rx: Double, ry: Double, rotationDegrees: Double, largeArc: Bool, sweep: Bool, to end: Point) {
        let start = currentPoint ?? .zero
        var rx = abs(rx)
        var ry = abs(ry)
        if start.isApproximatelyEqual(to: end, tolerance: 1e-12) {
            return
        }
        if rx < 1e-12 || ry < 1e-12 {
            line(to: end)
            return
        }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = (max(numerator, 0) / denominator).squareRoot()
        if largeArc == sweep {
            factor = -factor
        }
        let cx1 = factor * rx * y1 / ry
        let cy1 = -factor * ry * x1 / rx
        let center = Point(x: cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2, y: sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2)
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 {
            delta -= 2 * .pi
        } else if sweep && delta < 0 {
            delta += 2 * .pi
        }
        arc(center: center, rx: rx, ry: ry, rotation: phi, start: theta, sweep: delta)
        // Land exactly on the requested end point.
        if var contour = current, case .cubic(let c1, let c2, _) = contour.segments.last {
            contour.segments[contour.segments.count - 1] = .cubic(control1: c1, control2: c2, to: end)
            current = contour
        }
    }

    /// A DXF polyline bulge from the current point to `end`: `bulge` is the tangent of a quarter
    /// of the included angle, positive counter-clockwise in DXF's y-up space (pass the bulge as
    /// the file has it and `yDown` true when the points are already flipped).
    public mutating func bulge(_ bulge: Double, to end: Point, yDown: Bool) {
        let start = currentPoint ?? .zero
        guard abs(bulge) > 1e-12, !start.isApproximatelyEqual(to: end, tolerance: 1e-12) else {
            line(to: end)
            return
        }
        let chord = end - start
        let length = chord.length
        let included = 4 * atan(bulge)
        let radius = length / (2 * sin(included / 2))
        // Counter-clockwise in y-up is clockwise once y is flipped.
        let sign: Double = yDown ? -1 : 1
        let direction = sign * included
        let mid = Point.lerp(start, end, 0.5)
        let sagittaToCenter = radius * cos(included / 2)
        let normal = Vector(dx: -chord.dy / length, dy: chord.dx / length) * (sign)
        let center = mid + normal * sagittaToCenter
        let startAngle = atan2(start.y - center.y, start.x - center.x)
        let r = abs(radius)
        arc(center: center, rx: r, ry: r, start: startAngle, sweep: direction)
        if var contour = current, case .cubic(let c1, let c2, _) = contour.segments.last {
            contour.segments[contour.segments.count - 1] = .cubic(control1: c1, control2: c2, to: end)
            current = contour
        }
    }

    // MARK: Shapes

    /// A closed rectangle contour.
    public mutating func rect(_ rect: Rect) {
        move(to: Point(x: rect.minX, y: rect.minY))
        line(to: Point(x: rect.maxX, y: rect.minY))
        line(to: Point(x: rect.maxX, y: rect.maxY))
        line(to: Point(x: rect.minX, y: rect.maxY))
        close()
    }

    /// A closed ellipse contour of four quarter arcs, starting at its rightmost point.
    public mutating func ellipse(center: Point, rx: Double, ry: Double, rotation: Double = 0) {
        finishContour()
        arc(center: center, rx: rx, ry: ry, rotation: rotation, start: 0, sweep: 2 * .pi)
        if var contour = current, case .cubic(let c1, let c2, _) = contour.segments.last {
            contour.segments[contour.segments.count - 1] = .cubic(control1: c1, control2: c2, to: contour.start)
            current = contour
        }
        close()
    }
}
