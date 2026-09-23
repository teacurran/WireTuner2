import WTGeometry
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import WTRender

@Suite struct GlyphRunTests {
    static let helvetica = GlyphFont(postScriptName: "Helvetica", size: 20)

    static func glyph(_ character: Character, in font: GlyphFont) -> CGGlyph {
        ReferenceCorpus.makeGlyphRun(String(character), font: font, at: .zero).glyphs[0].glyph
    }

    @Test func fontsRoundTripThroughCoreText() {
        let font = GlyphRunTests.helvetica
        #expect(font.description == "Helvetica 20.0pt")
        let ctFont = font.ctFont
        #expect(CTFontCopyPostScriptName(ctFont) as String == "Helvetica")
        #expect(font.ctFont === ctFont, "fonts are cached by value")
        let back = GlyphFont(ctFont)
        #expect(back.postScriptName == "Helvetica" && back.size == 20 && back.horizontalScale == 1)
    }

    /// TXT-002: a PostScript name that loads only Core Text's stand-in is not available, and
    /// activating fonts drops the cached fonts and outlines so names load afresh.
    @Test func availabilityAndCacheFlushAfterFontActivation() throws {
        let helvetica = GlyphFont(postScriptName: "Helvetica", size: 12)
        #expect(helvetica.isAvailable)
        #expect(!GlyphFont(postScriptName: "NoSuchFont-Regular", size: 12).isAvailable)
        let before = helvetica.ctFont
        let outline = GlyphOutlines.shared.table(for: helvetica)
        GlyphFont.fontsChanged()
        #expect(GlyphOutlines.shared.table(for: helvetica) !== outline, "outline tables are rebuilt")
        #expect(CTFontCopyPostScriptName(helvetica.ctFont) as String == CTFontCopyPostScriptName(before) as String)
    }

    @Test func variationsReachTheFont() throws {
        // Skia ships with macOS as a variable font with a weight axis.
        let weightTag: UInt32 = 0x7767_6874  // 'wght'
        let bold = GlyphFont(postScriptName: "Skia-Regular", size: 30, variations: [weightTag: 2.0])
        let regular = GlyphFont(postScriptName: "Skia-Regular", size: 30)
        let variation = CTFontCopyVariation(bold.ctFont) as? [NSNumber: NSNumber]
        #expect(variation?[NSNumber(value: weightTag)]?.doubleValue ?? 0 > 1.5)
        #expect(GlyphFont(bold.ctFont).variations[weightTag] ?? 0 > 1.5)
        let glyph = GlyphRunTests.glyph("H", in: regular)
        let heavy = try #require(GlyphOutlines.shared.outline(of: glyph, in: bold)?.controlBounds)
        let light = try #require(GlyphOutlines.shared.outline(of: glyph, in: regular)?.controlBounds)
        #expect(heavy != light)
    }

    @Test func outlinesAreYDownAndScaled() throws {
        let font = GlyphRunTests.helvetica
        let h = GlyphRunTests.glyph("H", in: font)
        let bounds = try #require(GlyphOutlines.shared.outline(of: h, in: font)?.controlBounds)
        #expect(bounds.maxY <= 0.01 && bounds.minY < -10, "caps sit above the baseline, which is y = 0, y down")
        let wide = GlyphFont(postScriptName: "Helvetica", size: 20, horizontalScale: 2)
        let wideBounds = try #require(GlyphOutlines.shared.outline(of: h, in: wide)?.controlBounds)
        #expect(abs(wideBounds.width - 2 * bounds.width) < 0.01)
        #expect(abs(wideBounds.height - bounds.height) < 0.01)
        let space = GlyphRunTests.glyph(" ", in: font)
        #expect(GlyphOutlines.shared.outline(of: space, in: font) == nil)
        #expect(GlyphOutlines.shared.outline(of: space, in: font) == nil, "a cached absence")
    }

    @Test func runsPlaceOutlinesAndMeasureInk() throws {
        let font = GlyphRunTests.helvetica
        let run = ReferenceCorpus.makeGlyphRun("Hi H", font: font, at: Point(x: 10, y: 50))
        #expect(run.glyphs.count == 4)
        let ink = try #require(run.inkBounds)
        #expect(ink.minX >= 10 && ink.maxY <= 50.01 && ink.minY < 40)
        #expect(!run.outline.isEmpty)
        let placed = PositionedGlyph(glyph: 1, position: Point(x: 3, y: 4))
        #expect(placed.placement == .translation(x: 3, y: 4))
        let rotated = PositionedGlyph(glyph: 1, position: .zero, transform: .scale(2))
        #expect(rotated.placement == .scale(2))

        let spaces = ReferenceCorpus.makeGlyphRun("  ", font: font, at: Point(x: 5, y: 6))
        #expect(spaces.inkBounds == nil)
        #expect(spaces.outline.isEmpty)
        let item = TextRunItem(text: "  ", glyphRun: spaces, origin: Point(x: 5, y: 6))
        #expect(item.bounds == Rect(x: 5, y: 6, width: 0, height: 0))
        #expect(item.glyphRun == spaces)
        #expect(TextRunItem(text: "x", origin: .zero, bounds: .zero).glyphRun == nil)
    }

    @Test func cgPathsConvertElementByElement() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 10, y: 0))
        path.addQuadCurve(to: CGPoint(x: 10, y: 10), control: CGPoint(x: 15, y: 5))
        path.addCurve(to: CGPoint(x: 0, y: 10), control1: CGPoint(x: 8, y: 12), control2: CGPoint(x: 2, y: 12))
        path.closeSubpath()
        let converted = DisplayPath(cgPath: path)
        #expect(converted.elements == [
            .move(to: Point(x: 0, y: 0)),
            .line(to: Point(x: 10, y: 0)),
            .quadCurve(control: Point(x: 15, y: 5), end: Point(x: 10, y: 10)),
            .cubicCurve(control1: Point(x: 8, y: 12), control2: Point(x: 2, y: 12), end: Point(x: 0, y: 10)),
            .close,
        ])
    }

    /// Dark pixels inside the text's bounds, none outside.
    @Test func bothModesDrawGlyphsAndSpacesDrawNothing() throws {
        let run = ReferenceCorpus.makeGlyphRun("Hg", font: GlyphRunTests.helvetica, at: Point(x: 10, y: 40))
        let blankRun = ReferenceCorpus.makeGlyphRun("   ", font: GlyphRunTests.helvetica, at: Point(x: 10, y: 80))
        let list = DisplayList(canvas: "t", items: [
            .text(TextRunItem(text: "Hg", glyphRun: run, origin: Point(x: 10, y: 40), color: .black)),
            .text(TextRunItem(text: "   ", glyphRun: blankRun, origin: Point(x: 10, y: 80), color: .black)),
        ])
        let viewport = Viewport(size: Size(width: 64, height: 96))
        for mode in [ViewMode.preview, .keyline] {
            let image = try #require(CoreGraphicsRenderer(background: .white, viewMode: mode).renderBitmap(list, viewport: viewport))
            let surface = try #require(BitmapSurface(drawing: image))
            var dark = 0
            for y in 0..<surface.height {
                for x in 0..<surface.width where surface.pixel(x: x, y: y).red < 128 {
                    dark += 1
                    #expect(y < 48, "nothing painted by the space run")
                }
            }
            #expect(dark > 40, "\(mode)")
        }
    }
}
