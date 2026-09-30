// CMS-015: a headless WebKit run of a written SVG, with CSS Color 4 and without.  WebKit has no
// switch that turns CSS Color 4 off (its feature flags list none for `color()`, `lab()` or
// `oklch()`), so the run without it loads the same file with every wide value renamed to a
// function no engine knows -- which is what a CSS Color 3 engine sees: an invalid declaration it
// drops, leaving the `#rrggbb` fallback before it in force.  macOS only.

#if canImport(WebKit) && os(macOS)
import CoreGraphics
import Foundation
import Testing
import WebKit
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite(.serialized) struct WideGamutWebKitTests {
    static let p3 = Color(displayP3Red: 1, green: 0, blue: 0)

    /// What WebKit computed for the square's fill, and the pixel at its centre in sRGB.
    @MainActor static func render(_ svg: String) async throws -> (fill: String, pixel: [UInt8]) {
        let folder = Corpus.directory()
        let url = folder.appendingPathComponent("wide.svg")
        try svg.write(to: url, atomically: true, encoding: .utf8)
        let page = HeadlessPage(width: 200, height: 200)
        try await page.load(url, root: folder)
        let fill = try await page.view.evaluateJavaScript("getComputedStyle(document.querySelector('path, rect')).fill") as? String ?? ""
        let image = try await page.snapshot(CGRect(x: 0, y: 0, width: 200, height: 200))
        let pixels = Corpus.pixels(image)
        let x = pixels.width / 10, y = pixels.height / 10
        let offset = (y * pixels.width + x) * 4
        return (fill, Array(pixels.bytes[offset..<offset + 3]))
    }

    @Test @MainActor func webKitUsesTheWideValueAndAnEngineWithoutCSSColor4TheFallback() async throws {
        let page = Corpus.page([Corpus.path(Corpus.rect(0, 0, 100, 100), [Corpus.fill(.solid(Self.p3))])])
        let svg = SVGExporter().documents(scene: Corpus.scene([page]), options: SVGOptions())[0].text
        let serialized = WTColor.CSS.serialize(Self.p3)
        #expect(svg.contains(serialized.wide!))

        let wide = try await Self.render(svg)
        #expect(wide.fill.hasPrefix("color(display-p3 1 0 0"), "\(wide.fill)")

        var legacy = svg
        for function in ["color(", "lab(", "oklch("] {
            legacy = legacy.replacingOccurrences(of: ":" + function, with: ":-wt-no-css-color-4-" + function)
        }
        let fallback = try await Self.render(legacy)
        let expected = WTColor.Gamut.map(Self.p3, into: .sRGB)
        let rgb = [expected.red, expected.green, expected.blue].map { Int(($0 * 255).rounded()) }
        #expect(fallback.fill == "rgb(\(rgb[0]), \(rgb[1]), \(rgb[2]))", "the fallback \(serialized.fallback) is in force")
        #expect(zip(fallback.pixel, rgb).allSatisfy { abs(Int($0) - $1) <= 2 }, "\(fallback.pixel) vs \(rgb)")
    }
}
#endif
