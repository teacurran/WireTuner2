// The importer protocol and registry (import-formats.adoc, "Client"; IMG-008).  The Import sheet,
// Finder drops, paste and the share extension all consult one `ImportRegistry`: it knows every
// importable format's UTIs and extensions, recognises a file by its bytes when its name lies, and
// hands out the importer that probes and converts it.  Importers work on bytes, so tests need no
// files; the URL entry points read the file after the size check.

import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import WTGeometry

/// Every format the Import sheet accepts (import-formats.adoc, "Format summary"), text excepted
/// (importing-text.adoc belongs to the TXT epic).
public enum ImportFormat: String, CaseIterable, Hashable, Sendable, Codable, CustomStringConvertible {
    case pdf
    case illustrator
    case svg
    case dxf
    case eps
    case tiff
    case jpeg
    case png
    case gif
    case bmp
    case targa
    case psd
    case heic
    case webp
    case avif

    public var description: String { displayName }

    /// The name the Import sheet shows.
    public var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .illustrator: return "Adobe Illustrator"
        case .svg: return "SVG"
        case .dxf: return "AutoCAD DXF"
        case .eps: return "Encapsulated PostScript"
        case .tiff: return "TIFF"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        case .targa: return "Targa"
        case .psd: return "Photoshop"
        case .heic: return "HEIC"
        case .webp: return "WebP"
        case .avif: return "AVIF"
        }
    }

    /// File extensions, lower case, the preferred one first.
    public var fileExtensions: [String] {
        switch self {
        case .pdf: return ["pdf"]
        case .illustrator: return ["ai"]
        case .svg: return ["svg", "svgz"]
        case .dxf: return ["dxf"]
        case .eps: return ["eps", "epsf", "epsi"]
        case .tiff: return ["tif", "tiff"]
        case .jpeg: return ["jpg", "jpeg", "jpe"]
        case .png: return ["png"]
        case .gif: return ["gif"]
        case .bmp: return ["bmp", "dib"]
        case .targa: return ["tga", "targa"]
        case .psd: return ["psd"]
        case .heic: return ["heic", "heif"]
        case .webp: return ["webp"]
        case .avif: return ["avif"]
        }
    }

    /// The UTIs registered for the format.
    public var utis: [String] {
        switch self {
        case .pdf: return ["com.adobe.pdf"]
        case .illustrator: return ["com.adobe.illustrator.ai-image"]
        case .svg: return ["public.svg-image"]
        case .dxf: return ["com.autodesk.dxf"]
        case .eps: return ["com.adobe.encapsulated-postscript"]
        case .tiff: return ["public.tiff"]
        case .jpeg: return ["public.jpeg"]
        case .png: return ["public.png"]
        case .gif: return ["com.compuserve.gif"]
        case .bmp: return ["com.microsoft.bmp"]
        case .targa: return ["com.truevision.tga-image"]
        case .psd: return ["com.adobe.photoshop-image"]
        case .heic: return ["public.heic", "public.heif"]
        case .webp: return ["org.webmproject.webp"]
        case .avif: return ["public.avif"]
        }
    }

    /// Whether the format imports as an image object.
    public var isBitmap: Bool {
        switch self {
        case .pdf, .illustrator, .svg, .dxf, .eps: return false
        default: return true
        }
    }

    /// The format of a file extension.
    public init?(fileExtension: String) {
        let lower = fileExtension.lowercased()
        guard let format = ImportFormat.allCases.first(where: { $0.fileExtensions.contains(lower) }) else {
            return nil
        }
        self = format
    }

    /// The format of a UTI, or of a type conforming to one of the formats' types.
    public init?(uti: String) {
        if let format = ImportFormat.allCases.first(where: { $0.utis.contains(uti) }) {
            self = format
            return
        }
        guard let type = UTType(uti) else {
            return nil
        }
        // Illustrator's type conforms to PDF's on some systems; match the most specific first.
        let ordered: [ImportFormat] = [.illustrator, .eps] + ImportFormat.allCases.filter { $0 != .illustrator && $0 != .eps }
        guard let format = ordered.first(where: { $0.utis.contains { UTType($0).map(type.conforms(to:)) ?? false } }) else {
            return nil
        }
        self = format
    }

    /// The format the bytes announce, whatever the file is called: magic numbers for the
    /// binary formats, the text heads of SVG, DXF and PostScript.  Illustrator files that are
    /// PDFs sniff as PDF; `ImportRegistry.format(of:name:)` keeps `.ai` names Illustrator.
    public static func sniff(_ data: Data) -> ImportFormat? {
        let head = [UInt8](data.prefix(64))
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + bytes.count && Array(head[offset..<(offset + bytes.count)]) == bytes
        }
        if starts([0x25, 0x50, 0x44, 0x46]) { return .pdf }                          // %PDF
        if starts([0x89, 0x50, 0x4E, 0x47]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts([0x47, 0x49, 0x46, 0x38]) { return .gif }                          // GIF8
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if starts([0x38, 0x42, 0x50, 0x53]) { return .psd }                          // 8BPS
        if starts([0x42, 0x4D]) { return .bmp }                                      // BM
        if starts([0xC5, 0xD0, 0xD3, 0xC6]) { return .eps }                          // DOS EPS binary header
        if starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], at: 8) { return .webp }
        if starts([0x66, 0x74, 0x79, 0x70], at: 4) {                                // ftyp
            let brand = String(decoding: head.dropFirst(8).prefix(4), as: UTF8.self)
            if brand.hasPrefix("avi") { return .avif }
            if ["heic", "heix", "mif1", "msf1", "heim", "heis", "hevc", "hevx"].contains(brand) { return .heic }
        }
        if starts([0x1F, 0x8B]) { return .svg }                                      // gzip: .svgz
        if starts(Array("AutoCAD Binary DXF".utf8)) { return .dxf }
        let text = String(decoding: data.prefix(1024), as: UTF8.self)
        let trimmed = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        if trimmed.hasPrefix("%!PS-Adobe") {
            return text.contains("Adobe Illustrator") && !text.contains("EPSF") ? .illustrator : .eps
        }
        if trimmed.hasPrefix("<") && text.range(of: "<svg", options: .caseInsensitive) != nil { return .svg }
        let lines = String(trimmed).replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if lines.count >= 2, lines[0] == "0", lines[1] == "SECTION" || lines[1] == "EOF" { return .dxf }
        if lines.count >= 2, lines[0] == "999" { return .dxf }                       // a leading DXF comment
        return nil
    }
}

/// Why an import was refused.  Every case names the file so the alert can say which one
/// (IMG-015: "an alert naming the file and never a crash").
public enum ImportError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The file is larger than the import limit (200 MiB for images).
    case tooLarge(name: String, bytes: Int, limit: Int)
    /// No importer reads this file.
    case unsupportedFormat(name: String)
    /// The file is damaged or not what its name says.
    case unreadable(name: String, reason: String)
    /// A JPEG with 12 bits per sample, which macOS cannot decode.
    case unsupportedJPEGPrecision(name: String, bits: Int)
    /// An option value is not valid for the format (a page range beyond the document).
    case invalidOption(name: String, reason: String)
    /// Nothing in the file could be imported (an empty page range, an empty drawing).
    case empty(name: String)

    public var description: String {
        switch self {
        case .tooLarge(let name, let bytes, let limit):
            return "“\(name)” is \(ImportError.size(bytes)), larger than the \(ImportError.size(limit)) an imported file may be."
        case .unsupportedFormat(let name):
            return "“\(name)” is not in a format WireTuner can import."
        case .unreadable(let name, let reason):
            return "“\(name)” could not be read: \(reason)"
        case .unsupportedJPEGPrecision(let name, let bits):
            return "“\(name)” is a \(bits)-bit JPEG, which macOS cannot read.  Save it as a 16-bit TIFF or an 8-bit JPEG and import that."
        case .invalidOption(let name, let reason):
            return "“\(name)” could not be imported with these options: \(reason)"
        case .empty(let name):
            return "“\(name)” contains nothing to import."
        }
    }

    /// The file name the error is about.
    public var fileName: String {
        switch self {
        case .tooLarge(let name, _, _), .unsupportedFormat(let name), .unreadable(let name, _),
             .unsupportedJPEGPrecision(let name, _), .invalidOption(let name, _), .empty(let name):
            return name
        }
    }

    /// `bytes` as the Finder writes sizes: MiB with one decimal.
    static func size(_ bytes: Int) -> String {
        let mib = Double(bytes) / 1_048_576
        return mib.rounded() == mib ? "\(Int(mib)) MiB" : String(format: "%.1f MiB", mib)
    }
}

/// What the Import sheet shows for a selected file before it is converted.
public struct ImportDescriptor: @unchecked Sendable {
    public var format: ImportFormat
    /// The natural size in points (page, view box, drawing extents, pixels / ppi · 72).
    public var naturalSize: Rect
    /// Bitmaps: the pixel size and mode.
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var colorMode: ImportedColorMode?
    /// PDF and Illustrator: the page count.
    public var pageCount: Int?
    /// A small preview for the sheet, when the format has one cheaply.
    public var preview: CGImage?
    /// Whether the file will be placed rather than converted (EPS, an animated SVG, a legacy
    /// Illustrator file outside the operator set).
    public var placed: Bool

    public init(format: ImportFormat, naturalSize: Rect, pixelWidth: Int? = nil, pixelHeight: Int? = nil, colorMode: ImportedColorMode? = nil, pageCount: Int? = nil, preview: CGImage? = nil, placed: Bool = false) {
        self.format = format
        self.naturalSize = naturalSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.colorMode = colorMode
        self.pageCount = pageCount
        self.preview = preview
        self.placed = placed
    }
}

/// Facts from the importing Mac's preferences that every converter may read.
public struct ImportContext: Hashable, Sendable {
    /// The largest file an import accepts (importing.adoc: 200 MiB).
    public static let maximumFileSize = 200 * 1_048_576

    /// *Downsample images larger than*, in pixels; nil is Off.  Default 50 megapixels.
    public var downsampleLimit: Int?
    /// The refusal size in bytes.
    public var maximumFileSize: Int
    /// *Keep both offset* in points: the gap between PDF pages imported in a row.
    public var keepBothOffset: Double

    public init(downsampleLimit: Int? = 50_000_000, maximumFileSize: Int = ImportContext.maximumFileSize, keepBothOffset: Double = 10) {
        self.downsampleLimit = downsampleLimit
        self.maximumFileSize = maximumFileSize
        self.keepBothOffset = keepBothOffset
    }

    /// The *Downsample images larger than* choices in megapixels; 0 is Off.
    public static let downsampleChoices = [0, 20, 50, 100]

    /// The context for a preference value in megapixels (0 = Off).
    public init(downsampleMegapixels: Int) {
        self.init(downsampleLimit: downsampleMegapixels > 0 ? downsampleMegapixels * 1_000_000 : nil)
    }

    /// Refuses `bytes` over the limit.
    func checkSize(_ bytes: Int, name: String) throws {
        if bytes > maximumFileSize {
            throw ImportError.tooLarge(name: name, bytes: bytes, limit: maximumFileSize)
        }
    }
}

/// Reads one family of formats.
public protocol Importer: Sendable {
    /// The formats this importer reads.
    var formats: [ImportFormat] { get }
    /// The options the sheet's btn:[Options…] shows for `format` (empty: no button).
    func optionsSchema(for format: ImportFormat) -> ImportOptionsSchema
    /// The sheet's facts about a file, without converting it.
    func probe(_ data: Data, name: String, format: ImportFormat) throws -> ImportDescriptor
    /// The file converted with `options`.
    func convert(_ data: Data, name: String, format: ImportFormat, options: ImportOptionValues, context: ImportContext) throws -> ImportedScene
}

extension Importer {
    /// The formats' default options.
    public func optionsSchema(for format: ImportFormat) -> ImportOptionsSchema { ImportOptionsSchema(fields: []) }
}

/// Every importable format with its importer.
public struct ImportRegistry: Sendable {
    private var importers: [ImportFormat: any Importer]

    public init(importers: [any Importer]) {
        var table: [ImportFormat: any Importer] = [:]
        for importer in importers {
            for format in importer.formats {
                table[format] = importer
            }
        }
        self.importers = table
    }

    /// Adds or replaces the importer of each of its formats.
    public mutating func register(_ importer: any Importer) {
        for format in importer.formats {
            importers[format] = importer
        }
    }

    /// The formats that can be imported, in the summary table's order.
    public var availableFormats: [ImportFormat] {
        ImportFormat.allCases.filter { importers[$0] != nil }
    }

    /// Every UTI the Import sheet and drag and drop accept.
    public var acceptedUTIs: [String] {
        availableFormats.flatMap(\.utis)
    }

    /// The importer of `format`.
    public func importer(for format: ImportFormat) -> (any Importer)? {
        importers[format]
    }

    /// The format of a file: its bytes when they are recognisable (a PNG named `.jpg` is a PNG),
    /// else its extension.  An Illustrator name keeps a PDF-compatible file Illustrator, and a
    /// PostScript Illustrator file named `.eps` stays EPS.
    public func format(of data: Data, name: String) -> ImportFormat? {
        let byName = ImportFormat(fileExtension: (name as NSString).pathExtension)
        guard let sniffed = ImportFormat.sniff(data) else {
            return byName
        }
        if byName == .illustrator && (sniffed == .pdf || sniffed == .eps) {
            return .illustrator
        }
        if byName == .eps && sniffed == .illustrator {
            return .eps
        }
        return sniffed
    }

    /// The descriptor of `data`.
    public func probe(_ data: Data, name: String) throws -> ImportDescriptor {
        let (format, importer) = try resolve(data, name: name)
        return try importer.probe(data, name: name, format: format)
    }

    /// `data` converted with the format's options.
    public func convert(_ data: Data, name: String, options: ImportOptionValues? = nil, context: ImportContext = ImportContext()) throws -> ImportedScene {
        try context.checkSize(data.count, name: name)
        let (format, importer) = try resolve(data, name: name)
        let values = options ?? importer.optionsSchema(for: format).defaults
        return try importer.convert(data, name: name, format: format, options: values, context: context)
    }

    /// The file at `url` converted; the size is checked before it is read.
    public func convert(contentsOf url: URL, options: ImportOptionValues? = nil, context: ImportContext = ImportContext()) throws -> ImportedScene {
        let data = try ImportRegistry.read(url, context: context)
        return try convert(data, name: url.lastPathComponent, options: options, context: context)
    }

    /// The descriptor of the file at `url`.
    public func probe(contentsOf url: URL, context: ImportContext = ImportContext()) throws -> ImportDescriptor {
        let data = try ImportRegistry.read(url, context: context)
        return try probe(data, name: url.lastPathComponent)
    }

    /// The bytes of `url` after the size check.
    static func read(_ url: URL, context: ImportContext) throws -> Data {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        try context.checkSize(size, name: name)
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ImportError.unreadable(name: name, reason: error.localizedDescription)
        }
    }

    private func resolve(_ data: Data, name: String) throws -> (ImportFormat, any Importer) {
        guard let format = format(of: data, name: name), let importer = importers[format] else {
            throw ImportError.unsupportedFormat(name: name)
        }
        return (format, importer)
    }
}
