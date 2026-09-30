import WTCRDT
import WTGeometry
import WTProto

// The Find & Replace tab's edits beyond a register per row (find-replace.adoc, "Find & Replace
// tab"; OBJ-023): the colour mapping with *Include tints* and gradient stops, *Remove >
// Overprinting*, and *Path shape* replacement.

/// *Color*: what each paint becomes.  A colour equal to `from` becomes `to`; with `tints` and a
/// swatch on both sides, a tint of `from` -- a named tint swatch based on it or an unnamed tint of
/// it -- becomes the same percentage of `to`: the named tint of `to` at that percentage when the
/// document has one, else an unnamed tint.  Paints are fills, strokes, gradient stops (the
/// fill's current ramp) and text runs' fill.
struct ColorReplacement {
    var from: Wiretuner_Doc_V1_ColorRef
    var to: Wiretuner_Doc_V1_ColorRef
    /// The swatches `from` and `to` name, when *Include tints* applies.
    private var tintBases: (from: OpID, to: OpID)?
    /// Every named tint: its base and percentage.
    private var namedTints: [OpID: (base: OpID, percent: Double)] = [:]
    private var resolver: ColorResolver?

    init(from: Wiretuner_Doc_V1_ColorRef, to: Wiretuner_Doc_V1_ColorRef, tints: Bool, state: EngineState) {
        self.from = from
        self.to = to
        guard tints, case .swatch(let source)? = from.ref, case .swatch(let target)? = to.ref else { return }
        tintBases = (OpID(source.id), OpID(target.id))
        let list = SwatchList(state)
        resolver = list.resolver
        for swatch in list.swatches {
            if let base = swatch.base { namedTints[swatch.id] = (base, swatch.tintPercent) }
        }
    }

    /// What `color` becomes; nil when it is left alone.
    func replacement(for color: Wiretuner_Doc_V1_ColorRef) -> Wiretuner_Doc_V1_ColorRef? {
        if ColorMatching.same(color, from) { return to }
        guard let (source, target) = tintBases, let resolver else { return nil }
        let percent: Double
        switch color.ref {
        case .tint(let tint)? where OpID(tint.base.id) == source:
            percent = tint.percent
        case .swatch(let swatch)?:
            guard let named = namedTints[OpID(swatch.id)], named.base == source else { return nil }
            percent = named.percent
        default:
            return nil
        }
        if let named = namedTints.first(where: { $0.value.base == target && $0.value.percent == percent })?.key {
            return resolver.reference(to: named)
        }
        return resolver.tint(of: target, percent: percent)
    }

    /// The writes recolouring `node`: one `SetAppearanceColor` per new colour over the rows,
    /// a `RecolorGradientStop` per matching stop, and a `fill` mark per matching text run.
    func commands(_ node: OpID, entries: [AttributeEntry], state: EngineState) -> [any Command] {
        var result: [any Command] = []
        var rows: [(color: Wiretuner_Doc_V1_ColorRef, rows: [(node: OpID, row: AppearanceRow)])] = []
        for entry in entries {
            if let color = AttributeFields.color(entry), let new = replacement(for: color) {
                if let index = rows.firstIndex(where: { $0.color == new }) {
                    rows[index].rows.append((node, entry.row))
                } else {
                    rows.append((new, [(node, entry.row)]))
                }
            }
            if entry.kind == .fill(.gradient) {
                for stop in GradientReading.ramp(entry.fill.settings.gradient) {
                    if let new = replacement(for: stop.color) { result.append(RecolorGradientStop(node: node, row: entry.row, stop: stop.id, color: new)) }
                }
            }
        }
        result.insert(contentsOf: rows.map { SetAppearanceColor($0.rows, color: $0.color) as any Command }, at: 0)
        if let text = state.textNode(node) {
            for run in text.runs {
                guard let new = run.values.lazy.compactMap({ value -> Wiretuner_Doc_V1_ColorRef? in
                    if case .fill(let color)? = value.value { return replacement(for: color) }
                    return nil
                }).first else { continue }
                result.append(ApplyMark(node: node, from: text.anchor(at: run.range.lowerBound), to: text.anchor(at: run.range.upperBound),
                                        value: .with { $0.fill = new }))
            }
        }
        return result
    }
}

/// *Remove > Overprinting*: overprint off on every basic fill and stroke that has it, and on the
/// text runs that overprint.
enum RemoveOverprinting {
    static func commands(_ node: OpID, entries: [AttributeEntry], state: EngineState) -> [any Command] {
        var result: [any Command] = []
        let fills = entries.filter { $0.kind == .fill(.basic) && $0.fill.settings.basic.overprint }.map { (node, $0.row) }
        if !fills.isEmpty { result.append(EditAttribute.fill(fills, "Overprint", [AttributeFields.Basic.fillOverprint]) { $0.basic.overprint = false }) }
        let strokes = entries.filter { $0.kind == .stroke(.basic) && $0.stroke.settings.basic.overprint }.map { (node, $0.row) }
        if !strokes.isEmpty { result.append(EditAttribute.stroke(strokes, "Overprint", [AttributeFields.Basic.overprint]) { $0.basic.overprint = false }) }
        if let text = state.textNode(node) {
            for run in text.runs where run.values.contains(where: { if case .overprint(true)? = $0.value { true } else { false } }) {
                result.append(ApplyMark(node: node, from: text.anchor(at: run.range.lowerBound), to: text.anchor(at: run.range.upperBound),
                                        value: .with { $0.overprint = false }))
            }
        }
        return result
    }
}

/// *Path shape*: each object matching `sample` (shape, stroke and fill) is replaced by a copy of
/// the replacement payload's first object, directly above it in its parent, and deleted.  The
/// copy is placed by the similarity carrying the sample onto the match -- so it sits on each match
/// as the replacement sat on the sample -- or, with `fit`, by `PathShape.fit` of the replacement's
/// bounds onto the match's.  The combining rules' merge story applies (new nodes, deleted matches).
struct PathShapeReplacement {
    var sample: PathShape
    var replacement: ClipboardPayload
    var fit: Bool

    /// The payload's first object alone.
    static func first(of payload: ClipboardPayload) -> ClipboardPayload? {
        guard let tree = payload.nodes.first else { return nil }
        var one = payload
        one.nodes = [tree]
        one.layerNames = Array(payload.layerNames.prefix(1))
        if payload.nodes.count > 1 { one.bounds = PathShape.bounds(of: tree) ?? payload.bounds }
        return one
    }

    /// `payload` with its named colours created or found in this change and its references
    /// rewritten, so every copy names the same swatches.
    static func resolvingColors(_ payload: ClipboardPayload, state: EngineState, builder: inout ChangeBuilder) throws -> ClipboardPayload {
        guard !payload.colors.isEmpty else { return payload }
        var resolved = payload
        let mapping = try PastedColors.resolve(payload.colors, state: state, builder: &builder)
        resolved.nodes = PastedColors.rewrite(payload.nodes, mapping: mapping, schema: state.schema)
        resolved.colors = []
        return resolved
    }

    /// The pasteboard-space matrix placing the replacement on `node`; nil when `node` does not match.
    func placement(on node: OpID, state: EngineState) -> AffineTransform? {
        guard let candidate = PathShape(node, in: state), candidate.look == sample.look, let similarity = sample.similarity(to: candidate) else { return nil }
        guard fit else { return similarity }
        guard let original = Objects.bounds(of: node, in: state), let bounds = replacement.bounds else { return similarity }
        return PathShape.fit(bounds, into: original)
    }

    func commands(_ node: OpID, state: EngineState) -> [any Command] {
        guard var payload = Self.first(of: replacement), let matrix = placement(on: node, state: state) else { return [] }
        payload.nodes[0].transform = payload.nodes[0].transform.concatenating(matrix)
        payload.bounds = payload.bounds.map { $0.applying(matrix) }
        return [Paste(payload, placement: .inFront(of: node)), DeleteNodes([node])]
    }
}

extension PathShape {
    /// The pasteboard bounds of a copied object's outline (anchors and controls through its
    /// transform); nil for anything but a path or shape.
    static func bounds(of tree: NodeTree) -> Rect? {
        guard let shape = PathShape(ClipboardPayload(nodes: [tree])) else { return nil }
        let points = shape.contours.flatMap(\.points)
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(Rect(first, first)) { $0.union($1) }
    }
}
