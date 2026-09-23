import Foundation
import Testing
import WTGeometry
import WTRender
@testable import WireTuner

@Suite struct CanvasNavigationTests {
    let navigation = CanvasNavigation()
    let size = Size(width: 800, height: 600)

    private func viewport(zoom: Double = 1, origin: Point = Point(x: 7000, y: 7000), rotation: Double = 0) -> Viewport {
        Viewport(scrollOrigin: origin, rotationDegrees: rotation, zoom: zoom, size: size)
    }

    private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

    @Test func zoomInAndOutStepThroughTheLadderKeepingTheCentre() {
        let start = viewport()
        let centre = start.toPasteboard(start.viewCenter)
        let zoomedIn = navigation.zoomIn(start)
        #expect(zoomedIn.zoom == 2)
        #expect(zoomedIn.toPasteboard(zoomedIn.viewCenter).isApproximatelyEqual(to: centre, tolerance: 1e-6))
        #expect(navigation.zoomOut(start).zoom == 0.5)
        #expect(navigation.zoomIn(viewport(zoom: 1.5)).zoom == 2)
        #expect(navigation.zoomOut(viewport(zoom: 1.5)).zoom == 1)
        #expect(navigation.zoomIn(viewport(zoom: 256)).zoom == 256)
        #expect(navigation.zoomOut(viewport(zoom: 0.06)).zoom == 0.06)
    }

    @Test func zoomAboutAPointKeepsThatPointStill() {
        let start = viewport()
        let pivot = Point(x: 100, y: 50)
        let anchored = start.toPasteboard(pivot)
        let zoomed = navigation.zoom(start, to: 4, about: pivot)
        #expect(zoomed.zoom == 4)
        #expect(zoomed.toView(anchored).isApproximatelyEqual(to: pivot, tolerance: 1e-6))
        let magnified = navigation.magnify(start, by: 1.5, about: pivot)
        #expect(close(magnified.zoom, 1.5))
        #expect(magnified.toView(anchored).isApproximatelyEqual(to: pivot, tolerance: 1e-6))
        #expect(navigation.magnify(start, by: 0, about: pivot) == start)
        #expect(navigation.magnify(start, by: .nan, about: pivot) == start)
        #expect(navigation.zoom(start, to: 1000).zoom == 256, "clamped to 25,600%")
        #expect(navigation.zoom(start, to: 0.001).zoom == 0.06, "clamped to 6%")
    }

    @Test func fitCentresAndScalesTheRectangleWithAMargin() {
        let page = Pasteboard.letterPage
        let fitted = navigation.fit(viewport(), rect: page)
        // (600 - 40) / 792 is the limiting ratio for a Letter page in an 800 × 600 view.
        #expect(close(fitted.zoom, 560.0 / 792.0))
        #expect(fitted.toView(page.center).isApproximatelyEqual(to: fitted.viewCenter, tolerance: 1e-6))
        let wide = Rect(x: 1000, y: 1000, width: 1520, height: 10)
        #expect(close(navigation.fit(viewport(), rect: wide).zoom, 760.0 / 1520.0))
        let line = Rect(x: 1000, y: 1000, width: 76, height: 0)
        #expect(close(navigation.fittingZoom(for: line, in: viewport()), 10))
        let dot = Rect(x: 1000, y: 1000, width: 0, height: 0)
        #expect(navigation.fittingZoom(for: dot, in: viewport(zoom: 3)) == 3)
        #expect(navigation.fit(viewport(), rect: .null) == viewport())
        #expect(navigation.fittingZoom(for: Rect(x: 0, y: 0, width: 1, height: 1), in: viewport()) == 256)
    }

    @Test func fitMeasuresInTheRotatedAxes() {
        // At 90° a tall page lies on its side: its 612-point width is now vertical and limits.
        let page = Pasteboard.letterPage
        let rotated = viewport(rotation: 90)
        #expect(close(navigation.fittingZoom(for: page, in: rotated), 560.0 / 612.0))
        let fitted = navigation.fit(rotated, rect: page)
        #expect(fitted.toView(page.center).isApproximatelyEqual(to: fitted.viewCenter, tolerance: 1e-6))
    }

    @Test func scrollingIsClampedToThePasteboard() {
        let start = viewport(origin: Point(x: 0, y: 0))
        #expect(navigation.scroll(start, by: Vector(dx: -100, dy: -100)).scrollOrigin == .zero)
        let moved = navigation.scroll(start, by: Vector(dx: 100, dy: 50))
        #expect(moved.scrollOrigin == Point(x: 100, y: 50))
        let end = navigation.scroll(start, by: Vector(dx: 1e9, dy: 1e9))
        #expect(close(end.scrollOrigin.x, Pasteboard.side - 800))
        #expect(close(end.scrollOrigin.y, Pasteboard.side - 600))
        let atTwo = navigation.scroll(viewport(zoom: 2, origin: .zero), by: Vector(dx: 1e9, dy: 0))
        #expect(close(atTwo.scrollOrigin.x, Pasteboard.side - 400), "the limit is in pasteboard units")
    }

    @Test func aPasteboardSmallerThanTheViewIsCentred() {
        // At 6% the pasteboard is 959 points square: smaller than a 2000 × 1200 view.
        let tiny = Viewport(scrollOrigin: Point(x: 5, y: 5), zoom: 0.03, size: Size(width: 2000, height: 1200))
        let clamped = navigation.clamped(tiny)
        let content = navigation.scroller.contentBounds(of: clamped)
        #expect(close(content.width, Pasteboard.side * 0.06))
        let shown = clamped.toView(Pasteboard.bounds.center)
        #expect(shown.isApproximatelyEqual(to: clamped.viewCenter, tolerance: 1e-6))
        #expect(CanvasScrollerModel.clamp(10, length: 100, contentMin: 0, contentMax: 50) == -25)
    }

    @Test func scrollBarsReportProportionAndPosition() {
        let scroller = CanvasScrollerModel()
        let start = viewport(origin: .zero)
        let horizontal = scroller.horizontal(start)
        #expect(close(horizontal.knobProportion, 800 / Pasteboard.side))
        #expect(horizontal.value == 0)
        #expect(horizontal.isScrollable)
        let vertical = scroller.vertical(scroller.scrolled(start, verticalValue: 1))
        #expect(close(vertical.value, 1))
        let middle = scroller.scrolled(start, horizontalValue: 0.5)
        #expect(close(scroller.horizontal(middle).value, 0.5))
        #expect(close(middle.scrollOrigin.x, (Pasteboard.side - 800) / 2))
        #expect(scroller.scrolled(start, horizontalValue: 7).scrollOrigin.x == scroller.scrolled(start, horizontalValue: 1).scrollOrigin.x)
        let all = scroller.horizontal(navigation.clamped(Viewport(zoom: 0.06, size: Size(width: 2000, height: 1200))))
        #expect(all == ScrollAxisState(knobProportion: 1, value: 0))
        #expect(!all.isScrollable)
        #expect(CanvasScrollerModel.axis(start: 0, length: 0, contentMin: 0, contentMax: 10) == ScrollAxisState(knobProportion: 1, value: 0))
    }

    @Test func centringPutsAPointAtTheViewCentre() {
        let centred = navigation.centring(viewport(), on: Point(x: 8000, y: 8000))
        #expect(centred.toView(Point(x: 8000, y: 8000)).isApproximatelyEqual(to: centred.viewCenter, tolerance: 1e-6))
        #expect(CanvasNavigation.union([]) == nil)
        #expect(CanvasNavigation.union([Rect(x: 0, y: 0, width: 1, height: 1), Rect(x: 5, y: 5, width: 1, height: 1)]) == Rect(x: 0, y: 0, width: 6, height: 6))
    }
}

@Suite struct MagnificationFormatTests {
    @Test func parsesPercentagesMultipliersAndBareNumbers() {
        #expect(MagnificationFormat.parse("400") == .init(zoom: 4, wasClamped: false))
        #expect(MagnificationFormat.parse("400%") == .init(zoom: 4, wasClamped: false))
        #expect(MagnificationFormat.parse(" 4x ") == .init(zoom: 4, wasClamped: false))
        #expect(MagnificationFormat.parse("12X") == .init(zoom: 12, wasClamped: false))
        #expect(MagnificationFormat.parse("1.5×") == .init(zoom: 1.5, wasClamped: false))
        #expect(MagnificationFormat.parse("25,600%") == .init(zoom: 256, wasClamped: false))
        #expect(MagnificationFormat.parse("6") == .init(zoom: 0.06, wasClamped: false))
        #expect(MagnificationFormat.parse("33.333").map { MagnificationFormat.string(for: $0.zoom) } == "33.33%", "two decimals of a percent")
    }

    @Test func clampsOutOfRangeAndRejectsGarbage() {
        #expect(MagnificationFormat.parse("0") == .init(zoom: 0.06, wasClamped: true))
        #expect(MagnificationFormat.parse("99999") == .init(zoom: 256, wasClamped: true))
        #expect(MagnificationFormat.parse("300x") == .init(zoom: 256, wasClamped: true))
        #expect(MagnificationFormat.parse("abc") == nil)
        #expect(MagnificationFormat.parse("") == nil)
        #expect(MagnificationFormat.parse("inf") == nil)
    }

    @Test func formatsWithoutTrailingZeros() {
        #expect(MagnificationFormat.string(for: 1.5) == "150%")
        #expect(MagnificationFormat.string(for: 0.06) == "6%")
        #expect(MagnificationFormat.string(for: 256) == "25600%")
        #expect(MagnificationFormat.string(for: 0.3333) == "33.33%")
        #expect(MagnificationFormat.string(for: 0.125) == "12.5%")
        #expect(MagnificationFormat.presetTitles.first == "6%")
        #expect(MagnificationFormat.presetTitles.count == ZoomLadder.presets.count)
    }
}

/// WTRender's drawing modes as the app names and stores them.
private typealias Mode = ViewMode

@Suite struct ViewModeTests {
    @Test func togglesFollowTheDrawingModesPage() {
        #expect(Mode.fastKeyline.togglingKeyline == .fastPreview)
        #expect(Mode.preview.togglingKeyline == .keyline)
        #expect(Mode.keyline.togglingKeyline == .preview)
        #expect(Mode.fastPreview.togglingKeyline == .fastKeyline)
        #expect(Mode.preview.togglingFast == .fastPreview)
        #expect(Mode.fastKeyline.togglingFast == .keyline)
        #expect(Mode.allCases.map(\.title) == ["Preview", "Fast Preview", "Keyline", "Fast Keyline"])
        #expect(Mode.allCases.filter(\.isKeyline) == [.keyline, .fastKeyline])
        #expect(Mode.allCases.filter(\.isFast) == [.fastPreview, .fastKeyline])
    }

    @Test func storedNamesRoundTripAndRejectUnknownOnes() throws {
        #expect(Mode.allCases.map(\.storedName) == ["preview", "fast_preview", "keyline", "fast_keyline"])
        for mode in Mode.allCases {
            #expect(Mode(storedName: mode.storedName) == mode)
            let data = try JSONEncoder().encode([mode])
            #expect(try JSONDecoder().decode([Mode].self, from: data) == [mode])
        }
        #expect(Mode(storedName: "outline") == nil)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([Mode].self, from: Data("[\"outline\"]".utf8)) }
    }
}
