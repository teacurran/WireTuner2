import Testing
@testable import WTGeometry

/// Random curves never crash or hang, and the invariants that tie the operations together hold
/// (testing.adoc, "Geometry and rendering").
@Suite struct FuzzTests {
    @Test func randomCubicsSatisfyInvariants() {
        var rng = SeededGenerator(seed: 42)
        for _ in 0..<300 {
            let curve = rng.cubic(in: -100...100)
            let tight = curve.bounds
            let hull = curve.controlBounds
            #expect(hull.expanded(by: 1e-9).contains(tight))
            let length = curve.length()
            #expect(length >= curve.chordLength - 1e-6)
            #expect(length <= curve.controlPolygonLength + 1e-6)
            for i in 0...20 {
                let t = Double(i) / 20
                let p = curve.evaluate(t)
                #expect(tight.expanded(by: 1e-7).contains(p))
                #expect(approx(p, curve.evaluateDeCasteljau(t), 1e-8))
                #expect(curve.tangent(t).length <= 1 + 1e-12)
                #expect(curve.curvature(t).isFinite)
            }
            let split = curve.split(at: rng.double(in: 0...1))
            #expect(approx(split.0.length() + split.1.length(), length, 1e-4))
            let s = rng.double(in: 0...1) * length
            let t = curve.parameter(atLength: s)
            #expect(approx(curve.length(from: 0, to: t), s, 1e-5))
        }
    }

    @Test func randomIntersectionsAreConsistent() {
        var rng = SeededGenerator(seed: 99)
        for _ in 0..<150 {
            let curve = rng.cubic(in: -100...100)
            let line = Line(rng.point(in: -120...120), rng.point(in: -120...120))
            let hits = curve.intersections(with: line)
            #expect(hits.count <= 3)
            for hit in hits {
                #expect(approx(line.signedDistance(to: hit.point), 0, 1e-6))
                #expect(approx(line.evaluate(hit.u), hit.point, 1e-5))
            }
            // Every transversal crossing the sampler sees well inside the segment is found.
            #expect(hits.count >= sampledCrossings(of: curve, with: line, samples: 5000, margin: 1e-3))
            let other = rng.cubic(in: -100...100)
            let pairs = curve.intersections(with: other)
            #expect(pairs.count <= 64)
            for pair in pairs {
                #expect(approx(curve.evaluate(pair.t), other.evaluate(pair.u), 1e-5))
            }
        }
    }

    @Test func randomContoursNeverCrash() {
        var rng = SeededGenerator(seed: 2024)
        for _ in 0..<60 {
            var segments: [CubicBezier] = []
            var cursor = rng.point(in: -50...50)
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                let next = rng.point(in: -50...50)
                segments.append(CubicBezier(cursor, rng.point(in: -80...80), rng.point(in: -80...80), next))
                cursor = next
            }
            let contour = Contour(segments: segments, closed: Bool.random(using: &rng))
            for _ in 0..<20 {
                let p = rng.point(in: -60...60)
                let winding = contour.windingNumber(at: p)
                let crossings = contour.crossingCount(at: p)
                #expect(abs(winding) <= crossings)
                #expect((winding - crossings) % 2 == 0)
                let bounds = contour.bounds
                if !bounds.contains(p) {
                    #expect(winding == 0)
                }
                // Above, below or to the right of everything the ray meets nothing at all.
                if p.y < bounds.minY || p.y > bounds.maxY || p.x > bounds.maxX {
                    #expect(crossings == 0)
                }
            }
            #expect(contour.length() >= 0)
            #expect(contour.nearestPoint(to: .zero) != nil)
        }
    }

    @Test func degenerateInputsAreHarmless() {
        let dot = CubicBezier(Point(0, 0), Point(0, 0), Point(0, 0), Point(0, 0))
        #expect(dot.bounds == Rect.zero)
        #expect(dot.length() == 0)
        #expect(dot.intersections(with: Line(Point(-1, 0), Point(1, 0))).count <= 1)
        #expect(dot.intersections(with: sCurve).count <= 1)
        #expect(dot.windingContribution(at: Point(-1, 0)) == 0)
        #expect(Contour(segments: [dot], closed: true).windingNumber(at: .zero) == 0)
        let huge = CubicBezier(Point(-1e9, -1e9), Point(1e9, 1e9), Point(-1e9, 1e9), Point(1e9, -1e9))
        #expect(huge.length().isFinite)
        #expect(huge.bounds.diagonal.isFinite)
        #expect(huge.nearestPoint(to: .zero).distance.isFinite)
    }
}
