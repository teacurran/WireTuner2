import Foundation
import WTGeometry
import WTInterchange

/// *What* the Export sheet exports (exporting.adoc, "Exporting a document").
enum ExportWhat: String, CaseIterable, Codable, Sendable {
    case currentPage
    case allPages
    case range
    case outputArea
    case selection

    var title: String {
        switch self {
        case .currentPage: "Current Page"
        case .allPages: "All Pages"
        case .range: "Range"
        case .outputArea: "Output Area"
        case .selection: "Selected Objects"
        }
    }
}

/// Page ranges as the sheet's field takes them: `1-3, 6`, `2-`, `-4` (exporting.adoc, "Client").
enum PageRange {
    enum Problem: Error, Equatable, CustomStringConvertible {
        case empty
        case invalid(String)
        case outOfRange(Int, pages: Int)

        var description: String {
            switch self {
            case .empty: "Type the pages to export, such as 1-3, 6."
            case .invalid(let part): "“\(part)” is not a page or a range of pages."
            case .outOfRange(let page, let pages): "There is no page \(page); the document has \(pages) \(pages == 1 ? "page" : "pages")."
            }
        }
    }

    /// The 0-based page indices `text` names among `pageCount` pages, in the order typed, each
    /// once.
    static func parse(_ text: String, pageCount: Int) throws(Problem) -> [Int] {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw Problem.empty }
        var pages: [Int] = []
        for part in parts {
            let bounds = try range(part, pageCount: pageCount)
            for page in bounds where !pages.contains(page - 1) {
                pages.append(page - 1)
            }
        }
        return pages
    }

    /// The 1-based pages one comma-separated part names.
    static func range(_ part: String, pageCount: Int) throws(Problem) -> ClosedRange<Int> {
        let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard ends.count <= 2, ends.allSatisfy({ $0.isEmpty || Int($0) != nil }), !ends.allSatisfy(\.isEmpty) else { throw Problem.invalid(part) }
        let lower = Int(ends[0]) ?? 1
        let upper = ends.count == 1 ? lower : Int(ends[1]) ?? pageCount
        for page in [lower, upper] where page < 1 || page > pageCount {
            throw Problem.outOfRange(page, pages: pageCount)
        }
        guard lower <= upper else { throw Problem.invalid(part) }
        return lower...upper
    }
}

/// Every format's options, one value each: what the options sheets edit and presets carry.
struct ExportFormatOptions: Hashable, Sendable {
    var pdf = PDFOptions.defaults
    var illustrator = IllustratorOptions.defaults
    var eps = EPSOptions.defaults
    var svg = SVGOptions.defaults
    var dxf = DXFOptions.defaults
    var png = PNGOptions.defaults
    var jpeg = JPEGOptions.defaults
    var webp = WebPOptions.defaults
    var heic = HEICOptions.defaults
    var avif = AVIFOptions.defaults
    var gif = GIFOptions.defaults
    var tiff = TIFFOptions.defaults
    var psd = PSDOptions.defaults
    var bmp = BMPOptions.defaults
    var targa = TargaOptions.defaults
    var animatedGIF = AnimatedGIFOptions.defaults
    var apng = APNGOptions.defaults
    var mp4H264 = MP4Options.defaults
    var mp4HEVC = MP4Options.defaults
    var rtf = RTFOptions.defaults
    var text = PlainTextOptions.defaults

    /// The options `format`'s exporter takes.
    func options(for format: ExportFormat) -> any ExportOptions {
        switch format {
        case .pdf: pdf
        case .illustrator: illustrator
        case .eps: eps
        case .svg: svg
        case .dxf: dxf
        case .animatedGIF: animatedGIF
        case .apng: apng
        case .mp4H264: mp4H264
        case .mp4HEVC: mp4HEVC
        case .rtf: rtf
        case .text: text
        default: bitmap(format)
        }
    }

    /// A bitmap format's options.
    func bitmap(_ format: ExportFormat) -> any BitmapFormatOptions {
        switch format {
        case .jpeg: jpeg
        case .webp: webp
        case .heic: heic
        case .avif: avif
        case .gif: gif
        case .tiff: tiff
        case .psd: psd
        case .bmp: bmp
        case .targa: targa
        default: png
        }
    }

    /// The options every bitmap format shares, for `format` (PNG's for a format that is not a
    /// bitmap).
    func common(_ format: ExportFormat) -> BitmapCommonOptions {
        bitmap(format).common
    }

    /// Sets `format`'s shared bitmap options.
    mutating func setCommon(_ common: BitmapCommonOptions, for format: ExportFormat) {
        switch format {
        case .jpeg: jpeg.common = common
        case .webp: webp.common = common
        case .heic: heic.common = common
        case .avif: avif.common = common
        case .gif: gif.common = common
        case .tiff: tiff.common = common
        case .psd: psd.common = common
        case .bmp: bmp.common = common
        case .targa: targa.common = common
        default: png.common = common
        }
    }

    /// The animation options every animation format shares.
    func animation(_ format: ExportFormat) -> AnimationCommonOptions {
        switch format {
        case .animatedGIF: animatedGIF.common
        case .apng: apng.common
        case .mp4HEVC: mp4HEVC.common
        default: mp4H264.common
        }
    }

    mutating func setAnimation(_ common: AnimationCommonOptions, for format: ExportFormat) {
        switch format {
        case .animatedGIF: animatedGIF.common = common
        case .apng: apng.common = common
        case .mp4HEVC: mp4HEVC.common = common
        default: mp4H264.common = common
        }
    }

    /// Whether the chosen options embed the document package (*Embed {product} document*).
    func embedsPackage(_ format: ExportFormat) -> Bool {
        switch format {
        case .pdf: pdf.embedPackage && pdf.standard == .none
        case .illustrator: illustrator.embedPackage
        case .eps: eps.embedPackage
        default: false
        }
    }

    /// These options with the PDF passwords removed: presets and the remembered export never
    /// store a password (export-pdf.adoc, "Data model").
    var withoutPasswords: ExportFormatOptions {
        var copy = self
        copy.pdf.openPassword = ""
        copy.pdf.permissionsPassword = ""
        return copy
    }
}

/// Everything the Export sheet sets up: format, options, *What*, naming and *After export*.
struct ExportSettings: Hashable, Sendable {
    var format: ExportFormat = .pdf
    var what: ExportWhat = .currentPage
    /// The *Range* field's text.
    var range = ""
    var includePageBoundary = true
    var namePattern = FileNamePattern.standard.rawValue
    var options = ExportFormatOptions()
    /// *Open with*: an application's bundle id, nil for none.
    var openWith: String?
    var revealInFinder = false
    /// A preset stored with a PDF password asks for it at export time.
    var asksOpenPassword = false
    var asksPermissionsPassword = false

    /// The scale factors the files are written at (bitmap formats only).
    var scales: [Double] {
        format.family == .bitmap ? options.common(format).scales : [1]
    }

    /// Whether the chosen options include a transparent background.
    var transparentBackground: Bool {
        format.family == .bitmap && options.common(format).background == .transparent
    }

    /// These settings as a preset or the remembered export keeps them: no passwords, a flag for
    /// each password that was set.
    var stored: ExportSettings {
        var copy = self
        copy.asksOpenPassword = asksOpenPassword || !options.pdf.openPassword.isEmpty
        copy.asksPermissionsPassword = asksPermissionsPassword || !options.pdf.permissionsPassword.isEmpty
        copy.options = options.withoutPasswords
        return copy
    }
}
