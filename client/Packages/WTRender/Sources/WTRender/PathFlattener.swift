// Curve flattening at the shared tolerance (docs/spec/client.adoc, "Metal tile renderer",
// *Path filling*): the Metal renderer fills polygons, so every path is reduced to line segments
// in device pixels before it reaches the GPU.  Pure CPU maths, no Metal.

import WTGeometry
import CoreGraphics

/// A set of closed polygons in device pixels: what the stencil pass fans and the cover pass
/// bounds.  Contours are implicitly closed, as a fill closes every subpath.
struct FlatPath: Hashable, Sendable {
    /// Every contour's vertices, back to back.
    var points: [SIMD2<Double>] = []
    /// `points` ranges, one per contour of at least three vertices.
    var contours: [Range<Int>] = []

    var isEmpty: Bool { contours.isEmpty }

    /// The bounding box of every contour's vertices; nil for an empty path.
    var bounds: Rect? {
        guard !contours.isEmpty else {
            return nil
        }
        var result = Rect.null
        for contour in contours {
            for point in points[contour] {
                result.formUnion(Point(x: point.x, y: point.y))
            }
        }
        return result
    }

    /// How many triangles the stencil fan of this path has.
    var fanTriangleCount: Int {
        contours.reduce(0) { $0 + $1.count - 2 }
    }

    /// Appends one contour; fewer than three vertices enclose nothing and are dropped.
    mutating func append(contour: [SIMD2<Double>]) {
        guard contour.count >= 3 else {
            return
        }
        let start = points.count
        points.append(contentsOf: contour)
        contours.append(start..<points.count)
    }

    /// Every contour clipped to `rect` (Sutherland–Hodgman).  Clipping each contour
    /// independently against a convex region preserves the winding number of every point
    /// inside it, so both fill rules fill the clipped path exactly as they fill the original
    /// within `rect`.  Keeps coordinates small enough for `Float` at extreme zoom.
    func clipped(to rect: Rect) -> FlatPath {
        var result = FlatPath()
        for contour in contours {
            var polygon = Array(points[contour])
            polygon = FlatPath.clip(polygon, axis: 0, bound: rect.minX, keepGreater: true)
            polygon = FlatPath.clip(polygon, axis: 0, bound: rect.maxX, keepGreater: false)
            polygon = FlatPath.clip(polygon, axis: 1, bound: rect.minY, keepGreater: true)
            polygon = FlatPath.clip(polygon, axis: 1, bound: rect.maxY, keepGreater: false)
            result.append(contour: polygon)
        }
        return result
    }

    private static func clip(_ polygon: [SIMD2<Double>], axis: Int, bound: Double, keepGreater: Bool) -> [SIMD2<Double>] {
        guard let last = polygon.last else {
            return []
        }
        func inside(_ point: SIMD2<Double>) -> Bool {
            keepGreater ? point[axis] >= bound : point[axis] <= bound
        }
        var result: [SIMD2<Double>] = []
        result.reserveCapacity(polygon.count + 2)
        var previous = last
        for point in polygon {
            let pointInside = inside(point)
            if pointInside != inside(previous) {
                let t = (bound - previous[axis]) / (point[axis] - previous[axis])
                result.append(previous + (point - previous) * t)
            }
            if pointInside {
                result.append(point)
            }
            previous = point
        }
        return result
    }
}

/// Reduces display paths and Core Graphics paths to `FlatPath`s.
struct PathFlattener: Sendable {
    /// The tolerance in device pixels; the flattener works in device pixels, so this is
    /// `FlatteningTolerance.devicePixels` unchanged.
    let tolerance: Double

    init(tolerance: FlatteningTolerance) {
        self.tolerance = tolerance.devicePixels
    }

    /// `path` mapped through `transform` (local → device pixels) and flattened.  Affine maps
    /// keep Bézier curves Bézier, so curves are transformed first and flattened in pixels.
    func flatten(_ path: DisplayPath, transform: AffineTransform) -> FlatPath {
        var result = FlatPath()
        var contour: [SIMD2<Double>] = []
        var start: SIMD2<Double>?
        var current: SIMD2<Double>?

        func map(_ point: Point) -> SIMD2<Double> {
            let mapped = transform.apply(point)
            return SIMD2(mapped.x, mapped.y)
        }
        func flush() {
            result.append(contour: contour)
            contour.removeAll(keepingCapacity: true)
        }
        func begin(at point: SIMD2<Double>) {
            flush()
            start = point
            current = point
            contour.append(point)
        }

        for element in path.elements {
            switch element {
            case .move(let point):
                begin(at: map(point))
            case .line(let point):
                let end = map(point)
                if current == nil {
                    begin(at: end)
                } else {
                    contour.append(end)
                    current = end
                }
            case .quadCurve(let control, let point):
                let end = map(point)
                if let from = current {
                    appendQuad(from, map(control), end, to: &contour)
                    current = end
                } else {
                    begin(at: end)
                }
            case .cubicCurve(let control1, let control2, let point):
                let end = map(point)
                if let from = current {
                    appendCubic(from, map(control1), map(control2), end, to: &contour)
                    current = end
                } else {
                    begin(at: end)
                }
            case .close:
                // Drawing after a close starts a new subpath at the closed one's start.
                flush()
                if let start {
                    contour.append(start)
                }
                current = start
            }
        }
        flush()
        return result
    }

    /// A Core Graphics path (a stroked outline) mapped through `transform` and flattened.
    func flatten(_ path: CGPath, transform: AffineTransform) -> FlatPath {
        flatten(DisplayPath(path), transform: transform)
    }

    /// Segments for a quadratic by Wang's formula: n = ⌈√(|p0 − 2p1 + p2| / (4·tol))⌉.
    func segmentCount(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>, _ p2: SIMD2<Double>) -> Int {
        let deviation = simdLength(p0 - 2 * p1 + p2)
        return PathFlattener.clampedCount((deviation / (4 * tolerance)).squareRoot())
    }

    /// Segments for a cubic by Wang's formula: n = ⌈√(3·M / (4·tol))⌉ with M the larger second
    /// difference of the control polygon.
    func segmentCount(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ p3: SIMD2<Double>) -> Int {
        let deviation = max(simdLength(p0 - 2 * p1 + p2), simdLength(p1 - 2 * p2 + p3))
        return PathFlattener.clampedCount((3 * deviation / (4 * tolerance)).squareRoot())
    }

    private static func clampedCount(_ value: Double) -> Int {
        guard value.isFinite else {
            return 1
        }
        return min(max(Int(value.rounded(.up)), 1), 4096)
    }

    private func appendQuad(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>, _ p2: SIMD2<Double>, to contour: inout [SIMD2<Double>]) {
        let count = segmentCount(p0, p1, p2)
        for index in 1...count {
            let t = Double(index) / Double(count)
            let u = 1 - t
            contour.append(u * u * p0 + 2 * u * t * p1 + t * t * p2)
        }
    }

    private func appendCubic(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ p3: SIMD2<Double>, to contour: inout [SIMD2<Double>]) {
        let count = segmentCount(p0, p1, p2, p3)
        for index in 1...count {
            let t = Double(index) / Double(count)
            let u = 1 - t
            contour.append(u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3)
        }
    }
}

private func simdLength(_ vector: SIMD2<Double>) -> Double {
    (vector * vector).sum().squareRoot()
}

extension DisplayPath {
    /// A Core Graphics path as display-path elements, so stroked outlines flatten through
    /// the same code as every other path.
    init(_ path: CGPath) {
        var elements: [Element] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            func point(_ index: Int) -> Point {
                Point(x: Double(points[index].x), y: Double(points[index].y))
            }
            switch element.type {
            case .moveToPoint:
                elements.append(.move(to: point(0)))
            case .addLineToPoint:
                elements.append(.line(to: point(0)))
            case .addQuadCurveToPoint:
                elements.append(.quadCurve(control: point(0), end: point(1)))
            case .addCurveToPoint:
                elements.append(.cubicCurve(control1: point(0), control2: point(1), end: point(2)))
            case .closeSubpath:
                elements.append(.close)
            @unknown default:
                break
            }
        }
        self.init(elements: elements)
    }
}
