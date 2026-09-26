// *Optimize Image* (IMG-020; docs/_includes/imported/external-editors.adoc, "Optimizing an
// image", "Client"): re-encodes a placed image's blob -- another format, a lossy quality,
// downsampled to an effective resolution or a longest edge, converted to grayscale or RGB,
// metadata stripped -- keeping its ICC profile and, where the format can hold it, its alpha.
// The sheet shows the before/after sizes from `plan` and the stored size from `estimate`
// (the same encode into memory, run on a background task and cancelled on change); btn:
// [Optimize] writes the result as the image's new pixels (WTModel's `OptimizeImages`).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WTGeometry

/// The sheet's settings.
public struct ImageOptimizeOptions: Hashable, Sendable {
    public enum Format: String, Hashable, Sendable, CaseIterable {
        /// The image's current format.
        case keep
        case png
        case jpeg
        case tiff
        case webp
        case heic

        /// The UTI written, nil for *Keep*.
        public var typeIdentifier: String? {
            switch self {
            case .keep: nil
            case .png: UTType.png.identifier
            case .jpeg: UTType.jpeg.identifier
            case .tiff: UTType.tiff.identifier
            case .webp: UTType.webP.identifier
            case .heic: UTType.heic.identifier
            }
        }

        /// Whether the format stores alpha (JPEG does not; the sheet dims it for images whose
        /// alpha is displayed).
        public var holdsAlpha: Bool { self != .jpeg }

        /// Whether *Quality* applies.
        public var isLossy: Bool { self == .jpeg || self == .webp || self == .heic }

        /// Whether this Mac can write the format (*Keep* always).
        public var isAvailable: Bool {
            typeIdentifier.map { (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains($0) } ?? true
        }
    }

    public enum Resample: Hashable, Sendable {
        case none
        /// Resample so the image has this many pixels per inch at its placed size.
        case effectiveResolution(Double)
        /// Resample so the longer edge has this many pixels.
        case pixelSize(Int)
    }

    public enum ColorMode: Hashable, Sendable {
        case keep
        case grayscale
        case rgb
    }

    public var format: Format
    /// JPEG, WebP and HEIC quality, 1 ... 100.
    public var quality: Int
    public var resample: Resample
    public var colorMode: ColorMode
    /// Drops EXIF, XMP, IPTC and GPS (the colour profile and orientation are always kept).
    public var stripMetadata: Bool

    public init(format: Format = .keep, quality: Int = 85, resample: Resample = .none, colorMode: ColorMode = .keep, stripMetadata: Bool = false) {
        self.format = format
        self.quality = quality
        self.resample = resample
        self.colorMode = colorMode
        self.stripMetadata = stripMetadata
    }

    /// Rejects values outside the sheet's ranges.
    public func validate() throws {
        guard (1...100).contains(quality) else { throw ImageOptimizeError.invalidOption("Quality must be 1 to 100.") }
        switch resample {
        case .none: break
        case .effectiveResolution(let ppi):
            guard ppi.isFinite, ppi >= 1, ppi <= 9600 else { throw ImageOptimizeError.invalidOption("The resolution must be 1 to 9,600 ppi.") }
        case .pixelSize(let edge):
            guard edge >= 1 else { throw ImageOptimizeError.invalidOption("The pixel size must be at least 1.") }
        }
        guard format.isAvailable else { throw ImageOptimizeError.invalidOption("This Mac cannot write \(format.rawValue.uppercased()) images.") }
    }
}

/// Why an image could not be optimized.
public enum ImageOptimizeError: Error, Hashable, Sendable {
    case invalidOption(String)
    /// The blob does not decode.
    case unreadable
    /// ImageIO refused to write the result.
    case encodingFailed(String)
}

/// The sheet's before/after readout for one image.
public struct ImageOptimizePlan: Hashable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var targetWidth: Int
    public var targetHeight: Int
    /// Effective resolution now and after, pixels per inch at the placed size.
    public var effectiveResolution: Double
    public var targetResolution: Double

    /// Whether the pixels are resampled.
    public var resamples: Bool { targetWidth != pixelWidth || targetHeight != pixelHeight }
}

/// Re-encodes image blobs.
public enum ImageOptimizer {
    /// The pixel size `options` resample an image of `width` × `height` pixels placed at
    /// `placedWidth` points wide to: downsampling only, the aspect ratio kept, at least 1 px.
    public static func plan(width: Int, height: Int, placedWidth: Double, resample: ImageOptimizeOptions.Resample) -> ImageOptimizePlan {
        var factor = 1.0
        switch resample {
        case .none:
            break
        case .effectiveResolution(let ppi):
            if placedWidth > 0 { factor = min(1, placedWidth / 72 * ppi / Double(width)) }
        case .pixelSize(let edge):
            factor = min(1, Double(edge) / Double(max(width, height)))
        }
        let targetWidth = factor < 1 ? max(Int((Double(width) * factor).rounded()), 1) : width
        let targetHeight = factor < 1 ? max(Int((Double(height) * factor).rounded()), 1) : height
        let effective = placedWidth > 0 ? Double(width) / (placedWidth / 72) : 72
        let target = placedWidth > 0 ? Double(targetWidth) / (placedWidth / 72) : 72
        return ImageOptimizePlan(pixelWidth: width, pixelHeight: height, targetWidth: targetWidth, targetHeight: targetHeight,
                                 effectiveResolution: effective, targetResolution: target)
    }

    /// `data` (a placed image's blob) optimized with `options`; `placedWidth` is the image's
    /// width on the page in points (for *To effective resolution*).
    public static func optimize(_ data: Data, placedWidth: Double, options: ImageOptimizeOptions) throws -> ImportedPixels {
        try options.validate()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let uti = CGImageSourceGetType(source) as String?,
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ImageOptimizeError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let plan = plan(width: image.width, height: image.height, placedWidth: placedWidth, resample: options.resample)
        let gray = options.colorMode == .grayscale || (options.colorMode == .keep && image.colorSpace?.model == .monochrome)
        let rgb = options.colorMode == .rgb && image.colorSpace?.model != .rgb
        if plan.resamples || options.colorMode == .grayscale && image.colorSpace?.model != .monochrome || rgb {
            image = redraw(image, width: plan.targetWidth, height: plan.targetHeight, gray: gray)
        }
        let type = options.format.typeIdentifier ?? uti
        var destination: [CFString: Any] = [:]
        if let orientation = properties[kCGImagePropertyOrientation] { destination[kCGImagePropertyOrientation] = orientation }
        if !options.stripMetadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyGPSDictionary] {
                if let value = properties[key] { destination[key] = value }
            }
        }
        if plan.resamples {
            destination[kCGImagePropertyDPIWidth] = plan.targetResolution
            destination[kCGImagePropertyDPIHeight] = plan.targetResolution
        } else {
            for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
                if let value = properties[key] { destination[key] = value }
            }
        }
        let lossy = ImageOptimizeOptions.Format.allCases.first { $0.typeIdentifier == type }?.isLossy ?? ImageImporter.isLossy(type)
        if lossy { destination[kCGImageDestinationLossyCompressionQuality] = Double(options.quality) / 100 }
        let encoded = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(encoded, type as CFString, 1, nil) else {
            throw ImageOptimizeError.encodingFailed(type)
        }
        CGImageDestinationAddImage(writer, image, destination as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw ImageOptimizeError.encodingFailed(type) }
        let written = encoded as Data
        let facts = try ImageImporter.facts(of: written, name: "").facts
        return ImportedPixels(blob: ImportedBlob(data: written, uti: facts.uti), width: facts.width, height: facts.height, mode: facts.mode,
                              bitsPerChannel: facts.bits, hasAlpha: facts.hasAlpha)
    }

    /// The stored size the sheet shows: the bytes `optimize` writes.
    public static func estimate(_ data: Data, placedWidth: Double, options: ImageOptimizeOptions) throws -> Int {
        try optimize(data, placedWidth: placedWidth, options: options).blob.data.count
    }

    /// `image` resampled to `width` × `height` at high interpolation, in its own colour space
    /// (grayscale in the generic gray profile when `gray`), alpha kept.
    static func redraw(_ image: CGImage, width: Int, height: Int, gray: Bool) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let alpha = ImageEncoding.hasAlpha(image)
        let source = image.colorSpace
        if gray {
            let space = source?.model == .monochrome ? source! : CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
            // Core Graphics draws gray without alpha: the luminance and, for a transparent image,
            // the coverage are drawn apart and interleaved into a gray + alpha image.
            let luminance = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            luminance.interpolationQuality = .high
            if alpha {
                luminance.setFillColor(gray: 0, alpha: 1)
                luminance.fill(rect)
            } else {
                luminance.setFillColor(gray: 1, alpha: 1)
                luminance.fill(rect)
            }
            luminance.draw(image, in: rect)
            guard alpha else { return luminance.makeImage()! }
            let coverage = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            coverage.interpolationQuality = .high
            coverage.draw(image, in: rect)
            let g = luminance.data!.assumingMemoryBound(to: UInt8.self), a = coverage.data!.assumingMemoryBound(to: UInt8.self)
            var bytes = [UInt8](repeating: 0, count: width * height * 2)
            for row in 0..<height {
                for column in 0..<width {
                    let covered = Int(a[row * coverage.bytesPerRow + column * 4 + 3])
                    // Over black, the luminance is premultiplied: divide it back out.
                    let value = Int(g[row * luminance.bytesPerRow + column])
                    bytes[(row * width + column) * 2] = UInt8(covered == 0 ? 0 : min(255, (value * 255 + covered / 2) / covered))
                    bytes[(row * width + column) * 2 + 1] = UInt8(covered)
                }
            }
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 16, bytesPerRow: width * 2, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        // RGB, keeping an RGB image's own profile; CMYK stays CMYK (no alpha there).
        let keep = source.flatMap { $0.model == .rgb || $0.model == .cmyk ? $0 : nil }
        let space = keep ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = space.model == .cmyk ? CGImageAlphaInfo.none.rawValue : (alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage()!
    }
}
