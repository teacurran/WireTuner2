import WTCRDT
import WTGeometry
import WTProto

// The Find & Replace Graphics panel's btn:[Change] (find-replace.adoc, "Find & Replace tab";
// OBJ-023): `ReplaceGraphics` finds the candidates the attribute's *From* settings match and maps
// each to the register writes of the owning feature's command -- recolour, stroke width,
// halftone, transform, simplify, blend steps, delete -- in one change labelled
// `Replace <attribute> in N objects`.  *Path shape* pastes the replacement over each match and
// deletes the match (`PathShapeReplacement`).  A replace larger than one change's op limit is split by
// `chunks(limit:in:)` into several with a `(2/3)` suffix, which the caller performs in one undo
// group.

/// A numeric field's arithmetic (`*2`, `+1`, `/3`, or a plain value), applied to each object's
/// own value.
public enum NumberEdit: Hashable, Sendable {
    case set(Double)
    case add(Double)
    case multiply(Double)
    case divide(Double)

    /// Parses a field: a plain number sets, a leading `+`, `*` or `/` computes (`-3` is a value).
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        let rest = Double(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
        switch first {
        case "+": guard let rest else { return nil }; self = .add(rest)
        case "*", "×": guard let rest else { return nil }; self = .multiply(rest)
        case "/", "÷": guard let rest, rest != 0 else { return nil }; self = .divide(rest)
        default:
            if let value = Double(trimmed) {
                self = .set(value)
            } else {
                return nil
            }
        }
    }

    public func apply(_ value: Double) -> Double {
        switch self {
        case .set(let new): new
        case .add(let delta): value + delta
        case .multiply(let factor): value * factor
        case .divide(let divisor): value / divisor
        }
    }
}

/// What btn:[Change] does.
public enum GraphicEdit: Hashable, Sendable {
    /// Every fill, stroke, gradient stop and text colour equal to `from` becomes `to`; with
    /// `tints` (*Include tints*) a tint of the swatch `from` -- named or unnamed -- becomes the same
    /// tint of the swatch `to` (`ColorReplacement`).
    case color(from: Wiretuner_Doc_V1_ColorRef, to: Wiretuner_Doc_V1_ColorRef, tints: Bool = false)
    /// Basic strokes whose width lies in `range` get `to` of their width.
    case strokeWidth(ValueRange, to: NumberEdit)
    /// Removes what `RemoveTarget` names.
    case remove(RemoveTarget)
    /// Rotates each object about its own bounds centre (degrees, counter-clockwise on the page).
    case rotate(Double)
    /// Scales each object about its own bounds centre (percentages).
    case scale(x: Double, y: Double)
    /// Paths with more than `points` points, simplified by `amount`.
    case simplify(points: Int, amount: Double)
    /// Blends whose steps lie in `range` get `to` steps.
    case blendSteps(ValueRange, to: NumberEdit)
    /// *Resample at* the printer resolution: blends whose steps lie in `range` get the steps the
    /// document's printer resolution and screen call for (`BlendResampling`, D-090).
    case resampleBlends(ValueRange)
    /// Objects with the shape, stroke and fill of `from` are replaced by the first object of `to`
    /// (a clipboard payload, *Paste In*): placed by the similarity carrying the sample onto the
    /// match, or with `fit` (*Transform to fit original*) scaled onto the match's bounds.
    case pathShape(from: PathShape, to: ClipboardPayload, fit: Bool)

    public enum RemoveTarget: String, Hashable, Sendable, CaseIterable {
        /// Objects with no fill and no stroke (paths and shapes).
        case invisible
        /// Overprinting on basic fills and strokes and on text.
        case overprinting
        /// Custom halftones.
        case halftones
        /// The contents of clipping paths (the clip path stays).
        case contents
    }

    /// The attribute's name in the label.
    public var noun: String {
        switch self {
        case .color: "color"
        case .strokeWidth: "stroke width"
        case .remove(.invisible): "invisible objects"
        case .remove(.halftones): "halftones"
        case .remove(.overprinting): "overprinting"
        case .remove(.contents): "contents"
        case .rotate: "rotation"
        case .scale: "scale"
        case .simplify: "path points"
        case .blendSteps, .resampleBlends: "blend steps"
        case .pathShape: "path shape"
        }
    }
}

/// btn:[Change].
public struct ReplaceGraphics: Command {
    /// The ingest limit of one change.
    public static let opLimit = 10_000

    public var edit: GraphicEdit
    /// The objects of the scope (`AttributeQuery.candidates`).
    public var candidates: [OpID]
    /// Fixed label (a split part); nil counts the matches.
    public var fixedLabel: String?

    public init(_ edit: GraphicEdit, candidates: [OpID], label: String? = nil) {
        self.edit = edit
        self.candidates = candidates
        fixedLabel = label
    }

    public var label: String { fixedLabel ?? "Replace \(edit.noun) in \(candidates.count) objects" }

    /// The candidates `edit` changes.
    public static func matches(_ edit: GraphicEdit, in candidates: [OpID], state: EngineState) -> [OpID] {
        let context = Context(edit, state: state)
        return candidates.filter { !commands(edit, for: $0, state: state, context: context).isEmpty }
    }

    /// What every node's commands share, read once per replace: the colour mapping.
    struct Context {
        var colors: ColorReplacement?

        init(_ edit: GraphicEdit, state: EngineState) {
            if case .color(let from, let to, let tints) = edit { colors = ColorReplacement(from: from, to: to, tints: tints, state: state) }
        }
    }

    /// The commands that change `node`, empty when it does not match.
    static func commands(_ edit: GraphicEdit, for node: OpID, state: EngineState, context: Context) -> [any Command] {
        guard state.isLive(node) else { return [] }
        let entries = AppearanceEditing.entries(node, in: state)
        switch edit {
        case .color:
            return context.colors.map { $0.commands(node, entries: entries, state: state) } ?? []
        case .remove(.overprinting):
            return RemoveOverprinting.commands(node, entries: entries, state: state)
        case .remove(.contents):
            guard ClipGroups.clipPath(of: node, in: state) != nil else { return [] }
            let contents = ClipGroups.contents(of: node, in: state)
            return contents.isEmpty ? [] : [DeleteNodes(contents)]
        case .pathShape(let from, let to, let fit):
            return PathShapeReplacement(sample: from, replacement: to, fit: fit).commands(node, state: state)
        case .strokeWidth(let range, let to):
            return entries.compactMap { entry -> (any Command)? in
                guard entry.kind == .stroke(.basic), let width = AttributeFields.width(entry), range.contains(width) else { return nil }
                let new = to.apply(width)
                guard new.isFinite, new >= 0, abs(new - width) > 1e-9 else { return nil }
                return SetStrokeWidth([(node, entry.row.element)], width: new)
            }
        case .remove(.invisible):
            let shapes: Set<NodeKind> = [.path, .rect, .ellipse, .polygon]
            guard let kind = state.nodeKind(node), shapes.contains(kind), entries.allSatisfy(\.hidden) else { return [] }
            return [DeleteNodes([node])]
        case .remove(.halftones):
            guard NodeValues.common(state.props(node)).map({ $0.hasHalftone && $0.halftone != Wiretuner_Doc_V1_Halftone() }) == true else { return [] }
            return [SetObjectHalftone([node], halftone: nil)]
        case .rotate(let degrees):
            guard degrees.truncatingRemainder(dividingBy: 360) != 0, let bounds = Objects.bounds(of: node, in: state) else { return [] }
            return [TransformObjects([node], matrix: .rotation(radians: degrees * .pi / 180), about: bounds.center, kind: .rotate)]
        case .scale(let x, let y):
            guard x > 0, y > 0, x != 100 || y != 100, let bounds = Objects.bounds(of: node, in: state) else { return [] }
            return [TransformObjects([node], matrix: .scale(x: x / 100, y: y / 100), about: bounds.center, kind: .scale)]
        case .simplify(let points, let amount):
            guard state.nodeKind(node) == .path, VectorPath(state.props(node).path, node: node, state: state).pointCount > points else { return [] }
            return [SimplifyPaths([node], amount: amount)]
        case .blendSteps(let range, let to):
            guard state.nodeKind(node) == .blend else { return [] }
            let steps = Double(state.props(node).blend.steps)
            guard range.contains(steps) else { return [] }
            let new = Int(to.apply(steps).rounded())
            guard (1...1000).contains(new), Double(new) != steps else { return [] }
            return [EditBlend.steps([node], new)]
        case .resampleBlends(let range):
            guard state.nodeKind(node) == .blend else { return [] }
            let stored = state.props(node).blend.steps
            let steps = stored == 0 ? 25 : Int(stored)
            guard range.contains(Double(steps)), let new = BlendResampling.steps(for: node, in: state), new != steps else { return [] }
            return [EditBlend.steps([node], new)]
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let context = Context(edit, state: state)
        var edit = edit
        if case .pathShape(let from, let to, let fit) = edit {
            // The replacement's named colours are resolved once for every copy.
            edit = .pathShape(from: from, to: try PathShapeReplacement.resolvingColors(to, state: state, builder: &builder), fit: fit)
        }
        for node in candidates {
            for command in Self.commands(edit, for: node, state: state, context: context) {
                try command.execute(&builder, state: state)
            }
        }
    }

    /// The replace as changes of at most `limit` ops each: one command when it fits, else parts
    /// labelled `... (2/3)`; only matching candidates are kept.
    public static func chunks(_ edit: GraphicEdit, candidates: [OpID], limit: Int = opLimit, in state: EngineState) -> [ReplaceGraphics] {
        let matched = matches(edit, in: candidates, state: state)
        guard !matched.isEmpty else { return [] }
        let context = Context(edit, state: state)
        var parts: [[OpID]] = [[]]
        var count = 0
        for node in matched {
            var scratch = ChangeBuilder(replica: 1, startCounter: 1)
            for command in commands(edit, for: node, state: state, context: context) { try? command.execute(&scratch, state: state) }
            let ops = scratch.ops.count
            if count + ops > limit, !parts[parts.count - 1].isEmpty {
                parts.append([])
                count = 0
            }
            parts[parts.count - 1].append(node)
            count += ops
        }
        let base = "Replace \(edit.noun) in \(matched.count) objects"
        guard parts.count > 1 else { return [ReplaceGraphics(edit, candidates: matched, label: base)] }
        return parts.enumerated().map { index, nodes in ReplaceGraphics(edit, candidates: nodes, label: "\(base) (\(index + 1)/\(parts.count))") }
    }
}
