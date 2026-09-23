// The display list's colour value (docs/_includes/color/spot-process.adoc, "Color spaces";
// decisions.adoc D-052): every colour carries the space it is stored in -- sRGB, Display P3,
// CIELAB (D50), OKLab or CMYK -- and is never rewritten into another space by the renderer.
// Renderers convert it at draw time (`ColorManagement`); PDF output carries it tagged.

import CoreGraphics

/// A colour in its own space with straight (non-premultiplied) alpha.
///
/// `components` hold the space's channels: red, green, blue in 0...1 for sRGB and Display P3;
/// L (0...100), a, b for CIELAB D50; L (0...1), a, b for OKLab; cyan, magenta, yellow, black in
/// 0...1 for CMYK.  Unused trailing components are 0, so equal colours compare equal.
public struct Color: Hashable, Sendable {
    /// The space a colour's components are in (`ColorSpace` in `common.proto`, with CMYK as
    /// the `cmyk` components case).
    public enum Space: UInt8, Hashable, Sendable, CaseIterable {
        case sRGB
        case displayP3
        /// CIE L*a*b* relative to D50 (the ICC connection space).
        case lab
        case oklab
        case cmyk

        /// How many of `components` the space uses.
        public var componentCount: Int { self == .cmyk ? 4 : 3 }

        /// Whether the components are gamma-encoded RGB.
        public var isRGB: Bool { self == .sRGB || self == .displayP3 }
    }

    public var space: Space
    public var components: SIMD4<Double>
    public var alpha: Double
    /// The spot ink the colour stands for (spot-process.adoc; PRINT-007): `components` are the
    /// ink's alternate as composite output shows it, `spot` names the ink and its tint so a
    /// separation puts the colour on the ink's own plate.  Nil for a process or RGB colour.
    public var spot: SpotInk?

    /// A colour of `space` from its components; channels past the space's count are dropped.
    public init(space: Space, components: SIMD4<Double>, alpha: Double = 1, spot: SpotInk? = nil) {
        self.space = space
        self.components = space == .cmyk ? components : SIMD4(components.x, components.y, components.z, 0)
        self.alpha = alpha
        self.spot = spot
    }

    /// An sRGB colour (the space every colour had before D-052).
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.init(space: .sRGB, components: SIMD4(red, green, blue, 0), alpha: alpha)
    }

    /// A neutral sRGB grey.
    public init(white: Double, alpha: Double = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    /// A Display P3 colour.
    public init(displayP3Red red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.init(space: .displayP3, components: SIMD4(red, green, blue, 0), alpha: alpha)
    }

    /// A CIELAB (D50) colour.
    public init(labL l: Double, a: Double, b: Double, alpha: Double = 1) {
        self.init(space: .lab, components: SIMD4(l, a, b, 0), alpha: alpha)
    }

    /// An OKLab colour.
    public init(oklabL l: Double, a: Double, b: Double, alpha: Double = 1) {
        self.init(space: .oklab, components: SIMD4(l, a, b, 0), alpha: alpha)
    }

    /// An OKLab colour from its polar form: lightness 0...1, chroma, hue in degrees.
    public init(oklchL l: Double, chroma: Double, hue: Double, alpha: Double = 1) {
        let lab = WTColor.Math.oklabFromOKLCH(SIMD3(l, chroma, hue))
        self.init(oklabL: lab.x, a: lab.y, b: lab.z, alpha: alpha)
    }

    /// A process (CMYK) colour, inks in 0...1.
    public init(cyan: Double, magenta: Double, yellow: Double, black: Double, alpha: Double = 1) {
        self.init(space: .cmyk, components: SIMD4(cyan, magenta, yellow, black), alpha: alpha)
    }

    public static let black = Color(white: 0)
    public static let white = Color(white: 1)
    public static let clear = Color(white: 0, alpha: 0)

    /// The colour with its alpha multiplied by `factor`.
    public func withAlpha(multipliedBy factor: Double) -> Color {
        Color(space: space, components: components, alpha: alpha * factor, spot: spot)
    }

    /// The colour as the spot ink `ink` at its full strength: `self` is the ink's alternate.
    public func asSpot(_ ink: SpotInk) -> Color {
        var result = self
        result.spot = ink
        return result
    }

    // MARK: sRGB view

    /// The colour's sRGB components: its own for an sRGB colour (unclamped, as stored), and for
    /// any other space the exact conversion clipped per channel to 0...1 -- what an sRGB
    /// surface shows.  CMYK converts naively here (`R = (1-C)(1-K)`); rendering converts it
    /// through the Working CMYK profile (`ColorManagement`).
    public var srgb: SIMD3<Double> {
        if space == .sRGB {
            return SIMD3(components.x, components.y, components.z)
        }
        return WTColor.Math.clipped(WTColor.Math.rgb(self, in: .sRGB))
    }

    /// The sRGB red channel (`srgb`).  Setting it stores the colour as sRGB.
    public var red: Double {
        get { srgb.x }
        set { self = Color(red: newValue, green: green, blue: blue, alpha: alpha) }
    }

    /// The sRGB green channel (`srgb`).  Setting it stores the colour as sRGB.
    public var green: Double {
        get { srgb.y }
        set { self = Color(red: red, green: newValue, blue: blue, alpha: alpha) }
    }

    /// The sRGB blue channel (`srgb`).  Setting it stores the colour as sRGB.
    public var blue: Double {
        get { srgb.z }
        set { self = Color(red: red, green: green, blue: newValue, alpha: alpha) }
    }

    // MARK: Conversions

    /// The colour converted into `target` by the exact formulas (WTColor.Math): unclipped
    /// between the RGB and Lab spaces, naive for CMYK.  Gamut mapping is `WTColor.Gamut`.
    public func converted(to target: Space) -> Color {
        guard target != space else {
            return self
        }
        switch target {
        case .sRGB, .displayP3:
            let rgb = WTColor.Math.rgb(self, in: target)
            return Color(space: target, components: SIMD4(rgb.x, rgb.y, rgb.z, 0), alpha: alpha)
        case .lab:
            let lab = WTColor.Math.lab(fromXYZD50: WTColor.Math.xyzD50(self))
            return Color(labL: lab.x, a: lab.y, b: lab.z, alpha: alpha)
        case .oklab:
            let lab = WTColor.Math.oklab(self)
            return Color(oklabL: lab.x, a: lab.y, b: lab.z, alpha: alpha)
        case .cmyk:
            let cmyk = WTColor.Math.naiveCMYK(fromSRGB: WTColor.Math.clipped(WTColor.Math.rgb(self, in: .sRGB)))
            return Color(space: .cmyk, components: cmyk, alpha: alpha)
        }
    }

    /// The colour mixed `amount` (0...1, clamped) of the way from white to itself in its own
    /// space, as a tint is (docs/_includes/color/tints.adoc): CMYK scales its inks toward zero,
    /// sRGB and Display P3 interpolate from (1, 1, 1), CIELAB from (100, 0, 0), OKLab from
    /// (1, 0, 0).  Alpha is kept.
    public func tinted(_ amount: Double) -> Color {
        let t = min(max(amount.isFinite ? amount : 1, 0), 1)
        let white: SIMD4<Double>
        switch space {
        case .sRGB, .displayP3: white = SIMD4(1, 1, 1, 0)
        case .lab: white = SIMD4(100, 0, 0, 0)
        case .oklab: white = SIMD4(1, 0, 0, 0)
        case .cmyk: white = .zero
        }
        return Color(space: space, components: white + (components - white) * t, alpha: alpha, spot: spot.map { $0.tinted(t) })
    }

    /// The components clamped to the space's range, as the read-time rules clamp an
    /// out-of-range stored value for display (spot-process.adoc, "Read-time normalizations").
    public var clampedToSpace: Color {
        var result = self
        switch space {
        case .sRGB, .displayP3, .cmyk:
            result.components = components.clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 1))
        case .lab:
            result.components = SIMD4(min(max(components.x, 0), 100), min(max(components.y, -128), 128), min(max(components.z, -128), 128), 0)
        case .oklab:
            result.components = SIMD4(min(max(components.x, 0), 1), min(max(components.y, -0.5), 0.5), min(max(components.z, -0.5), 0.5), 0)
        }
        result.alpha = min(max(alpha, 0), 1)
        return result
    }

    // MARK: Core Graphics

    /// The colour as a `CGColor` in its own space (COLOR-024's tagged render path): sRGB and
    /// Display P3 in their spaces, CIELAB in Generic Lab (D50), OKLab converted by matrix to
    /// linear sRGB in Extended Linear sRGB (whose range keeps a colour outside sRGB), CMYK in
    /// the bundled Default CMYK space.  `ColorManagement.cgColor` substitutes Working CMYK.
    public var cgColor: CGColor {
        switch space {
        case .sRGB:
            return CGColor(srgbRed: components.x, green: components.y, blue: components.z, alpha: alpha)
        case .displayP3:
            return CGColor(colorSpace: WTColor.Spaces.displayP3, components: [components.x, components.y, components.z, alpha])!
        case .lab:
            return CGColor(colorSpace: WTColor.Spaces.lab, components: [components.x, components.y, components.z, alpha])!
        case .oklab:
            let linear = WTColor.Math.linearSRGB(fromOKLab: SIMD3(components.x, components.y, components.z))
            return CGColor(colorSpace: WTColor.Spaces.extendedLinearSRGB, components: [linear.x, linear.y, linear.z, alpha])!
        case .cmyk:
            return CGColor(colorSpace: WTColor.Spaces.genericCMYK, components: [components.x, components.y, components.z, components.w, alpha])!
        }
    }
}
