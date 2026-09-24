// FONT-015's outline finishing steps (font-export.adoc, "What happens to your artwork"): the y
// flip into the font's convention, contour directions (outer contours one way, counters the
// other; CFF wants counter-clockwise outer contours in y-up space, TrueType clockwise), points at
// the extremes, rounding to whole units, and cubic → quadratic conversion within half a unit (the
// cu2qu tolerance) for TrueType outlines.

import WTGeometry

/// One quadratic contour: on-curve start points with their control points.
public struct QuadraticContour: Hashable, Sendable {
    public var segments: [QuadraticBezier]

    public init(segments: [QuadraticBezier]) {
        self.segments = segments
    }
}

/// Finishing glyph outlines for a font format.
public enum GlyphContours {
    /// Which way outer contours run, in the space given (x right, y up: counter-clockwise is a
    /// positive shoelace area).
    public enum Direction: Hashable, Sendable {
        case counterClockwise
        case clockwise
    }

    /// The cu2qu tolerance: quadratic curves stay within half a unit of the cubic.
    public static let quadraticTolerance = 0.5

    /// `contours` with y negated (glyph-canvas space ↔ font space).
    public static func flipped(_ contours: [Contour]) -> [Contour] {
        contours.map { $0.applying(.scale(x: 1, y: -1)) }
    }

    /// The nesting depth of each contour: how many of the others contain a point of it.  Even
    /// depths are outer contours, odd depths counters.  The contours must not cross.
    public static func depths(_ contours: [Contour]) -> [Int] {
        contours.enumerated().map { index, contour in
            guard let probe = probe(contour) else { return 0 }
            return contours.enumerated().filter { $0.offset != index && $0.element.windingNumber(at: probe) != 0 }.count
        }
    }

    /// A point on the contour away from its start (the middle of its longest segment).
    static func probe(_ contour: Contour) -> Point? {
        let segments = contour.segments + (contour.closingSegment.map { [$0] } ?? [])
        return segments.max { $0.chordLength + $0.controlPolygonLength < $1.chordLength + $1.controlPolygonLength }?.evaluate(0.5)
    }

    /// `contours` (non-crossing) turned so outer contours run `outer` and counters the other way.
    public static func correctingDirections(_ contours: [Contour], outer: Direction) -> [Contour] {
        let depths = depths(contours)
        return zip(contours, depths).map { contour, depth in
            let area = contour.signedArea()
            guard area != 0 else { return contour }
            let wantsPositive = (depth % 2 == 0) == (outer == .counterClockwise)
            return (area > 0) == wantsPositive ? contour : contour.reversed()
        }
    }

    /// Whether every contour already runs as `correctingDirections` would leave it.
    public static func hasCorrectDirections(_ contours: [Contour], outer: Direction) -> Bool {
        correctingDirections(contours, outer: outer) == contours
    }

    /// Each segment split where its x or y derivative is zero inside it, so the contour has an
    /// on-curve point at every horizontal and vertical extreme.
    public static func addingExtrema(_ contours: [Contour]) -> [Contour] {
        contours.map { contour in
            Contour(segments: contour.segments.flatMap(splitAtExtrema), closed: contour.isClosed)
        }
    }

    /// Whether a segment of `contours` has an extreme strictly inside it (Find Problems' *missing
    /// extrema*), beyond `tolerance` units from its ends.
    public static func isMissingExtrema(_ contours: [Contour], tolerance: Double = 0.5) -> Bool {
        contours.contains { contour in
            contour.segments.contains { segment in
                extremaParameters(segment).contains { t in
                    let point = segment.evaluate(t)
                    return point.distance(to: segment.p0) > tolerance && point.distance(to: segment.p3) > tolerance
                }
            }
        }
    }

    /// The parameters in (0, 1) where the segment's x or y derivative vanishes, ascending.
    static func extremaParameters(_ segment: CubicBezier) -> [Double] {
        guard !segment.isLinear() else { return [] }
        var result: [Double] = []
        for axis in 0..<2 {
            func c(_ point: Point) -> Double { axis == 0 ? point.x : point.y }
            // B'(t)/3 = a t² + b t + c over the control deltas.
            let d0 = c(segment.p1) - c(segment.p0), d1 = c(segment.p2) - c(segment.p1), d2 = c(segment.p3) - c(segment.p2)
            let a = d0 - 2 * d1 + d2, b = 2 * (d1 - d0), k = d0
            for t in Polynomial.quadraticRoots(a, b, k) where t > 1e-6 && t < 1 - 1e-6 {
                result.append(t)
            }
        }
        return result.sorted()
    }

    static func splitAtExtrema(_ segment: CubicBezier) -> [CubicBezier] {
        var pieces: [CubicBezier] = []
        var start = 0.0
        for t in extremaParameters(segment) where t - start > 1e-6 {
            pieces.append(segment.subdivide(from: start, to: t))
            start = t
        }
        pieces.append(start == 0 ? segment : segment.subdivide(from: start, to: 1))
        return pieces
    }

    /// Every point rounded to whole units; segments that collapse to a point are dropped, and
    /// contours with nothing left go.
    public static func rounded(_ contours: [Contour]) -> [Contour] {
        func round(_ point: Point) -> Point { Point(x: point.x.rounded(), y: point.y.rounded()) }
        func round(_ segment: CubicBezier) -> CubicBezier {
            CubicBezier(p0: round(segment.p0), p1: round(segment.p1), p2: round(segment.p2), p3: round(segment.p3))
        }
        func collapsed(_ segment: CubicBezier) -> Bool {
            segment.p0 == segment.p1 && segment.p1 == segment.p2 && segment.p2 == segment.p3
        }
        return contours.compactMap { contour -> Contour? in
            let segments: [CubicBezier] = contour.segments.map(round).filter { !collapsed($0) }
            return segments.isEmpty ? nil : Contour(segments: segments, closed: contour.isClosed)
        }
    }

    /// Whether any point of `contours` is off the unit grid.
    public static func isOffGrid(_ contours: [Contour]) -> Bool {
        contours.contains { contour in
            contour.segments.contains { segment in
                [segment.p0, segment.p1, segment.p2, segment.p3].contains { $0.x != $0.x.rounded() || $0.y != $0.y.rounded() }
            }
        }
    }

    /// The number of points a contour set writes in a CFF charstring (on-curve plus control
    /// points; a line writes one).
    public static func pointCount(_ contours: [Contour]) -> Int {
        contours.reduce(0) { total, contour in
            total + contour.segments.reduce(0) { $0 + ($1.isLinear() ? 1 : 3) }
        }
    }

    // MARK: Quadratic conversion

    /// `contour` as quadratic segments, each cubic split into the fewest equal parts whose
    /// single quadratic approximation stays within `tolerance`.
    public static func quadratic(_ contour: Contour, tolerance: Double = quadraticTolerance) -> QuadraticContour {
        var segments = contour.segments
        if let closing = contour.closingSegment { segments.append(closing) }
        return QuadraticContour(segments: segments.flatMap { quadratics(for: $0, tolerance: tolerance) })
    }

    /// The quadratic pieces of one cubic.
    static func quadratics(for cubic: CubicBezier, tolerance: Double) -> [QuadraticBezier] {
        if cubic.isLinear() {
            return [QuadraticBezier(cubic.p0, Point.lerp(cubic.p0, cubic.p3, 0.5), cubic.p3)]
        }
        for count in 1...64 {
            var pieces: [QuadraticBezier] = []
            var fits = true
            for index in 0..<count {
                let piece = cubic.subdivide(from: Double(index) / Double(count), to: Double(index + 1) / Double(count))
                let quad = approximation(piece)
                guard error(of: quad, against: piece) <= tolerance else {
                    fits = false
                    break
                }
                pieces.append(quad)
            }
            if fits { return pieces }
        }
        // Unreachable for finite input: 64 pieces of a finite cubic are flat within half a unit.
        return [approximation(cubic)]
    }

    /// The quadratic sharing the cubic's ends whose control point is the mean of the two
    /// tangent-line extrapolations.
    static func approximation(_ cubic: CubicBezier) -> QuadraticBezier {
        let control = Point(x: (3 * (cubic.p1.x + cubic.p2.x) - cubic.p0.x - cubic.p3.x) / 4,
                            y: (3 * (cubic.p1.y + cubic.p2.y) - cubic.p0.y - cubic.p3.y) / 4)
        return QuadraticBezier(cubic.p0, control, cubic.p3)
    }

    /// The largest distance from the cubic to the quadratic at sixteen parameter samples.
    static func error(of quad: QuadraticBezier, against cubic: CubicBezier) -> Double {
        (1..<16).map { Double($0) / 16 }.map { cubic.evaluate($0).distance(to: quad.evaluate($0)) }.max() ?? 0
    }
}
