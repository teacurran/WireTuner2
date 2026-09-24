import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// FONT-015 / FONT-009 / FONT-011 (render half): the glyph flattener, the outline finishing steps,
/// thumbnails and the glyph canvas decoration.
@Suite struct GlyphFlattenerTests {
    static func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Contour {
        Contour(polygon: [Point(x: x, y: y), Point(x: x + width, y: y), Point(x: x + width, y: y + height), Point(x: x, y: y + height)], closed: true)
    }

    static func circle(_ cx: Double, _ cy: Double, _ r: Double) -> Contour {
        let k = 0.5522847498 * r
        return Contour(segments: [
            CubicBezier(Point(x: cx + r, y: cy), Point(x: cx + r, y: cy + k), Point(x: cx + k, y: cy + r), Point(x: cx, y: cy + r)),
            CubicBezier(Point(x: cx, y: cy + r), Point(x: cx - k, y: cy + r), Point(x: cx - r, y: cy + k), Point(x: cx - r, y: cy)),
            CubicBezier(Point(x: cx - r, y: cy), Point(x: cx - r, y: cy - k), Point(x: cx - k, y: cy - r), Point(x: cx, y: cy - r)),
            CubicBezier(Point(x: cx, y: cy - r), Point(x: cx + k, y: cy - r), Point(x: cx + r, y: cy - k), Point(x: cx + r, y: cy)),
        ], closed: true)
    }

    static let black = Paint.solid(.black)

    @Test func overlappingShapesUnionAndEvenOddCountersSurvive() {
        let a = NodeID(counter: 1, replica: 1)
        let ring = GlyphShape(contours: [Self.box(0, -700, 600, 700), Self.box(100, -600, 400, 500)], fillRule: .evenOdd)
        let bar = GlyphShape(contours: [Self.box(500, -400, 300, 100)], transform: .translation(x: 50, y: 0))
        let outline = GlyphFlattener.outline(of: a, sources: [a: GlyphSource(shapes: [ring, bar])])
        #expect(outline.bounds == Rect(x: 0, y: -700, width: 850, height: 700))
        #expect(outline.path.fillRule == .nonZero && !outline.path.contains(Point(x: 300, y: -300)) && outline.path.contains(Point(x: 700, y: -350)))
        #expect(outline.report == GlyphFlatteningReport())
        // Keeping overlaps keeps both shapes' contours side by side.
        let kept = GlyphFlattener.outline(of: a, sources: [a: GlyphSource(shapes: [ring, bar])], options: .init(keepOverlaps: true))
        #expect(kept.path.contours.count == 3)
        #expect(GlyphFlattener.outline(of: a, sources: [:]) == .empty && GlyphOutline.empty.bounds == nil)
        #expect(GlyphSource().isEmpty && !GlyphSource(shapes: [ring]).isEmpty)
    }

    @Test func strokesExpandAndOpenUnstrokedContoursDrop() {
        let a = NodeID(counter: 1, replica: 1)
        let open = Contour(polygon: [Point(x: 0, y: 0), Point(x: 100, y: 0)], closed: false)
        let stroked = GlyphShape(contours: [open], filled: false, strokes: [StrokePaint(paint: Self.black, style: StrokeStyle(width: 20))])
        let bare = GlyphShape(contours: [open, Self.box(0, 50, 10, 10)])
        let unfilled = GlyphShape(contours: [Self.box(200, 0, 10, 10)], filled: false)
        let outline = GlyphFlattener.outline(of: a, sources: [a: GlyphSource(shapes: [stroked, bare, unfilled])])
        #expect(outline.report.droppedOpenContours == 1)
        let bounds = try? #require(outline.bounds)
        #expect(bounds == Rect(x: 0, y: -10, width: 100, height: 70))
    }

    @Test func componentsNestResolveAndStopAtTheDepthLimit() {
        let ids = (1...12).map { NodeID(counter: UInt64($0), replica: 1) }
        var sources: [NodeID: GlyphSource] = [ids[0]: GlyphSource(shapes: [GlyphShape(contours: [Self.box(0, 0, 10, 10)])])]
        for level in 1..<ids.count {
            sources[ids[level]] = GlyphSource(components: [GlyphComponentPlacement(source: .glyph(ids[level - 1]), transform: .translation(x: 10, y: 0))])
        }
        // Eight levels resolve; the ninth reads as a placeholder.
        let eight = GlyphFlattener.outline(of: ids[8], sources: sources)
        #expect(eight.bounds == Rect(x: 80, y: 0, width: 10, height: 10) && !eight.report.depthExceeded)
        let nine = GlyphFlattener.outline(of: ids[9], sources: sources)
        #expect(nine.path.isEmpty && nine.report.depthExceeded && nine.report.placeholders == 1)
        let all = GlyphFlattener.outlines(sources)
        #expect(all.count == 12 && all[ids[3]]?.bounds?.minX == 30)
        // Placeholders: a cached outline draws; a cut loop or an unknown glyph does not.
        let cached = GlyphFlattener.outline(of: GlyphSource(components: [
            GlyphComponentPlacement(source: .placeholder(FilledPath(Self.box(0, 0, 5, 5))), transform: .translation(x: 1, y: 1)),
            GlyphComponentPlacement(source: .placeholder(.empty)),
            GlyphComponentPlacement(source: .glyph(NodeID(counter: 99, replica: 9))),
        ]), sources: sources)
        #expect(cached.bounds == Rect(x: 1, y: 1, width: 5, height: 5) && cached.report.placeholders == 3)
        // A loop reaching the glyph itself is refused as a placeholder.
        let loop = GlyphFlattener.outline(of: ids[0], sources: [ids[0]: GlyphSource(components: [GlyphComponentPlacement(source: .glyph(ids[0]))])])
        #expect(loop.path.isEmpty && loop.report.placeholders == 1 && !loop.report.depthExceeded)
    }

    @Test func finishingDirectionsExtremaRounding() {
        // Glyph space (y down) → font space (y up).
        let ring = [Self.box(0, -700, 600, 700), Self.box(100, -600, 400, 500).reversed()]
        let flipped = GlyphContours.flipped(ring)
        #expect(flipped[0].bounds == Rect(x: 0, y: 0, width: 600, height: 700))
        #expect(GlyphContours.depths(flipped) == [0, 1])
        let ccw = GlyphContours.correctingDirections(flipped, outer: .counterClockwise)
        #expect(ccw[0].signedArea() > 0 && ccw[1].signedArea() < 0 && GlyphContours.hasCorrectDirections(ccw, outer: .counterClockwise))
        let cw = GlyphContours.correctingDirections(flipped, outer: .clockwise)
        #expect(cw[0].signedArea() < 0 && cw[1].signedArea() > 0 && !GlyphContours.hasCorrectDirections(cw, outer: .counterClockwise))
        let degenerate = Contour(polygon: [Point(x: 0, y: 0), Point(x: 1, y: 0)], closed: true)
        #expect(GlyphContours.correctingDirections([degenerate], outer: .clockwise) == [degenerate])
        #expect(GlyphContours.depths([Contour(segments: [], closed: true)]) == [0])
        // A curve with an interior extreme gains a point there.
        let bump = Contour(segments: [CubicBezier(Point(x: 0, y: 0), Point(x: 0, y: 100), Point(x: 100, y: 100), Point(x: 100, y: 0))], closed: true)
        #expect(GlyphContours.isMissingExtrema([bump]) && !GlyphContours.isMissingExtrema([Self.box(0, 0, 1, 1)]))
        let split = GlyphContours.addingExtrema([bump])
        #expect(split[0].segments.count == 2 && abs(split[0].segments[0].p3.y - 75) < 1e-9 && !GlyphContours.isMissingExtrema(split))
        // Rounding: whole units, collapsed segments and empty contours dropped.
        let wobbly = Contour(polygon: [Point(x: 0.4, y: 0.2), Point(x: 10.6, y: 0), Point(x: 10.6, y: 0.3), Point(x: 10, y: 10.5)], closed: true)
        #expect(GlyphContours.isOffGrid([wobbly]))
        let rounded = GlyphContours.rounded([wobbly, Contour(polygon: [Point(x: 0.1, y: 0.1), Point(x: 0.2, y: 0.2)], closed: false)])
        #expect(rounded.count == 1 && !GlyphContours.isOffGrid(rounded) && rounded[0].segments.count == 3)
        #expect(GlyphContours.pointCount([bump, Self.box(0, 0, 1, 1)]) == 3 + 4)
    }

    @Test func quadraticConversionStaysWithinHalfAUnit() {
        let circle = Self.circle(500, 500, 400)
        let quadratic = GlyphContours.quadratic(circle)
        #expect(quadratic.segments.count >= 4 && quadratic.segments.count <= 32)
        for (index, cubic) in circle.segments.enumerated() {
            _ = index
            for step in 0...20 {
                let point = cubic.evaluate(Double(step) / 20)
                let nearest = quadratic.segments.map { quad in (0...40).map { quad.evaluate(Double($0) / 40).distance(to: point) }.min()! }.min()!
                #expect(nearest <= 0.6)
            }
        }
        // Lines become one quadratic each, and an open contour's closing segment is added.
        let triangle = GlyphContours.quadratic(Contour(polygon: [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 5, y: 8)], closed: true))
        #expect(triangle.segments.count == 3 && triangle.segments[0].p1 == Point(x: 5, y: 0))
        #expect(QuadraticContour(segments: []).segments.isEmpty)
        let huge = CubicBezier(Point(x: 0, y: 0), Point(x: 1e7, y: 1e7), Point(x: -1e7, y: 1e7), Point(x: 1, y: 0))
        #expect(!GlyphContours.quadratics(for: huge, tolerance: 1e-9).isEmpty)
    }

    @Test func thumbnailsFitTheEmAndCache() throws {
        let outline = FilledPath(Self.box(0, -700, 500, 700))
        let image = try #require(GlyphThumbnail.image(outline, advanceWidth: 500, ascender: 800, descender: -200, pixels: 100))
        #expect(image.width == 100 && image.height == 100)
        // The box fills from the baseline (20 px from the bottom) to 70% of the em above it.
        let data = try #require(image.dataProvider?.data as Data?)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { data[y * image.bytesPerRow + x * 4 + 3] }
        #expect(alpha(50, 50) == 255 && alpha(50, 5) == 0 && alpha(50, 95) == 0 && alpha(10, 50) == 0)
        #expect(GlyphThumbnail.image(outline, advanceWidth: 500, ascender: 0, descender: 0, pixels: 10) == nil)
        #expect(GlyphThumbnail.image(FilledPath(contours: [Self.box(0, -1, 1, 1)], fillRule: .evenOdd), advanceWidth: 1, ascender: 1, descender: 0,
                                     pixels: 4) != nil)
        #expect(GlyphThumbnail.CellSize.allCases.map(\.rawValue) == [40, 64, 96])
        let cache = GlyphThumbnailCache()
        let glyph = NodeID(counter: 1, replica: 1)
        let render = { GlyphThumbnail.image(outline, advanceWidth: 500, ascender: 800, descender: -200, pixels: 40) }
        #expect(cache.image(for: glyph, version: 1, pixels: 40, render: render) != nil)
        #expect(cache.image(for: glyph, version: 1, pixels: 40, render: { nil }) != nil)
        #expect(cache.renders == 1 && cache.count == 1)
        #expect(cache.image(for: glyph, version: 2, pixels: 40, render: render) != nil && cache.renders == 2)
        #expect(cache.image(for: NodeID(counter: 2, replica: 1), version: 1, pixels: 40, render: { nil }) == nil)
        cache.invalidate([glyph])
        #expect(cache.count == 0)
        _ = cache.image(for: glyph, version: 3, pixels: 40, render: render)
        cache.removeAll()
        #expect(cache.count == 0)
    }

    @Test func canvasDecorationLinesAndSnapTargets() {
        var frame = GlyphCanvasFrame(advanceWidth: 500, extraLines: [GlyphMetricLine(role: .extra, label: "Overshoot", y: 510),
                                                                    GlyphMetricLine(role: .extra, label: "Off", y: .nan)])
        #expect(GlyphCanvasRendering.lines(frame).map(\.label) == ["Descender", "Baseline", "x-height", "Overshoot", "Cap height", "Ascender"])
        #expect(GlyphCanvasRendering.lines(frame).map(\.canvasY) == [200, 0, -500, -510, -700, -800])
        #expect(GlyphCanvasRendering.items(frame).count == 1 + 6 + 2)
        #expect(GlyphCanvasRendering.snapGuides(frame).contains(.vertical(x: 500)) && GlyphCanvasRendering.snapGuides(frame).contains(.horizontal(y: -500)))
        if case .group(let group) = GlyphCanvasRendering.item(frame) { #expect(group.children.count == 9) } else { Issue.record("not a group") }
        #expect(frame.extent.minX == -1_000 && frame.extent.maxX == 1_500)
        // Italic: the bearing lines slant; hidden lines and the em box drop out.
        frame.italicAngle = -12
        frame.showEmBox = false
        frame.showXHeight = false
        frame.showCapHeight = false
        frame.showAscender = false
        frame.showDescender = false
        frame.showBaseline = false
        let slanted = GlyphCanvasRendering.snapGuides(frame)
        #expect(slanted.count == 3 && slanted.contains { if case .angled = $0 { true } else { false } })
        #expect(abs(GlyphCanvasRendering.slant(frame, at: -800) - 800 * tan(12 * Double.pi / 180)) < 1e-9)
        frame.showSideBearings = false
        #expect(GlyphCanvasRendering.items(frame).count == 1 && GlyphCanvasRendering.snapGuides(frame).count == 1)
    }
}
