import Foundation
import Testing
import WTGeometry
import WTRender
import struct WTRender.StrokeStyle
@testable import WTText

/// TYPE-028 (paragraph layout remainder: keeps), TYPE-032 (cell grids with rules and border)
/// and TYPE-033 (balance, modify leading, copyfit, first-line leading).
@Suite struct ColumnsAdjustTests {
    static let stroke = StrokePaint(paint: .solid(Color(red: 0.2, green: 0.3, blue: 0.8)), style: StrokeStyle(width: 1))
    static let numbered = (1...40).map { "Line \($0)" }.joined(separator: "\n")

    /// The lines placed in each cell of container 0, by cell order of their tops.
    func linesPerCell(_ layout: TextLayout) -> [Int] {
        var cells: [Rect] = []
        var counts: [Int] = []
        for line in layout.lines where line.container == 0 {
            if let index = cells.firstIndex(of: line.cell) {
                counts[index] += 1
            } else {
                cells.append(line.cell)
                counts.append(1)
            }
        }
        return counts
    }

    // MARK: TYPE-032

    @Test func aThreeByTwoGridWithRulesAndBorder() throws {
        func grid(_ flow: FlowOrder) -> TextLayout {
            var block = TextBlock(width: 240, height: 120, inset: Inset(left: 6, right: 6, top: 6, bottom: 6), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(white: 0.95)))), .stroke(ColumnsAdjustTests.stroke)]), displayBorder: true)
            block.columns = ColumnsRows(columns: 3, columnSpacing: 12, rows: 2, rowSpacing: 10, flow: flow, columnRules: .full, rowRules: .inset)
            let text = (1...6).map { "Cell \($0)\nsecond line" }.joined(separator: "\u{000C}")
            return Fixture.layout(text, in: [.block(block)])
        }
        let down = grid(.down)
        let across = grid(.across)
        #expect(linesPerCell(down) == [2, 2, 2, 2, 2, 2])
        // Down fills a column top to bottom first; across fills a row first.
        let downOrigins = down.lineOrigins
        let acrossOrigins = across.lineOrigins
        #expect(approx(downOrigins[2].x, downOrigins[0].x) && downOrigins[2].y > 60)
        #expect(approx(acrossOrigins[2].y, acrossOrigins[0].y) && acrossOrigins[2].x > 80)
        Goldens.check(down, name: "gridDown", size: Size(width: 250, height: 130))
        Goldens.check(across, name: "gridAcross", size: Size(width: 250, height: 130))
        // Items: the block's fill first, then the rules and the border drawn with its stroke.
        let items = down.displayItems(forContainer: 0)
        guard case .path(let background) = items.first else {
            Issue.record("the fill comes first")
            return
        }
        #expect(background.appearance.strokes.isEmpty && background.path == DisplayPath(rect: Rect(x: 0, y: 0, width: 240, height: 120)))
        let strokes = Fixture.strokePaths(items)
        #expect(strokes.count == 2, "grid rules, then the border")
        let rules = strokes[0].path.elements
        // Two full-height column rules mid-gutter, one inset row rule mid-gutter.
        #expect(rules.count == 6)
        let cellWidth = (240.0 - 12 - 24) / 3
        #expect(rules[0] == .move(to: Point(x: 6 + cellWidth + 6, y: 0)) && rules[1] == .line(to: Point(x: 6 + cellWidth + 6, y: 120)))
        #expect(rules[4] == .move(to: Point(x: 6, y: 6 + 49 + 5)) && rules[5] == .line(to: Point(x: 234, y: 60)))
        #expect(strokes[1].path == DisplayPath(rect: Rect(x: 0, y: 0, width: 240, height: 120)))
    }

    @Test func displayBorderOffHidesTheBorderNotTheRules() {
        var block = TextBlock(width: 200, height: 100, appearance: Appearance([.fill(FillPaint(paint: .solid(.white))), .stroke(ColumnsAdjustTests.stroke)]))
        block.columns = ColumnsRows(columns: 2, columnSpacing: 10, rows: 2, columnRules: .inset, rowRules: .full)
        let layout = Fixture.layout("a\u{000C}b\u{000C}c\u{000C}d", in: [.block(block)])
        let strokes = Fixture.strokePaths(layout.displayItems(forContainer: 0))
        #expect(strokes.count == 1, "the rules only")
        let rules = strokes[0].path.elements
        #expect(rules[0] == .move(to: Point(x: 100, y: 0)) && rules[1] == .line(to: Point(x: 100, y: 100)), "inset equals full without an inset")
        #expect(rules[2] == .move(to: Point(x: 0, y: 50)) && rules[3] == .line(to: Point(x: 200, y: 50)))
        #expect(!layout.displayItems(forContainer: 0).contains { if case .path(let path) = $0 { return !path.appearance.fills.isEmpty } else { return false } })
        // No stroke: no rules; no rules asked for: none drawn; one column: nothing between.
        var bare = block
        bare.appearance = Appearance()
        #expect(Fixture.strokePaths(Fixture.layout("a", in: [.block(bare)]).displayItems(forContainer: 0)).isEmpty)
        var none = block
        none.columns = ColumnsRows(columns: 2, rows: 2)
        #expect(Fixture.strokePaths(Fixture.layout("a", in: [.block(none)]).displayItems(forContainer: 0)).isEmpty)
        var single = block
        single.columns = ColumnsRows(columnRules: .full, rowRules: .full)
        #expect(Fixture.strokePaths(Fixture.layout("a", in: [.block(single)]).displayItems(forContainer: 0)).isEmpty)
        // A path container has no grid.
        let path = Fixture.layout("a", in: [.path(PathText(contour: Contour(polygon: [.zero, Point(x: 100, y: 0)], closed: false)))])
        #expect(Fixture.strokePaths(path.displayItems(forContainer: 0)).isEmpty)
    }

    @Test func autoHeightGridRulesSpanTheGrownBlock() {
        var block = TextBlock(width: 200, height: 10, autoHeight: true, appearance: Appearance([.stroke(ColumnsAdjustTests.stroke)]))
        block.columns = ColumnsRows(columns: 2, columnSpacing: 10, columnRules: .full)
        let layout = Fixture.layout(ColumnsAdjustTests.numbered, in: [.block(block)])
        let rules = Fixture.strokePaths(layout.displayItems(forContainer: 0))[0].path.elements
        #expect(rules[1] == .line(to: Point(x: 100, y: layout.sizes[0].height)))
    }

    // MARK: TYPE-033

    @Test func balanceSpreadsLinesEvenly() {
        var block = TextBlock(width: 300, height: 400, adjust: AdjustColumns(balance: true))
        block.columns = ColumnsRows(columns: 3, columnSpacing: 10)
        for count in [10, 11, 12, 7] {
            let text = (1...count).map { "Line \($0)" }.joined(separator: "\n")
            let counts = linesPerCell(Fixture.layout(text, in: [.block(block)]))
            #expect(counts.max()! - counts.min()! <= 1, "\(count) lines: \(counts)")
            #expect(counts.reduce(0, +) == count && counts == counts.sorted(by: >), "the first columns take the extra lines")
        }
        let balanced = Fixture.layout((1...10).map { "Line \($0)" }.joined(separator: "\n"), in: [.block(block)])
        Goldens.check(balanced, name: "balanced", size: Size(width: 310, height: 70))
        // A flow that overflows fills its columns as usual; paragraph spacing may need more.
        var short = block
        short.height = 60
        #expect(linesPerCell(Fixture.layout(ColumnsAdjustTests.numbered, in: [.block(short)])) == [4, 4, 4])
        // A cell break defeats the even split: balance allows more lines until the text fits.
        var two = block
        two.columns = ColumnsRows(columns: 2, columnSpacing: 10)
        let broken = Fixture.layout("a\nb\nc\u{000C}d", in: [.block(two)])
        #expect(!broken.overflows && linesPerCell(broken) == [3, 1])
    }

    @Test func modifyLeadingFillsColumnsPastTheThreshold() {
        var block = TextBlock(width: 200, height: 100, adjust: AdjustColumns(modifyLeading: true, thresholdPercent: 50))
        block.columns = ColumnsRows(columns: 2, columnSpacing: 10)
        // Eight lines fill column one (seven fit) and leave one in column two, under the threshold.
        let text = (1...8).map { "Line \($0)" }.joined(separator: "\n")
        let layout = Fixture.layout(text, in: [.block(block)])
        let origins = layout.lineOrigins
        let firstColumn = layout.lines.filter { $0.cell.minX == 0 }
        let last = firstColumn.last!
        #expect(approx(last.origin.y + last.line.descent, 100, 0.01), "the full column is spread to its bottom")
        let gaps = zip(origins.prefix(firstColumn.count), origins.prefix(firstColumn.count).dropFirst()).map { $1.y - $0.y }
        #expect(gaps.allSatisfy { approx($0, gaps[0], 1e-9) } && gaps[0] > 14.4)
        #expect(approx(origins[firstColumn.count].y, origins[0].y), "the short column is left alone")
        Goldens.check(layout, name: "modifyLeading", size: Size(width: 210, height: 110))
        // Past the threshold a second column spreads too.
        var low = block
        low.adjust.thresholdPercent = 10
        let spread = Fixture.layout((1...9).map { "Line \($0)" }.joined(separator: "\n"), in: [.block(low)])
        let second = spread.lines.filter { $0.cell.minX > 0 }
        #expect(second.count == 2 && approx(second[1].origin.y + second[1].line.descent, 100, 0.01))
    }

    @Test func copyfitConvergesAndFits() {
        var block = TextBlock(width: 200, height: 120, adjust: AdjustColumns(copyfitMinPercent: 50, copyfitMaxPercent: 200))
        let content = TextContent(Fixture.lorem, attributes: Fixture.body)
        let engine = TextLayoutEngine()
        let fitted = engine.layout(content, in: [.block(block)])
        #expect(!fitted.overflows)
        #expect(fitted.copyfitIterations <= copyfitIterationLimit)
        #expect(fitted.copyfitScale > 1, "the text grows to fill the block")
        // Slightly larger overflows: the fit is tight (within the last bisection step).
        let larger = TextLayoutEngine().layout(content.scaled(by: fitted.copyfitScale + 1.5 / 64), in: [.block(TextBlock(width: 200, height: 120))])
        #expect(larger.overflows)
        // Deterministic: the same sizes every time (and on every Mac: one sequence of operations).
        #expect(TextLayoutEngine().layout(content, in: [.block(block)]).copyfitScale == fitted.copyfitScale)
        Goldens.check(fitted, name: "copyfit", size: Size(width: 210, height: 130))
        // Shrinking: too much text for the block at 100%.
        block.adjust = AdjustColumns(copyfitMinPercent: 40, copyfitMaxPercent: 100)
        let long = TextContent(Fixture.lorem + " " + Fixture.lorem, attributes: Fixture.body)
        let shrunk = engine.layout(long, in: [.block(block)])
        #expect(shrunk.copyfitScale < 1 && !shrunk.overflows && shrunk.copyfitIterations <= copyfitIterationLimit)
        // Even the minimum overflows: the minimum is used.
        block.adjust = AdjustColumns(copyfitMinPercent: 90, copyfitMaxPercent: 95)
        let tooMuch = engine.layout(long, in: [.block(block)])
        #expect(tooMuch.copyfitScale == 0.9 && tooMuch.overflows && tooMuch.copyfitIterations == 2)
        // A minimum above the maximum reads as both at the minimum; 100/100 is off.
        block.adjust = AdjustColumns(copyfitMinPercent: 80, copyfitMaxPercent: 60)
        #expect(engine.layout(long, in: [.block(block)]).copyfitScale == 0.8)
        #expect(AdjustColumns().copyfitRange == nil)
        let plain = engine.layout(content, in: [.block(TextBlock(width: 200, height: 120))])
        #expect(plain.copyfitScale == 1 && plain.copyfitIterations == 0)
        // Leading scales with the size unless it is a percentage.
        let extra = TextAttributes(size: 10, leading: Leading(mode: .extra, value: 2)).scaled(by: 2)
        #expect(extra.size == 20 && extra.leading == Leading(mode: .extra, value: 4))
        let percent = TextAttributes(size: 10, leading: .auto).scaled(by: 2)
        #expect(percent.leading == .auto)
    }

    @Test func copyfitFitsTextInsideAPath() {
        let circle = Contour(polygon: (0..<48).map { index in
            let angle = Double(index) / 48 * 2 * .pi
            return Point(x: 100 + 90 * cos(angle), y: 100 + 90 * sin(angle))
        }, closed: true)
        let path = PathText(contour: circle, mode: .inside, adjust: AdjustColumns(copyfitMinPercent: 30, copyfitMaxPercent: 300))
        let layout = TextLayoutEngine().layout(TextContent(Fixture.lorem, attributes: Fixture.body), in: [.path(path)])
        #expect(!layout.overflows && layout.copyfitScale > 1)
        Goldens.check(layout, name: "copyfitInsidePath", size: Size(width: 200, height: 200))
    }

    @Test func firstLineLeadingSetsEachColumnsFirstBaseline() {
        var block = TextBlock(width: 200, height: 100, firstLineLeading: Leading(mode: .fixed, value: 30))
        block.columns = ColumnsRows(columns: 2, columnSpacing: 10)
        let layout = Fixture.layout(ColumnsAdjustTests.numbered, in: [.block(block)])
        let firsts = layout.lines.filter { $0.line.start == 0 && $0.origin.y < 31 }
        #expect(firsts.count == 2 && firsts.allSatisfy { approx($0.origin.y, 30) })
    }

    // MARK: TYPE-028

    @Test func keepsNeverEmptyAColumnWhenTheParagraphFits() {
        var block = TextBlock(width: 300, height: 60)
        block.columns = ColumnsRows(columns: 3, columnSpacing: 6)
        // Three intro lines, then a heading kept with a body that keeps four lines together: the
        // heading would end column one, but the body's lines cannot follow it there.
        let styles = [ParagraphStyle(), ParagraphStyle(), ParagraphStyle(), ParagraphStyle(keepWithNext: true), ParagraphStyle(keepLines: 4)]
        let content = TextContent(runs: [TextRun("Intro one\nIntro two\nIntro three\nHeading\nBody line one two three four five six", attributes: Fixture.body)], paragraphs: styles)
        let layout = TextLayoutEngine().layout(content, in: [.block(block)])
        let counts = linesPerCell(layout)
        #expect(counts.first == 3 && counts.reduce(0, +) == layout.lineCount, "\(counts)")
        #expect(!layout.overflows)
        // The heading moved with the body's kept lines.
        let heading = layout.lines.first { $0.paragraph == 1 }!
        let body = layout.lines.first { $0.paragraph == 2 }!
        #expect(heading.cell == body.cell)
        // Keep with next checks as many of the next paragraph's lines as it keeps together.
        let kept = [ParagraphStyle(keepWithNext: true), ParagraphStyle(keepLines: 3)]
        let fits = TextLayoutEngine().layout(TextContent(runs: [TextRun("Intro\nHead\nOne two three four five six seven eight nine ten", attributes: Fixture.body)], paragraphs: [ParagraphStyle()] + kept), in: [.block(TextBlock(width: 60, height: 200))])
        #expect(fits.lineCount(inContainer: 0) == fits.lineCount && !fits.overflows)
        // At the top of a column keeps give way.
        var tiny = TextBlock(width: 60, height: 30)
        tiny.columns = ColumnsRows(columns: 2, columnSpacing: 5)
        let crowded = TextLayoutEngine().layout(TextContent(runs: [TextRun("one two three four five six", attributes: Fixture.body)], paragraphs: [ParagraphStyle(keepLines: 9)]), in: [.block(tiny)])
        #expect(crowded.lineCount(inContainer: 0) > 0)
    }

    @Test func aJustifiedFlowStaysWithinTheBudget() {
        let engine = TextLayoutEngine()
        func content(editing index: Int?) -> TextContent {
            let styles = (0..<400).map { _ in ParagraphStyle(alignment: .justified, hyphenation: Hyphenation(enabled: true), wordSpacing: SpacingRange(min: 80, optimum: 100, max: 133)) }
            let text = (0..<400).map { ($0 == index ? "Edited " : "") + String(repeating: "Justification spreads the words of every line to both edges. ", count: 9) }.joined(separator: "\n")
            return TextContent(runs: [TextRun(text, attributes: Fixture.body)], paragraphs: styles)
        }
        _ = engine.layout(content(editing: nil), in: IncrementalLayoutTests.chain)
        let start = Date()
        let layout = engine.layout(content(editing: 12), in: IncrementalLayoutTests.chain)
        let elapsed = Date().timeIntervalSince(start)
        #expect(layout.characterCount > 200_000)
        #if !DEBUG
        #expect(elapsed < 0.1, "justified relayout took \(elapsed * 1000) ms")
        #endif
        print(String(format: "PERF WTText justified 200,000 characters: relayout %.1f ms", elapsed * 1000))
    }
}
