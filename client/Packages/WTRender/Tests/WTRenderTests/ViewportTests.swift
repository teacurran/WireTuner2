import WTGeometry
import Testing
@testable import WTRender

@Suite struct ViewportTests {
    private let size = Size(width: 800, height: 600)

    @Test func normalizationAndClamping() {
        #expect(Viewport.normalizedDegrees(370) == 10)
        #expect(Viewport.normalizedDegrees(-190) == 170)
        #expect(Viewport.normalizedDegrees(180) == 180)
        #expect(Viewport.normalizedDegrees(-180) == 180)
        #expect(Viewport.normalizedDegrees(540) == 180)
        #expect(Viewport.normalizedDegrees(-360) == 0)
        #expect(Viewport.normalizedDegrees(-0.0).sign == .plus)
        #expect(Viewport.clampedZoom(.nan) == 1)
        #expect(Viewport.clampedZoom(.infinity) == 1)
        #expect(Viewport.clampedZoom(1000) == 256)
        #expect(Viewport.clampedZoom(0.01) == 0.06)
        #expect(Viewport.clampedZoom(1.5) == 1.5)

        var viewport = Viewport(rotationDegrees: 400, zoom: 0, size: size)
        #expect(viewport.rotationDegrees == 40)
        #expect(viewport.zoom == 0.06)
        viewport.rotationDegrees = -270
        viewport.zoom = 999
        #expect(viewport.rotationDegrees == 90)
        #expect(viewport.zoom == 256)
        #expect(approx(viewport.rotationRadians, .pi / 2))
        #expect(viewport.viewBounds == Rect(origin: .zero, size: size))
        #expect(viewport.viewBounds.size == size)
        #expect(viewport.viewCenter == Point(x: 400, y: 300))
    }

    @Test func identityViewportIsTheIdentityTransform() {
        let viewport = Viewport(size: size)
        #expect(viewport.pasteboardToView == .identity)
        #expect(viewport.viewToPasteboard == .identity)
        #expect(viewport.translation == Vector.zero)
        #expect(viewport.visiblePasteboardBounds == viewport.viewBounds)
    }

    @Test func scrollOriginAppearsAtTheViewOrigin() {
        let viewport = Viewport(scrollOrigin: Point(x: 120, y: -40), rotationDegrees: 27, zoom: 3, size: size)
        #expect(approx(viewport.toView(Point(x: 120, y: -40)), .zero, tolerance: 1e-12))
        #expect(approx(viewport.toPasteboard(.zero), Point(x: 120, y: -40), tolerance: 1e-12))
        #expect(approx(Point.zero + viewport.translation, viewport.pasteboardToView.apply(.zero)))
    }

    @Test func compositionIsTranslationRotationScale() {
        let viewport = Viewport(scrollOrigin: Point(x: 10, y: 20), rotationDegrees: 15, zoom: 2, size: size)
        let expected = AffineTransform.scale(2)
            .concatenating(.rotation(degrees: -15))
            .concatenating(.translation(viewport.translation))
        let actual = viewport.pasteboardToView
        #expect(approx(actual.a, expected.a) && approx(actual.b, expected.b) && approx(actual.c, expected.c))
        #expect(approx(actual.d, expected.d) && approx(actual.tx, expected.tx) && approx(actual.ty, expected.ty))
        #expect(approx(viewport.rotationAndScale.scaleFactor, 2))
    }

    @Test(arguments: [0.0, 15.0, 90.0, -37.5, 180.0])
    func roundTripsThroughRotation(degrees: Double) {
        let viewport = Viewport(scrollOrigin: Point(x: 100, y: -50), rotationDegrees: degrees, zoom: 2.5, size: size)
        let points = [Point.zero, Point(x: 400, y: 300), Point(x: -1234.5, y: 987.25), Point(x: 1e5, y: -1e5)]
        for point in points {
            let there = viewport.toView(point)
            let back = viewport.toPasteboard(there)
            #expect(approx(back, point, tolerance: 1e-8), "\(point) at \(degrees)°")
            let again = viewport.toView(viewport.toPasteboard(point))
            #expect(approx(again, point, tolerance: 1e-8))
        }
        // Distances scale by the zoom regardless of angle.
        let a = viewport.toView(Point(x: 0, y: 0))
        let b = viewport.toView(Point(x: 3, y: 4))
        #expect(approx(a.distance(to: b), 12.5, tolerance: 1e-9))
    }

    @Test func positiveRotationIsCounterClockwiseOnScreen() {
        // The view centre shows the pasteboard origin; a point to its right on the pasteboard
        // appears above it after turning the canvas 90° counter-clockwise.
        let viewport = Viewport(size: size).rotated(toDegrees: 90)
        let centre = viewport.viewCenter
        let origin = viewport.toPasteboard(centre)
        let right = viewport.toView(origin + Vector(dx: 10, dy: 0))
        #expect(approx(right, centre + Vector(dx: 0, dy: -10), tolerance: 1e-9))
        let below = viewport.toView(origin + Vector(dx: 0, dy: 10))
        #expect(approx(below, centre + Vector(dx: 10, dy: 0), tolerance: 1e-9))
    }

    @Test func rotatingAboutAPivotKeepsItFixed() {
        let start = Viewport(scrollOrigin: Point(x: 50, y: 60), rotationDegrees: 10, zoom: 1.5, size: size)
        let centreBefore = start.toPasteboard(start.viewCenter)
        let turned = start.rotated(byDegrees: 15)
        #expect(turned.rotationDegrees == 25)
        #expect(turned.zoom == start.zoom)
        #expect(approx(turned.toPasteboard(turned.viewCenter), centreBefore, tolerance: 1e-9))
        #expect(turned.scrollOrigin != start.scrollOrigin)

        let pivot = Point(x: 100, y: 500)
        let pivotBefore = start.toPasteboard(pivot)
        let turnedAboutPivot = start.rotated(toDegrees: -45, aboutViewPoint: pivot)
        #expect(turnedAboutPivot.rotationDegrees == -45)
        #expect(approx(turnedAboutPivot.toPasteboard(pivot), pivotBefore, tolerance: 1e-9))
    }

    @Test func zoomingAboutAPivotKeepsItFixed() {
        let start = Viewport(scrollOrigin: Point(x: -20, y: 30), rotationDegrees: 33, zoom: 1, size: size)
        let pointer = Point(x: 640, y: 120)
        let under = start.toPasteboard(pointer)
        let zoomed = start.zoomed(to: 4, aboutViewPoint: pointer)
        #expect(zoomed.zoom == 4)
        #expect(zoomed.rotationDegrees == 33)
        #expect(approx(zoomed.toPasteboard(pointer), under, tolerance: 1e-9))

        let centred = start.zoomed(to: 0.5)
        #expect(approx(centred.toPasteboard(centred.viewCenter), start.toPasteboard(start.viewCenter), tolerance: 1e-9))
        #expect(start.zoomed(to: 1e9).zoom == 256)
    }

    @Test func scrollingMovesContentByTheDelta() {
        let start = Viewport(scrollOrigin: Point(x: 0, y: 0), rotationDegrees: 60, zoom: 2, size: size)
        let probe = Point(x: 12, y: 34)
        let before = start.toView(probe)
        let scrolled = start.scrolled(byViewDelta: Vector(dx: 30, dy: -10))
        #expect(scrolled.rotationDegrees == 60 && scrolled.zoom == 2)
        #expect(approx(scrolled.toView(probe), before - Vector(dx: 30, dy: -10), tolerance: 1e-9))
    }

    @Test func visibleBoundsGrowWhenRotated() {
        let straight = Viewport(scrollOrigin: Point(x: 10, y: 20), zoom: 2, size: size)
        #expect(approx(straight.visiblePasteboardBounds, Rect(x: 10, y: 20, width: 400, height: 300)))
        let turned = straight.rotated(toDegrees: 45)
        let bounds = turned.visiblePasteboardBounds
        #expect(bounds.width > 400 && bounds.height > 300)
        #expect(bounds.contains(turned.toPasteboard(turned.viewCenter)))
    }
}
