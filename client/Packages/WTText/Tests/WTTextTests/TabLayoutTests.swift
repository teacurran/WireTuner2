import Foundation
import Testing
import WTGeometry
import WTRender
@testable import WTText

/// TYPE-025: wrapping tabs as rows of sub-columns, decimal tabs on the locale's separator,
/// default stops, leaders and the normalizations.
@Suite struct TabLayoutTests {
    /// Item | wrapping description | decimal price.
    static let tabs = [TabStop(.left, at: 60), TabStop(.wrapping, at: 70), TabStop(.left, at: 190), TabStop(.decimal, at: 250)]
    static let table = """
    Item\t\tDescription\t\tPrice
    Tea\t\tA smoky black tea from the hills, rolled by hand\t\t4.50
    Cake\t\tLemon\t\t12.25
    Soup\t\tOf the day, with bread\t\t9
    """

    func glyphs(_ layout: TextLayout, _ text: String, _ range: Range<Int>) -> [LaidOutGlyph] {
        layout.glyphs().filter { range.contains($0.offset) }
    }

    @Test func aTableWithLeftWrappingAndDecimalTabs() throws {
        let text = TabLayoutTests.table
        let layout = Fixture.layout(text, style: ParagraphStyle(spaceBelow: 4, tabs: TabLayoutTests.tabs), in: [Fixture.block(width: 300, height: 200)])
        let scalars = Array(text.unicodeScalars)
        let rows = layout.lineRanges
        #expect(rows.count == 4, "one row per paragraph however many sub-lines its cells take")
        // Row 2: the description wraps in its sub-column (70 to 190) and continues below the stop.
        let row = rows[1]
        let description = text.range(of: "A smoky")!
        let start = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: description.lowerBound)
        let end = start + "A smoky black tea from the hills, rolled by hand".unicodeScalars.count
        let wrapped = glyphs(layout, text, start..<end)
        let baselines = Set(wrapped.map { ($0.origin.y * 100).rounded() / 100 }).sorted()
        #expect(baselines.count == 3, "three sub-lines")
        #expect(zip(baselines, baselines.dropFirst()).allSatisfy { approx($1 - $0, 14.4, 0.01) }, "one leading apart")
        for baseline in baselines {
            let line = wrapped.filter { approx($0.origin.y, baseline, 0.01) }
            #expect(approx(line.map { $0.origin.x }.min()!, 70, 0.01), "each sub-line starts under the wrapping stop")
            #expect(line.allSatisfy { $0.origin.x + $0.advance <= 190.01 || scalars[$0.offset] == " " })
        }
        // The next column is intact: the price sits on the row's first line, decimal-aligned.
        let point = scalars[row].firstIndex(of: ".")!
        let price = layout.glyphs().first { $0.offset == point }!
        #expect(approx(price.origin.y, baselines[0], 0.01))
        #expect(approx(price.origin.x, 250, 0.3), "the separator's left edge on the stop")
        // A price without a separator right-aligns at the stop; the next row starts below the
        // wrapped description.
        let nine = layout.glyphs().first { $0.offset == scalars.count - 1 }!
        #expect(approx(nine.origin.x + nine.advance, 250, 0.3))
        #expect(layout.lineOrigins[2].y > baselines[2] + 14)
        Goldens.check(layout, name: "wrappingTable", size: Size(width: 300, height: 130))
    }

    @Test func rowsPlaceCaretsHitTestsAndSelectionsOnTheirSubLines() throws {
        let text = "Tea\t\tA smoky black tea from the hills\t\t4.50"
        let layout = Fixture.layout(text, style: ParagraphStyle(tabs: TabLayoutTests.tabs), in: [Fixture.block(width: 300, height: 200)])
        let hills = text.unicodeScalars.count - 7  // the "s" of "hills"
        let caret = try #require(layout.caret(atOffset: hills))
        #expect(caret.baseline.y > layout.lineOrigins[0].y + 10, "the caret is on the wrapped sub-line")
        #expect(layout.offset(at: Point(x: caret.baseline.x + 1, y: caret.baseline.y - 3), inContainer: 0) == hills)
        #expect(layout.offset(at: Point(x: 1, y: layout.lineOrigins[0].y - 3), inContainer: 0) == 0)
        let quads = layout.selection(from: 6, to: text.unicodeScalars.count)
        #expect(quads.count == 2, "one quad per sub-line the selection covers")
        #expect(Set(quads.map { $0.corners[0].y }).count == 2)
        // A mandatory break ends the row.
        let broken = Fixture.layout("a\tb c d e f\tz\u{2028}next", style: ParagraphStyle(tabs: [TabStop(.wrapping, at: 20), TabStop(.left, at: 40)]), in: [Fixture.block(width: 300)])
        #expect(broken.lineCount == 2)
        #expect(broken.caret(atOffset: 10)!.baseline.y > broken.lineOrigins[0].y + 10)
        #expect(approx(broken.caret(atOffset: 14)!.baseline.x, 0, 0.01), "the next line starts at the column edge")
    }

    @Test func rowCornerCases() {
        let wrap = [TabStop(.wrapping, at: 50)]
        // An empty wrapping cell, a line without tabs, a first cell too wide for the line.
        let empty = Fixture.layout("a\t", style: ParagraphStyle(tabs: wrap), in: [Fixture.block(width: 200)])
        #expect(empty.lineCount == 1 && empty.glyphs().count == 1)
        let plain = Fixture.layout("no tabs here", style: ParagraphStyle(tabs: wrap), in: [Fixture.block(width: 200)])
        #expect(plain.lineCount == 1)
        let wide = Fixture.layout(String(repeating: "x", count: 60) + "\tb", style: ParagraphStyle(tabs: wrap), in: [Fixture.block(width: 100)])
        #expect(wide.lineCount > 1, "not a row: Core Text breaks it")
        // Tabs that never reach the wrapping stop leave Core Text in charge.
        let before = Fixture.layout("ab\tcd", style: ParagraphStyle(tabs: [TabStop(.left, at: 30), TabStop(.wrapping, at: 150)]), in: [Fixture.block(width: 200)])
        #expect(approx(before.glyphs()[2].origin.x, 30, 0.01))
        // After the stops, default stops every half inch; right and centre stops align; leaders fill.
        let stops = [TabStop(.wrapping, at: 20), TabStop(.right, at: 120, leader: "."), TabStop(.center, at: 160)]
        let mixed = Fixture.layout("a\tbb\tcc\tdd\te", style: ParagraphStyle(tabs: stops), in: [Fixture.block(width: 300)])
        let all = mixed.glyphs()
        let c = all.filter { $0.offset == 5 || $0.offset == 6 }
        #expect(approx(c.last!.origin.x + c.last!.advance, 120, 0.05), "right stop")
        #expect(all.contains { $0.offset == 4 }, "a leader before the right stop")
        let d = all.filter { $0.offset == 8 || $0.offset == 9 }
        #expect(approx((d.first!.origin.x + d.last!.origin.x + d.last!.advance) / 2, 160, 0.5), "centre stop")
        let e = all.first { $0.offset == 11 }!
        #expect(approx(e.origin.x, 180, 0.01), "the next default stop past the last set one")
        // A stop past the column is ignored; with no default stop left the text follows on.
        let crowded = Fixture.layout("a\tb\tc", style: ParagraphStyle(tabs: [TabStop(.wrapping, at: 10), TabStop(.left, at: 500)]), in: [Fixture.block(width: 60)])
        #expect(crowded.lineCount == 1)
        #expect(TypesetParagraph(key: TextContent("x").splitParagraphs()[0].key).defaultStop(after: 50, stops: [], right: 60).position == 50)
    }

    @Test func decimalTabsAlignOnTheLocaleSeparator() {
        let tabs = [TabStop(.decimal, at: 100)]
        let german = Hyphenation(language: "de_DE")
        let comma = Fixture.layout("x\t12,50", style: ParagraphStyle(tabs: tabs, hyphenation: german), in: [Fixture.block()])
        let glyph = comma.glyphs().first { $0.offset == 4 }!
        #expect(abs(glyph.origin.x + glyph.advance / 2 - 100) < 2, "the comma is the separator in German")
        // In a row, too.
        let row = Fixture.layout("x\ty\t12,50", style: ParagraphStyle(tabs: [TabStop(.wrapping, at: 20), TabStop(.decimal, at: 100)], hyphenation: german), in: [Fixture.block()])
        let rowComma = row.glyphs().first { $0.offset == 6 }!
        #expect(approx(rowComma.origin.x, 100, 0.3))
    }

    @Test func normalizationsSortAndClampStops() {
        let style = ParagraphStyle(tabs: [TabStop(.left, at: 80), TabStop(.wrapping, at: 40, leader: "."), TabStop(.right, at: -10), TabStop(.center, at: 40)])
        let sorted = style.sortedTabs
        #expect(sorted.map(\.position) == [0, 40, 40, 80])
        #expect(sorted.map(\.kind) == [.right, .wrapping, .center, .left], "equal positions keep their order")
        #expect(sorted[1].leader.isEmpty, "a leader on a wrapping tab is ignored")
        // Vertical text ignores tab stops.
        var block = TextBlock(width: 100, height: 200)
        block.direction = .vertical
        let vertical = Fixture.layout("a\tb", style: ParagraphStyle(tabs: [TabStop(.left, at: 90)]), in: [.block(block)])
        let horizontal = Fixture.layout("a\tb", style: ParagraphStyle(tabs: [TabStop(.left, at: 90)]), in: [Fixture.block()])
        #expect(approx(horizontal.glyphs()[1].origin.x, 90, 0.01))
        #expect(vertical.glyphs()[1].origin.y < 50, "the default half-inch stop instead")
    }

    @Test func aThousandRowTableRelaysOutQuickly() {
        let engine = TextLayoutEngine()
        func table(editing index: Int?) -> TextContent {
            let rows = (0..<1000).map { number in
                "Item \(number)\t\t" + (number == index ? "Edited: a" : "A") + " description long enough to wrap in its column\t\t\(number).\(number % 100)"
            }
            return TextContent(rows.joined(separator: "\n"), attributes: Fixture.body, style: ParagraphStyle(tabs: TabLayoutTests.tabs))
        }
        let chain: [TextContainer] = [.block(TextBlock(width: 300, height: 10, autoHeight: true))]
        _ = engine.layout(table(editing: nil), in: chain)
        let start = Date()
        let layout = engine.layout(table(editing: 500), in: chain)
        let elapsed = Date().timeIntervalSince(start)
        #expect(layout.lineCount == 1000, "\(layout.lineCount) lines")
        #expect(!layout.overflows)
        #if !DEBUG
        #expect(elapsed < 0.05, "1,000-row relayout took \(elapsed * 1000) ms")
        #endif
        print(String(format: "PERF WTText 1,000-row tabbed table: relayout %.1f ms", elapsed * 1000))
    }
}
