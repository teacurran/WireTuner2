// The interchange clipboard formats (copying.adoc, "Clipboard formats"; OBJ-015): which formats
// a copy writes, the pasteboard types each one carries, and the three preferences that govern
// them -- *Clipboard formats*, *Convert colors to* and *Clipboard image resolution*.

import Foundation

/// One row of the *Clipboard formats* preference and of the Copy Special / Paste Special sheets.
public enum ClipboardFormat: String, CaseIterable, Hashable, Sendable, Codable {
    /// The {product} objects payload (`ClipboardPayload`), written and read by the app.
    case native
    case pdf
    case svg
    /// A rasterized picture, as TIFF and PNG.
    case image
    case rtf
    case plainText

    /// The native pasteboard type (copying.adoc, "Client").
    public static let nativeType = ImportPasteboard.objectsType
    /// The name earlier builds wrote the native type under; still read, never written.
    public static let legacyNativeType = "com.wiretuner.objects"
    public static let pdfType = "com.adobe.pdf"
    public static let svgType = "public.svg-image"
    public static let tiffType = "public.tiff"
    public static let pngType = "public.png"
    public static let rtfType = "public.rtf"
    public static let plainTextType = "public.utf8-plain-text"

    /// The pasteboard types a copy in this format writes, in the order they are offered.
    public var writtenTypes: [String] {
        switch self {
        case .native: [Self.nativeType]
        case .pdf: [Self.pdfType]
        case .svg: [Self.svgType]
        case .image: [Self.tiffType, Self.pngType]
        case .rtf: [Self.rtfType]
        case .plainText: [Self.plainTextType]
        }
    }

    /// The pasteboard types a paste in this format reads, preferred first (PNG keeps alpha
    /// exactly, so it wins over TIFF; the legacy native name is read after the current one).
    public var readTypes: [String] {
        switch self {
        case .native: [Self.nativeType, Self.legacyNativeType]
        case .image: [Self.pngType, Self.tiffType]
        default: writtenTypes
        }
    }

    /// The name in the preference and the sheets.
    public var displayName: String {
        switch self {
        case .native: "WireTuner"
        case .pdf: "PDF"
        case .svg: "SVG"
        case .image: "Image (TIFF and PNG)"
        case .rtf: "Rich text (RTF)"
        case .plainText: "Plain text"
        }
    }

    /// Whether the format carries only text: written only when the selection holds text.
    public var isText: Bool { self == .rtf || self == .plainText }

    /// Paste's order, richest first ("Pasting into {product} takes the richest format present").
    public static let richestFirst: [ClipboardFormat] = [.native, .pdf, .svg, .image, .rtf, .plainText]

    /// The format a pasteboard type belongs to, nil for a type none reads.
    public init?(pasteboardType type: String) {
        guard let format = Self.richestFirst.first(where: { $0.readTypes.contains(type) }) else { return nil }
        self = format
    }
}

/// *Convert colors to* (menu:WireTuner[Settings… > Export]): the colours of the PDF and SVG
/// copies.
public enum ClipboardColors: String, CaseIterable, Hashable, Sendable, Codable {
    case cmyk
    case rgb
    /// Each colour as the document holds it (the default).
    case cmykAndRGB

    public var displayName: String {
        switch self {
        case .cmyk: "CMYK"
        case .rgb: "RGB"
        case .cmykAndRGB: "CMYK and RGB"
        }
    }

    /// The PDF copy's colour conversion.
    public var pdfColors: PDFOptions.Colors {
        switch self {
        case .cmyk: .convertToCMYK
        case .rgb: .convertToRGB
        case .cmykAndRGB: .keep
        }
    }
}

/// The clipboard preferences (copying.adoc, "Client"): every format on, colours as held, 144 ppi.
public struct ClipboardSettings: Hashable, Sendable, Codable {
    /// The formats a Copy writes; the native format is always included.
    public var formats: Set<ClipboardFormat>
    public var colors: ClipboardColors
    /// *Clipboard image resolution* in pixels per inch.
    public var imageResolution: Double

    /// The preference's range and default.
    public static let imageResolutionRange: ClosedRange<Double> = 72...2400
    public static let defaultImageResolution: Double = 144

    public init(formats: Set<ClipboardFormat> = Set(ClipboardFormat.allCases), colors: ClipboardColors = .cmykAndRGB,
                imageResolution: Double = ClipboardSettings.defaultImageResolution) {
        self.formats = formats.union([.native])
        self.colors = colors
        self.imageResolution = min(max(imageResolution, Self.imageResolutionRange.lowerBound), Self.imageResolutionRange.upperBound)
    }

    /// The formats the preference lets the user switch off (every one but native).
    public static let optionalFormats: [ClipboardFormat] = ClipboardFormat.richestFirst.filter { $0 != .native }

    /// These settings with `format` on or off (native stays on).
    public func setting(_ format: ClipboardFormat, enabled: Bool) -> ClipboardSettings {
        var copy = self
        if enabled { copy.formats.insert(format) } else if format != .native { copy.formats.remove(format) }
        return copy
    }

    /// The settings of Copy Special: `format` alone (plus native only when it is the choice).
    public func only(_ format: ClipboardFormat) -> ClipboardSettings {
        var copy = self
        copy.formats = [format]
        return copy
    }
}
