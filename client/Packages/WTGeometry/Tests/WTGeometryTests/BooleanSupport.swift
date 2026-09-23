import Foundation
@testable import WTGeometry

func rectPath(_ x: Double, _ y: Double, _ w: Double, _ h: Double, rule: FillRule = .nonZero) -> FilledPath {
    FilledPath(Contour(polygon: [Point(x, y), Point(x + w, y), Point(x + w, y + h), Point(x, y + h)]), fillRule: rule)
}

func circlePath(_ cx: Double, _ cy: Double, _ r: Double, rule: FillRule = .nonZero) -> FilledPath {
    FilledPath(circle(center: Point(cx, cy), radius: r), fillRule: rule)
}

func polygonPath(_ points: [Point], rule: FillRule = .nonZero) -> FilledPath {
    FilledPath(Contour(polygon: points), fillRule: rule)
}

/// Polygon area of the path flattened at `samples` points per segment (closing chords
/// included): the slow reference for `signedArea()`.
func flattenedArea(_ path: FilledPath, samples: Int = 64) -> Double {
    var total = 0.0
    for contour in path.contours where !contour.isEmpty {
        var points: [Point] = []
        for segment in contour.segments {
            for k in 0..<samples {
                points.append(segment.evaluate(Double(k) / Double(samples)))
            }
        }
        points.append(contour.segments[contour.segments.count - 1].p3)
        for k in 0..<points.count {
            let a = points[k]
            let b = points[(k + 1) % points.count]
            total += a.x * b.y - a.y * b.x
        }
    }
    return total / 2
}

/// Distance from `point` to the nearest boundary of `path` (closing chords included).
func boundaryDistance(_ point: Point, _ path: FilledPath) -> Double {
    var best = Double.infinity
    for contour in path.contours where !contour.isEmpty {
        if let nearest = contour.nearestPoint(to: point) {
            best = min(best, nearest.distance)
        }
        if let closing = contour.closingSegment {
            best = min(best, closing.nearestPoint(to: point).distance)
        }
    }
    return best
}

/// The area a path fills, whatever its winding: the area of its normalization.
func filledArea(_ path: FilledPath) -> Double {
    Boolean.normalize(path).signedArea()
}

/// One boolean corpus case.
struct BooleanCase: Sendable, CustomStringConvertible {
    var name: String
    var a: FilledPath
    var b: FilledPath
    var description: String { name }
}

enum BooleanCorpus {
    static let unit = rectPath(0, 0, 10, 10)

    /// Rectangle pairs in every relation to the 10×10 square: disjoint, edge-touching,
    /// corner-touching, overlapping, sharing part of an edge, contained, containing, identical.
    static var rectangles: [BooleanCase] {
        var cases: [BooleanCase] = []
        var seen = Set<[Double]>()
        for s in [4.0, 10, 16] {
            let offsets = [-s - 3, -s, -s / 2, 0, 3, 10 - s, 10, 13]
            for x in offsets {
                for y in offsets where seen.insert([s, x, y]).inserted {
                    cases.append(BooleanCase(name: "rect \(s) at (\(x), \(y))", a: unit, b: rectPath(x, y, s, s)))
                }
            }
        }
        return cases
    }

    static var circlesAndRects: [BooleanCase] {
        var cases: [BooleanCase] = []
        for cx in [-4.0, 0, 5, 10, 14] {
            for cy in [-4.0, 0, 5, 10, 14] {
                cases.append(BooleanCase(name: "circle r4 at (\(cx), \(cy))", a: unit, b: circlePath(cx, cy, 4)))
            }
        }
        cases.append(BooleanCase(name: "circle inside rect", a: unit, b: circlePath(5, 5, 3)))
        cases.append(BooleanCase(name: "circle around rect", a: unit, b: circlePath(5, 5, 8)))
        cases.append(BooleanCase(name: "circle inscribed in rect", a: unit, b: circlePath(5, 5, 5)))
        cases.append(BooleanCase(name: "circle tangent outside rect", a: unit, b: circlePath(13, 5, 3)))
        cases.append(BooleanCase(name: "circle tangent inside rect", a: unit, b: circlePath(7, 5, 3)))
        cases.append(BooleanCase(name: "circles overlapping", a: circlePath(0, 0, 5), b: circlePath(6, 0, 5)))
        cases.append(BooleanCase(name: "circles overlapping diagonal", a: circlePath(0, 0, 5), b: circlePath(3, 4, 4)))
        cases.append(BooleanCase(name: "circles disjoint", a: circlePath(0, 0, 5), b: circlePath(20, 0, 5)))
        return cases
    }

    static var tangencies: [BooleanCase] {
        [
            BooleanCase(name: "circles tangent outside", a: circlePath(0, 0, 5), b: circlePath(10, 0, 5)),
            BooleanCase(name: "circles tangent outside vertical", a: circlePath(0, 0, 5), b: circlePath(0, 8, 3)),
            BooleanCase(name: "circles tangent inside", a: circlePath(0, 0, 5), b: circlePath(3, 0, 2)),
            BooleanCase(name: "circles concentric", a: circlePath(0, 0, 5), b: circlePath(0, 0, 2)),
            BooleanCase(name: "rect tangent to circle top", a: circlePath(0, 0, 5), b: rectPath(-3, 5, 6, 4)),
            BooleanCase(name: "rect tangent to circle inside", a: circlePath(0, 0, 5), b: rectPath(-2, -2, 7, 4)),
            BooleanCase(name: "triangle touching rect at a vertex",
                a: unit, b: polygonPath([Point(10, 5), Point(15, 0), Point(15, 10)])),
            BooleanCase(name: "triangle vertex on rect edge inside",
                a: unit, b: polygonPath([Point(5, 0), Point(8, 5), Point(2, 5)])),
            BooleanCase(name: "diamond corners on rect edges",
                a: unit, b: polygonPath([Point(5, 0), Point(10, 5), Point(5, 10), Point(0, 5)])),
            BooleanCase(name: "diamond touching rect corners",
                a: unit, b: polygonPath([Point(10, 10), Point(15, 15), Point(10, 20), Point(5, 15)])),
        ]
    }

    static let bowtie = [Point(0, 0), Point(10, 10), Point(10, 0), Point(0, 10)]

    /// A figure-eight (self-crossing bow tie) against rectangles, under both fill rules.
    static var selfIntersecting: [BooleanCase] {
        var cases: [BooleanCase] = []
        for rule in [FillRule.nonZero, .evenOdd] {
            let eight = polygonPath(bowtie, rule: rule)
            for (x, y, w, h) in [(-2.0, 3.0, 14.0, 4.0), (3, -2, 4, 14), (4, 4, 2, 2), (0, 0, 10, 10), (8, 2, 6, 6), (20, 0, 5, 5), (0, 0, 5, 10), (-5, -5, 10, 10)] {
                cases.append(BooleanCase(name: "figure-eight \(rule) vs rect (\(x), \(y), \(w), \(h))", a: eight, b: rectPath(x, y, w, h)))
            }
            cases.append(BooleanCase(name: "figure-eight \(rule) vs circle", a: eight, b: circlePath(5, 5, 3)))
            // A star (pentagram) winds twice in its centre: filled under non-zero, hollow under even-odd.
            let star = (0..<5).map { k -> Point in
                let angle = Double(k * 2) * 2 * .pi / 5 - .pi / 2
                return Point(5 + 5 * cos(angle), 5 + 5 * sin(angle))
            }
            cases.append(BooleanCase(name: "pentagram \(rule) vs rect", a: polygonPath(star, rule: rule), b: rectPath(2, 2, 6, 3)))
            cases.append(BooleanCase(name: "self-looping cubic \(rule) vs rect",
                a: FilledPath(Contour(segments: [loopCurve.applying(.scale(10))], closed: true), fillRule: rule),
                b: rectPath(0, 5, 10, 30)))
        }
        return cases
    }

    static var identical: [BooleanCase] {
        let square = unit.contours[0]
        return [
            BooleanCase(name: "identical rects", a: unit, b: unit),
            BooleanCase(name: "identical circles", a: circlePath(0, 0, 5), b: circlePath(0, 0, 5)),
            BooleanCase(name: "identical rect, other start",
                a: unit, b: polygonPath([Point(10, 10), Point(0, 10), Point(0, 0), Point(10, 0)])),
            BooleanCase(name: "identical rect, reversed", a: unit, b: FilledPath(square.reversed())),
            BooleanCase(name: "identical figure-eights", a: polygonPath(bowtie), b: polygonPath(bowtie)),
            BooleanCase(name: "identical circle, reversed", a: circlePath(0, 0, 5), b: FilledPath(circle(radius: 5).reversed())),
        ]
    }

    static var degenerate: [BooleanCase] {
        [
            BooleanCase(name: "zero-width rect across", a: unit, b: rectPath(5, -5, 0, 20)),
            BooleanCase(name: "zero-height rect along an edge", a: unit, b: rectPath(0, 0, 10, 0)),
            BooleanCase(name: "open line across", a: unit,
                b: FilledPath(Contour(polygon: [Point(-5, 5), Point(15, 5)], closed: false))),
            BooleanCase(name: "single point", a: unit,
                b: FilledPath(Contour(segments: [CubicBezier(Point(5, 5), Point(5, 5), Point(5, 5), Point(5, 5))], closed: true))),
            BooleanCase(name: "empty operand", a: unit, b: .empty),
            BooleanCase(name: "both empty", a: .empty, b: .empty),
            BooleanCase(name: "doubled-back contour", a: unit,
                b: polygonPath([Point(-5, 5), Point(15, 5), Point(15, 6), Point(15, 5)])),
        ]
    }

    static var holesAndMultipleContours: [BooleanCase] {
        let ring = FilledPath(contours: [unit.contours[0], rectPath(3, 3, 4, 4).contours[0].reversed()])
        let evenOddRing = FilledPath(contours: [unit.contours[0], rectPath(3, 3, 4, 4).contours[0]], fillRule: .evenOdd)
        let pair = FilledPath(contours: [rectPath(0, 0, 4, 4).contours[0], rectPath(6, 0, 4, 4).contours[0]])
        return [
            BooleanCase(name: "ring vs bar", a: ring, b: rectPath(-2, 4, 14, 2)),
            BooleanCase(name: "ring vs rect in hole", a: ring, b: rectPath(4, 4, 2, 2)),
            BooleanCase(name: "ring vs rect filling hole", a: ring, b: rectPath(3, 3, 4, 4)),
            BooleanCase(name: "even-odd ring vs bar", a: evenOddRing, b: rectPath(-2, 4, 14, 2)),
            BooleanCase(name: "even-odd ring vs non-zero ring", a: evenOddRing, b: ring),
            BooleanCase(name: "two-contour path vs bar", a: pair, b: rectPath(-1, 1, 12, 2)),
            BooleanCase(name: "two-contour path vs covering rect", a: pair, b: rectPath(-1, -1, 12, 6)),
            BooleanCase(name: "overlapping contours, non-zero", a: FilledPath(contours: [unit.contours[0], rectPath(5, 5, 10, 10).contours[0]]),
                b: rectPath(8, -2, 4, 20)),
            BooleanCase(name: "overlapping contours, even-odd",
                a: FilledPath(contours: [unit.contours[0], rectPath(5, 5, 10, 10).contours[0]], fillRule: .evenOdd),
                b: rectPath(8, -2, 4, 20)),
        ]
    }

    static var rotated: [BooleanCase] {
        var cases: [BooleanCase] = []
        for degrees in [15.0, 30, 45, 60] {
            let turn = AffineTransform.rotation(radians: degrees * .pi / 180, around: Point(5, 5))
            cases.append(BooleanCase(name: "rect rotated \(degrees)°", a: unit, b: unit.applying(turn)))
            cases.append(BooleanCase(name: "offset rect rotated \(degrees)°", a: unit, b: rectPath(6, 6, 8, 8).applying(turn)))
        }
        return cases
    }

    static let all: [BooleanCase] = rectangles + circlesAndRects + tangencies + selfIntersecting + identical + degenerate
        + holesAndMultipleContours + rotated
}
