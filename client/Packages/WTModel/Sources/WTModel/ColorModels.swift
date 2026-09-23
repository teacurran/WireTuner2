import WTRender

/// The picker models and colour utilities of COLOR-002 that are not conversions between stored
/// spaces (those are `WTColor.Math`'s): HLS and HSV over either RGB space, web-safe snapping,
/// perceptual nearest (ΔE in OKLab) and the in-gamut tests the Mixer's indicator reads.
public enum ColorModels {
    /// Hue (degrees, 0..<360), lightness and saturation (0...1) of an RGB colour.
    public struct HLS: Hashable, Sendable {
        public var hue: Double
        public var lightness: Double
        public var saturation: Double

        public init(hue: Double, lightness: Double, saturation: Double) {
            self.hue = hue
            self.lightness = lightness
            self.saturation = saturation
        }
    }

    /// Hue (degrees, 0..<360), saturation and value (0...1) of an RGB colour.
    public struct HSV: Hashable, Sendable {
        public var hue: Double
        public var saturation: Double
        public var value: Double

        public init(hue: Double, saturation: Double, value: Double) {
            self.hue = hue
            self.saturation = saturation
            self.value = value
        }
    }

    /// The RGB space a colour's HLS/HSV is computed in: its own when it is sRGB or Display P3,
    /// otherwise `fallback` (the *Default color space for new colors*).
    public static func rgbSpace(of color: Color, fallback: Color.Space = .displayP3) -> Color.Space {
        color.space.isRGB ? color.space : (fallback.isRGB ? fallback : .sRGB)
    }

    /// The encoded RGB components of `color` in `space` (sRGB or Display P3), clipped to 0...1.
    static func rgb(_ color: Color, in space: Color.Space) -> SIMD3<Double> {
        let converted = color.converted(to: space)
        return WTColor.Math.clipped(SIMD3(converted.components.x, converted.components.y, converted.components.z))
    }

    /// Hue, chroma bounds of an RGB triple.
    private static func hue(_ rgb: SIMD3<Double>) -> (hue: Double, max: Double, min: Double) {
        let maximum = max(rgb.x, rgb.y, rgb.z)
        let minimum = min(rgb.x, rgb.y, rgb.z)
        let delta = maximum - minimum
        guard delta > 0 else { return (0, maximum, minimum) }
        var h: Double
        if maximum == rgb.x {
            h = (rgb.y - rgb.z) / delta
        } else if maximum == rgb.y {
            h = (rgb.z - rgb.x) / delta + 2
        } else {
            h = (rgb.x - rgb.y) / delta + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (h, maximum, minimum)
    }

    /// The HLS of `color` in `space` (its RGB space by default).
    public static func hls(_ color: Color, in space: Color.Space? = nil) -> HLS {
        let (h, maximum, minimum) = hue(rgb(color, in: space ?? rgbSpace(of: color)))
        let l = (maximum + minimum) / 2
        let delta = maximum - minimum
        let s = delta == 0 ? 0 : delta / (1 - abs(2 * l - 1))
        return HLS(hue: h, lightness: l, saturation: min(max(s, 0), 1))
    }

    /// The HSV of `color` in `space` (its RGB space by default).
    public static func hsv(_ color: Color, in space: Color.Space? = nil) -> HSV {
        let (h, maximum, minimum) = hue(rgb(color, in: space ?? rgbSpace(of: color)))
        return HSV(hue: h, saturation: maximum == 0 ? 0 : (maximum - minimum) / maximum, value: maximum)
    }

    /// The RGB triple of a hue with chroma `c`, offset `m`.
    private static func rgb(hue: Double, chroma c: Double, offset m: Double) -> SIMD3<Double> {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let base: SIMD3<Double>
        switch Int(h) {
        case 0: base = SIMD3(c, x, 0)
        case 1: base = SIMD3(x, c, 0)
        case 2: base = SIMD3(0, c, x)
        case 3: base = SIMD3(0, x, c)
        case 4: base = SIMD3(x, 0, c)
        default: base = SIMD3(c, 0, x)
        }
        return base + SIMD3(repeating: m)
    }

    /// The colour of `hls` in `space` (sRGB or Display P3).
    public static func color(_ hls: HLS, in space: Color.Space) -> Color {
        let l = min(max(hls.lightness, 0), 1)
        let c = (1 - abs(2 * l - 1)) * min(max(hls.saturation, 0), 1)
        let rgb = rgb(hue: hls.hue, chroma: c, offset: l - c / 2)
        return Color(space: space.isRGB ? space : .sRGB, components: SIMD4(rgb.x, rgb.y, rgb.z, 0)).clampedToSpace
    }

    /// The colour of `hsv` in `space` (sRGB or Display P3).
    public static func color(_ hsv: HSV, in space: Color.Space) -> Color {
        let v = min(max(hsv.value, 0), 1)
        let c = v * min(max(hsv.saturation, 0), 1)
        let rgb = rgb(hue: hsv.hue, chroma: c, offset: v - c)
        return Color(space: space.isRGB ? space : .sRGB, components: SIMD4(rgb.x, rgb.y, rgb.z, 0)).clampedToSpace
    }

    /// The nearest of the 216 web-safe colours (sRGB, each channel a multiple of 0x33).
    public static func webSafe(_ color: Color) -> Color {
        let rgb = self.rgb(color, in: .sRGB)
        func snap(_ v: Double) -> Double { (v * 5).rounded() / 5 }
        return Color(red: snap(rgb.x), green: snap(rgb.y), blue: snap(rgb.z))
    }

    /// The index of the candidate perceptually nearest `color` (ΔE in OKLab), the first on a
    /// tie; nil for no candidates.
    public static func nearest(_ color: Color, in candidates: [Color]) -> Int? {
        candidates.indices.min { WTColor.Math.deltaEOK(color, candidates[$0]) < WTColor.Math.deltaEOK(color, candidates[$1]) }
    }

    /// Whether `color` is inside `space` (sRGB or Display P3), within the indicator tolerance.
    public static func isInGamut(_ color: Color, of space: Color.Space) -> Bool {
        WTColor.Gamut.contains(color, in: space)
    }
}
