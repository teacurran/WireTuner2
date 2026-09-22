import Testing
@testable import WTGeometry

@Suite struct QuadraticBezierTests {
    let quad = QuadraticBezier(Point(0, 0), Point(2, 4), Point(4, 0))

    @Test func initializers() {
        #expect(QuadraticBezier(p0: Point(0, 0), p1: Point(2, 4), p2: Point(4, 0)) == quad)
    }

    @Test func evaluationAndDerivative() {
        #expect(quad.evaluate(0) == quad.p0)
        #expect(quad.evaluate(1) == quad.p2)
        #expect(quad.evaluate(0.5) == Point(2, 2))
        #expect(quad.derivative(0) == 2 * (quad.p1 - quad.p0))
        #expect(quad.derivative(1) == 2 * (quad.p2 - quad.p1))
        #expect(quad.derivative(0.5) == Vector(4, 0))
    }

    @Test func elevationMatchesEverywhere() {
        let cubic = quad.elevated()
        #expect(cubic == CubicBezier(quadratic: quad))
        for i in 0...20 {
            let t = Double(i) / 20
            #expect(approx(cubic.evaluate(t), quad.evaluate(t), 1e-12))
            #expect(cubic.derivative(t).isApproximatelyEqual(to: quad.derivative(t), tolerance: 1e-12))
        }
    }

    @Test func bounds() {
        #expect(quad.controlBounds == Rect(minX: 0, minY: 0, maxX: 4, maxY: 4))
        let tight = quad.bounds
        #expect(approx(tight.maxY, 2))
        #expect(tight.minX == 0 && tight.maxX == 4 && tight.minY == 0)
    }

    @Test func reversedAndTransformed() {
        #expect(quad.reversed() == QuadraticBezier(Point(4, 0), Point(2, 4), Point(0, 0)))
        #expect(quad.applying(.scale(2)) == QuadraticBezier(Point(0, 0), Point(4, 8), Point(8, 0)))
    }
}
