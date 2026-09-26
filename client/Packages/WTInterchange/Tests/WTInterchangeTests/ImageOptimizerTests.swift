// IMG-020: *Optimize Image* -- lossless re-encoding, quality and the estimate, downsampling to an
// effective resolution or a pixel size, colour mode conversion, metadata, and the colour
// profile and alpha surviving every path that can hold them.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WTInterchange
import WTRender

@Suite struct ImageOptimizerTests {
    /// A noisy photograph-like RGB image (so lossy quality changes the size).
    static func photo(width: Int = 120, height: Int = 80, alpha: Bool = false, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        var seed: UInt32 = 7
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_103_515_245 &+ 12345
                let noise = CGFloat(seed >> 24) / 255 * 0.3
                let transparent = alpha && x < width / 3 && y < height / 3
                context.setFillColor(red: CGFloat(x) / CGFloat(width) * 0.7 + noise, green: CGFloat(y) / CGFloat(height) * 0.7, blue: 0.5 - noise, alpha: transparent ? 0.25 : 1)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }

    static func encode(_ image: CGImage, _ type: UTType, properties: [CFString: Any] = [:]) -> Data {
        ImageEncoding.encode(image, type: type, properties: properties)!
    }

    static func decoded(_ pixels: ImportedPixels) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(pixels.blob.data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    static func properties(_ pixels: ImportedPixels) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(pixels.blob.data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    @Test func tiffToPNGIsLossless() throws {
        let image = Self.photo(alpha: true)
        let tiff = Self.encode(image, .tiff)
        let png = try ImageOptimizer.optimize(tiff, placedWidth: 120, options: ImageOptimizeOptions(format: .png))
        #expect(png.blob.uti == UTType.png.identifier && png.hasAlpha && png.width == 120 && png.height == 80)
        #expect(RGBAPixels(try Self.decoded(png)).bytes == RGBAPixels(image).bytes)
        // *Keep* writes the same format.
        #expect(try ImageOptimizer.optimize(tiff, placedWidth: 120, options: ImageOptimizeOptions()).blob.uti == UTType.tiff.identifier)
    }

    @Test func jpegQualityChangesTheEstimateMonotonically() throws {
        let png = Self.encode(Self.photo(width: 200, height: 160), .png)
        let sizes = try [10, 40, 70, 95].map { try ImageOptimizer.estimate(png, placedWidth: 200, options: ImageOptimizeOptions(format: .jpeg, quality: $0)) }
        #expect(sizes == sizes.sorted() && Set(sizes).count == sizes.count, "\(sizes)")
        let jpeg = try ImageOptimizer.optimize(png, placedWidth: 200, options: ImageOptimizeOptions(format: .jpeg, quality: 60))
        #expect(!jpeg.hasAlpha && jpeg.blob.uti == UTType.jpeg.identifier)
    }

    @Test func resamplingDownsamplesOnly() throws {
        // 1200 × 800 placed 2 inches wide is 600 ppi; at 300 ppi it is 600 × 400.
        let plan = ImageOptimizer.plan(width: 1200, height: 800, placedWidth: 144, resample: .effectiveResolution(300))
        #expect(plan.targetWidth == 600 && plan.targetHeight == 400 && plan.resamples)
        #expect(abs(plan.effectiveResolution - 600) < 0.001 && abs(plan.targetResolution - 300) < 0.001)
        #expect(!ImageOptimizer.plan(width: 1200, height: 800, placedWidth: 144, resample: .effectiveResolution(9000)).resamples)
        #expect(!ImageOptimizer.plan(width: 1200, height: 800, placedWidth: 144, resample: .none).resamples)
        let edge = ImageOptimizer.plan(width: 400, height: 200, placedWidth: 0, resample: .pixelSize(100))
        #expect(edge.targetWidth == 100 && edge.targetHeight == 50 && edge.effectiveResolution == 72)
        #expect(!ImageOptimizer.plan(width: 400, height: 200, placedWidth: 0, resample: .effectiveResolution(10)).resamples)
        let data = Self.encode(Self.photo(width: 240, height: 160), .png)
        let resampled = try ImageOptimizer.optimize(data, placedWidth: 72, options: ImageOptimizeOptions(resample: .effectiveResolution(150)))
        #expect(abs(resampled.width - 150) <= 1 && abs(resampled.height - 100) <= 1)
        let stored = Self.properties(resampled)[kCGImagePropertyDPIWidth] as? Double
        #expect(abs((stored ?? 0) - 150) < 1)
    }

    @Test func grayscaleConversionEnablesTintingAndKeepsAlpha() throws {
        let opaque = try ImageOptimizer.optimize(Self.encode(Self.photo(), .png), placedWidth: 120, options: ImageOptimizeOptions(colorMode: .grayscale))
        #expect(opaque.mode == .grayscale && !opaque.hasAlpha)
        let transparent = try ImageOptimizer.optimize(Self.encode(Self.photo(alpha: true), .png), placedWidth: 120, options: ImageOptimizeOptions(colorMode: .grayscale))
        #expect(transparent.mode == .grayscale && transparent.hasAlpha)
        // Transparent pixels keep their coverage; opaque ones stay opaque.
        let pixels = RGBAPixels(try Self.decoded(transparent))
        #expect(abs(Int(pixels.bytes[(79 * 120) * 4 + 3]) - 64) <= 2)
        #expect(pixels.bytes[119 * 4 + 3] == 255)
        // A gray image resampled stays gray; converted to RGB becomes RGB.
        let resampledGray = try ImageOptimizer.optimize(opaque.blob.data, placedWidth: 120, options: ImageOptimizeOptions(resample: .pixelSize(60)))
        #expect(resampledGray.mode == .grayscale && resampledGray.width == 60)
        let rgb = try ImageOptimizer.optimize(opaque.blob.data, placedWidth: 120, options: ImageOptimizeOptions(colorMode: .rgb))
        #expect(rgb.mode == .rgb)
    }

    /// The colour profile survives every path; alpha survives every alpha-capable one.
    @Test func profileAndAlphaSurvive() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let source = Self.encode(Self.photo(alpha: true, space: p3), .png)
        var formats: [ImageOptimizeOptions.Format] = [.keep, .png, .jpeg, .tiff]
        formats += [.webp, .heic].filter(\.isAvailable)
        for format in formats {
            for resample in [ImageOptimizeOptions.Resample.none, .pixelSize(60)] {
                let result = try ImageOptimizer.optimize(source, placedWidth: 120, options: ImageOptimizeOptions(format: format, resample: resample))
                #expect(WTColor.OutputContext.embeddedProfile(in: result.blob.data) == WTColor.ProfileRegistry.shared.displayP3, "\(format) \(resample)")
                if format.holdsAlpha && format != .webp { #expect(result.hasAlpha, "\(format) \(resample)") }
            }
        }
        // CMYK stays CMYK when resampled.
        let cmyk = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.genericCMYK)!, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        cmyk.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.genericCMYK)!, components: [0.2, 0.5, 0, 0.1, 1])!)
        cmyk.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let press = try ImageOptimizer.optimize(Self.encode(cmyk.makeImage()!, .tiff), placedWidth: 40, options: ImageOptimizeOptions(resample: .pixelSize(20)))
        #expect(press.mode == .cmyk && press.width == 20)
    }

    @Test func metadataIsKeptOrStripped() throws {
        let exif: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "quokka"], kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144]
        let jpeg = Self.encode(Self.photo(), .jpeg, properties: exif)
        let kept = try ImageOptimizer.optimize(jpeg, placedWidth: 60, options: ImageOptimizeOptions(quality: 80))
        let keptExif = Self.properties(kept)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(keptExif?[kCGImagePropertyExifUserComment] as? String == "quokka")
        #expect(Self.properties(kept)[kCGImagePropertyDPIWidth] as? Double == 144)
        let stripped = try ImageOptimizer.optimize(jpeg, placedWidth: 60, options: ImageOptimizeOptions(quality: 80, stripMetadata: true))
        let strippedExif = Self.properties(stripped)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(strippedExif?[kCGImagePropertyExifUserComment] == nil)
    }

    @Test func optionsAndErrors() throws {
        #expect(throws: ImageOptimizeError.invalidOption("Quality must be 1 to 100.")) { try ImageOptimizeOptions(quality: 0).validate() }
        #expect(throws: ImageOptimizeError.self) { try ImageOptimizeOptions(resample: .effectiveResolution(0)).validate() }
        #expect(throws: ImageOptimizeError.self) { try ImageOptimizeOptions(resample: .pixelSize(0)).validate() }
        #expect(throws: ImageOptimizeError.unreadable) { try ImageOptimizer.optimize(Data("junk".utf8), placedWidth: 10, options: ImageOptimizeOptions()) }
        #expect(ImageOptimizeOptions.Format.keep.typeIdentifier == nil && ImageOptimizeOptions.Format.keep.isAvailable)
        #expect(!ImageOptimizeOptions.Format.jpeg.holdsAlpha && ImageOptimizeOptions.Format.png.holdsAlpha)
        #expect(ImageOptimizeOptions.Format.heic.isLossy && !ImageOptimizeOptions.Format.tiff.isLossy)
        #expect(ImageOptimizeOptions.Format.allCases.compactMap(\.typeIdentifier).count == 5)
        // A GIF can be read but not every Mac writes every type: an unwritable type fails cleanly.
        let gif = Self.encode(Self.photo(width: 8, height: 8), UTType.gif)
        #expect(try ImageOptimizer.optimize(gif, placedWidth: 8, options: ImageOptimizeOptions()).blob.uti == UTType.gif.identifier)
        let unavailable = ImageOptimizeOptions.Format.allCases.filter { !$0.isAvailable }
        for format in unavailable {
            #expect(throws: ImageOptimizeError.self) { try ImageOptimizeOptions(format: format).validate() }
        }
    }
}
