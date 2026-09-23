// IO-012: Document Info in exported files.  `exiftool` is not on the build Macs, so the read-back
// uses the readers macOS ships -- ImageIO's XMP and IPTC parsers for bitmaps (the same XMP core
// Adobe's tools use), CGPDFDocument for PDF Info and the XMP stream, XMLParser for SVG and the
// packet itself -- and parses the IIM record byte by byte.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WTGeometry
@testable import WTInterchange
import WTRender

private enum MetadataFixtures {
    /// Every field set, with XML-significant characters and text outside the BMP.
    static let full = DocumentMetadata(
        title: "Fish & <Chips> “🐟”", headline: "Headline 'quoted'", description: "Line one\nLine two 𝄞",
        keywords: ["zebra", "Apple", "apple", "  mango  ", ""], category: "ART", supplementalCategories: ["Posters", "Print"],
        creators: ["Ada Lovelace", "Grace Hopper"], creatorJobTitle: "Engineer", credit: "Credit Line", source: "Source Co",
        copyrightNotice: "© 2026 Village", copyrightStatus: .copyrighted, rightsUsageTerms: "No reuse", webStatement: "https://example.com/rights",
        dateCreated: "2026-03-14", city: "Portland", state: "OR", country: "United States", instructions: "Handle with care",
        language: "en-US")

    static func scene(_ metadata: DocumentMetadata?) -> ExportScene {
        Corpus.scene([Corpus.page([Corpus.path(Corpus.rect(10, 10, 40, 30), [Corpus.fill(.solid(Corpus.red))])], width: 80, height: 60)], info: ExportDocumentInfo(metadata: metadata))
    }

    /// The text of every element named `name` in `xml`.
    static func texts(_ name: String, in xml: String) -> [String] {
        final class Collector: NSObject, XMLParserDelegate {
            let name: String
            var inside = 0
            var current = ""
            var found: [String] = []

            init(name: String) { self.name = name }

            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
                if elementName == name {
                    inside += 1
                    current = ""
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if inside > 0 { current += string }
            }

            func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
                if elementName == name {
                    inside -= 1
                    found.append(current)
                }
            }
        }
        let collector = Collector(name: name)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        #expect(parser.parse(), "the XML parses")
        return collector.found
    }

    /// The IIM datasets of a record, as (record, number, text).
    static func datasets(_ data: Data) -> [(UInt8, UInt8, Data)] {
        let bytes = [UInt8](data)
        var result: [(UInt8, UInt8, Data)] = []
        var index = 0
        while index + 5 <= bytes.count {
            #expect(bytes[index] == 0x1C)
            let length = Int(bytes[index + 3]) << 8 | Int(bytes[index + 4])
            result.append((bytes[index + 1], bytes[index + 2], Data(bytes[(index + 5)..<(index + 5 + length)])))
            index += 5 + length
        }
        return result
    }

    /// A string value at an XMP path of an image's metadata.
    static func value(_ metadata: CGImageMetadata, _ path: String) -> String? {
        CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?
    }

    static func exported(_ format: ExportFormat, options: any ExportOptions, metadata: DocumentMetadata?) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wt-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter: any Exporter
        switch format {
        case .psd: exporter = PSDExporter()
        case .eps: exporter = EPSExporter()
        default: exporter = BitmapExporter(format: format)
        }
        let summary = try exporter.export(scene: scene(metadata), options: options, to: ExportDestination(url: directory.appendingPathComponent("meta.\(format.fileExtension)")))
        return try Data(contentsOf: summary.files[0])
    }

    /// Checks every XMP field of `metadata` read back from an image file.
    static func expectXMP(in data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil), sourceLocation: sourceLocation)
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil), sourceLocation: sourceLocation)
        expectXMP(metadata, sourceLocation: sourceLocation)
    }

    /// Checks every XMP field of `metadata`.
    static func expectXMP(_ metadata: CGImageMetadata, sourceLocation: SourceLocation = #_sourceLocation) {
        let expected: [(String, String)] = [
            ("dc:title[x-default]", "Fish & <Chips> “🐟”"), ("dc:description[x-default]", "Line one\nLine two 𝄞"),
            ("dc:subject[0]", "Apple"), ("dc:subject[1]", "mango"), ("dc:subject[2]", "zebra"),
            ("dc:creator[0]", "Ada Lovelace"), ("dc:creator[1]", "Grace Hopper"), ("dc:rights[x-default]", "© 2026 Village"),
            ("dc:language[0]", "en-US"), ("photoshop:Headline", "Headline 'quoted'"), ("photoshop:Category", "ART"),
            ("photoshop:SupplementalCategories[1]", "Print"), ("photoshop:AuthorsPosition", "Engineer"),
            ("photoshop:Credit", "Credit Line"), ("photoshop:Source", "Source Co"), ("photoshop:DateCreated", "2026-03-14"),
            ("photoshop:City", "Portland"), ("photoshop:State", "OR"), ("photoshop:Country", "United States"),
            ("photoshop:Instructions", "Handle with care"), ("xmpRights:Marked", "True"),
            ("xmpRights:UsageTerms[x-default]", "No reuse"), ("xmpRights:WebStatement", "https://example.com/rights"),
        ]
        for (path, value) in expected {
            #expect(MetadataFixtures.value(metadata, path) == value, "\(path)", sourceLocation: sourceLocation)
        }
    }
}

@Suite("Metadata writer")
struct MetadataTests {
    let writer = MetadataWriter(metadata: MetadataFixtures.full, documentName: "Poster", date: Date(timeIntervalSince1970: 1_790_000_000))

    @Test func normalizationTrimsAndSortsKeywords() {
        let normalized = MetadataFixtures.full.normalized
        #expect(normalized.keywords == ["Apple", "mango", "zebra"])
        #expect(DocumentMetadata(title: "  x ").normalized.title == "x")
        #expect(DocumentMetadata(creators: [" a ", " "]).normalized.creators == ["a"])
        let bridged = DocumentMetadata(ExportDocumentInfo(title: "T", author: "A", subject: "S", description: "D", keywords: ["k"], language: "fr"))
        #expect(bridged == DocumentMetadata(title: "T", headline: "S", description: "D", keywords: ["k"], creators: ["A"], language: "fr"))
        #expect(DocumentMetadata(ExportDocumentInfo()) == DocumentMetadata())
    }

    @Test func anEmptyTitleFallsBackToTheDocumentName() {
        #expect(writer.title == "Fish & <Chips> “🐟”")
        let untitled = MetadataWriter(metadata: DocumentMetadata(), documentName: "Poster")
        #expect(untitled.title == "Poster")
        #expect(untitled.pdfInfo.map(\.key) == ["Title", "Creator"])
        #expect(untitled.pdfLanguage == nil)
        #expect(untitled.svgLanguage == nil)
        #expect(untitled.epsComments.count == 3)
        #expect(MetadataFixtures.texts("rdf:li", in: String(decoding: untitled.xmpPacket(), as: UTF8.self)) == ["Poster"])
        #expect(MetadataWriter(metadata: DocumentMetadata(headline: "H"), documentName: "x").pdfInfo.first { $0.key == "Subject" }?.value == "H")
        #expect(!String(decoding: MetadataWriter(metadata: DocumentMetadata(copyrightStatus: .publicDomain), documentName: "x").xmpPacket(), as: UTF8.self).contains("xmpRights:Marked>True"))
    }

    @Test func thePacketIsWellFormedAndComplete() throws {
        let packet = String(decoding: writer.xmpPacket(format: "image/png"), as: UTF8.self)
        #expect(packet.hasPrefix("<?xpacket begin=\"\u{FEFF}\""))
        #expect(MetadataFixtures.texts("dc:format", in: packet) == ["image/png"])
        #expect(MetadataFixtures.texts("photoshop:City", in: packet) == ["Portland"])
        #expect(MetadataFixtures.texts("xmp:CreatorTool", in: packet) == ["WireTuner"])
        #expect(MetadataFixtures.texts("xmpRights:WebStatement", in: packet) == ["https://example.com/rights"])
        #expect(MetadataFixtures.texts("pdf:Keywords", in: packet) == ["Apple, mango, zebra"])
        #expect(!writer.xmpProperties(includeTool: false).contains("CreatorTool"))
        // ImageIO parses it and reads every field back, escapes and astral characters included.
        let metadata = try #require(CGImageMetadataCreateFromXMPData(writer.xmpPacket() as CFData))
        MetadataFixtures.expectXMP(metadata)
        #expect(MetadataFixtures.value(metadata, "dc:title[x-default]") == "Fish & <Chips> “🐟”")
        #expect(MetadataFixtures.value(metadata, "dc:description[x-default]") == "Line one\nLine two 𝄞")
        #expect(MetadataWriter.escape("a\u{01}b\tc'\"") == "ab\tc&apos;&quot;")
    }

    @Test func theIIMRecordCarriesEveryDataset() {
        let datasets = MetadataFixtures.datasets(writer.iptcIIM())
        func texts(_ number: UInt8) -> [String] {
            datasets.filter { $0.0 == 2 && $0.1 == number }.map { String(decoding: $0.2, as: UTF8.self) }
        }
        #expect(datasets[0].0 == 1 && datasets[0].1 == 90 && datasets[0].2 == Data([0x1B, 0x25, 0x47]))
        #expect(texts(5) == ["Fish & <Chips> “🐟”"])
        #expect(texts(15) == ["ART"])
        #expect(texts(20) == ["Posters", "Print"])
        #expect(texts(25) == ["Apple", "mango", "zebra"])
        #expect(texts(40) == ["Handle with care"])
        #expect(texts(55) == ["20260314"])
        #expect(texts(80) == ["Ada Lovelace", "Grace Hopper"])
        #expect(texts(85) == ["Engineer"])
        #expect(texts(90) == ["Portland"])
        #expect(texts(95) == ["OR"])
        #expect(texts(101) == ["United States"])
        #expect(texts(105) == ["Headline 'quoted'"])
        #expect(texts(110) == ["Credit Line"])
        #expect(texts(115) == ["Source Co"])
        #expect(texts(116) == ["© 2026 Village"])
        #expect(texts(120) == ["Line one\nLine two 𝄞"])
        // Limits cut at character boundaries; partial dates have no IIM form.
        #expect(MetadataWriter.utf8Prefix("é🐟x", bytes: 5) == Data("é".utf8))
        #expect(MetadataWriter.iimDate("2026-03") == nil)
        let partial = MetadataWriter(metadata: DocumentMetadata(dateCreated: "2026-03"), documentName: "x")
        #expect(!MetadataFixtures.datasets(partial.iptcIIM()).contains { $0.1 == 55 })
    }

    @Test func epsAndSVGContainers() {
        #expect(writer.epsComments == [
            "%%Title: Fish & <Chips> ???", "%%Creator: WireTuner", "%%For: Ada Lovelace, Grace Hopper",
            "%%CreationDate: 2026-09-21T14:13:20Z",
        ])
        let svg = writer.svgMetadata
        #expect(MetadataFixtures.texts("photoshop:Credit", in: svg) == ["Credit Line"])
        #expect(MetadataFixtures.texts("dc:format", in: svg) == ["image/svg+xml"])
        #expect(writer.svgLanguage == "en-US")
        #expect(writer.pdfInfo.map(\.key) == ["Title", "Author", "Subject", "Keywords", "Creator"])
    }

    // MARK: Exporters

    @Test func pdfExportsCarryInfoXMPAndLanguage() throws {
        let data = try PDFExporter().data(scene: MetadataFixtures.scene(MetadataFixtures.full), options: PDFOptions()).data
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        let info = try #require(document.info)
        func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
            var value: CGPDFStringRef?
            guard CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
            return CGPDFStringCopyTextString(value) as String?
        }
        #expect(string(info, "Title") == "Fish & <Chips> “🐟”")
        #expect(string(info, "Author") == "Ada Lovelace, Grace Hopper")
        #expect(string(info, "Keywords") == "Apple, mango, zebra")
        let catalog = try #require(document.catalog)
        #expect(string(catalog, "Lang") == "en-US")
        var stream: CGPDFStreamRef?
        #expect(CGPDFDictionaryGetStream(catalog, "Metadata", &stream))
        var format = CGPDFDataFormat.raw
        let xmp = try #require(stream.flatMap { CGPDFStreamCopyData($0, &format) } as Data?)
        let metadata = try #require(CGImageMetadataCreateFromXMPData(xmp as CFData))
        #expect(MetadataFixtures.value(metadata, "photoshop:City") == "Portland")
        #expect(MetadataFixtures.value(metadata, "dc:language[0]") == "en-US")
        #expect(MetadataFixtures.value(metadata, "xmp:CreatorTool") == "WireTuner")
        // PDF/X keeps its identification beside the fields.
        let pdfx = try PDFExporter().data(scene: MetadataFixtures.scene(DocumentMetadata()), options: .printPDFX4).data
        // The dictionary belongs to the document, which must outlive the lookups.
        let pdfxDocument = try #require(CGPDFDocument(CGDataProvider(data: pdfx as CFData)!))
        let pdfxInfo = try #require(pdfxDocument.info)
        #expect(string(pdfxInfo, "Title") == "Corpus")
        #expect(string(pdfxInfo, "GTS_PDFXVersion") == "PDF/X-4")
        withExtendedLifetime(pdfxDocument) {}
    }

    @Test func svgExportsCarryMetadataAndLanguage() throws {
        let documents = SVGExporter().documents(scene: MetadataFixtures.scene(MetadataFixtures.full), options: SVGOptions())
        let text = documents[0].text
        #expect(text.contains("xml:lang=\"en-US\""))
        #expect(MetadataFixtures.texts("photoshop:Instructions", in: text) == ["Handle with care"])
        #expect(MetadataFixtures.texts("rdf:li", in: text).contains("Fish & <Chips> “🐟”"))
    }

    @Test func bitmapExportsCarryXMPAndIIM() throws {
        for (format, options) in [(ExportFormat.jpeg, JPEGOptions() as any ExportOptions), (.tiff, TIFFOptions()), (.tiff, TIFFOptions(common: BitmapCommonOptions(background: .white), bits: 8))] {
            let data = try MetadataFixtures.exported(format, options: options, metadata: MetadataFixtures.full)
            try MetadataFixtures.expectXMP(in: data)
        }
        // PNG and Photoshop: ImageIO's readers of these formats merge the XMP with the
        // format's own text fields and keep only the first item of each array, so the file's
        // own packet (the iTXt chunk, image resource 0x0424) is read back, as exiftool reads it.
        for (format, options, mime) in [(ExportFormat.png, PNGOptions() as any ExportOptions, "image/png"), (.png, PNGOptions(bits: 8), "image/png"), (.psd, PSDOptions(), "image/vnd.adobe.photoshop")] {
            let file = String(decoding: try MetadataFixtures.exported(format, options: options, metadata: MetadataFixtures.full), as: UTF8.self)
            let start = try #require(file.range(of: "<?xpacket begin"))
            let end = try #require(file.range(of: "<?xpacket end=\"w\"?>"))
            #expect(file.ranges(of: "<?xpacket begin").count == 1)
            let packet = String(file[start.lowerBound..<end.upperBound])
            MetadataFixtures.expectXMP(try #require(CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData)))
            #expect(MetadataFixtures.texts("dc:format", in: packet) == [mime])
        }
        // The PNG stays a valid PNG ImageIO decodes, with the title it reads from the packet.
        let png = try MetadataFixtures.exported(.png, options: PNGOptions(), metadata: MetadataFixtures.full)
        let pngSource = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceCreateImageAtIndex(pngSource, 0, nil)?.width == 80)
        #expect(CGImageSourceCopyMetadataAtIndex(pngSource, 0, nil).flatMap { MetadataFixtures.value($0, "dc:title[x-default]") } == "Fish & <Chips> “🐟”")
        // Rewriting a PNG replaces its packet rather than adding a second; damaged PNGs are left alone.
        #expect(String(decoding: try #require(writer.png(png)), as: UTF8.self).ranges(of: "<?xpacket begin").count == 1)
        #expect(writer.png(Data("not a png".utf8)) == nil)
        #expect(writer.png(png.prefix(40)) == nil)
        // JPEG and TIFF read back the IIM record too.
        for (format, options) in [(ExportFormat.jpeg, JPEGOptions() as any ExportOptions), (.tiff, TIFFOptions())] {
            let data = try MetadataFixtures.exported(format, options: options, metadata: MetadataFixtures.full)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let iptc = try #require(properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any], "\(format)")
            #expect(iptc[kCGImagePropertyIPTCObjectName] as? String == "Fish & <Chips> “🐟”")
            #expect(iptc[kCGImagePropertyIPTCKeywords] as? [String] == ["Apple", "mango", "zebra"])
            #expect(iptc[kCGImagePropertyIPTCCity] as? String == "Portland")
        }
        // BMP has nowhere to put metadata and is written as before.
        #expect(try MetadataFixtures.exported(.bmp, options: BMPOptions(common: BitmapCommonOptions(background: .white), bits: 24), metadata: MetadataFixtures.full).count > 0)
        // Without Document Info nothing is added.
        let plain = try MetadataFixtures.exported(.png, options: PNGOptions(), metadata: nil)
        let source = try #require(CGImageSourceCreateWithData(plain as CFData, nil))
        #expect(CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { MetadataFixtures.value($0, "photoshop:City") } == nil)
    }

    @Test func epsExportsWriteDSCComments() throws {
        let data = try MetadataFixtures.exported(.eps, options: EPSOptions(), metadata: MetadataFixtures.full)
        let text = String(decoding: data.prefix(2048), as: UTF8.self)
        #expect(text.contains("%%Title: Fish & <Chips> ???"))
        #expect(text.contains("%%For: Ada Lovelace, Grace Hopper"))
        #expect(!text.contains("%WTSubject"))
    }

    @Test func embeddingRewritesWithoutReencoding() throws {
        let jpeg = ImageFixtures.encode([ImageFixtures.image(width: 8, height: 8)], type: .jpeg)
        let embedded = try #require(writer.embed(in: jpeg))
        try MetadataFixtures.expectXMP(in: embedded)
        #expect(writer.embed(in: Data("not an image".utf8)) == nil)
    }
}

