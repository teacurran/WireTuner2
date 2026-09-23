import CoreGraphics
import Foundation
import Testing
@testable import WTRender

/// D-052 / COLOR-006 utilities: the space-tagged `Color`, its exact conversions, tints and the
/// tagged `CGColor`s.
@Suite struct ColorSpaceTests {
    func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tolerance: Double) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.z - b.z) <= tolerance
    }

    @Test func legacyInitializersAreSRGBAndCompareAsBefore() {
        let color = Color(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
        #expect(color.space == .sRGB)
        #expect(color.red == 0.2 && color.green == 0.4 && color.blue == 0.6 && color.alpha == 0.5)
        #expect(Color(white: 0.5) == Color(red: 0.5, green: 0.5, blue: 0.5))
        #expect(Color(red: 1.2, green: -0.1, blue: 0).red == 1.2, "sRGB components read back as stored")
        #expect(Color(space: .sRGB, components: SIMD4(1, 0, 0, 9)).components.w == 0, "unused channel dropped")
        #expect(Color(cyan: 0.1, magenta: 0.2, yellow: 0.3, black: 0.4).components.w == 0.4)
        #expect(Color.Space.cmyk.componentCount == 4 && Color.Space.lab.componentCount == 3)
        #expect(Color.Space.displayP3.isRGB && !Color.Space.oklab.isRGB)
        #expect(Color(displayP3Red: 1, green: 0, blue: 0) != Color(red: 1, green: 0, blue: 0), "the tag is part of the value")
    }

    @Test func settersStoreSRGB() {
        var color = Color(displayP3Red: 0.5, green: 0.5, blue: 0.5)
        color.red = 1
        #expect(color.space == .sRGB && color.red == 1)
        color.green = 0.25
        color.blue = 0.75
        #expect(color == Color(red: 1, green: 0.25, blue: 0.75))
    }

    @Test func srgbViewClipsOtherSpaces() {
        let p3Red = Color(displayP3Red: 1, green: 0, blue: 0)
        #expect(p3Red.srgb == SIMD3(1, 0, 0), "P3 red clipped per channel")
        #expect(near(Color(cyan: 1, magenta: 0, yellow: 0, black: 0).srgb, SIMD3(0, 1, 1), 1e-12), "naive CMYK")
        #expect(p3Red.withAlpha(multipliedBy: 0.5) == Color(displayP3Red: 1, green: 0, blue: 0, alpha: 0.5))
    }

    @Test func referenceConversions() {
        // CSS Color 4 / WPT values.
        let red = Color(red: 1, green: 0, blue: 0)
        #expect(near(WTColor.Math.oklab(red), SIMD3(0.627_955_4, 0.224_863_0, 0.125_846_3), 1e-5))
        let lab = red.converted(to: .lab)
        #expect(near(SIMD3(lab.components.x, lab.components.y, lab.components.z), SIMD3(54.2905, 80.8049, 69.8910), 2e-3))
        let p3 = Color(displayP3Red: 1, green: 0, blue: 0).converted(to: .sRGB)
        #expect(near(SIMD3(p3.components.x, p3.components.y, p3.components.z), SIMD3(1.093_08, -0.226_84, -0.150_08), 1e-4))
        let white = Color.white.converted(to: .lab)
        #expect(near(SIMD3(white.components.x, white.components.y, white.components.z), SIMD3(100, 0, 0), 1e-4))
        let dark = Color(red: 0.001, green: 0.001, blue: 0.001).converted(to: .lab)
        #expect(dark.components.x < 0.1 && dark.components.x > 0, "the linear segment of L*")
        let back = Color(labL: 0.05, a: 0, b: 0).converted(to: .sRGB)
        #expect(back.components.x > 0 && back.components.x < 0.01)
    }

    @Test func roundTripsAreExact() {
        for rgb in [SIMD3(0.2, 0.5, 0.9), SIMD3(1, 0, 0), SIMD3(0.01, 0.002, 0.8), SIMD3(0, 0, 0)] {
            let color = Color(red: rgb.x, green: rgb.y, blue: rgb.z)
            for space in [Color.Space.displayP3, .lab, .oklab] {
                let back = color.converted(to: space).converted(to: .sRGB)
                #expect(near(SIMD3(back.components.x, back.components.y, back.components.z), rgb, 1.0 / 65_536), "\(space)")
            }
        }
        let cmyk = Color(red: 0.2, green: 0.4, blue: 0.6).converted(to: .cmyk)
        #expect(near(cmyk.converted(to: .sRGB).srgb, SIMD3(0.2, 0.4, 0.6), 1e-12))
        #expect(Color.black.converted(to: .cmyk).components == SIMD4(0, 0, 0, 1))
        #expect(Color(labL: 50, a: 10, b: 10).converted(to: .lab) == Color(labL: 50, a: 10, b: 10))
        let viaCMYK = Color(cyan: 0, magenta: 0, yellow: 0, black: 0.5).converted(to: .lab)
        #expect(abs(viaCMYK.components.y) < 1e-6)
        #expect(WTColor.Math.xyzD50(Color(labL: 50, a: 0, b: 0)).y > 0.18)
    }

    @Test func oklchPolarForm() {
        let color = Color(oklchL: 0.7, chroma: 0.1, hue: 90)
        #expect(abs(color.components.y) < 1e-12 && abs(color.components.z - 0.1) < 1e-12)
        let lch = WTColor.Math.oklch(fromOKLab: SIMD3(0.5, 0.1, -0.1))
        #expect(abs(lch.z - 315) < 1e-9 && abs(lch.y - 0.1 * 2.0.squareRoot()) < 1e-12)
        #expect(WTColor.Math.oklch(fromOKLab: SIMD3(0.5, 0, 0)) == SIMD3(0.5, 0, 0))
        #expect(WTColor.Math.oklch(fromOKLab: SIMD3(0.5, 0.1, 0.1)).z == 45)
        #expect(WTColor.Math.deltaEOK(Color.white, Color.black) > 0.99)
    }

    @Test func tintsMixTowardWhiteInTheirOwnSpace() {
        #expect(Color(red: 0, green: 0.5, blue: 1).tinted(0.5) == Color(red: 0.5, green: 0.75, blue: 1))
        #expect(Color(displayP3Red: 0, green: 0, blue: 0).tinted(0.25).space == .displayP3)
        #expect(Color(labL: 0, a: 40, b: -40).tinted(0.5) == Color(labL: 50, a: 20, b: -20))
        #expect(Color(oklabL: 0, a: 0.2, b: 0).tinted(0.5) == Color(oklabL: 0.5, a: 0.1, b: 0))
        #expect(Color(cyan: 1, magenta: 0.5, yellow: 0, black: 0.2, alpha: 0.5).tinted(0.5) == Color(cyan: 0.5, magenta: 0.25, yellow: 0, black: 0.1, alpha: 0.5))
        #expect(Color(red: 0, green: 0, blue: 0).tinted(2) == .black, "clamped")
        #expect(Color(red: 0, green: 0, blue: 0).tinted(.nan) == .black, "a non-finite tint is the base")
    }

    @Test func clampingToTheSpaceRange() {
        #expect(Color(red: 2, green: -1, blue: 0.5, alpha: 3).clampedToSpace == Color(red: 1, green: 0, blue: 0.5))
        #expect(Color(labL: 120, a: -200, b: 200).clampedToSpace == Color(labL: 100, a: -128, b: 128))
        #expect(Color(oklabL: 40, a: 1, b: -1).clampedToSpace == Color(oklabL: 1, a: 0.5, b: -0.5))
    }

    @Test func taggedCGColorsCarryTheirSpace() {
        #expect(Color(red: 1, green: 0, blue: 0).cgColor.colorSpace?.name == CGColorSpace.sRGB)
        #expect(Color(displayP3Red: 1, green: 0, blue: 0).cgColor.colorSpace?.name == CGColorSpace.displayP3)
        #expect(Color(labL: 50, a: 0, b: 0).cgColor.colorSpace?.model == .lab)
        #expect(Color(cyan: 1, magenta: 0, yellow: 0, black: 0).cgColor.colorSpace?.model == .cmyk)
        let wide = Color(oklchL: 0.7, chroma: 0.3, hue: 30).cgColor
        #expect(wide.colorSpace?.name == CGColorSpace.extendedLinearSRGB)
        #expect(wide.components!.prefix(3).contains { $0 < 0 || $0 > 1 }, "an OKLab colour outside sRGB is not clipped")
        #expect(Color.clear.cg.alpha == 0)
    }
}

/// COLOR-024: CSS Color 4 gamut mapping, the indicator and the display query.
@Suite struct GamutTests {
    /// color.js's CSS-algorithm vectors (test/gamut.js), percentages of sRGB.
    static let p3PrimariesToSRGB: [(SIMD3<Double>, SIMD3<Double>)] = [
        (SIMD3(1, 0, 0), SIMD3(100, 4.457, 4.5932)),
        (SIMD3(0, 1, 0), SIMD3(0, 98.576, 15.974)),
        (SIMD3(0, 0, 1), SIMD3(0, 0, 100)),
        (SIMD3(1, 1, 0), SIMD3(99.623, 99.901, 0)),
        (SIMD3(0, 1, 1), SIMD3(0, 99.645, 98.471)),
        (SIMD3(1, 0, 1), SIMD3(100, 16.736, 98.264)),
        (SIMD3(1, 1, 1), SIMD3(100, 100, 100)),
        (SIMD3(2, 0, 1), SIMD3(100, 100, 100)),
        (SIMD3(0, 0, 0), SIMD3(0, 0, 0)),
        (SIMD3(-1, 0, 0), SIMD3(0, 0, 0)),
    ]

    @Test func matchesTheReferenceVectorsWithinOneStep() {
        for (p3, expected) in Self.p3PrimariesToSRGB {
            let mapped = WTColor.Gamut.map(Color(displayP3Red: p3.x, green: p3.y, blue: p3.z, alpha: 0.5), into: .sRGB)
            #expect(mapped.space == .sRGB && mapped.alpha == 0.5)
            let got = SIMD3(mapped.components.x, mapped.components.y, mapped.components.z) * 100
            #expect(abs(got.x - expected.x) < 100.0 / 255 && abs(got.y - expected.y) < 100.0 / 255 && abs(got.z - expected.z) < 100.0 / 255, "\(p3) → \(got), expected \(expected)")
        }
    }

    @Test func inGamutColoursAreUnchangedAndMappingIsDeterministic() {
        let inside = Color(red: 0.3, green: 0.6, blue: 0.2)
        #expect(WTColor.Gamut.map(inside, into: .sRGB) == inside)
        let wide = Color(oklchL: 0.7, chroma: 0.4, hue: 30)
        let once = WTColor.Gamut.map(wide, into: .displayP3)
        #expect(once == WTColor.Gamut.map(wide, into: .displayP3))
        #expect(once.space == .displayP3 && WTColor.Gamut.contains(once, in: .displayP3))
        #expect(WTColor.Gamut.contains(WTColor.Gamut.map(Color(labL: 60, a: 90, b: -90), into: .sRGB), in: .sRGB))
        // A colour just outside, which clipping alone fixes within the JND.
        let barely = Color(red: 1.004, green: 0.5, blue: 0.5)
        #expect(WTColor.Gamut.map(barely, into: .sRGB).components.x == 1)
    }

    @Test func theIndicatorNamesTheNarrowestGamut() {
        #expect(WTColor.Gamut.indicator(for: Color(red: 0xE6 / 255.0, green: 0x39 / 255.0, blue: 0x46 / 255.0)) == .sRGB)
        #expect(WTColor.Gamut.indicator(for: Color(displayP3Red: 1, green: 0, blue: 0)) == .displayP3)
        #expect(WTColor.Gamut.indicator(for: Color(oklchL: 0.7, chroma: 0.4, hue: 30)) == .outOfGamut)
        #expect(WTColor.Gamut.contains(Color(cyan: 1, magenta: 1, yellow: 0, black: 0), in: .sRGB))
    }

    @Test func theDisplayQueryFollowsTheDisplayProfile() {
        let p3Red = Color(displayP3Red: 1, green: 0, blue: 0)
        #expect(WTColor.DisplayGamut.sRGB.clips(p3Red))
        #expect(WTColor.DisplayGamut.displayP3.canShow(p3Red))
        #expect(!WTColor.DisplayGamut.displayP3.canShow(Color(oklchL: 0.7, chroma: 0.4, hue: 30)))
        // A display profile other than the two formula spaces goes through ColorSync.
        let adobe = WTColor.DisplayGamut(colorSpace: CGColorSpace(name: CGColorSpace.adobeRGB1998)!)
        #expect(adobe.canShow(Color(red: 0.5, green: 0.5, blue: 0.5)))
        #expect(!adobe.canShow(Color(oklchL: 0.9, chroma: 0.35, hue: 150)))
        #expect(adobe.colorSpace.name == CGColorSpace.adobeRGB1998)
        // Components outside 0...1 in the display's encoding are not shown.
        #expect(!WTColor.DisplayGamut(colorSpace: WTColor.Spaces.lab).canShow(Color(red: 0.5, green: 0.5, blue: 0.5)))
    }
}

/// The trace's colours reach the document tagged.
@Suite struct TracedColorTests {
    @Test func cmykTracesCarryACMYKColour() {
        let rgb = Trace.TracedPath(contours: [], fill: Color(red: 1, green: 0, blue: 0))
        #expect(rgb.color == Color(red: 1, green: 0, blue: 0))
        #expect(Trace.TracedPath(contours: [], stroke: .black).color == .black)
        let cmyk = Trace.TracedPath(contours: [], fill: Color(red: 0, green: 1, blue: 1), cmyk: SIMD4(1, 0, 0, 0))
        #expect(cmyk.color == Color(cyan: 1, magenta: 0, yellow: 0, black: 0))
        #expect(Trace.TracedPath(contours: [], cmyk: SIMD4(0, 0, 0, 1)).color?.alpha == 1)
    }
}
