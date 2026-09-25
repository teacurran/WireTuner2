// Colour values for snippets and the Inspect panel (collaboration/inspect.adoc, "The Inspect panel",
// *Colors*; COLLAB-036).  sRGB (hex, `rgb()`) and Display P3 come from ColorSync's conversion of
// the colour tagged with its own space (`ColorManagement.taggedCGColor`, through Core Graphics,
// the path print output takes), clipped into the destination; OKLCH is computed exactly from the
// colour's XYZ (so it round-trips to sRGB without loss); CMYK is the document's CMYK profile
// through the `CMYKConverter` export uses, and a colour already in CMYK reports its own inks.

import CoreGraphics
import Foundation
import WTRender

/// Converts and formats colours for snippets.
public struct SnippetColors: Sendable {
    public var cmyk: any CMYKConverter

    public init(cmyk: any CMYKConverter = ProfileCMYKConverter()) {
        self.cmyk = cmyk
    }

    static let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let displayP3Space = CGColorSpace(name: CGColorSpace.displayP3)!

    /// `color` converted by ColorSync into `space` (relative colorimetric), clipped to 0 ... 1.
    static func converted(_ color: Color, into space: CGColorSpace) -> SIMD3<Double> {
        // Every tagged colour converts into sRGB and Display P3.
        let converted = ColorManagement.standard.taggedCGColor(color).converted(to: space, intent: .relativeColorimetric, options: nil)!
        let components = converted.components!.map { min(max(Double($0), 0), 1) }
        return SIMD3(components[0], components[1], components[2])
    }

    /// The colour's sRGB components, 0 ... 1.
    public func srgb(_ color: Color) -> SIMD3<Double> {
        Self.converted(color, into: Self.sRGBSpace)
    }

    /// The colour's Display P3 components, 0 ... 1.
    public func displayP3(_ color: Color) -> SIMD3<Double> {
        Self.converted(color, into: Self.displayP3Space)
    }

    /// OKLCH: lightness 0 ... 1, chroma, hue in degrees.
    public func oklch(_ color: Color) -> SIMD3<Double> {
        WTColor.Math.oklch(fromOKLab: WTColor.Math.oklab(color))
    }

    /// C, M, Y, K in 0 ... 1.
    public func cmykInks(_ color: Color) -> [Double] {
        cmyk.cmyk(color)
    }

    /// `color` in `notation`.
    public func format(_ color: Color, _ notation: SnippetNotation) -> String {
        let alpha = min(max(color.alpha, 0), 1)
        let alphaSuffix = alpha < 1 ? " / \(Self.decimal(alpha * 100, 2))%" : ""
        switch notation {
        case .hex:
            let rgb = srgb(color)
            var hex = "#" + [rgb.x, rgb.y, rgb.z].map { String(format: "%02X", Self.byte($0)) }.joined()
            if alpha < 1 { hex += String(format: "%02X", Self.byte(alpha)) }
            return hex
        case .rgb:
            let rgb = srgb(color)
            return "rgb(\([rgb.x, rgb.y, rgb.z].map { String(Self.byte($0)) }.joined(separator: " "))\(alphaSuffix))"
        case .displayP3:
            let p3 = displayP3(color)
            return "color(display-p3 \([p3.x, p3.y, p3.z].map { Self.decimal($0, 4) }.joined(separator: " "))\(alphaSuffix))"
        case .oklch:
            let lch = oklch(color)
            return "oklch(\(Self.decimal(lch.x * 100, 3))% \(Self.decimal(lch.y, 5)) \(Self.decimal(lch.z, 3))\(alphaSuffix))"
        case .cmyk:
            let inks = cmykInks(color)
            return "device-cmyk(\(inks.map { Self.decimal($0 * 100, 1) + "%" }.joined(separator: " "))\(alphaSuffix))"
        }
    }

    static func byte(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }

    /// `value` with at most `places` decimals, no trailing zeros.
    static func decimal(_ value: Double, _ places: Int) -> String {
        Numbers.format(value, places: places)
    }

    /// Parses `oklch(L% C h)` as written by `format` (the alpha ignored): OKLCH lightness 0 ... 1,
    /// chroma, hue.  Nil for anything else.
    public static func parseOKLCH(_ text: String) -> SIMD3<Double>? {
        guard text.hasPrefix("oklch("), text.hasSuffix(")") else { return nil }
        let parts = text.dropFirst(6).dropLast().split(separator: "/")[0].split(separator: " ")
        guard parts.count == 3, parts[0].hasSuffix("%"), let l = Double(parts[0].dropLast()), let c = Double(parts[1]), let h = Double(parts[2]) else { return nil }
        return SIMD3(l / 100, c, h)
    }
}
