import AppKit
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

/// TYPE-008 text file import (importing-text.adoc).
@Suite struct TextImportTests {
    /// The mapped set of a run's attributes that survives RTF: what the corpus compares.
    struct Mapped: Equatable {
        var family: String
        var size: Double
        var bold: Bool
        var italic: Bool
        var red: Int, green: Int, blue: Int
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
            (red, green, blue) = (Int((a.color.red * 255).rounded()), Int((a.color.green * 255).rounded()), Int((a.color.blue * 255).rounded()))
            underline = a.underline
            strikethrough = a.strikethrough
            shift = a.baselineShift
            scale = a.horizontalScale
            tracking = a.tracking
            smallCaps = a.smallCaps
            style = a.styleName
        }
    }

    struct MappedParagraph: Equatable {
        var text: String
        var alignment: ExportParagraphStyle.Alignment
        var indents: [Double]
        var spacing: [Double]
        var line: ExportParagraphStyle.LineSpacing
        var tabs: [ExportTabStop]
        var keep: Bool
        var style: String?
        var runs: [Mapped]

        init(_ p: ExportParagraph) {
            text = p.text
            alignment = p.style.alignment
            indents = [p.style.leftIndent, p.style.rightIndent, p.style.firstLineIndent]
            spacing = [p.style.spaceBefore, p.style.spaceAfter]
            line = p.style.lineSpacing
            tabs = p.style.tabStops
            keep = p.style.keepWithNext
            style = p.style.styleName
            // Adjacent runs with the same mapped attributes are one.
            var merged: [Mapped] = []
            for run in p.runs where !run.text.isEmpty {
                let mapped = Mapped(run.attributes)
                if merged.last != mapped { merged.append(mapped) }
            }
            runs = merged
        }
    }

    /// The corpus: stories covering the mapped set.
    static var corpus: [ExportStory] {
        let red = Color(red: 0.8, green: 0.1, blue: 0.2)
        return [
            ExportStory(paragraphs: [ExportParagraph([ExportTextRun("Plain words in Helvetica.")])]),
            ExportStory(paragraphs: [
                ExportParagraph([
                    ExportTextRun("Big ", attributes: ExportTextAttributes(fontFamily: "Times", size: 24)),
                    ExportTextRun("bold", attributes: ExportTextAttributes(fontFamily: "Times", size: 24, bold: true)),
                    ExportTextRun(" italic", attributes: ExportTextAttributes(fontFamily: "Times", size: 24, italic: true)),
                ], style: ExportParagraphStyle(alignment: .center, spaceBefore: 6, spaceAfter: 12, styleName: "Heading")),
                ExportParagraph([
                    ExportTextRun("red ", attributes: ExportTextAttributes(color: red)),
                    ExportTextRun("under", attributes: ExportTextAttributes(underline: true)),
                    ExportTextRun(" struck", attributes: ExportTextAttributes(strikethrough: true)),
                    ExportTextRun(" up", attributes: ExportTextAttributes(baselineShift: 3)),
                    ExportTextRun(" small", attributes: ExportTextAttributes(smallCaps: true)),
                    ExportTextRun(" wide", attributes: ExportTextAttributes(tracking: 100)),
                    ExportTextRun(" narrow", attributes: ExportTextAttributes(horizontalScale: 0.8)),
                    ExportTextRun(" Code", attributes: ExportTextAttributes(fontFamily: "Courier", styleName: "Code")),
                ], style: ExportParagraphStyle(alignment: .justified, leftIndent: 18, rightIndent: 9, firstLineIndent: -9,
                                               lineSpacing: .multiple(1.5), keepWithNext: true)),
                ExportParagraph([ExportTextRun("a\tb\tc")], style: ExportParagraphStyle(
                    lineSpacing: .exactly(16),
                    tabStops: [ExportTabStop(position: 72, alignment: .right, leader: .dots), ExportTabStop(position: 144, alignment: .center)],
                    styleName: "Heading")),
            ]),
            ExportStory(paragraphs: [ExportParagraph([ExportTextRun("Unicode: café — “quotes” 日本語 😀")])]),
        ]
    }

    @Test func rtfRoundTripsThroughImportAndExportOnTheMappedSet() throws {
        for story in Self.corpus {
            let first = try TextImporter.read(RTFExporter.rtf([story]), format: .rtf)
            #expect(!first.plain && first.notes.isEmpty)
            let expected = story.elements.compactMap { if case .paragraph(let p) = $0 { MappedParagraph(p) } else { nil } }
            #expect(first.paragraphs.map(MappedParagraph.init) == expected)
            let second = try TextImporter.read(RTFExporter.rtf([ExportStory(paragraphs: first.paragraphs)]), format: .rtf)
            #expect(second.paragraphs.map(MappedParagraph.init) == expected)
        }
    }

    @Test func aWindows1252FileWithoutABOMImportsWithTheRightCharacters() throws {
        let bytes: [UInt8] = Array("Caf".utf8) + [0xE9, 0x20, 0x93] + Array("quoted".utf8) + [0x94, 0x20, 0x80, 0x20, 0x96, 0x0D, 0x0A] + Array("na".utf8) + [0xEF, 0x76, 0x65]
        let file = try TextImporter.read(Data(bytes), format: .plain)
        #expect(file.string == "Café “quoted” € –\nnaïve")
        #expect(file.encoding == .windowsCP1252)
        #expect(file.plain && file.notes.first?.contains("detected") == true)
        // The Encoding option overrides the guess.
        let forced = try TextImporter.read(Data(bytes), format: .plain, options: TextImportOptions(encoding: .macOSRoman))
        #expect(forced.encoding == .macOSRoman && forced.notes.isEmpty && forced.string != file.string)
        #expect(throws: TextImportError.undecodable(.utf8)) { try TextImporter.read(Data(bytes), format: .plain, options: TextImportOptions(encoding: .utf8)) }
    }

    @Test func byteOrderMarksUTF8AndMarkdown() throws {
        #expect(try TextImporter.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hé".utf8)) == ("hé", .utf8, false))
        var utf16 = Data([0xFF, 0xFE])
        for unit in "hé\r".utf16 { utf16.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
        let decoded = try TextImporter.decode(utf16)
        #expect(decoded.string == "hé\r" && decoded.encoding == .utf16)
        #expect(try TextImporter.decode(Data("plain ✓".utf8)) == ("plain ✓", .utf8, false))
        let markdown = try TextImporter.read(Data("# Title\r\rSome *text*".utf8), format: .markdown)
        #expect(markdown.paragraphs.map(\.text) == ["# Title", "", "Some *text*"])
        #expect(markdown.paragraphs[1].runs.isEmpty)
        #expect(TextFileFormat(pathExtension: "MD") == .markdown && TextFileFormat(pathExtension: "txt") == .plain)
        #expect(TextFileFormat(pathExtension: "rtfd") == .rtfd && TextFileFormat(pathExtension: "rtf") == .rtf && TextFileFormat(pathExtension: "doc") == nil)
        #expect(TextFileFormat.markdown.isPlain && !TextFileFormat.rtf.isPlain)
        #expect(TextImporter.strippingBOM("\u{FEFF}x") == "x")
    }

    @Test func handWrittenRTFWithEscapesAndDestinations() throws {
        let rtf = #"{\rtf1\ansi\ansicpg1252\uc1{\fonttbl{\f0\fnil\fcharset0 Helvetica;}}{\*\generator Test;}{\info{\title Ignored}}{\stylesheet{\s0 Normal;}{\s3 Quote;}{\*\cs7\additive Em;}}\pard\s3\qr\f0\fs24 caf\'e9 "# + "\\" + #"u8212? {\cs7\caps big} \{x\}\par\pard\keepn\hyphpar0 end\line two\par}"#
        let file = try TextImporter.read(Data(rtf.utf8), format: .rtf)
        #expect(file.notes.isEmpty)
        #expect(file.paragraphs.count == 2)
        #expect(file.paragraphs[0].text == "café — big {x}")
        #expect(file.paragraphs[0].style.styleName == "Quote" && file.paragraphs[0].style.alignment == .right)
        let big = try #require(file.paragraphs[0].runs.first { $0.text.contains("big") })
        #expect(big.attributes.allCaps && big.attributes.styleName == "Em")
        #expect(file.paragraphs[1].style.keepWithNext && !file.paragraphs[1].style.hyphenate && file.paragraphs[1].style.styleName == nil)
        #expect(throws: TextImportError.unreadable(.rtf)) { try TextImporter.read(Data([0x00, 0x01]), format: .rtf) }
    }

    @Test func scannerCornersLeadersScalesAndStyleNameEscapes() throws {
        let rtf = #"{\rtf1\ansi\ansicpg1252\uc1{\fonttbl{\f0\fnil\fcharset0 Helvetica;}}{\stylesheet{\s0 Normal;}{\s2 Caf\'e9 \{x\};}}"#
            + #"\pard\s2\tlhyph\tx720\tlul\tx1440\f0 a\tab b\tab c\:{\charscalex80 n}{\charscalex100 m}\uc0 \u233 z\-y\"# + "\n" + #"last\par}"#
        let file = try TextImporter.read(Data(rtf.utf8), format: .rtf)
        #expect(file.notes.isEmpty)
        let paragraph = try #require(file.paragraphs.first)
        #expect(paragraph.style.styleName == "Caf? {x}")
        #expect(paragraph.style.tabStops.map(\.leader) == [.hyphens, .underline])
        let narrow = try #require(paragraph.runs.first { $0.text.contains("n") })
        #expect(narrow.attributes.horizontalScale == 0.8)
        #expect(paragraph.runs.first { $0.text.contains("m") }?.attributes.horizontalScale == 1)
        #expect(paragraph.text.hasSuffix("zy") && file.paragraphs.last?.text == "last")
    }

    @Test func picturesFromFileWrappersWithTheirBounds() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.green.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let text = NSMutableAttributedString(string: "x")
        for _ in 0..<2 {
            let wrapper = FileWrapper(regularFileWithContents: png)
            wrapper.preferredFilename = "p.png"
            let attachment = NSTextAttachment(fileWrapper: wrapper)
            attachment.bounds = CGRect(x: 0, y: 0, width: 20, height: 10)
            text.append(NSAttributedString(attachment: attachment))
        }
        let data = try #require(text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
        let file = try TextImporter.read(data, format: .rtfd)
        #expect(file.pictures.count == 2 && file.pictures.values.allSatisfy { $0.uti == "public.png" })
        #expect(file.notes.contains("2 pictures placed as inline graphics"))
        #expect(file.paragraphs[0].runs.contains { $0.graphic != nil && $0.graphicSize.width > 0 })
    }

    @Test func aScanThatDoesNotMatchIsLeftOutWithANote() throws {
        // A table: the attributed string's characters and the scan's counts differ.
        let rtf = #"{\rtf1\ansi{\fonttbl{\f0 Helvetica;}}\trowd\cellx1000\cellx2000\intbl a\cell b\cell\row\pard after\par}"#
        let file = try TextImporter.read(Data(rtf.utf8), format: .rtf)
        #expect(file.string.contains("after"))
        let scan = try #require(RTFScan(Data(rtf.utf8)))
        let attributed = try NSAttributedString(data: Data(rtf.utf8), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        if scan.length != attributed.length {
            #expect(file.notes.contains { $0.contains("could not be matched") })
        }
        #expect(scan.characterStyle(at: 999) == nil && !scan.smallCaps(at: -1) && !scan.allCaps(at: 999))
        var style = ExportParagraphStyle()
        scan.apply(to: &style, paragraph: 99)
        #expect(style == ExportParagraphStyle())
    }

    @Test func rtfdPicturesBecomeInlineGraphicRuns() throws {
        let image = NSImage(size: NSSize(width: 8, height: 6), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let text = NSMutableAttributedString(string: "pic ")
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: " end"))
        let data = try #require(text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
        let file = try TextImporter.read(data, format: .rtfd)
        #expect(file.paragraphs.count == 1)
        #expect(file.pictures.count == 1 && file.pictures[4] != nil)
        #expect(file.paragraphs[0].runs.contains { $0.graphic != nil && $0.graphicSize.width > 0 })
        #expect(file.notes.contains { $0.contains("picture") })
        // Through a package on disk.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("typm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wrapper = try #require(text.rtfdFileWrapper(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
        let package = directory.appendingPathComponent("doc.rtfd")
        try wrapper.write(to: package, options: .atomic, originalContentsURL: nil)
        #expect(try TextImporter.read(url: package).pictures.count == 1)
        let plain = directory.appendingPathComponent("doc.txt")
        try Data("one\ntwo".utf8).write(to: plain)
        #expect(try TextImporter.read(url: plain).paragraphs.count == 2)
        #expect(throws: TextImportError.unreadable(.plain)) { try TextImporter.read(url: directory.appendingPathComponent("x.doc")) }
    }

    @Test func attributedAttributesMapBothWays() {
        let font = NSFont(name: "Helvetica-Bold", size: 20)!
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.headIndent = 10
        style.firstLineHeadIndent = 4
        style.tailIndent = -5
        style.minimumLineHeight = 18
        style.maximumLineHeight = 18
        let decimal = NSTextTab(textAlignment: .right, location: 50, options: [.columnTerminators: NSTextTab.columnTerminators(for: .current)])
        style.tabStops = [decimal, NSTextTab(textAlignment: .center, location: 90), NSTextTab(textAlignment: .left, location: 120)]
        let attributes = TextImporter.characterAttributes([.font: font, .foregroundColor: NSColor.blue, .superscript: -1, .kern: 2.0, .expansion: 0.0])
        #expect(attributes.bold && attributes.size == 20 && attributes.script == .subscript && attributes.tracking == 100)
        #expect(attributes.color.blue == 1)
        #expect(TextImporter.characterAttributes([.superscript: 1]).script == .superscript)
        let paragraph = TextImporter.paragraphStyle(style)
        #expect(paragraph.alignment == .right && paragraph.leftIndent == 10 && paragraph.firstLineIndent == -6 && paragraph.rightIndent == 5)
        #expect(paragraph.lineSpacing == .exactly(18))
        #expect(paragraph.tabStops.map(\.alignment) == [.decimal, .center, .left])
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        #expect(TextImporter.paragraphStyle(centered).alignment == .center)
    }
}
