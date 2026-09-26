import WTCRDT
import WTGeometry
import WTProto
import WTRender

// The path operations with a sheet: menu:Modify[Combine > Transparency] (OBJ-026,
// combining-paths.adoc), menu:Modify[Alter Path > Expand Stroke] (OBJ-029, expand-stroke.adoc) and
// menu:Modify[Alter Path > Inset Path] (OBJ-030, inset-path.adoc).  Like `CombineCommand` they take
// unlocked paths, rectangles, ellipses and polygons, work in pasteboard space through the inputs'
// transform chains, and create fresh path nodes with the identity transform whose contours are in
// their parent's space, at the input's slot; an input they consume is `SetDeleted(true)` in the
// same change (combining-paths.adoc, "Merge semantics").

/// The colours the path operations read from an attribute stack.
public enum PathOperationPaint {
    /// The topmost visible fill of `node`'s stack; nil when it has none.
    public static func topFill(_ node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_FillSettings? {
        AttributePayload(copying: node, from: state)?.stack?.reversed().lazy.compactMap { element -> Wiretuner_Doc_V1_FillSettings? in
            if case .fill(let fill) = element, !fill.hidden { return fill.settings }
            return nil
        }.first
    }

    /// The topmost visible stroke of `node`'s stack; nil when it has none.
    public static func topStroke(_ node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_StrokeSettings? {
        AttributePayload(copying: node, from: state)?.stack?.reversed().lazy.compactMap { element -> Wiretuner_Doc_V1_StrokeSettings? in
            if case .stroke(let stroke) = element, !stroke.hidden { return stroke.settings }
            return nil
        }.first
    }

    /// The single colour a fill stands for (combining-paths.adoc, "Transparency color mix"): a
    /// Basic fill's colour; for the other kinds their average -- a gradient's ramp averaged along
    /// its length, a Custom fill's two colours, a Lens, Pattern or Textured fill's colour -- and
    /// white for a Tiled fill, which has none.  Nil for a fill of *None*.
    public static func averageColor(_ settings: Wiretuner_Doc_V1_FillSettings, resolver: ColorResolver) -> Color? {
        switch settings.kind {
        case .gradient:
            let stops = GradientReading.ramp(settings.gradient).compactMap { stop in resolver.color(stop.color).map { (stop.offset, $0) } }
            return average(ramp: stops)
        case .lens: return resolver.color(settings.lens.color)
        case .custom:
            let colors = [settings.custom.color, settings.custom.color2].compactMap(resolver.color)
            return colors.isEmpty ? nil : average(colors.map { ($0, 1) })
        case .pattern: return resolver.color(settings.pattern.color)
        case .textured: return resolver.color(settings.textured.color)
        case .tiled: return .white
        default: return resolver.color(settings.basic.color)
        }
    }

    /// The colour a stroke paints with (every kind has one); nil for *None*.
    public static func strokeColor(_ settings: Wiretuner_Doc_V1_StrokeSettings) -> Wiretuner_Doc_V1_ColorRef? {
        let ref: Wiretuner_Doc_V1_ColorRef = switch settings.kind {
        case .brush: settings.brush.color
        case .calligraphic: settings.calligraphic.color
        case .custom: settings.custom.color
        case .pattern: settings.pattern.color
        default: settings.basic.color
        }
        switch ref.ref {
        case .none?, nil: return nil
        default: return ref
        }
    }

    /// The space colours mix in: their own when they share one (and none is a spot ink), else the
    /// working space, Display P3.
    static func space(_ colors: [Color]) -> Color.Space {
        guard let first = colors.first, colors.allSatisfy({ $0.space == first.space && $0.spot == nil }) else { return .displayP3 }
        return first.space
    }

    /// `a` moved `amount` (0 ... 1) of the way to `b`, linearly in `space([a, b])`.
    public static func mix(_ a: Color, _ b: Color, amount: Double) -> Color {
        let t = min(max(amount, 0), 1)
        return average([(a, 1 - t), (b, t)])
    }

    /// The weighted average of `colors` (weights summing to more than 0).
    static func average(_ colors: [(Color, Double)]) -> Color {
        let space = space(colors.map(\.0))
        let total = colors.reduce(0) { $0 + $1.1 }
        var components = SIMD4<Double>(repeating: 0)
        var alpha = 0.0
        for (color, weight) in colors {
            let converted = color.converted(to: space)
            components += converted.components * (weight / total)
            alpha += converted.alpha * (weight / total)
        }
        return Color(space: space, components: components, alpha: alpha)
    }

    /// The mean of a piecewise linear ramp over 0 ... 1 (flat before its first stop and after its
    /// last); nil without stops.
    static func average(ramp stops: [(Double, Color)]) -> Color? {
        guard let first = stops.first, let last = stops.last else { return nil }
        var weighted: [(Color, Double)] = [(first.1, first.0), (last.1, 1 - last.0)]
        for (a, b) in zip(stops, stops.dropFirst()) {
            let length = b.0 - a.0
            weighted += [(a.1, length / 2), (b.1, length / 2)]
        }
        weighted.removeAll { $0.1 <= 0 }
        return weighted.isEmpty ? first.1 : average(weighted)
    }
}

/// Shared input rules of the path operations.
enum PathOperationInputs {
    /// The usable inputs of `nodes`, bottom first: unlocked live paths, rectangles, ellipses and
    /// polygons with something to draw, and -- when `closed` -- every renderable contour closed.
    static func of(_ nodes: [OpID], closed: Bool, in state: EngineState) -> [OpID] {
        Objects.stackingOrder(Objects.editable(nodes, in: state).filter { node in
            state.nodeKind(node).map(CombineCommand.kinds.contains) == true && (Objects.localPath(node, in: state)?.isRenderable ?? false)
                && (!closed || CombineCommand.isClosed(node, in: state))
        }, in: state)
    }

    /// Creates a path of `region` (pasteboard space) under `parent` with `stack`; its contours are
    /// in the space of `space` (the parent itself, or the live parent of a group created in the
    /// same change with the identity transform).
    static func create(_ region: FilledPath, stack: [AttributePayload.Element], parent: OpID, space: OpID? = nil, position: [UInt8],
                       state: EngineState, builder: inout ChangeBuilder) throws {
        var props = Wiretuner_Doc_V1_NodeProps()
        let toParent = Objects.pasteboardTransform(ofSpace: space ?? parent, in: state).inverse
        props.path.contours = InlineShapes.contours(DisplayPath(contours: region.applying(toParent).contours))
        let path = try NodeCopier.create(NodeTree(props: props), parent: parent, position: position, schema: state.schema, builder: &builder)
        try PasteAttributes.insert(stack, into: path, kind: .path, schema: state.schema, builder: &builder)
    }

    /// A stack of one Basic fill of `color` and nothing else.
    static func filled(_ color: Wiretuner_Doc_V1_ColorRef) -> [AttributePayload.Element] {
        var fill = Wiretuner_Doc_V1_Fill()
        fill.settings.kind = .basic
        fill.settings.basic.color = color
        return [.fill(fill)]
    }
}

// MARK: - Transparency (OBJ-026)

/// menu:Modify[Combine > Transparency] (combining-paths.adoc, "Transparency"): a new path in the
/// overlap of two filled closed paths, filled with their fill colours mixed -- `percent` of the
/// way from the back one's colour to the front one's (0 shows only the back colour, 100 only the
/// front) -- above the frontmost, under its parent.  The result has that one Basic fill and no
/// stroke.  The inputs are always kept.  One change "Transparency"; no change when the paths do
/// not overlap or the selection is not exactly two filled closed paths.
public struct TransparencyCommand: Command {
    public var nodes: [OpID]
    public var percent: Double

    public init(_ nodes: [OpID], percent: Double = 50) {
        self.nodes = nodes
        self.percent = percent
    }

    public var label: String { "Transparency" }

    /// The two inputs, back then front; empty when the item is disabled (not exactly two closed
    /// paths, or one without a fill).
    public static func inputs(_ nodes: [OpID], in state: EngineState) -> [OpID] {
        let inputs = PathOperationInputs.of(nodes, closed: true, in: state)
        let resolver = ColorResolver(state)
        guard inputs.count == 2, inputs.allSatisfy({ color(of: $0, in: state, resolver: resolver) != nil }) else { return [] }
        return inputs
    }

    /// Whether the menu item is enabled for the selection.
    public static func canPerform(_ nodes: [OpID], in state: EngineState) -> Bool {
        !inputs(nodes, in: state).isEmpty
    }

    /// The colour `node`'s fill stands for; nil when it has no fill.
    static func color(of node: OpID, in state: EngineState, resolver: ColorResolver) -> Color? {
        PathOperationPaint.topFill(node, in: state).flatMap { PathOperationPaint.averageColor($0, resolver: resolver) }
    }

    /// The overlap of the two inputs in pasteboard space; empty when they do not overlap or the
    /// command is disabled.
    public static func overlap(_ nodes: [OpID], in state: EngineState) -> FilledPath {
        let inputs = inputs(nodes, in: state)
        guard inputs.count == 2 else { return .empty }
        return Boolean.transparency(CombineCommand.region(inputs[0], in: state), CombineCommand.region(inputs[1], in: state))
    }

    /// The mixed colour the result is filled with; nil when the command is disabled.
    public static func mixedColor(_ nodes: [OpID], percent: Double, in state: EngineState) -> Color? {
        let inputs = inputs(nodes, in: state)
        guard inputs.count == 2 else { return nil }
        let resolver = ColorResolver(state)
        return PathOperationPaint.mix(color(of: inputs[0], in: state, resolver: resolver)!, color(of: inputs[1], in: state, resolver: resolver)!,
                                      amount: percent / 100)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let region = Self.overlap(nodes, in: state)
        guard !region.isEmpty, let front = Self.inputs(nodes, in: state).last, let parent = Objects.parent(of: front, in: state),
              let color = Self.mixedColor(nodes, percent: percent, in: state) else { return }
        let key = try Arranging.keys(next: front, above: true, count: 1, in: state)[0]
        try PathOperationInputs.create(region, stack: PathOperationInputs.filled(ColorResolver.inline(color)), parent: parent, position: key,
                                       state: state, builder: &builder)
    }
}

// MARK: - Expand Stroke (OBJ-029)

/// menu:Modify[Alter Path > Expand Stroke] (expand-stroke.adoc): each input's contours stroked with
/// `width`, `cap`, `join` and `miterLimit` (and the input's own dash, so a dashed stroke expands as
/// its dashes) by GEO-003's `Offset.strokeOutline` in the input's own space -- where its stroke is
/// drawn -- then carried to pasteboard space, so the outline lies where the stroke renders.  The
/// result is a closed path (a composite for a closed input) with one Basic fill of the input's
/// stroke colour (its topmost visible stroke's; black when it has none) and no stroke, at the
/// input's slot; the input is consumed unless `keepOriginal`.  Several inputs are expanded one by
/// one with the same settings.  One change "Expand Stroke"; no change when nothing expands.
public struct ExpandStrokeCommand: Command {
    public var nodes: [OpID]
    public var width: Double
    public var cap: WTGeometry.LineCap
    public var join: WTGeometry.LineJoin
    public var miterLimit: Double
    public var keepOriginal: Bool

    public init(_ nodes: [OpID], width: Double, cap: WTGeometry.LineCap = .butt, join: WTGeometry.LineJoin = .miter, miterLimit: Double = 4,
                keepOriginal: Bool = false) {
        self.nodes = nodes
        self.width = width
        self.cap = cap
        self.join = join
        self.miterLimit = miterLimit
        self.keepOriginal = keepOriginal
    }

    public var label: String { "Expand Stroke" }

    /// The sheet's width range in points.
    public static let widths: ClosedRange<Double> = 0.1...500

    /// The inputs of `nodes`, bottom first (open paths included).
    public static func inputs(_ nodes: [OpID], in state: EngineState) -> [OpID] {
        PathOperationInputs.of(nodes, closed: false, in: state)
    }

    public static func canPerform(_ nodes: [OpID], in state: EngineState) -> Bool {
        !inputs(nodes, in: state).isEmpty
    }

    /// The stroke the sheet starts from: the topmost visible stroke of the frontmost input as it
    /// draws (width, cap, join, miter limit and dash); a 1 pt butt, miter stroke when it has none.
    public static func style(_ nodes: [OpID], in state: EngineState) -> WTGeometry.StrokeStyle {
        guard let node = inputs(nodes, in: state).last, let stroke = PathOperationPaint.topStroke(node, in: state) else { return WTGeometry.StrokeStyle(width: 1) }
        return geometry(Appearances.stroke(stroke))
    }

    /// A drawn stroke's style as GEO-003 takes it.
    static func geometry(_ paint: StrokePaint) -> WTGeometry.StrokeStyle {
        let style = paint.style
        let cap: WTGeometry.LineCap = switch style.cap {
        case .butt: .butt
        case .round: .round
        case .square: .square
        }
        let join: WTGeometry.LineJoin = switch style.join {
        case .miter: .miter
        case .round: .round
        case .bevel: .bevel
        }
        return WTGeometry.StrokeStyle(width: style.width, cap: cap, join: join, miterLimit: style.miterLimit, dash: style.effectiveDash,
                                      dashPhase: style.dashPhase)
    }

    /// The outline of `node` in pasteboard space.
    public func outline(_ node: OpID, in state: EngineState) -> FilledPath {
        let path = Objects.localPath(node, in: state)!
        let contours = DocumentDisplayListBuilder.display(path) { $0.isRenderable }.path.contours
        let dash = PathOperationPaint.topStroke(node, in: state).map { Self.geometry(Appearances.stroke($0)) } ?? WTGeometry.StrokeStyle(width: width)
        let style = WTGeometry.StrokeStyle(width: min(max(width, Self.widths.lowerBound), Self.widths.upperBound), cap: cap, join: join,
                                miterLimit: max(miterLimit, 1), dash: dash.dash, dashPhase: dash.dashPhase)
        return Offset.strokeOutline(contours, style: style).applying(Objects.pasteboardTransform(of: node, in: state))
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Self.inputs(nodes, in: state) {
            let region = outline(node, in: state)
            guard !region.isEmpty, let parent = Objects.parent(of: node, in: state) else { continue }
            let color = PathOperationPaint.topStroke(node, in: state).flatMap(PathOperationPaint.strokeColor) ?? ColorResolver.inline(.black)
            let key = try Arranging.keys(next: node, above: true, count: 1, in: state)[0]
            try PathOperationInputs.create(region, stack: PathOperationInputs.filled(color), parent: parent, position: key, state: state,
                                           builder: &builder)
            if !keepOriginal { builder.append(Ops.setDeleted(node)) }
        }
    }
}

// MARK: - Inset Path (OBJ-030)

/// menu:Modify[Alter Path > Inset Path] (inset-path.adoc): each closed input's filled region in
/// pasteboard space inset by GEO-003's `Offset.insetSteps` -- step `k` of `steps` at the
/// `spacing` curve's distance, a positive `distance` inward, a negative one outward -- with
/// `join` and `miterLimit`.  One step makes one path at the input's slot; more make a group there
/// holding one path per step, outermost first (bottom of the stack).  Each path carries a copy of
/// the input's attribute stack; results are normalized regions, so *Even/odd fill* is off.
/// Collapsed steps are skipped; an input whose every step collapses is left alone (and kept).
/// Otherwise the input is consumed unless `keepOriginal`.  One change "Inset Path"; no change when
/// nothing survives.
public struct InsetPathCommand: Command {
    public var nodes: [OpID]
    public var steps: Int
    public var spacing: InsetSpacing
    public var distance: Double
    public var join: WTGeometry.LineJoin
    public var miterLimit: Double
    public var keepOriginal: Bool

    public init(_ nodes: [OpID], steps: Int = 1, spacing: InsetSpacing = .uniform, distance: Double, join: WTGeometry.LineJoin = .miter,
                miterLimit: Double = 4, keepOriginal: Bool = false) {
        self.nodes = nodes
        self.steps = steps
        self.spacing = spacing
        self.distance = distance
        self.join = join
        self.miterLimit = miterLimit
        self.keepOriginal = keepOriginal
    }

    public var label: String { "Inset Path" }

    /// The sheet's step range.
    public static let stepRange: ClosedRange<Int> = 1...100

    /// The closed inputs of `nodes`, bottom first.
    public static func inputs(_ nodes: [OpID], in state: EngineState) -> [OpID] {
        PathOperationInputs.of(nodes, closed: true, in: state)
    }

    public static func canPerform(_ nodes: [OpID], in state: EngineState) -> Bool {
        !inputs(nodes, in: state).isEmpty
    }

    /// The paths `node` insets to in pasteboard space, outermost first, collapsed steps left out.
    public func results(_ node: OpID, in state: EngineState) -> [FilledPath] {
        let count = min(max(steps, Self.stepRange.lowerBound), Self.stepRange.upperBound)
        let paths = Offset.insetSteps(CombineCommand.region(node, in: state), distance: distance, steps: count, spacing: spacing, join: join,
                                      miterLimit: max(miterLimit, 1)).filter { !$0.isEmpty }
        return distance < 0 ? paths.reversed() : paths
    }

    /// Whether every step of every input collapses (the sheet says so and btn:[OK] writes nothing).
    public func collapses(in state: EngineState) -> Bool {
        Self.inputs(nodes, in: state).allSatisfy { results($0, in: state).isEmpty }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Self.inputs(nodes, in: state) {
            let paths = results(node, in: state)
            guard !paths.isEmpty, let parent = Objects.parent(of: node, in: state) else { continue }
            let stack = AttributePayload(copying: node, from: state)?.stack ?? []
            let key = try Arranging.keys(next: node, above: true, count: 1, in: state)[0]
            if steps > 1 {
                var props = Wiretuner_Doc_V1_NodeProps()
                props.group.kind = .group
                let group = builder.append(Ops.create(parent: parent, position: key, props: props))
                for (path, position) in zip(paths, try PathEditing.keys(between: nil, and: nil, count: paths.count)) {
                    try PathOperationInputs.create(path, stack: stack, parent: group, space: parent, position: position, state: state, builder: &builder)
                }
            } else {
                try PathOperationInputs.create(paths[0], stack: stack, parent: parent, position: key, state: state, builder: &builder)
            }
            if !keepOriginal { builder.append(Ops.setDeleted(node)) }
        }
    }
}
