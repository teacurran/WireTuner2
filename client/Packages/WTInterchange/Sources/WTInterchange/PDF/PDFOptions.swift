// PDF export options (export-pdf.adoc; `PdfOptions` in interchange/v1/export_options.proto): the
// General, Compression, Fonts and Color sections IO-025 delivers, and the page-box and link
// options its writer needs.  PDF/X standards (IO-026), passwords, notes and bookmarks (IO-027) and
// the embedded package (IO-028) belong to later tasks and are refused or reported here.

import Foundation

public struct PDFOptions: ExportOptions, Hashable {
    public enum Version: String, CaseIterable, Hashable, Sendable {
        case v1_4 = "1.4"
        case v1_5 = "1.5"
        case v1_6 = "1.6"
        case v1_7 = "1.7"
        case v2_0 = "2.0"
    }

    public enum Standard: Hashable, Sendable {
        case none
        case pdfX1a2001
        case pdfX4_2010
    }

    public enum ImageCompression: Hashable, Sendable {
        /// JPEG bytes of placed JPEGs kept, everything else lossless.
        case auto
        case jpeg
        case lossless
        case none
    }

    public enum Fonts: Hashable, Sendable {
        case embedSubset
        case embedFull
        case outlines
    }

    public enum Colors: Hashable, Sendable {
        case keep
        case convertToCMYK
        case convertToRGB
    }

    public enum PageSize: Hashable, Sendable {
        case page
        case pagePlusBleed
    }

    public var version: Version
    public var standard: Standard
    /// Layers as optional content (PDF 1.5+).  Not written yet: reported.
    public var layers: Bool
    /// The embedded document package (IO-028).  Not written yet: reported.
    public var embedPackage: Bool
    /// *Optimize for fast web view*.  Not written yet: reported.
    public var linearize: Bool
    public var includeDocumentInfo: Bool
    public var colorImages: ImageCompression
    /// 1 ... 100.
    public var jpegQuality: Int
    public var downsample: Bool
    public var downsampleAbovePPI: Double
    public var downsampleToPPI: Double
    public var compressContent: Bool
    public var fonts: Fonts
    public var colors: Colors
    public var embedProfiles: Bool
    public var preserveOverprint: Bool
    public var pageSize: PageSize
    public var linksFromURLs: Bool
    /// Pixels per inch for regions PDF cannot express; 0 uses the document's raster resolution.
    public var rasterPPI: Double

    public init(
        version: Version = .v1_7,
        standard: Standard = .none,
        layers: Bool = false,
        embedPackage: Bool = false,
        linearize: Bool = false,
        includeDocumentInfo: Bool = true,
        colorImages: ImageCompression = .auto,
        jpegQuality: Int = 85,
        downsample: Bool = false,
        downsampleAbovePPI: Double = 450,
        downsampleToPPI: Double = 300,
        compressContent: Bool = true,
        fonts: Fonts = .embedSubset,
        colors: Colors = .keep,
        embedProfiles: Bool = true,
        preserveOverprint: Bool = true,
        pageSize: PageSize = .page,
        linksFromURLs: Bool = true,
        rasterPPI: Double = 0
    ) {
        self.version = version
        self.standard = standard
        self.layers = layers
        self.embedPackage = embedPackage
        self.linearize = linearize
        self.includeDocumentInfo = includeDocumentInfo
        self.colorImages = colorImages
        self.jpegQuality = jpegQuality
        self.downsample = downsample
        self.downsampleAbovePPI = downsampleAbovePPI
        self.downsampleToPPI = downsampleToPPI
        self.compressContent = compressContent
        self.fonts = fonts
        self.colors = colors
        self.embedProfiles = embedProfiles
        self.preserveOverprint = preserveOverprint
        self.pageSize = pageSize
        self.linksFromURLs = linksFromURLs
        self.rasterPPI = rasterPPI
    }

    public static var defaults: PDFOptions { PDFOptions() }

    /// Rejects values outside the sheet's ranges and choices later tasks deliver.
    func validate() throws {
        guard standard == .none else {
            throw ExportError.invalidOption("PDF/X output is not available yet (IO-026).")
        }
        guard colors != .convertToCMYK else {
            throw ExportError.invalidOption("Converting to CMYK needs the document's CMYK profile (CMS epic).")
        }
        guard (1...100).contains(jpegQuality) else {
            throw ExportError.invalidOption("JPEG quality must be 1 to 100.")
        }
        guard !downsample || (downsampleToPPI > 0 && downsampleAbovePPI >= downsampleToPPI) else {
            throw ExportError.invalidOption("Downsampling needs a target resolution at or below its threshold.")
        }
        guard rasterPPI >= 0 else {
            throw ExportError.invalidOption("The raster resolution cannot be negative.")
        }
    }

    /// Whether Display P3 colours can be written with their profile (ICC v4 needs PDF 1.7).
    var keepsDisplayP3: Bool {
        embedProfiles && colors == .keep && (version == .v1_7 || version == .v2_0)
    }
}
