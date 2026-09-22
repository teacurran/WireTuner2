import Testing
@testable import WTGeometry

@Suite struct RectTests {
    let r = Rect(minX: 0, minY: 0, maxX: 10, maxY: 5)

    @Test func initializersNormalize() {
        #expect(Rect(x: 10, y: 5, width: -10, height: -5) == r)
        #expect(Rect(x: 0, y: 0, width: 10, height: 5) == r)
        #expect(Rect(Point(10, 0), Point(0, 5)) == r)
        #expect(Rect(boundingPoints: [Point(0, 5), Point(10, 0), Point(3, 3)]) == r)
        #expect(Rect(boundingPoints: [Point]()).isNull)
        #expect(Rect.zero == Rect(minX: 0, minY: 0, maxX: 0, maxY: 0))
    }

    @Test func nullAndEmpty() {
        #expect(Rect.null.isNull)
        #expect(Rect.null.isEmpty)
        #expect(Rect.null.width == 0 && Rect.null.height == 0)
        #expect(Rect.null.diagonal == 0)
        #expect(!r.isNull)
        #expect(!r.isEmpty)
        #expect(Rect.zero.isEmpty && !Rect.zero.isNull)
        #expect(Rect(minX: 0, minY: 0, maxX: 5, maxY: 0).isEmpty)
        #expect(Rect(minX: 0, minY: 0, maxX: 0, maxY: 5).isEmpty)
    }

    @Test func derivedGeometry() {
        #expect(r.width == 10)
        #expect(r.height == 5)
        #expect(r.midX == 5)
        #expect(r.midY == 2.5)
        #expect(r.origin == Point(0, 0))
        #expect(r.center == Point(5, 2.5))
        #expect(r.minPoint == Point(0, 0))
        #expect(r.maxPoint == Point(10, 5))
        #expect(approx(r.diagonal, (125.0).squareRoot()))
    }

    @Test func containment() {
        #expect(r.contains(Point(0, 0)))
        #expect(r.contains(Point(10, 5)))
        #expect(r.contains(Point(5, 2)))
        #expect(!r.contains(Point(-1, 2)))
        #expect(!r.contains(Point(5, 6)))
        #expect(!Rect.null.contains(Point(0, 0)))
        #expect(r.contains(Rect(minX: 1, minY: 1, maxX: 2, maxY: 2)))
        #expect(r.contains(r))
        #expect(!r.contains(Rect(minX: 1, minY: 1, maxX: 12, maxY: 2)))
        #expect(r.contains(Rect.null))
        #expect(Rect.null.contains(Rect.null))
        #expect(!Rect.null.contains(r))
    }

    @Test func intersectsWithTolerance() {
        let touching = Rect(minX: 10, minY: 0, maxX: 20, maxY: 5)
        let apart = Rect(minX: 10.5, minY: 0, maxX: 20, maxY: 5)
        let aboveApart = Rect(minX: 0, minY: 5.5, maxX: 10, maxY: 8)
        #expect(r.intersects(touching))
        #expect(!r.intersects(apart))
        #expect(!r.intersects(aboveApart))
        #expect(r.intersects(apart, tolerance: 0.25))
        #expect(r.intersects(aboveApart, tolerance: 0.25))
        #expect(!r.intersects(Rect.null))
        #expect(!Rect.null.intersects(Rect.null, tolerance: 100))
    }

    @Test func unionAndIntersection() {
        let other = Rect(minX: 5, minY: -2, maxX: 12, maxY: 3)
        #expect(r.union(other) == Rect(minX: 0, minY: -2, maxX: 12, maxY: 5))
        #expect(r.union(Rect.null) == r)
        #expect(Rect.null.union(r) == r)
        #expect(r.union(Point(20, 20)) == Rect(minX: 0, minY: 0, maxX: 20, maxY: 20))
        var m = Rect.null
        m.formUnion(Point(1, 1))
        m.formUnion(Rect(minX: -1, minY: -1, maxX: 0, maxY: 0))
        #expect(m == Rect(minX: -1, minY: -1, maxX: 1, maxY: 1))
        #expect(r.intersection(other) == Rect(minX: 5, minY: 0, maxX: 10, maxY: 3))
        #expect(r.intersection(Rect(minX: 20, minY: 20, maxX: 30, maxY: 30)).isNull)
        #expect(r.intersection(Rect.null).isNull)
    }

    @Test func insetExpandOffset() {
        #expect(r.insetBy(dx: 1, dy: 2) == Rect(minX: 1, minY: 2, maxX: 9, maxY: 3))
        #expect(r.expanded(by: 1) == Rect(minX: -1, minY: -1, maxX: 11, maxY: 6))
        #expect(Rect.null.insetBy(dx: 1, dy: 1).isNull)
        #expect(Rect.null.expanded(by: 5).isNull)
        #expect(r.offset(by: Vector(1, 1)) == Rect(minX: 1, minY: 1, maxX: 11, maxY: 6))
        #expect(Rect.null.offset(by: Vector(1, 1)).isNull)
    }

    @Test func applyingTransformBoundsCorners() {
        let rotated = r.applying(.rotation(radians: .pi / 2))
        #expect(approx(rotated.minX, -5))
        #expect(approx(rotated.maxX, 0))
        #expect(approx(rotated.minY, 0))
        #expect(approx(rotated.maxY, 10))
        #expect(r.applying(.translation(x: 1, y: 1)) == Rect(minX: 1, minY: 1, maxX: 11, maxY: 6))
        #expect(Rect.null.applying(.scale(2)).isNull)
    }
}
