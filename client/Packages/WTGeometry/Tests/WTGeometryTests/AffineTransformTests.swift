import Testing
@testable import WTGeometry

@Suite struct AffineTransformTests {
    @Test func identity() {
        let i = AffineTransform.identity
        #expect(i.isIdentity)
        #expect(i.apply(Point(3, 4)) == Point(3, 4))
        #expect(i.apply(Vector(3, 4)) == Vector(3, 4))
        #expect(i.determinant == 1)
        #expect(!AffineTransform.scale(2).isIdentity)
    }

    @Test func translationMovesPointsNotVectors() {
        let t = AffineTransform.translation(Vector(5, -2))
        #expect(t == AffineTransform.translation(x: 5, y: -2))
        #expect(t.apply(Point(1, 1)) == Point(6, -1))
        #expect(t.apply(Vector(1, 1)) == Vector(1, 1))
        #expect(t.translation == Vector(5, -2))
    }

    @Test func scale() {
        #expect(AffineTransform.scale(2).apply(Point(1, 2)) == Point(2, 4))
        #expect(AffineTransform.scale(x: 2, y: 3).apply(Vector(1, 1)) == Vector(2, 3))
        #expect(AffineTransform.scale(x: 2, y: 3).determinant == 6)
    }

    @Test func rotation() {
        let quarter = AffineTransform.rotation(radians: .pi / 2)
        #expect(approx(quarter.apply(Point(1, 0)), Point(0, 1)))
        #expect(approx(quarter.apply(Vector(0, 1)), Vector(-1, 0)))
        let around = AffineTransform.rotation(radians: .pi, around: Point(1, 1))
        #expect(approx(around.apply(Point(2, 1)), Point(0, 1)))
        #expect(approx(around.apply(Point(1, 1)), Point(1, 1)))
    }

    @Test func concatenationOrder() {
        let scaleThenMove = AffineTransform.scale(2).concatenating(.translation(x: 1, y: 0))
        #expect(scaleThenMove.apply(Point(1, 1)) == Point(3, 2))
        let moveThenScale = AffineTransform.translation(x: 1, y: 0) * .scale(2)
        #expect(moveThenScale.apply(Point(1, 1)) == Point(4, 2))
        let rotateAboutOrigin = AffineTransform.rotation(radians: .pi / 2)
        let chained = rotateAboutOrigin * .translation(x: 10, y: 0)
        #expect(approx(chained.apply(Point(1, 0)), Point(10, 1)))
    }

    @Test func inverse() {
        let t = AffineTransform.translation(x: 3, y: 4) * .rotation(radians: 0.7) * .scale(x: 2, y: 5)
        let inverse = t.inverted()
        #expect(inverse != nil)
        let p = Point(7, -3)
        #expect(approx(inverse!.apply(t.apply(p)), p))
        #expect(approx((t * inverse!).apply(p), p))
        #expect(t.isInvertible)
        let flat = AffineTransform.scale(x: 1, y: 0)
        #expect(!flat.isInvertible)
        #expect(flat.inverted() == nil)
        #expect(!AffineTransform(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0).isInvertible)
    }
}
