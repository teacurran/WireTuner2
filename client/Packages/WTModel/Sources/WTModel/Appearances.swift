import WTCRDT
import WTProto
import WTRender

/// Resolves a stored attribute stack into WTRender's `Appearance` (attribute-stack.adoc,
/// "Rendering"): fills and strokes bottom first, hidden elements skipped.  Only basic fills and
/// basic strokes with inline colours (or a swatch's cached colour) resolve for now; every other
/// kind is skipped until its epic lands (deviation recorded on client.adoc, "Rendering").
public enum Appearances {
    /// The built-in defaults: a 1 pt black basic stroke and no fill
    /// (default-attributes.adoc, "an empty default stack reads as the built-in defaults").
    public static var standard: Wiretuner_Doc_V1_AppearanceProps {
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.strokes = [basicStroke(red: 0, green: 0, blue: 0, width: 1)]
        return appearance
    }

    /// A basic stroke of an inline sRGB colour.
    public static func basicStroke(red: Double, green: Double, blue: Double, width: Double) -> Wiretuner_Doc_V1_Stroke {
        var stroke = Wiretuner_Doc_V1_Stroke()
        stroke.settings.kind = .basic
        stroke.settings.basic.color = inline(red: red, green: green, blue: blue)
        stroke.settings.basic.width = width
        return stroke
    }

    /// A basic fill of an inline sRGB colour.
    public static func basicFill(red: Double, green: Double, blue: Double) -> Wiretuner_Doc_V1_Fill {
        var fill = Wiretuner_Doc_V1_Fill()
        fill.settings.kind = .basic
        fill.settings.basic.color = inline(red: red, green: green, blue: blue)
        return fill
    }

    static func inline(red: Double, green: Double, blue: Double) -> Wiretuner_Doc_V1_ColorRef {
        var color = Wiretuner_Doc_V1_ColorRef()
        color.inline.rgb.r = red
        color.inline.rgb.g = green
        color.inline.rgb.b = blue
        return color
    }

    /// The display appearance of `props`.  `evenOdd` sets every fill's rule; `paintsFill` false
    /// drops the fills (an open path that does not show its fill).
    public static func resolve(_ props: Wiretuner_Doc_V1_AppearanceProps, evenOdd: Bool = false, paintsFill: Bool = true) -> Appearance {
        var items: [AppearanceItem] = []
        for fill in props.fills where paintsFill && !fill.hidden && fill.settings.kind == .basic {
            items.append(.fill(FillPaint(paint: paint(fill.settings.basic.color), rule: evenOdd ? .evenOdd : .nonZero,
                                         overprint: fill.settings.basic.overprint)))
        }
        for stroke in props.strokes where !stroke.hidden && stroke.settings.kind == .basic {
            let basic = stroke.settings.basic
            let style = StrokeStyle(
                width: basic.width.isFinite ? max(basic.width, 0) : 1, cap: cap(basic.cap), join: join(basic.join),
                miterLimit: basic.miterLimit >= 1 ? basic.miterLimit : 10, dash: basic.dash.lengths
            )
            items.append(.stroke(StrokePaint(paint: paint(basic.color), style: style, overprint: basic.overprint)))
        }
        return Appearance(items)
    }

    /// The paint a colour reference resolves to.
    public static func paint(_ ref: Wiretuner_Doc_V1_ColorRef) -> Paint {
        switch ref.ref {
        case .none?: return .none
        case .inline(let color)?: return .solid(self.color(color))
        case .swatch(let swatch)?:
            if let cached = try? Wiretuner_Doc_V1_Color(serializedBytes: swatch.cached) {
                return .solid(color(cached))
            }
            return .solid(.black)
        case .tint(let tint)?:
            return .solid(color(tint))
        case nil:
            return .solid(.black)
        }
    }

    static func color(_ tint: Wiretuner_Doc_V1_InlineTint) -> Color {
        let base = (try? Wiretuner_Doc_V1_Color(serializedBytes: tint.base.cached)).map(color) ?? .black
        let amount = min(max(tint.percent / 100, 0), 1)
        func mix(_ value: Double) -> Double { 1 - (1 - value) * amount }
        return Color(red: mix(base.red), green: mix(base.green), blue: mix(base.blue))
    }

    /// A stored colour in sRGB for display (the colour-management epic owns real conversion):
    /// RGB as is, CMYK by the naive complement, Lab by its lightness.
    public static func color(_ color: Wiretuner_Doc_V1_Color) -> Color {
        switch color.components {
        case .rgb(let rgb)?:
            return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        case .cmyk(let cmyk)?:
            return Color(red: (1 - cmyk.c) * (1 - cmyk.k), green: (1 - cmyk.m) * (1 - cmyk.k), blue: (1 - cmyk.y) * (1 - cmyk.k))
        case .lab(let lab)?:
            return Color(white: min(max(lab.l / 100, 0), 1))
        case nil:
            return .black
        }
    }

    static func cap(_ cap: Wiretuner_Doc_V1_LineCap) -> LineCap {
        switch cap {
        case .round: .round
        case .square: .square
        default: .butt
        }
    }

    static func join(_ join: Wiretuner_Doc_V1_LineJoin) -> LineJoin {
        switch join {
        case .round: .round
        case .bevel: .bevel
        default: .miter
        }
    }
}
