import Testing
@testable import WTGeometry

/// The hot paths (`evaluate`, `derivative`, `bounds`) are fixed-size value computations with no
/// heap traffic; a tight loop over them must finish comfortably inside a generous wall-clock
/// bound even in a debug build.  GEO-001: "no allocation in hot paths".
@Suite struct PerformanceTests {
    let curve = CubicBezier(Point(0, 0), Point(10, 40), Point(70, -20), Point(100, 30))

    @Test func evaluateAndDerivativeInATightLoop() {
        let iterations = 500_000
        var accumulator = 0.0
        let elapsed = ContinuousClock().measure {
            for i in 0..<iterations {
                let t = Double(i & 1023) / 1023
                let p = curve.evaluate(t)
                let d = curve.derivative(t)
                accumulator += p.x + p.y + d.dx + d.dy
            }
        }
        #expect(accumulator.isFinite)
        #expect(elapsed < .seconds(5), "\(iterations) evaluations took \(elapsed)")
    }

    @Test func boundsInATightLoop() {
        let iterations = 200_000
        var accumulator = 0.0
        var c = curve
        let elapsed = ContinuousClock().measure {
            for i in 0..<iterations {
                c.p1.y = Double(i & 255)
                let b = c.bounds
                accumulator += b.minX + b.maxY
            }
        }
        #expect(accumulator.isFinite)
        #expect(elapsed < .seconds(5), "\(iterations) bounds took \(elapsed)")
    }

    @Test func windingInATightLoop() {
        let contour = circle(radius: 50)
        let iterations = 20_000
        var inside = 0
        let elapsed = ContinuousClock().measure {
            for i in 0..<iterations {
                let p = Point(Double(i % 200) - 100, Double(i % 137) - 68)
                if contour.contains(p) {
                    inside += 1
                }
            }
        }
        #expect(inside > 0)
        #expect(elapsed < .seconds(5), "\(iterations) winding queries took \(elapsed)")
    }
}
