import WTGeometry
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import WTRender

/// The renderer side of the type tasks: greeking by device pixel size, overprinting glyphs,
/// groups Keyline never draws, synthesized slants and the per-font outline tables.
@Suite struct TextRenderTests {
    static let viewport = Viewport(size: Size(width: 128, height: 96))

    func darkPixels(_ list: DisplayList, renderer: CoreGraphicsRenderer, scale: Double = 1) throws -> Int {
        let surface = try #require(renderer.renderBitmap(list, viewport: TextRenderTests.viewport, scale: scale).flatMap(BitmapSurface.init(drawing:)))
        var dark = 0
        for y in 0..<surface.height {
            for x in 0..<surface.width where surface.pixel(x: x, y: y).red < 200 {
                dark += 1
            }
        }
        return dark
    }

    @Test func typeSmallerThanTheThresholdGreeks() throws {
        let small = TextCorpus.text(ReferenceCorpus.makeGlyphRun("small", font: GlyphFont(postScriptName: "Helvetica", size: 6), at: Point(x: 10, y: 20)))
        guard case .text(let item) = small else {
            Issue.record("a text run")
            return
        }
        #expect(approx(item.pixelSize(under: .scale(2)), 12, tolerance: 1e-9))
        let placeholder = TextRunItem(text: "x", origin: .zero, bounds: Rect(x: 0, y: 0, width: 10, height: 5))
        #expect(approx(placeholder.pixelSize(under: .identity), 5), "a placeholder measures its bounds")
        var renderer = CoreGraphicsRenderer(background: .white)
        renderer.greekTypeBelow = 8
        let list = DisplayList(canvas: "t", items: [small])
        let greeked = try renderBitmapPixels(list, renderer: renderer, scale: 1)
        let full = try renderBitmapPixels(list, renderer: CoreGraphicsRenderer(background: .white), scale: 1)
        #expect(greeked != full)
        #expect(try renderBitmapPixels(list, renderer: renderer, scale: 2) == renderBitmapPixels(list, renderer: CoreGraphicsRenderer(background: .white), scale: 2), "12 device pixels: drawn in full")
        // PDF never greeks.
        #expect(renderer.renderPDF(list, viewport: TextRenderTests.viewport) != nil)
        // The Metal lowering greeks by the same rule.
        let builder = PaintListBuilder(viewMode: .preview, overprintPreview: false, tolerance: .standard, surface: Rect(x: 0, y: 0, width: 128, height: 96), greekTypeBelow: 8)
        let operations = builder.operations(for: list, pasteboardTransform: .identity, cull: Rect(x: 0, y: 0, width: 128, height: 96))
        #expect(operations.count == 1)
        guard case .fill(let bar) = operations.first else {
            Issue.record("a grey bar")
            return
        }
        #expect(approx(Double(bar.color.x), 0.7, tolerance: 0.01))
    }

    func renderBitmapPixels(_ list: DisplayList, renderer: CoreGraphicsRenderer, scale: Double) throws -> [UInt32] {
        let surface = try #require(renderer.renderBitmap(list, viewport: TextRenderTests.viewport, scale: scale).flatMap(BitmapSurface.init(drawing:)))
        return TileParity.words(of: surface)
    }

    @Test func overprintingGlyphsMultiplyUnderOverprintPreview() throws {
        let list = TextCorpus.overprint
        let plain = try renderBitmapPixels(list, renderer: CoreGraphicsRenderer(background: .white), scale: 1)
        let preview = try renderBitmapPixels(list, renderer: CoreGraphicsRenderer(background: .white, overprintPreview: true), scale: 1)
        #expect(plain != preview)
        let builder = PaintListBuilder(viewMode: .preview, overprintPreview: true, tolerance: .standard, surface: Rect(x: 0, y: 0, width: 128, height: 96))
        let operations = builder.operations(for: list, pasteboardTransform: .identity, cull: Rect(x: 0, y: 0, width: 128, height: 96))
        let blends = operations.compactMap { operation -> PaintBlend? in
            if case .fill(let fill) = operation { return fill.blend }
            return nil
        }
        #expect(blends == [.normal, .multiply, .normal])
    }

    @Test func keylineSkipsHiddenGroups() throws {
        let hidden = DisplayList(canvas: "t", items: [.group(GroupItem(children: [ReferenceCorpus.path(DisplayPath(rect: Rect(x: 10, y: 10, width: 50, height: 50)), [ReferenceCorpus.fill(.black)])], hiddenInKeyline: true))])
        #expect(try darkPixels(hidden, renderer: CoreGraphicsRenderer(background: .white)) > 2000)
        #expect(try darkPixels(hidden, renderer: CoreGraphicsRenderer(background: .white, viewMode: .keyline)) == 0)
        let builder = PaintListBuilder(viewMode: .keyline, overprintPreview: false, tolerance: .standard, surface: Rect(x: 0, y: 0, width: 128, height: 96))
        #expect(builder.operations(for: hidden, pasteboardTransform: .identity, cull: Rect(x: 0, y: 0, width: 128, height: 96)).isEmpty)
        #expect(GroupItem(children: []).hiddenInKeyline == false)
    }

    @Test func roundOutlinesCoverTheStrokeRegion() throws {
        // A closed square: the band reaches half the width out and in, rounded at the corners.
        let square = DisplayPath(rect: Rect(x: 10, y: 10, width: 40, height: 40))
        let band = RoundOutline.region(of: square, width: 10, tolerance: 0.01)
        let bounds = try #require(band.controlBounds)
        #expect(approx(bounds, Rect(x: 5, y: 5, width: 50, height: 50), tolerance: 1e-6))
        let filled = FilledPath(contours: band.contours)
        #expect(filled.contains(Point(x: 7, y: 30)) && filled.contains(Point(x: 13, y: 30)) && !filled.contains(Point(x: 30, y: 30)))
        #expect(!filled.contains(Point(x: 5.5, y: 5.5)), "the corner is round")
        // An open line gets round caps; a lone point a disc; no width, nothing.
        var line = DisplayPath()
        line.move(to: Point(x: 0, y: 0))
        line.addLine(to: Point(x: 20, y: 0))
        let capped = try #require(RoundOutline.region(of: line, width: 4, tolerance: 0.01).controlBounds)
        #expect(approx(capped.minX, -2, tolerance: 1e-6) && approx(capped.maxX, 22, tolerance: 1e-6))
        var dot = DisplayPath()
        dot.move(to: Point(x: 5, y: 5))
        dot.addLine(to: Point(x: 5, y: 5))
        let disc = try #require(RoundOutline.region(of: dot, width: 4, tolerance: 0.01).controlBounds)
        #expect(approx(disc.width, 4, tolerance: 1e-3))
        #expect(RoundOutline.region(of: line, width: 0, tolerance: 0.01).isEmpty)
        // Helvetica Bold's t at 5 pt, which GEO-003's stroker dropped before b867581, gets its
        // ring from the checked stroker.
        let t = ReferenceCorpus.makeGlyphRun("t", font: GlyphFont(postScriptName: "Helvetica-Bold", size: 24), at: .zero)
        let ring = try #require(t.roundOutline(width: 5).controlBounds)
        let ink = try #require(t.inkBounds)
        #expect(approx(ring.minX, ink.minX - 2.5, tolerance: 0.05) && approx(ring.maxY, ink.maxY + 2.5, tolerance: 0.1))
        #expect(t.roundOutline(width: 5) == t.roundOutline(width: 5), "cached per glyph")
        let items = t.roundOutlineItems(width: 5, paint: FillPaint(paint: .solid(.black)), transform: .translation(x: 3, y: 0))
        guard items.count == 1, case .path(let item) = items[0] else {
            Issue.record("one item per glyph")
            return
        }
        #expect(item.path == t.roundOutline(width: 5) && item.transform == .translation(x: 3, y: 0))
        let space = ReferenceCorpus.makeGlyphRun(" ", font: GlyphFont(postScriptName: "Helvetica-Bold", size: 24), at: .zero)
        #expect(space.roundOutline(width: 5).isEmpty)
    }

    @Test func glyphRingsUseTheCheckedStrokerWithRoundOutlineAsFallback() throws {
        let t = ReferenceCorpus.makeGlyphRun("t", font: GlyphFont(postScriptName: "Helvetica-Bold", size: 24), at: .zero)
        let outline = try #require(GlyphOutlines.shared.table(for: t.font).entry(t.glyphs[0].glyph).path)
        // The checked stroke outline: normalized, so its non-zero and even-odd fills agree.
        let stroked = GlyphOutlines.FontTable.strokeRegion(of: outline, width: 5, tolerance: 0.05)
        let expected = try Offset.checkedStrokeOutline(outline.contours, style: WTGeometry.StrokeStyle(width: 5, cap: .round, join: .round), tolerance: 0.05)
        #expect(stroked == DisplayPath(contours: expected.contours))
        #expect(stroked == t.roundOutline(width: 5, tolerance: 0.05))
        let ring = FilledPath(contours: stroked.contours)
        let inside = Point(x: try #require(t.inkBounds).minX - 1, y: try #require(t.inkBounds).midY)
        #expect(ring.contains(inside) == FilledPath(contours: stroked.contours, fillRule: .evenOdd).contains(inside))
        // A stroker that throws falls back to the RoundOutline region.
        struct Unresolved: Error {}
        let fallback = GlyphOutlines.FontTable.strokeRegion(of: outline, width: 5, tolerance: 0.05) { _, _, _ in throw Unresolved() }
        #expect(fallback == RoundOutline.region(of: outline, width: 5, tolerance: 0.05))
        // No width or tolerance: nothing, without calling the stroker.
        for (width, tolerance) in [(0.0, 0.05), (.infinity, 0.05), (5, 0)] {
            #expect(GlyphOutlines.FontTable.strokeRegion(of: outline, width: width, tolerance: tolerance) { _, _, _ in throw Unresolved() }.isEmpty)
        }
    }

    @Test func obliqueFontsSlantTheirOutlines() throws {
        let upright = GlyphFont(postScriptName: "Times-Roman", size: 30)
        let oblique = GlyphFont(postScriptName: "Times-Roman", size: 30, obliqueness: 0.25)
        #expect(upright != oblique)
        #expect(CTFontGetMatrix(oblique.ctFont).c == 0.25)
        #expect(GlyphFont(oblique.ctFont, obliqueness: 0.25).obliqueness == 0.25)
        let glyph = GlyphRunTests.glyph("I", in: upright)
        let straight = try #require(GlyphOutlines.shared.outline(of: glyph, in: upright)?.controlBounds)
        let slanted = try #require(GlyphOutlines.shared.outline(of: glyph, in: oblique)?.controlBounds)
        #expect(slanted.width > straight.width + 4, "the stem leans")
        // Outline tables are per font and remember glyphs without ink.
        let table = GlyphOutlines.shared.table(for: upright)
        #expect(GlyphOutlines.shared.table(for: upright) === table)
        let space = GlyphRunTests.glyph(" ", in: upright)
        #expect(table.entry(space).path == nil && table.entry(space).bounds == nil)
        // Transformed and translated glyphs measure and outline alike.
        let run = GlyphRun(font: upright, glyphs: [PositionedGlyph(glyph: glyph, position: Point(x: 5, y: 40)), PositionedGlyph(glyph: glyph, position: .zero, transform: .translation(x: 50, y: 40))])
        let ink = try #require(run.inkBounds)
        #expect(approx(ink.minX, 5 + straight.minX, tolerance: 1e-9) && approx(ink.maxX, 50 + straight.maxX, tolerance: 1e-9))
        #expect(run.outline.controlBounds == ink)
    }
}
