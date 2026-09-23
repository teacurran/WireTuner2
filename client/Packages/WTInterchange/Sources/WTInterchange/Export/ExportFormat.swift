// The formats {product} writes (docs/_includes/io/export-formats.adoc, IO-013).  The raw values
// are `ExportFormat`'s proto numbers in account/v1/preferences.proto, so a preset's stored
// format maps straight onto this enum.

import UniformTypeIdentifiers

/// One export file format.
public enum ExportFormat: Int, CaseIterable, Hashable, Sendable, CustomStringConvertible {
    case pdf = 1
    case illustrator = 2
    case eps = 3
    case svg = 4
    case dxf = 5
    case png = 10
    case jpeg = 11
    case webp = 12
    case heic = 13
    case avif = 14
    case gif = 15
    case tiff = 16
    case psd = 17
    case bmp = 18
    case targa = 19
    case rtf = 30
    case text = 31

    /// What kind of file the format writes.
    public enum Family: Hashable, Sendable {
        case vector
        case bitmap
        case text
    }

    public var family: Family {
        switch self {
        case .pdf, .illustrator, .eps, .svg, .dxf: return .vector
        case .png, .jpeg, .webp, .heic, .avif, .gif, .tiff, .psd, .bmp, .targa: return .bitmap
        case .rtf, .text: return .text
        }
    }

    /// The name in the Format pop-up menu.
    public var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .illustrator: return "Adobe Illustrator"
        case .eps: return "EPS"
        case .svg: return "SVG"
        case .dxf: return "DXF"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .webp: return "WebP"
        case .heic: return "HEIC"
        case .avif: return "AVIF"
        case .gif: return "GIF"
        case .tiff: return "TIFF"
        case .psd: return "Photoshop"
        case .bmp: return "BMP"
        case .targa: return "Targa"
        case .rtf: return "Rich Text"
        case .text: return "Plain Text"
        }
    }

    public var description: String { displayName }

    /// The file extension, without the dot.
    public var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .illustrator: return "ai"
        case .eps: return "eps"
        case .svg: return "svg"
        case .dxf: return "dxf"
        case .png: return "png"
        case .jpeg: return "jpg"
        case .webp: return "webp"
        case .heic: return "heic"
        case .avif: return "avif"
        case .gif: return "gif"
        case .tiff: return "tif"
        case .psd: return "psd"
        case .bmp: return "bmp"
        case .targa: return "tga"
        case .rtf: return "rtf"
        case .text: return "txt"
        }
    }

    /// The uniform type identifier string (what `NSSavePanel.allowedContentTypes` and the
    /// pasteboard use).  DXF and AVIF have no system-declared type on every macOS, so their
    /// identifiers are the ones the app's Info.plist imports.
    public var typeIdentifier: String {
        switch self {
        case .pdf: return "com.adobe.pdf"
        case .illustrator: return "com.adobe.illustrator.ai-image"
        case .eps: return "com.adobe.encapsulated-postscript"
        case .svg: return "public.svg-image"
        case .dxf: return "com.autodesk.dxf"
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .webp: return "org.webmproject.webp"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .gif: return "com.compuserve.gif"
        case .tiff: return "public.tiff"
        case .psd: return "com.adobe.photoshop-image"
        case .bmp: return "com.microsoft.bmp"
        case .targa: return "com.truevision.tga-image"
        case .rtf: return "public.rtf"
        case .text: return "public.plain-text"
        }
    }

    /// The type as a `UTType`: the system's declaration when there is one, otherwise a type
    /// exported for the identifier conforming to `public.data` and tagged with the extension.
    public var utType: UTType {
        UTType(typeIdentifier) ?? UTType(exportedAs: typeIdentifier, conformingTo: .data)
    }

    /// The format a file extension names (case-insensitive; `jpeg`, `tiff` and `text` are
    /// accepted as aliases).
    public init?(fileExtension: String) {
        let lowered = fileExtension.lowercased()
        let aliases = ["jpeg": ExportFormat.jpeg, "tiff": .tiff, "text": .text]
        guard let format = aliases[lowered] ?? ExportFormat.allCases.first(where: { $0.fileExtension == lowered }) else {
            return nil
        }
        self = format
    }

    /// What files of this format can hold (export-formats.adoc and the format pages).
    public var capabilities: ExportCapabilities {
        switch self {
        case .pdf, .illustrator:
            return [.multiPage, .vector, .text, .transparency, .alpha, .layers, .metadata, .colorProfiles, .spotColors, .cmyk, .links]
        case .eps:
            return [.vector, .text, .metadata, .spotColors, .cmyk]
        case .svg:
            return [.vector, .text, .transparency, .alpha, .layers, .metadata, .links, .filters]
        case .dxf:
            return [.vector, .layers]
        case .png, .webp, .heic, .avif:
            return [.alpha, .colorProfiles, .scales]
        case .jpeg:
            return [.colorProfiles, .cmyk, .scales]
        case .gif:
            return [.alpha, .scales]
        case .tiff:
            return [.alpha, .colorProfiles, .cmyk, .scales]
        case .psd:
            return [.alpha, .layers, .colorProfiles, .cmyk, .metadata, .scales]
        case .bmp, .targa:
            return [.alpha, .scales]
        case .rtf:
            // Every page's text goes into one file.
            return [.multiPage, .text]
        case .text:
            return [.multiPage]
        }
    }
}

/// What an export format (or an exporter) can carry.
public struct ExportCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Several pages in one file (PDF); every other format writes one file per page.
    public static let multiPage = ExportCapabilities(rawValue: 1 << 0)
    /// Paths stay paths.
    public static let vector = ExportCapabilities(rawValue: 1 << 1)
    /// Text stays text (selectable, searchable).
    public static let text = ExportCapabilities(rawValue: 1 << 2)
    /// Live transparency and blending.
    public static let transparency = ExportCapabilities(rawValue: 1 << 3)
    /// An alpha channel (bitmaps) or transparent areas (vector).
    public static let alpha = ExportCapabilities(rawValue: 1 << 4)
    /// Document layers survive as the format's layers or groups.
    public static let layers = ExportCapabilities(rawValue: 1 << 5)
    /// Document Info as metadata.
    public static let metadata = ExportCapabilities(rawValue: 1 << 6)
    /// An embedded ICC profile.
    public static let colorProfiles = ExportCapabilities(rawValue: 1 << 7)
    /// Named spot colors.
    public static let spotColors = ExportCapabilities(rawValue: 1 << 8)
    /// CMYK color.
    public static let cmyk = ExportCapabilities(rawValue: 1 << 9)
    /// Attached URLs as links.
    public static let links = ExportCapabilities(rawValue: 1 << 10)
    /// Blur, shadow and glow kept live as filters.
    public static let filters = ExportCapabilities(rawValue: 1 << 11)
    /// Several scale factors (1×, 2×, 3×), one file each.
    public static let scales = ExportCapabilities(rawValue: 1 << 12)
}
