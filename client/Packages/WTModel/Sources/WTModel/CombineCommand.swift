import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// menu:Modify[Combine] > Union, Divide, Intersect, Punch and Crop (OBJ-025, combining-paths.adoc)
/// over GEO-002's `Boolean`.  The inputs -- paths, rectangles, ellipses and polygons, unlocked --
/// are flattened to pasteboard space through their transform chains; every result is a fresh
/// path node with the identity transform whose contours are in its parent's space (pasteboard
/// space on a layer), created at the frontmost input's slot under its parent, carrying a copy of
/// the attribute stack it inherits under fresh element ids.  Results are normalized regions
/// (non-crossing contours, non-zero rule), so *Even/odd fill* is off on each.
///
/// * *Union*: one path covering everything, with the backmost input's attributes.
/// * *Divide*: a fresh group of one path per region, each with the attributes of the frontmost
///   input covering it; open inputs count as closed by their chord.
/// * *Intersect*: one path of the area common to all, with the backmost's attributes; when there
///   is none, nothing is created and the inputs are still consumed.
/// * *Punch* / *Crop*: the frontmost input is the cutter; each input below becomes a path of
///   itself minus (Punch) or trimmed to (Crop) the cutter, keeping its attributes; a target that
///   comes back empty makes nothing.  The cutter is consumed with the targets.
///
/// Unless `keepOriginals`, every input is then `SetDeleted(true)`: one change "Union 3 paths"
/// (combining-paths.adoc, "Merge semantics").  Kept originals stay where they were, under the
/// results.  Too few usable inputs, or open inputs to an operation that needs closed ones: no
/// change.
public struct CombineCommand: Command {
    public enum Operation: String, Hashable, Sendable, CaseIterable {
        case union, divide, intersect, punch, crop

        /// The menu item and the change label's verb.
        public var title: String {
            switch self {
            case .union: "Union"
            case .divide: "Divide"
            case .intersect: "Intersect"
            case .punch: "Punch"
            case .crop: "Crop"
            }
        }

        /// Whether every input must be closed (all but Divide).
        public var needsClosedPaths: Bool { self != .divide }
    }

    public var operation: Operation
    public var nodes: [OpID]
    public var keepOriginals: Bool

    public init(_ operation: Operation, _ nodes: [OpID], keepOriginals: Bool = false) {
        self.operation = operation
        self.nodes = nodes
        self.keepOriginals = keepOriginals
    }

    public var label: String { "\(operation.title) \(nodes.count) paths" }

    /// The kinds the operations take.
    public static let kinds: Set<NodeKind> = [.path, .rect, .ellipse, .polygon]

    /// Whether this use keeps the originals: *Path operations consume original paths* inverted by
    /// kbd:[Shift] (combining-paths.adoc, "Keeping the originals").
    public static func keepsOriginals(consumePreference: Bool, shift: Bool) -> Bool {
        consumePreference == shift
    }

    /// The menu item's title: "Union", or "Union (keep originals)" when this use keeps them.
    public static func title(_ operation: Operation, keepOriginals: Bool) -> String {
        keepOriginals ? "\(operation.title) (keep originals)" : operation.title
    }

    /// The inputs of `nodes` the operation would use, bottom first; empty when the item is
    /// disabled (fewer than two, or an open input to an operation needing closed ones).
    public static func inputs(_ operation: Operation, _ nodes: [OpID], in state: EngineState) -> [OpID] {
        let inputs = Objects.stackingOrder(Objects.editable(nodes, in: state).filter { node in
            state.nodeKind(node).map(kinds.contains) == true && (Objects.localPath(node, in: state)?.isRenderable ?? false)
        }, in: state)
        guard inputs.count >= 2 else { return [] }
        if operation.needsClosedPaths, !inputs.allSatisfy({ isClosed($0, in: state) }) { return [] }
        return inputs
    }

    /// Whether the menu item is enabled for the selection.
    public static func canPerform(_ operation: Operation, _ nodes: [OpID], in state: EngineState) -> Bool {
        !inputs(operation, nodes, in: state).isEmpty
    }

    /// Whether every renderable contour of the input is closed.
    static func isClosed(_ node: OpID, in state: EngineState) -> Bool {
        Objects.localPath(node, in: state)!.contours.allSatisfy { !$0.isRenderable || $0.closed }
    }

    /// The input's filled region in pasteboard space, under its own fill rule.
    static func region(_ node: OpID, in state: EngineState) -> FilledPath {
        let path = Objects.localPath(node, in: state)!
        let display = DocumentDisplayListBuilder.display(path) { $0.isRenderable }.path
        return FilledPath(contours: display.contours, fillRule: path.evenOdd ? .evenOdd : .nonZero)
            .applying(Objects.pasteboardTransform(of: node, in: state))
    }

    /// One result to create: its region and whose attributes it takes.
    struct Piece {
        var region: FilledPath
        var attributes: OpID
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let inputs = Self.inputs(operation, nodes, in: state)
        guard let backmost = inputs.first, let frontmost = inputs.last, let parent = Objects.parent(of: frontmost, in: state) else { return }
        let regions = inputs.map { Self.region($0, in: state) }
        var pieces: [Piece] = []
        switch operation {
        case .union:
            pieces = [Piece(region: Boolean.union(regions), attributes: backmost)]
        case .intersect:
            pieces = [Piece(region: Boolean.intersection(regions), attributes: backmost)]
        case .punch, .crop:
            let cutter = regions.last!
            let targets = Array(regions.dropLast())
            let cut = operation == .punch ? Boolean.punch(targets, with: cutter) : Boolean.crop(targets, with: cutter)
            pieces = zip(cut, inputs).map { Piece(region: $0, attributes: $1) }
        case .divide:
            // Pieces of front inputs stack above pieces of back ones (stable within an input).
            let divided = Boolean.divide(regions).enumerated().sorted { lhs, rhs in
                let l = lhs.element.operands.last!, r = rhs.element.operands.last!
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            pieces = divided.map { Piece(region: $0.element.path, attributes: inputs[$0.element.operands.last!]) }
        }
        pieces.removeAll { $0.region.isEmpty }
        let toParent = Objects.pasteboardTransform(ofSpace: parent, in: state).inverse
        if operation == .divide, !pieces.isEmpty {
            let key = try Arranging.keys(next: frontmost, above: true, count: 1, in: state)[0]
            var props = Wiretuner_Doc_V1_NodeProps()
            props.group.kind = .group
            let group = builder.append(Ops.create(parent: parent, position: key, props: props))
            let keys = try PathEditing.keys(between: nil, and: nil, count: pieces.count)
            for (piece, key) in zip(pieces, keys) {
                try Self.create(piece, parent: group, position: key, toParent: toParent, state: state, builder: &builder)
            }
        } else if !pieces.isEmpty {
            let keys = try Arranging.keys(next: frontmost, above: true, count: pieces.count, in: state)
            for (piece, key) in zip(pieces, keys) {
                try Self.create(piece, parent: parent, position: key, toParent: toParent, state: state, builder: &builder)
            }
        }
        guard !keepOriginals else { return }
        for input in inputs {
            builder.append(Ops.setDeleted(input))
        }
    }

    /// Creates `piece` as a path under `parent` with the inherited stack.
    static func create(_ piece: Piece, parent: OpID, position: [UInt8], toParent: AffineTransform, state: EngineState,
                       builder: inout ChangeBuilder) throws {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.path.contours = InlineShapes.contours(DisplayPath(contours: piece.region.applying(toParent).contours))
        let path = try NodeCopier.create(NodeTree(props: props), parent: parent, position: position, schema: state.schema, builder: &builder)
        try PasteAttributes.insert(AttributePayload(copying: piece.attributes, from: state)!.stack!, into: path, kind: .path,
                                   schema: state.schema, builder: &builder)
    }
}
