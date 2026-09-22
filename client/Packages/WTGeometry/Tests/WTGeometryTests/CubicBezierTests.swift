import Testing
@testable import WTGeometry

@Suite struct CubicBezierTests {
    let curve = CubicBezier(Point(0, 0), Point(1, 2), Point(3, 3), Point(4, 0))

    @Test func initializers() {
        #expect(CubicBezier(p0: Point(0, 0), p1: Point(1, 2), p2: Point(3, 3), p3: Point(4, 0)) == curve)
        let fromHandles = CubicBezier(from: Point(0, 0), outHandle: Vector(1, 2), inHandle: Vector(-1, 3), to: Point(4, 0))
        #expect(fromHandles == curve)
        let retracted = CubicBezier(from: Point(0, 0), outHandle: .zero, inHandle: .zero, to: Point(3, 0))
        #expect(retracted.isLinear())
        #expect(approx(retracted.evaluate(0.5), Point(1.5, 0)))
        #expect(curve.startPoint == Point(0, 0) && curve.endPoint == Point(4, 0))
        #expect(curve.chordLength == 4)
        #expect(approx(curve.controlPolygonLength, 5.0.squareRoot() + 5.0.squareRoot() + 10.0.squareRoot()))
        #expect(!curve.isDegenerate)
        #expect(CubicBezier(Point(1, 1), Point(1, 1), Point(1, 1), Point(1, 1)).isDegenerate)
    }

    @Test(arguments: [0.0, 0.1, 0.25, 0.5, 0.7, 0.99, 1.0])
    func bernsteinMatchesDeCasteljau(t: Double) {
        #expect(approx(curve.evaluate(t), curve.evaluateDeCasteljau(t), 1e-12))
        let wild = CubicBezier(Point(-100, 50), Point(300, -700), Point(-250, 900), Point(80, 10))
        #expect(approx(wild.evaluate(t), wild.evaluateDeCasteljau(t), 1e-9))
    }

    @Test func endpointsAndDerivativesAtEnds() {
        #expect(curve.evaluate(0) == curve.p0)
        #expect(curve.evaluate(1) == curve.p3)
        #expect(curve.derivative(0) == 3 * (curve.p1 - curve.p0))
        #expect(curve.derivative(1) == 3 * (curve.p3 - curve.p2))
        #expect(curve.secondDerivative(0) == 6 * ((curve.p2 - curve.p1) - (curve.p1 - curve.p0)))
        #expect(curve.secondDerivative(1) == 6 * ((curve.p3 - curve.p2) - (curve.p2 - curve.p1)))
    }

    @Test func derivativeMatchesFiniteDifference() {
        let h = 1e-6
        for i in 1..<10 {
            let t = Double(i) / 10
            let numeric = (curve.evaluate(t + h) - curve.evaluate(t - h)) / (2 * h)
            #expect(curve.derivative(t).isApproximatelyEqual(to: numeric, tolerance: 1e-6))
            let numeric2 = (curve.derivative(t + h) - curve.derivative(t - h)) / (2 * h)
            #expect(curve.secondDerivative(t).isApproximatelyEqual(to: numeric2, tolerance: 1e-5))
        }
    }

    @Test func splitThenReevaluate() {
        for split in [0.2, 0.5, 0.8] {
            let (left, right) = curve.split(at: split)
            #expect(left.p0 == curve.p0)
            #expect(right.p3 == curve.p3)
            #expect(left.p3 == right.p0)
            for i in 0...10 {
                let s = Double(i) / 10
                #expect(approx(left.evaluate(s), curve.evaluate(s * split), 1e-12))
                #expect(approx(right.evaluate(s), curve.evaluate(split + s * (1 - split)), 1e-12))
            }
        }
    }

    @Test func subdivideCoversTheRange() {
        let piece = curve.subdivide(from: 0.25, to: 0.75)
        for i in 0...10 {
            let s = Double(i) / 10
            #expect(approx(piece.evaluate(s), curve.evaluate(0.25 + 0.5 * s), 1e-12))
        }
        let backwards = curve.subdivide(from: 0.75, to: 0.25)
        #expect(approx(backwards.p0, curve.evaluate(0.75), 1e-12))
        #expect(approx(backwards.p3, curve.evaluate(0.25), 1e-12))
        #expect(curve.subdivide(from: -1, to: 2) == curve)
        #expect(curve.subdivide(from: 0, to: 1) == curve)
        let head = curve.subdivide(from: 0, to: 0.5)
        #expect(head == curve.split(at: 0.5).0)
        let tail = curve.subdivide(from: 0.5, to: 1)
        #expect(tail == curve.split(at: 0.5).1)
        let end = curve.subdivide(from: 1, to: 1)
        #expect(end.isDegenerate && end.p0 == curve.p3)
    }

    @Test func boundsAreTightAndContainTheCurve() {
        let hull = curve.controlBounds
        #expect(hull == Rect(minX: 0, minY: 0, maxX: 4, maxY: 3))
        let tight = curve.bounds
        #expect(hull.contains(tight))
        #expect(tight.maxY < 3)
        var sampled = Rect.null
        for i in 0...1000 {
            sampled.formUnion(curve.evaluate(Double(i) / 1000))
        }
        #expect(tight.expanded(by: 1e-9).contains(sampled))
        #expect(approx(tight.maxY, sampled.maxY, 1e-5))
        // A curve that overshoots in x on both sides: both x roots lie inside (0, 1).
        let overshoot = CubicBezier(Point(0, 0), Point(-3, 1), Point(6, 2), Point(3, 3))
        let ob = overshoot.bounds
        #expect(ob.minX < 0 && ob.maxX > 3)
        var sampledX = Rect.null
        for i in 0...100_000 {
            sampledX.formUnion(overshoot.evaluate(Double(i) / 100_000))
        }
        #expect(approx(ob.minX, sampledX.minX, 1e-8))
        #expect(approx(ob.maxX, sampledX.maxX, 1e-8))
        // A straight cubic has bounds equal to its chord box.
        let straight = Line(Point(1, 1), Point(5, 3)).elevated()
        #expect(straight.bounds == Rect(Point(1, 1), Point(5, 3)))
    }

    @Test func isLinearAndDegenerateChord() {
        #expect(Line(Point(0, 0), Point(3, 3)).elevated().isLinear())
        #expect(!curve.isLinear())
        #expect(curve.isLinear(tolerance: 10))
        let point = CubicBezier(Point(1, 1), Point(1, 1), Point(1, 1), Point(1, 1))
        #expect(point.isLinear())
        let closedLoop = CubicBezier(Point(0, 0), Point(1, 1), Point(-1, 1), Point(0, 0))
        #expect(!closedLoop.isLinear())
    }

    @Test func tangentNormalCurvature() {
        #expect(curve.tangent(0).isApproximatelyEqual(to: Vector(1, 2).normalized))
        #expect(curve.normal(0).isApproximatelyEqual(to: Vector(1, 2).normalized.perpendicular))
        // A straight segment has zero curvature everywhere.
        let straight = Line(Point(0, 0), Point(5, 5)).elevated()
        for i in 0...4 {
            #expect(approx(straight.curvature(Double(i) / 4), 0, 1e-12))
        }
        // The quarter circle approximation has curvature close to 1/r, positive in the
        // direction of travel here (turning toward the normal).
        let arc = quarterCircle(radius: 2)
        for i in 0...4 {
            #expect(approx(arc.curvature(Double(i) / 4), 0.5, 0.02))
        }
        #expect(arc.reversed().curvature(0.5) < 0)
    }

    @Test func tangentFallsBackWhenTheDerivativeVanishes() {
        // Coincident first control point: derivative at 0 is zero; the second derivative points
        // toward p2.
        let cuspStart = CubicBezier(Point(0, 0), Point(0, 0), Point(1, 1), Point(2, 0))
        #expect(cuspStart.tangent(0).isApproximatelyEqual(to: Vector(1, 1).normalized))
        #expect(cuspStart.curvature(0) == 0)
        let cuspEnd = CubicBezier(Point(0, 0), Point(1, 1), Point(2, 0), Point(2, 0))
        #expect(cuspEnd.tangent(1).isApproximatelyEqual(to: Vector(1, -1).normalized))
        // Both handles retracted onto the ends... and both ends coincide: fully degenerate.
        let dot = CubicBezier(Point(1, 1), Point(1, 1), Point(1, 1), Point(1, 1))
        #expect(dot.tangent(0.5) == .zero)
        // Degenerate derivative and second derivative but a chord: p0 == p1 == p2 != p3 at t = 0
        // has zero first derivative and zero second derivative.
        let stub = CubicBezier(Point(0, 0), Point(0, 0), Point(0, 0), Point(3, 0))
        #expect(stub.tangent(0) == Vector(1, 0))
    }

    @Test func reversedAndTransformed() {
        let r = curve.reversed()
        #expect(r.p0 == curve.p3 && r.p3 == curve.p0)
        for i in 0...10 {
            let t = Double(i) / 10
            #expect(approx(r.evaluate(t), curve.evaluate(1 - t), 1e-12))
        }
        let moved = curve.applying(.translation(x: 1, y: 1))
        #expect(moved.p0 == Point(1, 1) && moved.p3 == Point(5, 1))
        let rotated = curve.applying(.rotation(radians: .pi / 2))
        #expect(approx(rotated.evaluate(0.3), AffineTransform.rotation(radians: .pi / 2).apply(curve.evaluate(0.3))))
    }
}
