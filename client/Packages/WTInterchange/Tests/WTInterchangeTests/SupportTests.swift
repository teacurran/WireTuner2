// Encoders, colour arithmetic, font programs and the corners of the writers.

import CoreGraphics
import CoreText
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct SupportTests {
    @Test func numbersFormat() {
        #expect(Numbers.format(1.23456, places: 3) == "1.235")
        #expect(Numbers.format(2.5, places: 3) == "2.5")
        #expect(Numbers.format(-0.0001, places: 3) == "0")
        #expect(Numbers.format(.infinity, places: 3) == "0")
        #expect(Numbers.format(12, places: 2) == "12")
        #expect(Numbers.format(1e16 + 0.5, places: 1) == "10000000000000000.0" || Numbers.format(1e16 + 0.5, places: 1).hasPrefix("1000000000000000"))
    }

    @Test func zlibStreamsInflate() throws {
        for data in [Data(), Data("hello hello hello".utf8), Data((0..<20_000).map { UInt8($0 % 251) })] {
            let compressed = Zlib.compress(data)
            #expect(compressed.prefix(2) == Data([0x78, 0x9C]))
            let inflated = try (Data(compressed.dropFirst(2).dropLast(4)) as NSData).decompressed(using: .zlib) as Data
            #expect(inflated == data)
        }
        #expect(Zlib.compress(Data("a".utf8)).suffix(4) == Data([0x00, 0x62, 0x00, 0x62]))
    }

    @Test func imageEncodingAndPixels() {
        #expect(ImageEncoding.encode(Corpus.image(), type: .init(exportedAs: "com.example.none")) == nil)
        #expect(!ImageEncoding.hasAlpha(PDFTests.grayImage()))
        let pixels = RGBAPixels(Corpus.image(alpha: true))
        #expect(!pixels.isOpaque)
        #expect(pixels.rgb.count == 16 * 12 * 3)
        #expect(pixels.alpha.count == 16 * 12)
        #expect(ImageEncoding.dataURL(Data([1]), mime: "a/b") == "data:a/b;base64,AQ==")
    }

    @Test func colorMath() {
        #expect(ColorMath.linear(-0.5) == -ColorMath.linear(0.5))
        #expect(ColorMath.encoded(-0.5) == -ColorMath.encoded(0.5))
        #expect(!ColorMath.isWide(.white))
        #expect(ColorMath.isWide(Color(red: 0, green: 0, blue: 1.01)))
        let p3 = ColorMath.displayP3(Color(red: 1, green: 0, blue: 0))
        #expect(abs(p3.x - 0.9175) < 0.001 && abs(p3.y - 0.2003) < 0.001)
        #expect(ColorMath.clipped(Color(red: 1.2, green: -1, blue: 0.5, alpha: 2)) == Color(red: 1, green: 0, blue: 0.5, alpha: 1))
        #expect(ColorMath.hex(Color(red: 1, green: 0.5, blue: 0)) == "#ff8000")
        let ramp = Ramp(stops: [Gradient.Stop(offset: 0.2, color: Color.black.withAlpha(multipliedBy: 0)), Gradient.Stop(offset: 0.8, color: Color.black.withAlpha(multipliedBy: 0))])
        #expect(ramp.color(at: 0.5) == SIMD4(0, 0, 0, 0))
        #expect(ramp.color(at: .nan) == ramp.color(at: 0))
        #expect(ramp.color(at: 2) == ramp.samples.last!)
    }

    @Test func fontFactsAndPrograms() throws {
        #expect(FontFacts.cssWeight(forTrait: -0.8) == 100)
        #expect(FontFacts.cssWeight(forTrait: 0) == 400)
        #expect(FontFacts.cssWeight(forTrait: 0.4) == 700)
        #expect(FontFacts.cssWeight(forTrait: 0.9) == 900)
        #expect(FontFacts.embeddingPermitted(nil))
        #expect(FontFacts.embeddingPermitted(Data(count: 10)))
        #expect(!FontFacts.embeddingPermitted(Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 2])))
        #expect(!FontFacts.embeddingPermitted(Data([0, 0, 0, 0, 0, 0, 0, 0, 2, 0])))
        #expect(FontProgram.checksum([1, 2, 3]) == 0x0102_0300)
        let helvetica = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let subset = try #require(FontProgram.trueTypeSubset(of: helvetica, glyphs: [36, 37]))
        let descriptor = try #require(CTFontManagerCreateFontDescriptorFromData(subset as CFData))
        let reloaded = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        #expect(CTFontGetGlyphCount(reloaded) == CTFontGetGlyphCount(helvetica))
        #expect(FontProgram.trueTypeSubset(of: CTFontCreateWithName("KohinoorDevanagari-Regular" as CFString, 12, nil), glyphs: [1]) == nil)
        // Composite glyphs name their components: scale, x/y scale and 2×2 variants.
        func composite(_ flags: [UInt16]) -> ArraySlice<UInt8> {
            var bytes: [UInt8] = [0xFF, 0xFF] + [UInt8](repeating: 0, count: 8)
            for (index, flag) in flags.enumerated() {
                let more = index + 1 < flags.count ? UInt16(0x0020) : 0
                FontProgram.append(flag | more, to: &bytes)
                FontProgram.append(UInt16(10 + index), to: &bytes)
                bytes += [UInt8](repeating: 0, count: (flag & 1 != 0 ? 4 : 2) + (flag & 0x08 != 0 ? 2 : flag & 0x40 != 0 ? 4 : flag & 0x80 != 0 ? 8 : 0))
            }
            return bytes[...]
        }
        #expect(FontProgram.components(of: composite([0x0001, 0x0008, 0x0040, 0x0080])) == [10, 11, 12, 13])
        #expect(FontProgram.components(of: [0, 1, 0, 0, 0, 0, 0, 0, 0, 0]) == [])
        // A font with short loca offsets and composite glyphs subsets too.
        for name in ["Geneva", "Times-Roman", "Menlo-Regular", "ArialMT"] {
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            let characters = Array("Åé".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
            #expect(FontProgram.trueTypeSubset(of: font, glyphs: Set(glyphs)) != nil, "\(name)")
        }
        #expect(GlyphFont(postScriptName: "Helvetica", size: 10).subsettable)
        #expect(!GlyphFont(postScriptName: "Helvetica", size: 10, variations: [1: 1]).subsettable)
    }

    @Test func regionRasterizerBounds() throws {
        #expect(RegionRasterizer.render([], region: .null, ppi: 72) == nil)
        let huge = try #require(RegionRasterizer.render([Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(.black))])], region: Rect(x: 0, y: 0, width: 20000, height: 10), ppi: 72))
        #expect(huge.image.width <= RegionRasterizer.maximumEdge)
    }

    @Test func writerCorners() throws {
        // Effects hidden beside live ones, stroke-only effected items, odd shadow angles and
        // effected empty groups.
        let hidden = FlattenerTests.flatten([Corpus.path(Corpus.rect(0, 0, 20, 20), [Corpus.stroke(.solid(.black), width: 2)], effects: [
            EffectElement(.blur(LiveEffect.Blur(radius: 2)), hidden: true),
            EffectElement(.shadow(LiveEffect.Shadow(style: .dropShadow, opacity: 50, angle: .nan))),
        ])])
        if case .group(let group) = hidden.page.nodes[0], case .dropShadow(let dx, _, _, _) = group.filter { #expect(dx == 0) } else { Issue.record("expected a shadow") }
        let emptyGroup = FlattenerTests.flatten([.group(GroupItem(children: [], appearance: Appearance([], effects: [EffectElement(.transparency(LiveEffect.Transparency(amount: 50)))])))])
        #expect(emptyGroup.page.nodes.isEmpty)
        // Legacy fill and stroke items and pattern paints in the wide-colour scan.
        let legacy = DisplayList(canvas: "c", items: [
            .fill(FillItem(path: Corpus.rect(0, 0, 5, 5), paint: .solid(Color(red: 2, green: 0, blue: 0)))),
            .stroke(StrokeItem(path: Corpus.rect(0, 0, 5, 5), paint: .pattern(PatternPaint(bitmap: .checker, color: .black)))),
        ])
        #expect(WideColorScan.count(in: legacy) == 1)
        let flat = FlattenerTests.flatten(legacy.items)
        #expect(flat.page.nodes.count == 2)
        // SVG: minified class styles, clips with even-odd, varying baselines, a transformed
        // element with a gradient, and a writer with a unit it does not know.
        var run = Corpus.run("ab")
        run.glyphs[1].position.y += 2
        let items: [DisplayItem] = [
            .group(GroupItem(children: [Corpus.path(Corpus.rect(0, 0, 50, 50), [Corpus.fill(.solid(Corpus.red))])], clip: Corpus.ellipse(0, 0, 40, 40), clipRule: .evenOdd)),
            .text(TextRunItem(text: "ab", glyphRun: run, origin: .zero)),
            Corpus.path(Corpus.rect(0, 60, 20, 20), [Corpus.fill(Corpus.gradient(.linear))], transform: AffineTransform(a: 1, b: 0, c: 0.4, d: 1, tx: 0, ty: 0)),
        ]
        let svg = SVGTests.write(items, options: SVGOptions(styling: .cssClasses, minify: true))
        #expect(svg.root.all("clipPath")[0].children[0].attributes["clip-rule"] == "evenodd")
        #expect(svg.root.all("text")[0].attributes["y"]!.contains(" "))
        #expect(svg.root.all("linearGradient")[0].attributes["gradientTransform"] == nil)
        let unknown = SVGWriter(options: SVGOptions(responsive: false, sizeUnit: "cm")).write(FlatPage(bounds: Rect(x: 0, y: 0, width: 10, height: 10), nodes: []), scene: Corpus.scene([]))
        #expect(unknown.text.contains("width=\"10cm\""))
        // PDF: even-odd clips, bold fonts with two variation axes, CMYK JPEGs.
        let cmyk = PDFTests.cmykImage()
        let pdfItems: [DisplayItem] = [
            items[0],
            Corpus.text("Bold", font: "Helvetica-Bold", variations: [0x7767_6874: 700, 0x7769_6474: 90]),
            .image(ImageItem(assetID: "c", rect: Rect(x: 0, y: 100, width: 10, height: 10))),
        ]
        let pdf = try PDFTests.export([Corpus.page(pdfItems)], assets: ["c": ExportAsset(image: cmyk, jpegData: ImageEncoding.encode(cmyk, type: .jpeg)!)])
        let raw = PDFTests.text(of: pdf.data)
        #expect(raw.contains("W* n"))
        #expect(raw.contains("/DeviceCMYK /Filter /DCTDecode"))
        #expect(raw.contains("/StemV 120"))
    }
}
