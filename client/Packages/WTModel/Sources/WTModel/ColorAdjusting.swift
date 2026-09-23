import WTCRDT
import WTProto
import WTRender

// COLOR-014: adjusting the colours of objects (docs/_includes/color/editing-colors.adoc,
// "Brightening and dulling colors", "Controlling color values", "Converting to grayscale",
// "Randomizing named colors").  Each command writes the *result* into every colour register of
// the selection -- never a delta -- so two people lightening one object at once produce one
// step, not two.

/// The mode of *Color Control*: which components the deltas adjust.
public enum ColorControlMode: String, Hashable, Sendable, CaseIterable {
    case cmyk, rgb, hls
}

/// A colour adjustment (editing-colors.adoc, "Client"): the four one-step extensions move HLS
/// lightness or saturation by 10 points, computed in the colour's own RGB space (a CMYK or Lab
/// colour through sRGB) and written back in its own space; *Color Control* adds per-component
/// deltas (−1 ... 1, hue −360 ... 360 degrees) in its mode's space, clamped at the limits.
public enum ColorAdjustment: Hashable, Sendable {
    case lighten
    case darken
    case saturate
    case desaturate
    /// Deltas in `mode`'s components: C, M, Y, K; R, G, B; or H (degrees), L, S.
    case control(ColorControlMode, SIMD4<Double>)

    /// The step size of the one-step extensions.
    public static let step = 0.1

    public var verb: String {
        switch self {
        case .lighten: "Lighten colors"
        case .darken: "Darken colors"
        case .saturate: "Saturate colors"
        case .desaturate: "Desaturate colors"
        case .control: "Adjust colors"
        }
    }

    /// `color` adjusted, in its own space (its spot ink and alpha kept).
    public func apply(_ color: Color) -> Color {
        let result: Color
        switch self {
        case .lighten: result = Self.hls(color) { $0.lightness += Self.step }
        case .darken: result = Self.hls(color) { $0.lightness -= Self.step }
        case .saturate: result = Self.hls(color) { $0.saturation += Self.step }
        case .desaturate: result = Self.hls(color) { $0.saturation -= Self.step }
        case .control(.hls, let d):
            result = Self.hls(color) { hls in
                hls.hue = ((hls.hue + d.x).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
                hls.lightness += d.y
                hls.saturation += d.z
            }
        case .control(.rgb, let d):
            let space = ColorModels.rgbSpace(of: color, fallback: .sRGB)
            let rgb = ColorModels.rgb(color, in: space)
            let moved = (rgb + SIMD3(d.x, d.y, d.z)).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
            result = Color(space: space, components: SIMD4(moved.x, moved.y, moved.z, 0)).converted(to: color.space)
        case .control(.cmyk, let d):
            let cmyk = color.space == .cmyk ? color : color.converted(to: .cmyk)
            let moved = (cmyk.clampedToSpace.components + d).clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 1))
            result = Color(space: .cmyk, components: moved).converted(to: color.space)
        }
        var adjusted = result.clampedToSpace
        adjusted.alpha = color.alpha
        adjusted.spot = color.spot
        return adjusted
    }

    /// `color` with its HLS changed by `change` (clamped), back in its own space.  A colour
    /// already in its RGB space round-trips exactly.
    static func hls(_ color: Color, _ change: (inout ColorModels.HLS) -> Void) -> Color {
        let space = ColorModels.rgbSpace(of: color, fallback: .sRGB)
        var hls = ColorModels.hls(color, in: space)
        let before = hls
        change(&hls)
        hls.lightness = min(max(hls.lightness, 0), 1)
        hls.saturation = min(max(hls.saturation, 0), 1)
        guard hls != before else { return color }
        return ColorModels.color(hls, in: space).converted(to: color.space)
    }

    /// The Black tint percentage of *Convert to Grayscale*: `(1 − Y) × 100` with
    /// `Y = 0.2126 R + 0.7152 G + 0.0722 B` of the colour's sRGB rendering.
    public static func grayPercent(_ color: Color) -> Double {
        let rgb = color.srgb
        let y = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
        return min(max((1 - y) * 100, 0), 100)
    }
}

/// Every colour register under a selection (editing-colors.adoc, "Client"; shared with Find &
/// Replace): each selected node and its descendants -- group members, blend and extrusion
/// children -- once each, every `ColorRef` register of theirs that is not under a removed element
/// (fills, strokes, gradient stops, effect colours, overrides) and every text mark's fill.
/// Colours inside ATOMIC messages (`ColorUse.Location.nested`) are listed by `ColorUses` but not
/// rewritable one by one, so the walker leaves them out.
public enum ColorRegisterWalker {
    public static func uses(_ nodes: [OpID], in state: EngineState) -> [ColorUse] {
        var result: [ColorUse] = []
        var seen: Set<OpID> = []
        func visit(_ node: OpID) {
            guard seen.insert(node).inserted, state.isLive(node) else { return }
            for use in ColorUses.uses(of: node, in: state) {
                switch use.location {
                case .register(let path) where isLive(path, of: node, in: state): result.append(use)
                case .mark: result.append(use)
                default: break
                }
            }
            state.liveChildren(node).forEach(visit)
        }
        nodes.forEach(visit)
        return result
    }

    /// Whether every element `path` runs through is live.
    static func isLive(_ path: RegisterPath, of node: OpID, in state: EngineState) -> Bool {
        var prefix: [RegisterPath.Segment] = []
        for segment in path.segments {
            prefix.append(segment)
            if case .element = segment, state.store.element(node, RegisterPath(segments: prefix))?.isDeleted != false { return false }
        }
        return true
    }

    /// The op writing `ref` where `use` is: a `SetFields` of the register, or a `TextMark` over
    /// the same span as the mark with its fill replaced (a later mark of the same attribute wins).
    static func write(_ ref: Wiretuner_Doc_V1_ColorRef, at use: ColorUse, in state: EngineState) -> Wiretuner_Doc_V1_Op? {
        switch use.location {
        case .register(let path):
            return ColorUses.write(ref, at: path, of: use.node)
        case .mark(let text, let id):
            guard let mark = state.store.text(use.node, text)?.marks[id] else { return nil }
            var value = Wiretuner_Doc_V1_TextMark()
            value.node = use.node.proto
            value.text = text.proto
            value.start.char = Ops.elementID(mark.start.char)
            value.start.before = mark.start.before
            value.end.char = Ops.elementID(mark.end.char)
            value.end.before = mark.end.before
            value.value.fill = ref
            var op = Wiretuner_Doc_V1_Op()
            op.textMark = value
            return op
        default:
            return nil
        }
    }
}

/// Shared by the colour adjustment commands.
enum ColorRewriting {
    /// Writes `transform(use, colour)` over every colour register of `nodes` that resolves to a
    /// process colour and changes; spot and Registration colours and *None* are skipped.
    static func rewrite(_ nodes: [OpID], state: EngineState, builder: inout ChangeBuilder,
                        _ transform: (ColorUse, Color, ColorResolver) -> Wiretuner_Doc_V1_ColorRef?) {
        let resolver = ColorResolver(state)
        for use in ColorRegisterWalker.uses(nodes, in: state) {
            guard let color = resolver.color(use.ref), color.spot == nil, let ref = transform(use, color, resolver), ref != use.ref,
                  let op = ColorRegisterWalker.write(ref, at: use, in: state) else { continue }
            builder.append(op)
        }
    }
}

/// menu:Extensions[Colors > Lighten / Darken / Saturate / Desaturate Colors] and *Color Control*'s
/// btn:[Apply]: every process colour in the selection adjusted and written as an unnamed colour
/// over its register -- a swatch reference is replaced, the swatch untouched; a colour already at
/// its limit is left alone.  One change, labelled `Lighten colors` or `Lighten colors of 12
/// objects`.
public struct AdjustColors: Command {
    public var nodes: [OpID]
    public var adjustment: ColorAdjustment

    public init(_ nodes: [OpID], _ adjustment: ColorAdjustment) {
        self.nodes = nodes
        self.adjustment = adjustment
    }

    public var label: String { fannedLabel(adjustment.verb, count: nodes.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        ColorRewriting.rewrite(nodes, state: state, builder: &builder) { _, color, _ in
            let adjusted = adjustment.apply(color)
            return adjusted == color ? nil : ColorResolver.inline(adjusted)
        }
    }
}

/// menu:Extensions[Colors > Convert to Grayscale]: every process colour in the selection becomes a
/// tint of the Black swatch of matching darkness (`ColorAdjustment.grayPercent`); a colour lighter
/// than half a percent becomes the White swatch.  Without the default swatches the result is an
/// unnamed CMYK black of that percentage.  Labelled `Convert to grayscale`.
public struct ConvertToGrayscale: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { fannedLabel("Convert to grayscale", count: nodes.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        ColorRewriting.rewrite(nodes, state: state, builder: &builder) { _, color, resolver in
            Self.gray(ColorAdjustment.grayPercent(color), resolver: resolver)
        }
    }

    static func gray(_ percent: Double, resolver: ColorResolver) -> Wiretuner_Doc_V1_ColorRef {
        if percent < 0.5 {
            return resolver.swatch(role: .white).map(resolver.reference(to:)) ?? ColorResolver.inline(Color(cyan: 0, magenta: 0, yellow: 0, black: 0))
        }
        guard let black = resolver.swatch(role: .black) else {
            return ColorResolver.inline(Color(cyan: 0, magenta: 0, yellow: 0, black: percent / 100))
        }
        return resolver.tint(of: black, percent: percent)
    }
}

/// menu:Extensions[Colors > Randomize Named Colors]: every colour swatch except the protected
/// defaults (and tints, which follow their base) takes a random value in its own space; its spot
/// flag and name are kept, except that a swatch still named by its old values is renamed to the
/// new ones.  One change, labelled `Randomize named colors`; `seed` makes a run repeatable.
public struct RandomizeSwatches: Command {
    public var seed: UInt64

    public init(seed: UInt64 = UInt64.random(in: 1 ... .max)) {
        self.seed = seed
    }

    public var label: String { "Randomize named colors" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = SwatchList(state)
        var generator = SplitMix(state: seed)
        var taken: Set<String> = []
        for swatch in list.swatches where !swatch.isProtected && !swatch.isTint {
            let color = Self.random(in: swatch.value.space, using: &generator)
            var values = Wiretuner_Doc_V1_SwatchProps()
            values.value = ColorValues.stored(color)
            var paths = [SwatchFields.value]
            if swatch.hasDefaultName {
                let name = Swatches.defaultName(color, list, taken: taken, except: swatch.id)
                taken.insert(name)
                values.common.name = name
                paths.append(SwatchFields.name)
            }
            var props = Wiretuner_Doc_V1_NodeProps()
            props.swatch = values
            builder.append(Ops.set(swatch.id, paths, values: props))
        }
    }

    /// A random colour spread over `space`'s range.
    static func random(in space: Color.Space, using generator: inout SplitMix) -> Color {
        let u = SIMD4(generator.unit(), generator.unit(), generator.unit(), generator.unit())
        switch space {
        case .cmyk: return Color(cyan: u.x, magenta: u.y, yellow: u.z, black: u.w * 0.5)
        case .sRGB, .displayP3: return Color(space: space, components: SIMD4(u.x, u.y, u.z, 0))
        case .lab: return Color(labL: 20 + u.x * 70, a: u.y * 160 - 80, b: u.z * 160 - 80).clampedToSpace
        case .oklab: return Color(oklabL: 0.3 + u.x * 0.6, a: u.y * 0.4 - 0.2, b: u.z * 0.4 - 0.2)
        }
    }
}

/// SplitMix64: a small, repeatable generator for the randomizing commands.
struct SplitMix {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in 0 ..< 1 (the top 53 bits).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
