import CoreText
import Foundation
import Testing
import WTGeometry
import WTRender
@testable import WTText

/// TYPE-044's glyph outlines and TYPE-015's small caps size.
@Suite struct TextOutlineTests {
    func layout(_ runs: [TextRun], in containers: [TextContainer] = [Fixture.block(width: 400, height: 200)]) -> TextLayout {
        let content = TextContent(runs: runs, paragraphs: [ParagraphStyle](repeating: ParagraphStyle(), count: runs.map(\.text).joined().filter { $0 == "\n" }.count + 1))
        return TextLayoutEngine().layout(content, in: containers)
    }

    @Test func everyInkedGlyphHasAnOutlineAtItsCharacter() {
        var red = Fixture.body
        red.fill = Color(red: 1, green: 0, blue: 0)
        red.stroke = StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 1))
        red.overprint = true
        let laid = layout([TextRun("A b", attributes: Fixture.body), TextRun("C", attributes: red)],
                          in: [Fixture.block(width: 400, height: 200) { $0.transform = .translation(x: 100, y: 50) }])
        let outlines = laid.outlines(forContainer: 0, transform: .translation(x: 0, y: 10))
        // The space has no outline.
        #expect(outlines.glyphs.map(\.offset) == [0, 2, 3])
        #expect(outlines.glyphs[2].fill == Color(red: 1, green: 0, blue: 0) && outlines.glyphs[2].stroke != nil && outlines.glyphs[2].overprint)
        #expect(outlines.glyphs[0].fontName.hasPrefix("Helvetica"))
        // In pasteboard space: the container's transform and then the one given.
        let glyphs = laid.glyphs()
        let bounds = outlines.glyphs[0].path.controlBounds!
        #expect(bounds.minX >= 100 + glyphs[0].origin.x - 1 && bounds.minX < 100 + glyphs[0].origin.x + 2)
        #expect(bounds.maxY <= 50 + 10 + glyphs[0].origin.y + 0.5)
        #expect(outlines.under.isEmpty && outlines.over.isEmpty && outlines.inlines.isEmpty)
        #expect(laid.outlines(forContainer: 3).glyphs.isEmpty)
    }

    @Test func effectsBecomeShapesAndZoomIsDropped() {
        var underline = Fixture.body
        underline.effect = .underline(TextLineEffect(width: 1))
        var shadow = Fixture.body
        shadow.effect = .shadow(TextShadowEffect())
        var zoom = Fixture.body
        zoom.effect = .zoom(TextZoomEffect())
        var highlight = Fixture.body
        highlight.effect = .highlight(TextLineEffect(color: Color(red: 1, green: 1, blue: 0)))
        let laid = layout([TextRun("under ", attributes: underline), TextRun("shadow ", attributes: shadow), TextRun("zoom ", attributes: zoom),
                           TextRun("mark", attributes: highlight)])
        let outlines = laid.outlines(forContainer: 0)
        #expect(outlines.over.count == 1 && outlines.over[0].stroke?.style.width == 1)
        // The shadow (a fill per run) and the highlight under the glyphs; no zoom copies.
        #expect(outlines.under.contains { $0.fill != nil } && outlines.under.contains { $0.stroke != nil })
        #expect(outlines.under.count == 2)
    }

    @Test func inlineGraphicsArePlacedInPasteboardSpace() {
        var graphic = Fixture.body
        graphic.inlineGraphic = InlineGraphic(bounds: Rect(x: 0, y: 0, width: 10, height: 10), items: [])
        let laid = layout([TextRun("a", attributes: Fixture.body), TextRun("\u{FFFC}", attributes: graphic)],
                          in: [Fixture.block(width: 400, height: 200) { $0.transform = .translation(x: 7, y: 0) }])
        let outlines = laid.outlines(forContainer: 0)
        #expect(outlines.inlines.count == 1 && outlines.inlines[0].offset == 1)
        let local = laid.inlineGraphics()[0].transform
        #expect(abs(outlines.inlines[0].transform.tx - (local.tx + 7)) < 0.001)
    }

    @Test func smallCapsTakeTheDocumentsSize() {
        var caps = TextAttributes(fontFamily: "Helvetica", size: 20)
        let capitals = layout([TextRun("AB", attributes: caps)]).glyphs()
        caps.smallCaps = true
        caps.smallCapsSize = 0.5
        let half = layout([TextRun("Ab", attributes: caps)]).glyphs()
        #expect(abs(half[1].advance - capitals[1].advance * 0.5) < 0.01)
        // Out of range reads as the default.
        caps.smallCapsSize = 0
        let fallback = layout([TextRun("Ab", attributes: caps)]).glyphs()
        #expect(abs(fallback[1].advance - capitals[1].advance * TextAttributes.smallCapsScale) < 0.01)
        #expect(TextAttributes().smallCapsSize == TextAttributes.smallCapsScale)
    }
}
