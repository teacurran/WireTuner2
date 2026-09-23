// Color arithmetic the writers need: the gradient ramp exactly as WTRender computes it (OKLab
// interpolation with premultiplied alpha, CSS Color 4 style), luminance for masks, the in-gamut
// test, Display P3 components and sRGB fallbacks through WTColor's gamut mapping (COLOR-024), and
// hex serialization.  WTRender keeps its ramp internal, so the ramp
// is restated here and held to WTRender's pixels by the PDF and SVG comparison tests.

import Foundation
import WTRender

enum ColorMath {
    // MARK: sRGB transfer

    static func linear(_ c: Double) -> Double {
        let magnitude = abs(c)
        let value = magnitude <= 0.040_45 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
        return c < 0 ? -value : value
    }

    static func encoded(_ c: Double) -> Double {
        let magnitude = abs(c)
        let value = magnitude <= 0.003_130_8 ? 12.92 * magnitude : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
        return c < 0 ? -value : value
    }

    // MARK: OKLab

    static func oklab(_ red: Double, _ green: Double, _ blue: Double) -> SIMD3<Double> {
        let r = linear(red), g = linear(green), b = linear(blue)
        let l = cbrt(0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b)
        let m = cbrt(0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b)
        let s = cbrt(0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b)
        return SIMD3(
            0.210_454_255_3 * l + 0.793_617_785_0 * m - 0.004_072_046_8 * s,
            1.977_998_495_1 * l - 2.428_592_205_0 * m + 0.450_593_709_9 * s,
            0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766_0 * s
        )
    }

    /// The sRGB colour of an OKLab value, clipped to the gamut as WTRender's ramp clips it.
    static func srgb(fromOKLab lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = pow(lab.x + 0.396_337_777_4 * lab.y + 0.215_803_757_3 * lab.z, 3)
        let m = pow(lab.x - 0.105_561_345_8 * lab.y - 0.063_854_172_8 * lab.z, 3)
        let s = pow(lab.x - 0.089_484_177_5 * lab.y - 1.291_485_548_0 * lab.z, 3)
        let r = 4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s
        let g = -1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s
        let b = -0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701_0 * s
        func clip(_ v: Double) -> Double { min(max(encoded(min(max(v, 0), 1)), 0), 1) }
        return SIMD3(clip(r), clip(g), clip(b))
    }

    // MARK: Wide gamut

    /// Whether a colour lies outside sRGB (WTColor's in-gamut test: any Display P3, Lab or
    /// OKLab colour beyond sRGB, or an extended sRGB value).  CMYK is always inside.
    static func isWide(_ color: Color) -> Bool {
        !WTColor.Gamut.contains(color, in: .sRGB)
    }

    /// The colour's Display P3 components, gamut-mapped into Display P3.
    static func displayP3(_ color: Color) -> SIMD3<Double> {
        let mapped = WTColor.Gamut.map(color, into: .displayP3).components
        return SIMD3(mapped.x, mapped.y, mapped.z)
    }

    /// The colour as sRGB for a format or setting that holds nothing wider: gamut-mapped by
    /// COLOR-024's CSS Color 4 mapping (CMYK through the Working CMYK profile), alpha clamped.
    static func sRGBFallback(_ color: Color) -> Color {
        let mapped = color.space == .cmyk ? ColorManagement.standard.sampledColor(color) : WTColor.Gamut.map(color, into: .sRGB)
        return Color(red: mapped.red, green: mapped.green, blue: mapped.blue, alpha: min(max(color.alpha, 0), 1))
    }

    // MARK: Luminance

    /// Rec. 709 luminance of the sRGB components (WTRender's gradient-mask value).
    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        min(max(0.2126 * red + 0.7152 * green + 0.0722 * blue, 0), 1)
    }

    // MARK: Hex

    static func byte(_ component: Double) -> Int {
        Int((min(max(component, 0), 1) * 255).rounded())
    }

    /// `#rrggbb` of the colour's sRGB fallback.
    static func hex(_ color: Color) -> String {
        let rgb = sRGBFallback(color)
        return String(format: "#%02x%02x%02x", byte(rgb.red), byte(rgb.green), byte(rgb.blue))
    }
}

/// A compiled gradient ramp: WTRender's `GradientRamp` restated (1024 samples, OKLab between
/// stops with premultiplied alpha, exact colours at and outside the stops).
struct Ramp: Sendable {
    static let resolution = 1024
    let samples: [SIMD4<Double>]

    init(stops sorted: [Gradient.Stop]) {
        let labs = sorted.map { stop -> SIMD4<Double> in
            let lab = ColorMath.oklab(stop.color.red, stop.color.green, stop.color.blue)
            let alpha = min(max(stop.color.alpha, 0), 1)
            return SIMD4(lab.x * alpha, lab.y * alpha, lab.z * alpha, alpha)
        }
        func exact(_ stop: Gradient.Stop) -> SIMD4<Double> {
            SIMD4(stop.color.red, stop.color.green, stop.color.blue, stop.color.alpha)
        }
        samples = (0..<Ramp.resolution).map { index in
            let u = Double(index) / Double(Ramp.resolution - 1)
            guard let upper = sorted.firstIndex(where: { $0.offset >= u }) else {
                return exact(sorted[sorted.count - 1])
            }
            if upper == 0 || sorted[upper].offset == u {
                return exact(sorted[upper])
            }
            let lower = upper - 1
            let span = sorted[upper].offset - sorted[lower].offset
            let t = (u - sorted[lower].offset) / span
            let mixed = labs[lower] + (labs[upper] - labs[lower]) * t
            guard mixed.w > 1e-9 else {
                return SIMD4(0, 0, 0, 0)
            }
            let rgb = ColorMath.srgb(fromOKLab: SIMD3(mixed.x, mixed.y, mixed.z) / mixed.w)
            return SIMD4(rgb.x, rgb.y, rgb.z, mixed.w)
        }
    }

    /// The straight-alpha colour at ramp position `u`, linearly between table entries.
    func color(at u: Double) -> SIMD4<Double> {
        let position = min(max(u.isFinite ? u : 0, 0), 1) * Double(Ramp.resolution - 1)
        let index = Int(position)
        guard index < Ramp.resolution - 1 else {
            return samples[Ramp.resolution - 1]
        }
        let t = position - Double(index)
        return samples[index] + (samples[index + 1] - samples[index]) * t
    }
}
