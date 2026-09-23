import Foundation
import Testing
import WTGeometry
import WTRender
@testable import WTText

/// Incremental relayout (TXT-001 "Done when": a 200,000-character flow relays out in under
/// 100 ms after an edit).
@Suite struct IncrementalLayoutTests {
    @Test func onlyEditedParagraphsAreTypesetAgain() {
        let engine = TextLayoutEngine()
        var paragraphs = (0..<10).map { "Paragraph \($0) " + Fixture.lorem }
        let containers = [Fixture.block(width: 300, height: 10000)]
        _ = engine.layout(TextContent(paragraphs.joined(separator: "\n"), attributes: Fixture.body), in: containers)
        #expect(engine.paragraphsTypeset == 10)
        let lines = engine.linesBroken
        _ = engine.layout(TextContent(paragraphs.joined(separator: "\n"), attributes: Fixture.body), in: containers)
        #expect(engine.paragraphsTypeset == 10, "an unchanged flow typesets nothing")
        #expect(engine.linesBroken == lines, "and breaks no line")
        paragraphs[4] = "Edited. " + paragraphs[4]
        let edited = engine.layout(TextContent(paragraphs.joined(separator: "\n"), attributes: Fixture.body), in: containers)
        #expect(engine.paragraphsTypeset == 11)
        #expect(edited.lineCount > 30)
        // A new width re-breaks lines but reuses the shaped paragraphs.
        _ = engine.layout(TextContent(paragraphs.joined(separator: "\n"), attributes: Fixture.body), in: [Fixture.block(width: 250, height: 10000)])
        #expect(engine.paragraphsTypeset == 11)
        #expect(engine.linesBroken > lines)
    }

    /// 200,000 characters in 400 paragraphs through linked two-column blocks.
    static func largeFlow(editing index: Int? = nil) -> TextContent {
        let paragraph = String(repeating: "The quick brown fox jumps over the lazy dog, then naps. ", count: 9)  // 504
        var runs: [TextRun] = []
        var styles: [ParagraphStyle] = []
        for number in 0..<397 {
            let text = (number == index ? "Edited: " : "") + "\(number): " + paragraph
            runs.append(TextRun(text + (number < 396 ? "\n" : ""), attributes: Fixture.body))
            styles.append(ParagraphStyle(alignment: number.isMultiple(of: 2) ? .left : .justified, spaceBelow: 6))
        }
        return TextContent(runs: runs, paragraphs: styles)
    }

    static let chain: [TextContainer] = (0..<80).map { page in
        var block = TextBlock(width: 400, height: 700, transform: .translation(x: 0, y: Double(page) * 720))
        block.columns = ColumnsRows(columns: 2, columnSpacing: 12)
        return .block(block)
    } + [.block(TextBlock(width: 400, height: 10, autoHeight: true))]

    @Test func aLargeFlowRelaysOutIncrementally() {
        let engine = TextLayoutEngine()
        let content = IncrementalLayoutTests.largeFlow()
        #expect(content.scalarCount >= 200_000)
        let initialStart = Date()
        let initial = engine.layout(content, in: IncrementalLayoutTests.chain)
        let initialTime = Date().timeIntervalSince(initialStart)
        #expect(!initial.overflows)
        #expect(engine.paragraphsTypeset == 397)

        let edited = IncrementalLayoutTests.largeFlow(editing: 200)
        let start = Date()
        let relaid = engine.layout(edited, in: IncrementalLayoutTests.chain)
        let elapsed = Date().timeIntervalSince(start)
        #expect(engine.paragraphsTypeset == 398, "one paragraph typeset again")
        #expect(relaid.characterCount == content.scalarCount + 8)
        #expect(relaid.lineCount >= initial.lineCount)
        PerfBudget.expect(.seconds(elapsed), within: .milliseconds(100))
        print(String(format: "PERF WTText (%@): %d characters, %d lines in %d containers; full layout %.1f ms, incremental relayout after a one-paragraph edit %.1f ms", PerfBudget.buildName, relaid.characterCount, relaid.lineCount, IncrementalLayoutTests.chain.count, initialTime * 1000, elapsed * 1000))
    }
}
