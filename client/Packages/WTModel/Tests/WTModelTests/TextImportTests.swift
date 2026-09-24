import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// TYPE-008 text file import into the document (importing-text.adoc).
@Suite struct TextImportTests {
    static let rich = ExportStory(paragraphs: [
        ExportParagraph([
            ExportTextRun("Heading ", attributes: ExportTextAttributes(fontFamily: "Times", size: 20, bold: true)),
            ExportTextRun("text", attributes: ExportTextAttributes(fontFamily: "Times", size: 20, italic: true, color: Color(red: 1, green: 0, blue: 0))),
        ], style: ExportParagraphStyle(alignment: .center, spaceAfter: 6, styleName: "Title")),
        ExportParagraph([
            ExportTextRun("body ", attributes: ExportTextAttributes(underline: true)),
            ExportTextRun("CAPS", attributes: ExportTextAttributes(smallCaps: true, styleName: "Emphasis")),
            ExportTextRun(" x", attributes: ExportTextAttributes(strikethrough: true, baselineShift: 2, horizontalScale: 0.9, tracking: 50)),
        ], style: ExportParagraphStyle(leftIndent: 12, rightIndent: 6, firstLineIndent: 4, spaceBefore: 3, lineSpacing: .multiple(1.5),
                                       tabStops: [ExportTabStop(position: 36, alignment: .decimal, leader: .hyphens)], keepWithNext: true)),
        ExportParagraph([ExportTextRun("last", attributes: ExportTextAttributes(fontFamily: "Courier"))],
                        style: ExportParagraphStyle(lineSpacing: .exactly(14), styleName: "Title")),
    ])

    static func importRich(_ replica: inout Replica) throws -> OpID {
        let file = try TextImporter.read(RTFExporter.rtf([rich]), format: .rtf)
        let change = try #require(try replica.perform(ImportText(file, frame: .point(Point(x: 10, y: 20)))))
        #expect(change.label == "Import text")
        return try #require(change.createdObjects.first { replica.state.store.kind($0) == TextFields.kind })
    }

    @Test func aRichFileBecomesATextBlockWithMarksRegistersAndStyles() throws {
        var a = Replica(1)
        let node = try Self.importRich(&a)
        let text = TextFixture.text(a, node)
        #expect(text.string == "Heading text\nbody CAPS x\nlast")
        #expect(text.props.block.autoWidth && text.props.common.transform.tx == 10)
        let paragraphs = text.paragraphs
        #expect(paragraphs[0].props.alignment == .center && paragraphs[0].props.spaceBelow == 6)
        #expect(paragraphs[1].props.leftIndent == 12 && paragraphs[1].props.keepWithNext)
        #expect(paragraphs[1].props.tabs.map(\.leader) == ["-"] && paragraphs[1].props.tabs.first?.kind == .decimal)
        // The styles the file names were created, once each; both Title paragraphs reference one.
        let resolver = a.state.textStyles
        let title = try #require(resolver.styles(.paragraph).first { $0.name == "Title" })
        #expect(resolver.styles(.character).map(\.name) == ["Emphasis"])
        #expect(resolver.paragraphStyle(paragraphs[0].props).style == title.id)
        #expect(resolver.paragraphStyle(paragraphs[2].props).style == title.id)
        // Created with no settings: the registers decide the look.
        #expect(title.attrs == Wiretuner_Doc_V1_TextStyleAttrs())
        // Marks.
        func values(_ offset: Int) -> [Wiretuner_Doc_V1_TextMarkValue] { text.values(at: offset) }
        #expect(values(0).contains(.with { $0.fontStyle = "Bold" }) && values(0).contains(.with { $0.size = 20 }))
        #expect(values(8).contains { if case .fill? = $0.value { true } else { false } })
        #expect(values(13).contains { if case .effect(let e)? = $0.value { if case .underline? = e.effect { true } else { false } } else { false } })
        #expect(values(18).contains(.with { $0.case = .smallCaps }))
        #expect(values(18).contains { if case .style? = $0.value { true } else { false } })
        #expect(values(23).contains(.with { $0.horizontalScale = 90 }) && values(23).contains(.with { $0.rangeKerning = 5 }))
        #expect(values(13).contains(.with { $0.leading = .with { $0.mode = .percent; $0.value = 180 } }))
        #expect(values(25).contains(.with { $0.leading = .with { $0.mode = .fixed; $0.value = 14 } }))
        // An existing style of the name is used, not duplicated.
        let again = try Self.importRich(&a)
        #expect(a.state.textStyles.styles(.paragraph).filter { $0.name == "Title" }.count == 1)
        #expect(a.state.textStyles.paragraphStyle(TextFixture.text(a, again).paragraphs[0].props).style == title.id)
    }

    @Test func importThenExportRoundTripsTheMappedSet() throws {
        var a = Replica(1)
        let node = try Self.importRich(&a)
        let imported = try TextImporter.read(RTFExporter.rtf([Self.rich]), format: .rtf)
        let story = TextAttributeMapping.story(TextFixture.text(a, node), styles: a.state.textStyles)
        let back = try TextImporter.read(RTFExporter.rtf([story]), format: .rtf)
        #expect(back.paragraphs.count == imported.paragraphs.count)
        for (lhs, rhs) in zip(back.paragraphs, imported.paragraphs) {
            #expect(lhs.text == rhs.text)
            #expect(lhs.style.alignment == rhs.style.alignment && lhs.style.leftIndent == rhs.style.leftIndent && lhs.style.rightIndent == rhs.style.rightIndent)
            #expect(lhs.style.firstLineIndent == rhs.style.firstLineIndent && lhs.style.spaceBefore == rhs.style.spaceBefore && lhs.style.spaceAfter == rhs.style.spaceAfter)
            #expect(lhs.style.lineSpacing == rhs.style.lineSpacing && lhs.style.tabStops == rhs.style.tabStops && lhs.style.styleName == rhs.style.styleName)
            #expect(lhs.style.keepWithNext == rhs.style.keepWithNext)
            let left = lhs.runs.map { TextImportComparison($0.attributes) }
            let right = rhs.runs.map { TextImportComparison($0.attributes) }
            #expect(TextImportComparison.merged(left) == TextImportComparison.merged(right))
        }
    }

    @Test func plainTextTakesTheDefaultsAndLongTextIsChunked() throws {
        var a = Replica(1)
        let long = String(repeating: "é", count: 40_000)
        let file = try TextImporter.read(Data("one\n\(long)".utf8), format: .plain)
        let change = try #require(try a.perform(ImportText(file, frame: .area(Rect(x: 0, y: 0, width: 100, height: 50)), defaults: [TextFixture.size(9)])))
        let inserts = change.ops.compactMap { if case .textInsert(let insert)? = $0.op { insert } else { nil } }
        #expect(inserts.count == 2)
        #expect(inserts.allSatisfy { $0.chars.utf8.count <= 65_536 })
        let node = try #require(change.createdObjects.first { a.state.store.kind($0) == TextFields.kind })
        let text = TextFixture.text(a, node)
        #expect(text.length == 4 + 40_000)
        #expect(text.props.block.width == 100 && !text.props.block.autoWidth)
        #expect(text.runs.count == 1 && text.runs[0].values == [TextFixture.size(9)])
        #expect(ImportText.chunks(Array("ab".unicodeScalars)).count == 1)
        // An empty file refuses; a bad frame refuses; an empty text makes an empty block.
        #expect(throws: TextEditError.invalidValue("file")) { try a.perform(ImportText(ImportedTextFile(paragraphs: [], plain: true), frame: .point(.zero))) }
        #expect(throws: TextEditError.invalidValue("frame")) { try a.perform(ImportText(file, frame: .area(Rect(x: 0, y: 0, width: 0, height: 1)))) }
        let empty = try #require(try a.perform(ImportText(ImportedTextFile(paragraphs: [ExportParagraph([])], plain: true), frame: .point(.zero))))
        #expect(!empty.ops.contains { if case .textInsert? = $0.op { true } else { false } })
    }

    @Test func notesAndRTFDPicturesAsInlineGraphics() throws {
        let image = NSImage(size: NSSize(width: 8, height: 6), flipped: false) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let source = NSMutableAttributedString(string: "pic ")
        source.append(NSAttributedString(attachment: attachment))
        let data = try #require(source.rtfd(from: NSRange(location: 0, length: source.length), documentAttributes: [:]))
        let file = try TextImporter.read(data, format: .rtfd)
        var a = Replica(1)
        let command = ImportText(file, frame: .point(.zero))
        #expect(command.blobs.count == 1)
        let change = try #require(try a.perform(command))
        let node = try #require(change.createdObjects.first { a.state.store.kind($0) == TextFields.kind })
        let placements = InlineGraphics.placements(TextFixture.text(a, node))
        #expect(placements.count == 1 && placements[0].offset == 4)
        #expect(a.state.store.placement(placements[0].graphic)?.parent == node)
        #expect(a.state.props(placements[0].graphic).image.pixels.pixelWidth > 0)
        #expect(TextFixture.text(a, node).props.common.note.contains("picture"))
    }

    @Test func theMappingCoversScriptsFacesAndEffects() {
        let superscript = TextAttributeMapping.marks(ExportTextAttributes(size: 10, script: .superscript))
        #expect(superscript.contains(.with { $0.size = 5.8 }) && superscript.contains(.with { $0.baselineShift = 3.3 }))
        let subscriptMarks = TextAttributeMapping.marks(ExportTextAttributes(size: 10, script: .subscript))
        #expect(subscriptMarks.contains(.with { $0.baselineShift = -1.4 }))
        #expect(TextAttributeMapping.face(ExportTextAttributes(bold: true, italic: true)) == "Bold Italic")
        #expect(TextAttributeMapping.face(ExportTextAttributes(italic: true)) == "Italic")
        #expect(TextAttributeMapping.face(ExportTextAttributes(fontFace: "Regular")) == nil)
        #expect(TextAttributeMapping.face(ExportTextAttributes(fontFace: "Condensed Black")) == "Condensed Black")
        #expect(TextAttributeMapping.marks(ExportTextAttributes(language: "fr")).contains(.with { $0.language = "fr" }))
        let back = TextAttributeMapping.attributes([
            .with { $0.fontFamily = "" }, .with { $0.fontStyle = "Oblique" }, .with { $0.size = 0 },
            .with { $0.effect.strikethrough = .init() }, .with { $0.language = "" }, .with { $0.horizontalScale = 0 },
            .with { $0.fill = Appearances.inline(red: 0, green: 1, blue: 0) }, .with { $0.kerning = 3 },
        ])
        #expect(back.italic && back.strikethrough && back.fontFamily == "Helvetica" && back.size == 12 && back.language == nil)
        #expect(back.color.green == 1 && back.horizontalScale == 1)
        let style = TextAttributeMapping.style(.with { $0.alignment = .right; $0.tabs = [.with { $0.kind = .center; $0.leader = "_" }, .with { $0.leader = "." }] },
                                               leading: .with { $0.mode = .extra })
        #expect(style.alignment == .right && style.tabStops.map(\.leader) == [.underline, .dots] && style.lineSpacing == .auto)
        #expect(TextAttributeMapping.style(.with { $0.alignment = .justified }).alignment == .justified)
        #expect(TextAttributeMapping.style(.with { $0.alignment = .center; $0.tabs = [.with { $0.kind = .right }] }).tabStops.first?.alignment == .right)
    }

    @Test func paragraphMappingAndEdgeRuns() throws {
        let mapped = TextAttributeMapping.paragraph(ExportParagraphStyle(alignment: .right, tabStops: [
            ExportTabStop(position: 1, alignment: .center, leader: .dots), ExportTabStop(position: 2, alignment: .right, leader: .underline),
        ]))
        #expect(mapped.props.alignment == .right && mapped.props.tabs.map(\.kind) == [.center, .right] && mapped.props.tabs.map(\.leader) == [".", "_"])
        #expect(TextAttributeMapping.paragraph(ExportParagraphStyle(alignment: .justified)).props.alignment == .justified)
        #expect(TextAttributeMapping.face(ExportTextAttributes(bold: true)) == "Bold")
        let values = TextAttributeMapping.attributes([.with { $0.fontStyle = "" }, .with { $0.fill.none = true }, .with { $0.effect.highlight = .init() },
                                                      .with { $0.language = "de" }])
        #expect(values.fontFace == nil && values.color == .black && !values.underline && !values.strikethrough && values.language == "de")
        // All caps become capitals; an empty run is skipped; an existing unrelated style stays.
        var a = Replica(1)
        try a.perform(CreateTextStyle(.paragraph, name: "Other"))
        let file = ImportedTextFile(paragraphs: [ExportParagraph([ExportTextRun(""), ExportTextRun("loud", attributes: ExportTextAttributes(allCaps: true))],
                                                                 style: ExportParagraphStyle(styleName: "Fresh"))], plain: false)
        let node = try #require(try a.perform(ImportText(file, frame: .point(.zero)))).createdObjects.first { a.state.store.kind($0) == TextFields.kind }
        let text = TextFixture.text(a, try #require(node))
        #expect(text.string == "LOUD")
        #expect(Set(a.state.textStyles.styles(.paragraph).map(\.name)) == ["Other", "Fresh"])
        // The story of a text without styles.
        let story = TextAttributeMapping.story(text)
        guard case .paragraph(let paragraph)? = story.elements.first else { Issue.record("story"); return }
        #expect(paragraph.text == "LOUD" && paragraph.style.styleName == nil)
    }

    // MARK: Merge

    @Test func twoReplicasImportDifferentFilesConcurrently() throws {
        var pair = Pair()
        let first = try TextImporter.read(RTFExporter.rtf([Self.rich]), format: .rtf)
        let second = try TextImporter.read(Data("plain\nlines".utf8), format: .plain)
        let a = try #require(try pair.a.perform(ImportText(first, frame: .point(.zero)))).createdObjects.first { pair.a.state.store.kind($0) == TextFields.kind }
        let b = try #require(try pair.b.perform(ImportText(second, frame: .point(Point(x: 50, y: 50)), defaults: [TextFixture.size(8)])))
            .createdObjects.first { pair.b.state.store.kind($0) == TextFields.kind }
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        for replica in [pair.a, pair.b] {
            #expect(TextFixture.text(replica, try #require(a)).string == "Heading text\nbody CAPS x\nlast")
            #expect(TextFixture.text(replica, try #require(b)).string == "plain\nlines")
            #expect(TextFixture.sizes(TextFixture.text(replica, try #require(b))).allSatisfy { $0 == 8 })
            #expect(TextFixture.text(replica, try #require(a)).values(at: 0).contains(.with { $0.fontStyle = "Bold" }))
        }
    }
}

/// The mapped set of run attributes that survives an RTF round trip through the document.
struct TextImportComparison: Equatable {
    var family: String
    var size: Double
    var bold: Bool
    var italic: Bool
    var color: [Int]
    var underline: Bool
    var strikethrough: Bool
    var shift: Double
    var scale: Double
    var tracking: Double
    var smallCaps: Bool
    var style: String?

    init(_ a: ExportTextAttributes) {
        family = a.fontFamily
        size = a.size
        bold = a.bold
        italic = a.italic
        color = [a.color.red, a.color.green, a.color.blue].map { Int(($0 * 255).rounded()) }
        underline = a.underline
        strikethrough = a.strikethrough
        shift = a.baselineShift
        scale = a.horizontalScale
        tracking = a.tracking
        smallCaps = a.smallCaps
        style = a.styleName
    }

    static func merged(_ runs: [TextImportComparison]) -> [TextImportComparison] {
        var result: [TextImportComparison] = []
        for run in runs where result.last != run { result.append(run) }
        return result
    }
}
