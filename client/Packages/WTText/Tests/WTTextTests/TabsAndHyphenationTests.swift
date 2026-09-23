import Testing
import WTGeometry
import WTRender
@testable import WTText

/// Tabs with leaders (tabs-indents) and hyphenation (paragraphs, "Hyphenation").
@Suite struct TabsAndHyphenationTests {
    /// The glyphs of the characters at `offsets`.
    func glyphs(_ layout: TextLayout, at offsets: Set<Int>) -> [LaidOutGlyph] {
        layout.glyphs().filter { offsets.contains($0.offset) }
    }

    @Test func tabKindsAlignAtTheirStops() {
        // left | right | centre | decimal
        let text = "L\tab\tRR\tcenter\t12.50"
        let tabs = [TabStop(.left, at: 40), TabStop(.right, at: 120), TabStop(.center, at: 170), TabStop(.decimal, at: 240)]
        let layout = Fixture.layout(text, style: ParagraphStyle(tabs: tabs), in: [Fixture.block(width: 300)])
        let all = layout.glyphs()
        let scalars = Array(text.unicodeScalars)
        func glyph(_ offset: Int) -> LaidOutGlyph { all.first { $0.offset == offset }! }
        #expect(approx(glyph(2).origin.x, 40, 0.01), "left tab: text starts at the stop")
        let rightEnd = glyph(6).origin.x + glyph(6).advance
        #expect(approx(rightEnd, 120, 0.05), "right tab: text ends at the stop")
        let centerStart = glyph(8).origin.x
        let centerEnd = glyph(13).origin.x + glyph(13).advance
        #expect(approx((centerStart + centerEnd) / 2, 170, 0.5), "center tab: centred on the stop")
        let point = scalars.firstIndex(of: ".")!
        #expect(approx(glyph(point).origin.x + glyph(point).advance / 2, 240, 0.5), "decimal tab: the separator on the stop")
        Goldens.check(layout, name: "tabs", size: Size(width: 300, height: 30))
    }

    @Test func leadersFillTheGapInThePrecedingFont() {
        let text = "Soup\t4.50\nSalad\t12.00"
        let style = ParagraphStyle(tabs: [TabStop(.right, at: 180, leader: ".")])
        let layout = Fixture.layout(text, style: style, in: [Fixture.block(width: 200)])
        // The dots are glyphs attributed to the tab character.
        let dots = glyphs(layout, at: [4])
        #expect(dots.count > 10)
        let dotXs = dots.map { $0.origin.x }
        #expect(dotXs == dotXs.sorted())
        for (lhs, rhs) in zip(dots, dots.dropFirst()) {
            #expect(approx(rhs.origin.x - lhs.origin.x, lhs.advance, 0.001), "one leader advance apart")
        }
        // Leaders sit on a grid from the column edge, so rows of leaders line up.
        let secondRow = glyphs(layout, at: [15])
        let advance = dots[0].advance
        for dot in dots + secondRow {
            let slot = dot.origin.x / advance
            #expect(approx(slot, slot.rounded(), 0.001))
        }
        // Wrapping tabs take no leader; a stop without a leader draws none.
        let wrapping = Fixture.layout("a\tb", style: ParagraphStyle(tabs: [TabStop(.wrapping, at: 100, leader: ".")]), in: [Fixture.block()])
        #expect(glyphs(wrapping, at: [1]).isEmpty)
        let plainAfterLeader = Fixture.layout("a\tb\tc", style: ParagraphStyle(tabs: [TabStop(.left, at: 60, leader: "-"), TabStop(.left, at: 120)]), in: [Fixture.block()])
        #expect(!glyphs(plainAfterLeader, at: [1]).isEmpty)
        #expect(glyphs(plainAfterLeader, at: [3]).isEmpty)
        // A leader character the font lacks, or a gap too small for one, draws nothing.
        let missing = Fixture.layout("a\tb", style: ParagraphStyle(tabs: [TabStop(.left, at: 60, leader: "\u{E000}")]), in: [Fixture.block()])
        #expect(glyphs(missing, at: [1]).isEmpty)
        let tiny = Fixture.layout("abc\tb", style: ParagraphStyle(tabs: [TabStop(.left, at: 20, leader: "_")]), in: [Fixture.block()])
        #expect(glyphs(tiny, at: [3]).isEmpty)
        Goldens.check(layout, name: "tabLeaders", size: Size(width: 200, height: 40))
    }

    @Test func defaultTabsEveryHalfInchAfterTheLastStop() {
        let layout = Fixture.layout("a\tb\tc", style: ParagraphStyle(tabs: [TabStop(.left, at: 50)]), in: [Fixture.block(width: 300)])
        let all = layout.glyphs()
        #expect(approx(all.first { $0.offset == 2 }!.origin.x, 50))
        #expect(approx(all.first { $0.offset == 4 }!.origin.x, 72), "the next default stop after 50 is 72")
        let plain = Fixture.layout("a\tb", in: [Fixture.block(width: 300)])
        #expect(approx(plain.glyphs().first { $0.offset == 2 }!.origin.x, 36))
    }

    @Test func tabsCountFromTheColumnEdgeWhateverTheIndent() {
        let layout = Fixture.layout("a\tb", style: ParagraphStyle(leftIndent: 20, tabs: [TabStop(.left, at: 60)]), in: [Fixture.block(width: 300)])
        #expect(approx(layout.glyphs().first { $0.offset == 2 }!.origin.x, 60))
    }

    @Test func justifiedLinesSpreadOnlyAfterTheLastTab() {
        let text = "Name\tthe rest of this line is long enough to wrap around"
        let layout = Fixture.layout(text, style: ParagraphStyle(alignment: .justified, tabs: [TabStop(.left, at: 50)]), in: [Fixture.block(width: 200)])
        #expect(approx(layout.glyphs().first { $0.offset == 5 }!.origin.x, 50, 0.01), "text after the tab still starts at the stop")
        #expect(approx(Fixture.lineExtents(layout, text: text)[0].end, 200, 0.6))
    }

    // MARK: Hyphenation

    let hyphenated = ParagraphStyle(hyphenation: Hyphenation(enabled: true, language: "en_US"))
    let longWords = "Internationalization and characterization are extraordinarily lengthy words indeed"

    @Test func hyphenationBreaksWordsWithAHyphenGlyph() {
        let plain = Fixture.layout(longWords, in: [Fixture.block(width: 110)])
        let layout = Fixture.layout(longWords, style: hyphenated, in: [Fixture.block(width: 110)])
        let scalars = Array(longWords.unicodeScalars)
        // Some line ends inside a word...
        let breaks = layout.lineRanges.dropLast().map(\.upperBound)
        let midWord = breaks.filter { scalars[$0 - 1].properties.isAlphabetic && scalars[$0].properties.isAlphabetic }
        #expect(!midWord.isEmpty)
        #expect(plain.lineRanges.dropLast().map(\.upperBound).allSatisfy { !scalars[$0 - 1].properties.isAlphabetic || !scalars[$0].properties.isAlphabetic })
        // ... and draws a hyphen glyph (attributed to the last character before the break).
        for end in midWord {
            let last = layout.glyphs().filter { $0.offset == end - 1 }
            #expect(last.count == 2, "the letter and the hyphen")
        }
        #expect(Fixture.lineExtents(layout, text: longWords).allSatisfy { $0.end <= 110.01 })
        // The caret at the break sits before the hyphen.
        let end = midWord[0]
        let caret = layout.caret(atOffset: end, upstream: true)!
        let hyphen = layout.glyphs().filter { $0.offset == end - 1 }.max { $0.origin.x < $1.origin.x }!
        #expect(approx(caret.baseline.x, hyphen.origin.x, 0.01))
        Goldens.check(layout, name: "hyphenation", size: Size(width: 130, height: 110))
    }

    @Test func hyphenationRespectsItsLimits() {
        let settings = { (hyphenation: Hyphenation) in ParagraphStyle(hyphenation: hyphenation) }
        func midWordBreaks(_ layout: TextLayout, _ text: String) -> Int {
            let scalars = Array(text.unicodeScalars)
            return layout.lineRanges.dropLast().map(\.upperBound).filter { scalars[$0 - 1].properties.isAlphabetic && scalars[$0].properties.isAlphabetic }.count
        }
        let text = "extraordinarily extraordinarily extraordinarily extraordinarily extraordinarily"
        let unlimited = Fixture.layout(text, style: settings(Hyphenation(enabled: true)), in: [Fixture.block(width: 100)])
        let limited = Fixture.layout(text, style: settings(Hyphenation(enabled: true, consecutive: 1)), in: [Fixture.block(width: 100)])
        #expect(midWordBreaks(unlimited, text) > midWordBreaks(limited, text))
        let limitedEnds = limited.lineRanges.dropLast().map(\.upperBound)
        let scalars = Array(text.unicodeScalars)
        let flags = limitedEnds.map { scalars[$0 - 1].properties.isAlphabetic && scalars[$0].properties.isAlphabetic }
        for (lhs, rhs) in zip(flags, flags.dropFirst()) {
            #expect(!(lhs && rhs), "never two hyphenated lines in a row")
        }

        let capitalized = "Extraordinarily Extraordinarily Extraordinarily"
        let skipping = Fixture.layout(capitalized, style: settings(Hyphenation(enabled: true, skipCapitalized: true)), in: [Fixture.block(width: 100)])
        #expect(midWordBreaks(skipping, capitalized) == 0)
        let notSkipping = Fixture.layout(capitalized, style: settings(Hyphenation(enabled: true)), in: [Fixture.block(width: 100)])
        #expect(midWordBreaks(notSkipping, capitalized) > 0)

        var inhibited = Fixture.body
        inhibited.noHyphen = true
        let content = TextContent(runs: [TextRun(text, attributes: inhibited)], paragraphs: [settings(Hyphenation(enabled: true))])
        #expect(midWordBreaks(TextLayoutEngine().layout(content, in: [Fixture.block(width: 100)]), text) == 0)

        // Short words and words that cannot fit a syllable are left alone.
        let short = "tiny word list with small bits"
        #expect(midWordBreaks(Fixture.layout(short, style: settings(Hyphenation(enabled: true)), in: [Fixture.block(width: 40)]), short) == 0)
    }

    @Test func discretionaryHyphensBreakWithHyphenationOff() {
        let text = "aaaa bbbbbbbb\u{00AD}cccccccc"
        let width = TextLayoutEngine().layout(TextContent("aaaa bbbbbbbb-", attributes: Fixture.body), in: [Fixture.block(width: 500)]).glyphs().last.map { $0.origin.x + $0.advance }!
        let layout = Fixture.layout(text, in: [Fixture.block(width: width + 1)])
        #expect(layout.lineRanges[0] == 0..<14)
        let lastGlyphs = layout.glyphs().filter { $0.offset == 13 }
        #expect(lastGlyphs.count == 1, "the soft hyphen draws as a hyphen at the break")
        let unbroken = Fixture.layout(text, in: [Fixture.block(width: 500)])
        #expect(unbroken.glyphs().filter { $0.offset == 13 }.isEmpty, "and as nothing inside a line")
    }

    @Test func aWordLongerThanTheLineHyphenatesOrBreaks() {
        let text = "Pneumonoultramicroscopicsilicovolcanoconiosis"
        let hyphen = Fixture.layout(text, style: hyphenated, in: [Fixture.block(width: 90)])
        #expect(hyphen.lineCount > 1)
        let plain = Fixture.layout(text, in: [Fixture.block(width: 90)])
        #expect(plain.lineCount > 1, "an emergency break inside the word")
    }
}
