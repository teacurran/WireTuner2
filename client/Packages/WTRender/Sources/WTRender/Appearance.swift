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

/// One stroke of an attribute stack, resolved: its kind, paint, geometry parameters and
/// arrowheads.  For Basic strokes (and Pattern strokes, which are Basic strokes painted
/// `.pattern`) `style` and the arrowheads define the outline; a Custom stroke reads its width
/// from `style`; a Brush stroke falls back to `paint` and `style` (the cached Basic stroke).
public struct StrokePaint: Hashable, Sendable {
    public var paint: Paint
    public var style: StrokeStyle
    /// Drawn at the path's start point, pointing back past it.  Ignored on a closed start.
    public var startArrowhead: Arrowhead?
    /// Drawn at the path's end point, pointing along the path.  Ignored on a closed end.
    public var endArrowhead: Arrowhead?
    public var overprint: Bool
    public var kind: StrokeKind

    public init(
        paint: Paint,
        style: StrokeStyle = StrokeStyle(),
        startArrowhead: Arrowhead? = nil,
        endArrowhead: Arrowhead? = nil,
        overprint: Bool = false,
        kind: StrokeKind = .basic
    ) {
        self.paint = paint
        self.style = style
        self.startArrowhead = startArrowhead
        self.endArrowhead = endArrowhead
        self.overprint = overprint
        self.kind = kind
    }

    /// The kind that actually draws: a brush stroke whose brush is gone or has no live symbol
    /// draws as its cached Basic stroke.
    var effectiveKind: StrokeKind {
        if case .brush(let brush) = kind, brush.liveBrush == nil {
            return .basic
        }
        return kind
    }

    /// Whether the stroke is outlined at `style.width` along the path (Basic, Pattern, Custom
    /// and a brush's fallback), which is what the outline hit tolerance measures.
    var hasWidthOutline: Bool {
        switch effectiveKind {
        case .basic, .custom: return true
        case .brush, .calligraphic: return false
        }
    }

    /// Whether either end carries an arrowhead (hairlines carry none: heads scale with width;
    /// only Basic strokes carry heads).
    public var hasArrowheads: Bool {
        effectiveKind == .basic && !style.isHairline && (startArrowhead != nil || endArrowhead != nil)
    }

    /// How far, in local units, the stroke's paint can reach beyond the path's control bounds,
    /// arrowheads included.  Brush strokes are bounded by their copies instead (see
    /// `Appearance.paintedBounds(of:)`).
    var outset: Double {
        switch effectiveKind {
        case .basic:
            var result = style.outset
            if hasArrowheads {
                for head in [startArrowhead, endArrowhead].compactMap({ $0 }) {
                    result = max(result, head.extent * style.width)
                }
            }
            return result
        case .custom:
            // Tiles span the width across the path; bent round corners they can reach a
            // little further, which the miter-style outset covers.
            return style.outset
        case .calligraphic(let nib):
            return CalligraphicSweep.nibPolygon(nib, tolerance: 0.1).map { $0.distance(to: .zero) }.max() ?? 0
        case .brush:
            return 0
        }
    }
}

/// One element of a resolved attribute stack.
public enum AppearanceItem: Hashable, Sendable {
    case fill(FillPaint)
    case stroke(StrokePaint)
}

/// One element of an object's stack as WTModel reads it: the element and its visibility.
public struct StackElement: Hashable, Sendable {
    public var item: AppearanceItem
    public var hidden: Bool

    public init(_ item: AppearanceItem, hidden: Bool = false) {
        self.item = item
        self.hidden = hidden
    }
}

/// A resolved attribute stack: every visible fill and stroke in ascending position, bottom
/// first, and the live effects (FX epic) in ascending position, which is the order they apply
/// in.  An effect's `.element` target indexes `items`.
public struct Appearance: Hashable, Sendable {
    public var items: [AppearanceItem]
    /// The live effects, first applied first.
    public var effects: [EffectElement]
    /// The resolution raster effects render at (the object's override or the document's).
    public var raster: RasterSettings

    public init(_ items: [AppearanceItem] = [], effects: [EffectElement] = [], raster: RasterSettings = RasterSettings()) {
        self.items = items
        self.effects = effects
        self.raster = raster
    }

    /// The display-list stack of `stack` (already in ascending position): hidden elements are
    /// skipped here, at build time, so they cost nothing to paint or hit test.  `effects`
    /// target `stack` indices; an effect attached to a hidden element is skipped with it, and
    /// hidden effects are dropped.
    public init(stack: [StackElement], effects: [EffectElement] = [], raster: RasterSettings = RasterSettings()) {
        var remap: [Int: Int] = [:]
        var items: [AppearanceItem] = []
        for (index, element) in stack.enumerated() where !element.hidden {
            remap[index] = items.count
            items.append(element.item)
        }
        let kept = effects.compactMap { element -> EffectElement? in
            guard !element.hidden else { return nil }
            switch element.target {
            case .object:
                return element
            case .element(let index):
                guard let mapped = remap[index] else { return nil }
                var result = element
                result.target = .element(mapped)
                return result
            }
        }
        self.init(items, effects: kept, raster: raster)
    }

    /// The effects that draw: visible, of a known kind, attached to an element that exists.
    var liveEffects: [EffectElement] {
        effects.filter { element in
            guard !element.hidden, element.effect != .unsupported else { return false }
            if case .element(let index) = element.target {
                return items.indices.contains(index)
            }
            return true
        }
    }

    /// Whether any effect draws.
    public var hasEffects: Bool { !liveEffects.isEmpty }

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

    /// Whether any fill paints the interior (a *None* fill does not; lens and transparent
    /// Custom fills do, everywhere inside the path).
    public var paintsInterior: Bool {
        fills.contains { !$0.paint.isNone }
    }

    /// The widest width-outlined stroke that paints, whose half width sets the outline's hit
    /// tolerance.  Brush and Calligraphic strokes hit on their own geometry instead.
    public var widestStroke: StrokePaint? {
        strokes.filter { !$0.paint.isNone && $0.hasWidthOutline }.max { $0.style.width < $1.style.width }
    }

    /// Whether any fill is a lens: the item repaints when anything beneath it changes.
    public var hasLens: Bool {
        fills.contains { $0.paint.isLens }
    }

    /// The largest outset of any stroke, 0 for fills only.
    var outset: Double {
        strokes.map(\.outset).max() ?? 0
    }

    /// A conservative local-space bound on everything the stack paints on `path`: the control
    /// bounds grown by the strokes' outset, joined with every brush stroke's copies.
    func paintedBounds(of path: DisplayPath) -> Rect? {
        guard let control = path.controlBounds else {
            return nil
        }
        var result = control.expanded(by: outset)
        for stroke in strokes {
            if case .brush(let brush) = stroke.effectiveKind,
               let copies = BrushLayout.cached(path: path, stroke: brush).bounds {
                result = result.union(copies)
            }
        }
        return result
    }
}

/// A path painted by its attribute stack.
public struct PathItem: Hashable, Sendable {
    public var path: DisplayPath
    public var appearance: Appearance
    /// Local → pasteboard.
    public var transform: AffineTransform
    /// Vector effects inherited from enclosing groups (FX-006), applied after the item's own.
    var inheritedEffects: [FramedEffect] = []

    public init(path: DisplayPath, appearance: Appearance, transform: AffineTransform = .identity) {
        self.path = path
        self.appearance = appearance
        self.transform = transform
    }

    /// Whether any live effect changes how the item draws.
    public var hasEffects: Bool {
        appearance.hasEffects || !inheritedEffects.isEmpty
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

/// A named dash (`DashPattern`): on, off, on, off... lengths in points.
public struct DashPreset: Hashable, Sendable {
    public var name: String
    public var lengths: [Double]

    public init(name: String, lengths: [Double]) {
        self.name = name
        self.lengths = lengths
    }

    /// The built-in dashes, in pop-up order after *No dash*.  Application resources: a stroke
    /// copies the chosen lengths into its own `dash`.
    public static let builtIns: [DashPreset] = [
        DashPreset(name: "Dotted", lengths: [1, 2]),
        DashPreset(name: "Short", lengths: [2, 2]),
        DashPreset(name: "Medium", lengths: [4, 2]),
        DashPreset(name: "Long", lengths: [8, 4]),
        DashPreset(name: "Dash Dot", lengths: [8, 3, 1, 3]),
        DashPreset(name: "Dash Dot Dot", lengths: [8, 3, 1, 3, 1, 3]),
        DashPreset(name: "Sparse", lengths: [2, 6]),
    ]
}
