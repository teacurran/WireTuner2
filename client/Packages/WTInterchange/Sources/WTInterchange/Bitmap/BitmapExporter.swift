// Bitmap export (export-bitmap.adoc; IO-021, IO-022): PNG, JPEG, TIFF and BMP through ImageIO,
// Targa by its own writer, GIF and the 8-bit palette PNG and TIFF depths through the quantizer,
// one file per page and scale.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WTRender

public struct BitmapExporter: Exporter {
    public let format: ExportFormat

    /// The formats this exporter writes.
    static let formats: [ExportFormat] = [.png, .jpeg, .tiff, .bmp, .targa, .gif, .webp, .heic, .avif]

    /// Whether this Mac's ImageIO can encode `format` (WebP, HEIC and AVIF vary by macOS).
    public static func canEncode(_ format: ExportFormat) -> Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(format.typeIdentifier)
    }

    /// An exporter for PNG, JPEG, TIFF, BMP, Targa, GIF, WebP, HEIC or AVIF.
    public init(format: ExportFormat) {
        precondition(BitmapExporter.formats.contains(format), "\(format) is not a bitmap format this exporter writes")
        self.format = format
    }

    public var optionsType: any ExportOptions.Type {
        switch format {
        case .png: return PNGOptions.self
        case .jpeg: return JPEGOptions.self
        case .tiff: return TIFFOptions.self
        case .bmp: return BMPOptions.self
        case .gif: return GIFOptions.self
        case .webp: return WebPOptions.self
        case .heic: return HEICOptions.self
        case .avif: return AVIFOptions.self
        default: return TargaOptions.self
        }
    }

    /// The common options as rendered: GIF's own *Transparent background* replaces the common
    /// background choice.
    static func effectiveCommon(_ options: any BitmapFormatOptions) -> BitmapCommonOptions {
        var common = options.common
        if let gif = options as? GIFOptions {
            common.background = gif.transparent ? .transparent : (common.background == .transparent ? .white : common.background)
        }
        return common
    }

    public var capabilities: ExportCapabilities { format.capabilities }

    /// How one format lays out its pixels for `options`.
    struct Layout {
        var bitsPerComponent: Int
        var alpha: Bool
    }

    /// Validates the format's own options against the common ones and returns the layout.
    func layout(for options: any BitmapFormatOptions) throws -> Layout {
        let common = BitmapExporter.effectiveCommon(options)
        try common.validate()
        let transparent = common.background == .transparent
        func require(_ bits: Int, in allowed: [Int]) throws {
            guard allowed.contains(bits) else {
                throw ExportError.invalidOption("\(format.displayName) bit depth must be one of \(allowed.map(String.init).joined(separator: ", ")).")
            }
        }
        var layout: Layout
        switch options {
        case let png as PNGOptions:
            try require(png.bits, in: [8, 24, 32, 48, 64])
            if png.bits == 8 {
                try png.palette.validate()
            }
            layout = Layout(bitsPerComponent: png.bits >= 48 ? 16 : 8, alpha: png.bits == 32 || png.bits == 64 || (png.bits == 8 && transparent))
        case let jpeg as JPEGOptions:
            guard (1...100).contains(jpeg.quality) else {
                throw ExportError.invalidOption("JPEG quality must be 1 to 100.")
            }
            layout = Layout(bitsPerComponent: 8, alpha: false)
        case let tiff as TIFFOptions:
            try require(tiff.bits, in: common.color == .cmyk ? [32] : (common.color == .gray ? [24, 32, 48, 64] : [8, 24, 32, 48, 64]))
            if tiff.bits == 8 {
                try tiff.palette.validate()
            }
            layout = Layout(bitsPerComponent: tiff.bits >= 48 ? 16 : 8, alpha: common.color == .rgb && (tiff.bits == 32 || tiff.bits == 64))
        case let bmp as BMPOptions:
            try require(bmp.bits, in: [24, 32])
            if bmp.rle {
                throw ExportError.invalidOption("BMP RLE compression applies to 8-bit images, which need IO-022's palette quantizer.")
            }
            layout = Layout(bitsPerComponent: 8, alpha: bmp.bits == 32)
        case let targa as TargaOptions:
            try require(targa.bits, in: [8, 16, 24, 32])
            layout = Layout(bitsPerComponent: 8, alpha: targa.bits == 16 || targa.bits == 32)
        case let gif as GIFOptions:
            try gif.palette.validate()
            guard common.color == .rgb else {
                throw ExportError.invalidOption("GIF palettes are RGB: choose RGB color (a Grayscale palette gives grey output).")
            }
            layout = Layout(bitsPerComponent: 8, alpha: gif.transparent)
        case let webp as WebPOptions:
            try BitmapExporter.requireQuality(webp.quality, format: .webp)
            layout = Layout(bitsPerComponent: 8, alpha: transparent)
        case let heic as HEICOptions:
            try BitmapExporter.requireQuality(heic.quality, format: .heic)
            layout = Layout(bitsPerComponent: 8, alpha: transparent)
        case let avif as AVIFOptions:
            try BitmapExporter.requireQuality(avif.quality, format: .avif)
            guard (0...10).contains(avif.speed) else {
                throw ExportError.invalidOption("AVIF speed must be 0 to 10.")
            }
            if avif.lossless {
                throw ExportError.invalidOption("Lossless AVIF is not available: macOS's AVIF encoder is lossy only.  Choose PNG or lossless WebP for exact pixels.")
            }
            layout = Layout(bitsPerComponent: 8, alpha: transparent)
        default:
            throw ExportError.wrongOptions(format: format)
        }
        if [.webp, .heic, .avif].contains(format) && !BitmapExporter.canEncode(format) {
            throw ExportError.encoderUnavailable(format)
        }
        if common.color == .cmyk && ![.jpeg, .tiff].contains(format) {
            throw ExportError.unsupported(.cmyk, format: format)
        }
        if transparent && !(layout.alpha && common.color == .rgb) {
            throw ExportError.unsupported(.alpha, format: format)
        }
        if common.maskLayer != nil && !(transparent && layout.alpha) {
            throw ExportError.invalidOption("Mask from layer needs a transparent background and a format depth with alpha.")
        }
        if format == .targa, let targa = options as? TargaOptions, (targa.bits == 8) != (common.color == .gray) {
            throw ExportError.invalidOption("8-bit Targa is greyscale: choose Grayscale color with 8 bits, or RGB with 16, 24 or 32.")
        }
        return layout
    }

    public func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination) throws -> ExportSummary {
        guard let options = options as? any BitmapFormatOptions, type(of: options) == optionsType else {
            throw ExportError.wrongOptions(format: format)
        }
        let layout = try layout(for: options)
        guard !scene.pages.isEmpty else {
            throw ExportError.nothingToExport
        }
        let common = BitmapExporter.effectiveCommon(options)
        var destination = destination
        if common.scales.count > 1, let pattern = destination.namePattern, !pattern.rawValue.contains("{scale}") {
            destination.namePattern = FileNamePattern(pattern.rawValue + "{scale}")
        }
        let jobs = scene.pages.indices.flatMap { page in common.scales.map { (page, $0) } }
        let urls = try destination.urls(count: jobs.count, format: format) { index in
            let (page, scale) = jobs[index]
            return FileNamePattern.Values(name: scene.name, page: page + 1, pageName: scene.pages[page].name, scale: scale)
        }
        let rasterizer = BitmapRasterizer(common: common, output: WTColor.OutputContext.withGamut(of: scene))
        var summary = ExportSummary()
        var clipped = 0
        for ((page, scale), url) in zip(jobs, urls) {
            let rendered = rasterizer.render(scene.pages[page], scale: scale, bitsPerComponent: layout.bitsPerComponent, alpha: layout.alpha)
            clipped = max(clipped, rendered.clipped)
            try write(rendered.bitmap, options: options, pixelsPerInch: common.ppi * scale, metadata: scene.info.metadataWriter(documentName: scene.name), to: url)
            summary.files.append(url)
        }
        if let warning = WTColor.OutputContext.clippedWarning(clipped) {
            summary.notes.append(warning)
        }
        if let avif = options as? AVIFOptions, avif.speed != AVIFOptions.defaults.speed {
            summary.notes.append("AVIF speed is chosen by macOS's encoder; the Speed setting has no effect")
        }
        return summary
    }

    static func requireQuality(_ quality: Int, format: ExportFormat) throws {
        guard (1...100).contains(quality) else {
            throw ExportError.invalidOption("\(format.displayName) quality must be 1 to 100.")
        }
    }

    /// The file of a format this exporter writes by its own code (Targa, GIF, palette PNG and
    /// TIFF); nil for the ImageIO formats.
    func ownEncoding(_ bitmap: RasterBitmap, options: any BitmapFormatOptions, pixelsPerInch: Double) throws -> Data? {
        switch options {
        case let targa as TargaOptions:
            return TargaWriter.data(bitmap, bits: targa.bits, rle: targa.rle)
        case let gif as GIFOptions:
            let image = try Quantizer.indexed(StraightPixels(bitmap), settings: gif.palette, transparent: gif.transparent, matte: gif.matte)
            return GIFWriter.data(image, interlaced: gif.interlaced)
        case let png as PNGOptions where png.bits == 8:
            let image = try Quantizer.indexed(StraightPixels(bitmap), settings: png.palette, transparent: bitmap.hasAlpha, matte: .white)
            return PalettePNGWriter.data(image, interlaced: png.interlaced, pixelsPerInch: pixelsPerInch)
        case let tiff as TIFFOptions where tiff.bits == 8:
            guard tiff.compression != .jpeg else {
                throw ExportError.invalidOption("8-bit palette TIFF cannot use JPEG compression.")
            }
            let image = try Quantizer.indexed(StraightPixels(bitmap), settings: tiff.palette, transparent: false, matte: .white)
            let codes: [TIFFOptions.Compression: Int] = [.none: 1, .lzw: 5, .zip: 8]
            return PaletteTIFFWriter.data(image, compression: codes[tiff.compression]!, pixelsPerInch: pixelsPerInch)
        default:
            return nil
        }
    }

    /// Encodes `bitmap` as this format.
    func write(_ bitmap: RasterBitmap, options: any BitmapFormatOptions, pixelsPerInch: Double = 72, metadata: MetadataWriter? = nil, to url: URL) throws {
        var data = try ownEncoding(bitmap, options: options, pixelsPerInch: pixelsPerInch) ?? imageIOEncoding(bitmap, options: options, url: url)
        // Document Info goes in as XMP added to the encoded file without re-encoding (IO-012):
        // an iTXt chunk in PNG, ImageIO's metadata rewrite elsewhere (which also writes the IIM
        // record of JPEG and TIFF).  BMP, Targa and GIF have nowhere standard to put it.
        if let metadata, let embedded = format == .png ? metadata.png(data) : metadata.embed(in: data), ![.bmp, .targa, .gif].contains(format) {
            data = embedded
        }
        do {
            try data.write(to: url)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    /// `bitmap` encoded by ImageIO with the format's options.
    func imageIOEncoding(_ bitmap: RasterBitmap, options: any BitmapFormatOptions, url: URL) throws -> Data {
        var properties: [CFString: Any] = [:]
        switch options {
        case let png as PNGOptions:
            var dictionary: [CFString: Any] = [:]
            if png.interlaced {
                dictionary[kCGImagePropertyPNGInterlaceType] = 1
            }
            if png.fast {
                dictionary[kCGImagePropertyPNGCompressionFilter] = 0  // IMAGEIO_PNG_NO_FILTERS
            }
            properties[kCGImagePropertyPNGDictionary] = dictionary
        case let jpeg as JPEGOptions:
            properties[kCGImageDestinationLossyCompressionQuality] = Double(jpeg.quality) / 100
            if jpeg.progressive {
                properties[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true]
            }
        case let tiff as TIFFOptions:
            let codes: [TIFFOptions.Compression: Int] = [.none: 1, .lzw: 5, .zip: 8, .jpeg: 7]
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: codes[tiff.compression]!]
            if tiff.compression == .jpeg {
                properties[kCGImageDestinationLossyCompressionQuality] = Double(tiff.jpegQuality) / 100
            }
        case let webp as WebPOptions:
            properties[kCGImageDestinationLossyCompressionQuality] = webp.lossless ? 1.0 : Double(webp.quality) / 100
        case let heic as HEICOptions:
            properties[kCGImageDestinationLossyCompressionQuality] = Double(heic.quality) / 100
        case let avif as AVIFOptions:
            // ImageIO's AVIF encoder refuses quality 1.0 (it has no lossless mode).
            properties[kCGImageDestinationLossyCompressionQuality] = min(Double(avif.quality) / 100, 0.99)
        default:
            break
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.typeIdentifier as CFString, 1, nil) else {
            throw ExportError.writeFailed("cannot create \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, bitmap.image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.writeFailed("\(format.displayName) encoding failed for \(url.lastPathComponent)")
        }
        return output as Data
    }
}

/// The Targa writer (export-bitmap.adoc, "BMP and Targa"): uncompressed or RLE true-colour
/// (types 2 and 10) at 16, 24 or 32 bits and greyscale (types 3 and 11) at 8 bits, rows stored
/// top to bottom, alpha straight.
enum TargaWriter {
    static func data(_ bitmap: RasterBitmap, bits: Int, rle: Bool) -> Data {
        let gray = bits == 8
        var header = [UInt8](repeating: 0, count: 18)
        header[2] = UInt8((gray ? 3 : 2) + (rle ? 8 : 0))
        header[12] = UInt8(bitmap.width & 0xFF)
        header[13] = UInt8(bitmap.width >> 8)
        header[14] = UInt8(bitmap.height & 0xFF)
        header[15] = UInt8(bitmap.height >> 8)
        header[16] = UInt8(bits)
        let alphaBits: UInt8 = bits == 32 ? 8 : (bits == 16 ? 1 : 0)
        header[17] = 0x20 | alphaBits  // top-left origin
        var output = Data(header)
        let pixelBytes = bits / 8
        for band in 0..<bitmap.bandCount {
            let rows = bitmap.band(band)
            let rowCount = rows.count / bitmap.bytesPerRow
            rows.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for row in 0..<rowCount {
                    var pixels = [UInt8]()
                    pixels.reserveCapacity(bitmap.width * pixelBytes)
                    for column in 0..<bitmap.width {
                        let base = row * bitmap.bytesPerRow + column * bitmap.components
                        if gray {
                            pixels.append(source[base])
                            continue
                        }
                        var red = Int(source[base]), green = Int(source[base + 1]), blue = Int(source[base + 2])
                        let alpha = bitmap.hasAlpha ? Int(source[base + 3]) : 255
                        if alpha > 0 && alpha < 255 {
                            red = min(255, (red * 255 + alpha / 2) / alpha)
                            green = min(255, (green * 255 + alpha / 2) / alpha)
                            blue = min(255, (blue * 255 + alpha / 2) / alpha)
                        }
                        switch bits {
                        case 16:
                            let value = UInt16(alpha >= 128 ? 0x8000 : 0) | UInt16(red >> 3) << 10 | UInt16(green >> 3) << 5 | UInt16(blue >> 3)
                            pixels += [UInt8(value & 0xFF), UInt8(value >> 8)]
                        case 24:
                            pixels += [UInt8(blue), UInt8(green), UInt8(red)]
                        default:
                            pixels += [UInt8(blue), UInt8(green), UInt8(red), UInt8(alpha)]
                        }
                    }
                    output.append(contentsOf: rle ? encodeRLE(pixels, pixelBytes: pixelBytes) : pixels)
                }
            }
        }
        // TGA 2.0 footer: no extension or developer area.
        output.append(contentsOf: [UInt8](repeating: 0, count: 8))
        output.append(contentsOf: Array("TRUEVISION-XFILE.".utf8) + [0])
        return output
    }

    /// One row as Targa run-length packets (runs never cross rows).
    static func encodeRLE(_ pixels: [UInt8], pixelBytes: Int) -> [UInt8] {
        let count = pixels.count / pixelBytes
        func pixel(_ index: Int) -> ArraySlice<UInt8> {
            pixels[(index * pixelBytes)..<((index + 1) * pixelBytes)]
        }
        var result = [UInt8]()
        var index = 0
        while index < count {
            var run = 1
            while index + run < count && run < 128 && pixel(index + run) == pixel(index) {
                run += 1
            }
            if run > 1 {
                result.append(UInt8(0x80 | (run - 1)))
                result += pixel(index)
                index += run
                continue
            }
            var literal = 1
            while index + literal < count && literal < 128 && (index + literal + 1 >= count || pixel(index + literal) != pixel(index + literal + 1)) {
                literal += 1
            }
            result.append(UInt8(literal - 1))
            result += pixels[(index * pixelBytes)..<((index + literal) * pixelBytes)]
            index += literal
        }
        return result
    }
}
