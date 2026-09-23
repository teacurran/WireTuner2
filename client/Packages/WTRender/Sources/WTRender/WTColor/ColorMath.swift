// The WTColor module (docs/_includes/cms/color-management.adoc, "Client"; decisions.adoc
// D-068): colour arithmetic, gamut mapping, the profile registry, the conversion service and
// the renderer's colour pipeline live in `WTRender` under the `WTColor` namespace.  `WTModel`
// (COLOR-002) wraps the proto `Color` over these formulas and adds parsing, naming and tints of
// swatches.
//
// The formulas are CSS Color 4's (sample code of section 18, "Sample code for color
// conversions"): sRGB and Display P3 through linear light and XYZ D65, CIELAB through XYZ D50
// with the Bradford adaptation, OKLab through Ottosson's LMS matrices.  They are exact and
// never go through ColorSync, so they give the same bits on every Mac (D-052).

import CoreGraphics
import Foundation

/// The colour-management kernel's namespace.
public enum WTColor {}

extension WTColor {
    /// Core Graphics colour spaces the render path tags colours with, created once.
    public enum Spaces {
        public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        public static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
        public static let lab = CGColorSpace(name: CGColorSpace.genericLab)!
        public static let extendedLinearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        public static let genericCMYK = CGColorSpace(name: CGColorSpace.genericCMYK)!
        public static let genericGray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
    }

    /// Exact colour-space formulas.
    public enum Math {
        typealias Matrix = (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)

        static func multiply(_ m: Matrix, _ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3((m.0 * v).sum(), (m.1 * v).sum(), (m.2 * v).sum())
        }

        static let linearSRGBToXYZ: Matrix = (
            SIMD3(506_752.0 / 1_228_815, 87_881.0 / 245_763, 12_673.0 / 70_218),
            SIMD3(87_098.0 / 409_605, 175_762.0 / 245_763, 12_673.0 / 175_545),
            SIMD3(7_918.0 / 409_605, 87_881.0 / 737_289, 1_001_167.0 / 1_053_270)
        )
        static let xyzToLinearSRGB: Matrix = (
            SIMD3(12_831.0 / 3_959, -329.0 / 214, -1_974.0 / 3_959),
            SIMD3(-851_781.0 / 878_810, 1_648_619.0 / 878_810, 36_519.0 / 878_810),
            SIMD3(705.0 / 12_673, -2_585.0 / 12_673, 705.0 / 667)
        )
        static let linearP3ToXYZ: Matrix = (
            SIMD3(608_311.0 / 1_250_200, 189_793.0 / 714_400, 198_249.0 / 1_000_160),
            SIMD3(35_783.0 / 156_275, 247_089.0 / 357_200, 198_249.0 / 2_500_400),
            SIMD3(0, 32_229.0 / 714_400, 5_220_557.0 / 5_000_800)
        )
        static let xyzToLinearP3: Matrix = (
            SIMD3(446_124.0 / 178_915, -333_277.0 / 357_830, -72_051.0 / 178_915),
            SIMD3(-14_852.0 / 17_905, 63_121.0 / 35_810, 423.0 / 17_905),
            SIMD3(11_844.0 / 330_415, -50_337.0 / 660_830, 316_169.0 / 330_415)
        )
        /// Bradford chromatic adaptation, D65 → D50 and back.
        static let d65ToD50: Matrix = (
            SIMD3(1.047_929_792_544_996_9, 0.022_946_870_601_609_652, -0.050_192_266_289_205_24),
            SIMD3(0.029_627_808_770_055_99, 0.990_434_426_753_879_9, -0.017_073_799_063_418_826),
            SIMD3(-0.009_243_040_646_204_504, 0.015_055_191_490_298_152, 0.751_874_281_428_137_1)
        )
        static let d50ToD65: Matrix = (
            SIMD3(0.955_473_421_488_075, -0.023_098_454_948_764_71, 0.063_259_243_200_570_72),
            SIMD3(-0.028_369_709_333_863_7, 1.009_995_398_081_304_1, 0.021_041_441_191_917_323),
            SIMD3(0.012_314_014_864_481_998, -0.020_507_649_298_898_964, 1.330_365_926_242_124)
        )
        static let xyzToLMS: Matrix = (
            SIMD3(0.819_022_437_996_703_0, 0.361_906_260_052_890_4, -0.128_873_781_520_987_9),
            SIMD3(0.032_983_653_932_388_5, 0.929_286_861_586_343_4, 0.036_144_666_350_642_4),
            SIMD3(0.048_177_189_359_624_2, 0.264_239_531_752_730_8, 0.633_547_828_469_430_9)
        )
        static let lmsToOKLab: Matrix = (
            SIMD3(0.210_454_268_309_314_0, 0.793_617_774_702_305_4, -0.004_072_043_011_619_3),
            SIMD3(1.977_998_532_431_168_4, -2.428_592_242_048_579_9, 0.450_593_709_617_411_0),
            SIMD3(0.025_904_042_465_547_8, 0.782_771_712_457_529_6, -0.808_675_754_923_077_4)
        )
        static let lmsToXYZ: Matrix = (
            SIMD3(1.226_879_875_845_924_3, -0.557_814_994_460_217_1, 0.281_391_045_665_964_7),
            SIMD3(-0.040_575_745_214_800_8, 1.112_286_803_280_317_0, -0.071_711_058_065_516_4),
            SIMD3(-0.076_372_936_674_660_1, -0.421_493_332_402_243_2, 1.586_924_019_836_781_6)
        )
        static let okLabToLMS: Matrix = (
            SIMD3(1, 0.396_337_777_376_174_9, 0.215_803_757_309_913_6),
            SIMD3(1, -0.105_561_345_815_658_6, -0.063_854_172_825_813_3),
            SIMD3(1, -0.089_484_177_529_811_9, -1.291_485_548_019_409_2)
        )
        /// The D50 white point (CSS Color 4's chromaticity-derived value).
        static let d50White = SIMD3(0.3457 / 0.3585, 1, (1 - 0.3457 - 0.3585) / 0.3585)
        static let kappa = 24_389.0 / 27
        static let epsilon = 216.0 / 24_389

        // MARK: Transfer

        /// The sRGB (and Display P3) transfer curve to linear light, extended to negative values
        /// by symmetry.
        public static func linear(_ c: Double) -> Double {
            let magnitude = abs(c)
            let value = magnitude <= 0.040_45 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
            return c < 0 ? -value : value
        }

        /// Linear light back to the sRGB transfer curve, extended by symmetry.
        public static func encoded(_ c: Double) -> Double {
            let magnitude = abs(c)
            let value = magnitude <= 0.003_130_8 ? magnitude * 12.92 : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
            return c < 0 ? -value : value
        }

        static func linear(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(linear(rgb.x), linear(rgb.y), linear(rgb.z))
        }

        static func encoded(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(encoded(rgb.x), encoded(rgb.y), encoded(rgb.z))
        }

        // MARK: Hubs

        /// CIE XYZ relative to D65 of any colour (CMYK converted naively through sRGB).
        public static func xyzD65(_ color: Color) -> SIMD3<Double> {
            let c = SIMD3(color.components.x, color.components.y, color.components.z)
            switch color.space {
            case .sRGB:
                return multiply(linearSRGBToXYZ, linear(c))
            case .displayP3:
                return multiply(linearP3ToXYZ, linear(c))
            case .lab:
                return multiply(d50ToD65, xyz(fromLab: c))
            case .oklab:
                return xyz(fromOKLab: c)
            case .cmyk:
                return multiply(linearSRGBToXYZ, linear(naiveSRGB(fromCMYK: color.components)))
            }
        }

        /// CIE XYZ relative to D50 (the ICC connection space) of any colour.
        public static func xyzD50(_ color: Color) -> SIMD3<Double> {
            if color.space == .lab {
                return xyz(fromLab: SIMD3(color.components.x, color.components.y, color.components.z))
            }
            return multiply(d65ToD50, xyzD65(color))
        }

        /// The gamma-encoded components of `color` in `space` (sRGB or Display P3), unclipped.
        public static func rgb(_ color: Color, in space: Color.Space) -> SIMD3<Double> {
            precondition(space.isRGB, "rgb(_:in:) takes sRGB or Display P3")
            if color.space == space {
                return SIMD3(color.components.x, color.components.y, color.components.z)
            }
            return encoded(linearRGB(color, in: space))
        }

        /// The linear-light components of `color` in `space` (sRGB or Display P3), unclipped.
        public static func linearRGB(_ color: Color, in space: Color.Space) -> SIMD3<Double> {
            let xyz = xyzD65(color)
            return multiply(space == .displayP3 ? xyzToLinearP3 : xyzToLinearSRGB, xyz)
        }

        /// Each channel clipped to 0...1.
        public static func clipped(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(min(max(rgb.x, 0), 1), min(max(rgb.y, 0), 1), min(max(rgb.z, 0), 1))
        }

        // MARK: CIELAB

        /// CIELAB (D50) of XYZ relative to D50.
        public static func lab(fromXYZD50 xyz: SIMD3<Double>) -> SIMD3<Double> {
            let scaled = xyz / d50White
            func f(_ v: Double) -> Double { v > epsilon ? cbrt(v) : (kappa * v + 16) / 116 }
            let fx = f(scaled.x), fy = f(scaled.y), fz = f(scaled.z)
            return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
        }

        /// XYZ relative to D50 of a CIELAB (D50) value.
        public static func xyz(fromLab lab: SIMD3<Double>) -> SIMD3<Double> {
            let fy = (lab.x + 16) / 116
            let fx = lab.y / 500 + fy
            let fz = fy - lab.z / 200
            let x = pow(fx, 3) > epsilon ? pow(fx, 3) : (116 * fx - 16) / kappa
            let y = lab.x > kappa * epsilon ? pow(fy, 3) : lab.x / kappa
            let z = pow(fz, 3) > epsilon ? pow(fz, 3) : (116 * fz - 16) / kappa
            return SIMD3(x, y, z) * d50White
        }

        // MARK: OKLab

        /// OKLab of any colour.
        public static func oklab(_ color: Color) -> SIMD3<Double> {
            if color.space == .oklab {
                return SIMD3(color.components.x, color.components.y, color.components.z)
            }
            return oklab(fromXYZ: xyzD65(color))
        }

        /// OKLab of XYZ relative to D65.
        public static func oklab(fromXYZ xyz: SIMD3<Double>) -> SIMD3<Double> {
            let lms = multiply(xyzToLMS, xyz)
            return multiply(lmsToOKLab, SIMD3(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z)))
        }

        /// XYZ relative to D65 of an OKLab value.
        public static func xyz(fromOKLab lab: SIMD3<Double>) -> SIMD3<Double> {
            let lms = multiply(okLabToLMS, lab)
            return multiply(lmsToXYZ, lms * lms * lms)
        }

        /// Linear sRGB (unclipped) of an OKLab value: what `Color.cgColor` carries in Extended
        /// Linear sRGB.
        public static func linearSRGB(fromOKLab lab: SIMD3<Double>) -> SIMD3<Double> {
            multiply(xyzToLinearSRGB, xyz(fromOKLab: lab))
        }

        /// OKLCH (lightness, chroma, hue in degrees 0..<360) of an OKLab value; the hue of an
        /// achromatic colour is 0.
        public static func oklch(fromOKLab lab: SIMD3<Double>) -> SIMD3<Double> {
            let chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
            guard chroma > 1e-12 else {
                return SIMD3(lab.x, 0, 0)
            }
            let hue = atan2(lab.z, lab.y) * 180 / .pi
            return SIMD3(lab.x, chroma, hue < 0 ? hue + 360 : hue)
        }

        /// OKLab of an OKLCH value.
        public static func oklabFromOKLCH(_ lch: SIMD3<Double>) -> SIMD3<Double> {
            let radians = lch.z * .pi / 180
            return SIMD3(lch.x, lch.y * cos(radians), lch.y * sin(radians))
        }

        /// ΔE OK: Euclidean distance in OKLab, which OKLab was designed for.
        public static func deltaEOK(_ a: Color, _ b: Color) -> Double {
            let d = oklab(a) - oklab(b)
            return (d * d).sum().squareRoot()
        }

        // MARK: CMYK

        /// The naive sRGB of CMYK inks: `R = (1 − C)(1 − K)` and so on.
        public static func naiveSRGB(fromCMYK cmyk: SIMD4<Double>) -> SIMD3<Double> {
            SIMD3((1 - cmyk.x) * (1 - cmyk.w), (1 - cmyk.y) * (1 - cmyk.w), (1 - cmyk.z) * (1 - cmyk.w))
        }

        /// The naive inverse with K = 1 − max(R, G, B).
        public static func naiveCMYK(fromSRGB rgb: SIMD3<Double>) -> SIMD4<Double> {
            // 1 − K is the brightest channel itself, so no ink comes out a rounding error below 0.
            let scale = max(rgb.x, rgb.y, rgb.z)
            let k = 1 - scale
            guard scale > 0 else {
                return SIMD4(0, 0, 0, 1)
            }
            return SIMD4((scale - rgb.x) / scale, (scale - rgb.y) / scale, (scale - rgb.z) / scale, k)
        }
    }
}
