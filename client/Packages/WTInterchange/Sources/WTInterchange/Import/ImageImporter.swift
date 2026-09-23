// Bitmap import (importing.adoc, "Client"; IMG-002, IMG-015): ImageIO probes the file for the
// `PixelSource` facts without decoding pixels, the original bytes become the blob, and two
// preferences-driven rewrites happen before placement -- an image whose EXIF orientation is not
// upright is re-encoded upright as PNG, so the stored dimensions are the ones the user sees, and
// an image over *Downsample images larger than* is resampled to that many pixels (PNG for
// lossless sources, JPEG at 0.92 for lossy ones) with its resolution scaled so its natural size
// is unchanged.  The same decoder serves the vector importers' embedded images.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WTGeometry
import WTRender

public struct ImageImporter: Importer {
    public init() {}

    public var formats: [ImportFormat] { ImportFormat.allCases.filter(\.isBitmap) }

    /// A decoded image ready to place.
    public struct Decoded: Hashable, Sendable {
        public var pixels: ImportedPixels
        public var dpiX: Double
        public var dpiY: Double
        /// What was changed on the way in ("downsampled to 50 MP", "rotated upright").
        public var notes: [String]

        /// The image node, named `name`, at the origin.
        public func image(name: String?) -> ImportedImage {
            ImportedImage(pixels: pixels, dpiX: dpiX, dpiY: dpiY, name: name)
        }
    }

    /// The facts ImageIO reports for the first image of a file.
    struct Facts {
        var uti: String
        var width: Int
        var height: Int
        var mode: ImportedColorMode
        var bits: Int
        var hasAlpha: Bool
        var dpiX: Double
        var dpiY: Double
        var orientation: Int
        var lab: Bool
        var frames: Int
    }

    // MARK: Importer

    public func probe(_ data: Data, name: String, format: ImportFormat) throws -> ImportDescriptor {
        let (source, facts) = try ImageImporter.facts(of: data, name: name)
        let upright = facts.orientation >= 5
        let width = upright ? facts.height : facts.width
        let height = upright ? facts.width : facts.height
        let natural = ImageItem.naturalRect(pixelWidth: width, pixelHeight: height, dpiX: upright ? facts.dpiY : facts.dpiX, dpiY: upright ? facts.dpiX : facts.dpiY)
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        return ImportDescriptor(format: format, naturalSize: natural, pixelWidth: width, pixelHeight: height, colorMode: facts.mode, preview: CGImageSourceCreateThumbnailAtIndex(source, 0, options))
    }

    public func convert(_ data: Data, name: String, format: ImportFormat, options: ImportOptionValues, context: ImportContext) throws -> ImportedScene {
        let decoded = try decode(data, name: name, context: context)
        let image = decoded.image(name: name)
        return ImportedScene(kind: .bitmap, name: name, bounds: image.naturalRect, nodes: [.image(image)], notes: decoded.notes)
    }

    // MARK: Decoding

    /// `data` as a placed image's pixel source: probed, oriented upright, downsampled per
    /// `context`, refused with a message naming `name` when unreadable.
    public func decode(_ data: Data, name: String, context: ImportContext = ImportContext()) throws -> Decoded {
        try context.checkSize(data.count, name: name)
        let (source, facts) = try ImageImporter.facts(of: data, name: name)
        var notes: [String] = []
        if facts.frames > 1 {
            notes.append("“\(name)” has \(facts.frames) frames or pages; the first was imported.")
        }
        if facts.lab {
            notes.append("“\(name)” is a Lab image; it is shown and exported through its RGB rendering.")
        }
        var blob = ImportedBlob(data: data, uti: facts.uti)
        var current = facts
        let pixelCount = facts.width * facts.height
        let downsample = context.downsampleLimit.map { pixelCount > $0 } ?? false
        if facts.orientation != 1 || downsample {
            var width = facts.orientation >= 5 ? facts.height : facts.width
            var height = facts.orientation >= 5 ? facts.width : facts.height
            var dpiX = facts.orientation >= 5 ? facts.dpiY : facts.dpiX
            var dpiY = facts.orientation >= 5 ? facts.dpiX : facts.dpiY
            var maxSide = max(width, height)
            if downsample, let limit = context.downsampleLimit {
                let factor = (Double(limit) / Double(pixelCount)).squareRoot()
                maxSide = max(Int((Double(maxSide) * factor).rounded(.down)), 1)
            }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceShouldCacheImmediately: false,
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                throw ImportError.unreadable(name: name, reason: "its pixels could not be decoded.")
            }
            let lossy = ImageImporter.isLossy(facts.uti)
            let type: UTType = lossy && downsample ? .jpeg : .png
            let encoded = ImageEncoding.encode(image, type: type, properties: type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:])!
            dpiX *= Double(image.width) / Double(width)
            dpiY *= Double(image.height) / Double(height)
            width = image.width
            height = image.height
            blob = ImportedBlob(data: encoded, uti: type.identifier)
            let reprobed = try ImageImporter.facts(of: encoded, name: name).facts
            current = reprobed
            current.dpiX = dpiX
            current.dpiY = dpiY
            // Re-encoding keeps the source's gray, indexed or bilevel nature only as far as
            // PNG and JPEG carry it; the source's mode is what the user chose, so keep it
            // where the new encoding can hold it.
            if facts.mode == .grayscale || facts.mode == .bilevel {
                current.mode = reprobed.mode == .grayscale ? facts.mode : reprobed.mode
            }
            if facts.orientation != 1 {
                notes.append("“\(name)” was turned upright from its orientation metadata.")
            }
            if downsample {
                let megapixels = Double(width * height) / 1_000_000
                notes.append("“\(name)” was downsampled to \(String(format: "%.1f", megapixels)) megapixels (\(width) × \(height)).")
            }
        }
        let pixels = ImportedPixels(blob: blob, width: current.width, height: current.height, mode: current.mode, bitsPerChannel: current.bits, hasAlpha: current.hasAlpha)
        return Decoded(pixels: pixels, dpiX: current.dpiX, dpiY: current.dpiY, notes: notes)
    }

    /// A generated or extracted image (a PDF image XObject, an SVG data URL's pixels that
    /// needed re-encoding) as a lossless PNG pixel source at 72 ppi.
    public static func pixels(of image: CGImage) -> ImportedPixels {
        let data = ImageEncoding.encode(image, type: .png)!
        let facts = (try? ImageImporter.facts(of: data, name: "").facts)
        return ImportedPixels(blob: ImportedBlob(data: data, uti: UTType.png.identifier), width: image.width, height: image.height, mode: facts?.mode ?? .rgb, bitsPerChannel: facts?.bits ?? 8, hasAlpha: facts?.hasAlpha ?? ImageEncoding.hasAlpha(image))
    }

    static func isLossy(_ uti: String) -> Bool {
        [UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier, "public.avif", UTType.webP.identifier].contains(uti)
    }

    /// ImageIO's facts for the first image, without decoding pixels.
    static func facts(of data: Data, name: String) throws -> (source: CGImageSource, facts: Facts) {
        if let bits = ImageImporter.jpegPrecision(data), bits > 8 {
            throw ImportError.unsupportedJPEGPrecision(name: name, bits: bits)
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let uti = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0 else {
            throw ImportError.unreadable(name: name, reason: "it is damaged or is not an image this Mac can read.")
        }
        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
        let model = properties[kCGImagePropertyColorModel] as? String ?? "RGB"
        // ImageIO reports `IsIndexed` only once an image has been decoded, so palette files are
        // recognised from their own headers: PNG colour type 3, TIFF photometric 3.
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let indexed = properties[kCGImagePropertyIsIndexed] as? Bool == true
            || (uti == "public.png" && data.count > 25 && data[data.startIndex + 25] == 3)
            || tiff?[kCGImagePropertyTIFFPhotometricInterpretation] as? Int == 3
        var mode: ImportedColorMode
        switch model {
        case "Gray":
            mode = depth == 1 ? .bilevel : (indexed ? .indexed : .grayscale)
        case "CMYK":
            mode = .cmyk
        default:
            mode = indexed ? .indexed : .rgb
        }
        var hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        // ImageIO reports every GIF as RGB with alpha; a GIF is a palette image whose alpha is
        // its first frame's transparent colour, if it declares one.
        if uti == "com.compuserve.gif" {
            mode = .indexed
            hasAlpha = ImageImporter.gifHasTransparency(data)
        }
        let bits = mode == .bilevel ? 1 : (depth > 8 ? 16 : 8)
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let dpiX = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        let dpiY = properties[kCGImagePropertyDPIHeight] as? Double ?? dpiX
        let facts = Facts(
            uti: uti, width: width, height: height, mode: mode, bits: bits,
            hasAlpha: hasAlpha,
            dpiX: dpiX > 0 ? dpiX : 72, dpiY: dpiY > 0 ? dpiY : 72,
            orientation: (1...8).contains(orientation) ? orientation : 1,
            lab: model == "Lab",
            frames: CGImageSourceGetCount(source))
        return (source, facts)
    }

    /// Whether a GIF's first frame declares a transparent colour: the Graphic Control
    /// Extension before its image descriptor has the transparency flag set.
    static func gifHasTransparency(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count > 13 else {
            return false
        }
        var index = 13
        if bytes[10] & 0x80 != 0 {
            index += 3 << (Int(bytes[10] & 0x07) + 1)
        }
        while index < bytes.count {
            switch bytes[index] {
            case 0x21:
                guard index + 1 < bytes.count else { return false }
                if bytes[index + 1] == 0xF9, index + 3 < bytes.count {
                    return bytes[index + 3] & 0x01 != 0
                }
                // Skip the extension's sub-blocks.
                index += 2
                while index < bytes.count, bytes[index] != 0 {
                    index += Int(bytes[index]) + 1
                }
                index += 1
            default:
                // An image descriptor (or anything else) before any control extension.
                return false
            }
        }
        return false
    }

    /// The sample precision of a JPEG's frame header (SOF0-SOF15 except DHT, JPG and DAC), or
    /// nil for anything else.
    static func jpegPrecision(_ data: Data) -> Int? {
        let bytes = [UInt8](data.prefix(65_536))
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            return nil
        }
        var index = 2
        while index + 4 < bytes.count {
            guard bytes[index] == 0xFF else {
                return nil
            }
            let marker = bytes[index + 1]
            if marker == 0xFF {
                index += 1
                continue
            }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker) {
                return index + 4 < bytes.count ? Int(bytes[index + 4]) : nil
            }
            if marker == 0xDA || length < 2 {
                return nil
            }
            index += 2 + length
        }
        return nil
    }
}

// MARK: - Pasteboard

/// The pasteboard reader (importing.adoc, "Pasting"; IMG-002): of the representations a
/// pasteboard offers, the one import should read.  {product} objects are the app's own paste
/// path and are not read here; after them PDF wins over any image type.
public enum ImportPasteboard {
    /// The app's own objects type, preferred over everything (read by `WTModel`).
    public static let objectsType = "com.villagecompute.wiretuner.objects"

    /// What to import from `representations` (UTI and bytes, in the pasteboard's order): nil
    /// when the app's objects are present or nothing importable is.
    public static func choose(_ representations: [(type: String, data: Data)]) -> (format: ImportFormat, data: Data)? {
        if representations.contains(where: { $0.type == objectsType }) {
            return nil
        }
        if let pdf = representations.first(where: { $0.type == "com.adobe.pdf" }) {
            return (.pdf, pdf.data)
        }
        for representation in representations {
            guard let type = UTType(representation.type), type.conforms(to: .image) else {
                continue
            }
            if let format = ImportFormat.sniff(representation.data) ?? ImportFormat(uti: representation.type), format.isBitmap {
                return (format, representation.data)
            }
        }
        return nil
    }

    /// The pasteboard's contents converted: a PDF through `registry`'s PDF importer, an image
    /// through its image importer, named `name` ("Pasted").
    public static func convert(_ representations: [(type: String, data: Data)], registry: ImportRegistry, name: String = "Pasted", context: ImportContext = ImportContext()) throws -> ImportedScene? {
        guard let (format, data) = choose(representations), let importer = registry.importer(for: format) else {
            return nil
        }
        return try importer.convert(data, name: name, format: format, options: importer.optionsSchema(for: format).defaults, context: context)
    }
}
