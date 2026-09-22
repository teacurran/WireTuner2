import Testing
import WTGeometry
@testable import WTRender

/// WTGeometry's own tests cover `Point`, `Rect` and `AffineTransform`; these cover what
/// WTRender adds on top.
@Suite struct GeometryExtensionTests {
    @Test func sizeAndRectBridging() {
        #expect(Size.zero == Size(width: 0, height: 0))
        let rect = Rect(origin: Point(x: 3, y: 4), size: Size(width: -2, height: 5))
        #expect(rect == Rect(x: 1, y: 4, width: 2, height: 5), "negative sizes normalize")
        #expect(rect.size == Size(width: 2, height: 5))
        #expect(rect.nonNull == rect)
        #expect(Rect.null.nonNull == nil)
    }

    @Test func rotationInDegreesAndScaleFactor() {
        let quarter = AffineTransform.rotation(degrees: 90)
        let turned = quarter.apply(Point(x: 1, y: 0))
        #expect(abs(turned.x) < 1e-12 && abs(turned.y - 1) < 1e-12, "positive angles turn +x toward +y")
        #expect(abs(AffineTransform.scale(x: 2, y: 8).scaleFactor - 4) < 1e-12)
        #expect(abs(AffineTransform.rotation(degrees: 33).scaleFactor - 1) < 1e-12)
    }

    @Test func singularTransformsInvertToTheIdentity() {
        #expect(AffineTransform.scale(x: 0, y: 1).invertedOrIdentity == .identity)
        let regular = AffineTransform.translation(x: 5, y: -2).concatenating(.scale(2))
        let inverse = regular.invertedOrIdentity
        let roundTrip = inverse.apply(regular.apply(Point(x: 7, y: 9)))
        #expect(roundTrip.isApproximatelyEqual(to: Point(x: 7, y: 9), tolerance: 1e-12))
    }
}
