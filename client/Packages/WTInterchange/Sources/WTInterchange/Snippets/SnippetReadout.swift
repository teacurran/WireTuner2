// The Inspect panel's value sections (inspect.adoc, "The Inspect panel"; COLLAB-037's rest):
// *Colors*, *Stroke*, *Fills*, *Effects*, *Typography* and *Text* read from a snippet object's
// drawing, every value in the panel's notation, unit and scale, so a click can copy it.

import Foundation
import WTGeometry
import WTRender
import struct WTRender.StrokeStyle

/// What the Inspect panel lists for one object.
public struct SnippetReadout: Hashable, Sendable {
    /// One labelled value (a click copies `value`).
    public struct Row: Hashable, Sendable {
        public var label: String
        public var value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    /// A colour: its swatch name when it has one, its value in the notation, and the colour.
    public struct ColorRow: Hashable, Sendable {
        public var name: String?
        public var value: String
        public var color: Color
    }

    /// Every colour the object uses -- each fill (gradient stops included), each stroke, shadow
    /// colours, text colours -- once each, in first-use order.
    public var colors: [ColorRow]
    /// The topmost stroke: width, cap, join, miter limit, dash, arrowheads, colour.
    public var stroke: [Row]
    /// Each fill, bottom to top.
    public var fills: [Row]
    /// Each shown live effect with its settings.
    public var effects: [Row]
    /// Each text run: family, style, size, leading, tracking, colour.
    public var typography: [[Row]]
    /// The text, for copying as plain text; nil when the object draws none.
    public var text: String?

    public init(_ object: SnippetObject, options: SnippetOptions) {
        let formatter = SnippetColors(cmyk: options.cmyk)
        func color(_ value: Color) -> String { formatter.format(value, options.notation) }
        func length(_ points: Double) -> String { options.unit.format(points, scale: options.scale) }
        var strokes: [StrokePaint] = []
        if case .path(let path) = object.item { strokes = path.appearance.strokes.filter { !$0.paint.isNone } }
        // Colours.
        var used: [Color] = []
        func add(_ paint: Paint) {
            switch paint {
            case .solid(let value): used.append(value)
            case .gradient(let gradient): used += gradient.sortedStops.map(\.color)
            default: break
            }
        }
        object.fills.forEach { add($0.paint) }
        strokes.forEach { add($0.paint) }
        used += object.shadows.map(\.color) + object.runs.map(\.color)
        var seen = Set<Color>()
        colors = used.filter { seen.insert($0).inserted }.map { ColorRow(name: object.swatchNames[$0], value: color($0), color: $0) }
        // Stroke.
        if let top = strokes.last {
            let style = top.style
            var rows = [Row("Width", length(max(style.width, 0))), Row("Cap", Self.cap(style)), Row("Join", Self.join(style))]
            if style.join == .miter { rows.append(Row("Miter limit", Numbers.format(style.miterLimit, places: 2))) }
            rows.append(Row("Dash", style.effectiveDash.isEmpty ? "Solid" : style.effectiveDash.map { length($0) }.joined(separator: ", ")))
            if top.startArrowhead != nil || top.endArrowhead != nil {
                rows.append(Row("Arrowheads", "\(top.startArrowhead?.name ?? "None") – \(top.endArrowhead?.name ?? "None")"))
            }
            rows.append(Row("Color", Self.describe(top.paint, color: color)))
            stroke = rows
        } else {
            stroke = []
        }
        // Fills.
        fills = object.fills.enumerated().map { Row("Fill \($0.offset + 1)", Self.describe($0.element.paint, color: color)) }
        // Effects.
        effects = object.effects.map { effect in
            switch effect {
            case .shadow(let shadow):
                let title: String = switch shadow.style {
                case .dropShadow: "Drop shadow"
                case .innerShadow: "Inner shadow"
                case .glow: "Glow"
                case .innerGlow: "Inner glow"
                }
                let details = "offset \(length(shadow.effectiveOffset)) at \(Numbers.format(shadow.angle, places: 1))°, softness "
                    + "\(length(shadow.effectiveSoftness)), \(color(shadow.color)) at \(Numbers.format(shadow.effectiveOpacity, places: 0))%"
                return Row(title, details)
            case .blur(let blur):
                return Row("Blur", "radius \(length(blur.radius))")
            default:
                return Row(Self.title(effect), "")
            }
        }
        // Typography and text.
        typography = object.runs.map { run in
            var rows: [Row] = []
            if let facts = SnippetObject.facts(run) {
                rows += [Row("Font", facts.family), Row("Style", Self.style(weight: facts.weight, italic: facts.italic, postScriptName: facts.postScriptName)),
                         Row("Size", length(facts.size))]
            }
            if let leading = object.leading { rows.append(Row("Leading", length(leading))) }
            rows.append(Row("Tracking", Numbers.format(object.tracking, places: 2)))
            rows.append(Row("Color", color(run.color)))
            return rows
        }
        let text = object.runs.map(\.text).joined()
        self.text = text.isEmpty ? nil : text
    }

    static func cap(_ style: StrokeStyle) -> String {
        switch style.cap {
        case .butt: "Butt"
        case .round: "Round"
        case .square: "Square"
        }
    }

    static func join(_ style: StrokeStyle) -> String {
        switch style.join {
        case .miter: "Miter"
        case .round: "Round"
        case .bevel: "Bevel"
        }
    }

    /// A paint as the panel reads it: a colour; a gradient with its kind and every stop; the kind
    /// of any other paint.
    static func describe(_ paint: Paint, color: (Color) -> String) -> String {
        switch paint {
        case .none: return "None"
        case .solid(let value): return color(value)
        case .gradient(let gradient):
            let stops = gradient.sortedStops.map { "\(color($0.color)) \(Numbers.format($0.offset * 100, places: 1))%" }.joined(separator: ", ")
            return "\(String(describing: gradient.kind).capitalized) gradient: \(stops)"
        case .pattern: return "Pattern"
        case .custom: return "Custom"
        case .textured: return "Textured"
        case .tiled: return "Tiled"
        case .lens: return "Lens"
        }
    }

    /// An effect's name from its case ("Bevel emboss" for `bevelEmboss`).
    static func title(_ effect: LiveEffect) -> String {
        let raw = String(describing: effect).split(separator: "(")[0]
        var words = ""
        for character in raw {
            if character.isUppercase { words += " " + character.lowercased() } else { words.append(character) }
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The style name a person reads: the weight's name, italic after it ("Bold Italic").
    static func style(weight: Int, italic: Bool, postScriptName: String) -> String {
        let names = [100: "Thin", 200: "Extra Light", 300: "Light", 400: "Regular", 500: "Medium", 600: "Semibold", 700: "Bold", 800: "Extra Bold", 900: "Black"]
        let base = names[(weight / 100) * 100] ?? postScriptName
        guard italic else { return base }
        return base == "Regular" ? "Italic" : base + " Italic"
    }
}
