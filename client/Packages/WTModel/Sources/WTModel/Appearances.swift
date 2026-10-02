import struct Foundation.Data
import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Resolves a stored attribute stack into WTRender's `Appearance` (attribute-stack.adoc,
/// "Rendering"): every fill and stroke in stack order, bottom first, hidden elements skipped, and
/// every kind lowered to its display-list paint with the read-time normalizations of the stroke
/// and fill pages.  Brush strokes draw their brush node's symbols while a scene build resolves the
/// document's brushes (`SceneContext`), else their cached Basic stroke; effects are lowered by
/// `EffectLowering`.
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

    /// An inline sRGB colour reference.
    public static func inline(red: Double, green: Double, blue: Double) -> Wiretuner_Doc_V1_ColorRef {
        var color = Wiretuner_Doc_V1_ColorRef()
        color.inline.rgb.r = red
        color.inline.rgb.g = green
        color.inline.rgb.b = blue
        return color
    }

    /// The display appearance of `props`.  `order` is the stack order (`AppearanceEditing.stack`);
    /// without it fills paint below strokes.  `evenOdd` sets every fill's rule; `paintsFill`
    /// false drops the fills (an open path that does not show its fill).  Effects (FX-002) come
    /// in stack order with their targets -- an effect attached to a fill or stroke that is not
    /// drawn is skipped with it -- and `corners` resolves a Corners effect's point ids.
    public static func resolve(_ props: Wiretuner_Doc_V1_AppearanceProps, order: [AppearanceRow]? = nil, evenOdd: Bool = false,
                               paintsFill: Bool = true, corners: (OpID) -> CornerPoint? = { _ in nil }) -> Appearance {
        let fillElement = { (fill: Wiretuner_Doc_V1_Fill) in StackElement(.fill(Self.fill(fill.settings, evenOdd: evenOdd)), hidden: fill.hidden) }
        let strokeElement = { (stroke: Wiretuner_Doc_V1_Stroke) in StackElement(.stroke(Self.stroke(stroke.settings)), hidden: stroke.hidden) }
        guard let order else {
            let fills = paintsFill ? props.fills : []
            let rows = fills.map { OpID(element: $0.id) ?? .zero } + props.strokes.map { OpID(element: $0.id) ?? .zero }
            return Appearance(stack: fills.map(fillElement) + props.strokes.map(strokeElement),
                              effects: EffectLowering.elements(effects: props.effects, rows: rows, corners: corners),
                              raster: EffectLowering.raster(props))
        }
        let fills = Dictionary(props.fills.compactMap { fill in OpID(element: fill.id).map { ($0, fill) } }) { first, _ in first }
        let strokes = Dictionary(props.strokes.compactMap { stroke in OpID(element: stroke.id).map { ($0, stroke) } }) { first, _ in first }
        let effects = Dictionary(props.effects.compactMap { effect in OpID(element: effect.id).map { ($0, effect) } }) { first, _ in first }
        var rows: [OpID] = []
        var ordered: [Wiretuner_Doc_V1_Effect] = []
        let stack = order.compactMap { row -> StackElement? in
            let element: StackElement?
            switch row.list {
            case .fills: element = paintsFill ? fills[row.element].map(fillElement) : nil
            case .strokes: element = strokes[row.element].map(strokeElement)
            case .effects:
                if let effect = effects[row.element] { ordered.append(effect) }
                element = nil
            }
            if element != nil { rows.append(row.element) }
            return element
        }
        return Appearance(stack: stack, effects: EffectLowering.elements(effects: ordered, rows: rows, corners: corners),
                          raster: EffectLowering.raster(props))
    }

    // MARK: Fills

    public static func fill(_ settings: Wiretuner_Doc_V1_FillSettings, evenOdd: Bool) -> FillPaint {
        let rule: FillRule = evenOdd ? .evenOdd : .nonZero
        switch settings.kind {
        case .gradient:
            // No live stops reads as a Basic fill (gradients.adoc, "Read-time normalizations").
            guard !GradientReading.ramp(settings.gradient).isEmpty else { return basic(settings.basic.color, rule: rule, overprint: settings.gradient.overprint) }
            return FillPaint(paint: .gradient(gradient(settings.gradient)), rule: rule, overprint: settings.gradient.overprint)
        case .lens:
            let lens = settings.lens
            guard let type = lensType(lens.type) else { return basic(lens.color, rule: rule, overprint: false) }
            let snapshot = lens.snapshot && !lens.snapshotContents.nodes.isEmpty ? SubtreeRendering.items(lens.snapshotContents) : nil
            return FillPaint(paint: .lens(LensFill(
                type: type, color: color(lens.color) ?? .black, amount: lens.amount, magnification: max(lens.magnification, 1),
                centerpoint: lens.hasCenterpoint ? Point(x: lens.centerpoint.x, y: lens.centerpoint.y) : nil,
                objectsOnly: lens.objectsOnly, snapshot: snapshot
            )), rule: rule)
        case .custom:
            let custom = settings.custom
            guard let pattern = customFillPattern(custom.pattern) else { return basic(custom.color, rule: rule, overprint: custom.overprint) }
            return FillPaint(paint: .custom(CustomFill(
                pattern: pattern, color: color(custom.color) ?? .black, color2: color(custom.color2) ?? .white, width: custom.width,
                height: custom.height, radius: custom.radius, side: custom.side, spacing: custom.spacing, angle: custom.angle,
                angle2: custom.angle2, whiteness: min(max(custom.whiteness, 0), 100), count: Int(custom.count), seed: custom.seed
            )), rule: rule, overprint: custom.overprint)
        case .pattern:
            let pattern = settings.pattern
            return FillPaint(paint: patternPaint(pattern.color, pattern.bitmap), rule: rule, overprint: pattern.overprint)
        case .textured:
            let textured = settings.textured
            guard let texture = texture(textured.texture) else { return basic(textured.color, rule: rule, overprint: textured.overprint) }
            guard let value = color(textured.color) else { return FillPaint(paint: .none, rule: rule) }
            return FillPaint(paint: .textured(TexturedFill(texture: texture, color: value)), rule: rule, overprint: textured.overprint)
        case .tiled:
            let tiled = settings.tiled
            return FillPaint(paint: .tiled(TiledFill(
                tile: SubtreeRendering.items(tiled.tile), angle: tiled.angle, scaleX: tiled.scaleX, scaleY: tiled.scaleY,
                offset: Point(x: tiled.offset.x, y: tiled.offset.y)
            )), rule: rule, overprint: tiled.overprint)
        default:
            return basic(settings.basic.color, rule: rule, overprint: settings.basic.overprint)
        }
    }

    static func basic(_ ref: Wiretuner_Doc_V1_ColorRef, rule: FillRule, overprint: Bool) -> FillPaint {
        FillPaint(paint: paint(ref), rule: rule, overprint: overprint)
    }

    static func patternPaint(_ ref: Wiretuner_Doc_V1_ColorRef, _ bitmap: Wiretuner_Doc_V1_PatternBitmap) -> Paint {
        guard let value = color(ref) else { return .none }
        return .pattern(PatternPaint(bitmap: PatternBitmap(rows: Array(bitmap.rows)), color: value))
    }

    static func gradient(_ gradient: Wiretuner_Doc_V1_GradientFill) -> Gradient {
        let kinds: [Wiretuner_Doc_V1_GradientType: Gradient.Kind] = [
            .logarithmic: .logarithmic, .radial: .radial, .rectangle: .rectangle, .contour: .contour, .cone: .cone,
        ]
        let behaviors: [Wiretuner_Doc_V1_GradientBehavior: Gradient.Behavior] = [.repeat: .repeat, .reflect: .reflect, .autoSize: .autoSize]
        let axis = gradient.hasAxis ? Gradient.Axis(
            start: Point(x: gradient.axis.start.x, y: gradient.axis.start.y), end: Point(x: gradient.axis.end.x, y: gradient.axis.end.y),
            end2: gradient.axis.hasEnd2 ? Point(x: gradient.axis.end2.x, y: gradient.axis.end2.y) : nil
        ) : nil
        let stops = GradientReading.ramp(gradient).map { Gradient.Stop(offset: $0.offset, color: color($0.color) ?? .clear) }
        return Gradient(kind: kinds[gradient.type] ?? .linear, behavior: behaviors[gradient.behavior] ?? .normal,
                        repeatCount: Int(max(gradient.repeatCount, 1)), axis: axis, stops: stops)
    }

    static func lensType(_ type: Wiretuner_Doc_V1_LensType) -> LensType? {
        let types: [Wiretuner_Doc_V1_LensType: LensType] = [
            .unspecified: .transparency, .transparency: .transparency, .magnify: .magnify, .invert: .invert, .lighten: .lighten,
            .darken: .darken, .monochrome: .monochrome,
        ]
        return types[type]
    }

    static func customFillPattern(_ pattern: Wiretuner_Doc_V1_CustomFillPattern) -> CustomFillPattern? {
        let patterns: [Wiretuner_Doc_V1_CustomFillPattern: CustomFillPattern] = [
            .blackWhiteNoise: .blackWhiteNoise, .bricks: .bricks, .circles: .circles, .hatch: .hatch, .noise: .noise,
            .randomGrass: .randomGrass, .randomLeaves: .randomLeaves, .squares: .squares, .tigerTeeth: .tigerTeeth, .topNoise: .topNoise,
        ]
        return patterns[pattern]
    }

    static func texture(_ texture: Wiretuner_Doc_V1_Texture) -> Texture? {
        let textures: [Wiretuner_Doc_V1_Texture: Texture] = [
            .burlap: .burlap, .denim: .denim, .gravel: .gravel, .marble: .marble, .mesh: .mesh, .oak: .oak, .sand: .sand, .stucco: .stucco,
        ]
        return textures[texture]
    }

    // MARK: Strokes

    /// Widths clamp to 0 ... 16,164 pt.
    static func width(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 16_164) : 1
    }

    public static func stroke(_ settings: Wiretuner_Doc_V1_StrokeSettings) -> StrokePaint {
        switch settings.kind {
        case .brush:
            let brush = settings.brush
            let cached = (try? Wiretuner_Doc_V1_BasicStroke(serializedBytes: brush.brush.cached)).flatMap { $0 == Wiretuner_Doc_V1_BasicStroke() ? nil : $0 }
            let fallback = BrushStroke(brush: Brushes.definition(brush.brush), widthPercent: brush.widthPercent, seed: brush.seed)
            var paint = basic(cached ?? { var basic = Wiretuner_Doc_V1_BasicStroke(); basic.color = brush.color; basic.width = 1; return basic }())
            paint.kind = .brush(fallback)
            return paint
        case .calligraphic:
            let calligraphic = settings.calligraphic
            let nib = CalligraphicNib(width: width(calligraphic.width), height: width(calligraphic.height),
                                      angle: calligraphic.angle.isFinite ? calligraphic.angle : 0, shape: nibShape(calligraphic.nib))
            return StrokePaint(paint: paint(calligraphic.color), style: StrokeStyle(width: max(nib.width, nib.height)), kind: .calligraphic(nib))
        case .custom:
            let custom = settings.custom
            guard let pattern = customStrokePattern(custom.pattern) else {
                var basic = Wiretuner_Doc_V1_BasicStroke()
                basic.color = custom.color
                basic.width = custom.width
                return self.basic(basic)
            }
            return StrokePaint(paint: paint(custom.color), style: StrokeStyle(width: width(custom.width)),
                               kind: .custom(CustomStroke(pattern: pattern, length: max(custom.length, 0), spacing: max(custom.spacing, 0))))
        case .pattern:
            let pattern = settings.pattern
            return StrokePaint(paint: patternPaint(pattern.color, pattern.bitmap), style: StrokeStyle(width: width(pattern.width)))
        default:
            return basic(settings.basic)
        }
    }

    static func basic(_ basic: Wiretuner_Doc_V1_BasicStroke) -> StrokePaint {
        let miter = basic.miterLimit == 0 || !basic.miterLimit.isFinite ? 4 : min(max(basic.miterLimit, 1), 57)
        let style = StrokeStyle(width: width(basic.width), cap: cap(basic.cap), join: join(basic.join), miterLimit: miter, dash: dash(basic.dash))
        return StrokePaint(paint: paint(basic.color), style: style, startArrowhead: arrowhead(basic.startArrowhead),
                           endArrowhead: arrowhead(basic.endArrowhead), overprint: basic.overprint)
    }

    /// A dash's lengths: all-zero (or negative) reads as solid, an odd count repeats its cycle.
    static func dash(_ dash: Wiretuner_Doc_V1_DashPattern) -> [Double] {
        let lengths = dash.lengths.map { $0.isFinite ? max($0, 0) : 0 }
        guard lengths.contains(where: { $0 > 0 }) else { return [] }
        return lengths.count.isMultiple(of: 2) ? lengths : lengths + lengths
    }

    static func arrowhead(_ head: Wiretuner_Doc_V1_Arrowhead) -> Arrowhead? {
        guard !head.contours.isEmpty else { return nil }
        let shape = display(head.contours)
        guard !shape.elements.isEmpty else { return nil }
        return Arrowhead(name: head.name, shape: shape, filled: head.filled, pathTrim: head.pathTrim.isFinite ? head.pathTrim : 0)
    }

    /// A custom nib: one closed contour, else nil (the ellipse).
    static func nibShape(_ contours: [Wiretuner_Doc_V1_Contour]) -> DisplayPath? {
        guard contours.count == 1, contours[0].closed, contours[0].points.count >= 2 else { return nil }
        return display(contours)
    }

    /// Inline contours (arrowheads, nibs) as a display path.
    public static func display(_ contours: [Wiretuner_Doc_V1_Contour]) -> DisplayPath {
        var path = Wiretuner_Doc_V1_PathProps()
        path.contours = contours
        return DocumentDisplayListBuilder.display(VectorPath(path)) { _ in true }.path
    }

    static func customStrokePattern(_ pattern: Wiretuner_Doc_V1_CustomStrokePattern) -> CustomStrokePattern? {
        let patterns: [Wiretuner_Doc_V1_CustomStrokePattern: CustomStrokePattern] = [
            .arrow: .arrow, .ball: .ball, .braid: .braid, .cartographer: .cartographer, .checker: .checker, .crepe: .crepe,
            .diamond: .diamond, .dot: .dot, .heart: .heart, .leftDiagonal: .leftDiagonal, .neon: .neon, .rectangle: .rectangle,
            .rightDiagonal: .rightDiagonal, .roman: .roman, .snowflake: .snowflake, .squiggle: .squiggle, .star: .star, .swirl: .swirl,
            .teeth: .teeth, .threeWaves: .threeWaves, .twoWaves: .twoWaves, .wedge: .wedge, .zigzag: .zigzag,
        ]
        return patterns[pattern]
    }

    // MARK: Colours

    /// The paint a colour reference resolves to.
    public static func paint(_ ref: Wiretuner_Doc_V1_ColorRef) -> Paint {
        color(ref).map(Paint.solid) ?? .none
    }

    /// The colour a reference resolves to; nil for *None*; an unset reference reads black.
    /// While a scene is built (`ColorResolver.current`) swatch and tint references resolve
    /// through the document's swatches -- the live colour, a spot or Registration swatch (and a
    /// tint of one) with its ink -- and outside a build they read their cached colours.
    public static func color(_ ref: Wiretuner_Doc_V1_ColorRef) -> Color? {
        switch ref.ref {
        case nil:
            return .black
        case .none?:
            return nil
        case .inline(let color)?:
            return self.color(color)
        case .swatch(let swatch)?:
            if let resolver = ColorResolver.current { return resolver.color(ref) }
            return (try? Wiretuner_Doc_V1_Color(serializedBytes: swatch.cached)).map { color($0) } ?? .black
        case .tint(let tint)?:
            if let resolver = ColorResolver.current { return resolver.color(ref) }
            return color(tint)
        }
    }

    /// An inline tint read from its cached base: the base mixed toward paper in its own space
    /// (`Color.tinted`, as `ColorResolver` tints), so a CMYK base stays CMYK.
    static func color(_ tint: Wiretuner_Doc_V1_InlineTint) -> Color {
        let base = (try? Wiretuner_Doc_V1_Color(serializedBytes: tint.base.cached)).map(color) ?? .black
        return base.tinted(min(max(tint.percent / 100, 0), 1))
    }

    /// A stored colour for display, in its own space: sRGB and Display P3, CIELAB and OKLab
    /// tagged, and CMYK as CMYK, which the renderers take through Working CMYK
    /// (`ColorManagement`) as they take a swatch's -- an unnamed CMYK fill drew by the naive
    /// complement `R = (1 − C)(1 − K)` before, far brighter than the same colour as a swatch or
    /// in any export (C 80 M 5 showed as RGB 51/242/255 instead of 0/168/216).
    public static func color(_ color: Wiretuner_Doc_V1_Color) -> Color {
        switch color.components {
        case .rgb(let rgb)?:
            return color.space == .displayP3 ? Color(displayP3Red: rgb.r, green: rgb.g, blue: rgb.b) : Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        case .cmyk(let cmyk)?:
            return Color(cyan: cmyk.c, magenta: cmyk.m, yellow: cmyk.y, black: cmyk.k)
        case .lab(let lab)?:
            return color.space == .oklab ? Color(oklabL: lab.l, a: lab.a, b: lab.b) : Color(labL: lab.l, a: lab.a, b: lab.b)
        case nil:
            return .black
        }
    }
}
