import struct Foundation.Data
import WTProto
import WTRender

/// The stored `Color` as a value (docs/_includes/color/spot-process.adoc, "Read-time
/// normalizations"; COLOR-002): the doc.v1 message read with its `space` tag into WTRender's
/// tagged `Color` and written back.  The arithmetic is `WTColor.Math`'s (decisions.adoc D-068);
/// this file only applies the read-time rules.
public enum ColorValues {
    /// The colour a stored `Color` reads as:
    ///
    /// * no components case (a malformed write) reads as CMYK 0/0/0/0 -- white;
    /// * `cmyk` ignores the tag;
    /// * `rgb` is Display P3 when tagged so, and sRGB otherwise -- including a `LAB` or `OKLAB`
    ///   tag and a tag this client does not know (a newer space);
    /// * `lab` is OKLab when tagged so, and CIELAB otherwise;
    /// * components are clamped to their space's range.
    ///
    /// Nothing is written back: an unknown tag stays in the message and in the state.
    public static func color(_ stored: Wiretuner_Doc_V1_Color) -> Color {
        switch stored.components {
        case .cmyk(let cmyk)?:
            return Color(cyan: cmyk.c, magenta: cmyk.m, yellow: cmyk.y, black: cmyk.k).clampedToSpace
        case .rgb(let rgb)?:
            let space: Color.Space = stored.space == .displayP3 ? .displayP3 : .sRGB
            return Color(space: space, components: SIMD4(rgb.r, rgb.g, rgb.b, 0)).clampedToSpace
        case .lab(let lab)?:
            let space: Color.Space = stored.space == .oklab ? .oklab : .lab
            return Color(space: space, components: SIMD4(lab.l, lab.a, lab.b, 0)).clampedToSpace
        case nil:
            return Color(cyan: 0, magenta: 0, yellow: 0, black: 0)
        }
    }

    /// `color` as a stored `Color`, space included (the spot ink and alpha are not stored).
    /// Components are clamped to the space's range so the write passes validation.
    public static func stored(_ color: Color) -> Wiretuner_Doc_V1_Color {
        let c = color.clampedToSpace.components
        var stored = Wiretuner_Doc_V1_Color()
        switch color.space {
        case .cmyk:
            var cmyk = Wiretuner_Doc_V1_Cmyk()
            cmyk.c = c.x
            cmyk.m = c.y
            cmyk.y = c.z
            cmyk.k = c.w
            stored.cmyk = cmyk
        case .sRGB, .displayP3:
            var rgb = Wiretuner_Doc_V1_Rgb()
            rgb.r = c.x
            rgb.g = c.y
            rgb.b = c.z
            stored.rgb = rgb
            stored.space = color.space == .displayP3 ? .displayP3 : .srgb
        case .lab, .oklab:
            var lab = Wiretuner_Doc_V1_Lab()
            lab.l = c.x
            lab.a = c.y
            lab.b = c.z
            stored.lab = lab
            stored.space = color.space == .oklab ? .oklab : .lab
        }
        return stored
    }

    /// The encoded `Color` a `NodeRef.cached` holds for a swatch reference (space included).
    public static func cached(_ color: Color) -> Data {
        (try? stored(color).serializedData()) ?? Data()
    }

    /// The colour a `NodeRef.cached` holds, or nil when it is empty or not a `Color`.
    public static func cachedColor(_ bytes: Data) -> Color? {
        guard !bytes.isEmpty, let stored = try? Wiretuner_Doc_V1_Color(serializedBytes: bytes) else { return nil }
        return color(stored)
    }

    /// The Swatches panel's space badge (swatches.adoc, "The panel"): nil for CMYK.
    public static func badge(_ space: Color.Space) -> String? {
        switch space {
        case .sRGB: return "RGB"
        case .displayP3: return "P3"
        case .lab: return "Lab"
        case .oklab: return "OKLab"
        case .cmyk: return nil
        }
    }
}

/// The conversion protocol colour-space commands go through (spot-process.adoc, "Client"): the
/// naive CMYK pair until the CMS epic supplies a profile conversion behind the same protocol.
/// sRGB, Display P3 and the Lab spaces convert by the exact formulas either way.
public protocol ColorConverting: Sendable {
    /// `color` in `space`, unclipped where the formulas allow it.
    func convert(_ color: Color, to space: Color.Space) -> Color
}

/// `Color.converted(to:)`: exact formulas, naive CMYK.
public struct FormulaColorConversion: ColorConverting {
    public init() {}

    public func convert(_ color: Color, to space: Color.Space) -> Color {
        color.converted(to: space)
    }
}
