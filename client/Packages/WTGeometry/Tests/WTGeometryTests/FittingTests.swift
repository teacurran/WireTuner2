import Foundation
import Testing
@testable import WTGeometry

/// A recorded-stroke fixture: samples along a known curve every ~2 pt with seeded jitter, as a
/// pointer at event rate produces (GEO-004's stroke corpus; DRAW-016 compares against it).
struct StrokeFixture: Sendable, CustomStringConvertible {
    var name: String
    var samples: [Point]
    var description: String { name }

    static func make(_ name: String, seed: UInt64, noise: Double = 0.25, count: Int, _ curve: (Double) -> Point) -> StrokeFixture {
        var rng = SeededGenerator(seed: seed)
        var samples: [Point] = []
        for i in 0..<count {
            let t = Double(i) / Double(count - 1)
            samples.append(curve(t) + Vector(rng.double(in: -noise...noise), rng.double(in: -noise...noise)))
        }
        return StrokeFixture(name: name, samples: samples)
    }

    static let corpus: [StrokeFixture] = [
        make("arc", seed: 1, count: 160) { t in Point(200 + 150 * cos(t * .pi), 200 - 150 * sin(t * .pi)) },
        make("sine", seed: 2, count: 250) { t in Point(500 * t, 100 + 40 * sin(t * 6 * .pi)) },
        make("scurve", seed: 3, count: 120) { t in
            CubicBezier(Point(0, 0), Point(150, -120), Point(100, 220), Point(260, 90)).evaluate(t)
        },
        make("spiral", seed: 4, count: 400) { t in
            let a = t * 5 * .pi
            return Point(300 + (20 + 30 * a) * cos(a), 300 + (20 + 30 * a) * sin(a))
        },
        make("zigzag", seed: 5, noise: 0.1, count: 201) { t in
            // Three straight legs with sharp corners.
            let leg = min(2.999, t * 3)
            let k = Int(leg)
            let f = leg - Double(k)
            let corners = [Point(0, 0), Point(100, 80), Point(200, 0), Point(300, 80)]
            return Point.lerp(corners[k], corners[k + 1], f)
        },
        make("scribble", seed: 6, noise: 0.4, count: 300) { t in
            Point(200 + 120 * sin(3 * t * .pi) + 30 * cos(11 * t), 150 + 90 * sin(5 * t * .pi))
        },
    ]
}

/// Largest distance from any sample to the contour.
func maxDeviation(_ samples: [Point], from contour: Contour) -> Double {
    samples.map { contour.nearestPoint(to: $0)?.distance ?? .infinity }.max() ?? 0
}

@Suite struct FittingTests {
    @Test(arguments: StrokeFixture.corpus)
    func fitStaysWithinTolerance(fixture: StrokeFixture) {
        for tolerance in [0.5, 1, 2, 4, 8] {
            let fitted = CurveFitter(maxError: tolerance).fitContour(fixture.samples)
            #expect(!fitted.isEmpty)
            #expect(fitted.startPoint == fixture.samples.first && fitted.endPoint == fixture.samples.last)
            #expect(maxDeviation(fixture.samples, from: fitted) <= tolerance * (1 + 1e-9), "\(fixture) at \(tolerance)")
            for k in 1..<fitted.segments.count {
                #expect(fitted.segments[k - 1].p3 == fitted.segments[k].p0)
            }
        }
    }

    @Test(arguments: StrokeFixture.corpus)
    func precisionControlsPointCount(fixture: StrokeFixture) {
        var counts: [Int] = []
        for value in PrecisionSetting.range {
            let precision = PrecisionSetting(value)
            let fitted = precision.fit(stroke: fixture.samples)
            let distinct = Polyline.removingDuplicates(fixture.samples)
            let corners = CurveFitter.corners(in: distinct, angle: PrecisionSetting.cornerAngle, window: PrecisionSetting.cornerWindow)
            let smoothed = PrecisionSetting.smoothedRuns(distinct, corners: corners, sigma: precision.smoothingSigma).points
            #expect(maxDeviation(smoothed, from: fitted) <= precision.tolerance() * (1 + 1e-9), "\(fixture) p\(value)")
            counts.append(fitted.segments.count)
        }
        // Looser precision never needs more segments than a tighter one by more than one, and
        // the extremes differ clearly.
        for k in 1..<counts.count {
            #expect(counts[k] + 1 >= counts[k - 1], "\(fixture): \(counts)")
        }
        #expect(counts[9] > counts[0], "\(fixture): \(counts)")
    }

    /// The golden segment counts per precision (1…10) for the corpus, which DRAW-016 holds the
    /// Pencil tool to within 10%.  A change to the fitter that moves these is a behavior change.
    @Test func goldenSegmentCounts() {
        let golden: [String: [Int]] = Self.golden
        for fixture in StrokeFixture.corpus {
            let counts = PrecisionSetting.range.map { PrecisionSetting($0).fit(stroke: fixture.samples).segments.count }
            #expect(golden[fixture.name] == counts, "\(fixture.name): \(counts)")
        }
    }

    static let golden: [String: [Int]] = [
        "arc": [1, 1, 1, 1, 1, 2, 2, 2, 4, 4],
        "sine": [5, 5, 5, 7, 7, 7, 7, 7, 7, 9],
        "scurve": [1, 1, 1, 1, 3, 3, 3, 3, 4, 4],
        "spiral": [7, 7, 8, 12, 12, 12, 12, 12, 12, 12],
        "zigzag": [3, 3, 3, 3, 3, 3, 4, 5, 5, 5],
        "scribble": [8, 8, 8, 10, 12, 12, 13, 14, 15, 15],
    ]

    @Test func precisionMapping() {
        #expect(PrecisionSetting(0).value == 1 && PrecisionSetting(42).value == 10)
        #expect(PrecisionSetting(1).tolerance() == 12)
        #expect(approx(PrecisionSetting(10).tolerance(), 1.2))
        // 1600%: sixteen times smaller in pasteboard units (DRAW-016).
        #expect(approx(PrecisionSetting(5).tolerance(zoom: 16), PrecisionSetting(5).tolerance() / 16))
        #expect(PrecisionSetting(5).tolerance(zoom: 0) == PrecisionSetting(5).tolerance())
        #expect(PrecisionSetting(10).smoothingSigma == 0 && PrecisionSetting(1).smoothingSigma == 3)
        #expect(PrecisionSetting(3) < PrecisionSetting(4))
        #expect(PrecisionSetting(7).fitter(zoom: 2).maxError == PrecisionSetting(7).tolerance(zoom: 2))
        #expect(PrecisionSetting(5).fit(stroke: [Point(1, 1), Point(1, 1)]).isEmpty)
    }

    @Test func cornersAreKept() {
        // A clean L: two straight legs meeting at a right angle.
        var points: [Point] = []
        for i in 0...50 { points.append(Point(Double(i) * 2, 0)) }
        for i in 1...50 { points.append(Point(100, Double(i) * 2)) }
        let corners = CurveFitter.corners(in: points, angle: .pi / 3)
        #expect(corners == [50])
        let fitted = CurveFitter(maxError: 0.5).fit(points)
        #expect(fitted.count == 2)
        #expect(fitted[0].p3 == Point(100, 0))
        #expect(fitted.allSatisfy { $0.isLinear(tolerance: 1e-6) })
        // Disabled corner detection still fits within tolerance, with a rounded knee.
        let rounded = CurveFitter(maxError: 0.5, cornerAngle: .pi).fitContour(points)
        #expect(maxDeviation(points, from: rounded) <= 0.5 + 1e-9)
        #expect(CurveFitter.corners(in: points, angle: .pi).isEmpty)
        #expect(CurveFitter.corners(in: [Point(0, 0), Point(1, 0)], angle: 0.1).isEmpty)
        // A run of sharp samples collapses to its sharpest.
        let hairpin = [Point(0, 0), Point(10, 0), Point(10.1, 0.5), Point(0, 1)]
        #expect(CurveFitter.corners(in: hairpin, angle: .pi / 3).count == 1)
    }

    @Test func degenerateInput() {
        let fitter = CurveFitter(maxError: 1)
        #expect(fitter.fit([]).isEmpty)
        #expect(fitter.fit([Point(3, 3)]).isEmpty)
        #expect(fitter.fit([Point(3, 3), Point(3, 3), Point(3, 3)]).isEmpty)
        let two = fitter.fit([Point(0, 0), Point(9, 0)])
        #expect(two.count == 1 && two[0].isLinear())
        #expect(fitter.fit([Point(0, 0), Point(.nan, 1), Point(4, 0)]).count == 1)
        // A cusp (the stroke reverses on itself) still fits.
        let back = [Point(0, 0), Point(5, 0), Point(10, 0), Point(5, 0.0001), Point(0, 0)]
        let fitted = CurveFitter(maxError: 0.1, cornerAngle: .pi).fitContour(back)
        #expect(maxDeviation(back, from: fitted) <= 0.1 + 1e-9)
        // The recursion cap falls back to straight pieces.
        let capped = CurveFitter(maxError: 1e-9, maxDepth: 1).fit(StrokeFixture.corpus[5].samples)
        #expect(!capped.isEmpty)
        #expect(maxDeviation(StrokeFixture.corpus[5].samples, from: Contour(segments: capped, closed: false)) <= 1e-6)
    }

    @Test func schneiderHelpers() {
        let d = [Point(0, 0), Point(0, 0), Point(0, 0)]
        #expect(CurveFitter.chordLengthParameterize(d, 0, 2) == [0, 0.5, 1])
        #expect(CurveFitter.leftTangent(d, 0, 2) == Vector(1, 0))
        #expect(CurveFitter.rightTangent(d, 0, 2) == Vector(-1, 0))
        #expect(CurveFitter.turningAngle(.zero, Vector(1, 0)) == 0)
        // A symmetric cusp: the centre tangent falls back to a perpendicular.
        let cusp = [Point(0, 0), Point(1, 0), Point(0, 0)]
        #expect(approx(CurveFitter.centerTangent(cusp, 1).length, 1))
        #expect(CurveFitter.centerTangent([Point(0, 0), Point(0, 0), Point(0, 0)], 1) == Vector(1, 0))
        // Collinear samples make the least-squares system singular: the Wu/Barsky fallback.
        let line = [Point(0, 0), Point(1, 0), Point(2, 0)]
        let bezier = CurveFitter.generateBezier(line, 0, 2, [0, 0.5, 1], Vector(1, 0), Vector(-1, 0))
        #expect(bezier.p0 == Point(0, 0) && bezier.p3 == Point(2, 0))
        let flat = CurveFitter.generateBezier(line, 0, 2, [0, 0, 0], Vector(0, 1), Vector(0, 1))
        #expect(approx(flat.p1, Point(0, 2.0 / 3)))
        let steps = CurveFitter.reparameterize([Point(0, 0), Point(1, 0), Point(2, 0)], 0, 2, [0, 0.5, 1],
            CubicBezier(Point(0, 0), Point(0, 0), Point(0, 0), Point(0, 0)))
        #expect(steps == [0, 0.5, 1])
    }
}

@Suite struct SimplifyTests {
    @Test func douglasPeuckerClassics() {
        // Collinear points vanish.
        let line = (0...10).map { Point(Double($0), 2 * Double($0)) }
        #expect(Polyline.simplify(line, tolerance: 1e-9) == [line[0], line[10]])
        // The textbook example: a bump survives, the flat run does not.
        let bump = [Point(0, 0), Point(1, 0.1), Point(2, -0.1), Point(3, 5), Point(4, 6), Point(5, 7), Point(6, 8.1), Point(7, 9), Point(8, 9), Point(9, 9)]
        let simplified = Polyline.simplify(bump, tolerance: 1)
        #expect(simplified.first == bump.first && simplified.last == bump.last)
        #expect(simplified.contains(Point(2, -0.1)) && simplified.contains(Point(7, 9)))
        #expect(!simplified.contains(Point(1, 0.1)))
        for p in bump {
            var nearest = Double.infinity
            for k in 1..<simplified.count {
                nearest = min(nearest, Line(simplified[k - 1], simplified[k]).distance(to: p))
            }
            #expect(nearest <= 1 + 1e-12)
        }
        // Zero tolerance keeps every non-collinear point.
        #expect(Polyline.simplify(bump, tolerance: 0).count == bump.count - 2)  // (4,6) and (8,9) are exactly collinear
        // Tiny inputs pass through.
        #expect(Polyline.simplify([Point(0, 0), Point(1, 1)], tolerance: 5).count == 2)
        #expect(Polyline.simplify(bump, tolerance: -1) == bump)
        // A closed ring (first == last) keeps its far point.
        let ring = [Point(0, 0), Point(5, 0), Point(5, 5), Point(0, 5), Point(0, 0)]
        #expect(Polyline.simplify(ring, tolerance: 0.1).contains(Point(5, 5)))
        // A long input does not recurse.
        let long = (0..<100_000).map { Point(Double($0), sin(Double($0) * 0.001) * 100) }
        #expect(Polyline.simplify(long, tolerance: 0.5).count < 1000)
    }

    @Test func duplicatesAndLength() {
        let pts = [Point(0, 0), Point(0, 0), Point(3, 4), Point(3, 4 + 1e-12), Point(.nan, 0), Point(3, 8)]
        #expect(Polyline.removingDuplicates(pts) == [Point(0, 0), Point(3, 4), Point(3, 8)])
        #expect(Polyline.length([Point(0, 0), Point(3, 4), Point(3, 8)]) == 9)
        #expect(Polyline.length([]) == 0 && Polyline.length([Point(1, 1)]) == 0)
    }

    @Test func gaussianSmoothing() {
        var rng = SeededGenerator(seed: 8)
        let noisy = (0..<200).map { Point(Double($0), rng.double(in: -1...1)) }
        let smooth = Polyline.smoothed(noisy, sigma: 3)
        #expect(smooth.first == noisy.first && smooth.last == noisy.last)
        func roughness(_ p: [Point]) -> Double {
            var total = 0.0
            for i in 1..<(p.count - 1) {
                let second: Double = p[i - 1].y - 2 * p[i].y + p[i + 1].y
                total += abs(second)
            }
            return total
        }
        #expect(roughness(smooth) < roughness(noisy) / 5)
        // A straight evenly-sampled line is a fixed point.
        let line = (0..<20).map { Point(Double($0), 2 * Double($0)) }
        let same = Polyline.smoothed(line, sigma: 2)
        #expect(approx(same[10], line[10], 1e-9))
        #expect(Polyline.smoothed(noisy, sigma: 0) == noisy)
        #expect(Polyline.smoothed([Point(0, 0), Point(1, 1)], sigma: 2).count == 2)
    }

    /// A traced 1,000-point path (a wobbly closed blob as polygon) drops below 100 points with
    /// the outline inside the tolerance (DRAW-030).
    @Test func simplifyTracedPath() {
        var points: [Point] = []
        for i in 0..<1000 {
            let a = Double(i) / 1000 * 2 * .pi
            let r = 100 + 12 * sin(3 * a) + 5 * cos(7 * a)
            points.append(Point(r * cos(a), r * sin(a)))
        }
        let traced = Contour(polygon: points)
        #expect(traced.segments.count == 1000)
        let tolerance = 0.5
        let simple = traced.simplified(tolerance: tolerance)
        #expect(simple.isClosed)
        #expect(simple.segments.count < 100, "\(simple.segments.count)")
        #expect(simple.startPoint == simple.endPoint)
        var worst = 0.0
        for segment in traced.segments {
            for k in 0..<4 {
                worst = max(worst, simple.nearestPoint(to: segment.evaluate(Double(k) / 4))!.distance)
            }
        }
        #expect(worst <= tolerance * 1.05, "\(worst)")
        #expect(approx(simple.signedArea(), traced.signedArea(), traced.signedArea() * 0.01))
    }

    @Test func simplifyEdgeCases() {
        let square = Contour(polygon: [Point(0, 0), Point(10, 0), Point(10, 10), Point(0, 10)])
        // Amount 0 is a no-op.
        #expect(square.simplified(tolerance: 0) == square)
        #expect(Contour(segments: [], closed: true).simplified(tolerance: 1).isEmpty)
        // Corners survive: a square stays four segments.
        let s = square.simplified(tolerance: 1)
        #expect(s.segments.count == 4)
        // An open polyline along a smooth curve merges.
        let open = Contour(polygon: (0...40).map { Point(Double($0) * 5, 30 * sin(Double($0) / 40 * .pi)) }, closed: false)
        let merged = open.simplified(tolerance: 0.5)
        #expect(!merged.isClosed && merged.segments.count < open.segments.count)
        #expect(merged.startPoint == open.startPoint && merged.endPoint == open.endPoint)
        // A smooth closed contour with no corners (a circle) keeps its segment count or less.
        let c = circle(radius: 50)
        #expect(c.simplified(tolerance: 0.01).segments.count <= 4)
        // A closed contour left open at the seam fits across its closing chord.
        let gap = Contour(polygon: [Point(0, 0), Point(10, 0), Point(10, 10), Point(0, 10)], closed: false)
        let closed = Contour(segments: gap.segments, closed: true)
        #expect(closed.simplified(tolerance: 1).segments.count == 4)
    }
}
