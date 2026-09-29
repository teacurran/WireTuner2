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

/// A grid handle dragged or double-clicked on the canvas with the Perspective tool (perspective.adoc,
/// "To reshape the grid on the canvas"): the registers `fields` of the page's grid set from `values`,
/// as `EditGrid` (`.edit`), `ForkGrid` (`.fork`, kbd:[Option]) or `CloneOnGrid` (`.clone`,
/// kbd:[Option+Shift]) write them.  While the page uses the built-in grid (`grid` nil) the same
/// change defines it first, as FreeHand lets the default grid be dragged directly: a grid "Grid"
/// holding the built-in geometry of the page with the edit applied is appended and made the page's
/// grid, so objects attached to the built-in grid re-project onto it; `.fork` also keeps the
/// unedited built-in grid ("Grid", the edited copy "Grid 2"), and `.clone` pins the copies of the
/// page's attached objects to it.  One change, labelled `gesture` (`.fork`: "Define grid",
/// `.clone`: "Clone on grid").
public struct ReshapePageGrid: Command {
    public enum Mode: Sendable, Equatable {
        case edit, fork, clone
    }

    public var page: OpID
    public var grid: OpID?
    public var gesture: String
    public var mode: Mode
    public var fields: [PerspectiveFields.GridField]
    public var values: Wiretuner_Doc_V1_PerspectiveGrid

    public init(page: OpID, grid: OpID?, gesture: String, mode: Mode = .edit, fields: [PerspectiveFields.GridField],
                _ build: (inout Wiretuner_Doc_V1_PerspectiveGrid) -> Void) {
        self.page = page
        self.grid = grid
        self.gesture = gesture
        self.mode = mode
        self.fields = fields
        var values = Wiretuner_Doc_V1_PerspectiveGrid()
        build(&values)
        self.values = values
    }

    public var label: String {
        switch mode {
        case .edit: gesture
        case .fork: "Define grid"
        case .clone: "Clone on grid"
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !fields.contains(.name) else { throw PerspectiveError.invalidValue("name") }
        if let grid {
            let edit = EditGrid(grid, label: gesture, fields: fields) { $0 = values }
            switch mode {
            case .edit: try edit.execute(&builder, state: state)
            case .fork: try ForkGrid(edit, page: page).execute(&builder, state: state)
            case .clone: try CloneOnGrid(edit).execute(&builder, state: state)
            }
            return
        }
        let pages = PageList(state)
        let current = try PageEditing.page(page, in: pages)
        let name = PerspectiveReading.unusedName("Grid", in: state)
        let builtIn = PerspectiveReading.defaultGrid(name: name, page: current.rect)
        var edited = builtIn
        Self.assign(fields, from: values, to: &edited)
        // The attached objects that follow the built-in grid on this page, before the change.
        let attached = mode == .clone ? CloneOnGrid.wrappers(on: nil, in: state).filter { PerspectiveReading.page(of: $0, in: state).id == current.id } : []
        var inserted: [Wiretuner_Doc_V1_PerspectiveGrid] = []
        switch mode {
        case .edit:
            inserted = [edited]
        case .fork:
            edited.name = Self.nextName(after: name, in: state)
            inserted = [builtIn, edited]
        case .clone:
            var pinned = builtIn
            pinned.name = Self.nextName(after: name, in: state)
            inserted = [edited, pinned]
        }
        let ids = try PerspectiveEditing.insert(inserted, in: state, builder: &builder)
        let used = mode == .fork ? ids[1] : ids[0]
        try PerspectiveEditing.setPageGrid(current.id, used, in: state, builder: &builder)
        guard mode == .clone else { return }
        var props = Wiretuner_Doc_V1_PerspectiveProps()
        props.grid = ids[1].elementID
        for wrapper in attached {
            let parent = Objects.parent(of: wrapper, in: state)!
            let key = try Arranging.keys(next: wrapper, above: true, count: 1, in: state)[0]
            let clone = try NodeCopier.create(NodeTree(wrapper, state: state), parent: parent, position: key, schema: state.schema, builder: &builder)
            builder.append(Ops.set(clone, [PerspectiveFields.grid], values: PerspectiveFields.values(props)))
        }
    }

    /// The name after `name` in sequence that no grid has ("Grid" → "Grid 2").
    static func nextName(after name: String, in state: EngineState) -> String {
        let names = Set(PerspectiveReading.grids(state).map(\.name) + [name])
        var number = 2
        while names.contains("Grid \(number)") { number += 1 }
        return "Grid \(number)"
    }

    /// Copies the registers `fields` of `values` onto `grid`.
    public static func assign(_ fields: [PerspectiveFields.GridField], from values: Wiretuner_Doc_V1_PerspectiveGrid, to grid: inout Wiretuner_Doc_V1_PerspectiveGrid) {
        for field in fields {
            switch field {
            case .name: grid.name = values.name
            case .vanishingPoints: grid.vanishingPoints = values.vanishingPoints
            case .cellSize: grid.cellSize = values.cellSize
            case .horizonY: grid.horizonY = values.horizonY
            case .leftVP: grid.leftVp = values.leftVp
            case .rightVP: grid.rightVp = values.rightVp
            case .verticalVP: grid.verticalVp = values.verticalVp
            case .leftWallX: grid.leftWallX = values.leftWallX
            case .rightWallX: grid.rightWallX = values.rightWallX
            case .floorFrontY: grid.floorFrontY = values.floorFrontY
            case .leftColor: grid.leftColor = values.leftColor
            case .rightColor: grid.rightColor = values.rightColor
            case .floorColor: grid.floorColor = values.floorColor
            case .leftHidden: grid.leftHidden = values.leftHidden
            case .rightHidden: grid.rightHidden = values.rightHidden
            case .floorHidden: grid.floorHidden = values.floorHidden
            }
        }
    }
}
