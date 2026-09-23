import Testing
import WTGeometry
import WTRender
@testable import WTText

/// Alignment, justification, indents and spacing (paragraphs, tabs-indents,
/// type-specifications).
@Suite struct ParagraphLayoutTests {
    let width = 200.0

    @Test func leftAlignedTextWrapsWithinTheBlock() {
        let layout = Fixture.layout(Fixture.lorem, in: [Fixture.block(width: width)])
        #expect(layout.lineCount > 3)
        #expect(!layout.overflows)
        let extents = Fixture.lineExtents(layout, text: Fixture.lorem)
        #expect(extents.allSatisfy { approx($0.start, 0, 1.5) && $0.end <= width + 0.01 })
        let ranges = layout.lineRanges
        #expect(ranges.first?.lowerBound == 0 && ranges.last?.upperBound == Fixture.lorem.unicodeScalars.count)
        for (lhs, rhs) in zip(ranges, ranges.dropFirst()) {
            #expect(lhs.upperBound == rhs.lowerBound)
        }
        // Baselines one auto leading (120% of 12 pt) apart.
        let origins = layout.lineOrigins
        for (lhs, rhs) in zip(origins, origins.dropFirst()) {
            #expect(approx(rhs.y - lhs.y, 14.4))
        }
        Goldens.check(layout, name: "alignLeft", size: Size(width: 220, height: 120))
    }

    @Test func centerAndRightAlign() {
        let center = Fixture.layout(Fixture.lorem, style: ParagraphStyle(alignment: .center), in: [Fixture.block(width: width)])
        for extent in Fixture.lineExtents(center, text: Fixture.lorem) {
            #expect(approx(extent.start, width - extent.end, 1.5), "centred: equal margins")
        }
        let right = Fixture.layout(Fixture.lorem, style: ParagraphStyle(alignment: .right), in: [Fixture.block(width: width)])
        for extent in Fixture.lineExtents(right, text: Fixture.lorem) {
            #expect(approx(extent.end, width, 1.0), "flush right")
        }
        Goldens.check(center, name: "alignCenter", size: Size(width: 220, height: 120))
        Goldens.check(right, name: "alignRight", size: Size(width: 220, height: 120))
    }

    @Test func justifiedLinesFillTheMeasureAndTheLastLineFollowsTheFlushZone() {
        let text = Fixture.lorem
        let justified = Fixture.layout(text, style: ParagraphStyle(alignment: .justified), in: [Fixture.block(width: width)])
        let extents = Fixture.lineExtents(justified, text: text)
        for extent in extents.dropLast() {
            #expect(approx(extent.end, width, 0.6), "justified line ends at the right edge: \(extent)")
        }
        #expect(extents.last!.end < width - 20, "the short last line stays left (flush zone 100)")
        Goldens.check(justified, name: "alignJustified", size: Size(width: 220, height: 120))

        // A flush zone the last line reaches justifies it too; 0 never does.
        let lastLineLength = extents.last!.end
        let zone = lastLineLength / width * 100 - 1
        let flushed = Fixture.layout(text, style: ParagraphStyle(alignment: .justified, flushZone: zone), in: [Fixture.block(width: width)])
        #expect(approx(Fixture.lineExtents(flushed, text: text).last!.end, width, 0.6))
        let never = Fixture.layout("aa bb", style: ParagraphStyle(alignment: .justified, flushZone: 0), in: [Fixture.block(width: width)])
        #expect(Fixture.lineExtents(never, text: "aa bb")[0].end < 50)
    }

    @Test func justificationSpendsLetterSpacingThenBeyondWhenWordsRunOut() {
        // One long word per line: no spaces to stretch, so letters take the slack.
        let text = "Incomprehensibilities antidisestablishment"
        let style = ParagraphStyle(alignment: .justified, letterSpacing: SpacingRange(min: 0, optimum: 0, max: 50))
        let layout = Fixture.layout(text, style: style, in: [Fixture.block(width: 150)])
        let extents = Fixture.lineExtents(layout, text: text)
        #expect(approx(extents[0].end, 150, 0.6))
        // With no letter room either, spaces take everything beyond their maximum.
        let words = "a b c d e f g h i j k l m n o p q r s t u v w x y z a b c d e f"
        let tight = ParagraphStyle(alignment: .justified, wordSpacing: SpacingRange(min: 100, optimum: 100, max: 100), letterSpacing: SpacingRange(min: 0, optimum: 0, max: 0))
        let spread = Fixture.layout(words, style: tight, in: [Fixture.block(width: 100)])
        let spreadExtents = Fixture.lineExtents(spread, text: words)
        #expect(approx(spreadExtents[0].end, 100, 0.6))
        // No spaces and no letter room: letters still absorb the rest.
        let lone = Fixture.layout("Incomprehensibilities xx", style: tight, in: [Fixture.block(width: 124)])
        #expect(lone.lineCount == 2)
        #expect(approx(Fixture.lineExtents(lone, text: "Incomprehensibilities xx")[0].end, 124, 0.6))
    }

    @Test func indentsAndHangingIndent() {
        let style = ParagraphStyle(leftIndent: 20, rightIndent: 30, firstLineIndent: -15)
        let layout = Fixture.layout(Fixture.lorem, style: style, in: [Fixture.block(width: width)])
        let extents = Fixture.lineExtents(layout, text: Fixture.lorem)
        #expect(approx(extents[0].start, 5, 1.5), "first line: left + first-line indent")
        for extent in extents.dropFirst() {
            #expect(approx(extent.start, 20, 1.5))
            #expect(extent.end <= width - 30 + 0.01)
        }
        Goldens.check(layout, name: "indents", size: Size(width: 220, height: 140))
    }

    @Test func raggedWidthBreaksShort() {
        let full = Fixture.layout(Fixture.lorem, in: [Fixture.block(width: width)])
        let ragged = Fixture.layout(Fixture.lorem, style: ParagraphStyle(raggedWidth: 70), in: [Fixture.block(width: width)])
        #expect(Fixture.lineExtents(ragged, text: Fixture.lorem).allSatisfy { $0.end <= width * 0.7 + 0.01 })
        #expect(ragged.lineCount > full.lineCount)
    }

    @Test func hangingPunctuationSitsOutsideTheIndents() {
        let text = "\u{201C}Quoted text that runs long enough to wrap onto more lines, ending with a dash \u{2014}"
        let plain = Fixture.layout(text, style: ParagraphStyle(alignment: .right), in: [Fixture.block(width: 150)])
        let hung = Fixture.layout(text, style: ParagraphStyle(alignment: .right, hangPunctuation: true), in: [Fixture.block(width: 150)])
        let left = Fixture.layout(text, style: ParagraphStyle(hangPunctuation: true), in: [Fixture.block(width: 150)])
        #expect(Fixture.lineExtents(left, text: text)[0].start < -2, "the opening quote hangs left of the edge")
        let plainEnd = Fixture.lineExtents(plain, text: text).last!.end
        let hungEnd = Fixture.lineExtents(hung, text: text).last!.end
        #expect(hungEnd > plainEnd + 2, "the closing dash hangs right of the edge")
    }

    @Test func wordAndLetterSpacingOptimaAndKerning() {
        let text = "ab cd ef"
        let base = Fixture.layout(text, in: [Fixture.block(width: width)])
        let wide = Fixture.layout(text, style: ParagraphStyle(wordSpacing: SpacingRange(min: 200, optimum: 200, max: 200)), in: [Fixture.block(width: width)])
        let tracked = Fixture.layout(text, style: ParagraphStyle(letterSpacing: SpacingRange(min: 10, optimum: 10, max: 10)), in: [Fixture.block(width: width)])
        var kerned = Fixture.body
        kerned.kerning = 20
        kerned.rangeKerning = 10
        let kernedLayout = Fixture.layout(text, attributes: kerned, in: [Fixture.block(width: width)])
        let baseEnd = Fixture.lineExtents(base, text: text)[0].end
        #expect(Fixture.lineExtents(wide, text: text)[0].end > baseEnd + 5)
        #expect(Fixture.lineExtents(tracked, text: text)[0].end > baseEnd + 5)
        #expect(approx(Fixture.lineExtents(kernedLayout, text: text)[0].end - baseEnd, 8 * 12 * 0.3, 0.5), "30% of an em after each of the eight characters")
    }

    @Test func baselineShiftScaleAndSizeFeedTheLine() {
        var raised = Fixture.body
        raised.baselineShift = 4
        var wide = Fixture.body
        wide.horizontalScale = 200
        var big = Fixture.body
        big.size = 24
        let content = TextContent(runs: [TextRun("base ", attributes: Fixture.body), TextRun("up ", attributes: raised), TextRun("wide ", attributes: wide), TextRun("big", attributes: big)])
        let layout = TextLayoutEngine().layout(content, in: [Fixture.block(width: 300)])
        let glyphs = layout.glyphs()
        let baseline = glyphs[0].origin.y
        #expect(approx(glyphs[5].origin.y, baseline - 4), "raised 4 pt")
        let normalW = TextLayoutEngine().layout(TextContent("w", attributes: Fixture.body), in: [Fixture.block(width: 300)]).glyphs()[0].advance
        #expect(approx(glyphs[8].advance, normalW * 2, 0.01), "twice as wide")
        #expect(approx(layout.lineOrigins[0].y, baseline))
        // The line's leading is its largest: 120% of 24 pt; its first baseline its largest ascent.
        let two = TextLayoutEngine().layout(TextContent(runs: [TextRun("a ", attributes: Fixture.body), TextRun("B\nc", attributes: big)]), in: [Fixture.block(width: 300)])
        #expect(approx(two.lineOrigins[1].y - two.lineOrigins[0].y, 28.8))
        #expect(two.lineOrigins[0].y > 18)
        Goldens.check(layout, name: "characterAttributes", size: Size(width: 300, height: 40))
    }

    @Test func leadingModes() {
        func gap(_ leading: Leading) -> Double {
            var attributes = Fixture.body
            attributes.leading = leading
            let layout = Fixture.layout("one\ntwo", attributes: attributes, in: [Fixture.block()])
            return layout.lineOrigins[1].y - layout.lineOrigins[0].y
        }
        #expect(approx(gap(.solid), 12))
        #expect(approx(gap(Leading(mode: .extra, value: 6)), 18))
        #expect(approx(gap(Leading(mode: .fixed, value: 30)), 30))
        #expect(approx(gap(Leading(mode: .percent, value: 150)), 18))
        #expect(approx(gap(.auto), 14.4))
        // First-line leading sets the first baseline.
        let fixed = Fixture.layout("x", in: [Fixture.block { $0.firstLineLeading = Leading(mode: .fixed, value: 40) }])
        #expect(approx(fixed.lineOrigins[0].y, 40))
        let extra = Fixture.layout("x", in: [Fixture.block { $0.firstLineLeading = Leading(mode: .extra, value: 3); $0.inset = Inset(top: 10) }])
        #expect(approx(extra.lineOrigins[0].y, 25))
    }

    @Test func paragraphSpacingUsesTheLargerAndSkipsTheColumnTop() {
        let content = TextContent(
            runs: [TextRun("first\nsecond\nthird", attributes: Fixture.body)],
            paragraphs: [
                ParagraphStyle(spaceAbove: 50, spaceBelow: 10),
                ParagraphStyle(spaceAbove: 4, spaceBelow: 20),
                ParagraphStyle(spaceAbove: 30),
            ]
        )
        let layout = TextLayoutEngine().layout(content, in: [Fixture.block()])
        let origins = layout.lineOrigins
        #expect(origins[0].y < 12, "space above ignored at the top of the column")
        #expect(approx(origins[1].y - origins[0].y, 14.4 + 10))
        #expect(approx(origins[2].y - origins[1].y, 14.4 + 30))
        let negative = TextContent(runs: [TextRun("a\nb", attributes: Fixture.body)], paragraphs: [ParagraphStyle(spaceBelow: -20), ParagraphStyle(spaceAbove: -5)])
        let pulled = TextLayoutEngine().layout(negative, in: [Fixture.block()])
        #expect(approx(pulled.lineOrigins[1].y - pulled.lineOrigins[0].y, 14.4 - 5), "the larger of two negatives")
        Goldens.check(layout, name: "paragraphSpacing", size: Size(width: 120, height: 110))
    }

    @Test func selectedWordsNeverBreak() {
        var together = Fixture.body
        together.noBreak = true
        let content = TextContent(runs: [TextRun("aaaa bbbb cccc ", attributes: Fixture.body), TextRun("dddd eeee", attributes: together)])
        let width = TextLayoutEngine().layout(TextContent("aaaa bbbb cccc dddd", attributes: Fixture.body), in: [Fixture.block(width: 500)]).glyphs().last.map { $0.origin.x + $0.advance }!
        let layout = TextLayoutEngine().layout(content, in: [Fixture.block(width: width + 2)])
        #expect(layout.lineRanges[0] == 0..<15, "\"dddd eeee\" moves down together")
        // A span that cannot fit anywhere still breaks rather than leave a line empty.
        let wholeLine = TextContent(runs: [TextRun("dddd eeee ffff gggg", attributes: together)])
        let forced = TextLayoutEngine().layout(wholeLine, in: [Fixture.block(width: 40)])
        #expect(forced.lineCount > 1)
    }

    @Test func emptyParagraphsHaveHeight() {
        let layout = Fixture.layout("a\n\nb", in: [Fixture.block()])
        #expect(layout.lineCount == 3)
        #expect(approx(layout.lineOrigins[2].y - layout.lineOrigins[0].y, 28.8))
        let centered = Fixture.layout("", style: ParagraphStyle(alignment: .center), in: [Fixture.block(width: 100)])
        #expect(approx(centered.caret(atOffset: 0)!.baseline.x, 50))
        let right = Fixture.layout("", style: ParagraphStyle(alignment: .right), in: [Fixture.block(width: 100)])
        #expect(approx(right.caret(atOffset: 0)!.baseline.x, 100))
    }
}
