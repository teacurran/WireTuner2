import WTGeometry
import CoreGraphics
import Testing
@testable import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// ATTR-007: dashes and arrowheads through GEO-003 outlines, in both renderers.
@Suite struct StrokeOutlineTests {
    static let line = DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 100, y: 0)], closed: false)

    func regions(_ stroke: StrokePaint, path: DisplayPath = line, hairline: Double = 1) -> [PaintedRegion] {
        StrokeExpansion.regions(for: stroke, path: path, hairlineWidth: hairline, tolerance: 1.0 / 64)
    }

    func shapes(_ regions: [PaintedRegion]) -> [DisplayPath] {
        regions.compactMap { region in
            if case .fill(let path, let rule, _) = region {
                #expect(rule == .nonZero)
                return path
            }
            return nil
        }
    }

    @Test func toleranceIsAPowerOfTwoFractionOfAPixel() {
        #expect(StrokeExpansion.tolerance(forScale: 1) == 1.0 / 256, "scales up to 4 share the 4× outline")
        #expect(StrokeExpansion.tolerance(forScale: 4) == 1.0 / 256)
        #expect(StrokeExpansion.tolerance(forScale: 1e-9) == 1.0 / 256)
        #expect(StrokeExpansion.tolerance(forScale: 6) == 1.0 / 512, "rounded down to a power of two")
        #expect(StrokeExpansion.tolerance(forScale: 0) == 1.0 / 256)
        #expect(StrokeExpansion.tolerance(forScale: .nan) == 1.0 / 256)
        #expect(StrokeExpansion.tolerance(forScale: 1e9) == pow(2, -14), "never finer than 1e-4, rounded down")
    }

    @Test func aBasicStrokeIsItsOutline() throws {
        let body = shapes(regions(StrokePaint(paint: .solid(red), style: StrokeStyle(width: 4))))
        #expect(body.count == 1)
        let bounds = try #require(body[0].controlBounds)
        #expect(approx(bounds, Rect(x: 0, y: -2, width: 100, height: 4), tolerance: 1e-6))
        let round = try #require(shapes(regions(StrokePaint(paint: .solid(red), style: StrokeStyle(width: 4, cap: .round)))).first?.controlBounds)
        #expect(approx(round.minX, -2, tolerance: 1e-3), "round caps reach half the width past the ends")
    }

    @Test func dashesAreLaidOutByArcLength() {
        let dashed = shapes(regions(StrokePaint(paint: .solid(red), style: StrokeStyle(width: 2, dash: [10, 10]))))
        #expect(dashed.count == 1)
        #expect(dashed[0].contours.count == 5, "100 pt of 10 on, 10 off")
        let phased = shapes(regions(StrokePaint(paint: .solid(red), style: StrokeStyle(width: 2, dash: [10, 10], dashPhase: 5))))
        #expect(phased[0].contours.count == 6, "a phase of 5 starts halfway through a dash")
        let dots = shapes(regions(StrokePaint(paint: .solid(red), style: StrokeStyle(width: 4, cap: .round, dash: [0, 20]))))
        #expect(dots[0].contours.count == 5, "zero-length dashes with round caps are dots")
    }

    @Test func headsSitOnTheTrimmedPathWithoutOverlap() throws {
        let short = DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 40, y: 0)], closed: false)
        let parts = shapes(regions(StrokePaint(paint: .solid(red), style: StrokeStyle(width: 4), startArrowhead: .triangle, endArrowhead: .triangle), path: short))
        #expect(parts.count == 3, "body and two heads")
        let body = try #require(parts[0].controlBounds)
        #expect(approx(body.minX, 6, tolerance: 1e-6) && approx(body.maxX, 34, tolerance: 1e-6), "trimmed 1.5 units × width 4 at each end")
        let start = try #require(parts[1].controlBounds)
        let end = try #require(parts[2].controlBounds)
        #expect(start.maxX <= body.minX + 1e-9 + 2, "the start head's base meets the trimmed start")
        #expect(approx(start.minX, -4, tolerance: 1e-9) && approx(end.maxX, 44, tolerance: 1e-9), "tips one unit past the ends")
    }

    @Test func aClosedPathIgnoresItsHeads() {
        let closed = DisplayPath(rect: Rect(x: 0, y: 0, width: 20, height: 20))
        let parts = shapes(regions(StrokePaint(paint: .solid(red), style: StrokeStyle(width: 2), startArrowhead: .triangle, endArrowhead: .open), path: closed))
        #expect(parts.count == 1)
    }

    @Test func openHeadsAreOutlinedAtTheStrokeWidthUndashed() throws {
        let parts = shapes(regions(StrokePaint(paint: .solid(red), style: StrokeStyle(width: 2, dash: [1, 1]), endArrowhead: .open)))
        #expect(parts.count == 2)
        let head = try #require(parts[1].contours.first)
        #expect(parts[1].contours.count == 1, "one undashed outline")
        #expect(head.isClosed)
    }

    @Test func hairlinesAreOutlinedAtTheDeviceWidth() throws {
        let hairline = try #require(shapes(regions(StrokePaint(paint: .solid(red), style: StrokeStyle(width: 0)), hairline: 0.25)).first?.controlBounds)
        #expect(approx(hairline.height, 0.25, tolerance: 1e-9))
        #expect(regions(StrokePaint(paint: .solid(red), style: StrokeStyle(width: 0)), hairline: 0).isEmpty, "a degenerate device width paints nothing")
        #expect(StrokeExpansion.outline([], style: StrokeStyle(width: 1), width: 1, tolerance: 0.01).isEmpty)
    }

    @Test func outlinesAreMemoized() {
        let stroke = StrokePaint(paint: .solid(red), style: StrokeStyle(width: 3, join: .round, dash: [4, 1]))
        let path = ReferenceCorpus.zigzag(x: 0, y: 0, width: 90, height: 30)
        let first = regions(stroke, path: path)
        let second = regions(stroke, path: path)
        #expect(first == second)
    }

    @Test func capsAndJoinsMapToGeometry() {
        #expect(LineCap.butt.geometry == .butt && LineCap.round.geometry == .round && LineCap.square.geometry == .square)
        #expect(LineJoin.miter.geometry == .miter && LineJoin.round.geometry == .round && LineJoin.bevel.geometry == .bevel)
    }

    @Test func bothRenderersFillTheSameOutlines() {
        // The Metal lowering of a headed, dashed stroke is fills only: body and heads.
        let item = DisplayItem.path(PathItem(path: ReferenceCorpus.zigzag(x: 10, y: 10, width: 100, height: 60), appearance: Appearance([
            .stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 3, dash: [6, 2]), startArrowhead: .circle, endArrowhead: .open)),
        ])))
        let builder = PaintListBuilder(viewMode: .preview, overprintPreview: false, tolerance: .standard, surface: Rect(x: 0, y: 0, width: 128, height: 96))
        let operations = builder.operations(for: DisplayList(canvas: "x", items: [item]), pasteboardTransform: .identity, cull: Rect(x: -100, y: -100, width: 400, height: 400))
        #expect(operations.count == 3)
        #expect(operations.allSatisfy { if case .fill(let fill) = $0 { return fill.rule == .nonZero } else { return false } })
    }

    @Test func decorationLinesAreQuadsAndOctagons() throws {
        let region = HairlineOutline.region(StrokeOutlineTests.line, width: 2, tolerance: 0.1)
        #expect(region.contours.count == 3, "two end octagons and one quad")
        let bounds = try #require(region.controlBounds)
        #expect(approx(bounds.minY, -1, tolerance: 1e-9) && bounds.minX < 0)
        #expect(HairlineOutline.region(StrokeOutlineTests.line, width: 0, tolerance: 0.1).isEmpty)
        #expect(HairlineOutline.region(DisplayPath(polygon: [Point(x: 1, y: 1), Point(x: 1, y: 1)], closed: false), width: 1, tolerance: 0.1).contours.count == 1, "a dot is one octagon")
    }

    /// Where GEO-003 cannot resolve an outline (`checkedStrokeOutline` throws), its best effort
    /// can lack the inner edge, and a FreeHand letter's open outline then filled the whole letter;
    /// the outline is Core Graphics' instead: a band along the path, the inside left unpainted.
    @Test func anUnresolvedOutlineFallsBackToCoreGraphicsStroker() throws {
        // A square drawn round to its start but not closed: the letter's case.
        let loop = DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 40, y: 0), Point(x: 40, y: 40), Point(x: 0, y: 40), Point(x: 0, y: 0)], closed: false)
        let failing: ([Contour], WTGeometry.StrokeStyle, Double) throws -> FilledPath = { _, _, _ in throw OffsetError.unresolvedOutline }
        for (cap, join) in [(LineCap.butt, LineJoin.miter), (.round, .round), (.square, .bevel)] {
            let style = StrokeStyle(width: 4, cap: cap, join: join)
            let outline = StrokeExpansion.outline(loop.contours, style: style, width: 4, tolerance: 1.0 / 64, stroke: failing)
            let region = FilledPath(contours: outline.contours, fillRule: .nonZero)
            #expect(region.contains(Point(x: 20, y: 0.5)) && region.contains(Point(x: 40, y: 20)), "the band along the path is painted")
            #expect(!region.contains(Point(x: 20, y: 20)), "the inside is not")
            #expect(!region.contains(Point(x: 20, y: 3)))
        }
        // Dashed, the fallback dashes first; a non-finite miter limit reads as 4.
        var dashed = StrokeStyle(width: 2, miterLimit: .nan)
        dashed.dash = [5, 5]
        let pieces = StrokeExpansion.outline(Self.line.contours, style: dashed, width: 2, tolerance: 1.0 / 64, stroke: failing)
        let band = FilledPath(contours: pieces.contours, fillRule: .nonZero)
        #expect(band.contains(Point(x: 2.5, y: 0)) && !band.contains(Point(x: 7.5, y: 0)) && band.contains(Point(x: 12.5, y: 0)))
        // A resolved outline is GEO-003's own, as before.
        let resolved = StrokeExpansion.outline(Self.line.contours, style: StrokeStyle(width: 2), width: 2, tolerance: 1.0 / 64)
        let geometry = Offset.strokeOutline(Self.line.contours, style: WTGeometry.StrokeStyle(width: 2, cap: .butt, join: .miter, miterLimit: 10, dash: [], dashPhase: 0), tolerance: 1.0 / 64)
        #expect(resolved == DisplayPath(contours: geometry.contours))
    }
}
