import Testing
import WTGeometry
import WTRender
@testable import WTText

/// Blocks: sizes, insets, columns and rows, keeps, rules, linked flow, vertical writing
/// (text-blocks, columns-tables, paragraphs, text-effects).
@Suite struct BlockLayoutTests {
    static let numbered = (1...40).map { "Line \($0)" }.joined(separator: "\n")

    @Test func insetsMoveTheText() {
        let layout = Fixture.layout("Inset", in: [Fixture.block(width: 100, height: 50) { $0.inset = Inset(left: 10, right: 5, top: 8, bottom: 2) }])
        let first = layout.glyphs()[0]
        #expect(approx(first.origin.x, 10, 1.2))
        #expect(approx(layout.lineOrigins[0].y, 8 + 9.24, 0.01), "top inset plus the ascent")
    }

    @Test func fixedBlocksOverflowAndAutoBlocksGrow() {
        let fixed = Fixture.layout(BlockLayoutTests.numbered, in: [Fixture.block(width: 100, height: 60)])
        #expect(fixed.overflows)
        #expect(fixed.lineCount == 4, "four 14.4 pt lines fit in 60 pt")
        #expect(fixed.sizes[0] == Size(width: 100, height: 60))

        let tall = Fixture.layout(BlockLayoutTests.numbered, in: [Fixture.block(width: 100, height: 60) { $0.autoHeight = true; $0.inset = Inset(top: 5, bottom: 7) }])
        #expect(!tall.overflows)
        #expect(tall.lineCount == 40)
        let lastBaseline = tall.lineOrigins.last!.y
        #expect(tall.sizes[0].height > lastBaseline + 7 && tall.sizes[0].height < lastBaseline + 12)
        #expect(tall.sizes[0].width == 100)

        let text = "Short\nA considerably longer line"
        let wide = Fixture.layout(text, style: ParagraphStyle(alignment: .right, rightIndent: 3), in: [Fixture.block(width: 20, height: 100) { $0.autoWidth = true; $0.inset = Inset(left: 4, right: 6) }])
        #expect(wide.lineCount == 2, "an auto-width block never wraps")
        let longest = Fixture.lineExtents(wide, text: text)[1]
        #expect(approx(wide.sizes[0].width, longest.end + 3 + 6, 0.5))
        #expect(approx(Fixture.lineExtents(wide, text: text)[0].end, longest.end, 0.5), "right alignment within the measured width")
        Goldens.check(wide, name: "autoWidth", size: Size(width: 180, height: 40))
    }

    @Test func columnsAndRowsFillInFlowOrder() {
        func cellStarts(_ flow: FlowOrder) -> [Point] {
            var block = TextBlock(width: 200, height: 100)
            block.columns = ColumnsRows(columns: 2, columnSpacing: 20, rows: 2, rowSpacing: 10, flow: flow)
            let text = "A\u{000C}B\u{000C}C\u{000C}D"
            let layout = Fixture.layout(text, in: [.block(block)])
            #expect(layout.lineCount == 4)
            return layout.glyphs().map(\.origin)
        }
        let down = cellStarts(.down)
        // Cells are 90 wide and 45 tall; down fills the left column first.
        #expect(approx(down[0].x, 0, 1) && approx(down[1].x, 0, 1) && approx(down[2].x, 110, 1) && approx(down[3].x, 110, 1))
        #expect(down[1].y > 50 && down[3].y > 50 && down[0].y < 20 && down[2].y < 20)
        let across = cellStarts(.across)
        #expect(approx(across[1].x, 110, 1) && approx(across[2].x, 0, 1))
        #expect(across[2].y > 50)
    }

    @Test func textFlowsFromColumnToColumn() {
        var block = TextBlock(width: 210, height: 60)
        block.columns = ColumnsRows(columns: 3, columnSpacing: 15)
        let layout = Fixture.layout(BlockLayoutTests.numbered, in: [.block(block)])
        #expect(layout.lineCount == 12)
        let origins = layout.lineOrigins
        #expect(approx(origins[4].x, 75, 1) && approx(origins[8].x, 150, 1))
        #expect(approx(origins[4].y, origins[0].y))
        Goldens.check(layout, name: "columns", size: Size(width: 220, height: 70))
        // A column break mid-paragraph moves the rest to the next column.
        let broken = Fixture.layout("one two\u{000C}three", in: [.block(block)])
        #expect(broken.lineCount == 2)
        #expect(approx(broken.lineOrigins[1].x, 75, 1))
        // In the last cell of a linked block a column break ends the block: the rest flows on.
        let last = Fixture.layout("a\u{000C}b", in: [Fixture.block(width: 100, height: 100), Fixture.block(width: 100, height: 100)])
        #expect(last.lineCount(inContainer: 0) == 1 && last.lineCount(inContainer: 1) == 1)
        // In a lone block of one cell it is a line break (columns-tables, read-time normalizations).
        let lone = Fixture.layout("a\u{000C}b", in: [Fixture.block(width: 100, height: 100)])
        #expect(!lone.overflows && lone.lineCount == 2)
    }

    @Test func explicitCellSizesGrowTheBlock() {
        var block = TextBlock(width: 50, height: 50, inset: Inset(left: 1, right: 2, top: 3, bottom: 4))
        block.columns = ColumnsRows(columns: 2, columnHeight: 30, columnSpacing: 10, rows: 3, rowWidth: 40, rowSpacing: 5)
        let layout = Fixture.layout("x", in: [.block(block)])
        #expect(layout.sizes[0] == Size(width: 1 + 2 * 40 + 10 + 2, height: 3 + 3 * 30 + 2 * 5 + 4))
    }

    @Test func keepLinesTogetherPreventsWidowsAndOrphans() {
        // Columns of six lines, 30 pt wide: one word per line.
        let seven = Array(repeating: "word", count: 7).joined(separator: " ")
        let text = "Intro\n" + seven
        var block = TextBlock(width: 70, height: 90)
        block.columns = ColumnsRows(columns: 2, columnSpacing: 10)
        func secondColumnLines(keep: Int) -> Int {
            let content = TextContent(runs: [TextRun(text, attributes: Fixture.body)], paragraphs: [ParagraphStyle(), ParagraphStyle(keepLines: keep)])
            let layout = TextLayoutEngine().layout(content, in: [.block(block)])
            return layout.lineOrigins.filter { $0.x >= 40 }.count
        }
        #expect(secondColumnLines(keep: 0) == 2, "5 + 2 without keeps")
        #expect(secondColumnLines(keep: 2) == 2)
        #expect(secondColumnLines(keep: 3) == 3, "a widow rule pulls a third line over")
        #expect(secondColumnLines(keep: 6) == 6, "an orphan rule moves the whole paragraph (and it overflows)")
        // Keep with next: a heading at the bottom of a column follows its paragraph.
        let five = Array(repeating: "word", count: 5).joined(separator: " ")
        let heading = ParagraphStyle(keepWithNext: true)
        let content = TextContent(runs: [TextRun("a\nb\nc\nd\ne\nHd\n" + five, attributes: Fixture.body)], paragraphs: [ParagraphStyle(), ParagraphStyle(), ParagraphStyle(), ParagraphStyle(), ParagraphStyle(), heading, ParagraphStyle()])
        let layout = TextLayoutEngine().layout(content, in: [.block(block)])
        let headingLine = layout.lineRanges.firstIndex { $0.lowerBound == 10 }!
        #expect(layout.lineOrigins[headingLine].x >= 40, "the heading moved with its paragraph")
        // A paragraph that starts a column cannot be pushed: keeps give way.
        let top = TextContent(runs: [TextRun(five + " " + five, attributes: Fixture.body)], paragraphs: [ParagraphStyle(keepLines: 20)])
        #expect(TextLayoutEngine().layout(top, in: [.block(block)]).lineOrigins.first!.x < 30)
    }

    @Test func keepWithNextMovesTheLastLineWhenTheNextParagraphWouldNotFit() {
        let five = Array(repeating: "word", count: 5).joined(separator: " ")
        let three = Array(repeating: "word", count: 3).joined(separator: " ")
        var block = TextBlock(width: 70, height: 90)
        block.columns = ColumnsRows(columns: 2, columnSpacing: 10)
        // Three one-line paragraphs and a three-line one fill the column exactly.
        let text = "x\ny\nz\n" + three + "\n" + five
        func firstColumnLines(_ style: ParagraphStyle) -> Int {
            let content = TextContent(runs: [TextRun(text, attributes: Fixture.body)], paragraphs: [ParagraphStyle(), ParagraphStyle(), ParagraphStyle(), style, ParagraphStyle()])
            return TextLayoutEngine().layout(content, in: [.block(block)]).lineOrigins.filter { $0.x < 30 }.count
        }
        #expect(firstColumnLines(ParagraphStyle()) == 6)
        #expect(firstColumnLines(ParagraphStyle(keepWithNext: true)) == 5, "its last line moves with the next paragraph")
        #expect(firstColumnLines(ParagraphStyle(keepLines: 2, keepWithNext: true)) == 3, "and with keep lines 2, all of it")
    }

    @Test func paragraphRulesAboveAndBelow() throws {
        let block = StrokePaint(paint: .solid(Color(red: 0.8, green: 0, blue: 0)), style: StrokeStyle(width: 2))
        let heavy = StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 4))
        let styles = [
            ParagraphStyle(rule: ParagraphRule(mode: .centered, widthPercent: 50, basis: .column, position: 4)),
            ParagraphStyle(alignment: .right, rule: ParagraphRule(mode: .paragraph, widthPercent: 100, basis: .lastLine, position: 3)),
            ParagraphStyle(alignment: .center, rule: ParagraphRule(mode: .paragraph, widthPercent: 100, basis: .column, position: 2, above: true, stroke: heavy)),
            ParagraphStyle(rule: ParagraphRule(mode: .paragraph, widthPercent: 50, basis: .column, position: 2)),
            ParagraphStyle(alignment: .right, rule: ParagraphRule(mode: .paragraph, widthPercent: 50, basis: .column)),
            ParagraphStyle(alignment: .center, rule: ParagraphRule(mode: .paragraph, widthPercent: 50, basis: .lastLine)),
            ParagraphStyle(rule: ParagraphRule(mode: .none)),
        ]
        let content = TextContent(runs: [TextRun("Centered\nRight rule\nAbove\nLeft\nRight half\nMiddle\nNone", attributes: Fixture.body)], paragraphs: styles)
        let container = TextBlock(width: 200, height: 200, appearance: Appearance([.stroke(block)]))
        let layout = TextLayoutEngine().layout(content, in: [.block(container)])
        let strokes = Fixture.strokePaths(layout.displayItems(forContainer: 0))
        #expect(strokes.count == 6)
        func span(_ stroke: PathItem) -> (x0: Double, x1: Double, y: Double) {
            guard case .move(let a) = stroke.path.elements[0], case .line(let b) = stroke.path.elements[1] else {
                return (0, 0, 0)
            }
            return (a.x, b.x, a.y)
        }
        let origins = layout.lineOrigins
        let centered = span(strokes[0])
        #expect(approx(centered.x0, 50) && approx(centered.x1, 150) && approx(centered.y, origins[0].y + 4))
        #expect(strokes[0].appearance.strokes == [block])
        let right = span(strokes[1])
        let extents = Fixture.lineExtents(layout, text: "Centered\nRight rule\nAbove\nLeft\nRight half\nMiddle\nNone")
        #expect(approx(right.x1, 200, 0.5) && approx(right.x0, extents[1].start, 1.0))
        let above = span(strokes[2])
        #expect(approx(above.x0, 0) && approx(above.x1, 200))
        #expect(above.y < origins[2].y - 8)
        #expect(strokes[2].appearance.strokes == [heavy], "the rule's own stroke overrides the block's")
        #expect(approx(span(strokes[3]).x0, 0) && approx(span(strokes[3]).x1, 100))
        #expect(approx(span(strokes[4]).x0, 100) && approx(span(strokes[4]).x1, 200))
        let middle = span(strokes[5])
        #expect(approx((middle.x0 + middle.x1) / 2, 100, 0.5))
        Goldens.check(layout, name: "paragraphRules", size: Size(width: 210, height: 110))

        // No stroke on the block and none on the rule: nothing is drawn.
        let bare = TextLayoutEngine().layout(content, in: [.block(TextBlock(width: 200, height: 200))])
        #expect(Fixture.strokePaths(bare.displayItems(forContainer: 0)).count == 1, "only the rule with its own stroke")
        // A rule is drawn only where its paragraph ends (or starts, above).
        let split = TextContent(runs: [TextRun("a\nb\nc\nd\ne", attributes: Fixture.body)], paragraphs: Array(repeating: ParagraphStyle(rule: ParagraphRule(mode: .centered, above: true)), count: 5))
        var columns = TextBlock(width: 100, height: 30, appearance: Appearance([.stroke(block)]))
        columns.columns = ColumnsRows(columns: 2)
        let splitLayout = TextLayoutEngine().layout(split, in: [.block(columns)])
        #expect(Fixture.strokePaths(splitLayout.displayItems(forContainer: 0)).count == splitLayout.lineCount)
        #expect(splitLayout.displayItems(forContainer: 7).isEmpty)
    }

    @Test func linkedBlocksContinueTheFlow() {
        let first = Fixture.block(width: 100, height: 45)
        let second = Fixture.block(width: 150, height: 45) { $0.transform = .translation(x: 300, y: 0) }
        let third = Fixture.block(width: 80, height: 30)
        let layout = Fixture.layout(BlockLayoutTests.numbered, in: [first, second, third])
        #expect(layout.lineCount(inContainer: 0) == 3)
        #expect(layout.lineCount(inContainer: 1) == 3)
        #expect(layout.lineCount(inContainer: 2) == 2)
        #expect(layout.overflows)
        let ranges = layout.lineRanges
        #expect(ranges[3].lowerBound == ranges[2].upperBound + 1, "the next block starts at the next paragraph")
        // Items carry each block's own transform.
        let items = layout.displayItems(forContainer: 1)
        #expect(items.allSatisfy { $0.transform == .translation(x: 300, y: 0) })
        #expect(layout.displayItems(forContainer: 1, transform: .scale(2)).first?.transform == AffineTransform.translation(x: 300, y: 0).concatenating(.scale(2)))
        // A paragraph split across blocks of different widths re-breaks in the new width.
        let long = Fixture.layout(Fixture.lorem, in: [Fixture.block(width: 200, height: 30), Fixture.block(width: 80, height: 400)])
        #expect(long.lineCount(inContainer: 0) == 2)
        #expect(Fixture.lineExtents(long, text: Fixture.lorem).dropFirst(2).allSatisfy { $0.end <= 80.01 })
        #expect(!long.overflows)
        // Nothing left for later containers.
        let short = Fixture.layout("hi", in: [first, second])
        #expect(short.lineCount(inContainer: 1) == 0)
    }

    @Test func verticalTextRunsDownAndStacksRightToLeft() {
        let text = "縦書き\nAbc"
        var block = TextBlock(width: 60, height: 100)
        block.direction = .vertical
        let layout = Fixture.layout(text, attributes: TextAttributes(fontFamily: "Hiragino Sans", size: 14), in: [.block(block)])
        #expect(layout.lineCount == 2)
        let glyphs = layout.glyphs()
        let cjk = glyphs.filter { $0.offset < 3 }
        let latin = glyphs.filter { $0.offset > 3 }
        // Upright ideographs: untransformed glyphs moving down the first (rightmost) line.
        #expect(cjk.allSatisfy { $0.transform.a == 1 && $0.transform.b == 0 && $0.transform.c == 0 && $0.transform.d == 1 })
        #expect(cjk.map(\.origin.y) == cjk.map(\.origin.y).sorted())
        #expect(cjk.allSatisfy { $0.origin.x > 30 })
        // Latin rotated a quarter turn clockwise, on the line to the left.
        #expect(latin.allSatisfy { approx($0.transform.a, 0) && approx($0.transform.b, 1) && approx($0.transform.c, -1) && approx($0.transform.d, 0) })
        #expect(latin.allSatisfy { $0.origin.x < cjk[0].origin.x })
        #expect(latin.map(\.origin.y) == latin.map(\.origin.y).sorted())
        // Carets run across the vertical line.
        let caret = layout.caret(atOffset: 1)!
        #expect(approx(caret.top.y, caret.bottom.y) && caret.top.x > caret.bottom.x)
        #expect(layout.offset(at: Point(x: caret.baseline.x, y: caret.baseline.y + 1), inContainer: 0) == 1)
        Goldens.check(layout, name: "vertical", size: Size(width: 70, height: 110))

        // Auto height measures along the lines; auto width grows with the lines.
        var auto = TextBlock(width: 10, height: 10, autoWidth: true, autoHeight: true)
        auto.direction = .vertical
        let grown = Fixture.layout("ab\ncd\nef", in: [.block(auto)])
        #expect(grown.sizes[0].width > 40 && grown.sizes[0].height < 20)
        let rightmost = grown.glyphs().max { $0.origin.x < $1.origin.x }!
        #expect(rightmost.offset == 0 && rightmost.origin.x <= grown.sizes[0].width)
    }
}
