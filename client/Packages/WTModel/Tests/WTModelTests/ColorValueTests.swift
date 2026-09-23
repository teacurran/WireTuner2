import Foundation
import Testing
import WTCRDT
@testable import WTModel
import WTProto
import WTRender

/// COLOR-002: the stored `Color` with its read-time rules, default names, the CSS Color 4
/// parser, HLS/HSV, web-safe snapping, nearest and the gamut tests.
@Suite struct ColorValueTests {
    static func stored(_ build: (inout Wiretuner_Doc_V1_Color) -> Void) -> Wiretuner_Doc_V1_Color {
        var color = Wiretuner_Doc_V1_Color()
        build(&color)
        return color
    }

    @Test func eachSpaceReadsAsTagged() {
        let p3 = Self.stored { $0.rgb.r = 1; $0.space = .displayP3 }
        #expect(ColorValues.color(p3) == Color(displayP3Red: 1, green: 0, blue: 0))
        let srgb = Self.stored { $0.rgb.g = 0.5 }
        #expect(ColorValues.color(srgb) == Color(red: 0, green: 0.5, blue: 0))
        let lab = Self.stored { $0.lab.l = 54; $0.lab.a = 63; $0.lab.b = 32; $0.space = .lab }
        #expect(ColorValues.color(lab) == Color(labL: 54, a: 63, b: 32))
        let oklab = Self.stored { $0.lab.l = 0.6; $0.lab.a = 0.1; $0.space = .oklab }
        #expect(ColorValues.color(oklab) == Color(oklabL: 0.6, a: 0.1, b: 0))
        let cmyk = Self.stored { $0.cmyk.m = 0.8; $0.space = .displayP3 }
        #expect(ColorValues.color(cmyk) == Color(cyan: 0, magenta: 0.8, yellow: 0, black: 0))
    }

    @Test func mismatchedAndUnknownTagsFollowTheReadTimeRules() throws {
        // No case: white CMYK.
        #expect(ColorValues.color(Wiretuner_Doc_V1_Color()) == Color(cyan: 0, magenta: 0, yellow: 0, black: 0))
        // rgb tagged LAB or OKLAB reads as sRGB; lab tagged SRGB or DISPLAY_P3 as CIELAB.
        #expect(ColorValues.color(Self.stored { $0.rgb.r = 0.2; $0.space = .oklab }).space == .sRGB)
        #expect(ColorValues.color(Self.stored { $0.lab.l = 50; $0.space = .displayP3 }).space == .lab)
        // An unknown tag reads as sRGB (rgb) or CIELAB (lab), and survives re-encoding.
        let unknown = Self.stored { $0.rgb.r = 0.25; $0.space = .UNRECOGNIZED(9) }
        #expect(ColorValues.color(unknown) == Color(red: 0.25, green: 0, blue: 0))
        #expect(ColorValues.color(Self.stored { $0.lab.l = 20; $0.space = .UNRECOGNIZED(9) }).space == .lab)
        let bytes = try unknown.serializedBytes() as [UInt8]
        #expect(try Wiretuner_Doc_V1_Color(serializedBytes: bytes).space == .UNRECOGNIZED(9))
        // Out-of-range components are clamped to the space.
        #expect(ColorValues.color(Self.stored { $0.lab.l = 40; $0.space = .oklab }).components.x == 1)
    }

    @Test func storedColorsRoundTripWithTheirSpaces() {
        for color in [Color(cyan: 0.1, magenta: 0.2, yellow: 0.3, black: 0.4), Color(red: 0.1, green: 0.2, blue: 0.3),
                      Color(displayP3Red: 0.9, green: 0.2, blue: 0.1), Color(labL: 50, a: -20, b: 30), Color(oklabL: 0.7, a: 0.1, b: -0.1)] {
            #expect(ColorValues.color(ColorValues.stored(color)) == color)
            #expect(ColorValues.cachedColor(ColorValues.cached(color)) == color)
        }
        #expect(ColorValues.stored(Color(displayP3Red: 1, green: 0, blue: 0)).space == .displayP3)
        #expect(ColorValues.cachedColor(Data()) == nil)
        #expect(ColorValues.cachedColor(Data([0xFF, 0xFF])) == nil)
        #expect(ColorValues.badge(.sRGB) == "RGB" && ColorValues.badge(.displayP3) == "P3" && ColorValues.badge(.lab) == "Lab")
        #expect(ColorValues.badge(.oklab) == "OKLab" && ColorValues.badge(.cmyk) == nil)
        #expect(FormulaColorConversion().convert(Color(red: 1, green: 0, blue: 0), to: .cmyk) == Color(red: 1, green: 0, blue: 0).converted(to: .cmyk))
    }

    @Test func defaultNamesFormatAndParseBack() throws {
        let names = ["0c 80m 90y 0k", "230r 57g 70b", "p3(0.90 0.22 0.27)", "lab(54 63 32)", "oklch(62% 0.22 25)"]
        for name in names {
            let color = try #require(ColorText.parse(name), "\(name)")
            #expect(ColorText.defaultName(color) == name)
        }
        #expect(ColorText.defaultName(ColorFixture.red) == "230r 57g 70b")
        #expect(ColorText.field(ColorFixture.red) == "#E63946")
        #expect(ColorText.field(Color(cyan: 0, magenta: 0.8, yellow: 0.9, black: 0)) == "0c 80m 90y 0k")
        #expect(ColorText.defaultName(Color(labL: 54, a: -63, b: 32)) == "lab(54 -63 32)")
        // A grey has no hue.
        #expect(ColorText.defaultName(Color(oklabL: 0.5, a: 0, b: 0)) == "oklch(50% 0.00 0)")
        #expect(ColorText.tintName(percent: 40, base: "Grape") == "40% Grape")
        #expect(ColorText.unique("Grape") { _ in false } == "Grape")
        #expect(ColorText.unique("Grape") { ["Grape", "Grape-1"].contains($0) } == "Grape-2")
    }

    @Test func cssColor4FormsParse() throws {
        #expect(ColorText.parse("#e63946") == ColorFixture.red)
        #expect(ColorText.parse("  #E63946 ") == ColorFixture.red)
        #expect(ColorText.parse("#f00") == Color(red: 1, green: 0, blue: 0))
        #expect(ColorText.parse("#f008") == Color(red: 1, green: 0, blue: 0))
        #expect(ColorText.parse("#ff000080") == Color(red: 1, green: 0, blue: 0))
        #expect(ColorText.parse("rgb(255, 0, 0)") == Color(red: 1, green: 0, blue: 0))
        #expect(ColorText.parse("rgba(100% 0% 0% / 0.5)") == Color(red: 1, green: 0, blue: 0))
        #expect(ColorText.parse("color(display-p3 1 0 0)") == Color(displayP3Red: 1, green: 0, blue: 0))
        #expect(ColorText.parse("color(srgb 0 1 0)") == Color(red: 0, green: 1, blue: 0))
        #expect(ColorText.parse("p3(50% 0 0)") == Color(displayP3Red: 0.5, green: 0, blue: 0))
        #expect(ColorText.parse("lab(50% 20 -30)") == Color(labL: 50, a: 20, b: -30))
        #expect(ColorText.parse("oklab(0.5 50% -0.1)") == Color(oklabL: 0.5, a: 0.2, b: -0.1))
        let oklch = try #require(ColorText.parse("oklch(70% 0.1 120deg)"))
        #expect(close(oklch, Color(oklchL: 0.7, chroma: 0.1, hue: 120), 1e-12))
        #expect(ColorText.parse("oklch(0.7 none 0)") == Color(oklchL: 0.7, chroma: 0, hue: 0))
        #expect(ColorText.parse("0c 80m 90y 0k") == Color(cyan: 0, magenta: 0.8, yellow: 0.9, black: 0))
        for bad in ["", "#12", "#ggg", "rgb(1 2)", "rgb(a b c)", "color(rec2020 1 0 0)", "color(srgb 1)", "hsl(0 0% 0%)", "oklch(1 2)",
                    "oklch(a 0 0)", "p3(1 x 0)", "0c 80m 90y", "0c 80x 90y 0k", "1r 2g bb", "grape"] {
            #expect(ColorText.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func hlsAndHSVRoundTripInEitherRGBSpace() {
        let colors = [Color(red: 0.9, green: 0.2, blue: 0.3), Color(red: 0.2, green: 0.9, blue: 0.3), Color(red: 0.2, green: 0.3, blue: 0.9),
                      Color(displayP3Red: 0.8, green: 0.7, blue: 0.1), Color(red: 0.5, green: 0.5, blue: 0.5), Color(red: 0.7, green: 0.1, blue: 0.9)]
        for color in colors {
            let hls = ColorModels.hls(color)
            #expect(close(ColorModels.color(hls, in: color.space), color, 1e-9))
            let hsv = ColorModels.hsv(color)
            #expect(close(ColorModels.color(hsv, in: color.space), color, 1e-9))
        }
        let red = ColorModels.hls(Color(red: 1, green: 0, blue: 0))
        #expect(red == ColorModels.HLS(hue: 0, lightness: 0.5, saturation: 1))
        #expect(ColorModels.hsv(Color(red: 0, green: 0, blue: 0)) == ColorModels.HSV(hue: 0, saturation: 0, value: 0))
        // A non-RGB colour is read in the default space; a non-RGB target writes sRGB.
        #expect(ColorModels.rgbSpace(of: Color(labL: 50, a: 0, b: 0)) == .displayP3)
        #expect(ColorModels.rgbSpace(of: Color(labL: 50, a: 0, b: 0), fallback: .cmyk) == .sRGB)
        #expect(ColorModels.color(ColorModels.HLS(hue: 300, lightness: 0.5, saturation: 1), in: .cmyk) == Color(red: 1, green: 0, blue: 1))
        #expect(ColorModels.color(ColorModels.HSV(hue: -60, saturation: 1, value: 1), in: .lab) == Color(red: 1, green: 0, blue: 1))
    }

    @Test func webSafeNearestAndGamut() {
        #expect(ColorModels.webSafe(Color(red: 0.29, green: 0.61, blue: 0.95)) == Color(red: 0.2, green: 0.6, blue: 1))
        let candidates = [Color(red: 1, green: 0, blue: 0), Color(red: 0, green: 0, blue: 1), Color(red: 0.9, green: 0.1, blue: 0.1)]
        #expect(ColorModels.nearest(Color(red: 0.85, green: 0.12, blue: 0.1), in: candidates) == 2)
        #expect(ColorModels.nearest(.black, in: []) == nil)
        #expect(ColorModels.isInGamut(ColorFixture.red, of: .sRGB))
        #expect(!ColorModels.isInGamut(Color(displayP3Red: 1, green: 0, blue: 0), of: .sRGB))
        #expect(ColorModels.isInGamut(Color(displayP3Red: 1, green: 0, blue: 0), of: .displayP3))
    }
}
