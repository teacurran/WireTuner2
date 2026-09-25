// The CSS snippet (collaboration/inspect.adoc, "Copying as code"; COLLAB-036): custom properties
// for every colour the object uses -- named after the swatch where there is one, `--color-N`
// otherwise -- then one rule for the object: `width`, `height`, `background` (solid,
// `linear-gradient` or `radial-gradient`), `border` and `border-radius` for rectangles, rounded
// rectangles and ellipses, `box-shadow` from shadows and glows, `opacity`, and for text the font,
// size, `line-height`, `letter-spacing` and `color` (one more rule per further run).  Lengths are
// in the chosen unit at the chosen scale, colours in the chosen notation.  What CSS cannot express
// gets a comment saying so and the object's SVG snippet as the background image.

import Foundation
import WTGeometry
import WTRender

public enum CSSSnippet {
    public static func make(_ object: SnippetObject, options: SnippetOptions) -> String {
        let colors = SnippetColors(cmyk: options.cmyk)
        let bounds = object.bounds
        func length(_ points: Double) -> String { options.unit.format(points, scale: options.scale) }
        // Custom properties, in first-use order.
        var properties: [Color: String] = [:]
        var root: [String] = []
        var used = Set<String>()
        for color in object.colors {
            var name = object.swatchNames[color].map(slug) ?? ""
            if name.isEmpty || used.contains(name) { name = "color-\(root.count + 1)" }
            used.insert(name)
            properties[color] = "var(--\(name))"
            root.append("  --\(name): \(colors.format(color, options.notation));")
        }
        func value(_ color: Color) -> String { properties[color]! }
        var declarations: [String] = []
        let reasons = object.unexpressible + (object.shape == .path || object.shape == .other ? ["this shape"] : [])
        if object.shape != .text {
            declarations += ["width: \(length(bounds.width));", "height: \(length(bounds.height));"]
            switch object.fill {
            case .solid(let color):
                declarations.append("background: \(value(color));")
            case .gradient(let gradient) where gradient.kind == .linear || gradient.kind == .radial:
                declarations.append("background: \(self.gradient(gradient, object: object, value: value));")
            default:
                break
            }
            if let stroke = object.stroke, case .solid(let color) = stroke.paint, object.shape != .path, object.shape != .other {
                let style = stroke.style.effectiveDash.isEmpty ? "solid" : "dashed"
                declarations.append("border: \(length(max(stroke.style.width, 0))) \(style) \(value(color));")
            }
            switch object.shape {
            case .roundedRectangle(let radius): declarations.append("border-radius: \(length(radius));")
            case .ellipse: declarations.append("border-radius: 50%;")
            default: break
            }
            let shadows = object.shadows.map { shadow in
                (shadow.inset ? "inset " : "") + [shadow.dx, shadow.dy, shadow.blur].map(length).joined(separator: " ")
                    + (shadow.spread != 0 ? " " + length(shadow.spread) : "") + " " + value(shadow.color)
            }
            if !shadows.isEmpty { declarations.append("box-shadow: \(shadows.joined(separator: ", "));") }
        }
        if object.opacity < 1 { declarations.append("opacity: \(Numbers.format(max(object.opacity, 0), places: 2));") }
        let runs = object.runs
        var extra: [String] = []
        for (index, run) in runs.enumerated() {
            guard let facts = SnippetObject.facts(run) else { continue }
            var lines = ["font-family: \"\(facts.family)\";", "font-weight: \(facts.weight);", "font-style: \(facts.italic ? "italic" : "normal");",
                         "font-size: \(length(facts.size));"]
            if let leading = object.leading { lines.append("line-height: \(length(leading));") }
            if object.tracking != 0 { lines.append("letter-spacing: \(length(object.tracking / 1000 * facts.size));") }
            lines.append("color: \(value(run.color));")
            if index == 0 {
                declarations += lines
            } else {
                extra.append(rule("\(selector(object)) span:nth-of-type(\(index + 1))", lines))
            }
        }
        var comment = ""
        if !reasons.isEmpty {
            let svg = SVGSnippet.make(object)
            comment = "  /* CSS cannot express \(list(reasons)); the flattened SVG is the background. */\n"
            declarations.append("background: url(\"data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())\") center / 100% 100% no-repeat;")
        }
        var blocks: [String] = []
        if !root.isEmpty { blocks.append(":root {\n" + root.joined(separator: "\n") + "\n}") }
        blocks.append("\(selector(object)) {\n" + comment + declarations.map { "  " + $0 }.joined(separator: "\n") + "\n}")
        return (blocks + extra).joined(separator: "\n\n") + "\n"
    }

    /// `linear-gradient(…)` or `radial-gradient(…)` of a fill: the angle (CSS: 0deg up,
    /// clockwise) or centre from the axis in pasteboard space, stops at their offsets.
    static func gradient(_ gradient: Gradient, object: SnippetObject, value: (Color) -> String) -> String {
        let stops = gradient.sortedStops.map { "\(value($0.color)) \(Numbers.format($0.offset * 100, places: 2))%" }.joined(separator: ", ")
        let transform: AffineTransform
        if case .path(let path) = object.item { transform = path.transform } else { transform = .identity }
        let bounds = object.bounds
        switch gradient.kind {
        case .radial:
            let center = gradient.axis.map { transform.apply($0.start) } ?? Point(x: bounds.midX, y: bounds.midY)
            let x = bounds.width > 0 ? (center.x - bounds.minX) / bounds.width * 100 : 50
            let y = bounds.height > 0 ? (center.y - bounds.minY) / bounds.height * 100 : 50
            return "radial-gradient(circle at \(Numbers.format(x, places: 2))% \(Numbers.format(y, places: 2))%, \(stops))"
        default:
            var angle = 90.0
            if let axis = gradient.axis {
                let start = transform.apply(axis.start), end = transform.apply(axis.end)
                angle = atan2(end.x - start.x, -(end.y - start.y)) * 180 / .pi
                if angle < 0 { angle += 360 }
            }
            return "linear-gradient(\(Numbers.format(angle, places: 2))deg, \(stops))"
        }
    }

    /// The rule's selector: the name as a class, `.object` without one.
    static func selector(_ object: SnippetObject) -> String {
        let name = object.name.map(slug) ?? ""
        return "." + (name.isEmpty ? "object" : name)
    }

    /// A CSS identifier from a name: lowercase letters and digits, runs of anything else one
    /// hyphen, never starting with a digit.
    static func slug(_ name: String) -> String {
        var result = ""
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                result.unicodeScalars.append(scalar)
            } else if !result.isEmpty && !result.hasSuffix("-") {
                result += "-"
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        if let first = result.first, first.isNumber { result = "c-" + result }
        return result
    }

    static func rule(_ selector: String, _ lines: [String]) -> String {
        "\(selector) {\n" + lines.map { "  " + $0 }.joined(separator: "\n") + "\n}"
    }

    /// "a, b and c".
    static func list(_ items: [String]) -> String {
        items.count > 1 ? items.dropLast().joined(separator: ", ") + " and " + items.last! : items[0]
    }
}
