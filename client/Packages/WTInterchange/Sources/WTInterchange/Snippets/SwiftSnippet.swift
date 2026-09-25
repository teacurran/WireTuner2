// The Swift snippet (collaboration/inspect.adoc, "Copying as code"; COLLAB-036): SwiftUI.  A
// rectangle is `Rectangle()` or `RoundedRectangle(cornerRadius:)`, an ellipse `Ellipse()` or
// `Circle()`, any other path a `Path { }` of its segments (relative to its bounds), each with
// `.fill(...)` (a colour, `LinearGradient` or `RadialGradient`) and a stroke overlay, a `frame`
// of the object's size, `.shadow` and `.opacity`; text is `Text("…")` runs joined with `+`, each
// with `.font(.custom(PostScript name, size:))`, `.kerning` and `.foregroundStyle`, then
// `.lineSpacing`.  Colours are `Color(red:green:blue:)` in sRGB, or `Color(.displayP3, …)` when
// the Display P3 notation is chosen; a colour with a swatch name becomes a `static let` in a
// `Color` extension emitted first and used by name.  Lengths are points (SwiftUI's unit).  What
// SwiftUI cannot express is named in a comment holding the object's flattened SVG.

import Foundation
import WTGeometry
import WTRender

/// A Swift snippet: declarations (the `Color` extension, the fallback comment) and the view
/// expression.
public struct SwiftSnippetCode: Hashable, Sendable {
    public var declarations: String
    public var view: String

    /// Both, as the Inspect panel shows and copies them.
    public var text: String {
        (declarations.isEmpty ? "" : declarations + "\n\n") + view + "\n"
    }
}

public enum SwiftSnippet {
    public static func make(_ object: SnippetObject, options: SnippetOptions) -> SwiftSnippetCode {
        let colors = SnippetColors(cmyk: options.cmyk)
        let p3 = options.notation == .displayP3
        var statics: [String] = []
        var names: [Color: String] = [:]
        var used = Set<String>()
        for color in object.colors {
            guard let swatch = object.swatchNames[color] else { continue }
            let name = identifier(swatch)
            guard !used.contains(name) else { continue }
            used.insert(name)
            names[color] = "Color.\(name)"
            statics.append("    static let \(name) = \(literal(color, p3: p3, colors: colors))")
        }
        func value(_ color: Color) -> String { names[color] ?? literal(color, p3: p3, colors: colors) }
        var declarations: [String] = []
        if !statics.isEmpty { declarations.append("extension Color {\n" + statics.joined(separator: "\n") + "\n}") }
        let reasons = object.unexpressible
        if !reasons.isEmpty {
            let svg = SVGSnippet.make(object).replacingOccurrences(of: "*/", with: "* /")
            declarations.append("// SwiftUI cannot express \(CSSSnippet.list(reasons)); the flattened SVG:\n/*\n\(svg.trimmingCharacters(in: .newlines))\n*/")
        }
        let bounds = object.bounds
        var lines: [String]
        switch object.shape {
        case .text:
            lines = text(object, value: value)
        case .other:
            lines = ["Rectangle()", "    .fill(Color.clear)", "    .frame(width: \(number(bounds.width)), height: \(number(bounds.height)))"]
        default:
            let shape = self.shape(object)
            lines = [shape]
            if let paint = object.fill, let fill = self.paint(paint, object: object, value: value) {
                lines.append("    .fill(\(fill)\(object.fills.last?.rule == .evenOdd ? ", style: FillStyle(eoFill: true)" : ""))")
            } else if object.stroke != nil {
                lines.append("    .fill(Color.clear)")
            }
            if let stroke = object.stroke, let paint = self.paint(stroke.paint, object: object, value: value) {
                let style = stroke.style
                var parts = ["lineWidth: \(number(max(style.width, 0)))"]
                if style.cap != .butt { parts.append("lineCap: .\(style.cap)") }
                if style.join != .miter { parts.append("lineJoin: .\(style.join)") }
                if !style.effectiveDash.isEmpty { parts.append("dash: [\(style.effectiveDash.map(number).joined(separator: ", "))]") }
                lines.append("    .overlay(\(shape).stroke(\(paint), style: StrokeStyle(\(parts.joined(separator: ", ")))))")
            }
            lines.append("    .frame(width: \(number(bounds.width)), height: \(number(bounds.height)))")
            for shadow in object.shadows where !shadow.inset {
                lines.append("    .shadow(color: \(value(shadow.color)), radius: \(number(shadow.blur)), x: \(number(shadow.dx)), y: \(number(shadow.dy)))")
            }
        }
        if object.opacity < 1 { lines.append("    .opacity(\(number(max(object.opacity, 0))))") }
        return SwiftSnippetCode(declarations: declarations.joined(separator: "\n\n"), view: lines.joined(separator: "\n"))
    }

    /// The SwiftUI shape of a rectangle, ellipse or path.
    static func shape(_ object: SnippetObject) -> String {
        let bounds = object.bounds
        switch object.shape {
        case .rectangle: return "Rectangle()"
        case .roundedRectangle(let radius): return "RoundedRectangle(cornerRadius: \(number(radius)))"
        case .ellipse: return abs(bounds.width - bounds.height) < 0.005 ? "Circle()" : "Ellipse()"
        default: return path(object)
        }
    }

    /// `Path { path in … }` of the item's path in pasteboard space, moved to its bounds' origin.
    static func path(_ object: SnippetObject) -> String {
        guard case .path(let item) = object.item else { return "Path()" }
        let origin = object.bounds
        let shape = item.path.applying(item.transform.concatenating(.translation(x: -origin.minX, y: -origin.minY)))
        func point(_ p: Point) -> String { "CGPoint(x: \(number(p.x)), y: \(number(p.y)))" }
        var lines = ["Path { path in"]
        for element in shape.elements {
            switch element {
            case .move(let p): lines.append("    path.move(to: \(point(p)))")
            case .line(let p): lines.append("    path.addLine(to: \(point(p)))")
            case .quadCurve(let c, let p): lines.append("    path.addQuadCurve(to: \(point(p)), control: \(point(c)))")
            case .cubicCurve(let c1, let c2, let p): lines.append("    path.addCurve(to: \(point(p)), control1: \(point(c1)), control2: \(point(c2)))")
            case .close: lines.append("    path.closeSubpath()")
            }
        }
        return lines.joined(separator: "\n") + "\n}"
    }

    /// A fill or stroke paint: a colour, or a linear or radial gradient in unit points of the
    /// bounds; nil for what SwiftUI cannot paint.
    static func paint(_ paint: Paint, object: SnippetObject, value: (Color) -> String) -> String? {
        switch paint {
        case .solid(let color):
            return value(color)
        case .gradient(let gradient) where gradient.kind == .linear || gradient.kind == .radial:
            let stops = gradient.sortedStops.map { ".init(color: \(value($0.color)), location: \(number($0.offset)))" }.joined(separator: ", ")
            let bounds = object.bounds
            let transform: AffineTransform
            if case .path(let path) = object.item { transform = path.transform } else { transform = .identity }
            func unit(_ p: Point) -> String {
                let x = bounds.width > 0 ? (p.x - bounds.minX) / bounds.width : 0.5
                let y = bounds.height > 0 ? (p.y - bounds.minY) / bounds.height : 0.5
                return "UnitPoint(x: \(number(x)), y: \(number(y)))"
            }
            if gradient.kind == .radial {
                let center = gradient.axis.map { transform.apply($0.start) } ?? Point(x: bounds.midX, y: bounds.midY)
                let radius = gradient.axis.map { axis -> Double in
                    let a = transform.apply(axis.start), b = transform.apply(axis.end)
                    return ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
                } ?? max(bounds.width, bounds.height) / 2
                return "RadialGradient(stops: [\(stops)], center: \(unit(center)), startRadius: 0, endRadius: \(number(radius)))"
            }
            guard let axis = gradient.axis else { return "LinearGradient(stops: [\(stops)], startPoint: .leading, endPoint: .trailing)" }
            return "LinearGradient(stops: [\(stops)], startPoint: \(unit(transform.apply(axis.start))), endPoint: \(unit(transform.apply(axis.end))))"
        default:
            return nil
        }
    }

    /// The text runs as one `Text`.
    static func text(_ object: SnippetObject, value: (Color) -> String) -> [String] {
        let runs = object.runs.compactMap { run in SnippetObject.facts(run).map { (run, $0) } }
        guard !runs.isEmpty else { return ["Text(\"\")"] }
        let parts = runs.map { run, facts -> String in
            var part = "Text(\(stringLiteral(run.text)))\n        .font(.custom(\(stringLiteral(facts.postScriptName)), size: \(number(facts.size))))"
            if object.tracking != 0 { part += "\n        .kerning(\(number(object.tracking / 1000 * facts.size)))" }
            return part + "\n        .foregroundStyle(\(value(run.color)))"
        }
        var lines = parts.count == 1 ? [parts[0].replacingOccurrences(of: "\n        ", with: "\n    ")] : ["(" + parts.joined(separator: "\n    + ") + ")"]
        if let leading = object.leading, let size = runs.first?.1.size {
            lines.append("    .lineSpacing(\(number(max(leading - size * 1.2, 0))))")
        }
        return lines
    }

    /// A `Color` literal: sRGB components, or Display P3 ones.
    static func literal(_ color: Color, p3: Bool, colors: SnippetColors) -> String {
        let c = p3 ? colors.displayP3(color) : colors.srgb(color)
        let opacity = color.alpha < 1 ? ", opacity: \(number(max(color.alpha, 0)))" : ""
        return "Color(\(p3 ? ".displayP3, " : "")red: \(number(c.x)), green: \(number(c.y)), blue: \(number(c.z))\(opacity))"
    }

    /// A Swift identifier from a swatch name, lower camel case (`Brand red` → `brandRed`).
    static func identifier(_ name: String) -> String {
        let words = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.map { $0.filter(\.isASCII) }.filter { !$0.isEmpty }
        var result = words.enumerated().map { $0.offset == 0 ? $0.element.prefix(1).lowercased() + $0.element.dropFirst() : $0.element.prefix(1).uppercased() + $0.element.dropFirst() }.joined()
        if result.isEmpty || result.first!.isNumber { result = "swatch" + result.prefix(1).uppercased() + result.dropFirst() }
        return result
    }

    /// A Swift string literal.
    static func stringLiteral(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// Up to three decimals.
    static func number(_ value: Double) -> String {
        Numbers.format(value, places: 3)
    }
}
