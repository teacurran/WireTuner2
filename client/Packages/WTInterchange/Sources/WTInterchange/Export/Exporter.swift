// The exporter protocol and registry (export-formats.adoc, "Client"; IO-013).  The Export sheet,
// presets, drag export and scripting all consult one `ExportRegistry`: it knows every format's
// extension, type and capabilities, validates a request before anything is written, and hands
// out the exporter that writes it.

import Foundation

/// The options of one format (`SvgOptions`, `PngOptions`, `PdfOptions`…).
public protocol ExportOptions: Sendable {
    /// What the options sheet starts with.
    static var defaults: Self { get }
}

/// Where an export goes: one file, or -- for a format that writes one file per page or per
/// scale -- the first file's URL whose directory and base name the pattern expands in.
public struct ExportDestination: Hashable, Sendable {
    /// The file the user chose (its extension is replaced by the format's).
    public var url: URL
    /// How several files are named; nil when only one file may be written.
    public var namePattern: FileNamePattern?
    /// The date `{date}` expands to.
    public var date: Date

    public init(url: URL, namePattern: FileNamePattern? = nil, date: Date = Date()) {
        self.url = url
        self.namePattern = namePattern
        self.date = date
    }

    /// The URLs of `count` files: the chosen URL alone for one file, otherwise the pattern
    /// expanded per file with sibling collisions suffixed.  `values(i)` supplies file `i`'s
    /// tokens (its name is replaced by the chosen file's base name).
    func urls(count: Int, format: ExportFormat, values: (Int) -> FileNamePattern.Values) throws -> [URL] {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        guard count > 1 else {
            return [directory.appendingPathComponent(base).appendingPathExtension(format.fileExtension)]
        }
        guard let pattern = namePattern else {
            throw ExportError.namePatternRequired(format: format, files: count)
        }
        let names = (0..<count).map { index -> String in
            var tokens = values(index)
            tokens.name = base
            tokens.date = date
            return pattern.expand(tokens)
        }
        return FileNamePattern.uniqueURLs(for: names, extension: format.fileExtension, in: directory)
    }
}

extension ExportDestination {
    /// Writes a format's one file at the chosen URL with `fileExtension`.
    func writeSingle(_ written: (data: Data, notes: [String]), extension fileExtension: String) throws -> ExportSummary {
        let file = url.deletingPathExtension().appendingPathExtension(fileExtension)
        do {
            try written.data.write(to: file)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return ExportSummary(files: [file], notes: written.notes)
    }
}

/// What an export wrote and what it had to change.
public struct ExportSummary: Hashable, Sendable {
    /// Every file written, in order.
    public var files: [URL]
    /// Notes for the export summary: rasterized regions, outlined fonts, clipped colors…
    public var notes: [String]

    public init(files: [URL] = [], notes: [String] = []) {
        self.files = files
        self.notes = notes
    }
}

/// Why an export was refused or failed.  Every case has a message the Export sheet can show.
public enum ExportError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The format cannot carry something the request asks for.
    case unsupported(ExportCapabilities, format: ExportFormat)
    /// Several files would be written but no name pattern tells them apart.
    case namePatternRequired(format: ExportFormat, files: Int)
    /// The options value is not this format's options type.
    case wrongOptions(format: ExportFormat)
    /// An option value is out of range or not available for this format.
    case invalidOption(String)
    /// No exporter is registered for the format yet.
    case notImplemented(ExportFormat)
    /// This Mac's image encoders cannot write the format (WebP: ImageIO decodes it but has no
    /// encoder, and no encoder is bundled).
    case encoderUnavailable(ExportFormat)
    /// There is nothing to export.
    case nothingToExport
    /// Encoding or writing failed.
    case writeFailed(String)

    public var description: String {
        switch self {
        case .unsupported(let capabilities, let format):
            return "\(format.displayName) cannot hold \(ExportError.names(of: capabilities))."
        case .namePatternRequired(let format, let files):
            return "\(format.displayName) writes \(files) files; choose a file name pattern with {page} or {pagename}."
        case .wrongOptions(let format):
            return "The options are not \(format.displayName) options."
        case .invalidOption(let message):
            return message
        case .notImplemented(let format):
            return "\(format.displayName) export is not available yet."
        case .encoderUnavailable(let format):
            return "This Mac cannot encode \(format.displayName) images: macOS provides no \(format.displayName) encoder and none is bundled.  Choose another format."
        case .nothingToExport:
            return "There is nothing to export."
        case .writeFailed(let message):
            return "The file could not be written: \(message)"
        }
    }

    static func names(of capabilities: ExportCapabilities) -> String {
        let names: [(ExportCapabilities, String)] = [
            (.multiPage, "several pages"), (.vector, "vector artwork"), (.text, "live text"),
            (.transparency, "live transparency"), (.alpha, "transparency"), (.layers, "layers"),
            (.metadata, "document info"), (.colorProfiles, "a color profile"), (.spotColors, "spot colors"),
            (.cmyk, "CMYK color"), (.links, "links"), (.filters, "live filters"), (.scales, "several scales"),
        ]
        return names.filter { capabilities.contains($0.0) }.map(\.1).joined(separator: ", ")
    }
}

/// Writes one format.
public protocol Exporter: Sendable {
    var format: ExportFormat { get }
    /// The options type `export` expects.
    var optionsType: any ExportOptions.Type { get }
    /// What this exporter carries (a subset of the format's own capabilities).
    var capabilities: ExportCapabilities { get }
    /// Writes `scene` with `options` (of `optionsType`) to `destination`.
    func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination) throws -> ExportSummary
}

extension Exporter {
    /// `options` as this exporter's type, or `ExportError.wrongOptions`.
    func typed<Options: ExportOptions>(_ options: any ExportOptions, as type: Options.Type) throws -> Options {
        guard let typed = options as? Options else {
            throw ExportError.wrongOptions(format: format)
        }
        return typed
    }
}

/// What the user asked for, before any file is written.
public struct ExportRequest: Hashable, Sendable {
    public var format: ExportFormat
    /// How many pages (or output areas) are exported.
    public var pageCount: Int
    /// Bitmap scale factors; each writes its own file.
    public var scales: [Double]
    /// A transparent background (bitmaps) was chosen.
    public var transparentBackground: Bool
    public var namePattern: FileNamePattern?

    public init(format: ExportFormat, pageCount: Int = 1, scales: [Double] = [1], transparentBackground: Bool = false, namePattern: FileNamePattern? = nil) {
        self.format = format
        self.pageCount = pageCount
        self.scales = scales
        self.transparentBackground = transparentBackground
        self.namePattern = namePattern
    }

    /// The number of files the request writes.
    public var fileCount: Int {
        let perPage = format.capabilities.contains(.scales) ? max(scales.count, 1) : 1
        return format.capabilities.contains(.multiPage) ? perPage : pageCount * perPage
    }
}

/// Options for the stub exporter.
public struct StubExportOptions: ExportOptions, Hashable {
    /// Seconds each page takes, so dialog tests can cancel or change the model mid-export.
    public var delayPerPage: Double

    public init(delayPerPage: Double = 0) {
        self.delayPerPage = delayPerPage
    }

    public static var defaults: StubExportOptions { StubExportOptions() }
}

/// An exporter for dialog and pipeline tests (IO-014): writes one small text file per page
/// listing the page's name, bounds and item count.
public struct StubExporter: Exporter {
    public let format: ExportFormat

    public init(format: ExportFormat = .text) {
        self.format = format
    }

    public var optionsType: any ExportOptions.Type { StubExportOptions.self }
    public var capabilities: ExportCapabilities { format.capabilities }

    public func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination) throws -> ExportSummary {
        let options = try typed(options, as: StubExportOptions.self)
        guard !scene.pages.isEmpty else {
            throw ExportError.nothingToExport
        }
        let urls = try destination.urls(count: scene.pages.count, format: format) { index in
            FileNamePattern.Values(name: scene.name, page: index + 1, pageName: scene.pages[index].name)
        }
        for (page, url) in zip(scene.pages, urls) {
            if options.delayPerPage > 0 {
                Thread.sleep(forTimeInterval: options.delayPerPage)
            }
            let b = page.bounds
            let text = "\(page.name ?? "page") \(b.minX) \(b.minY) \(b.width) \(b.height) \(page.displayList.count)\n"
            try Data(text.utf8).write(to: url)
        }
        return ExportSummary(files: urls)
    }
}

/// Every format with its exporter, where one exists.
public struct ExportRegistry: Sendable {
    private var exporters: [ExportFormat: any Exporter]

    /// A registry with the given exporters.
    public init(exporters: [any Exporter]) {
        var table: [ExportFormat: any Exporter] = [:]
        for exporter in exporters {
            table[exporter.format] = exporter
        }
        self.exporters = table
    }

    /// The exporters this package ships: every format, WebP, HEIC and AVIF where this Mac's
    /// ImageIO encodes them.
    public static let standard = ExportRegistry(exporters: [
        PDFExporter(),
        IllustratorExporter(),
        EPSExporter(),
        SVGExporter(),
        DXFExporter(),
        BitmapExporter(format: .png),
        BitmapExporter(format: .jpeg),
        BitmapExporter(format: .gif),
        BitmapExporter(format: .tiff),
        PSDExporter(),
        BitmapExporter(format: .bmp),
        BitmapExporter(format: .targa),
        RTFExporter(),
        PlainTextExporter(),
    ] + [ExportFormat.webp, .heic, .avif].filter(BitmapExporter.canEncode).map { BitmapExporter(format: $0) })

    /// Every format the Format menu lists, in its order.
    public var formats: [ExportFormat] { ExportFormat.allCases }

    /// The formats that can be exported now.
    public var availableFormats: [ExportFormat] {
        ExportFormat.allCases.filter { exporters[$0] != nil }
    }

    /// Adds or replaces the exporter for its format.
    public mutating func register(_ exporter: any Exporter) {
        exporters[exporter.format] = exporter
    }

    /// The exporter for `format`.
    public func exporter(for format: ExportFormat) throws -> any Exporter {
        guard let exporter = exporters[format] else {
            if [.webp, .heic, .avif].contains(format) && !BitmapExporter.canEncode(format) {
                throw ExportError.encoderUnavailable(format)
            }
            throw ExportError.notImplemented(format)
        }
        return exporter
    }

    /// The format of a file extension, if one is registered.
    public func format(forExtension fileExtension: String) -> ExportFormat? {
        ExportFormat(fileExtension: fileExtension)
    }

    /// Rejects a request the format cannot satisfy: alpha where the format has none, several
    /// scales on a format without scales, several files without a pattern that tells them
    /// apart, nothing to export.
    public func validate(_ request: ExportRequest) throws {
        let capabilities = request.format.capabilities
        guard request.pageCount > 0 else {
            throw ExportError.nothingToExport
        }
        if request.transparentBackground && !capabilities.contains(.alpha) {
            throw ExportError.unsupported(.alpha, format: request.format)
        }
        if request.scales.count > 1 && !capabilities.contains(.scales) {
            throw ExportError.unsupported(.scales, format: request.format)
        }
        let files = request.fileCount
        if files > 1 {
            guard let pattern = request.namePattern else {
                throw ExportError.namePatternRequired(format: request.format, files: files)
            }
            // Scales need no token: a pattern without `{scale}` gets the suffix appended.
            if request.pageCount > 1 && !capabilities.contains(.multiPage) && !pattern.distinguishesPages {
                throw ExportError.namePatternRequired(format: request.format, files: files)
            }
        }
    }
}
