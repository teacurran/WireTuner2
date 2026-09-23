import Foundation
import Testing
import WTGeometry
import WTRender
import struct WTRender.StrokeStyle
@testable import WTText

/// TYPE-039: text flowing around objects in front of it, at their standoff.
@Suite struct TextWrapTests {
    /// A pull-quote block's outline (its rectangle: inset and stroke included), in its own space.
    static let quote = Contour(polygon: [Point(x: 0, y: 0), Point(x: 90, y: 0), Point(x: 90, y: 60), Point(x: 0, y: 60)], closed: true)
    static let body = String(repeating: Fixture.lorem + " ", count: 3)

    func layout(_ exclusions: [TextExclusion], text: String = TextWrapTests.body, width: Double = 300, engine: TextLayoutEngine = TextLayoutEngine()) -> TextLayout {
        engine.layout(TextContent(text, attributes: Fixture.body), in: [.block(TextBlock(width: width, height: 400, exclusions: exclusions))])
    }

    /// Every laid-out glyph's advance box that isn't a space.
    func inkBoxes(_ layout: TextLayout, text: String) -> [Rect] {
        let scalars = Array(text.unicodeScalars)
        return layout.glyphs().filter { !scalars[$0.offset].properties.isWhitespace }.map { glyph in
            Rect(x: glyph.origin.x, y: glyph.origin.y - 9, width: glyph.advance, height: 11)
        }
    }

    @Test func aPullQuoteWrapsBodyTextAtTheStandoff() throws {
        // The quote sits in the middle of the column, 8 pt of standoff around it.
        let exclusion = TextExclusion(contours: [TextWrapTests.quote], transform: .translation(x: 100, y: 80), standoff: 8)
        let wrapped = layout([exclusion])
        // Every glyph's box stays the standoff away from the quote (round at its corners).
        let quote = Rect(x: 100, y: 80, width: 90, height: 60)
        for box in inkBoxes(wrapped, text: TextWrapTests.body) {
            let dx = max(0, quote.minX - box.maxX, box.minX - quote.maxX)
            let dy = max(0, quote.minY - box.maxY, box.minY - quote.maxY)
            #expect((dx * dx + dy * dy).squareRoot() >= 7.9, "\(box) inside the standoff")
        }
        // Lines beside the quote are split into the spans left and right of it.
        let beside = wrapped.lines.filter { $0.origin.y > 80 && $0.origin.y < 140 }
        #expect(beside.contains { approx($0.origin.x, 0) } && beside.contains { approx($0.origin.x, 198, 0.01) })
        #expect(beside.filter { approx($0.origin.x, 0) }.allSatisfy { $0.cell.maxX <= 92.01 })
        #expect(!wrapped.overflows)
        let quoteItem = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 100, y: 80, width: 90, height: 60)), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(white: 0.9)))), .stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 1)))])))
        Goldens.checkGlyphs(wrapped, name: "pullQuote")
        let image = try #require(Goldens.render(wrapped, size: Size(width: 300, height: 260), extra: [quoteItem]))
        Goldens.checkImage(image, name: "pullQuote")
    }

    @Test func exclusionsWithCurvesTransformsAndNegativeStandoff() {
        let circle = Contour(polygon: (0..<32).map { index in
            let angle = Double(index) / 32 * 2 * .pi
            return Point(x: 30 * cos(angle), y: 30 * sin(angle))
        }, closed: true)
        // A rotated and scaled circle (a similarity): offset in its own space.
        let similar = TextExclusion(contours: [circle], transform: AffineTransform.scale(2).concatenating(.translation(x: 150, y: 100)), standoff: 6)
        let region = ExclusionRegion(similar)
        #expect(approx(region.bounds.width, 2 * (60 + 6), 0.5), "the standoff is in block points")
        // A skew is no similarity: offset after placing.
        let skewed = TextExclusion(contours: [circle], transform: AffineTransform(a: 1, b: 0, c: 0.5, d: 1, tx: 150, ty: 100), standoff: 6)
        #expect(ExclusionRegion(skewed).bounds.height > 70)
        let mirrored = TextExclusion(contours: [circle], transform: AffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 150, ty: 100), standoff: 6)
        #expect(approx(ExclusionRegion(mirrored).bounds.width, 72, 0.5))
        // A negative standoff lets text under the edge; collapsing the shape leaves nothing.
        let under = ExclusionRegion(TextExclusion(contours: [circle], standoff: -10))
        #expect(approx(under.bounds.width, 40, 0.5))
        let gone = ExclusionRegion(TextExclusion(contours: [circle], standoff: -40))
        #expect(gone.isEmpty)
        let wrapped = layout([similar, TextExclusion(contours: [circle], standoff: -40)])
        #expect(!wrapped.overflows)
        // Text flows on both sides of the circle.
        let aside = wrapped.lines.filter { $0.origin.y > 60 && $0.origin.y < 140 }
        #expect(aside.contains { $0.origin.x > 200 })
        // An exclusion off the block changes nothing.
        let away = layout([TextExclusion(contours: [circle], transform: .translation(x: 1000, y: 1000))])
        #expect(away.lineRanges == layout([]).lineRanges)
    }

    @Test func bandsTooNarrowForAWordArePassedOver() {
        // A bar across the column but for a sliver: lines pass beneath it.
        let bar = Contour(polygon: [Point(x: 10, y: 0), Point(x: 300, y: 0), Point(x: 300, y: 40), Point(x: 10, y: 40)], closed: true)
        let wrapped = layout([TextExclusion(contours: [bar])], text: "Words below the bar")
        #expect(wrapped.lineOrigins.first!.y > 40)
        // The same bar covering everything: nothing fits and the text overflows.
        let wall = Contour(polygon: [Point(x: -5, y: -5), Point(x: 400, y: -5), Point(x: 400, y: 500), Point(x: -5, y: 500)], closed: true)
        let blocked = layout([TextExclusion(contours: [wall])], text: "Nowhere")
        #expect(blocked.overflows && blocked.lineCount == 0)
        // Paragraphs keep their spacing and cell breaks end the cell while wrapping.
        let spaced = TextContent(runs: [TextRun("One\nTwo\u{000C}Three", attributes: Fixture.body)], paragraphs: [ParagraphStyle(spaceBelow: 10), ParagraphStyle(), ParagraphStyle()])
        let square = Contour(polygon: [Point(x: 0, y: 0), Point(x: 30, y: 0), Point(x: 30, y: 20), Point(x: 0, y: 20)], closed: true)
        var block = TextBlock(width: 300, height: 100, exclusions: [TextExclusion(contours: [square], transform: .translation(x: 110, y: 5))])
        block.columns = ColumnsRows(columns: 2, columnSpacing: 10)
        let columns = TextLayoutEngine().layout(spaced, in: [.block(block)])
        #expect(approx(columns.lineOrigins[1].y - columns.lineOrigins[0].y, 24.4, 0.01))
        #expect(columns.lineOrigins[2].x > 150, "the cell break moved on to the next column")
        // Vertical blocks ignore exclusions.
        var vertical = TextBlock(width: 100, height: 100, direction: .vertical, exclusions: [TextExclusion(contours: [wall])])
        vertical.direction = .vertical
        #expect(TextLayoutEngine().layout(TextContent("a"), in: [.block(vertical)]).lineCount == 1)
    }

    @Test func freeSpansSubtractTheBlockedIntervals() {
        let region = ExclusionRegion(TextExclusion(contours: [Contour(polygon: [Point(x: 40, y: 0), Point(x: 60, y: 0), Point(x: 60, y: 10), Point(x: 40, y: 10)], closed: true)]))
        #expect(region.blocked(top: 20, bottom: 30).isEmpty)
        let spans = ExclusionRegion.freeSpans(in: 0...100, top: 2, bottom: 8, exclusions: [region], minimum: 5)
        #expect(spans == [0...40, 60...100])
        #expect(ExclusionRegion.freeSpans(in: 0...100, top: 2, bottom: 8, exclusions: [region], minimum: 50).isEmpty)
        let wide = ExclusionRegion(TextExclusion(contours: [Contour(polygon: [Point(x: -10, y: 0), Point(x: 200, y: 0), Point(x: 200, y: 10), Point(x: -10, y: 10)], closed: true)]))
        #expect(ExclusionRegion.freeSpans(in: 0...100, top: 2, bottom: 8, exclusions: [wide, region], minimum: 1).isEmpty)
        // A shape wholly inside the band blocks its edges' reach.
        let dot = ExclusionRegion(TextExclusion(contours: [Contour(polygon: [Point(x: 50, y: 4), Point(x: 52, y: 4), Point(x: 52, y: 5), Point(x: 50, y: 5)], closed: true)]))
        #expect(ExclusionRegion.freeSpans(in: 0...100, top: 0, bottom: 10, exclusions: [dot], minimum: 1) == [0...50, 52...100])
    }

    @Test func unmovedExclusionsAreReused() {
        let engine = TextLayoutEngine()
        let exclusion = TextExclusion(contours: [TextWrapTests.quote], transform: .translation(x: 100, y: 80), standoff: 8)
        let first = layout([exclusion], engine: engine)
        let second = layout([exclusion], engine: engine)
        #expect(first.lineRanges == second.lineRanges)
        // A line that does not fit below the band where a span was found ends the cell.
        let tall = TextContent(runs: [TextRun("small ", attributes: Fixture.body), TextRun("TALL", attributes: TextAttributes(fontFamily: "Helvetica", size: 60))])
        let short = TextLayoutEngine().layout(tall, in: [.block(TextBlock(width: 300, height: 30, exclusions: [TextExclusion(contours: [TextWrapTests.quote], transform: .translation(x: 100, y: 0))]))])
        #expect(short.overflows)
    }

    @Test func movingTheObjectRelaysOutQuickly() {
        let engine = TextLayoutEngine()
        let page = String(repeating: Fixture.lorem + "\n", count: 12)
        _ = layout([TextExclusion(contours: [TextWrapTests.quote], transform: .translation(x: 100, y: 80), standoff: 8)], text: page, engine: engine)
        var worst = 0.0
        for step in 1...5 {
            let start = Date()
            let moved = layout([TextExclusion(contours: [TextWrapTests.quote], transform: .translation(x: 100 + Double(step) * 7, y: 80 + Double(step) * 11), standoff: 8)], text: page, engine: engine)
            worst = max(worst, Date().timeIntervalSince(start))
            #expect(moved.lineCount > 30)
        }
        #if !DEBUG
        #expect(worst < 0.016, "re-wrapping a page took \(worst * 1000) ms")
        #endif
        print(String(format: "PERF WTText re-wrap a page around a moved object: worst %.1f ms", worst * 1000))
    }
}
