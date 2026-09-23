// The attribute stack in the display list (REND-002; docs/_includes/appearance/attribute-stack.adoc,
// "Rendering"): an object's fills and strokes share one position space, so the resolved stack
// is one ordered list painted bottom first, and a fill can sit above a stroke.  Hidden
// elements are skipped when the list is built, so everything here paints.

import WTGeometry

/// One fill of an attribute stack, resolved.
public struct FillPaint: Hashable, Sendable {
    public var paint: Paint
    public var rule: FillRule
    /// Printed on top of the inks beneath rather than knocking them out; shown on screen only
    /// with the renderer's overprint preview on.
    public var overprint: Bool

    public init(paint: Paint, rule: FillRule = .nonZero, overprint: Bool = false) {
        self.paint = paint
        self.rule = rule
        self.overprint = overprint
    }
}

/// One Basic stroke of an attribute stack, resolved: paint, geometry parameters, arrowheads.
public struct StrokePaint: Hashable, Sendable {
    public var paint: Paint
    public var style: StrokeStyle
    /// Drawn at the path's start point, pointing back past it.  Ignored on a closed start.
    public var startArrowhead: Arrowhead?
    /// Drawn at the path's end point, pointing along the path.  Ignored on a closed end.
    public var endArrowhead: Arrowhead?
    public var overprint: Bool

    public init(
        paint: Paint,
        style: StrokeStyle = StrokeStyle(),
        startArrowhead: Arrowhead? = nil,
        endArrowhead: Arrowhead? = nil,
        overprint: Bool = false
    ) {
        self.paint = paint
        self.style = style
        self.startArrowhead = startArrowhead
        self.endArrowhead = endArrowhead
        self.overprint = overprint
    }

    /// Whether either end carries an arrowhead (hairlines carry none: heads scale with width).
    public var hasArrowheads: Bool {
        !style.isHairline && (startArrowhead != nil || endArrowhead != nil)
    }

    /// How far, in local units, the stroke's paint can reach beyond the path's control bounds,
    /// arrowheads included.
    var outset: Double {
        var result = style.outset
        if !style.isHairline {
            for head in [startArrowhead, endArrowhead].compactMap({ $0 }) {
                result = max(result, head.extent * style.width)
            }
        }
        return result
    }
}

/// One element of a resolved attribute stack.
public enum AppearanceItem: Hashable, Sendable {
    case fill(FillPaint)
    case stroke(StrokePaint)
}

/// A resolved attribute stack: every visible fill and stroke in ascending position, bottom
/// first.  Effects join with the FX epic.
public struct Appearance: Hashable, Sendable {
    public var items: [AppearanceItem]

    public init(_ items: [AppearanceItem] = []) {
        self.items = items
    }

    /// The default for a newly drawn object: one fill with one stroke above it.
    public static func fillAndStroke(fill: Color, stroke: Color, width: Double = 1) -> Appearance {
        Appearance([
            .fill(FillPaint(paint: .solid(fill))),
            .stroke(StrokePaint(paint: .solid(stroke), style: StrokeStyle(width: width))),
        ])
    }

    public var fills: [FillPaint] {
        items.compactMap { item in
            if case .fill(let fill) = item { return fill }
            return nil
        }
    }

    public var strokes: [StrokePaint] {
        items.compactMap { item in
            if case .stroke(let stroke) = item { return stroke }
            return nil
        }
    }

    /// Whether any fill paints the interior (a *None* fill does not).
    public var paintsInterior: Bool {
        fills.contains { !$0.paint.isNone }
    }

    /// The widest stroke that paints, whose half width sets the outline's hit tolerance.
    public var widestStroke: StrokePaint? {
        strokes.filter { !$0.paint.isNone }.max { $0.style.width < $1.style.width }
    }

    /// The largest outset of any stroke, 0 for fills only.
    var outset: Double {
        strokes.map(\.outset).max() ?? 0
    }
}

/// A path painted by its attribute stack.
public struct PathItem: Hashable, Sendable {
    public var path: DisplayPath
    public var appearance: Appearance
    /// Local → pasteboard.
    public var transform: AffineTransform

    public init(path: DisplayPath, appearance: Appearance, transform: AffineTransform = .identity) {
        self.path = path
        self.appearance = appearance
        self.transform = transform
    }
}

/// An arrowhead shape, stored inline in the stroke that uses it
/// (docs/_includes/appearance/stroke-attributes.adoc, `Arrowhead`).
///
/// The outline is in arrowhead units -- one unit is the stroke width -- with its origin at the
/// path's endpoint and +x pointing beyond the end of the path.  The renderer maps it through
/// scale(width) · rotation(tangent) · translation(endpoint).
public struct Arrowhead: Hashable, Sendable {
    public var name: String
    public var shape: DisplayPath
    /// Filled with the stroke colour; otherwise stroked at one unit (the stroke width).
    public var filled: Bool
    /// How far, in units, the path is shortened under the head.
    public var pathTrim: Double

    public init(name: String, shape: DisplayPath, filled: Bool = true, pathTrim: Double = 0) {
        self.name = name
        self.shape = shape
        self.filled = filled
        self.pathTrim = max(pathTrim, 0)
    }

    /// The farthest the head reaches from the endpoint, in units, stroke included.
    public var extent: Double {
        let points = shape.elements.flatMap(\.points)
        let reach = points.map { $0.distance(to: .zero) }.max() ?? 0
        return filled ? reach : reach + 0.5
    }

    /// A solid triangle whose tip passes one unit beyond the endpoint.
    public static let triangle = Arrowhead(
        name: "Triangle",
        shape: DisplayPath(polygon: [Point(x: 1, y: 0), Point(x: -2, y: 1.5), Point(x: -2, y: -1.5)]),
        pathTrim: 1.5
    )

    /// An open chevron stroked at the stroke's width.
    public static let open = Arrowhead(
        name: "Open",
        shape: DisplayPath(polygon: [Point(x: -2, y: -1.75), Point(x: 0.5, y: 0), Point(x: -2, y: 1.75)], closed: false),
        filled: false
    )

    /// A solid disc centred on the endpoint.
    public static let circle = Arrowhead(
        name: "Circle",
        shape: DisplayPath(ellipseIn: Rect(x: -1.25, y: -1.25, width: 2.5, height: 2.5))
    )

    /// A solid square centred on the endpoint.
    public static let square = Arrowhead(
        name: "Square",
        shape: DisplayPath(rect: Rect(x: -1.1, y: -1.1, width: 2.2, height: 2.2))
    )

    /// A bar across the endpoint.
    public static let bar = Arrowhead(
        name: "Bar",
        shape: DisplayPath(rect: Rect(x: -0.3, y: -2, width: 0.6, height: 4))
    )

    /// The built-in presets, in pop-up order.
    public static let builtIns: [Arrowhead] = [triangle, open, circle, square, bar]
}
