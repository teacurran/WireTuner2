import WTCRDT
import WTGeometry
import WTProto

// ATTR-020, the half ATTR-013/ATTR-017 left: the lens Snapshot command (fill-attributes.adoc,
// "Merge semantics", Snapshot) and Paste In as a command.  The capture and expansion of a tile
// (`Subtrees.tile`, `Subtrees.payload`) and the lens-type change (`EditAttribute.lensType`) were
// built with the fill editors.

/// Why a lens could not be frozen.
public enum LensSnapshotError: Error, Equatable, Sendable {
    /// The row is not a lens fill of the node.
    case notALens
    /// More than 20,000 nodes or a node over 2 MiB beneath the lens: refused, never truncated.
    case tooLarge

    public var message: String {
        switch self {
        case .notALens: "Snapshot applies to a lens fill."
        case .tooLarge: "There is too much artwork under this lens to freeze."
        }
    }
}

/// What a lens shows, captured as a `Subtree` (fill-attributes.adoc, "Lens"; the backdrop as
/// LensRendering draws it).
public enum LensSnapshots {
    /// The kinds a snapshot carries: what `SubtreeRendering` draws.  Text, images and placed files
    /// beneath the lens are left out of the picture (they cannot be drawn from a `Subtree`).
    static let drawable: Set<NodeKind> = [.path, .rect, .ellipse, .polygon, .group]

    /// The artwork beneath lens object `lens`: every live object on a visible layer drawn before it
    /// -- earlier layers, earlier siblings, and earlier siblings of each group holding it -- whose
    /// bounds meet the lens's, as detached copies in the lens's own coordinates (ids stripped, each
    /// root's transform mapping it into the lens object's space), parents before children.
    public static func capture(lens: OpID, in state: EngineState) throws(LensSnapshotError) -> Wiretuner_Doc_V1_Subtree {
        try capture(lens: lens, in: state, maximumNodes: Subtrees.maximumNodes, maximumNodeBytes: Subtrees.maximumNodeBytes)
    }

    /// `capture(lens:in:)` under the given limits.
    static func capture(lens: OpID, in state: EngineState, maximumNodes: Int, maximumNodeBytes: Int) throws(LensSnapshotError) -> Wiretuner_Doc_V1_Subtree {
        guard let area = Objects.bounds(of: lens, in: state) else { return Wiretuner_Doc_V1_Subtree() }
        let toLens = Objects.pasteboardTransform(of: lens, in: state).inverted() ?? .identity
        var ancestors: Set<OpID> = []
        var current = Objects.parent(of: lens, in: state)
        while let id = current, id != WellKnown.layers {
            ancestors.insert(id)
            current = Objects.parent(of: id, in: state)
        }
        var subtree = Wiretuner_Doc_V1_Subtree()
        var reached = false
        func add(_ tree: NodeTree, parent: Int32) throws(LensSnapshotError) {
            guard let kind = tree.kind, drawable.contains(kind) else { return }
            guard subtree.nodes.count < maximumNodes else { throw .tooLarge }
            var node = Wiretuner_Doc_V1_SubtreeNode()
            node.parent = parent
            node.props = (try? tree.props.serializedData()) ?? .init()
            guard node.props.count <= maximumNodeBytes else { throw .tooLarge }
            subtree.nodes.append(node)
            let index = Int32(subtree.nodes.count - 1)
            for child in tree.children { try add(child, parent: index) }
        }
        func visit(_ node: OpID) throws(LensSnapshotError) {
            guard !reached else { return }
            if node == lens {
                reached = true
            } else if ancestors.contains(node) {
                for child in state.liveChildren(node) { try visit(child) }
            } else if Objects.isObject(node, in: state), let bounds = Objects.bounds(of: node, in: state), bounds.intersects(area) {
                var tree = NodeTree(node, state: state)
                tree.transform = Objects.pasteboardTransform(of: node, in: state).concatenating(toLens)
                try add(tree, parent: -1)
            }
        }
        let order = LayerOrder(state)
        for layer in order.layers where layer.visible && !reached {
            for object in order.objects(on: layer.id, in: state) { try visit(object) }
        }
        return subtree
    }
}

/// btn:[Snapshot] on a lens fill: `snapshot = true` and `snapshot_contents` -- what the lens
/// shows now (`LensSnapshots.capture`) -- written together in one change for each row, so two
/// concurrent snapshots each stay a complete picture and the later wins.  Turning Snapshot off is
/// ATTR-013's `EditAttribute` (the flag, with the contents cleared).  Labelled "Snapshot".
public struct SnapshotLens: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]

    public init(_ rows: [(node: OpID, row: AppearanceRow)]) {
        self.rows = rows
    }

    public var label: String { fannedLabel("Snapshot", count: rows.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (node, row) in rows {
            let owner = try AppearanceEditing.owner(node, row, in: state)
            guard row.list == .fills, AttributeEntry.read(node, row, owner: owner, state: state).fill.settings.kind == .lens else {
                throw LensSnapshotError.notALens
            }
            let contents = try LensSnapshots.capture(lens: node, in: state)
            try EditAttribute.fill([(node, row)], "Snapshot", [AttributeFields.Lens.snapshot, AttributeFields.Lens.snapshotContents]) {
                $0.lens.snapshot = true
                $0.lens.snapshotContents = contents
            }.execute(&builder, state: state)
        }
    }
}

extension EditAttribute {
    /// btn:[Paste In] on a tiled fill: the pasteboard's objects captured as the tile
    /// (`Subtrees.tile`, which refuses what a tile may not hold) and written to `tile` whole
    /// (ATOMIC).  Copy Out reads only (`Subtrees.payload`).  Labelled "Paste In".
    public static func pasteIn(_ rows: [(node: OpID, row: AppearanceRow)], _ payload: ClipboardPayload) throws(PasteInError) -> EditAttribute {
        let tile = try Subtrees.tile(from: payload)
        return fill(rows, "Paste In", [AttributeFields.Tiled.tile]) { $0.tiled.tile = tile }
    }
}
