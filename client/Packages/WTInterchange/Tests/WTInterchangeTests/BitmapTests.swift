// IO-021: the tiled supersampling rasterizer and the PNG, JPEG, TIFF, BMP and Targa encoders.
// Goldens live in Goldens/ next to this file; `WTINTERCHANGE_RECORD_GOLDENS=1 swift test` rewrites
// them.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

/// Bitmap options no exporter knows.
struct ForeignOptions: BitmapFormatOptions {
    var common = BitmapCommonOptions()
    static var defaults: ForeignOptions { ForeignOptions() }
}

@Suite struct BitmapTests {
    static let goldens = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Goldens")

    static func read(_ url: URL) -> (image: CGImage, properties: [CFString: Any])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return (image, CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:])
    }

    static func export(_ format: ExportFormat, _ options: any ExportOptions, page: ExportPage = Corpus.fixture("basics"), pattern: FileNamePattern? = nil) throws -> (summary: ExportSummary, images: [(image: CGImage, properties: [CFString: Any])]) {
        let directory = Corpus.directory()
        let summary = try BitmapExporter(format: format).export(scene: Corpus.scene([page]), options: options, to: ExportDestination(url: directory.appendingPathComponent("out.\(format.fileExtension)"), namePattern: pattern))
        return (summary, summary.files.compactMap(read))
    }

    /// A box downsample of `image` by `factor`, over white, for comparing with an export.
    static func downsample(_ image: CGImage, factor: Int) -> [UInt8] {
        let source = Corpus.pixels(image, background: .white)
        let width = source.width / factor, height = source.height / factor
        var result = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<4 {
                    var sum = 0
                    for dy in 0..<factor {
                        for dx in 0..<factor {
                            sum += Int(source.bytes[((y * factor + dy) * source.width + x * factor + dx) * 4 + channel])
                        }
                    }
                    result[(y * width + x) * 4 + channel] = UInt8((sum + factor * factor / 2) / (factor * factor))
                }
            }
        }
        return result
    }

    @Test func exportMatchesTheScreenAfterDownsampling() throws {
        for name in ["basics", "gradients", "effects", "text"] {
            let page = Corpus.fixture(name)
            let exported = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(ppi: 72, antiAliasing: 4, background: .white), bits: 24), page: page)
            let image = exported.images[0].image
            #expect(image.width == 200 && image.height == 150)
            var renderer = CoreGraphicsRenderer(background: .white)
            renderer.rasterPreview = .document
            let screen = renderer.renderBitmap(page.displayList, viewport: Viewport(size: Size(width: 200, height: 150)), scale: 4)!
            let expected = Self.downsample(screen, factor: 4)
            let actual = Corpus.pixels(image, background: .white).bytes
            let worst = zip(expected, actual).map { abs(Int($0) - Int($1)) }.max()!
            #expect(worst <= 1, "\(name): \(worst)")
        }
    }

    @Test func largeExportsRenderInTiles() throws {
        // 1100 × 60 px at anti-aliasing 4: tiles of 512 pixels, three across.
        let items = [Corpus.path(Corpus.rect(5, 5, 1090, 50), [Corpus.fill(Corpus.gradient(.linear)), Corpus.stroke(.solid(.black), width: 3)]), Corpus.path(Corpus.ellipse(500, 0, 60, 60), [Corpus.fill(.solid(Corpus.red))])]
        let page = Corpus.page(items, width: 1100, height: 60)
        let rasterizer = BitmapRasterizer(common: BitmapCommonOptions(background: .white))
        let rendered = rasterizer.render(page, scale: 1, bitsPerComponent: 8, alpha: false)
        #expect(rendered.bitmap.bandCount == 1)
        #expect(rendered.bitmap.bandHeight == 512)
        var renderer = CoreGraphicsRenderer(background: .white)
        renderer.rasterPreview = .document
        let screen = renderer.renderBitmap(page.displayList, viewport: Viewport(size: Size(width: 1100, height: 60)), scale: 4)!
        let expected = Self.downsample(screen, factor: 4)
        let actual = Corpus.pixels(rendered.bitmap.image, background: .white).bytes
        #expect(zip(expected, actual).map { abs(Int($0) - Int($1)) }.max()! <= 1)
        // Several bands: 3× anti-aliasing of a tall page.
        let tall = BitmapRasterizer(common: BitmapCommonOptions(ppi: 144, antiAliasing: 3, background: .white)).render(Corpus.page(items, width: 100, height: 400), scale: 1, bitsPerComponent: 8, alpha: false)
        #expect(tall.bitmap.bandCount == 2)
        #expect(tall.bitmap.image.width == 200)
    }

    @Test(arguments: ["basics", "transparency", "gradients", "text"])
    func goldens(_ name: String) throws {
        let exported = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(ppi: 144)), page: Corpus.fixture(name))
        let image = exported.images[0].image
        let url = Self.goldens.appendingPathComponent("\(name)@2x.png")
        if ProcessInfo.processInfo.environment["WTINTERCHANGE_RECORD_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: Self.goldens, withIntermediateDirectories: true)
            try ImageEncoding.encode(image, type: .png)!.write(to: url)
        }
        let golden = try #require(Self.read(url)?.image, "missing golden \(url.lastPathComponent)")
        let failing = Corpus.difference(golden, image, tolerance: 24)
        if failing > 0.002 {
            Corpus.dump(image, "golden-\(name)")
        }
        #expect(failing <= 0.002, "\(name): \(failing)")
    }

    @Test func everyDepthAndCompressionReadsBack() throws {
        let png24 = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(background: .white), bits: 24, interlaced: true, fast: true))
        #expect(png24.images[0].image.alphaInfo == .none || png24.images[0].image.alphaInfo == .noneSkipLast)
        #expect((png24.images[0].properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyPNGInterlaceType] as? Int == 1)
        let png32 = try Self.export(.png, PNGOptions())
        #expect(ImageEncoding.hasAlpha(png32.images[0].image))
        let png64 = try Self.export(.png, PNGOptions(bits: 64))
        #expect(png64.images[0].image.bitsPerComponent == 16 && ImageEncoding.hasAlpha(png64.images[0].image))
        let png48 = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(background: .pageColor), bits: 48))
        #expect(png48.images[0].image.bitsPerComponent == 16)
        let jpeg = try Self.export(.jpeg, JPEGOptions(quality: 60, progressive: true))
        #expect(jpeg.images[0].image.width == 200)
        let cmyk = try Self.export(.jpeg, JPEGOptions(common: BitmapCommonOptions(background: .white, color: .cmyk)))
        #expect(cmyk.images[0].properties[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelCMYK as String)
        for compression in [TIFFOptions.Compression.none, .lzw, .zip, .jpeg] {
            let tiff = try Self.export(.tiff, TIFFOptions(common: BitmapCommonOptions(background: compression == .jpeg ? .white : .transparent), compression: compression, bits: compression == .jpeg ? 24 : 32))
            #expect(tiff.images.count == 1, "\(compression)")
        }
        let tiffCMYK = try Self.export(.tiff, TIFFOptions(common: BitmapCommonOptions(background: .white, color: .cmyk)))
        #expect(tiffCMYK.images[0].properties[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelCMYK as String)
        let tiff16 = try Self.export(.tiff, TIFFOptions(bits: 64))
        #expect(tiff16.images[0].image.bitsPerComponent == 16)
        let gray = try Self.export(.tiff, TIFFOptions(common: BitmapCommonOptions(background: .white, color: .gray, embedProfile: false), bits: 24))
        #expect(gray.images[0].properties[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelGray as String)
        let bmp = try Self.export(.bmp, BMPOptions())
        #expect(bmp.images[0].image.width == 200)
        let bmp24 = try Self.export(.bmp, BMPOptions(common: BitmapCommonOptions(background: .white), bits: 24))
        #expect(bmp24.images[0].image.height == 150)
    }

    @Test func targaWritesEveryDepth() throws {
        for (bits, rle) in [(32, false), (32, true), (24, false), (24, true), (16, true)] {
            let background: BitmapCommonOptions.Background = bits == 24 ? .white : .transparent
            let result = try Self.export(.targa, TargaOptions(common: BitmapCommonOptions(background: background), bits: bits, rle: rle))
            let data = try Data(contentsOf: result.summary.files[0])
            #expect(data[2] == (rle ? 10 : 2))
            #expect(data[16] == UInt8(bits))
            #expect(String(decoding: data.suffix(18).prefix(17), as: UTF8.self) == "TRUEVISION-XFILE.")
            let image = try #require(result.images.first?.image, "\(bits) \(rle)")
            #expect(image.width == 200 && image.height == 150)
        }
        let gray = try Self.export(.targa, TargaOptions(common: BitmapCommonOptions(background: .white, color: .gray), bits: 8, rle: true))
        let data = try Data(contentsOf: gray.summary.files[0])
        #expect(data[2] == 11)
        // Alpha survives: the page corner is transparent.
        let transparent = try Self.export(.targa, TargaOptions())
        let pixels = Corpus.pixels(transparent.images[0].image)
        #expect(pixels.bytes[3] == 0)
        #expect(TargaWriter.encodeRLE([1, 1, 1, 2, 3, 3], pixelBytes: 1) == [0x82, 1, 0x00, 2, 0x81, 3])
        #expect(TargaWriter.encodeRLE([1, 2, 3], pixelBytes: 1) == [0x02, 1, 2, 3])
    }

    @Test func alphaBackgroundsAndScales() throws {
        let transparent = try Self.export(.png, PNGOptions())
        #expect(Corpus.pixels(transparent.images[0].image).bytes[3] == 0)
        var page = Corpus.fixture("basics")
        page.background = Color(red: 1, green: 0, blue: 0, alpha: 0.5)
        let colored = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(background: .pageColor), bits: 24), page: page)
        let corner = Corpus.pixels(colored.images[0].image).bytes
        #expect(corner[0] == 255 && corner[1] == 128)
        let scaled = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(scales: [1, 2, 3])), pattern: .standard)
        #expect(scaled.summary.files.map(\.lastPathComponent) == ["out-1.png", "out-1@2x.png", "out-1@3x.png"])
        #expect(scaled.images.map(\.image.width) == [200, 400, 600])
        let tokens = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(scales: [1, 2])), pattern: "{name}{scale}")
        #expect(tokens.summary.files.map(\.lastPathComponent) == ["out.png", "out@2x.png"])
        let none = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(antiAliasing: 1)))
        #expect(none.images[0].image.width == 200)
        let overprint = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(simulateOverprint: true)))
        #expect(overprint.images.count == 1)
    }

    @Test func maskFromLayerMultipliesAlpha() throws {
        let page = Corpus.page([Corpus.path(Corpus.rect(0, 0, 200, 150), [Corpus.fill(.solid(Corpus.red))])])
        let mask = DisplayList(canvas: "mask", items: [Corpus.path(Corpus.rect(0, 0, 200, 150), [Corpus.fill(Corpus.gradient(.linear, stops: [Gradient.Stop(offset: 0, color: .black), Gradient.Stop(offset: 1, color: .white)]))])])
        let result = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(maskLayer: mask)), page: page)
        let pixels = Corpus.pixels(result.images[0].image)
        let left = pixels.bytes[(75 * 200 + 2) * 4 + 3], right = pixels.bytes[(75 * 200 + 197) * 4 + 3]
        #expect(left < 20 && right > 235)
        let deep = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(maskLayer: mask), bits: 64), page: page)
        #expect(deep.images[0].image.bitsPerComponent == 16)
    }

    @Test func colorSpacesAndProfiles() throws {
        let wide = Corpus.page([Corpus.path(Corpus.rect(0, 0, 200, 150), [Corpus.fill(.solid(Color(red: 1.1, green: 0.2, blue: -0.1)))]), Corpus.text("A", color: Color(red: 0, green: 1.2, blue: 0)), .group(GroupItem(children: [Corpus.path(Corpus.rect(0, 0, 5, 5), [Corpus.stroke(Corpus.gradient(.linear), width: 1)])])), .image(ImageItem(assetID: "x", rect: Rect(x: 0, y: 0, width: 1, height: 1)))])
        #expect(WideColorScan.count(in: wide.displayList) == 2)
        let auto = try Self.export(.png, PNGOptions(), page: wide)
        #expect(auto.images[0].properties[kCGImagePropertyProfileName] as? String == "Display P3")
        #expect(auto.summary.notes.isEmpty)
        let untagged = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(embedProfile: false)), page: wide)
        #expect(untagged.images[0].properties[kCGImagePropertyProfileName] as? String != "Display P3")
        #expect(untagged.summary.notes == ["2 colors outside sRGB pulled into sRGB"])
        let forced = try Self.export(.tiff, TIFFOptions(common: BitmapCommonOptions(rgbSpace: .displayP3)))
        #expect(forced.images[0].properties[kCGImagePropertyProfileName] as? String == "Display P3")
        let srgb = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(rgbSpace: .sRGB)), page: wide)
        #expect(srgb.summary.notes == ["2 colors outside sRGB pulled into sRGB"])
        let working = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(rgbSpace: .workingRGB)))
        #expect(working.images[0].properties[kCGImagePropertyProfileName] as? String == "sRGB IEC61966-2.1")
        let one = Corpus.page([Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(Color(red: 1.1, green: 0, blue: 0)))])])
        #expect(try Self.export(.png, PNGOptions(common: BitmapCommonOptions(embedProfile: false)), page: one).summary.notes == ["1 color outside sRGB pulled into sRGB"])
        let cmykUntagged = try Self.export(.tiff, TIFFOptions(common: BitmapCommonOptions(background: .white, color: .cmyk, embedProfile: false)))
        #expect(cmykUntagged.images.count == 1)
        let grayTagged = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(background: .white, color: .gray), bits: 24))
        #expect(grayTagged.images[0].properties[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelGray as String)
    }

    @Test func invalidOptionsAreRejected() {
        let invalid: [(ExportFormat, any ExportOptions)] = [
            (.png, PNGOptions(common: BitmapCommonOptions(ppi: 0))),
            (.png, PNGOptions(common: BitmapCommonOptions(scales: []))),
            (.png, PNGOptions(common: BitmapCommonOptions(antiAliasing: 5))),
            (.png, PNGOptions(bits: 8)),
            (.png, PNGOptions(bits: 24)),
            (.png, PNGOptions(common: BitmapCommonOptions(color: .cmyk))),
            (.png, PNGOptions(common: BitmapCommonOptions(background: .white, maskLayer: DisplayList(canvas: "m", items: [])), bits: 24)),
            (.jpeg, JPEGOptions(quality: 0)),
            (.jpeg, JPEGOptions(common: BitmapCommonOptions())),
            (.tiff, TIFFOptions(common: BitmapCommonOptions(background: .white, color: .cmyk), bits: 24)),
            (.bmp, BMPOptions(bits: 16)),
            (.bmp, BMPOptions(rle: true)),
            (.targa, TargaOptions(bits: 12)),
            (.targa, TargaOptions(common: BitmapCommonOptions(background: .white), bits: 8)),
            (.png, JPEGOptions()),
            (.png, SVGOptions()),
        ]
        let directory = Corpus.directory()
        for (format, options) in invalid {
            #expect(throws: ExportError.self, "\(format) \(options)") {
                try BitmapExporter(format: format).export(scene: Corpus.scene([Corpus.fixture("basics")]), options: options, to: ExportDestination(url: directory.appendingPathComponent("x")))
            }
        }
        #expect(throws: ExportError.nothingToExport) {
            try BitmapExporter(format: .png).export(scene: Corpus.scene([]), options: PNGOptions(), to: ExportDestination(url: directory.appendingPathComponent("x")))
        }
        for url in [URL(fileURLWithPath: "/nonexistent-folder/x.png"), URL(fileURLWithPath: "/nonexistent-folder/x.tga")] {
            let format = ExportFormat(fileExtension: url.pathExtension)!
            let options: any ExportOptions = format == .png ? PNGOptions() : TargaOptions()
            #expect(throws: ExportError.self) {
                try BitmapExporter(format: format).export(scene: Corpus.scene([Corpus.fixture("basics")]), options: options, to: ExportDestination(url: url))
            }
        }
        #expect((try? BitmapExporter(format: .png).layout(for: ForeignOptions())) == nil)
        #expect(PNGOptions.defaults.bits == 32 && JPEGOptions.defaults.quality == 85 && TIFFOptions.defaults.compression == .lzw && BMPOptions.defaults.bits == 32 && TargaOptions.defaults.bits == 32)
        #expect(BitmapExporter(format: .jpeg).optionsType is JPEGOptions.Type)
        #expect(BitmapExporter(format: .tiff).optionsType is TIFFOptions.Type)
        #expect(BitmapExporter(format: .bmp).optionsType is BMPOptions.Type)
    }

    @Test func bandReaderSkipsAndRewinds() {
        let bitmap = BitmapRasterizer(common: BitmapCommonOptions()).render(Corpus.page([]), scale: 1, bitsPerComponent: 8, alpha: true).bitmap
        let reader = BandReader(bitmap: bitmap)
        #expect(reader.skip(10) == 10)
        #expect(reader.skip(Int.max / 2) == reader.total - 10)
        var byte: UInt8 = 0
        #expect(reader.read(into: &byte, count: 1) == 0)
        reader.rewind()
        #expect(reader.read(into: &byte, count: 1) == 1)
        let provider = bitmap.image.dataProvider!
        #expect(CFDataGetLength(provider.data!) == bitmap.bytesPerRow * bitmap.height)
    }
}
