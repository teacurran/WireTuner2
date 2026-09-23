import Foundation
@testable import WTGeometry

/// The segments of `contour` including the closing segment of a closed contour.
func allSegments(_ contour: Contour) -> [CubicBezier] {
    var segments = contour.segments
    if contour.isClosed, let closing = contour.closingSegment {
        segments.append(closing)
    }
    return segments
}

/// Distance from `point` to the nearest point of any of `contours` (closing segments of closed
/// contours included).
func distance(from point: Point, to contours: [Contour]) -> Double {
    var best = Double.infinity
    for contour in contours {
        for segment in allSegments(contour) {
            best = min(best, segment.nearestPoint(to: point, samples: 64).distance)
        }
    }
    return best
}

/// Points sampled along every segment of `path`, `perSegment` per segment.
func boundarySamples(_ path: FilledPath, perSegment: Int = 12) -> [Point] {
    var points: [Point] = []
    for contour in path.contours {
        for segment in allSegments(contour) {
            for k in 0..<perSegment {
                points.append(segment.evaluate(Double(k) / Double(perSegment)))
            }
        }
    }
    return points
}

/// An open contour through `count` random cubic segments, each starting where the last ended.
func randomContour(_ rng: inout SeededGenerator, segments count: Int, range: ClosedRange<Double>, closed: Bool = false) -> Contour {
    var segments: [CubicBezier] = []
    var current = rng.point(in: range)
    for _ in 0..<count {
        let next = CubicBezier(current, rng.point(in: range), rng.point(in: range), rng.point(in: range))
        segments.append(next)
        current = next.p3
    }
    return Contour(segments: segments, closed: closed)
}

/// A square as a closed polygon contour, running in the positive rotation direction.
func squareContour(_ x: Double, _ y: Double, _ side: Double) -> Contour {
    Contour(polygon: [Point(x, y), Point(x + side, y), Point(x + side, y + side), Point(x, y + side)])
}

/// The number of line-like and curved segments is irrelevant to most checks; this is the area.
func area(_ path: FilledPath) -> Double {
    path.signedArea()
}

func relativeError(_ value: Double, _ expected: Double) -> Double {
    abs(value - expected) / max(abs(expected), 1e-300)
}
