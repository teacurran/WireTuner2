// PRINT-014: fonts at print time -- *Print text as outlines* and the job's font check.

import CoreGraphics
import CoreText
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct PrintFontsTests {
    static let paper = PrintPaper(size: Size(width: 300, height: 260), imageable: Rect(x: 9, y: 9, width: 282, height: 242))

    static func page(_ items: [DisplayItem], nodes: [NodeID?], number: Int) -> ExportPage {
        var page = Corpus.page(items, nodes: nodes)
        page.number = number
        return page
    }

    /// The `BaseFont` names a PDF's font dictionaries give (Core Graphics writes dictionaries
    /// uncompressed), and whether any font program is embedded.
    static func fonts(inPDF data: Data) -> (names: [String], embedded: Bool) {
        let text = String(decoding: data, as: UTF8.self)
        var names: [String] = []
        var rest = text[...]
        while let range = rest.range(of: "/BaseFont /") {
            let name = rest[range.upperBound...].prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }
            names.append(String(name))
            rest = rest[range.upperBound...]
        }
        return (names, text.contains("/FontFile"))
    }

    @Test func outlinesReplaceEveryGlyphRun() throws {
        let node = Corpus.node(1)
        let placeholder = DisplayItem.text(TextRunItem(text: "…", origin: Point(x: 0, y: 0), bounds: Rect(x: 0, y: -10, width: 20, height: 12)))
        let square = Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(.black))])
        let overprinted = DisplayItem.text(TextRunItem(text: "Op", glyphRun: Corpus.run("Op"), origin: Point(x: 10, y: 40), color: Corpus.red, overprint: true))
        let list = DisplayList(canvas: "p", items: [Corpus.text("Hello"), .group(GroupItem(children: [overprinted, square])), placeholder], nodeIDs: [node, nil, nil])
        let outlined = PrintTextOutlines.outline(list)
        #expect(outlined.nodeIDs == list.nodeIDs && outlined.items.count == 3)
        guard case .path(let hello) = outlined.items[0], case .group(let group) = outlined.items[1], case .path(let op) = group.children[0] else {
            Issue.record("runs were not outlined: \(outlined.items)")
            return
        }
        #expect(hello.path == Corpus.run("Hello").outline)
        #expect(op.appearance.items == [.fill(FillPaint(paint: .solid(Corpus.red), overprint: true))])
        #expect(group.children[1] == square)
        #expect(outlined.items[2] == placeholder)
    }

    @Test func outlinedJobsEmbedNoFontsAndMatchTheFontRender() throws {
        let items = [Corpus.text("Proof 123", size: 24, origin: Point(x: 20, y: 60)), Corpus.text("small print", font: "Times-Roman", size: 9, origin: Point(x: 20, y: 100))]
        let request = PrintRequest(scene: ExportScene(name: "Fonts", pages: [Self.page(items, nodes: [], number: 1)]), paper: Self.paper)
        var outlines = request
        outlines.options.textAsOutlines = true
        let asText = try PrintPDF.data(PrintPlan(request))
        let asOutlines = try PrintPDF.data(PrintPlan(outlines))
        #expect(Self.fonts(inPDF: asOutlines).names.isEmpty && !Self.fonts(inPDF: asOutlines).embedded)
        // WTRender fills glyph runs as outlines in the print context too, so a job without the
        // option embeds nothing either (print-fonts.adoc, the PRINT-014 note).
        #expect(Self.fonts(inPDF: asText).names.isEmpty && !Self.fonts(inPDF: asText).embedded)
        // At 300 dpi the outlines fall within anti-aliasing of the font render.
        let scale = 300.0 / 72
        let text = try PrintSheetTests.bitmap(PrintPlan(request), scale: scale)
        let outlined = try PrintSheetTests.bitmap(PrintPlan(outlines), scale: scale)
        #expect(Corpus.difference(text, outlined, tolerance: 96) < 0.002)
        #expect(Corpus.difference(text, try PrintSheetTests.bitmap(PrintPlan(request), scale: scale, renderer: PrintSheetRenderer(textOutliner: { $0 })), tolerance: 0) == 0)
    }

    @Test func theCheckReadsOnlyPrintedRuns() throws {
        let printed = Corpus.node(1), pasteboard = Corpus.node(2), unprinted = Corpus.node(3), grouped = Corpus.node(4)
        let front = Self.page([
            .group(GroupItem(children: [Corpus.text("Front", origin: Point(x: 20, y: 40))])),
            Corpus.text("Offstage", font: "Times-Roman", origin: Point(x: 600, y: 40)),
            .group(GroupItem(children: [Corpus.text("Bold", font: "Helvetica-Bold", origin: Point(x: 20, y: 90))])),
            Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(.black))]),
        ], nodes: [printed, pasteboard, nil, nil], number: 1)
        var withNested = front
        withNested.nestedNodeIDs = [[2, 0]: grouped]
        let back = Self.page([Corpus.text("Back", font: "Courier", origin: Point(x: 20, y: 40))], nodes: [unprinted], number: 2)
        let request = PrintRequest(scene: ExportScene(name: "Check", pages: [withNested, back]), paper: Self.paper, pageRange: 1...1)
        let plan = PrintPlan(request)
        let check = PrintFontCheck(plan: plan)
        #expect(check.fonts.map(\.postScriptName) == ["Helvetica", "Helvetica-Bold"])
        #expect(check.textNodes == [printed, grouped])
        #expect(PrintFontCheck.families(check.fonts) == ["Helvetica"])
        // Neither the pasteboard's font nor the unprinted page's is in the saved PDF's font list.
        let names = Self.fonts(inPDF: try PrintPDF.data(plan)).names
        #expect(!names.contains { $0.contains("Times") || $0.contains("Courier") })
        // Both pages printed: the back page's font joins.
        var all = request
        all.pageRange = nil
        #expect(PrintFontCheck(plan: PrintPlan(all)).fonts.map(\.family).contains("Courier"))
    }

    @Test func fontNames() throws {
        let facts = PrintFont(CTFontCreateWithName("Helvetica" as CFString, 12, nil))
        #expect(facts.family == "Helvetica" && facts.postScriptName == "Helvetica" && facts.style == "Regular")
        #expect(PrintFont(postScriptName: "A", family: "B") < PrintFont(postScriptName: "A", family: "C"))
        #expect(PrintFontCheck(fonts: [], textNodes: []).fonts.isEmpty)
    }
}
