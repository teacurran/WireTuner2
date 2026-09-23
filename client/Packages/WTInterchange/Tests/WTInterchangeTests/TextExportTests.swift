// IO-030: RTF and plain-text export.  Order: linked chains once at their head, blocks by page then
// stacking order; RTF read back through AppKit's RTF reader for the round trip of formatting.

import AppKit
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct TextExportTests {
    static func story(_ texts: String...) -> ExportStory {
        ExportStory(paragraphs: texts.map { ExportParagraph([ExportTextRun($0)]) })
    }

    static func scene(_ blocks: [ExportTextBlock]) -> ExportScene {
        ExportScene(name: "Text", pages: [Corpus.page([]), Corpus.page([]), Corpus.page([])], text: blocks)
    }

    /// Three pages: unlinked blocks, a chain crossing pages, and a loop without a head.
    static let blocks: [ExportTextBlock] = {
        let n = (1...9).map { Corpus.node(UInt64($0)) }
        return [
            ExportTextBlock(node: n[0], page: 0, stackingOrder: 2, story: story("A")),
            ExportTextBlock(node: n[1], page: 0, stackingOrder: 1, next: n[2], story: story("B1", "B2")),
            ExportTextBlock(node: n[2], page: 2, stackingOrder: 0, next: n[3], story: nil),
            ExportTextBlock(node: n[3], page: 1, stackingOrder: 5, story: story("B3")),
            ExportTextBlock(node: n[4], page: 0, stackingOrder: 0, story: story("E")),
            ExportTextBlock(node: n[5], page: 1, stackingOrder: 0, story: story("F")),
            ExportTextBlock(node: n[6], page: 2, stackingOrder: 3, next: n[7], story: story("G")),
            ExportTextBlock(node: n[7], page: 2, stackingOrder: 1, next: n[6], story: story("H")),
            ExportTextBlock(node: n[8], page: 2, stackingOrder: 9, story: nil),
        ]
    }()

    @Test func storiesExportInTheSpecifiedOrder() throws {
        let text = PlainTextWriter.string(TextStories.ordered(Self.blocks))
        #expect(text == "E\n\nB1\nB2\nB3\n\nA\n\nF\n\nH\nG")
        let data = try PlainTextExporter().data(scene: Self.scene(Self.blocks), options: PlainTextOptions(crlf: true))
        #expect(String(decoding: data, as: UTF8.self).hasPrefix("E\r\n\r\nB1\r\nB2"))
        let bom = try PlainTextExporter().data(scene: Self.scene(Self.blocks), options: PlainTextOptions(encoding: .utf8BOM))
        #expect(bom.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        let utf16 = try PlainTextExporter().data(scene: Self.scene(Self.blocks), options: PlainTextOptions(encoding: .utf16))
        #expect(utf16.prefix(4) == Data([0xFF, 0xFE, 0x45, 0x00]))
        #expect(String(data: utf16, encoding: .utf16) == text)
    }

    static let formatted: ExportStory = {
        var bold = ExportTextAttributes(fontFamily: "Helvetica", size: 14, bold: true, color: Color(red: 0.8, green: 0.1, blue: 0.1), underline: true, language: "en-US", styleName: "Strong")
        bold.tracking = 100
        let sup = ExportTextAttributes(size: 12, italic: true, strikethrough: true, script: .superscript, horizontalScale: 1.5, smallCaps: true)
        let sub = ExportTextAttributes(size: 12, script: .subscript, baselineShift: -2, allCaps: true, language: "xx-invalid")
        let shifted = ExportTextAttributes(fontFamily: "Times New Roman", size: 12, baselineShift: 3)
        let heading = ExportParagraphStyle(alignment: .center, spaceBefore: 6, spaceAfter: 12, lineSpacing: .multiple(1.5), keepWithNext: true, styleName: "Heading")
        let body = ExportParagraphStyle(alignment: .justified, leftIndent: 36, rightIndent: 18, firstLineIndent: -12, lineSpacing: .exactly(16), tabStops: [
            ExportTabStop(position: 72), ExportTabStop(position: 144, alignment: .right, leader: .dots), ExportTabStop(position: 216, alignment: .center, leader: .hyphens), ExportTabStop(position: 288, alignment: .decimal, leader: .underline),
        ], hyphenate: false)
        let right = ExportParagraphStyle(alignment: .right)
        let table = ExportTable(columnWidths: [100, 150], rows: [
            [[ExportParagraph([ExportTextRun("Cell 1")])], [ExportParagraph([ExportTextRun("Cell 2")]), ExportParagraph([ExportTextRun("more")])]],
            [[], [ExportParagraph([ExportTextRun("Cell 4")])]],
        ])
        return ExportStory([
            .paragraph(ExportParagraph([ExportTextRun("Title {with} \\ braces ✓", attributes: bold)], style: heading)),
            .paragraph(ExportParagraph([ExportTextRun("E=mc"), ExportTextRun("2", attributes: sup), ExportTextRun(" H"), ExportTextRun("2", attributes: sub), ExportTextRun("O\tshift", attributes: shifted), ExportTextRun("\u{2028}next 😀")], style: body)),
            .table(table),
            .paragraph(ExportParagraph([ExportTextRun("end")], style: right)),
        ])
    }()

    @Test func rtfRoundTripsThroughAppKit() throws {
        let block = ExportTextBlock(node: Corpus.node(1), page: 0, stackingOrder: 0, story: Self.formatted)
        let result = try RTFExporter().data(scene: Self.scene([block]), options: RTFOptions())
        let rtf = String(decoding: result.data, as: UTF8.self)
        #expect(rtf.hasPrefix("{\\rtf1\\ansi"))
        #expect(rtf.contains("{\\s1\\sbasedon0\\snext1 Heading;}"))
        #expect(rtf.contains("{\\*\\cs100\\additive Strong;}"))
        #expect(rtf.contains("\\trowd"))
        #expect(rtf.contains("\\tqr\\tldot\\tx2880"))
        #expect(rtf.contains("\\lang1033"))
        let string = try NSAttributedString(data: result.data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let text = string.string
        #expect(text.contains("Title {with} \\ braces ✓"))
        #expect(text.contains("next 😀"))
        #expect(text.contains("Cell 1") && text.contains("Cell 4"))
        func attributes(of needle: String, offset: Int = 0) -> [NSAttributedString.Key: Any] {
            let range = (text as NSString).range(of: needle)
            return string.attributes(at: range.location + offset, effectiveRange: nil)
        }
        let title = attributes(of: "Title")
        let font = try #require(title[.font] as? NSFont)
        #expect(font.pointSize == 14)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        #expect((title[.underlineStyle] as? Int) == 1)
        #expect(abs(((title[.kern] as? Double) ?? 0) - 1.4) < 0.06)
        let color = try #require((title[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - 0.8) < 0.01)
        let heading = try #require(title[.paragraphStyle] as? NSParagraphStyle)
        #expect(heading.alignment == .center)
        #expect(heading.paragraphSpacing == 12 && heading.paragraphSpacingBefore == 6)
        let superscript = attributes(of: "2 H", offset: 0)
        #expect((superscript[.superscript] as? Int) == 1)
        #expect((superscript[.strikethroughStyle] as? Int) == 1)
        let subscriptRange = (text as NSString).range(of: "2O")
        let subscripted = string.attributes(at: subscriptRange.location, effectiveRange: nil)
        #expect((subscripted[.superscript] as? Int) == -1)
        let shifted = attributes(of: "O\t")
        #expect((shifted[.baselineOffset] as? Double) == 3)
        #expect((shifted[.font] as? NSFont)?.familyName == "Times New Roman")
        let body = try #require(attributes(of: "E=mc")[.paragraphStyle] as? NSParagraphStyle)
        #expect(body.alignment == .justified)
        #expect(body.headIndent == 36 && body.firstLineHeadIndent == 24)
        // AppKit measures the right indent from the left margin of its default 432 pt column.
        #expect(abs(body.tailIndent - (432 - 18)) < 0.01)
        #expect(body.maximumLineHeight == 16)
        #expect(body.tabStops.map(\.location) == [72, 144, 216, 288])
        #expect(body.tabStops[1].alignment == .right)
    }

    @Test func inlineGraphicsArePNGOrBullets() throws {
        let graphic = Corpus.image(width: 8, height: 8)
        let story = ExportStory(paragraphs: [ExportParagraph([ExportTextRun("A "), ExportTextRun(graphic: graphic, size: CGSize(width: 12, height: 12)), ExportTextRun(" B")])])
        let block = ExportTextBlock(node: Corpus.node(1), page: 0, stackingOrder: 0, story: story)
        let embedded = try RTFExporter().data(scene: Self.scene([block]), options: RTFOptions())
        let rtf = String(decoding: embedded.data, as: UTF8.self)
        #expect(rtf.contains("\\pict\\pngblip\\picw8\\pich8\\picwgoal240\\pichgoal240"))
        #expect(rtf.contains("89504e47"))
        #expect(embedded.notes == ["1 inline graphic embedded as PNG"])
        let bullet = try RTFExporter().data(scene: Self.scene([block]), options: RTFOptions(embedInlineGraphics: false))
        #expect(String(decoding: bullet.data, as: UTF8.self).contains("\\u8226?"))
        let plain = try PlainTextExporter().data(scene: Self.scene([block]), options: PlainTextOptions())
        #expect(String(decoding: plain, as: UTF8.self) == "A \u{2022} B")
        let flavors = TextPasteboard.flavors([block])
        #expect(flavors.map(\.type) == ["public.rtf", "public.utf8-plain-text"])
        #expect(String(decoding: flavors[1].data, as: UTF8.self) == "A \u{2022} B")
    }

    @Test func pagesBreakAndFilesAreWritten() throws {
        let rtf = try RTFExporter().data(scene: Self.scene(Self.blocks), options: RTFOptions())
        let text = String(decoding: rtf.data, as: UTF8.self)
        #expect(text.components(separatedBy: "\\page").count - 1 == 2)
        let directory = Corpus.directory()
        let summary = try RTFExporter().export(scene: Self.scene(Self.blocks), options: RTFOptions(), to: ExportDestination(url: directory.appendingPathComponent("story.txt")))
        #expect(summary.files.map(\.lastPathComponent) == ["story.rtf"])
        let plain = try PlainTextExporter().export(scene: Self.scene(Self.blocks), options: PlainTextOptions(), to: ExportDestination(url: directory.appendingPathComponent("story")))
        #expect(plain.files.map(\.lastPathComponent) == ["story.txt"])
        #expect(throws: ExportError.nothingToExport) { try RTFExporter().data(scene: Self.scene([]), options: RTFOptions()) }
        #expect(throws: ExportError.nothingToExport) { try PlainTextExporter().data(scene: Self.scene([]), options: PlainTextOptions()) }
        #expect(throws: ExportError.wrongOptions(format: .rtf)) { try RTFExporter().export(scene: Self.scene(Self.blocks), options: PlainTextOptions(), to: ExportDestination(url: directory.appendingPathComponent("x"))) }
        #expect(throws: ExportError.wrongOptions(format: .text)) { try PlainTextExporter().export(scene: Self.scene(Self.blocks), options: RTFOptions(), to: ExportDestination(url: directory.appendingPathComponent("x"))) }
        #expect(throws: ExportError.self) { try RTFExporter().export(scene: Self.scene(Self.blocks), options: RTFOptions(), to: ExportDestination(url: URL(fileURLWithPath: "/nonexistent-folder/x.rtf"))) }
        #expect(RTFExporter().optionsType is RTFOptions.Type && PlainTextExporter().optionsType is PlainTextOptions.Type)
        #expect(RTFExporter().capabilities == ExportFormat.rtf.capabilities && PlainTextExporter().capabilities == ExportFormat.text.capabilities)
        #expect(RTFOptions.defaults == RTFOptions() && PlainTextOptions.defaults == PlainTextOptions())
        // A table in plain text: cells by tabs, rows by lines.
        let table = ExportTextBlock(node: Corpus.node(1), page: 0, stackingOrder: 0, story: Self.formatted)
        let tabbed = PlainTextWriter.string(TextStories.ordered([table]))
        #expect(tabbed.contains("Cell 1\tCell 2 more\n\tCell 4"))
        #expect(RTFWriter.escape("a\u{1}b") == "ab")
    }
}
