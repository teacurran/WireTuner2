// PDF export options (export-pdf.adoc; `PdfOptions` in interchange/v1/export_options.proto): the
// General, Compression, Fonts and Color sections (IO-025), PDF/X and the bleed of *Pages and marks*
// (IO-026), the *Interactive* section -- links, notes, bookmarks, passwords and permissions
// (IO-027) -- and the embedded package (IO-028).

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
    /// Document layers as optional content groups (PDF 1.5+).
    public var layers: Bool
    /// *Embed {product} document*: `ExportScene.package` attached as an embedded file (IO-028).
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
    /// The bleed comes from the document (each page's bleed); otherwise `bleedPoints`.
    public var useDocumentBleed: Bool
    public var bleedPoints: Double
    public var linksFromURLs: Bool
    /// Object notes as text annotations at the objects' top-left corners.
    public var notesAsComments: Bool
    /// Named pages as bookmarks (the outline).
    public var bookmarksFromPageNames: Bool
    /// *Comments as annotations* (COLLAB-033): each open comment thread as a `/Text` annotation
    /// at its pin, replies as `/Text` annotations replying to the opener.  Off by default.
    public var commentsAsAnnotations = false
    /// *Tagged PDF (PDF/UA-1)* (IO-032): the structure tree, marked content and the PDF/UA-1
    /// claim when the file is eligible (`PDFStructure.swift`).  On by default.
    public var tagged = true
    /// Required to open the file; empty for none.  Never stored in a preset.
    public var openPassword: String
    /// Required to print, copy or edit beyond the permissions below; empty for none.
    public var permissionsPassword: String
    public var allowPrinting: Bool
    public var allowCopying: Bool
    public var allowEditing: Bool
    /// Spot colours as `/Separation` colour spaces on their own plates (FX-012 relies on it for
    /// vector parts); off writes their process alternates.
    public var preserveSpot: Bool
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
        useDocumentBleed: Bool = true,
        bleedPoints: Double = 0,
        linksFromURLs: Bool = true,
        rasterPPI: Double = 0,
        notesAsComments: Bool = false,
        bookmarksFromPageNames: Bool = true,
        openPassword: String = "",
        permissionsPassword: String = "",
        allowPrinting: Bool = true,
        allowCopying: Bool = true,
        allowEditing: Bool = true,
        preserveSpot: Bool = true
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
        self.useDocumentBleed = useDocumentBleed
        self.bleedPoints = bleedPoints
        self.linksFromURLs = linksFromURLs
        self.rasterPPI = rasterPPI
        self.notesAsComments = notesAsComments
        self.bookmarksFromPageNames = bookmarksFromPageNames
        self.openPassword = openPassword
        self.permissionsPassword = permissionsPassword
        self.allowPrinting = allowPrinting
        self.allowCopying = allowCopying
        self.allowEditing = allowEditing
        self.preserveSpot = preserveSpot
    }

    public static var defaults: PDFOptions { PDFOptions() }

    /// The shipped *Print (PDF/X-4)* preset: transparency live, colours tagged, page plus bleed.
    public static var printPDFX4: PDFOptions { PDFOptions(standard: .pdfX4_2010, pageSize: .pagePlusBleed) }

    /// The shipped *Press (PDF/X-1a)* preset: flattened, CMYK, page plus bleed.
    public static var pressPDFX1a: PDFOptions { PDFOptions(standard: .pdfX1a2001, colors: .convertToCMYK, embedProfiles: false, pageSize: .pagePlusBleed) }

    /// Rejects values outside the sheet's ranges.
    func validate() throws {
        guard (1...100).contains(jpegQuality) else {
            throw ExportError.invalidOption("JPEG quality must be 1 to 100.")
        }
        guard !downsample || (downsampleToPPI > 0 && downsampleAbovePPI >= downsampleToPPI) else {
            throw ExportError.invalidOption("Downsampling needs a target resolution at or below its threshold.")
        }
        guard rasterPPI >= 0 else {
            throw ExportError.invalidOption("The raster resolution cannot be negative.")
        }
        guard bleedPoints.isFinite, bleedPoints >= 0, bleedPoints <= 72 else {
            throw ExportError.invalidOption("The bleed must be 0 to 72 points (1 inch).")
        }
    }

    /// The options a standard requires, and what was changed to meet it (the fix report).
    func conforming() -> (options: PDFOptions, fixes: [String]) {
        var result = self
        var fixes: [String] = []
        func force<Value: Equatable>(_ path: WritableKeyPath<PDFOptions, Value>, _ value: Value, _ fix: String) {
            if result[keyPath: path] != value {
                result[keyPath: path] = value
                fixes.append(fix)
            }
        }
        switch standard {
        case .none:
            return (self, [])
        case .pdfX1a2001:
            force(\.colors, .convertToCMYK, "colors converted to CMYK (PDF/X-1a allows CMYK and spot colors only)")
            force(\.embedProfiles, false, "profiles not embedded (PDF/X-1a uses the output intent only)")
            force(\.layers, false, "layers flattened into the page (PDF/X-1a has no layers)")
        case .pdfX4_2010:
            force(\.embedProfiles, true, "profiles embedded (PDF/X-4 requires tagged color)")
        }
        force(\.includeDocumentInfo, true, "document info included (PDF/X identifies itself there)")
        force(\.preserveOverprint, true, "overprint preserved (PDF/X requires it)")
        force(\.embedPackage, false, "the embedded document package left out (PDF/X forbids attachments)")
        force(\.linksFromURLs, false, "links left out (PDF/X allows no annotations on the page)")
        force(\.notesAsComments, false, "comments left out (PDF/X allows no annotations on the page)")
        force(\.commentsAsAnnotations, false, "comment threads left out (PDF/X allows no annotations on the page)")
        force(\.bookmarksFromPageNames, false, "bookmarks left out (interactive features are off for PDF/X)")
        force(\.openPassword, "", "the open password removed (PDF/X forbids encryption)")
        force(\.permissionsPassword, "", "the permissions password removed (PDF/X forbids encryption)")
        force(\.pageSize, .pagePlusBleed, "media box set to page plus bleed (PDF/X bleed box)")
        return (result, fixes)
    }

    /// The version written in the file header: a standard's own (PDF/X-1a:2001 is PDF 1.3,
    /// PDF/X-4 is PDF 1.6), otherwise the chosen one -- raised to 1.6 when passwords need AES.
    var headerVersion: String {
        switch standard {
        case .none: return encrypts && (version == .v1_4 || version == .v1_5) ? "1.6" : version.rawValue
        case .pdfX1a2001: return "1.3"
        case .pdfX4_2010: return "1.6"
        }
    }

    /// Whether the file is encrypted: a password is set (PDF/X has already removed them).
    var encrypts: Bool {
        !openPassword.isEmpty || !permissionsPassword.isEmpty
    }

    /// Whether Display P3 colours can be written with their profile: PDF 1.7 and later, and PDF/X-4.
    var keepsDisplayP3: Bool {
        // PDF/X-4 (PDF 1.6) allows ICC v4 profiles, which PDF has read since 1.5 (CMS-015).
        embedProfiles && colors == .keep && (standard == .pdfX4_2010 || (standard == .none && (version == .v1_7 || version == .v2_0)))
    }

    /// Whether optional content (layers) can be written: PDF 1.5 or later.
    var writesLayers: Bool {
        layers && (standard == .pdfX4_2010 || version != .v1_4)
    }
}
