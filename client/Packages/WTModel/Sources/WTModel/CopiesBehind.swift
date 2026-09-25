import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// The Smudge and Shadow tools' change (path-effects.adoc, "Smudging" and "Adding a drop shadow
/// with the Shadow tool"; FX-033): each object gets copies of itself behind it, each moved by its
/// own pasteboard-space matrix and recoloured, and the copies and the object are grouped in the
/// object's place -- `CreateNode(group)`, the copies created in it bottom first, `MoveNode` of the
/// object to its top.  A concurrent delete of the object leaves the copies (reviewed as
/// edit-vs-delete); a concurrent move of it follows the move ordering (the group may end up holding
/// only the copies).
public struct CopiesBehind: Command {
    /// What a copy's basic fills or strokes become.  Gradients, patterns and other kinds keep their
    /// settings.
    public enum Paint: Hashable, Sendable {
        /// As the object has it.
        case keep
        /// *None*.
        case none
        /// The object's own colour moved `amount` (0...1) of the way to `color`, in process CMYK
        /// (a spot or RGB colour gives a process intermediate); *None* stays *None*.
        case toward(Color, amount: Double)
        /// The first paint, then the second over its result (a shadow's tint faded toward *Fade to*).
        indirect case then(Paint, Paint)
    }

    /// One copy.
    public struct Copy: Hashable, Sendable {
        /// Pasteboard space: applied after the object's own placement.
        public var matrix: AffineTransform
        public var fill: Paint
        public var stroke: Paint

        public init(matrix: AffineTransform, fill: Paint = .keep, stroke: Paint = .keep) {
            self.matrix = matrix
            self.fill = fill
            self.stroke = stroke
        }
    }

    public var copies: [(node: OpID, copies: [Copy])]
    public var label: String

    public init(_ label: String, copies: [(node: OpID, copies: [Copy])]) {
        self.label = label
        self.copies = copies
    }

    /// How many objects the change creates: each copy's whole subtree (the Smudge cap counts
    /// these, nested objects included).
    public static func objectCount(_ node: OpID, copies: Int, in state: EngineState) -> Int {
        func count(_ node: OpID) -> Int { 1 + state.liveChildren(node).map(count).reduce(0, +) }
        return count(node) * copies
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let resolver = ColorResolver(state)
        let lists = Dictionary(copies.map { ($0.node, $0.copies) }, uniquingKeysWith: { first, _ in first })
        for node in Objects.stackingOrder(Objects.editable(lists.keys.filter { Objects.isObject($0, in: state) }, in: state), in: state) {
            guard let list = lists[node], !list.isEmpty, let parent = Objects.parent(of: node, in: state) else { continue }
            let toPasteboard = Objects.pasteboardTransform(ofSpace: parent, in: state)
            let fromPasteboard = toPasteboard.inverse
            var props = Wiretuner_Doc_V1_NodeProps()
            props.group.kind = .group
            let slot = try Arranging.keys(next: node, above: true, count: 1, in: state)[0]
            let group = builder.append(Ops.create(parent: parent, position: slot, props: props))
            let keys = try PathEditing.keys(between: nil, and: nil, count: list.count + 1)
            for (copy, key) in zip(list, keys) {
                var tree = NodeTree(node, state: state)
                tree.transform = tree.transform.concatenating(toPasteboard).concatenating(copy.matrix).concatenating(fromPasteboard)
                tree.transformConnectors(by: copy.matrix)
                Self.recolor(&tree, fill: copy.fill, stroke: copy.stroke, resolver: resolver)
                try NodeCopier.create(tree, parent: group, position: key, schema: state.schema, builder: &builder)
            }
            builder.append(Ops.move(node, parent: group, position: keys[list.count]))
        }
    }

    /// `tree` and every node under it with their basic fills and strokes painted.
    static func recolor(_ tree: inout NodeTree, fill: Paint, stroke: Paint, resolver: ColorResolver) {
        if let kind = tree.kind, var appearance = NodeValues.appearance(tree.props) {
            for index in appearance.fills.indices where [.basic, .unspecified].contains(appearance.fills[index].settings.kind) {
                appearance.fills[index].settings.basic.color = painted(appearance.fills[index].settings.basic.color, fill, resolver: resolver)
            }
            for index in appearance.strokes.indices where [.basic, .unspecified].contains(appearance.strokes[index].settings.kind) {
                appearance.strokes[index].settings.basic.color = painted(appearance.strokes[index].settings.basic.color, stroke, resolver: resolver)
            }
            tree.props = NodeValues.replacing(appearance, of: kind, in: tree.props)
        }
        for index in tree.children.indices {
            recolor(&tree.children[index], fill: fill, stroke: stroke, resolver: resolver)
        }
    }

    /// `ref` painted by `paint`: *None* reads as nothing to move.
    static func painted(_ ref: Wiretuner_Doc_V1_ColorRef, _ paint: Paint, resolver: ColorResolver) -> Wiretuner_Doc_V1_ColorRef {
        switch paint {
        case .keep: return ref
        case .none: return .with { $0.none = true }
        case .toward(let target, let amount):
            guard let color = resolver.color(ref) else { return ref }
            return ColorResolver.inline(mix(color, target, amount: amount))
        case .then(let first, let second):
            return painted(painted(ref, first, resolver: resolver), second, resolver: resolver)
        }
    }

    /// `a` moved `amount` of the way to `b` in process CMYK (an end stays in its own space).
    public static func mix(_ a: Color, _ b: Color, amount: Double) -> Color {
        let t = min(max(amount, 0), 1)
        if t == 0, a.spot == nil { return a }
        if t == 1, b.spot == nil { return b }
        let from = a.converted(to: .cmyk), to = b.converted(to: .cmyk)
        let components = from.components + (to.components - from.components) * t
        return Color(space: .cmyk, components: components, alpha: from.alpha + (to.alpha - from.alpha) * t)
    }
}
