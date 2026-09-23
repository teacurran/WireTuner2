// Calligraphic strokes (ATTR-011; docs/_includes/appearance/stroke-attributes.adoc, "Client"):
// the nib swept along the path.  The swept region of a polygon N along a segment [a, b] is the
// Minkowski sum, which is exactly N at a, N at b and every edge of N swept from a to b (a
// parallelogram): a point the moving nib covers is either in a copy at an end or is crossed
// by the nib's boundary on the way.  Every piece is oriented positively, so their non-zero fill
// is the union -- no boolean pass, no gaps at corners or cusps (each vertex carries a nib copy),
// and no spikes (nothing lies outside the sum).  Works for any simple nib, convex or not.

import WTGeometry
import Foundation

enum CalligraphicSweep {
    private struct Key: Hashable, Sendable {
        let nib: CalligraphicNib
        let path: DisplayPath
        let tolerance: Double
    }

    private static let cache = RenderCache<Key, DisplayPath>(capacity: 512)

    /// The nib as a closed polygon in local units, centred on the origin: the custom shape
    /// scaled by width and height (or the ellipse), then rotated by the angle.  Empty for a nib
    /// with no extent.
    static func nibPolygon(_ nib: CalligraphicNib, tolerance: Double) -> [Point] {
        let width = nib.width.isFinite ? abs(nib.width) : 0
        let height = nib.height.isFinite ? abs(nib.height) : 0
        guard width > 0 || height > 0 else {
            return []
        }
        let rotation = AffineTransform.rotation(degrees: nib.angle.isFinite ? nib.angle : 0)
        var unit: [Point]
        if let shape = nib.shape, let contour = singleClosedContour(shape) {
            let arc = ArcLengthPath(contour: contour, tolerance: tolerance / max(width, height, 1))
            unit = arc.points
            if unit.count > 1 && unit.first == unit.last {
                unit.removeLast()
            }
        } else {
            // Enough sides that the polygon is within the tolerance of the ellipse.
            let radius = max(width, height) / 2
            let sides = min(max(Int((Double.pi / acos(max(1 - tolerance / max(radius, 1e-9), -1))).rounded(.up)), 8), 256)
            unit = (0..<sides).map { index in
                let angle = 2 * Double.pi * Double(index) / Double(sides)
                return Point(x: cos(angle) / 2, y: sin(angle) / 2)
            }
        }
        return unit.map { rotation.apply(Point(x: $0.x * width, y: $0.y * height)) }
    }

    /// The one closed contour of a custom nib; nil (the ellipse) for anything else.
    static func singleClosedContour(_ shape: DisplayPath) -> Contour? {
        let contours = shape.contours
        guard contours.count == 1, contours[0].isClosed, !contours[0].segments.allSatisfy(\.isDegenerate) else {
            return nil
        }
        return contours[0]
    }

    /// The swept region of `nib` along `path` in local units, filled non-zero.
    static func region(_ nib: CalligraphicNib, path: DisplayPath, tolerance: Double) -> DisplayPath {
        cache.value(for: Key(nib: nib, path: path, tolerance: tolerance)) {
            computeRegion(nib, path: path, tolerance: tolerance)
        }
    }

    private static func computeRegion(_ nib: CalligraphicNib, path: DisplayPath, tolerance: Double) -> DisplayPath {
        var polygon = nibPolygon(nib, tolerance: tolerance)
        guard polygon.count >= 2 else {
            return DisplayPath()
        }
        if signedArea(polygon) < 0 {
            polygon.reverse()
        }
        var result = DisplayPath()
        func add(_ points: [Point]) {
            let area = signedArea(points)
            guard abs(area) > 1e-12 else { return }
            result.elements += DisplayPath(polygon: area > 0 ? points : points.reversed()).elements
        }
        for contour in path.contours {
            let arc = ArcLengthPath(contour: contour, tolerance: tolerance)
            let vertices = arc.points
            for vertex in vertices {
                add(polygon.map { Point(x: $0.x + vertex.x, y: $0.y + vertex.y) })
            }
            for index in vertices.indices.dropFirst() {
                let a = vertices[index - 1]
                let b = vertices[index]
                let step = b - a
                for edge in polygon.indices {
                    let e0 = polygon[edge]
                    let e1 = polygon[(edge + 1) % polygon.count]
                    add([
                        Point(x: a.x + e0.x, y: a.y + e0.y), Point(x: a.x + e1.x, y: a.y + e1.y),
                        Point(x: a.x + e1.x, y: a.y + e1.y) + step, Point(x: a.x + e0.x, y: a.y + e0.y) + step,
                    ])
                }
            }
        }
        return result
    }

    /// Twice-signed shoelace area halved; positive for the renderers' positive orientation.
    static func signedArea(_ points: [Point]) -> Double {
        guard points.count > 2 else {
            return 0
        }
        var sum = 0.0
        for index in points.indices {
            let p = points[index]
            let q = points[(index + 1) % points.count]
            sum += p.x * q.y - q.x * p.y
        }
        return sum / 2
    }
}
