import Testing
@testable import WTGeometry

@Suite struct LineTests {
    let line = Line(Point(0, 0), Point(4, 0))

    @Test func basics() {
        #expect(Line(start: Point(0, 0), end: Point(4, 0)) == line)
        #expect(line.direction == Vector(4, 0))
        #expect(line.length == 4)
        #expect(line.midpoint == Point(2, 0))
        #expect(line.bounds == Rect(minX: 0, minY: 0, maxX: 4, maxY: 0))
        #expect(line.evaluate(0.25) == Point(1, 0))
        #expect(line.reversed() == Line(Point(4, 0), Point(0, 0)))
        #expect(line.applying(.translation(x: 0, y: 1)) == Line(Point(0, 1), Point(4, 1)))
    }

    @Test func signedDistanceIsPositiveOnThePerpendicularSide() {
        #expect(line.signedDistance(to: Point(2, 3)) == 3)
        #expect(line.signedDistance(to: Point(2, -3)) == -3)
        #expect(line.signedDistance(to: Point(10, 0)) == 0)
        #expect(Line(Point(1, 1), Point(1, 1)).signedDistance(to: Point(5, 5)) == 0)
    }

    @Test func nearestPointClampsToSegment() {
        let inside = line.nearestPoint(to: Point(1, 2))
        #expect(inside.t == 0.25 && inside.point == Point(1, 0) && inside.distance == 2)
        let before = line.nearestPoint(to: Point(-3, 4))
        #expect(before.t == 0 && before.distance == 5)
        let after = line.nearestPoint(to: Point(7, 4))
        #expect(after.t == 1 && after.distance == 5)
        #expect(line.distance(to: Point(2, -1)) == 1)
        let degenerate = Line(Point(1, 1), Point(1, 1)).nearestPoint(to: Point(4, 5))
        #expect(degenerate.t == 0 && degenerate.distance == 5)
    }

    @Test func elevationKeepsParametrization() {
        let cubic = line.elevated()
        #expect(cubic == CubicBezier(line: line))
        for i in 0...10 {
            let t = Double(i) / 10
            #expect(approx(cubic.evaluate(t), line.evaluate(t)))
        }
        #expect(cubic.isLinear())
    }

    @Test func crossingSegments() {
        let cross = Line(Point(2, -1), Point(2, 1))
        let hit = line.intersection(with: cross)
        #expect(hit != nil)
        #expect(hit!.t == 0.5 && hit!.u == 0.5 && hit!.point == Point(2, 0))
        #expect(line.intersection(with: Line(Point(5, -1), Point(5, 1))) == nil)
        #expect(line.intersection(with: Line(Point(2, 1), Point(2, 3))) == nil)
    }

    @Test func parallelAndCollinearReportNothing() {
        #expect(line.intersection(with: Line(Point(0, 1), Point(4, 1))) == nil)
        #expect(line.intersection(with: Line(Point(1, 0), Point(3, 0))) == nil)
        #expect(line.intersection(with: Line(Point(2, 0), Point(2, 0))) == nil)
    }

    @Test func toleranceAdmitsEndpointTouches() {
        let touch = Line(Point(4 + 1e-12, -1), Point(4 + 1e-12, 1))
        let hit = line.intersection(with: touch, tolerance: 1e-9)
        #expect(hit != nil)
        #expect(hit!.t == 1)
        #expect(line.intersection(with: touch, tolerance: 0) == nil)
    }

    @Test func nearestPointValue() {
        let n = NearestPoint(t: 0.5, point: Point(1, 1), distance: 2)
        #expect(n.t == 0.5 && n.point == Point(1, 1) && n.distance == 2)
    }
}
