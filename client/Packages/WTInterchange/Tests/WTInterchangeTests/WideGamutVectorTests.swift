// CMS-015's remaining checks: the CSS Color 4 serializer against the WPT css-color serialization
// vectors, every wide value in a written SVG preceded by its sRGB fallback, WebP tagged Display
// P3 where macOS encodes WebP, and the export's RGB space decided once for every page.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct WideGamutVectorTests {
    /// WPT `css/css-color/parsing/color-computed-lab.html` and `color-computed-color-function.html`
    /// (web-platform-tests/wpt at d4e04ca383d7a5469b18e770d7f5f9365ab2ecf8): the expected
    /// serializations of the forms the serializer writes -- `lab()`, `oklch()` and
    /// `color(display-p3 …)`, with and without alpha.  Left out, because the serializer never
    /// writes them: `none` components, `lch()`, `oklab()` (OKLab is written as `oklch()`),
    /// `srgb`/`rec2020`/other `color()` spaces, P3 components outside 0...1 (the serializer writes
    /// Display P3 values gamut-mapped into P3), an achromatic `oklch()` with a hue (a stored
    /// OKLab colour has none), and `calc(infinity)`.
    static let vectors = [
        // lab()
        "lab(0 0 0)", "lab(0 0 0 / 0.5)", "lab(20 0 10 / 0.5)", "lab(100 0 10 / 0.5)", "lab(50 -160 160)", "lab(50 -200 200)",
        "lab(0 0 0 / 0)", "lab(50 -20 0)", "lab(50 0 -20)", "lab(100 -0.5 1.5 / 0.5)", "lab(0 1.5 -1.5 / 0)", "lab(20 -62.5 112.5 / 0.5)",
        "lab(60 30 50 / 0.5)", "lab(60 30 50 / 0.6)", "lab(60 30 50 / 0.51)", "lab(40 30 50 / 0.52)",
        // oklch()
        "oklch(0 0 0)", "oklch(0 0 0 / 0.5)", "oklch(1 2.3 0 / 0.5)", "oklch(0.2 0.5 20 / 0.5)", "oklch(0.1 0.2 20 / 0)", "oklch(0.1 0.2 20)",
        "oklch(0.1 0.2 73.3386)", "oklch(0.2 0 0)", "oklch(0 1.5 320 / 0)", "oklch(0.2 0.24 10 / 0.5)", "oklch(0.6 0.3 50 / 0.5)",
        "oklch(0.6 0.3 50 / 0.6)", "oklch(0.6 0.3 50 / 0.51)", "oklch(0.4 0.3 50 / 0.52)",
        // color(display-p3 …)
        "color(display-p3 1 0.5 0.2)", "color(display-p3 1 0.5 0.2 / 0.6)", "color(display-p3 0.6 0.7 0.8)",
    ]

    /// The colour a vector's serialization names.
    static func color(_ text: String) throws -> Color {
        let open = try #require(text.firstIndex(of: "("))
        let name = String(text[..<open])
        var body = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        var alpha = 1.0
        if let slash = body.firstIndex(of: "/") {
            alpha = try #require(Double(body[body.index(after: slash)...].trimmingCharacters(in: .whitespaces)))
            body = String(body[..<slash])
        }
        var words = body.split(separator: " ").map(String.init)
        if name == "color" { #expect(words.removeFirst() == "display-p3") }
        let n = try words.map { try #require(Double($0)) }
        switch name {
        case "lab": return Color(labL: n[0], a: n[1], b: n[2], alpha: alpha)
        case "oklch": return Color(oklchL: n[0], chroma: n[1], hue: n[2], alpha: alpha)
        default: return Color(displayP3Red: n[0], green: n[1], blue: n[2], alpha: alpha)
        }
    }

    @Test(arguments: vectors) func theSerializerMatchesTheWPTVector(_ expected: String) throws {
        #expect(WTColor.CSS.value(try Self.color(expected)) == expected)
    }

    @Test func theWideValueIsTheVectorFormAndCMYKHasNone() {
        let p3 = Color(displayP3Red: 1, green: 0, blue: 0)
        #expect(WTColor.CSS.serialize(p3).wide == WTColor.CSS.value(p3))
        #expect(WTColor.CSS.value(Color(oklchL: 0.5, chroma: 0.1, hue: 359.99999)) == "oklch(0.5 0.1 0)", "a hue rounding to 360 is 0")
    }

    /// In a written SVG every wide declaration comes straight after the same property's `#rrggbb`
    /// fallback, and the fallback is the colour gamut-mapped into sRGB.
    @Test func everyWideValueInAnSVGFollowsItsFallback() throws {
        let colors = [Color(displayP3Red: 1, green: 0, blue: 0), Color(labL: 50, a: 110, b: -110), Color(oklabL: 0.7, a: 0.3, b: 0.1)]
        var items: [DisplayItem] = []
        for (index, color) in colors.enumerated() {
            let x = Double(index) * 20
            items.append(Corpus.path(Corpus.rect(x, 0, 10, 10), [Corpus.fill(.solid(color)), Corpus.stroke(.solid(color), width: 1)]))
        }
        items.append(Corpus.path(Corpus.rect(0, 40, 10, 10), [Corpus.fill(.solid(Corpus.red))]))
        for styling in [SVGOptions.Styling.presentationAttributes, .inlineStyle, .cssClasses] {
            let text = SVGExporter().documents(scene: Corpus.scene([Corpus.page(items)]), options: SVGOptions(styling: styling))[0].text
            let wide = try Regex(#"(fill|stroke):(color\(display-p3 [^;"}]*\)|lab\([^;"}]*\)|oklch\([^;"}]*\))"#)
            let matches = text.matches(of: wide)
            #expect(matches.count == 6, "\(styling): \(text)")
            for match in matches {
                let property = String(text[match.range].prefix { $0 != ":" })
                let before = text[..<match.range.lowerBound]
                let fallback = try #require(before.matches(of: try Regex("\(property)(:|=\")#([0-9a-f]{6})")).last, "\(styling)")
                let hex = String(before[fallback.range].suffix(6))
                let serialized = String(text[match.range].dropFirst(property.count + 1))
                let color = try #require(colors.first { WTColor.CSS.value($0) == serialized })
                #expect("#" + hex == WTColor.CSS.serialize(color).fallback)
            }
        }
    }

    /// WebP tagged Display P3 with the P3 value, where the running macOS encodes WebP.
    @Test(.enabled(if: BitmapExporter.canEncode(.webp))) func webPIsTaggedDisplayP3() throws {
        let page = Corpus.page([Corpus.path(Corpus.rect(0, 0, 200, 150), [Corpus.fill(.solid(Color(displayP3Red: 0.9, green: 0.1, blue: 0.2)))])])
        let tagged = try BitmapTests.export(.webp, WebPOptions(lossless: true), page: page)
        #expect(tagged.images[0].properties[kCGImagePropertyProfileName] as? String == "Display P3")
        let value = WideGamutOutputTests.pixel(tagged.images[0].image, x: 100, y: 75, in: CGColorSpace(name: CGColorSpace.displayP3)!)
        #expect(zip(value, [0.9, 0.1, 0.2]).allSatisfy { abs(Double($0) / 255 - $1) <= 1.0 / 255 + 1e-9 }, "\(value)")
    }

    /// Where macOS only decodes WebP (the build Mac, IO-024's decision) the export is refused
    /// rather than written untagged.
    @Test(.enabled(if: !BitmapExporter.canEncode(.webp))) func webPWithoutAnEncoderIsRefused() {
        let page = Corpus.page([Corpus.path(Corpus.rect(0, 0, 20, 20), [Corpus.fill(.solid(Color(displayP3Red: 0.9, green: 0.1, blue: 0.2)))])])
        #expect(throws: ExportError.encoderUnavailable(.webp)) { try BitmapExporter.export(.webp, WebPOptions(), page: page) }
    }

    /// The document gamut scan carried by the context decides for every page; without it one
    /// scan of the exported pages does.
    @Test func everyPageOfAnExportSharesOneRGBSpace() throws {
        let narrow = Corpus.page([Corpus.path(Corpus.rect(0, 0, 20, 20), [Corpus.fill(.solid(Corpus.red))])])
        let wide = Corpus.page([Corpus.path(Corpus.rect(0, 0, 20, 20), [Corpus.fill(.solid(Color(displayP3Red: 0.9, green: 0.1, blue: 0.2)))])])
        let directory = Corpus.directory()
        var scene = Corpus.scene([narrow, wide])
        scene.output = .standard
        let destination = ExportDestination(url: directory.appendingPathComponent("page.png"), namePattern: FileNamePattern("{name}-{page}"))
        let summary = try BitmapExporter(format: .png).export(scene: scene, options: PNGOptions(), to: destination)
        let profiles = summary.files.compactMap(BitmapTests.read).map { $0.properties[kCGImagePropertyProfileName] as? String }
        #expect(profiles == ["Display P3", "Display P3"], "the sRGB page follows the document")
        #expect(WTColor.OutputContext.withGamut(of: scene)?.widestSpaceUsed == .displayP3)
        scene.output?.widestSpaceUsed = .sRGB
        #expect(WTColor.OutputContext.withGamut(of: scene)?.widestSpaceUsed == .sRGB, "the document scan wins")
        scene.output = nil
        #expect(WTColor.OutputContext.withGamut(of: scene) == nil)
        // PSD layers render into the composite's space.
        var psd = Corpus.scene([narrow])
        psd.output = .standard
        psd.output?.widestSpaceUsed = .displayP3
        let data = try PSDExporter().data(scene: psd, page: 0, options: PSDOptions())
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyProfileName] as? String == "Display P3")
    }
}

extension BitmapExporter {
    /// Exports `page` as `format`, for a refusal check.
    static func export(_ format: ExportFormat, _ options: any ExportOptions, page: ExportPage) throws {
        _ = try BitmapTests.export(format, options, page: page)
    }
}
