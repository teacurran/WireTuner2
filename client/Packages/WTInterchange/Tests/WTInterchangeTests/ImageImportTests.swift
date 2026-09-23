// IMG-002 and IMG-015: bitmap import.  The fixture corpus is generated here -- through the
// package's own bitmap exporters where they write the variant, through ImageIO's encoders
// otherwise -- so every format × variant is produced, imported and checked for the documented
// `PixelSource` without third-party files.  The two WebP fixtures are 6 × 4 images this test
// suite's author encoded with `cwebp` (libwebp) from a generated PNG, since macOS has no WebP
// encoder; they are this project's own bytes, embedded as base64.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WTGeometry
@testable import WTInterchange
import WTRender

/// Generated image fixtures.
enum ImageFixtures {
    /// A `width` × `height` sRGB ramp, with a transparent left column when `alpha`.
    static func image(width: Int, height: Int, alpha: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        if alpha {
            context.clear(CGRect(x: 0, y: 0, width: max(width / 4, 1), height: height))
        }
        return context.makeImage()!
    }

    /// A grayscale image of 8 bits per component, or a 1-bit bilevel image (built from its
    /// bytes: Core Graphics draws into no 1-bit context).
    static func gray(width: Int, height: Int, bits: Int = 8) -> CGImage {
        if bits == 1 {
            let rowBytes = (width + 7) / 8
            let bytes = Data((0..<(rowBytes * height)).map { $0 % 2 == 0 ? 0xAA : 0x0F })
            return CGImage(width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 0.25, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A CMYK image.
    static func cmyk(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceCMYK(), components: [0.1, 0.8, 0.3, 0.05, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A 16-bit RGB image.
    static func deep(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        context.setFillColor(red: 0.3, green: 0.6, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// `images` encoded as `type` (several images make a multi-page or animated file), with
    /// per-image `properties`.
    static func encode(_ images: [CGImage], type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)!
        for image in images {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination), "\(type) did not encode")
        return data as Data
    }

    static func png(width: Int, height: Int, alpha: Bool = false) -> Data {
        encode([image(width: width, height: height, alpha: alpha)], type: .png)
    }

    /// A page with a red and blue square on a transparent background, exported by the package's
    /// own bitmap exporter for `format` with `options`.
    static func exported(_ format: ExportFormat, options: any ExportOptions) throws -> Data {
        let page = Corpus.page([
            Corpus.path(Corpus.rect(0, 0, 20, 10), [Corpus.fill(.solid(Corpus.red))]),
            Corpus.path(Corpus.rect(20, 10, 20, 10), [Corpus.fill(.solid(Corpus.blue))]),
        ], width: 40, height: 20)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wt-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = format == .psd ? PSDExporter() as any Exporter : BitmapExporter(format: format)
        let summary = try exporter.export(scene: Corpus.scene([page]), options: options, to: ExportDestination(url: directory.appendingPathComponent("fixture.\(format.fileExtension)")))
        return try Data(contentsOf: summary.files[0])
    }

    /// The sRGB colour of pixel (`x`, `y`) of `image`, (0, 0) top-left.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        let alpha = Double(bytes[3]) / 255
        func channel(_ value: UInt8) -> Double { alpha > 0 ? Double(value) / 255 / alpha : 0 }
        return (channel(bytes[0]), channel(bytes[1]), channel(bytes[2]), alpha)
    }

    /// 6 × 4 lossless WebP with a transparent column.
    static let webpLossless = Data(base64Encoded: "UklGRjYAAABXRUJQVlA4TCoAAAAvBcAAEB6CbJtJTnKS1zg6QbYN1JzmNKc7vYD9j4+5tv2R1fpFzfkDEuM=")!
    /// 6 × 4 lossy WebP, opaque.
    static let webpLossy = Data(base64Encoded: "UklGRmoAAABXRUJQVlA4IF4AAAAwAgCdASoGAAQAAUAmJbACdEyAfoAB2aeNEAD+8b/qviM+15Z706HxdTDNP+YvEYW386FeRiXeyRbN9m4H6XL/5Nv/UeoMZdhnZ5//rUT7vTHZv/+LD/uMt4e/wAAA")!

    /// A JPEG frame header claiming `bits` of precision (SOF1), as a 12-bit JPEG starts.
    static func jpegHeader(bits: UInt8) -> Data {
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46]    // SOI, a short APP0
        bytes += [0xFF, 0xC1, 0x00, 0x0B, bits, 0x00, 0x10, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00]
        bytes += [0xFF, 0xD9]
        return Data(bytes)
    }
}

@Suite("Image import")
struct ImageImportTests {
    let importer = ImageImporter()

    func decode(_ data: Data, name: String = "fixture", context: ImportContext = ImportContext()) throws -> ImageImporter.Decoded {
        try importer.decode(data, name: name, context: context)
    }

    /// Checks the `PixelSource` facts of a fixture.
    func expectPixels(_ data: Data, width: Int, height: Int, mode: ImportedColorMode, bits: Int, alpha: Bool, uti: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let decoded = try decode(data)
        let pixels = decoded.pixels
        #expect(pixels.width == width, sourceLocation: sourceLocation)
        #expect(pixels.height == height, sourceLocation: sourceLocation)
        #expect(pixels.mode == mode, sourceLocation: sourceLocation)
        #expect(pixels.bitsPerChannel == bits, sourceLocation: sourceLocation)
        #expect(pixels.hasAlpha == alpha, sourceLocation: sourceLocation)
        if let uti {
            #expect(pixels.blob.uti == uti, sourceLocation: sourceLocation)
        }
        // Nothing was rewritten: the blob is the file.
        #expect(pixels.blob.data == data, sourceLocation: sourceLocation)
    }

    // MARK: Format × variant corpus

    @Test func tiffVariants() throws {
        try expectPixels(ImageFixtures.encode([ImageFixtures.image(width: 8, height: 6)], type: .tiff), width: 8, height: 6, mode: .rgb, bits: 8, alpha: true, uti: "public.tiff")
        try expectPixels(ImageFixtures.exported(.tiff, options: TIFFOptions(common: BitmapCommonOptions(background: .white), bits: 24)), width: 40, height: 20, mode: .rgb, bits: 8, alpha: false)
        try expectPixels(ImageFixtures.exported(.tiff, options: TIFFOptions(bits: 64)), width: 40, height: 20, mode: .rgb, bits: 16, alpha: true)
        try expectPixels(ImageFixtures.exported(.tiff, options: TIFFOptions(common: BitmapCommonOptions(background: .white, color: .cmyk), bits: 32)), width: 40, height: 20, mode: .cmyk, bits: 8, alpha: false)
        try expectPixels(ImageFixtures.exported(.tiff, options: TIFFOptions(common: BitmapCommonOptions(background: .white, color: .gray), bits: 24)), width: 40, height: 20, mode: .grayscale, bits: 8, alpha: false)
        try expectPixels(ImageFixtures.exported(.tiff, options: TIFFOptions(common: BitmapCommonOptions(background: .white), bits: 8)), width: 40, height: 20, mode: .indexed, bits: 8, alpha: false)
        try expectPixels(ImageFixtures.encode([ImageFixtures.gray(width: 16, height: 8, bits: 1)], type: .tiff), width: 16, height: 8, mode: .bilevel, bits: 1, alpha: false)
        // Multi-page TIFFs import their first page, and say so.
        let pages = ImageFixtures.encode([ImageFixtures.image(width: 8, height: 6), ImageFixtures.image(width: 4, height: 4)], type: .tiff)
        let decoded = try decode(pages, name: "pages.tif")
        #expect(decoded.pixels.width == 8)
        #expect(decoded.notes.contains { $0.contains("2 frames or pages") })
    }

    @Test func jpegVariants() throws {
        try expectPixels(ImageFixtures.exported(.jpeg, options: JPEGOptions()), width: 40, height: 20, mode: .rgb, bits: 8, alpha: false, uti: "public.jpeg")
        try expectPixels(ImageFixtures.encode([ImageFixtures.cmyk(width: 8, height: 8)], type: .jpeg), width: 8, height: 8, mode: .cmyk, bits: 8, alpha: false)
        try expectPixels(ImageFixtures.exported(.jpeg, options: JPEGOptions(common: BitmapCommonOptions(background: .white, color: .gray))), width: 40, height: 20, mode: .grayscale, bits: 8, alpha: false)
    }

    @Test func pngVariants() throws {
        try expectPixels(ImageFixtures.exported(.png, options: PNGOptions(common: BitmapCommonOptions(background: .white), bits: 24)), width: 40, height: 20, mode: .rgb, bits: 8, alpha: false, uti: "public.png")
        try expectPixels(ImageFixtures.exported(.png, options: PNGOptions(bits: 32)), width: 40, height: 20, mode: .rgb, bits: 8, alpha: true)
        try expectPixels(ImageFixtures.exported(.png, options: PNGOptions(common: BitmapCommonOptions(background: .white), bits: 48)), width: 40, height: 20, mode: .rgb, bits: 16, alpha: false)
        try expectPixels(ImageFixtures.exported(.png, options: PNGOptions(bits: 64)), width: 40, height: 20, mode: .rgb, bits: 16, alpha: true)
        try expectPixels(ImageFixtures.exported(.png, options: PNGOptions(bits: 8)), width: 40, height: 20, mode: .indexed, bits: 8, alpha: true)
        try expectPixels(ImageFixtures.encode([ImageFixtures.gray(width: 5, height: 5)], type: .png), width: 5, height: 5, mode: .grayscale, bits: 8, alpha: false)
        try expectPixels(ImageFixtures.encode([ImageFixtures.deep(width: 5, height: 5)], type: .png), width: 5, height: 5, mode: .rgb, bits: 16, alpha: false)
    }

    @Test func gifTakesItsFirstFrameAndTransparentColour() throws {
        try expectPixels(ImageFixtures.exported(.gif, options: GIFOptions()), width: 40, height: 20, mode: .indexed, bits: 8, alpha: true, uti: "com.compuserve.gif")
        try expectPixels(ImageFixtures.exported(.gif, options: GIFOptions(common: BitmapCommonOptions(background: .white), transparent: false)), width: 40, height: 20, mode: .indexed, bits: 8, alpha: false)
        let animated = ImageFixtures.encode([ImageFixtures.image(width: 6, height: 6), ImageFixtures.image(width: 6, height: 6, alpha: true)], type: .gif, properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]])
        let decoded = try decode(animated, name: "wave.gif")
        #expect(decoded.pixels.width == 6)
        #expect(decoded.notes.count == 1)
    }

    @Test func bmpTargaAndPhotoshop() throws {
        try expectPixels(ImageFixtures.exported(.bmp, options: BMPOptions(common: BitmapCommonOptions(background: .white), bits: 24)), width: 40, height: 20, mode: .rgb, bits: 8, alpha: false, uti: "com.microsoft.bmp")
        try expectPixels(ImageFixtures.exported(.targa, options: TargaOptions(bits: 32)), width: 40, height: 20, mode: .rgb, bits: 8, alpha: true, uti: "com.truevision.tga-image")
        try expectPixels(ImageFixtures.exported(.targa, options: TargaOptions(common: BitmapCommonOptions(background: .white), bits: 24)), width: 40, height: 20, mode: .rgb, bits: 8, alpha: false)
        try expectPixels(ImageFixtures.exported(.targa, options: TargaOptions(common: BitmapCommonOptions(background: .white, color: .gray), bits: 8)), width: 40, height: 20, mode: .grayscale, bits: 8, alpha: false)
        // Photoshop: the flattened composite with transparency.
        try expectPixels(ImageFixtures.exported(.psd, options: PSDOptions()), width: 40, height: 20, mode: .rgb, bits: 8, alpha: true, uti: "com.adobe.photoshop-image")
        try expectPixels(ImageFixtures.encode([ImageFixtures.image(width: 7, height: 5, alpha: true)], type: UTType("com.adobe.photoshop-image")!), width: 7, height: 5, mode: .rgb, bits: 8, alpha: true)
    }

    @Test func heicWebPAndAVIF() throws {
        try expectPixels(ImageFixtures.encode([ImageFixtures.image(width: 64, height: 48)], type: .heic), width: 64, height: 48, mode: .rgb, bits: 8, alpha: false, uti: "public.heic")
        try expectPixels(ImageFixtures.webpLossless, width: 6, height: 4, mode: .rgb, bits: 8, alpha: true, uti: "org.webmproject.webp")
        try expectPixels(ImageFixtures.webpLossy, width: 6, height: 4, mode: .rgb, bits: 8, alpha: false, uti: "org.webmproject.webp")
        let avif = ImageFixtures.encode([ImageFixtures.image(width: 64, height: 48, alpha: true)], type: UTType("public.avif")!)
        let decoded = try decode(avif)
        #expect(decoded.pixels.width == 64 && decoded.pixels.height == 48)
        #expect(decoded.pixels.mode == .rgb)
        #expect(decoded.pixels.blob.uti == "public.avif")
    }

    // MARK: Orientation, resolution, downsampling

    @Test func orientedImagesAreStoredUpright() throws {
        // A HEIC as an iPhone writes it: pixels landscape, orientation 6 (rotate 90° clockwise).
        let heic = ImageFixtures.encode([ImageFixtures.image(width: 64, height: 32)], type: .heic, properties: [kCGImagePropertyOrientation: 6, kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 72])
        let probe = try importer.probe(heic, name: "IMG_0001.HEIC", format: .heic)
        #expect(probe.pixelWidth == 32 && probe.pixelHeight == 64)
        #expect(probe.preview != nil)
        let decoded = try decode(heic, name: "IMG_0001.HEIC")
        #expect(decoded.pixels.width == 32)
        #expect(decoded.pixels.height == 64)
        #expect(decoded.pixels.blob.uti == "public.png")
        #expect(decoded.notes.contains { $0.contains("upright") })
        // The resolutions swap with the axes: the natural size is the rotated one.
        #expect(abs(decoded.dpiX - 72) < 1e-9 && abs(decoded.dpiY - 144) < 1e-9)
        // A mirrored orientation that keeps the axes.
        let flipped = ImageFixtures.encode([ImageFixtures.gray(width: 10, height: 4)], type: .jpeg, properties: [kCGImagePropertyOrientation: 2])
        let upright = try decode(flipped)
        #expect(upright.pixels.width == 10 && upright.pixels.height == 4)
        #expect(upright.pixels.mode == .grayscale)
    }

    @Test func resolutionSetsTheNaturalSize() throws {
        let png = ImageFixtures.encode([ImageFixtures.image(width: 300, height: 150)], type: .png, properties: [kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300])
        let scene = try importer.convert(png, name: "print.png", format: .png, options: ImportOptionValues(), context: ImportContext())
        #expect(scene.kind == .bitmap)
        #expect(abs(scene.bounds.width - 72) < 1e-6)
        #expect(abs(scene.bounds.height - 36) < 1e-6)
        let unmarked = try decode(ImageFixtures.png(width: 10, height: 10))
        #expect(unmarked.dpiX == 72 && unmarked.dpiY == 72)
        let probe = try importer.probe(png, name: "print.png", format: .png)
        #expect(probe.colorMode == .rgb)
        #expect(abs(probe.naturalSize.width - 72) < 1e-6)
    }

    @Test func largeImagesAreDownsampledKeepingTheirSize() throws {
        // 1200 × 1000 = 1.2 MP against a 1 MP limit, lossless and lossy.
        let big = ImageFixtures.image(width: 1200, height: 1000)
        let png = ImageFixtures.encode([big], type: .png, properties: [kCGImagePropertyDPIWidth: 150, kCGImagePropertyDPIHeight: 150])
        let context = ImportContext(downsampleLimit: 1_000_000)
        let decoded = try decode(png, name: "big.png", context: context)
        #expect(decoded.pixels.width * decoded.pixels.height <= 1_000_000)
        #expect(decoded.pixels.blob.uti == "public.png")
        let natural = ImportedImage(pixels: decoded.pixels, dpiX: decoded.dpiX, dpiY: decoded.dpiY).naturalRect
        #expect(abs(natural.width - 1200.0 / 150 * 72) < 0.01)
        #expect(abs(natural.height - 1000.0 / 150 * 72) < 0.01)
        #expect(decoded.notes.contains { $0.contains("downsampled") })
        let jpeg = ImageFixtures.encode([big], type: .jpeg)
        #expect(try decode(jpeg, context: context).pixels.blob.uti == "public.jpeg")
        // Off keeps every pixel.
        #expect(try decode(png, context: ImportContext(downsampleLimit: nil)).pixels.width == 1200)
        // A grayscale source stays grayscale after resampling.
        let gray = ImageFixtures.encode([ImageFixtures.gray(width: 1200, height: 1000)], type: .png)
        #expect(try decode(gray, context: context).pixels.mode == .grayscale)
    }

    @Test func sixtyMegapixelsAtTheFiftyMegapixelDefault() throws {
        // IMG-002: "a 60 MP file with the preference at 50 MP is downsampled with unchanged
        // natural size".  A flat JPEG keeps the fixture quick to make.
        let width = 9000, height = 6667
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let jpeg = ImageFixtures.encode([context.makeImage()!], type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.5, kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300])
        let decoded = try decode(jpeg, name: "60mp.jpg", context: ImportContext(downsampleMegapixels: 50))
        #expect(decoded.pixels.width * decoded.pixels.height <= 50_000_000)
        #expect(decoded.pixels.width * decoded.pixels.height > 45_000_000)
        let natural = ImportedImage(pixels: decoded.pixels, dpiX: decoded.dpiX, dpiY: decoded.dpiY).naturalRect
        #expect(abs(natural.width - Double(width) / 300 * 72) < 0.05)
        #expect(abs(natural.height - Double(height) / 300 * 72) < 0.05)
    }

    // MARK: Refusals

    @Test func twelveBitJPEGsAreRefusedWithAMessage() {
        #expect(throws: ImportError.unsupportedJPEGPrecision(name: "scan.jpg", bits: 12)) {
            try decode(ImageFixtures.jpegHeader(bits: 12), name: "scan.jpg")
        }
        #expect(ImageImporter.jpegPrecision(ImageFixtures.jpegHeader(bits: 8)) == 8)
        #expect(ImageImporter.jpegPrecision(Data([0xFF, 0xD8, 0xFF])) == nil)
        #expect(ImageImporter.jpegPrecision(Data([0xFF, 0xD8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])) == nil)
        // Padding bytes between markers, then start of scan without a frame header.
        #expect(ImageImporter.jpegPrecision(Data([0xFF, 0xD8, 0xFF, 0xFF, 0xDA, 0x00, 0x02, 0x00, 0x00])) == nil)
        // A truncated frame header.
        #expect(ImageImporter.jpegPrecision(Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B])) == nil)
        #expect(ImageImporter.jpegPrecision(Data("PNG".utf8)) == nil)
    }

    @Test func corruptFilesOfEveryFormatAreRefusedNamingTheFile() throws {
        let valid: [(String, Data)] = [
            ("a.png", ImageFixtures.png(width: 20, height: 20)),
            ("a.jpg", ImageFixtures.encode([ImageFixtures.image(width: 20, height: 20)], type: .jpeg)),
            ("a.tif", ImageFixtures.encode([ImageFixtures.image(width: 20, height: 20)], type: .tiff)),
            ("a.gif", ImageFixtures.encode([ImageFixtures.image(width: 20, height: 20)], type: .gif)),
            ("a.bmp", ImageFixtures.encode([ImageFixtures.image(width: 20, height: 20)], type: .bmp)),
            ("a.psd", ImageFixtures.encode([ImageFixtures.image(width: 20, height: 20)], type: UTType("com.adobe.photoshop-image")!)),
            ("a.heic", ImageFixtures.encode([ImageFixtures.image(width: 20, height: 20)], type: .heic)),
            ("a.webp", ImageFixtures.webpLossy),
        ]
        for (name, data) in valid {
            // The header alone, and garbage after a valid signature.
            for damaged in [data.prefix(12), data.prefix(4) + Data(repeating: 0x5A, count: 64)] {
                do {
                    _ = try importer.convert(Data(damaged), name: name, format: ImportFormat(fileExtension: (name as NSString).pathExtension)!, options: ImportOptionValues(), context: ImportContext())
                    Issue.record("\(name) damaged should be refused")
                } catch let error as ImportError {
                    #expect(error.fileName == name)
                }
            }
        }
        #expect(throws: ImportError.self) {
            try importer.probe(Data("not an image".utf8), name: "x.png", format: .png)
        }
        #expect(throws: ImportError.tooLarge(name: "x", bytes: 5, limit: 4)) {
            try decode(Data(repeating: 0, count: 5), name: "x", context: ImportContext(maximumFileSize: 4))
        }
    }

    @Test func gifTransparencyIsReadFromTheControlExtension() {
        func gif(_ blocks: [UInt8], globalTable: Bool = false) -> Data {
            var bytes = Array("GIF89a".utf8) + [4, 0, 4, 0, globalTable ? 0x80 : 0x00, 0, 0]
            if globalTable { bytes += [UInt8](repeating: 0, count: 6) }
            return Data(bytes + blocks)
        }
        let control: (UInt8) -> [UInt8] = { [0x21, 0xF9, 0x04, $0, 0, 0, 0, 0] }
        let application: [UInt8] = [0x21, 0xFF, 0x03, 0x41, 0x42, 0x43, 0x02, 0x01, 0x00, 0x00]
        #expect(ImageImporter.gifHasTransparency(gif(control(1))))
        #expect(!ImageImporter.gifHasTransparency(gif(control(0))))
        #expect(ImageImporter.gifHasTransparency(gif(application + control(1), globalTable: true)))
        #expect(!ImageImporter.gifHasTransparency(gif([0x2C, 0, 0])))
        #expect(!ImageImporter.gifHasTransparency(gif([0x21])))
        #expect(!ImageImporter.gifHasTransparency(gif(application)))
        #expect(!ImageImporter.gifHasTransparency(Data("GIF89a".utf8)))
    }

    @Test func labImagesImportAsRGBWithANote() throws {
        let space = CGColorSpace(name: CGColorSpace.genericLab)!
        let bytes = Data((0..<(4 * 4 * 3)).map { UInt8(truncatingIfNeeded: $0 * 5) })
        let image = CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 12, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let tiff = ImageFixtures.encode([image], type: .tiff)
        let decoded = try decode(tiff, name: "lab.tif")
        #expect(decoded.pixels.mode == .rgb)
        #expect(decoded.notes.contains { $0.contains("Lab") })
    }

    // MARK: Blobs and placement

    @Test func theSameFileImportedTwiceIsOneBlob() throws {
        let data = ImageFixtures.png(width: 12, height: 9)
        let a = try importer.convert(data, name: "a.png", format: .png, options: ImportOptionValues(), context: ImportContext())
        let b = try importer.convert(data, name: "copy of a.png", format: .png, options: ImportOptionValues(), context: ImportContext())
        #expect(a.blobs == b.blobs)
        #expect(a.blobs.count == 1)
        // What the blob cache keys on: one hash, one pending upload.
        var pending = Set<Data>()
        for scene in [a, b] {
            for blob in scene.blobs {
                pending.insert(blob.sha256)
            }
        }
        #expect(pending.count == 1)
        guard case .image(let image) = b.subtree else {
            Issue.record("one image node")
            return
        }
        #expect(image.name == "copy of a.png")
    }

    @Test func generatedImagesBecomePNGBlobs() {
        let pixels = ImageImporter.pixels(of: ImageFixtures.image(width: 9, height: 7, alpha: true))
        #expect(pixels.blob.uti == "public.png")
        #expect(pixels.width == 9 && pixels.height == 7)
        #expect(pixels.hasAlpha)
        #expect(ImageImporter.isLossy("public.jpeg"))
        #expect(!ImageImporter.isLossy("public.png"))
    }

    // MARK: Pasteboard

    @Test func pasteboardPrefersObjectsThenPDFThenImages() throws {
        let png = ImageFixtures.png(width: 3, height: 3)
        let pdf = Data("%PDF-1.4".utf8)
        #expect(ImportPasteboard.choose([(ImportPasteboard.objectsType, Data()), ("com.adobe.pdf", pdf)]) == nil)
        #expect(ImportPasteboard.choose([("public.png", png), ("com.adobe.pdf", pdf)])?.format == .pdf)
        #expect(ImportPasteboard.choose([("public.utf8-plain-text", Data("x".utf8)), ("public.tiff", png)])?.format == .png)
        #expect(ImportPasteboard.choose([("public.jpeg", Data("??".utf8))])?.format == .jpeg)
        #expect(ImportPasteboard.choose([("public.image", Data("??".utf8))]) == nil)
        #expect(ImportPasteboard.choose([("public.utf8-plain-text", Data("x".utf8))]) == nil)
        let registry = ImportRegistry(importers: [ImageImporter()])
        let scene = try #require(try ImportPasteboard.convert([("public.png", png)], registry: registry))
        #expect(scene.name == "Pasted")
        #expect(scene.kind == .bitmap)
        #expect(try ImportPasteboard.convert([("com.adobe.pdf", pdf)], registry: registry) == nil)
    }
}
