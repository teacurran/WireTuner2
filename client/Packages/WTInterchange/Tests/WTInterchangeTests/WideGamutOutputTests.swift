// CMS-015: wide-gamut output.  The gamut scan and the RGB export space, the Display P3 bytes, the
// CSS Color 4 serializer with its sRGB fallback, the sRGB pull-in for files without a profile (the
// same pixels as COLOR-024's mapping), P3 bitmaps that decode to the P3 value, and PDF/X-4 keeping
// P3 objects tagged.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct WideGamutOutputTests {
    typealias Context = WTColor.OutputContext
    static let p3Red = Color(displayP3Red: 1, green: 0, blue: 0)
    static let deepLab = Color(labL: 50, a: 110, b: -110)

    @Test func theScanFindsHowFarColoursReach() {
        #expect(Context.widestSpace(of: [Color.white, Corpus.red]) == .sRGB)
        #expect(Context.widestSpace(of: [Corpus.red, Self.p3Red]) == .displayP3)
        #expect(Context.widestSpace(of: [Self.p3Red, Self.deepLab, .black]) == .beyondDisplayP3)
        #expect(Context.GamutReach.sRGB < .displayP3 && .displayP3 < .beyondDisplayP3)
        let wide = Corpus.page([
            Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.stroke(.solid(Corpus.blue), width: 1)]),
            .group(GroupItem(children: [Corpus.text("A", color: Self.p3Red)])),
        ])
        #expect(Context.widestSpaceUsed(in: Corpus.scene([Corpus.page([Corpus.path(Corpus.rect(0, 0, 1, 1), [Corpus.fill(.solid(.black))])]), wide])) == .displayP3)
        #expect(Context.widestSpaceUsed(in: Corpus.scene([Corpus.fixture("basics")])) == .sRGB)
    }

    @Test func rgbExportSpaceFollowsWorkingRGBUnlessItIsNarrower() throws {
        let registry = WTColor.ProfileRegistry.shared
        let standard = Context.standard
        #expect(standard.rgbExportSpace(widest: .sRGB) == registry.sRGB)
        #expect(standard.rgbExportSpace(widest: .displayP3) == registry.displayP3)
        #expect(standard.rgbExportSpace(widest: .beyondDisplayP3) == registry.displayP3)
        let p3 = Context(rgbProfile: registry.displayP3)
        #expect(p3.rgbExportSpace(widest: .displayP3) == registry.displayP3)
        let adobe = try #require(registry.register(colorSpace: CGColorSpace(name: CGColorSpace.adobeRGB1998)!))
        #expect(Context(rgbProfile: adobe).rgbExportSpace(widest: .sRGB) == adobe)
        #expect(Context(rgbProfile: adobe).rgbExportSpace(widest: .displayP3) == registry.displayP3, "Adobe RGB does not hold P3's red")
        let prophoto = try #require(registry.register(colorSpace: CGColorSpace(name: CGColorSpace.rommrgb)!))
        #expect(Context(rgbProfile: prophoto).rgbExportSpace(widest: .displayP3) == prophoto, "ProPhoto holds Display P3")
        #expect(standard.displayP3ICC == CGColorSpace(name: CGColorSpace.displayP3)!.copyICCData()! as Data)
    }

    @Test func theSerializerPairsEveryWideValueWithAFallback() {
        #expect(WTColor.CSS.serialize(Corpus.red) == ("#e61a1a", nil))
        #expect(WTColor.CSS.serialize(Color(cyan: 1, magenta: 0, yellow: 0, black: 0)).wide == nil)
        let p3 = WTColor.CSS.serialize(Self.p3Red)
        #expect(p3.fallback == ColorMath.hex(WTColor.Gamut.map(Self.p3Red, into: .sRGB)))
        #expect(p3.wide == "color(display-p3 1 0 0)")
        var translucent = Self.p3Red
        translucent.alpha = 0.5
        #expect(WTColor.CSS.serialize(translucent).wide == "color(display-p3 1 0 0 / 0.5)")
        #expect(WTColor.CSS.serialize(Color(red: 1.2, green: 0.1, blue: -0.05)).wide?.hasPrefix("color(display-p3 ") == true)
        #expect(WTColor.CSS.serialize(Self.deepLab).wide == "lab(50 110 -110)")
        let oklab = Color(oklabL: 0.7, a: 0.3, b: 0.1)
        let lch = WTColor.Math.oklch(fromOKLab: SIMD3(0.7, 0.3, 0.1))
        #expect(WTColor.CSS.serialize(oklab).wide == "oklch(0.7 \(Numbers.format(lch.y, places: 5)) \(Numbers.format(lch.z, places: 4)))")
        #expect(WTColor.CSS.declarations("fill", Self.p3Red) == ["fill:\(p3.fallback)", "fill:color(display-p3 1 0 0)"])
        #expect(WTColor.CSS.declarations("fill", .black) == ["fill:#000000"])
        // Every serialized form reads back as the colour through the SVG importer's CSS Color 4
        // parser (the serialization vectors: shortest numbers, `none` never written).
        for color in [Self.p3Red, Color(displayP3Red: 0.25, green: 0.875, blue: 0.5)] {
            let parsed = SVGImportValues.color(WTColor.CSS.serialize(color).wide!)
            #expect(parsed?.space == .displayP3)
            #expect(parsed.map { value in (0..<4).allSatisfy { i in abs(value.components[i] - color.components[i]) < 0.001 } } == true)
        }
    }

    @Test func warningsAndThePullIntoSRGB() throws {
        #expect(Context.clippedWarning(0) == nil)
        #expect(Context.clippedWarning(1) == "1 color outside sRGB was clipped")
        #expect(Context.clippedWarning(3) == "3 colors outside sRGB were clipped")
        let gradient = Paint.gradient(Gradient(kind: .linear, stops: [Gradient.Stop(offset: 0, color: Self.p3Red), Gradient.Stop(offset: 1, color: .white)]))
        let list = DisplayList(canvas: "c", items: [
            .fill(FillItem(path: Corpus.rect(0, 0, 5, 5), paint: .solid(Self.p3Red))),
            .stroke(StrokeItem(path: Corpus.rect(0, 0, 5, 5), style: StrokeStyle(width: 1), paint: gradient)),
            Corpus.path(Corpus.rect(0, 0, 5, 5), [Corpus.fill(.solid(Self.deepLab)), Corpus.stroke(.solid(Corpus.red), width: 1)]),
            .group(GroupItem(children: [Corpus.text("B", color: Self.p3Red)])),
            .image(ImageItem(assetID: "x", rect: Rect(x: 0, y: 0, width: 1, height: 1))),
        ])
        let mapped = Context.mappedIntoSRGB(list)
        #expect(WideColorScan.count(in: mapped) == 0)
        #expect(WideColorScan.count(in: list) == 2)
        var colors = Set<Color>()
        mapped.items.forEach { WideColorScan.collect($0, into: &colors) }
        #expect(colors.contains(Corpus.red) && colors.contains(.white), "colours inside sRGB are untouched")
        #expect(colors.contains(WTColor.Gamut.map(Self.p3Red, into: .sRGB)))
    }

    static func pixel(_ image: CGImage, x: Int, y: Int, in space: CGColorSpace) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return [bytes[offset], bytes[offset + 1], bytes[offset + 2]]
    }

    @Test func p3BitmapsDecodeToTheP3ValueAndUntaggedOnesToTheMappedOne() throws {
        let fill = Color(displayP3Red: 0.9, green: 0.1, blue: 0.2)
        let page = Corpus.page([Corpus.path(Corpus.rect(0, 0, 200, 150), [Corpus.fill(.solid(fill))])])
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        for (format, options) in [(ExportFormat.png, PNGOptions() as any ExportOptions), (.tiff, TIFFOptions())] {
            let tagged = try BitmapTests.export(format, options, page: page)
            #expect(tagged.images[0].properties[kCGImagePropertyProfileName] as? String == "Display P3")
            let value = Self.pixel(tagged.images[0].image, x: 100, y: 75, in: p3)
            #expect(zip(value, [0.9, 0.1, 0.2]).allSatisfy { abs(Double($0) / 255 - $1) <= 1.0 / 255 + 1e-9 }, "\(value)")
        }
        // Without a profile: sRGB pixels of COLOR-024's mapping, the same on every Mac.
        let untagged = try BitmapTests.export(.png, PNGOptions(common: BitmapCommonOptions(embedProfile: false)), page: page)
        #expect(untagged.summary.notes == ["1 color outside sRGB was clipped"])
        let mapped = WTColor.Gamut.map(fill, into: .sRGB)
        let value = Self.pixel(untagged.images[0].image, x: 100, y: 75, in: CGColorSpace(name: CGColorSpace.sRGB)!)
        #expect(zip(value, [mapped.red, mapped.green, mapped.blue]).allSatisfy { abs(Double($0) / 255 - $1) <= 1.0 / 255 + 1e-9 }, "\(value)")
        // A Working RGB that holds P3 is kept under Automatic.
        var scene = Corpus.scene([page])
        let prophoto = try #require(WTColor.ProfileRegistry.shared.register(colorSpace: CGColorSpace(name: CGColorSpace.rommrgb)!))
        scene.output = Context(rgbProfile: prophoto)
        let rasterizer = BitmapRasterizer(common: BitmapCommonOptions(), output: scene.output)
        #expect(rasterizer.colorSetup(for: page).space.name == CGColorSpace.rommrgb)
        scene.output = Context.standard
        #expect(BitmapRasterizer(common: BitmapCommonOptions(), output: scene.output).colorSetup(for: page).space.name == CGColorSpace.displayP3)
        #expect(BitmapRasterizer(common: BitmapCommonOptions(), output: scene.output).colorSetup(for: Corpus.fixture("basics")).space.name == CGColorSpace.sRGB)
    }

    @Test func pdfX4KeepsP3TaggedAndX1aConvertsIt() throws {
        let page = Corpus.page([Corpus.path(Corpus.rect(0, 0, 40, 40), [Corpus.fill(.solid(Self.p3Red))])])
        let x4 = try PDFExporter().data(scene: Corpus.scene([page]), options: .printPDFX4)
        #expect(x4.notes.contains("1 Display P3 color kept tagged with the Display P3 profile"), "\(x4.notes)")
        #expect(!x4.notes.contains { $0.hasPrefix("PDF/X check") })
        let raw = PDFTests.text(of: x4.data)
        #expect(raw.contains("/S /GTS_PDFX"))
        let legacy = try PDFExporter().data(scene: Corpus.scene([page]), options: PDFOptions(version: .v1_4))
        #expect(legacy.notes.contains { $0.hasPrefix("1 wide-gamut color gamut-mapped into sRGB") })
        let x1a = try PDFExporter().data(scene: Corpus.scene([page]), options: .pressPDFX1a)
        #expect(!PDFTests.text(of: x1a.data).contains("/ICCBased"))
    }
}
