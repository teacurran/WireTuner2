import Foundation

// Select Similar's shape classifier (selecting.adoc, "Select Similar"; IMG-030): the classes and
// the feature vector a path is classified by.  The feature extraction is pure geometry, shared by
// the app and by the training tool (tools/shape-classifier), so the model sees at run time exactly
// what it was trained on.

/// What kind of shape an object is.  The first eleven are the model's; groups, text blocks and
/// images are classed without it.
public enum ShapeClass: String, CaseIterable, Hashable, Sendable {
    case circle, ellipse, rectangle
    case roundedRectangle = "rounded_rectangle"
    case triangle, polygon, star, arrow, line, letterform, blob
    case group, text, image

    /// The classes the model predicts.
    public static let modelled: [ShapeClass] = [.circle, .ellipse, .rectangle, .roundedRectangle, .triangle, .polygon, .star, .arrow, .line,
                                                .letterform, .blob]
}

/// A path's feature vector (selecting.adoc, "Select Similar"): its main outline resampled to 64
/// points by arc length after translation, scale and rotation normalization, then the outline's
/// corner count, convexity, aspect and hole count -- and, beyond the spec's list, the number of
/// contours, whether the outline is closed and its circularity, which separate letterforms,
/// lines and circles from their neighbours cheaply.
///
/// Normalization: the centroid of the outline goes to the origin, its principal axis onto x (by
/// the covariance of the resampled points), the axes are flipped so the third moments along them
/// are not negative, a closed outline runs counterclockwise, and the root-mean-square radius is 1.
/// A closed outline then starts at its rightmost point, an open one at the end further left, so
/// neither where the path was started nor its direction matters.
public struct ShapeFeatures: Hashable, Sendable {
    /// How many outline points the vector holds.
    public static let pointCount = 64
    /// Samples along the outline before the points are taken (four per point).
    static let denseCount = 256
    /// A joint turning more than this (radians) is a corner.
    static let cornerAngle = 0.52

    /// The normalized outline points.
    public var points: [Point]
    /// Joints of the main outline where the direction turns by more than 30°.
    public var corners: Int
    /// The outline's area over its convex hull's (1 for a convex outline or a line).
    public var convexity: Double
    /// Minor over major principal extent, 0 (a line) to 1 (isotropic).
    public var aspect: Double
    /// Closed contours inside the main outline.
    public var holes: Int
    /// Contours the path has.
    public var contours: Int
    /// Whether the main outline is closed.
    public var closed: Bool
    /// 4πA/P² of the main outline (1 for a circle), 0 when open.
    public var circularity: Double

    /// The features of a path made of `contours` (in whatever space it is drawn: the features do
    /// not depend on position, size or rotation); nil when nothing of it has length.
    public init?(_ contours: [Contour]) {
        let outlines = contours.map { Self.polyline($0) }.filter { $0.points.count >= 2 && Self.length($0.points, closed: $0.closed) > 1e-9 }
        guard !outlines.isEmpty else { return nil }
        let main = outlines.max { a, b in
            let areaA = a.closed ? abs(Self.signedArea(a.points)) : 0, areaB = b.closed ? abs(Self.signedArea(b.points)) : 0
            if areaA != areaB { return areaA < areaB }
            return Self.length(a.points, closed: a.closed) < Self.length(b.points, closed: b.closed)
        }!
        let isClosed = main.closed && abs(Self.signedArea(main.points)) > 1e-9
        var dense = Self.resample(main.points, closed: isClosed, count: Self.denseCount)
        // Translation and the principal axis.
        let n = Double(dense.count)
        let cx = dense.reduce(0) { $0 + $1.x } / n, cy = dense.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in dense {
            let dx = p.x - cx, dy = p.y - cy
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        sxx /= n
        syy /= n
        sxy /= n
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        let trace = sxx + syy, spread = ((sxx - syy) * (sxx - syy) + 4 * sxy * sxy).squareRoot()
        let major = (trace + spread) / 2, minor = max((trace - spread) / 2, 0)
        let (c, s) = (cos(-angle), sin(-angle))
        dense = dense.map { p in
            let dx = p.x - cx, dy = p.y - cy
            return Point(x: dx * c - dy * s, y: dx * s + dy * c)
        }
        // Scale: the root-mean-square radius becomes 1.
        let rms = (dense.reduce(0) { $0 + $1.x * $1.x + $1.y * $1.y } / n).squareRoot()
        guard rms > 1e-12 else { return nil }
        dense = dense.map { Point(x: $0.x / rms, y: $0.y / rms) }
        // Flip the axes so the third moments are not negative.
        if dense.reduce(0, { $0 + $1.x * $1.x * $1.x }) < -1e-9 { dense = dense.map { Point(x: -$0.x, y: $0.y) } }
        if dense.reduce(0, { $0 + $1.y * $1.y * $1.y }) < -1e-9 { dense = dense.map { Point(x: $0.x, y: -$0.y) } }
        // Direction and start.
        if isClosed {
            if Self.signedArea(dense) < 0 { dense.reverse() }
            let start = dense.indices.max { a, b in dense[a].x != dense[b].x ? dense[a].x < dense[b].x : dense[a].y < dense[b].y }!
            dense = Array(dense[start...] + dense[..<start])
            let step = dense.count / Self.pointCount
            points = (0..<Self.pointCount).map { dense[$0 * step] }
        } else {
            if dense[0].x > dense[dense.count - 1].x { dense.reverse() }
            points = (0..<Self.pointCount).map { dense[Int((Double($0) * Double(dense.count - 1) / Double(Self.pointCount - 1)).rounded())] }
        }
        self.contours = outlines.count
        closed = isClosed
        aspect = major > 1e-18 ? (minor / major).squareRoot() : 1
        corners = Self.corners(of: contours.first { Self.polyline($0).points == main.points } ?? Contour(polygon: main.points, closed: main.closed),
                               scale: rms)
        let area = abs(Self.signedArea(main.points))
        let hull = abs(Self.signedArea(Self.convexHull(main.points)))
        convexity = hull > 1e-12 ? min(area / hull, 1) : 1
        let perimeter = Self.length(main.points, closed: true)
        circularity = isClosed && perimeter > 0 ? min(4 * .pi * area / (perimeter * perimeter), 1) : 0
        holes = outlines.filter { $0.closed && $0.points != main.points && Self.inside($0.points[0], main.points) }.count
    }

    /// The vector in the model's column order (`names`).
    public var values: [Double] {
        points.flatMap { [$0.x, $0.y] } + [Double(corners), convexity, aspect, Double(holes), Double(contours), closed ? 1 : 0, circularity]
    }

    /// The model's input column names, in `values` order.
    public static let names: [String] = (0..<pointCount).flatMap { ["x\($0)", "y\($0)"] }
        + ["corners", "convexity", "aspect", "holes", "contours", "closed", "circularity"]

    // MARK: Geometry

    /// A contour as a polyline: a straight segment's end, or twelve steps along a curved one.
    static func polyline(_ contour: Contour) -> (points: [Point], closed: Bool) {
        guard let start = contour.startPoint else { return ([], contour.isClosed) }
        var points = [start]
        for segment in contour.segments {
            if segment.isLinear(tolerance: 1e-9 * max(segment.controlPolygonLength, 1)) {
                points.append(segment.p3)
            } else {
                for step in 1...12 { points.append(segment.evaluate(Double(step) / 12)) }
            }
        }
        if contour.isClosed, points.count > 1, points[points.count - 1].isApproximatelyEqual(to: points[0], tolerance: 1e-9) { points.removeLast() }
        return (points.filter(\.isFinite), contour.isClosed)
    }

    static func length(_ points: [Point], closed: Bool) -> Double {
        guard points.count > 1 else { return 0 }
        var total = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        if closed { total += points[points.count - 1].distance(to: points[0]) }
        return total
    }

    /// Twice-halved shoelace area: positive counterclockwise in y-up terms.
    static func signedArea(_ points: [Point]) -> Double {
        guard points.count > 2 else { return 0 }
        var sum = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// `count` points evenly spaced by arc length along the polyline, from its start (a closed one
    /// wraps round without repeating the start; an open one ends at its end).
    static func resample(_ points: [Point], closed: Bool, count: Int) -> [Point] {
        let ring = closed ? points + [points[0]] : points
        var cumulative = [0.0]
        for (a, b) in zip(ring, ring.dropFirst()) { cumulative.append(cumulative[cumulative.count - 1] + a.distance(to: b)) }
        let total = cumulative[cumulative.count - 1]
        let step = total / Double(closed ? count : count - 1)
        var result: [Point] = []
        result.reserveCapacity(count)
        var segment = 0
        for index in 0..<count {
            let target = min(Double(index) * step, total)
            while segment < ring.count - 2 && cumulative[segment + 1] < target { segment += 1 }
            let span = cumulative[segment + 1] - cumulative[segment]
            let t = span > 0 ? (target - cumulative[segment]) / span : 0
            result.append(Point.lerp(ring[segment], ring[segment + 1], t))
        }
        return result
    }

    /// Joints between consecutive segments (and the closing joint) turning by more than
    /// `cornerAngle`; degenerate segments are skipped.
    static func corners(of contour: Contour, scale: Double) -> Int {
        let segments = contour.segments.filter { $0.p0.distance(to: $0.p3) + $0.controlPolygonLength > scale * 1e-6 }
        guard segments.count > 1 else { return 0 }
        func turn(_ incoming: CubicBezier, _ outgoing: CubicBezier) -> Double {
            let a = incoming.tangent(1), b = outgoing.tangent(0)
            return abs(atan2(a.cross(b), a.dot(b)))
        }
        var count = 0
        for (a, b) in zip(segments, segments.dropFirst()) where turn(a, b) > cornerAngle { count += 1 }
        if contour.isClosed, turn(segments[segments.count - 1], segments[0]) > cornerAngle { count += 1 }
        return count
    }

    /// The convex hull (Andrew's monotone chain), counterclockwise.
    static func convexHull(_ points: [Point]) -> [Point] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: Point, _ a: Point, _ b: Point) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [Point] = [], upper: [Point] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Even-odd point-in-polygon.
    static func inside(_ point: Point, _ polygon: [Point]) -> Bool {
        var result = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
            j = i
        }
        return result
    }
}
