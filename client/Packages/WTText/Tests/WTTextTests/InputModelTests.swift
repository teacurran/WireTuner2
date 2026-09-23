import CoreText
import Foundation
import Testing
import WTGeometry
import WTRender
@testable import WTText

/// The input model, fonts and the corners of the layout API.
@Suite struct InputModelTests {
    @Test func idsAndAnchors() {
        let a = CharID(counter: 1, replica: 5)
        let b = CharID(counter: 2, replica: 0)
        #expect(a < b && CharID(counter: 2, replica: 0) < CharID(counter: 2, replica: 1))
        #expect(a.description == "1:5")
        #expect(CharAnchor.before(a) == CharAnchor(char: a, before: true))
        #expect(CharAnchor.after(a) == CharAnchor(char: a, before: false))
        #expect(syntheticCharID(4) == CharID(counter: 4, replica: .max))
    }

    @Test func leadingAndAttributes() {
        #expect(Leading.auto.distance(forSize: 10) == 12)
        #expect(Leading.solid.distance(forSize: 10) == 10)
        #expect(TextAttributes(size: 20).lineDistance == 24)
        #expect(TextAttributes(size: 20, leading: Leading(mode: .fixed, value: 7)).lineDistance == 7)
    }

    @Test func contentConvenience() {
        let content = TextContent("ab\ncd", style: ParagraphStyle(alignment: .right), replica: 3, firstCounter: 10)
        #expect(content.string == "ab\ncd")
        #expect(content.scalarCount == 5)
        #expect(content.paragraphs.count == 2 && content.paragraphs[1].alignment == .right)
        #expect(content.charIDs.first == CharID(counter: 10, replica: 3) && content.charIDs.count == 5)
        #expect(ParagraphStyle(tabs: [TabStop(at: 50), TabStop(.right, at: 20), TabStop(.center, at: 50)]).sortedTabs.map(\.position) == [20, 50, 50])
        #expect(ParagraphStyle(tabs: [TabStop(at: 50), TabStop(.center, at: 50)]).sortedTabs[1].kind == .center, "ties keep sequence order")
    }

    @Test func paragraphSplitting() {
        var bold = Fixture.body
        bold.fontStyle = "Bold"
        let content = TextContent(
            runs: [TextRun("ab", attributes: Fixture.body), TextRun("c\nd", attributes: Fixture.body), TextRun("", attributes: bold), TextRun("e\n", attributes: bold)],
            paragraphs: [ParagraphStyle(alignment: .center)]
        )
        let paragraphs = content.splitParagraphs()
        #expect(paragraphs.count == 3)
        #expect(paragraphs[0].key.text == "abc" && paragraphs[0].key.spans == [AttributeSpan(length: 3, attributes: Fixture.body)], "equal neighbours merge")
        #expect(paragraphs[0].key.style.alignment == .center)
        #expect(paragraphs[1].key.style == ParagraphStyle(), "missing styles read as the default")
        #expect(paragraphs[1].key.spans.count == 2 && paragraphs[1].start == 4 && paragraphs[1].length == 2)
        #expect(paragraphs[2].length == 0 && !paragraphs[2].terminated && paragraphs[2].key.terminator == bold)
        #expect(paragraphs[1].terminated)
        let empty = TextContent(runs: []).splitParagraphs()
        #expect(empty.count == 1 && empty[0].length == 0 && empty[0].key.terminator == TextAttributes())
        // Keys compare by value and flip direction.
        let key = paragraphs[0].key
        #expect(key.with(vertical: false) == key)
        let vertical = key.with(vertical: true)
        #expect(vertical != key && vertical.with(vertical: false) == key)
        #expect(Set([key, vertical, key.with(vertical: true)]).count == 2)
    }

    @Test func fontsFromAttributes() {
        let resolver = FontResolver.shared
        let plain = resolver.font(for: TextAttributes())
        #expect(CTFontCopyFamilyName(plain) as String == "Helvetica")
        #expect(resolver.font(for: TextAttributes()) === plain, "cached")
        let bold = resolver.font(for: TextAttributes(fontFamily: "Helvetica", fontStyle: "Bold"))
        #expect(CTFontCopyPostScriptName(bold) as String == "Helvetica-Bold")
        let heavy = resolver.font(for: TextAttributes(fontFamily: "Skia", axes: ["wght": 1.8, "bad": 3]))
        let variation = CTFontCopyVariation(heavy) as? [NSNumber: NSNumber]
        #expect((variation?[NSNumber(value: fourCharCode("wght")!)]?.doubleValue ?? 0) > 1.5)
        let small = resolver.font(for: TextAttributes(fontFamily: "Baskerville", smallCaps: true, features: ["liga": .off, "onum": .default, "dlig": .on]))
        let settings = CTFontDescriptorCopyAttribute(CTFontCopyFontDescriptor(small), kCTFontFeatureSettingsAttribute) as? [[String: Any]] ?? []
        #expect(settings.count >= 2, "features reach the descriptor; default writes nothing")
        let wide = resolver.font(for: TextAttributes(horizontalScale: 150))
        #expect(CTFontGetMatrix(wide).a == 1.5)
        #expect(CTFontGetMatrix(resolver.font(for: TextAttributes(horizontalScale: 0))).a == 1, "a non-positive scale reads as 100%")
        #expect(fourCharCode("wght") == 0x7767_6874)
        #expect(fourCharCode("wgh") == nil && fourCharCode("wghté") == nil && fourCharCode("wgé") == nil)
        // Small caps and languages reach the shaping.
        var caps = TextAttributes(fontFamily: "Baskerville", size: 20)
        let normal = Fixture.layout("abc", attributes: caps, in: [Fixture.block()]).glyphs().map(\.glyph)
        caps.smallCaps = true
        caps.language = "en"
        #expect(Fixture.layout("abc", attributes: caps, in: [Fixture.block()]).glyphs().map(\.glyph) != normal)
    }

    @Test func layoutAPICorners() {
        let layout = Fixture.layout("hello\nworld", in: [Fixture.block(), .path(PathText(contour: Contour(polygon: [.zero, Point(x: 100, y: 0)], closed: false)))])
        #expect(layout.lineCount(inContainer: 0) == 2 && layout.lineCount(inContainer: 1) == 0)
        #expect(layout.displayItems(forContainer: 5).isEmpty)
        #expect(layout.displayItems(forContainer: 1).isEmpty, "a path with no text draws nothing")
        #expect(layout.glyphs(inContainer: 1).isEmpty)
        #expect(layout.charID(at: -1) == nil)
        let items = layout.displayItems(forContainer: 0)
        #expect(items.count == 2)
        if case .text(let run) = items[0] {
            #expect(run.text == "hello" && run.glyphRun?.glyphs.count == 5 && run.color == .black)
            #expect(run.bounds.minX >= 0 && run.bounds.maxY <= layout.lineOrigins[0].y + 0.5)
        } else {
            Issue.record("expected a text run")
        }
        let glyph = layout.glyphs()[0]
        #expect(glyph.origin == Point(x: glyph.transform.tx, y: glyph.transform.ty))
    }

    @Test func linesOfControlsAndOverfullLines() {
        // A line holding only a column break draws nothing.
        var columns = TextBlock(width: 200, height: 100)
        columns.columns = ColumnsRows(columns: 2)
        let broken = Fixture.layout("\u{000C}next", in: [.block(columns)])
        #expect(broken.lineCount == 2 && broken.glyphs().count == 4)
        // A justified line narrower than one glyph is overfull: nothing to spread.
        let overfull = Fixture.layout("WW", style: ParagraphStyle(alignment: .justified), in: [Fixture.block(width: 5)])
        #expect(overfull.lineCount == 2)
        // A justified line ending in a tab has nothing after it to spread.
        let tabbed = Fixture.layout("Name\tIncomprehensibilities", style: ParagraphStyle(alignment: .justified, tabs: [TabStop(at: 40)]), in: [Fixture.block(width: 100)])
        #expect(tabbed.lineRanges[0] == 0..<5)
        // Auto width measures every line of a paragraph with column breaks.
        let auto = Fixture.layout("a\u{000C}a much longer line", in: [Fixture.block(width: 10) { $0.autoWidth = true }])
        #expect(auto.sizes[0].width > 60)
        // A closed path whose top run takes everything leaves nothing for the bottom.
        let single = Fixture.layout("top", in: [.path(PathText(contour: PathTextTests.circle))])
        #expect(single.lineCount == 1 && !single.overflows)
        // A closed polygon whose end does not meet its start is closed for arc length too.
        let triangle = Contour(polygon: [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 50, y: 80)], closed: true)
        var open = triangle
        open.segments.removeLast()
        #expect(approx(ArcLength(open).total, ArcLength(triangle).total, 1e-6))
        let inside = Fixture.layout("in", in: [.path(PathText(contour: open, mode: .inside))])
        #expect(inside.lineCount == 1)
    }

    @Test func rulesOnlyWhereTheirParagraphStartsOrEnds() {
        let long = Fixture.lorem
        let stroke = RuleStroke()
        var columns = TextBlock(width: 300, height: 50, ruleStroke: stroke)
        columns.columns = ColumnsRows(columns: 2, columnSpacing: 10)
        for above in [false, true] {
            let content = TextContent(runs: [TextRun(long, attributes: Fixture.body)], paragraphs: [ParagraphStyle(rule: ParagraphRule(mode: .centered, above: above))])
            let layout = TextLayoutEngine().layout(content, in: [.block(columns), Fixture.block(width: 145, height: 200) { $0.ruleStroke = stroke }])
            let first = layout.displayItems(forContainer: 0).filter { if case .stroke = $0 { return true } else { return false } }
            let second = layout.displayItems(forContainer: 1).filter { if case .stroke = $0 { return true } else { return false } }
            #expect(first.count == (above ? 1 : 0) && second.count == (above ? 0 : 1))
        }
    }
}
