import WTCRDT
import WTGeometry
import WTProto

/// kbd:[Option]-drag of a grid line with the Perspective tool (perspective.adoc, "To make a new grid
/// by dragging"; FX-043): a copy of the page's grid, named in sequence ("Grid 2"), becomes the
/// page's grid with the dragged registers written on it; the original is kept, unchanged, in
/// Define Grids.  One change, labelled "Define grid".
public struct ForkGrid: Command {
    public var edit: EditGrid
    public var page: OpID

    public init(_ edit: EditGrid, page: OpID) {
        self.edit = edit
        self.page = page
    }

    public var label: String { "Define grid" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let source = try PerspectiveEditing.liveGrid(edit.grid, in: state)
        guard !edit.fields.contains(.name) else { throw PerspectiveError.invalidValue("name") }
        var grid = source.stored
        grid.name = PerspectiveReading.unusedName(source.name.isEmpty ? "Grid" : source.name, in: state)
        let copy = try PerspectiveEditing.insert(grid, in: state, builder: &builder)
        try PerspectiveEditing.setPageGrid(page, copy, in: state, builder: &builder)
        guard !edit.fields.isEmpty else { return }
        builder.append(Ops.set(WellKnown.settings, edit.fields.map { PerspectiveFields.grid(copy, $0) }, values: PerspectiveFields.gridValues(edit.values)))
    }
}

/// Moving attached objects with the Pointer tool or the arrow keys (perspective.adoc, "Moving an
/// attached object with the Pointer tool or the arrow keys takes it *off* the grid, keeping its
/// current perspective appearance"; FX-043): each attached object is released with its
/// perspective -- as *Release with Perspective* does -- already moved by `delta`, and the other
/// objects move as `MoveObjects` moves them.  One change, labelled "Move".
public struct MoveOffGrid: Command {
    public var nodes: [OpID]
    public var delta: Vector

    public init(_ nodes: [OpID], by delta: Vector) {
        self.nodes = nodes
        self.delta = delta
    }

    public var label: String { "Move" }

    /// The move of `nodes` by `delta`: this command when one of them is on the grid, else
    /// `MoveObjects`.
    public static func command(_ nodes: [OpID], by delta: Vector, in state: EngineState) -> any Command {
        nodes.contains { PerspectiveReading.wrapper(of: $0, in: state) != nil } ? MoveOffGrid(nodes, by: delta) : MoveObjects(nodes, by: delta)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var flat: [OpID] = []
        var released: Set<OpID> = []
        for node in nodes {
            guard let wrapper = PerspectiveReading.wrapper(of: node, in: state) else {
                flat.append(node)
                continue
            }
            guard released.insert(wrapper).inserted, let parent = Objects.parent(of: wrapper, in: state) else { continue }
            let trees = PerspectiveBaking.item(wrapper, in: state).map { Baking.trees([$0]) } ?? []
            let key = try Arranging.keys(next: wrapper, above: true, count: 1, in: state)[0]
            var props = Wiretuner_Doc_V1_NodeProps()
            props.group.kind = .group
            let toParent = Objects.pasteboardTransform(ofSpace: parent, in: state).inverse
            let placed = AffineTransform.translation(delta).concatenating(toParent)
            if !placed.isIdentity { props.group.common.transform = PathEditing.proto(placed) }
            _ = try NodeCopier.create(NodeTree(props: props, children: trees), parent: parent, position: key, schema: state.schema, builder: &builder)
            builder.append(Ops.setDeleted(wrapper))
        }
        if !flat.isEmpty { try MoveObjects(flat, by: delta).execute(&builder, state: state) }
    }
}
