import Testing
@testable import WTGeometry

@Suite struct PointTests {
    @Test func initializersAndZero() {
        #expect(Point(x: 1, y: 2) == Point(1, 2))
        #expect(Point.zero.x == 0 && Point.zero.y == 0)
        #expect(Point(1, 2).isFinite)
        #expect(!Point(.nan, 2).isFinite)
        #expect(!Point(1, .infinity).isFinite)
    }

    @Test func arithmeticBetweenPointsAndVectors() {
        let p = Point(1, 2)
        let v = Vector(3, -1)
        #expect(p + v == Point(4, 1))
        #expect(p - v == Point(-2, 3))
        #expect(Point(4, 1) - p == v)
        var q = p
        q += v
        #expect(q == Point(4, 1))
        q -= v
        #expect(q == p)
    }

    @Test func distances() {
        let a = Point(0, 0)
        let b = Point(3, 4)
        #expect(a.distance(to: b) == 5)
        #expect(a.distanceSquared(to: b) == 25)
        #expect(a.isApproximatelyEqual(to: Point(1e-10, 0)))
        #expect(!a.isApproximatelyEqual(to: Point(1e-3, 0)))
        #expect(a.isApproximatelyEqual(to: Point(1e-3, 0), tolerance: 1e-2))
    }

    @Test func lerpIsLinearAndUnclamped() {
        let a = Point(0, 0)
        let b = Point(10, -20)
        #expect(Point.lerp(a, b, 0) == a)
        #expect(Point.lerp(a, b, 1) == b)
        #expect(Point.lerp(a, b, 0.25) == Point(2.5, -5))
        #expect(Point.lerp(a, b, 2) == Point(20, -40))
    }

    @Test func hashable() {
        let set: Set<Point> = [Point(1, 1), Point(1, 1), Point(2, 2)]
        #expect(set.count == 2)
    }
}

@Suite struct VectorTests {
    @Test func initializersAndZero() {
        #expect(Vector(dx: 1, dy: 2) == Vector(1, 2))
        #expect(Vector.zero.lengthSquared == 0)
        #expect(Vector(1, 2).isFinite)
        #expect(!Vector(.infinity, 0).isFinite)
    }

    @Test func lengthAndNormalization() {
        let v = Vector(3, 4)
        #expect(v.length == 5)
        #expect(v.lengthSquared == 25)
        #expect(approx(v.normalized.length, 1))
        #expect(v.normalized == Vector(0.6, 0.8))
        #expect(Vector.zero.normalized == .zero)
    }

    @Test func perpendicularDotCross() {
        let v = Vector(1, 0)
        #expect(v.perpendicular == Vector(0, 1))
        #expect(v.dot(v.perpendicular) == 0)
        #expect(v.cross(v.perpendicular) == 1)
        #expect(v.perpendicular.cross(v) == -1)
        #expect(Vector(2, 3).dot(Vector(4, 5)) == 23)
    }

    @Test func arithmetic() {
        let a = Vector(1, 2)
        let b = Vector(3, 4)
        #expect(a + b == Vector(4, 6))
        #expect(a - b == Vector(-2, -2))
        #expect(-a == Vector(-1, -2))
        #expect(a * 2 == Vector(2, 4))
        #expect(2 * a == Vector(2, 4))
        #expect(b / 2 == Vector(1.5, 2))
        var c = a
        c += b
        #expect(c == Vector(4, 6))
        c -= b
        #expect(c == a)
        c *= 3
        #expect(c == Vector(3, 6))
    }

    @Test func approximateEquality() {
        #expect(Vector(1, 1).isApproximatelyEqual(to: Vector(1 + 1e-12, 1)))
        #expect(!Vector(1, 1).isApproximatelyEqual(to: Vector(1.1, 1)))
        #expect(Vector(1, 1).isApproximatelyEqual(to: Vector(1.1, 1), tolerance: 0.2))
    }
}
