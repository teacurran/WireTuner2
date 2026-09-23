// Document Info in exported files (file-info.adoc, "Client"; IO-012).  `DocumentMetadata` mirrors
// `DocumentInfo` field for field; `MetadataWriter` maps it to every container an exporter needs:
// an XMP packet (RDF/XML in the `dc`, `xmp`, `xmpRights`, `photoshop`, `Iptc4xmpCore` and `pdf`
// namespaces), an IPTC-IIM record, PDF Info entries and the catalog's `/Lang`, EPS DSC comments,
// SVG `<metadata>` and `xml:lang`, and ImageIO properties for PNG, JPEG, TIFF, HEIC and the other
// ImageIO formats.  An empty title falls back to the document's name.  The read-time
// normalizations of `DocumentInfo` apply here: whitespace trimmed, keywords sorted
// case-insensitively with case duplicates collapsed.

import CoreGraphics
import Foundation
import ImageIO

/// `DocumentInfo` (file_info.proto) as an exporter receives it.
public struct DocumentMetadata: Hashable, Sendable {
    /// `CopyrightStatus`.
    public enum CopyrightStatus: Hashable, Sendable {
        case unknown
        case copyrighted
        case publicDomain
    }

    public var title: String
    public var headline: String
    public var description: String
    public var keywords: [String]
    public var category: String
    public var supplementalCategories: [String]
    public var creators: [String]
    public var creatorJobTitle: String
    public var credit: String
    public var source: String
    public var copyrightNotice: String
    public var copyrightStatus: CopyrightStatus
    public var rightsUsageTerms: String
    public var webStatement: String
    /// ISO 8601 date or partial date ("2026-03").
    public var dateCreated: String
    public var city: String
    public var state: String
    public var country: String
    public var instructions: String
    /// BCP 47.
    public var language: String

    public init(title: String = "", headline: String = "", description: String = "", keywords: [String] = [], category: String = "", supplementalCategories: [String] = [], creators: [String] = [], creatorJobTitle: String = "", credit: String = "", source: String = "", copyrightNotice: String = "", copyrightStatus: CopyrightStatus = .unknown, rightsUsageTerms: String = "", webStatement: String = "", dateCreated: String = "", city: String = "", state: String = "", country: String = "", instructions: String = "", language: String = "") {
        self.title = title
        self.headline = headline
        self.description = description
        self.keywords = keywords
        self.category = category
        self.supplementalCategories = supplementalCategories
        self.creators = creators
        self.creatorJobTitle = creatorJobTitle
        self.credit = credit
        self.source = source
        self.copyrightNotice = copyrightNotice
        self.copyrightStatus = copyrightStatus
        self.rightsUsageTerms = rightsUsageTerms
        self.webStatement = webStatement
        self.dateCreated = dateCreated
        self.city = city
        self.state = state
        self.country = country
        self.instructions = instructions
        self.language = language
    }

    /// The exporters' older, smaller Document Info.
    public init(_ info: ExportDocumentInfo) {
        self.init(title: info.title ?? "", headline: info.subject ?? "", description: info.description ?? "", keywords: info.keywords, creators: info.author.map { [$0] } ?? [], language: info.language ?? "")
    }

    /// The read-out: every string trimmed, empty list entries dropped, keywords sorted
    /// case-insensitively with duplicates differing only in case collapsed to the first.
    public var normalized: DocumentMetadata {
        func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        func list(_ items: [String]) -> [String] { items.map(trim).filter { !$0.isEmpty } }
        var result = DocumentMetadata(
            title: trim(title), headline: trim(headline), description: trim(description), category: trim(category),
            creatorJobTitle: trim(creatorJobTitle), credit: trim(credit), source: trim(source), copyrightNotice: trim(copyrightNotice),
            copyrightStatus: copyrightStatus, rightsUsageTerms: trim(rightsUsageTerms), webStatement: trim(webStatement),
            dateCreated: trim(dateCreated), city: trim(city), state: trim(state), country: trim(country),
            instructions: trim(instructions), language: trim(language))
        result.creators = list(creators)
        result.supplementalCategories = list(supplementalCategories)
        var seen = Set<String>()
        result.keywords = list(keywords)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .filter { seen.insert($0.lowercased()).inserted }
        return result
    }
}

/// Writes `DocumentMetadata` into the containers exporters need.
public struct MetadataWriter: Sendable {
    public let metadata: DocumentMetadata
    /// The document's name: the title when the title is empty.
    public let documentName: String
    public let creatorTool: String
    public let date: Date

    public init(metadata: DocumentMetadata, documentName: String, creatorTool: String = "WireTuner", date: Date = Date()) {
        self.metadata = metadata.normalized
        self.documentName = documentName
        self.creatorTool = creatorTool
        self.date = date
    }

    /// The title written: Document Info's, else the document name.
    public var title: String {
        metadata.title.isEmpty ? documentName : metadata.title
    }

    // MARK: XMP

    static let namespaces: [(String, String)] = [
        ("dc", "http://purl.org/dc/elements/1.1/"),
        ("xmp", "http://ns.adobe.com/xap/1.0/"),
        ("xmpRights", "http://ns.adobe.com/xap/1.0/rights/"),
        ("photoshop", "http://ns.adobe.com/photoshop/1.0/"),
        ("Iptc4xmpCore", "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"),
        ("pdf", "http://ns.adobe.com/pdf/1.3/"),
    ]

    /// The `xmlns:` declarations of the namespaces the properties use.
    public static var namespaceDeclarations: String {
        namespaces.map { " xmlns:\($0.0)=\"\($0.1)\"" }.joined()
    }

    /// The properties of one `rdf:Description`, for writers that assemble their own packet
    /// (the PDF writer adds PDF/X identification beside them).  `format` is `dc:format`.
    public func xmpProperties(format: String? = nil, includeTool: Bool = true) -> String {
        let m = metadata
        var out = ""
        func simple(_ name: String, _ value: String) {
            if !value.isEmpty { out += "<\(name)>\(MetadataWriter.escape(value))</\(name)>" }
        }
        func alt(_ name: String, _ value: String) {
            if !value.isEmpty { out += "<\(name)><rdf:Alt><rdf:li xml:lang=\"x-default\">\(MetadataWriter.escape(value))</rdf:li></rdf:Alt></\(name)>" }
        }
        func array(_ name: String, _ kind: String, _ values: [String]) {
            if !values.isEmpty { out += "<\(name)><rdf:\(kind)>" + values.map { "<rdf:li>\(MetadataWriter.escape($0))</rdf:li>" }.joined() + "</rdf:\(kind)></\(name)>" }
        }
        if let format { simple("dc:format", format) }
        alt("dc:title", title)
        alt("dc:description", m.description)
        array("dc:subject", "Bag", m.keywords)
        array("dc:creator", "Seq", m.creators)
        alt("dc:rights", m.copyrightNotice)
        array("dc:language", "Bag", m.language.isEmpty ? [] : [m.language])
        simple("photoshop:Headline", m.headline)
        simple("photoshop:Category", m.category)
        array("photoshop:SupplementalCategories", "Bag", m.supplementalCategories)
        simple("photoshop:AuthorsPosition", m.creatorJobTitle)
        simple("photoshop:Credit", m.credit)
        simple("photoshop:Source", m.source)
        simple("photoshop:DateCreated", m.dateCreated)
        simple("photoshop:City", m.city)
        simple("photoshop:State", m.state)
        simple("photoshop:Country", m.country)
        simple("photoshop:Instructions", m.instructions)
        switch m.copyrightStatus {
        case .unknown: break
        case .copyrighted: simple("xmpRights:Marked", "True")
        case .publicDomain: simple("xmpRights:Marked", "False")
        }
        alt("xmpRights:UsageTerms", m.rightsUsageTerms)
        simple("xmpRights:WebStatement", m.webStatement)
        simple("pdf:Keywords", m.keywords.joined(separator: ", "))
        if includeTool {
            simple("xmp:CreatorTool", creatorTool)
        }
        let stamp = ISO8601DateFormatter().string(from: date)
        simple("xmp:MetadataDate", stamp)
        return out
    }

    /// A complete XMP packet with its `xpacket` wrapper.
    public func xmpPacket(format: String? = nil) -> Data {
        let packet = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
            + "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\"\(MetadataWriter.namespaceDeclarations)>\(xmpProperties(format: format))</rdf:Description>"
            + "</rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
        return Data(packet.utf8)
    }

    /// `text` escaped for XML character data and attributes.
    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                // Control characters other than tab, line feed and carriage return are not
                // allowed in XML 1.0 at all; drop them.
                if scalar.value < 0x20 && ![0x09, 0x0A, 0x0D].contains(scalar.value) {
                    continue
                }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: IPTC-IIM

    /// The IPTC-IIM record: 1:90 declares UTF-8, then the application record's datasets.
    public func iptcIIM() -> Data {
        let m = metadata
        var data = Data()
        func dataset(_ record: UInt8, _ number: UInt8, _ value: Data) {
            // Datasets over 32,767 bytes need the extended length form; IPTC limits keep
            // every field far below it, so values are capped instead.
            let bytes = value.prefix(32_767)
            data.append(contentsOf: [0x1C, record, number])
            data.appendBigEndian(UInt16(bytes.count))
            data.append(bytes)
        }
        func text(_ number: UInt8, _ value: String, limit: Int) {
            if !value.isEmpty { dataset(2, number, MetadataWriter.utf8Prefix(value, bytes: limit)) }
        }
        dataset(1, 90, Data([0x1B, 0x25, 0x47]))                 // ESC % G: UTF-8
        dataset(2, 0, Data([0x00, 0x04]))                        // record version 4
        text(5, title, limit: 64)
        text(15, m.category, limit: 3)
        for category in m.supplementalCategories { text(20, category, limit: 32) }
        for keyword in m.keywords { text(25, keyword, limit: 64) }
        text(40, m.instructions, limit: 256)
        if let date = MetadataWriter.iimDate(m.dateCreated) { text(55, date, limit: 8) }
        for creator in m.creators { text(80, creator, limit: 32) }
        text(85, m.creatorJobTitle, limit: 32)
        text(90, m.city, limit: 32)
        text(95, m.state, limit: 32)
        text(101, m.country, limit: 64)
        text(105, m.headline, limit: 256)
        text(110, m.credit, limit: 32)
        text(115, m.source, limit: 32)
        text(116, m.copyrightNotice, limit: 128)
        text(120, m.description, limit: 2000)
        return data
    }

    /// The longest prefix of `text` whose UTF-8 fits in `bytes`, never splitting a character.
    static func utf8Prefix(_ text: String, bytes: Int) -> Data {
        var result = Data()
        for character in text {
            let encoded = Data(String(character).utf8)
            if result.count + encoded.count > bytes {
                break
            }
            result.append(encoded)
        }
        return result
    }

    /// An IIM date (CCYYMMDD) from an ISO 8601 date, nil for partial dates.
    static func iimDate(_ text: String) -> String? {
        let digits = text.prefix(10).filter(\.isNumber)
        return digits.count == 8 ? String(digits) : nil
    }

    // MARK: PDF, EPS, SVG

    /// The PDF Info dictionary's text entries, in order (dates and producer are the writer's).
    public var pdfInfo: [(key: String, value: String)] {
        let m = metadata
        var entries: [(String, String)] = [("Title", title)]
        if !m.creators.isEmpty { entries.append(("Author", m.creators.joined(separator: ", "))) }
        let subject = m.description.isEmpty ? m.headline : m.description
        if !subject.isEmpty { entries.append(("Subject", subject)) }
        if !m.keywords.isEmpty { entries.append(("Keywords", m.keywords.joined(separator: ", "))) }
        entries.append(("Creator", creatorTool))
        return entries
    }

    /// The catalog's `/Lang`, when a language is set.
    public var pdfLanguage: String? {
        metadata.language.isEmpty ? nil : metadata.language
    }

    /// DSC comments for an EPS header (`%%Title:`, `%%Creator:`, `%%For:`, `%%CreationDate:`),
    /// each a line without its line end; DSC text is 7-bit, so other characters become `?`.
    public var epsComments: [String] {
        func dsc(_ text: String) -> String {
            String(text.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 ? Character($0) : "?" }.prefix(250))
        }
        var lines = ["%%Title: \(dsc(title))", "%%Creator: \(dsc(creatorTool))"]
        if !metadata.creators.isEmpty {
            lines.append("%%For: \(dsc(metadata.creators.joined(separator: ", ")))")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        lines.append("%%CreationDate: \(formatter.string(from: date))")
        return lines
    }

    /// The SVG `<metadata>` element holding the RDF.
    public var svgMetadata: String {
        "<metadata><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\"\(MetadataWriter.namespaceDeclarations)>\(xmpProperties(format: "image/svg+xml"))</rdf:Description></rdf:RDF></metadata>"
    }

    /// The root element's `xml:lang` value, when a language is set.
    public var svgLanguage: String? { pdfLanguage }

    // MARK: Images

    /// The XMP as ImageIO metadata, for `CGImageDestinationAddImageAndMetadata`.
    public func imageMetadata() -> CGImageMetadata {
        // The packet is well-formed by construction, so ImageIO always parses it.
        CGImageMetadataCreateFromXMPData(xmpPacket() as CFData)!
    }

    /// A PNG with the XMP packet in an `iTXt` chunk keyed `XML:com.adobe.xmp` right after
    /// `IHDR` (XMP Specification Part 3), replacing any packet it had; nil when `data` is not
    /// a PNG.  Written directly: ImageIO's PNG metadata path rewrites XMP arrays through the
    /// PNG text chunks and loses all but their first item.
    public func png(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= 8, Array(bytes[0..<8]) == signature else {
            return nil
        }
        let keyword = Array("XML:com.adobe.xmp".utf8)
        var body = keyword + [0, 0, 0, 0, 0]
        body += [UInt8](xmpPacket(format: "image/png"))
        var chunk = Data()
        chunk.appendBigEndian(UInt32(body.count))
        let typed = Array("iTXt".utf8) + body
        chunk.append(contentsOf: typed)
        chunk.appendBigEndian(CRC32.checksum(typed))
        var output = Data(signature)
        var index = 8
        while index + 12 <= bytes.count {
            let length = Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16 | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let end = index + 12 + length
            guard end <= bytes.count else {
                return nil
            }
            let type = String(decoding: bytes[(index + 4)..<(index + 8)], as: UTF8.self)
            let isXMP = type == "iTXt" && bytes[(index + 8)...].starts(with: keyword + [0])
            if !isXMP {
                output.append(contentsOf: bytes[index..<end])
            }
            if type == "IHDR" {
                output.append(chunk)
            }
            index = end
        }
        return index == bytes.count ? output : nil
    }

    /// `data` (any format ImageIO writes) with this metadata merged in, without re-encoding
    /// its pixels; nil when ImageIO cannot rewrite the format.
    public func embed(in data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationMetadata: imageMetadata(), kCGImageDestinationMergeMetadata: true] as CFDictionary
        guard CGImageDestinationCopyImageSource(destination, source, options, nil) else {
            return nil
        }
        return output as Data
    }
}
