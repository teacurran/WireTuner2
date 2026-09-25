import WTCRDT
import WTGeometry
import WTProto

// The Find & Replace Graphics panel's btn:[Change] (find-replace.adoc, "Find & Replace tab";
// OBJ-023): `ReplaceGraphics` finds the candidates the attribute's *From* settings match and maps
// each to the register writes of the owning feature's command -- recolour, stroke width,
// halftone, transform, simplify, blend steps, delete -- in one change labelled
// `Replace <attribute> in N objects`.  A replace larger than one change's op limit is split by
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
    /// Every fill, stroke and text colour equal to `from` becomes `to`.
    case color(from: Wiretuner_Doc_V1_ColorRef, to: Wiretuner_Doc_V1_ColorRef)
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

    public enum RemoveTarget: String, Hashable, Sendable, CaseIterable {
        /// Objects with no fill and no stroke (paths and shapes).
        case invisible
        /// Custom halftones.
        case halftones
    }

    /// The attribute's name in the label.
    public var noun: String {
        switch self {
        case .color: "color"
        case .strokeWidth: "stroke width"
        case .remove(.invisible): "invisible objects"
        case .remove(.halftones): "halftones"
        case .rotate: "rotation"
        case .scale: "scale"
        case .simplify: "path points"
        case .blendSteps: "blend steps"
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
        candidates.filter { !commands(edit, for: $0, state: state).isEmpty }
    }

    /// The commands that change `node`, empty when it does not match.
    static func commands(_ edit: GraphicEdit, for node: OpID, state: EngineState) -> [any Command] {
        guard state.isLive(node) else { return [] }
        let entries = AppearanceEditing.entries(node, in: state)
        switch edit {
        case .color(let from, let to):
            var result: [any Command] = []
            let rows = entries.filter { entry in AttributeFields.color(entry).map { ColorMatching.same($0, from) } == true }.map { (node, $0.row) }
            if !rows.isEmpty { result.append(SetAppearanceColor(rows, color: to)) }
            if let text = state.textNode(node) {
                for run in text.runs where run.values.contains(where: { if case .fill(let color)? = $0.value { ColorMatching.same(color, from) } else { false } }) {
                    result.append(ApplyMark(node: node, from: text.anchor(at: run.range.lowerBound), to: text.anchor(at: run.range.upperBound),
                                            value: .with { $0.fill = to }))
                }
            }
            return result
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
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in candidates {
            for command in Self.commands(edit, for: node, state: state) {
                try command.execute(&builder, state: state)
            }
        }
    }

    /// The replace as changes of at most `limit` ops each: one command when it fits, else parts
    /// labelled `... (2/3)`; only matching candidates are kept.
    public static func chunks(_ edit: GraphicEdit, candidates: [OpID], limit: Int = opLimit, in state: EngineState) -> [ReplaceGraphics] {
        let matched = matches(edit, in: candidates, state: state)
        guard !matched.isEmpty else { return [] }
        var parts: [[OpID]] = [[]]
        var count = 0
        for node in matched {
            var scratch = ChangeBuilder(replica: 1, startCounter: 1)
            for command in commands(edit, for: node, state: state) { try? command.execute(&scratch, state: state) }
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
