import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// What a scene build knows beyond one node's registers (FX-002, FX-007, ATTR-008): the
/// document's raster effect settings, and each brush node's definition resolved with its symbols'
/// artwork.  `DocumentDisplayListBuilder` makes one `current` for each build, beside
/// `ColorResolver.current`; outside a build objects render with 72 ppi and brush strokes as their
/// cached Basic strokes.
public struct SceneContext: Sendable {
    @TaskLocal public static var current: SceneContext?

    /// `SettingsProps.raster_effects`, resolved.
    public var raster: RasterSettings
    /// Live brush nodes by id, resolved (`Brushes.resolve`).
    public var brushes: [OpID: Brush]

    public init(raster: RasterSettings = RasterSettings(), brushes: [OpID: Brush] = [:]) {
        self.raster = raster
        self.brushes = brushes
    }

    /// The document's raster settings as `state` holds them.
    public static func raster(_ state: EngineState) -> RasterSettings {
        let settings = state.props(WellKnown.settings).settings.rasterEffects
        return RasterSettings(resolution: settings.resolutionPpi == 0 ? 72 : Double(settings.resolutionPpi), optimalCMYK: settings.optimalCmyk)
    }
}

/// Lowers stored effects to WTRender's `LiveEffect` (live-effects.adoc, raster-effects.adoc,
/// transparency.adoc): every field copied as stored -- the kernels apply the read-time clamps --
/// colours resolved, `CornersEffect.points` resolved to anchors by the caller.
public enum EffectLowering {
    /// The display-list effect of `settings`; `corners` maps a path point element id to its
    /// anchor (nil drops the member, as a dangling, curve or foreign point is dropped).
    public static func effect(_ settings: Wiretuner_Doc_V1_EffectSettings, corners: (OpID) -> CornerPoint? = { _ in nil }) -> LiveEffect {
        switch settings.kind {
        case .bend:
            return .bend(LiveEffect.Bend(size: settings.bend.size, center: point(settings.bend.center)))
        case .duet:
            let duet = settings.duet
            return .duet(LiveEffect.Duet(mode: duet.mode == .rotate ? .rotate : .reflect, center: point(duet.center), axisAngle: duet.axisAngle,
                                         copies: Int(duet.copies), joined: duet.joined, closed: duet.closed, evenOdd: duet.evenOdd))
        case .expandPath:
            let expand = settings.expandPath
            let directions: [Wiretuner_Doc_V1_ExpandDirection: LiveEffect.ExpandPath.Direction] = [.inside: .inside, .outside: .outside]
            return .expandPath(LiveEffect.ExpandPath(direction: directions[expand.direction] ?? .both, width: expand.width, cap: Appearances.cap(expand.cap),
                                                     join: Appearances.join(expand.join), miterLimit: expand.miterLimit))
        case .ragged:
            let ragged = settings.ragged
            return .ragged(LiveEffect.Ragged(size: ragged.size, frequency: ragged.frequency, copies: Int(ragged.copies), smooth: ragged.smooth,
                                             uniform: ragged.uniform, seed: ragged.seed))
        case .sketch:
            let sketch = settings.sketch
            return .sketch(LiveEffect.Sketch(amount: sketch.amount, copies: Int(sketch.copies), closed: sketch.closed, seed: sketch.seed))
        case .transform:
            let t = settings.transform
            return .transform(LiveEffect.Transform(scaleX: t.scaleX, scaleY: t.scaleY, skewH: t.skewH, skewV: t.skewV, rotate: t.rotate,
                                                   move: point(t.move), center: point(t.center), copies: Int(t.copies)))
        case .corners:
            let styles: [Wiretuner_Doc_V1_CornerStyle: LiveEffect.Corners.Style] = [.invertedRound: .invertedRound, .chamfer: .chamfer]
            // Members that resolve to no anchor drop out; when every member drops out the effect
            // treats no corner (an unmatched placeholder), not every corner as an empty set would.
            let members = settings.corners.points.compactMap { OpID(element: $0) }
            let points = members.compactMap(corners)
            return .corners(LiveEffect.Corners(radius: settings.corners.radius, style: styles[settings.corners.style] ?? .round,
                                               points: members.isEmpty ? [] : (points.isEmpty ? [CornerPoint(contour: -1, anchor: -1)] : points)))
        case .combine:
            let operations: [Wiretuner_Doc_V1_BooleanOp: LiveEffect.Combine.Operation] = [.subtract: .subtract, .intersect: .intersect, .exclude: .exclude]
            return .combine(LiveEffect.Combine(operation: operations[settings.combine.op] ?? .union))
        default:
            return raster(settings)
        }
    }

    /// The raster and transparency kinds (and unknown kinds, which render as nothing).
    static func raster(_ settings: Wiretuner_Doc_V1_EffectSettings) -> LiveEffect {
        switch settings.kind {
        case .bevelEmboss:
            let bevel = settings.bevelEmboss
            let styles: [Wiretuner_Doc_V1_BevelStyle: LiveEffect.BevelEmboss.Style] = [
                .outerBevel: .outerBevel, .raisedEmboss: .raisedEmboss, .insetEmboss: .insetEmboss,
            ]
            let edges: [Wiretuner_Doc_V1_BevelEdgeShape: LiveEffect.BevelEmboss.EdgeShape] = [
                .smooth: .smooth, .sloped: .sloped, .frame1: .frame1, .frame2: .frame2, .ring: .ring, .ruffle: .ruffle,
            ]
            let presets: [Wiretuner_Doc_V1_BevelButtonPreset: LiveEffect.BevelEmboss.ButtonPreset] = [
                .highlighted: .highlighted, .inset: .inset, .inverted: .inverted,
            ]
            return .bevelEmboss(LiveEffect.BevelEmboss(
                style: styles[bevel.style] ?? .innerBevel, color: bevel.hasColor ? (Appearances.color(bevel.color) ?? .clear) : Color(white: 0.6),
                width: bevel.width, contrast: Double(bevel.contrast), softness: Double(bevel.softness), angle: bevel.angle,
                edgeShape: edges[bevel.edgeShape] ?? .flat, buttonPreset: presets[bevel.buttonPreset] ?? .raised
            ))
        case .blur:
            return .blur(LiveEffect.Blur(style: settings.blur.style == .basic ? .basic : .gaussian, radius: settings.blur.radius))
        case .shadow:
            let shadow = settings.shadow
            let styles: [Wiretuner_Doc_V1_ShadowStyle: LiveEffect.Shadow.Style] = [.innerShadow: .innerShadow, .glow: .glow, .innerGlow: .innerGlow]
            return .shadow(LiveEffect.Shadow(style: styles[shadow.style] ?? .dropShadow, color: shadow.hasColor ? (Appearances.color(shadow.color) ?? .clear) : .black,
                                             offset: shadow.offset, opacity: Double(shadow.opacity), softness: Double(shadow.softness), angle: shadow.angle))
        case .sharpen:
            let sharpen = settings.sharpen
            return .sharpen(LiveEffect.Sharpen(style: sharpen.style == .unsharpMask ? .unsharpMask : .basic, amount: sharpen.amount,
                                               pixelRadius: sharpen.pixelRadius, threshold: Double(sharpen.threshold)))
        case .transparency:
            let transparency = settings.transparency
            let styles: [Wiretuner_Doc_V1_TransparencyStyle: LiveEffect.Transparency.Style] = [.feather: .feather, .gradientMask: .gradientMask]
            let style = styles[transparency.style] ?? .basic
            return .transparency(LiveEffect.Transparency(
                style: style, amount: Double(transparency.amount), radius: transparency.radius, softness: Double(transparency.softness),
                mask: style == .gradientMask ? Appearances.gradient(transparency.mask) : nil
            ))
        default:
            return .unsupported
        }
    }

    static func point(_ point: Wiretuner_Doc_V1_Point) -> Point {
        Point(x: point.x, y: point.y)
    }

    /// The display elements of `effects` for a display stack of `rows` (the stack's fill and stroke
    /// rows as `Appearance(stack:)` receives them, in order): each effect in `effects`' order with
    /// its target -- the object, or the index of its fill or stroke in `rows`.  An effect whose
    /// `attached_to` names no row in `rows` (deleted, not a fill or stroke, or a fill left out)
    /// is skipped.
    static func elements(effects: [Wiretuner_Doc_V1_Effect], rows: [OpID],
                         corners: (OpID) -> CornerPoint?) -> [EffectElement] {
        let index = Dictionary(rows.enumerated().map { ($0.element, $0.offset) }) { first, _ in first }
        return effects.compactMap { effect in
            let target: EffectTarget
            if let attached = OpID(element: effect.attachedTo) {
                guard let at = index[attached] else { return nil }
                target = .element(at)
            } else {
                target = .object
            }
            return EffectElement(Self.effect(effect.settings, corners: corners), target: target, hidden: effect.hidden)
        }
    }

    /// The raster settings of a stack: its own `raster_dpi`, else the document's.
    static func raster(_ props: Wiretuner_Doc_V1_AppearanceProps) -> RasterSettings {
        var settings = SceneContext.current?.raster ?? RasterSettings()
        if props.rasterDpi > 0 { settings.resolution = Double(props.rasterDpi) }
        return settings
    }

    /// Whether `props` carries a visible Corners effect at the object level: a rectangle's own
    /// radii are then ignored (live-effects.adoc, "Corners" merge rule).
    static func hasCorners(_ props: Wiretuner_Doc_V1_AppearanceProps) -> Bool {
        props.effects.contains { $0.settings.kind == .corners && !$0.hidden && OpID(element: $0.attachedTo) == nil }
    }

    /// Anchor lookup for a path's point element ids, in the `CornerPoint` numbering (renderable
    /// contours in order, anchors in drawing order).
    static func cornerPoints(_ path: VectorPath) -> (OpID) -> CornerPoint? {
        var table: [OpID: CornerPoint] = [:]
        var contourIndex = 0
        for contour in path.contours where contour.isRenderable {
            for (anchor, point) in contour.drawn.enumerated() where table[point.id] == nil {
                table[point.id] = CornerPoint(contour: contourIndex, anchor: anchor)
            }
            contourIndex += 1
        }
        return { table[$0] }
    }
}
