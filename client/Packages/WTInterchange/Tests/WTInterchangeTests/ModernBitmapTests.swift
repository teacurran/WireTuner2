// IO-024: WebP, HEIC and AVIF through ImageIO where the running macOS encodes them.  On macOS 15
// and later ImageIO encodes HEIC and AVIF (lossy only) and decodes but does not encode WebP.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct ModernBitmapTests {
    static let wide = Color(red: 1.15, green: 0.2, blue: -0.05)

    @Test(arguments: [ExportFormat.heic, .avif])
    func lossyAlphaAndSize(_ format: ExportFormat) throws {
        try #require(BitmapExporter.canEncode(format))
        let options: any ExportOptions = format == .heic ? HEICOptions() : AVIFOptions()
        let photo = try BitmapTests.export(format, options, page: PaletteTests.photo)
        let image = photo.images[0].image
        #expect(image.width == 200 && image.height == 150)
        let png = try BitmapTests.export(.png, PNGOptions(), page: PaletteTests.photo)
        let size = try Data(contentsOf: photo.summary.files[0]).count
        let pngSize = try Data(contentsOf: png.summary.files[0]).count
        #expect(Double(size) < 0.3 * Double(pngSize), "\(size) vs PNG \(pngSize)")
        // Transparent corners stay transparent; the artwork is close to the PNG.
        let logo = try BitmapTests.export(format, options, page: Corpus.page([Corpus.path(Corpus.ellipse(20, 20, 160, 110), [Corpus.fill(.solid(Corpus.blue))])]))
        let pixels = Corpus.pixels(logo.images[0].image).bytes
        #expect(pixels[3] == 0)
        let center = (75 * 200 + 100) * 4
        #expect(pixels[center + 3] == 255 && abs(Int(pixels[center + 2]) - 230) < 12)
        let opaque = try BitmapTests.export(format, format == .heic ? HEICOptions(common: BitmapCommonOptions(background: .white), quality: 95) as any ExportOptions : AVIFOptions(common: BitmapCommonOptions(background: .white), quality: 95), page: PaletteTests.photo)
        #expect(Corpus.pixels(opaque.images[0].image).bytes[3] == 255)
    }

    @Test(arguments: [ExportFormat.heic, .avif])
    func displayP3ColorsAreTagged(_ format: ExportFormat) throws {
        try #require(BitmapExporter.canEncode(format))
        let page = Corpus.page([Corpus.path(Corpus.rect(0, 0, 200, 150), [Corpus.fill(.solid(Self.wide))])])
        let options: any ExportOptions = format == .heic ? HEICOptions(quality: 100) : AVIFOptions(quality: 100)
        let result = try BitmapTests.export(format, options, page: page)
        #expect(result.images[0].properties[kCGImagePropertyProfileName] as? String == "Display P3")
        // The fill decodes to its Display P3 value (lossy coding: within a few steps).  WTRender still
        // draws extended values clipped to sRGB (the IO-021 note), so that is the value expected.
        let image = result.images[0].image
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let expected = ColorMath.displayP3(Color(red: 1, green: 0.2, blue: 0))
        let center = (75 * 200 + 100) * 4
        #expect(abs(Int(bytes[center]) - ColorMath.byte(expected.x)) <= 6)
        #expect(abs(Int(bytes[center + 1]) - ColorMath.byte(expected.y)) <= 6)
    }

    @Test func webPNeedsAnEncoder() throws {
        let exporter = BitmapExporter(format: .webp)
        #expect(exporter.optionsType is WebPOptions.Type)
        guard BitmapExporter.canEncode(.webp) else {
            #expect(throws: ExportError.encoderUnavailable(.webp)) { try BitmapTests.export(.webp, WebPOptions(), page: PaletteTests.photo) }
            #expect(ExportError.encoderUnavailable(.webp).description.contains("WebP"))
            return
        }
        let lossless = try BitmapTests.export(.webp, WebPOptions(lossless: true), page: PaletteTests.photo)
        let png = try BitmapTests.export(.png, PNGOptions(), page: PaletteTests.photo)
        #expect(Corpus.pixels(lossless.images[0].image).bytes == Corpus.pixels(png.images[0].image).bytes)
    }

    @Test func optionsAreValidated() throws {
        #expect(throws: ExportError.self) { try BitmapTests.export(.avif, AVIFOptions(lossless: true), page: PaletteTests.logo) }
        #expect(throws: ExportError.self) { try BitmapTests.export(.avif, AVIFOptions(speed: 11), page: PaletteTests.logo) }
        #expect(throws: ExportError.self) { try BitmapTests.export(.heic, HEICOptions(quality: 0), page: PaletteTests.logo) }
        #expect(throws: ExportError.self) { try BitmapTests.export(.webp, WebPOptions(quality: 101), page: PaletteTests.logo) }
        #expect(throws: ExportError.self) { try BitmapTests.export(.heic, HEICOptions(common: BitmapCommonOptions(color: .cmyk)), page: PaletteTests.logo) }
        #expect(throws: ExportError.wrongOptions(format: .heic)) { try BitmapTests.export(.heic, AVIFOptions(), page: PaletteTests.logo) }
        let slow = try BitmapTests.export(.avif, AVIFOptions(speed: 0), page: PaletteTests.logo)
        #expect(slow.summary.notes.contains { $0.contains("AVIF speed") })
        #expect(BitmapExporter(format: .heic).optionsType is HEICOptions.Type)
        #expect(BitmapExporter(format: .avif).optionsType is AVIFOptions.Type)
        #expect(WebPOptions.defaults == WebPOptions() && HEICOptions.defaults == HEICOptions() && AVIFOptions.defaults == AVIFOptions())
    }
}
