import WTGeometry
import CoreGraphics
import Foundation
import Testing
@testable import WTRender

/// ATTR-027: ramp compilation in OKLab with the behaviours and the logarithmic curve; axial,
/// elliptical, rectangle, cone and contour shadings; the cached distance field; PDF output.
@Suite struct GradientTests {
    static let redToBlue = Gradient(.linear, from: Color(red: 1, green: 0, blue: 0), to: Color(red: 0, green: 0, blue: 1))

    @Test func okLabRoundTripsAndKnownValues() {
        let white = OKLab.fromSRGB(1, 1, 1)
        #expect(approx(white.x, 1, tolerance: 1e-4) && approx(white.y, 0, tolerance: 1e-4) && approx(white.z, 0, tolerance: 1e-4))
        for (r, g, b) in [(0.2, 0.5, 0.9), (1.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.03, 0.002, 0.8)] {
            let back = OKLab.toSRGB(OKLab.fromSRGB(r, g, b))
            #expect(approx(back.x, r, tolerance: 1e-6) && approx(back.y, g, tolerance: 1e-6) && approx(back.z, b, tolerance: 1e-6))
        }
        let outOfGamut = OKLab.toSRGB(SIMD3(0.9, 0.4, 0.4))
        #expect((0...1).contains(outOfGamut.x) && (0...1).contains(outOfGamut.y) && (0...1).contains(outOfGamut.z), "clipped to the gamut")
    }

    @Test func theRampHitsItsStopsExactlyAndDoesNotPassThroughGrey() {
        let ramp = GradientRamp(stops: Self.redToBlue.sortedStops)
        #expect(ramp.color(at: 0) == SIMD4(1, 0, 0, 1))
        #expect(ramp.color(at: 1) == SIMD4(0, 0, 1, 1))
        let middle = ramp.color(at: 0.5)
        let chroma = max(middle.x, middle.y, middle.z) - min(middle.x, middle.y, middle.z)
        #expect(chroma > 0.3, "OKLab keeps the middle of red → blue purple, not grey (\(middle))")
        #expect(abs(middle.x - 0.5) > 0.05, "and differs from the sRGB midpoint")
        #expect(ramp.color(at: -1) == ramp.color(at: 0) && ramp.color(at: .nan) == ramp.color(at: 0))
        #expect(ramp.color(at: 0.25) != ramp.color(at: 0.26), "interpolated between table entries")
    }

    @Test func stopsBeyondTheEndsAndAlpha() {
        let stops = [Gradient.Stop(offset: 0.25, color: Color(red: 1, green: 1, blue: 0)), Gradient.Stop(offset: 0.75, color: Color(red: 0, green: 1, blue: 1, alpha: 0))]
        let ramp = GradientRamp(stops: stops)
        #expect(ramp.color(at: 0.1) == SIMD4(1, 1, 0, 1), "before the first stop, its colour")
        #expect(ramp.color(at: 0.9).w == 0, "after the last, its colour")
        let middle = ramp.color(at: 0.5)
        #expect(approx(middle.w, 0.5, tolerance: 0.01))
        #expect(approx(middle.x, 1, tolerance: 0.05), "premultiplied: the transparent stop does not pull the colour")
        let clear = GradientRamp(stops: [Gradient.Stop(offset: 0, color: .clear), Gradient.Stop(offset: 1, color: .clear)])
        #expect(clear.color(at: 0.5) == SIMD4(0, 0, 0, 0))
        let single = GradientRamp(stops: [Gradient.Stop(offset: 0.5, color: Color(red: 0.2, green: 0.4, blue: 0.6))])
        #expect(single.color(at: 0) == single.color(at: 1), "one stop reads as that colour at both ends")
        let coincident = GradientRamp(stops: [Gradient.Stop(offset: 0.5, color: .black), Gradient.Stop(offset: 0.5, color: .white)])
        #expect(coincident.color(at: 0.75) == SIMD4(1, 1, 1, 1))
        #expect(GradientRamp.cached(stops) === GradientRamp.cached(stops))
    }

    @Test func stopsSortByOffsetThenOrderAndClamp() {
        let gradient = Gradient(stops: [
            Gradient.Stop(offset: 0.8, color: .white),
            Gradient.Stop(offset: -2, color: .black),
            Gradient.Stop(offset: 0.8, color: red),
            Gradient.Stop(offset: .nan, color: blue),
        ])
        #expect(gradient.sortedStops.map(\.offset) == [0, 0, 0.8, 0.8])
        #expect(gradient.sortedStops.map(\.color) == [.black, blue, .white, red])
        #expect(Gradient(repeatCount: 0, stops: []).effectiveRepeatCount == 1)
        #expect(Gradient(repeatCount: 500, stops: []).effectiveRepeatCount == 100)
    }

    @Test func behavioursAndTheLogarithmicCurve() {
        var gradient = Self.redToBlue
        #expect(gradient.rampPosition(-1) == 0 && gradient.rampPosition(2) == 1 && gradient.rampPosition(0.3) == 0.3)
        #expect(gradient.rampPosition(.nan) == 0)
        gradient.behavior = .repeat
        gradient.repeatCount = 4
        #expect(approx(gradient.rampPosition(0.3), 0.2, tolerance: 1e-12))
        #expect(gradient.rampPosition(1) == 1, "the last repeat ends on the end colour")
        gradient.behavior = .reflect
        #expect(approx(gradient.rampPosition(0.125 / 2), 0.5, tolerance: 1e-12), "halfway up the first reflection")
        #expect(approx(gradient.rampPosition(0.125 * 1.5), 0.5, tolerance: 1e-12), "halfway down")
        #expect(gradient.rampPosition(1) == 0, "back at the start after whole reflections")
        gradient.behavior = .autoSize
        #expect(gradient.rampPosition(0.4) == 0.4, "Auto size clamps like Normal")
        gradient.behavior = .normal
        gradient.kind = .logarithmic
        #expect(approx(gradient.rampPosition(0.5), log(5.5) / log(10), tolerance: 1e-12))
        #expect(gradient.rampPosition(0) == 0 && approx(gradient.rampPosition(1), 1, tolerance: 1e-12))
    }

    @Test func axisNormalizations() {
        let bounds = Rect(x: 10, y: 20, width: 100, height: 40)
        let auto = Gradient(.linear, from: .black, to: .white)
        #expect(auto.resolvedAxis(bounds: bounds) == Gradient.Axis(start: Point(x: 10, y: 40), end: Point(x: 110, y: 40)))
        var radial = Gradient(.radial, from: .black, to: .white)
        #expect(radial.resolvedAxis(bounds: bounds) == Gradient.Axis(start: Point(x: 60, y: 40), end: Point(x: 110, y: 40), end2: Point(x: 60, y: 60)))
        var cone = Gradient(.cone, from: .black, to: .white)
        #expect(cone.resolvedAxis(bounds: bounds).start == Point(x: 60, y: 40))
        radial.axis = Gradient.Axis(start: Point(x: 0, y: 0), end: Point(x: 10, y: 0))
        #expect(radial.resolvedAxis(bounds: bounds).end2 == Point(x: 0, y: 10), "a missing second end is the first rotated 90°")
        radial.axis = Gradient.Axis(start: Point(x: 5, y: 5), end: Point(x: 5, y: 5))
        #expect(radial.resolvedAxis(bounds: bounds).end == Point(x: 6, y: 5), "a coincident end is a 1 pt axis")
        radial.behavior = .autoSize
        #expect(radial.resolvedAxis(bounds: bounds).start == Point(x: 60, y: 40), "Auto size ignores the axis")
        cone.axis = Gradient.Axis(start: .zero, end: Point(x: 0, y: 3))
        #expect(cone.resolvedAxis(bounds: bounds).end == Point(x: 0, y: 3))
        let flat = Gradient(.linear, from: .black, to: .white).resolvedAxis(bounds: Rect(x: 5, y: 5, width: 0, height: 0))
        #expect(flat.end == Point(x: 6, y: 5))
    }

    @Test func theDistanceFieldMeasuresToTheBoundary() {
        let square = DisplayPath(rect: Rect(x: 0, y: 0, width: 40, height: 40))
        let field = DistanceField(path: square, rule: .nonZero, resolution: 4)
        #expect(approx(field.maximum, 20, tolerance: 0.3), "the inradius of a 40 pt square")
        #expect(approx(field.distance(at: Point(x: 20, y: 20)), 20, tolerance: 0.3))
        #expect(approx(field.distance(at: Point(x: 5, y: 20)), 5, tolerance: 0.3))
        #expect(field.distance(at: Point(x: -30, y: 0)) == 0, "outside the grid")
        #expect(field.distance(at: Point(x: .nan, y: 0)) == 0)
        let frame = DistanceField(path: ReferenceCorpus.frame(Rect(x: 0, y: 0, width: 40, height: 40), Rect(x: 10, y: 10, width: 20, height: 20)), rule: .evenOdd, resolution: 2)
        #expect(frame.distance(at: Point(x: 20, y: 20)) == 0, "even-odd leaves the middle out")
        #expect(DistanceField.cached(path: square, rule: .nonZero, resolution: 4) === DistanceField.cached(path: square, rule: .nonZero, resolution: 4))
        let huge = DistanceField(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 4000, height: 4000)), rule: .nonZero, resolution: 16)
        #expect(huge.resolution < 16, "coarsened to stay within the sample budget")
        #expect(DistanceField.transform([0, 1e20, 1e20, 0], count: 4) == [0, 1, 1, 0])
    }

    @Test func everyTypeRendersInsideItsPath() {
        for kind in Gradient.Kind.allCases {
            for behavior in Gradient.Behavior.allCases {
                let gradient = Gradient(kind: kind, behavior: behavior, repeatCount: 2, stops: [Gradient.Stop(offset: 0, color: Color(red: 1, green: 0, blue: 0)), Gradient.Stop(offset: 1, color: Color(red: 0, green: 0, blue: 1))])
                let item = DisplayItem.path(PathItem(path: DisplayPath(ellipseIn: Rect(x: 16, y: 16, width: 96, height: 64)), appearance: Appearance([.fill(FillPaint(paint: .gradient(gradient)))])))
                let surface = renderSurface([item])
                #expect(surface.pixel(x: 4, y: 4) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255), "\(kind) \(behavior) clipped to the path")
                let centre = surface.pixel(x: 64, y: 48)
                #expect(centre.alpha == 255 && Int(centre.red) + Int(centre.blue) > 200 && centre.green < 140, "\(kind) \(behavior) paints a ramp colour: \(centre)")
            }
        }
        // A gradient without stops paints nothing.
        let none = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 50, height: 50)), appearance: Appearance([.fill(FillPaint(paint: .gradient(Gradient(stops: []))))])))
        #expect(renderSurface([none]).pixel(x: 25, y: 25) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
    }

    @Test func degenerateAxesStillDraw() {
        for kind in [Gradient.Kind.radial, .rectangle] {
            let gradient = Gradient(kind: kind, axis: Gradient.Axis(start: Point(x: 64, y: 48), end: Point(x: 90, y: 48), end2: Point(x: 116, y: 48)), stops: [Gradient.Stop(offset: 0, color: .black), Gradient.Stop(offset: 1, color: .white)])
            let item = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 128, height: 96)), appearance: Appearance([.fill(FillPaint(paint: .gradient(gradient)))])))
            #expect(renderSurface([item]).pixel(x: 64, y: 48).red < 20, "\(kind): collinear ends read as a circle or square")
        }
        // A contour whose start lies outside the path reaches the inradius.
        let outside = Gradient(kind: .contour, axis: Gradient.Axis(start: Point(x: -50, y: -50), end: Point(x: 0, y: 0)), stops: [Gradient.Stop(offset: 0, color: .black), Gradient.Stop(offset: 1, color: .white)])
        let item = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 24, y: 8, width: 80, height: 80)), appearance: Appearance([.fill(FillPaint(paint: .gradient(outside)))])))
        #expect(renderSurface([item]).pixel(x: 64, y: 48).red > 230)
    }

    @Test func contourOnAFiveHundredPointPathAfterTheFirstFrame() {
        let points = (0..<500).map { index -> Point in
            let angle = 2 * Double.pi * Double(index) / 500
            let radius = 300 + 40 * sin(angle * 9)
            return Point(x: 400 + radius * cos(angle), y: 400 + radius * sin(angle))
        }
        let gradient = Gradient(.contour, from: .black, to: .white)
        let item = DisplayItem.path(PathItem(path: DisplayPath(polygon: points), appearance: Appearance([.fill(FillPaint(paint: .gradient(gradient)))])))
        let list = DisplayList(canvas: "x", items: [item])
        let renderer = CoreGraphicsRenderer(background: .white)
        let viewport = Viewport(size: Size(width: 800, height: 800))
        _ = renderer.renderBitmap(list, viewport: viewport)
        let started = DispatchTime.now().uptimeNanoseconds
        let image = renderer.renderBitmap(list, viewport: viewport)
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        #expect(image != nil)
        print("PERF contour gradient: a 500-point path at 800 × 800 px in \(String(format: "%.1f", milliseconds)) ms after the first frame (budget 10 ms on M1, enforced in release builds)")
        #if !DEBUG
        #expect(milliseconds < 10)
        #endif
    }

    /// PDF export of each type reopens (rasterized by Core Graphics, as Preview does) like the
    /// screen: the shading types exactly within REND-001's gate; the sampled types, embedded at
    /// 300 dpi, within 24/255 on at most 1% of the pixels.
    @Test(arguments: Gradient.Kind.allCases)
    func pdfOutputMatchesTheScreen(kind: Gradient.Kind) throws {
        let gradient = Gradient(kind: kind, behavior: .normal, stops: [Gradient.Stop(offset: 0, color: Color(red: 1, green: 0, blue: 0)), Gradient.Stop(offset: 0.5, color: Color(red: 1, green: 0.9, blue: 0)), Gradient.Stop(offset: 1, color: Color(red: 0, green: 0, blue: 1))])
        let path = kind == .contour ? AttributeCorpus.concaveStar(center: Point(x: 64, y: 48), outer: 44, inner: 22) : DisplayPath(ellipseIn: Rect(x: 8, y: 8, width: 112, height: 80))
        let list = DisplayList(canvas: "pdf", items: [.path(PathItem(path: path, appearance: Appearance([.fill(FillPaint(paint: .gradient(gradient)))])))])
        let renderer = CoreGraphicsRenderer(background: .white)
        let viewport = Viewport(size: Size(width: 128, height: 96))
        let pdf = try #require(renderer.renderPDF(list, viewport: viewport))
        let screenImage = try #require(renderer.renderBitmap(list, viewport: viewport, scale: 2))
        let screen = try #require(BitmapSurface(drawing: screenImage))
        let reopened = try #require(PDFRasterizer.rasterize(pdf, scale: 2))
        let comparison = PixelComparison(reference: screen, candidate: reopened, interiorTolerance: 0, edgeTolerance: 16)
        switch kind {
        case .linear, .logarithmic, .radial:
            #expect(comparison.passes, "\(kind): \(comparison.interiorMismatches) interior (Δ\(comparison.maxInteriorDifference)), \(comparison.edgeMismatches) edge (Δ\(comparison.maxEdgeDifference))")
        case .rectangle, .cone, .contour:
            var off = 0
            for y in 0..<screen.height {
                for x in 0..<screen.width where screen.pixel(x: x, y: y).maxChannelDifference(to: reopened.pixel(x: x, y: y)) > 24 {
                    off += 1
                }
            }
            #expect(Double(off) <= 0.01 * Double(screen.width * screen.height), "\(kind): \(off) pixels beyond 24/255")
        }
    }
}
