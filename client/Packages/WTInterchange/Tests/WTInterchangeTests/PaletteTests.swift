// IO-022: GIF with palettes, and the 8-bit palette PNG and TIFF depths.  Every file is read back
// by ImageIO and compared with what was rendered.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct PaletteTests {
    static func export(_ format: ExportFormat, _ options: any ExportOptions, page: ExportPage) throws -> (url: URL, image: CGImage, properties: [CFString: Any]) {
        let result = try BitmapTests.export(format, options, page: page)
        let url = result.summary.files[0]
        let read = try #require(BitmapTests.read(url))
        return (url, read.image, read.properties)
    }

    /// A logo of flat, pixel-aligned colours: at anti-aliasing None it has exactly five colours.
    static let logo = Corpus.page([
        Corpus.path(Corpus.rect(10, 10, 60, 40), [Corpus.fill(.solid(Corpus.red))]),
        Corpus.path(Corpus.rect(80, 10, 50, 40), [Corpus.fill(.solid(Corpus.blue))]),
        Corpus.path(Corpus.rect(140, 10, 50, 40), [Corpus.fill(.solid(Corpus.green))]),
        Corpus.path(Corpus.rect(10, 60, 180, 80), [Corpus.fill(.solid(Corpus.yellow))]),
    ])

    /// A photograph-like page: two overlapping gradients.
    static let photo = Corpus.page([
        Corpus.path(Corpus.rect(0, 0, 200, 150), [Corpus.fill(Corpus.gradient(.linear, axis: Gradient.Axis(start: Point(x: 0, y: 0), end: Point(x: 200, y: 150))))]),
        Corpus.path(Corpus.ellipse(40, 20, 120, 110), [Corpus.fill(Corpus.gradient(.radial, stops: [Gradient.Stop(offset: 0, color: .white), Gradient.Stop(offset: 1, color: Corpus.green.withAlpha(multipliedBy: 0.3))]))]),
    ])

    static func rendered(_ page: ExportPage, common: BitmapCommonOptions) -> StraightPixels {
        StraightPixels(BitmapRasterizer(common: common).render(page, scale: 1, bitsPerComponent: 8, alpha: common.background == .transparent).bitmap)
    }

    @Test func flatLogoKeepsItsExactColors() throws {
        let common = BitmapCommonOptions(antiAliasing: 1, background: .white)
        let result = try Self.export(.gif, GIFOptions(common: common, palette: PaletteSettings(choice: .exact), transparent: false), page: Self.logo)
        let expected = Self.rendered(Self.logo, common: common)
        let actual = Corpus.pixels(result.image).bytes
        #expect(result.image.width == 200 && result.image.height == 150)
        #expect(zip(expected.bytes, actual).allSatisfy { $0 == $1 })
        let data = try Data(contentsOf: result.url)
        #expect(data.prefix(6) == Data("GIF89a".utf8))
        // Five colours need a three-bit table: 8 entries.
        #expect(data[10] & 0x07 == 2)
        #expect(throws: ExportError.self) {
            try BitmapTests.export(.gif, GIFOptions(common: BitmapCommonOptions(background: .white), palette: PaletteSettings(choice: .exact, colors: 16), transparent: false), page: Self.photo)
        }
    }

    @Test func photographAt64ColorsWithDither() throws {
        let common = BitmapCommonOptions(background: .white)
        let expected = Self.rendered(Self.photo, common: common)
        func meanError(_ image: CGImage) -> Double {
            let bytes = Corpus.pixels(image).bytes
            var total = 0
            for index in stride(from: 0, to: bytes.count, by: 4) {
                total += (0..<3).map { abs(Int(bytes[index + $0]) - Int(expected.bytes[index + $0])) }.reduce(0, +)
            }
            return Double(total) / Double(bytes.count / 4 * 3)
        }
        let dithered = try Self.export(.gif, GIFOptions(common: common, palette: PaletteSettings(colors: 64, ditherPercent: 100), transparent: false), page: Self.photo)
        let banded = try Self.export(.gif, GIFOptions(common: common, palette: PaletteSettings(colors: 64), transparent: false, interlaced: true), page: Self.photo)
        #expect(meanError(dithered.image) < 6)
        #expect(meanError(banded.image) < 6)
        // Dithering breaks the bands up: many more distinct neighbouring pairs.
        func transitions(_ image: CGImage) -> Int {
            let bytes = Corpus.pixels(image).bytes
            return stride(from: 4, to: bytes.count, by: 4).filter { bytes[$0] != bytes[$0 - 4] }.count
        }
        #expect(transitions(dithered.image) > 2 * transitions(banded.image))
        let interlaced = try Data(contentsOf: banded.url)
        #expect(interlaced.range(of: Data([0x2C, 0, 0, 0, 0, 200, 0, 150, 0, 0x40])) != nil)
    }

    @Test func transparentBackgroundAgainstMatteLeavesNoFringe() throws {
        let matte = Color(red: 0.2, green: 0.4, blue: 0.8)
        let page = Corpus.page([Corpus.path(Corpus.ellipse(20, 20, 160, 110), [Corpus.fill(.solid(Corpus.yellow)), Corpus.stroke(.solid(Corpus.red), width: 3)])])
        let result = try Self.export(.gif, GIFOptions(matte: matte), page: page)
        #expect(result.image.alphaInfo != .none)
        let source = Self.rendered(page, common: BitmapCommonOptions(background: .transparent))
        let onMatte = Corpus.pixels(result.image, background: matte).bytes
        let transparentCorner = Corpus.pixels(result.image).bytes
        #expect(transparentCorner[3] == 0)
        // Composited on the matte, every kept pixel -- edges included -- is within a palette step of
        // the artwork over the matte (a white matte's halo would be far off); the rest is the matte.
        var worst = 0
        let mattes = [matte.red, matte.green, matte.blue].map { Int(($0 * 255).rounded()) }
        for index in stride(from: 0, to: onMatte.count, by: 4) {
            let alpha = Int(source.bytes[index + 3])
            guard alpha >= Quantizer.alphaThreshold else {
                #expect(Array(onMatte[index..<(index + 3)]).map(Int.init) == mattes)
                continue
            }
            for channel in 0..<3 {
                let expected = (Int(source.bytes[index + channel]) * alpha + mattes[channel] * (255 - alpha) + 127) / 255
                worst = max(worst, abs(expected - Int(onMatte[index + channel])))
            }
        }
        #expect(worst <= 24, "\(worst)")
    }

    @Test func fixedAndCustomPalettes() throws {
        let common = BitmapCommonOptions(background: .white)
        let web = try Self.export(.gif, GIFOptions(common: common, palette: PaletteSettings(choice: .web216), transparent: false), page: Self.photo)
        let levels: Set<UInt8> = [0, 51, 102, 153, 204, 255]
        #expect(Corpus.pixels(web.image).bytes.enumerated().allSatisfy { $0.offset % 4 == 3 || levels.contains($0.element) })
        let gray = try Self.export(.gif, GIFOptions(common: common, palette: PaletteSettings(choice: .grayscale, colors: 16), transparent: false), page: Self.photo)
        let grayBytes = Corpus.pixels(gray.image).bytes
        let neutral = stride(from: 0, to: grayBytes.count, by: 4).allSatisfy { (index: Int) -> Bool in
            grayBytes[index] == grayBytes[index + 1] && grayBytes[index + 1] == grayBytes[index + 2]
        }
        #expect(neutral)
        // An .act of four colours with a count, and an .aco with RGB, HSB, grey and a CMYK swatch it skips.
        var act = Data(repeating: 0, count: 772)
        for (index, color) in [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)].enumerated() {
            act[index * 3] = UInt8(color.0)
            act[index * 3 + 1] = UInt8(color.1)
            act[index * 3 + 2] = UInt8(color.2)
        }
        act[769] = 4
        let custom = try Self.export(.gif, GIFOptions(common: common, palette: PaletteSettings(choice: .custom(act)), transparent: false), page: Self.logo)
        let allowed: Set<[UInt8]> = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255]]
        let customBytes = Corpus.pixels(custom.image).bytes
        #expect(stride(from: 0, to: customBytes.count, by: 4).allSatisfy { allowed.contains(Array(customBytes[$0..<($0 + 3)])) })
        var aco = Data([0, 1, 0, 4])
        for swatch in [[0, 65535, 0, 0], [1, 0, 65535, 65535], [8, 5000, 0, 0], [2, 1, 2, 3]] {
            aco.append(contentsOf: [0, UInt8(swatch[0])])
            for value in swatch.dropFirst() {
                aco.appendBigEndian(UInt16(value))
            }
            aco.append(contentsOf: [0, 0])
        }
        let loaded = try Quantizer.loadPalette(aco)
        #expect(loaded == [RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 0, b: 0), RGB(r: 128, g: 128, b: 128)])
        #expect(try Quantizer.loadPalette(Data(repeating: 7, count: 768)).count == 256)
        #expect(throws: ExportError.self) { try Quantizer.loadPalette(Data([9, 9, 9])) }
        #expect(throws: ExportError.self) { try Quantizer.loadPalette(Data([0, 1, 0, 5])) }
        #expect(throws: ExportError.self) { try Quantizer.loadPalette(Data([0, 1, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0])) }
        for hue in stride(from: 0.0, to: 1, by: 1.0 / 6) {
            let rgb = Quantizer.hsb(hue: hue + 0.01, saturation: 1, brightness: 1)
            #expect([rgb.0, rgb.1, rgb.2].contains(255))
        }
    }

    @Test func lzwSurvivesTableResets() throws {
        // Noise over 256 colours fills the 4,096-code table many times.
        var generator = SystemRandomNumberGenerator()
        let palette = (0..<256).map { (index: Int) -> RGB in
            RGB(r: UInt8(index), g: UInt8(255 - index), b: UInt8((index * 7) & 0xFF))
        }
        let indices = (0..<(300 * 200)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let image = IndexedImage(width: 300, height: 200, palette: palette, indices: indices, transparentIndex: nil)
        let data = GIFWriter.data(image, interlaced: false)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytes = Corpus.pixels(decoded).bytes
        for (index, value) in indices.enumerated() {
            let color = palette[Int(value)]
            if bytes[index * 4] != color.r || bytes[index * 4 + 1] != color.g || bytes[index * 4 + 2] != color.b {
                Issue.record("pixel \(index) differs")
                break
            }
        }
        #expect(GIFWriter.lzw([], minimumCodeSize: 2).count == 1)
        #expect(GIFWriter.interlacedRows(10) == [0, 8, 4, 2, 6, 1, 3, 5, 7, 9])
    }

    @Test func eightBitPNGAndTIFF() throws {
        let png = try Self.export(.png, PNGOptions(bits: 8), page: Self.logo)
        let pngData = try Data(contentsOf: png.url)
        #expect(pngData[25] == 3 && pngData[24] == 8)
        #expect(pngData.range(of: Data("tRNS".utf8)) != nil)
        #expect(png.image.alphaInfo != .none)
        #expect((png.properties[kCGImagePropertyDPIWidth] as? Double).map { abs($0 - 72) < 0.1 } == true)
        let opaque = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(ppi: 144, background: .white), bits: 8, interlaced: true, palette: PaletteSettings(colors: 32, ditherPercent: 50)), page: Self.photo)
        let opaqueData = try Data(contentsOf: opaque.url)
        #expect(opaqueData[25] == 3 && opaqueData[28] == 1)
        #expect(opaqueData.range(of: Data("tRNS".utf8)) == nil)
        #expect(opaque.image.width == 400)
        let tiny = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(background: .white), bits: 8, interlaced: true), page: Corpus.page([], width: 3, height: 3))
        #expect(tiny.image.width == 3)
        for compression in [TIFFOptions.Compression.none, .lzw, .zip] {
            let tiff = try Self.export(.tiff, TIFFOptions(common: BitmapCommonOptions(background: .white), compression: compression, bits: 8), page: Self.logo)
            let dictionary = tiff.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            #expect(dictionary?[kCGImagePropertyTIFFPhotometricInterpretation] as? Int == 3)
            #expect(tiff.properties[kCGImagePropertyIsIndexed] as? Bool == true)
        }
        #expect(throws: ExportError.self) { try BitmapTests.export(.tiff, TIFFOptions(common: BitmapCommonOptions(background: .white), compression: .jpeg, bits: 8), page: Self.logo) }
        #expect(throws: ExportError.self) { try BitmapTests.export(.tiff, TIFFOptions(bits: 8), page: Self.logo) }
        #expect(throws: ExportError.self) { try BitmapTests.export(.tiff, TIFFOptions(common: BitmapCommonOptions(background: .white, color: .gray), bits: 8), page: Self.logo) }
        #expect(throws: ExportError.self) { try BitmapTests.export(.png, PNGOptions(bits: 8, palette: PaletteSettings(colors: 1)), page: Self.logo) }
        #expect(throws: ExportError.self) { try BitmapTests.export(.tiff, TIFFOptions(common: BitmapCommonOptions(background: .white), bits: 8, palette: PaletteSettings(ditherPercent: 101)), page: Self.logo) }
    }

    @Test func gifOptionsAndErrors() throws {
        #expect(throws: ExportError.self) { try BitmapTests.export(.gif, GIFOptions(palette: PaletteSettings(colors: 300)), page: Self.logo) }
        #expect(throws: ExportError.self) { try BitmapTests.export(.gif, GIFOptions(common: BitmapCommonOptions(color: .gray)), page: Self.logo) }
        #expect(throws: ExportError.wrongOptions(format: .gif)) { try BitmapTests.export(.gif, PNGOptions(), page: Self.logo) }
        #expect(BitmapExporter(format: .gif).optionsType is GIFOptions.Type)
        #expect(GIFOptions.defaults == GIFOptions())
        // Transparent off with a transparent common background reads as white; page colour stays.
        #expect(BitmapExporter.effectiveCommon(GIFOptions(transparent: false)).background == .white)
        #expect(BitmapExporter.effectiveCommon(GIFOptions(common: BitmapCommonOptions(background: .pageColor), transparent: false)).background == .pageColor)
        let scaled = try BitmapTests.export(.gif, GIFOptions(common: BitmapCommonOptions(scales: [1, 2])), page: Self.logo, pattern: .standard)
        #expect(scaled.summary.files.map(\.lastPathComponent) == ["out-1.gif", "out-1@2x.gif"])
        // An empty page with a transparent background is one transparent index.
        let empty = try BitmapTests.export(.gif, GIFOptions(), page: Corpus.page([], width: 4, height: 4))
        #expect(Corpus.pixels(empty.images[0].image).bytes[3] == 0)
        #expect(Quantizer.medianCut([], size: 4) == [RGB(r: 0, g: 0, b: 0)])
        #expect(try Quantizer.palette(.exact, colors: [], size: 4) == [RGB(r: 0, g: 0, b: 0)])
    }
}
