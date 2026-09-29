import WTCRDT
import WTGeometry
import WTProto
import WTRender

// FX-041: the perspective commands and read-time normalizations (effects/perspective.adoc,
// "Merge semantics", "Read-time normalizations", "Undo").  Grids are elements of
// `SettingsProps.perspective_grids` (91) on the settings node; a page names its grid in
// `PageProps.perspective_grid` (20); an attached object is wrapped in a `perspective` node (kind
// 103) holding its plane and cell placement, the object inside staying flat.
//
// The scene reads the wrapper as `NodeKind.perspective` / `WrapperKind.perspective` and draws it
// through `PerspectiveReading.live` and `drawOrder` (`Wrappers`); the reading here goes by the raw
// kind, which is the same number.

/// Register paths of the perspective schema.
public enum PerspectiveFields {
    /// `NodeProps.perspective`.
    public static let kind: UInt32 = 103
    public static let common = RegisterPath([kind, 1])
    public static let transform = RegisterPath([kind, 1, 4])
    public static let plane = RegisterPath([kind, 2])
    public static let cellPosition = RegisterPath([kind, 3])
    public static let cellWidth = RegisterPath([kind, 4])
    public static let cellHeight = RegisterPath([kind, 5])
    public static let flipped = RegisterPath([kind, 6])
    public static let grid = RegisterPath([kind, 7])
    /// `SettingsProps.perspective_grids`.
    public static let grids = RegisterPath([SettingsFields.kind, 91])
    /// `PageProps.perspective_grid`.
    public static let pageGrid = RegisterPath([PageFields.kind, 20])

    /// A `PerspectiveGrid` field, by number.
    public enum GridField: UInt32, CaseIterable, Sendable {
        case name = 2, vanishingPoints, cellSize, horizonY, leftVP, rightVP, verticalVP, leftWallX, rightWallX, floorFrontY
        case leftColor, rightColor, floorColor, leftHidden, rightHidden, floorHidden
    }

    /// Field `field` of grid element `id`.
    public static func grid(_ id: OpID, _ field: GridField) -> RegisterPath { grids.element(id).child(field.rawValue) }

    /// The longest grid name.
    public static let maxName = 64

    static func values(_ props: Wiretuner_Doc_V1_PerspectiveProps) -> Wiretuner_Doc_V1_NodeProps {
        var values = Wiretuner_Doc_V1_NodeProps()
        values.perspective = props
        return values
    }

    static func gridValues(_ grid: Wiretuner_Doc_V1_PerspectiveGrid) -> Wiretuner_Doc_V1_NodeProps {
        SettingsFields.values { $0.perspectiveGrids = [grid] }
    }
}

/// Why a perspective command refused.
public enum PerspectiveError: Error, Equatable, Sendable {
    /// Not attached to a grid (not a live `perspective` wrapper nor inside one).
    case notAttached(OpID)
    /// Already on a grid.
    case alreadyAttached(OpID)
    /// Not a live grid of the document.
    case unknownGrid(OpID)
    /// Another grid has this name.
    case duplicateName(String)
    case invalidValue(String)
}

/// One grid of the document as read.
public struct PerspectiveGridInfo: Hashable, Sendable {
    public var id: OpID
    /// The stored name.
    public var name: String
    /// What the Define Grids sheet shows: a name another grid of smaller id also has, with " 2",
    /// " 3" ... appended (duplicates after a merge).
    public var displayName: String
    public var stored: Wiretuner_Doc_V1_PerspectiveGrid
}

/// Reading grids, pages and wrappers (the read-time normalizations).
public enum PerspectiveReading {
    /// Whether `node` is a `perspective` wrapper (live or not).
    public static func isWrapper(_ node: OpID, in state: EngineState) -> Bool {
        state.store.kind(node) == PerspectiveFields.kind
    }

    /// The live wrapper `node` is or lies inside (the nearest).
    public static func wrapper(of node: OpID, in state: EngineState) -> OpID? {
        var current: OpID? = node
        var steps = 0
        while let id = current, steps < 10_000 {
            if isWrapper(id, in: state), state.isEffectivelyLive(id) { return id }
            current = state.store.placement(id)?.parent
            steps += 1
        }
        return nil
    }

    /// The object projected: the live child of the smallest node id; the others draw flat, and a
    /// wrapper without a live child is an empty outline (nil).
    public static func child(_ wrapper: OpID, in state: EngineState) -> OpID? {
        state.liveChildren(wrapper).min()
    }

    /// The document's grids in sequence order.
    public static func grids(_ state: EngineState) -> [PerspectiveGridInfo] {
        let stored = state.props(WellKnown.settings).settings.perspectiveGrids
        var infos = stored.compactMap { grid in OpID(element: grid.id).map { PerspectiveGridInfo(id: $0, name: grid.name, displayName: grid.name, stored: grid) } }
        var byName: [String: [Int]] = [:]
        for (index, info) in infos.enumerated() { byName[info.name, default: []].append(index) }
        for indices in byName.values where indices.count > 1 {
            for (rank, index) in indices.sorted(by: { infos[$0].id < infos[$1].id }).enumerated() where rank > 0 {
                infos[index].displayName = "\(infos[index].name) \(rank + 1)"
            }
        }
        return infos
    }

    /// `id` when it names a live grid, else the default grid: the sequence's first live element,
    /// nil (the built-in two-point grid) when there is none.
    public static func resolve(_ id: OpID?, in state: EngineState) -> OpID? {
        let live = state.liveElements(WellKnown.settings, PerspectiveFields.grids)
        if let id, live.contains(id) { return id }
        return live.first
    }

    /// The grid `page` uses (its register, dangling or unset reading as the default).
    public static func grid(of page: Page, in state: EngineState) -> OpID? {
        guard !page.isSynthesized else { return resolve(nil, in: state) }
        return resolve(OpID(element: state.props(page.id).page.perspectiveGrid), in: state)
    }

    /// The page an attached object is drawn on: the one holding the centre of its flat child's
    /// bounds, else the first page.
    public static func page(of wrapper: OpID, in state: EngineState) -> Page {
        let pages = PageList(state)
        let bounds = child(wrapper, in: state).flatMap { Objects.bounds(of: $0, in: state) }
        return bounds.flatMap { pages.page(ofBounds: $0) } ?? pages.pages[0]
    }

    /// Page coordinates (points from the page's bottom-left, y up) → pasteboard (y down).
    static func pasteboard(_ point: Wiretuner_Doc_V1_Point, page: Rect) -> Point {
        Point(x: page.minX + point.x, y: page.maxY - point.y)
    }

    /// Pasteboard → page coordinates.
    static func pageCoordinates(_ point: Point, page: Rect) -> Wiretuner_Doc_V1_Point {
        var value = Wiretuner_Doc_V1_Point()
        value.x = point.x - page.minX
        value.y = page.maxY - point.y
        return value
    }

    /// Grid `id` (nil: the built-in default) resolved for a page with rectangle `page`.
    public static func spec(grid id: OpID?, page: Rect, in state: EngineState) -> PerspectiveGridSpec {
        guard let id, let grid = grids(state).first(where: { $0.id == id })?.stored else { return PerspectiveGridSpec.defaultGrid(page: page) }
        return spec(stored: grid, page: page)
    }

    /// Stored grid `grid` (page coordinates) resolved for a page with rectangle `page`.
    public static func spec(stored grid: Wiretuner_Doc_V1_PerspectiveGrid, page: Rect) -> PerspectiveGridSpec {
        PerspectiveGridSpec(
            vanishingPoints: Int(grid.vanishingPoints), cellSize: grid.cellSize, horizonY: page.maxY - grid.horizonY,
            leftVP: pasteboard(grid.leftVp, page: page), rightVP: pasteboard(grid.rightVp, page: page), verticalVP: pasteboard(grid.verticalVp, page: page),
            leftWallX: page.minX + grid.leftWallX, rightWallX: page.minX + grid.rightWallX, floorFrontY: page.maxY - grid.floorFrontY
        )
    }

    /// The built-in two-point grid of a page, as stored geometry in page coordinates.
    public static func defaultGrid(name: String, page: Rect) -> Wiretuner_Doc_V1_PerspectiveGrid {
        let spec = PerspectiveGridSpec.defaultGrid(page: page)
        var grid = Wiretuner_Doc_V1_PerspectiveGrid()
        grid.name = name
        grid.vanishingPoints = UInt32(spec.vanishingPoints)
        grid.cellSize = spec.cellSize
        grid.horizonY = page.maxY - spec.horizonY
        grid.leftVp = pageCoordinates(spec.leftVP, page: page)
        grid.rightVp = pageCoordinates(spec.rightVP, page: page)
        grid.verticalVp = pageCoordinates(spec.verticalVP, page: page)
        grid.leftWallX = spec.leftWallX - page.minX
        grid.rightWallX = spec.rightWallX - page.minX
        grid.floorFrontY = page.maxY - spec.floorFrontY
        return grid
    }

    /// The stored plane as the projector names it; unspecified or unknown reads as the left wall
    /// (the projector maps walls and floors across one- and multi-point grids).
    static func plane(_ plane: Wiretuner_Doc_V1_PerspectivePlane) -> PerspectiveSpec.Plane {
        switch plane {
        case .rightWall: .rightWall
        case .floorLeft: .floorLeft
        case .floorRight: .floorRight
        case .wall: .wall
        case .floor: .floor
        default: .leftWall
        }
    }

    /// The grid wrapper `wrapper` projects onto: its own `grid` when live, else its page's.
    public static func grid(ofWrapper wrapper: OpID, in state: EngineState) -> OpID? {
        let stored = OpID(element: state.props(wrapper).perspective.grid)
        let live = state.liveElements(WellKnown.settings, PerspectiveFields.grids)
        if let stored, live.contains(stored) { return stored }
        return grid(of: page(of: wrapper, in: state), in: state)
    }

    /// `PerspectiveProps` of `wrapper` resolved against its grid and page.
    public static func spec(_ wrapper: OpID, in state: EngineState) -> PerspectiveSpec {
        let props = state.props(wrapper).perspective
        let page = page(of: wrapper, in: state)
        let grid = spec(grid: grid(ofWrapper: wrapper, in: state), page: page.rect, in: state)
        return PerspectiveSpec(grid: grid, plane: plane(props.plane), cellPosition: Point(x: props.cellPosition.x, y: props.cellPosition.y),
                               cellWidth: props.cellWidth, cellHeight: props.cellHeight, flipped: props.flipped)
    }

    /// What the scene draws for wrapper `wrapper`: a group whose first child is the projected
    /// object (the scene hook's `LiveGroup`).
    public static func live(_ wrapper: OpID, in state: EngineState) -> LiveGroup {
        .perspective(spec(wrapper, in: state))
    }

    /// The drawn order of the wrapper's children: the projected one first, the others flat after
    /// it in sibling order.
    public static func drawOrder(_ wrapper: OpID, in state: EngineState) -> [OpID] {
        let children = state.liveChildren(wrapper)
        guard let first = children.min() else { return [] }
        return [first] + children.filter { $0 != first }
    }

    /// A name no grid has: `base`, else "`base` 2", "`base` 3" ...
    public static func unusedName(_ base: String, in state: EngineState) -> String {
        let names = Set(grids(state).map(\.name))
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}

/// Shared by the perspective commands.
enum PerspectiveEditing {
    /// The distinct live wrappers `nodes` are or lie inside, or throws for one that is not attached.
    static func wrappers(_ nodes: [OpID], in state: EngineState) throws -> [OpID] {
        var seen: Set<OpID> = []
        return try nodes.map { node in
            guard let wrapper = PerspectiveReading.wrapper(of: node, in: state) else { throw PerspectiveError.notAttached(node) }
            return wrapper
        }.filter { seen.insert($0).inserted }
    }

    static func checkName(_ name: String, except: OpID? = nil, in state: EngineState) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= PerspectiveFields.maxName else { throw PerspectiveError.invalidValue("name") }
        guard !PerspectiveReading.grids(state).contains(where: { $0.name == trimmed && $0.id != except }) else { throw PerspectiveError.duplicateName(trimmed) }
        return trimmed
    }

    static func liveGrid(_ id: OpID, in state: EngineState) throws -> PerspectiveGridInfo {
        guard let grid = PerspectiveReading.grids(state).first(where: { $0.id == id }) else { throw PerspectiveError.unknownGrid(id) }
        return grid
    }

    /// Appends grid `grid` (its id cleared) after the last element; returns its id.
    static func insert(_ grid: Wiretuner_Doc_V1_PerspectiveGrid, in state: EngineState, builder: inout ChangeBuilder) throws -> OpID {
        try insert([grid], in: state, builder: &builder)[0]
    }

    /// Appends `grids` (ids cleared), in order, after the last element; returns their ids.
    static func insert(_ grids: [Wiretuner_Doc_V1_PerspectiveGrid], in state: EngineState, builder: inout ChangeBuilder) throws -> [OpID] {
        let path = PerspectiveFields.grids
        let last = state.store.elementOrder(WellKnown.settings, path).last.flatMap { state.position(WellKnown.settings, path, $0) }
        let keys = try PathEditing.keys(between: last, and: nil, count: grids.count)
        return zip(grids, keys).map { grid, key in
            var element = grid
            element.clearID()
            return builder.append(Ops.elementInsert(WellKnown.settings, path, positions: [key], values: PerspectiveFields.gridValues(element)))
        }
    }

    /// Points `page` at grid `grid` (nil: unset, the default), materializing a synthesized page.
    static func setPageGrid(_ page: OpID, _ grid: OpID?, in state: EngineState, builder: inout ChangeBuilder) throws {
        let list = PageList(state)
        let current = try PageEditing.page(page, in: list)
        let node = try PageEditing.materialize(current.id, in: list, builder: &builder)
        var values = Wiretuner_Doc_V1_NodeProps()
        if let grid { values.page.perspectiveGrid = grid.elementID } else { values.page = Wiretuner_Doc_V1_PageProps() }
        builder.append(Ops.set(node, [PerspectiveFields.pageGrid], values: values))
    }

    /// The wrapper's cell size, a width or height of 0 or less read as the child's flat size in
    /// cells.
    static func cellSize(_ wrapper: OpID, in state: EngineState) -> (width: Double, height: Double) {
        let props = state.props(wrapper).perspective
        let cell = PerspectiveReading.spec(wrapper, in: state).grid.effectiveCellSize
        let flat = PerspectiveReading.child(wrapper, in: state).flatMap { Objects.bounds(of: $0, in: state) } ?? Rect(x: 0, y: 0, width: cell, height: cell)
        return (props.cellWidth > 0 ? props.cellWidth : flat.width / cell, props.cellHeight > 0 ? props.cellHeight : flat.height / cell)
    }
}

// MARK: - Objects on the grid

/// Attaching objects to the grid (the Perspective tool's release with a plane chosen): each
/// selected object wrapped, at its slot, in a `perspective` node with the plane, the cell
/// placement and the grid its page uses, and moved inside -- one change labelled "Attach to
/// perspective grid".  A width or height of 0 reads the object's flat size in cells; `flipped`
/// is kbd:[Space] pressed before the release.
public struct AttachToPerspectiveGrid: Command {
    public var nodes: [OpID]
    public var plane: Wiretuner_Doc_V1_PerspectivePlane
    public var cellPosition: Point
    public var cellWidth: Double
    public var cellHeight: Double
    public var flipped: Bool

    public init(_ nodes: [OpID], plane: Wiretuner_Doc_V1_PerspectivePlane, at cellPosition: Point, cellWidth: Double = 0, cellHeight: Double = 0,
                flipped: Bool = false) {
        self.nodes = nodes
        self.plane = plane
        self.cellPosition = cellPosition
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.flipped = flipped
    }

    public var label: String { "Attach to perspective grid" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard cellPosition.isFinite, cellWidth.isFinite, cellHeight.isFinite else { throw PerspectiveError.invalidValue("cell") }
        for node in Objects.editable(nodes, in: state) {
            guard PerspectiveReading.wrapper(of: node, in: state) == nil else { throw PerspectiveError.alreadyAttached(node) }
            let parent = Objects.parent(of: node, in: state)!
            let pages = PageList(state)
            let page = Objects.bounds(of: node, in: state).flatMap { pages.page(ofBounds: $0) } ?? pages.pages[0]
            var props = Wiretuner_Doc_V1_PerspectiveProps()
            props.plane = plane
            props.cellPosition = PathEditing.proto(cellPosition)
            props.cellWidth = max(cellWidth, 0)
            props.cellHeight = max(cellHeight, 0)
            props.flipped = flipped
            if let grid = PerspectiveReading.grid(of: page, in: state) { props.grid = grid.elementID }
            let key = try Arranging.keys(next: node, above: true, count: 1, in: state)[0]
            let wrapper = builder.append(Ops.create(parent: parent, position: key, props: PerspectiveFields.values(props)))
            builder.append(Ops.move(node, parent: wrapper, position: try PathEditing.keys(between: nil, and: nil, count: 1)[0]))
        }
    }
}

/// A drag with the Perspective tool: each wrapper's `cell_position` (ATOMIC: one drag, the later
/// wins) -- the object stays on its plane.  Keys are the dragged objects or their wrappers.
/// Labelled "Move on grid".
public struct MoveOnGrid: Command {
    public var positions: [OpID: Point]

    public init(_ positions: [OpID: Point]) {
        self.positions = positions
    }

    public var label: String { "Move on grid" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in positions.keys.sorted() {
            let point = positions[node]!
            guard point.isFinite else { throw PerspectiveError.invalidValue("cell_position") }
            let wrapper = try PerspectiveEditing.wrappers([node], in: state)[0]
            var props = Wiretuner_Doc_V1_PerspectiveProps()
            props.cellPosition = PathEditing.proto(point)
            builder.append(Ops.set(wrapper, [PerspectiveFields.cellPosition], values: PerspectiveFields.values(props)))
        }
    }
}

/// kbd:[Space] during a Perspective-tool press: `flipped` toggled on each wrapper.  Labelled
/// "Flip on grid".
public struct FlipOnGrid: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { "Flip on grid" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for wrapper in try PerspectiveEditing.wrappers(nodes, in: state) {
            var props = Wiretuner_Doc_V1_PerspectiveProps()
            props.flipped = !state.props(wrapper).perspective.flipped
            builder.append(Ops.set(wrapper, [PerspectiveFields.flipped], values: PerspectiveFields.values(props)))
        }
    }
}

/// The digit keys during a Perspective-tool press: `width` and `height` cells added to each
/// wrapper's size (negative shrinks; 1 and 2 change both, 3/4 the width, 5/6 the height), an
/// automatic size resolved to the object's flat size first; neither goes below one cell.
/// Labelled "Resize on grid".
public struct ResizeOnGrid: Command {
    public var nodes: [OpID]
    public var width: Int
    public var height: Int

    public init(_ nodes: [OpID], width: Int, height: Int) {
        self.nodes = nodes
        self.width = width
        self.height = height
    }

    public var label: String { "Resize on grid" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for wrapper in try PerspectiveEditing.wrappers(nodes, in: state) {
            let size = PerspectiveEditing.cellSize(wrapper, in: state)
            var props = Wiretuner_Doc_V1_PerspectiveProps()
            var paths: [RegisterPath] = []
            if width != 0 {
                props.cellWidth = max(size.width + Double(width), 1)
                paths.append(PerspectiveFields.cellWidth)
            }
            if height != 0 {
                props.cellHeight = max(size.height + Double(height), 1)
                paths.append(PerspectiveFields.cellHeight)
            }
            if !paths.isEmpty { builder.append(Ops.set(wrapper, paths, values: PerspectiveFields.values(props))) }
        }
    }
}

/// menu:View[Perspective Grid > Remove Perspective]: the flat object (every live child) moves
/// back to the wrapper's slot as it was and the wrapper is deleted; a concurrent edit of the child
/// lands on the freed child.  Labelled "Remove perspective".
public struct RemovePerspective: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { "Remove perspective" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for wrapper in try PerspectiveEditing.wrappers(nodes, in: state) {
            try WrapperEditing.unwrap(wrapper, children: state.liveChildren(wrapper), state: state, builder: &builder)
        }
    }
}

/// menu:View[Perspective Grid > Release with Perspective]: a group of the projected drawing as
/// plain paths (text as its projected glyph outlines) at the wrapper's slot -- baked from this
/// replica's state -- and the wrapper deleted with its child inside, so undo or *Restore* brings
/// the attached object back.  Labelled "Release with perspective".
public struct ReleaseWithPerspective: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { "Release with perspective" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for wrapper in try PerspectiveEditing.wrappers(nodes, in: state) {
            let parent = Objects.parent(of: wrapper, in: state)!
            let trees = PerspectiveBaking.item(wrapper, in: state).map { Baking.trees([$0]) } ?? []
            let key = try Arranging.keys(next: wrapper, above: true, count: 1, in: state)[0]
            try Baking.createGroup(trees, parent: parent, position: key, state: state, builder: &builder)
            builder.append(Ops.setDeleted(wrapper))
        }
    }
}

/// The projected drawing of an attached object.
public enum PerspectiveBaking {
    /// The replica a scratch change is made as (never sent).
    static let scratchReplica = UInt64.max

    /// What wrapper `wrapper` draws: its projected child (and any other children, flat) as a live
    /// perspective group in pasteboard space; nil when it has no live child.  The children are
    /// drawn by the document scene from a scratch copy of the state in which they are unwrapped,
    /// so they draw exactly as they would flat.
    public static func item(_ wrapper: OpID, in state: EngineState) -> DisplayItem? {
        let order = PerspectiveReading.drawOrder(wrapper, in: state)
        guard !order.isEmpty else { return nil }
        var builder = ChangeBuilder(replica: scratchReplica, startCounter: state.clock.peek)
        var scratch = state
        do {
            try WrapperEditing.unwrap(wrapper, children: order, state: state, builder: &builder)
        } catch {
            return nil
        }
        var change = Wiretuner_Doc_V1_Change()
        change.replica = scratchReplica
        change.seq = 1
        change.startCounter = builder.startCounter
        change.ops = builder.ops
        scratch.apply(change)
        var scene = DocumentDisplayListBuilder(canvas: "perspective")
        let built = scene.rebuild(scratch)
        let children = order.compactMap { built.object($0)?.item }
        guard !children.isEmpty else { return nil }
        return .group(GroupItem(children: children, live: PerspectiveReading.live(wrapper, in: state)))
    }
}

// MARK: - Grids

/// btn:[New] and btn:[Duplicate] in Define Grids, and the kbd:[Option]-drag of a grid line: a grid
/// appended with `name` (unique in the document) -- a copy of `source`'s settings, or the
/// built-in two-point grid of `page` -- and, with `usedBy`, that page pointed at it in the same
/// change.  Labelled "Define grid".
public struct DefineGrid: Command {
    public var name: String
    public var source: OpID?
    public var page: OpID?
    public var usedBy: OpID?

    /// `page` sizes the built-in geometry of a new grid (the first page when nil).
    public init(name: String, copying source: OpID? = nil, page: OpID? = nil, usedBy: OpID? = nil) {
        self.name = name
        self.source = source
        self.page = page
        self.usedBy = usedBy
    }

    public var label: String { "Define grid" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let name = try PerspectiveEditing.checkName(self.name, in: state)
        var grid: Wiretuner_Doc_V1_PerspectiveGrid
        if let source {
            grid = try PerspectiveEditing.liveGrid(source, in: state).stored
            grid.name = name
        } else {
            let pages = PageList(state)
            let rect = try page.map { try PageEditing.page($0, in: pages).rect } ?? pages.pages[0].rect
            grid = PerspectiveReading.defaultGrid(name: name, page: rect)
        }
        let id = try PerspectiveEditing.insert(grid, in: state, builder: &builder)
        if let usedBy { try PerspectiveEditing.setPageGrid(usedBy, id, in: state, builder: &builder) }
    }
}

/// btn:[Duplicate] with the name chosen for it: "<name> 2", "<name> 3" ... (the kbd:[Option]-drag
/// grid is "Grid 2").  Labelled "Define grid".
public struct DuplicateGrid: Command {
    public var grid: OpID
    public var usedBy: OpID?

    public init(_ grid: OpID, usedBy: OpID? = nil) {
        self.grid = grid
        self.usedBy = usedBy
    }

    public var label: String { "Define grid" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let source = try PerspectiveEditing.liveGrid(grid, in: state)
        let base = source.name.isEmpty ? "Grid" : source.name
        try DefineGrid(name: PerspectiveReading.unusedName(base, in: state), copying: grid, usedBy: usedBy).execute(&builder, state: state)
    }
}

/// Renaming a grid in Define Grids; a name another grid has is refused.  Labelled "Rename grid".
public struct RenameGrid: Command {
    public var grid: OpID
    public var name: String

    public init(_ grid: OpID, to name: String) {
        self.grid = grid
        self.name = name
    }

    public var label: String { "Rename grid" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try PerspectiveEditing.liveGrid(grid, in: state)
        var element = Wiretuner_Doc_V1_PerspectiveGrid()
        element.name = try PerspectiveEditing.checkName(name, except: grid, in: state)
        builder.append(Ops.set(WellKnown.settings, [PerspectiveFields.grid(grid, .name)], values: PerspectiveFields.gridValues(element)))
    }
}

/// btn:[Delete] in Define Grids: the element deleted.  Pages and objects naming it fall back to
/// the default grid on read; *Restore* in the review re-inserts it.  Labelled "Delete grid".
public struct DeleteGrid: Command {
    public var grid: OpID

    public init(_ grid: OpID) {
        self.grid = grid
    }

    public var label: String { "Delete grid" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try PerspectiveEditing.liveGrid(grid, in: state)
        builder.append(Ops.elementDelete(WellKnown.settings, [PerspectiveFields.grids.element(grid)]))
    }
}

/// Choosing a grid for a page (Define Grids' btn:[OK] with a row selected): the page's
/// `perspective_grid` (nil: unset, the default grid).  Labelled "Set page grid".
public struct SetPageGrid: Command {
    public var page: OpID
    public var grid: OpID?

    public init(_ page: OpID, grid: OpID?) {
        self.page = page
        self.grid = grid
    }

    public var label: String { "Set page grid" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if let grid { _ = try PerspectiveEditing.liveGrid(grid, in: state) }
        try PerspectiveEditing.setPageGrid(page, grid, in: state, builder: &builder)
    }
}

/// Any grid option or geometry edit -- a vanishing point, horizon or edge drag, the hide toggles,
/// Define Grids' fields: the registers `fields` of the grid from `build`.  Every vanishing point is
/// ATOMIC, the other fields their own registers, so different handles dragged at once both keep.
/// `label` names the gesture ("Move vanishing point", "Define grid").
public struct EditGrid: Command {
    public var grid: OpID
    public var fields: [PerspectiveFields.GridField]
    public var values: Wiretuner_Doc_V1_PerspectiveGrid
    public var label: String

    public init(_ grid: OpID, label: String, fields: [PerspectiveFields.GridField], _ build: (inout Wiretuner_Doc_V1_PerspectiveGrid) -> Void) {
        self.grid = grid
        self.label = label
        self.fields = fields
        var values = Wiretuner_Doc_V1_PerspectiveGrid()
        build(&values)
        self.values = values
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try PerspectiveEditing.liveGrid(grid, in: state)
        guard !fields.contains(.name) else { throw PerspectiveError.invalidValue("name") }
        if fields.contains(.vanishingPoints), !(1...3).contains(values.vanishingPoints) { throw PerspectiveError.invalidValue("vanishing_points") }
        if fields.contains(.cellSize), !(values.cellSize.isFinite && values.cellSize >= 0) { throw PerspectiveError.invalidValue("cell_size") }
        builder.append(Ops.set(WellKnown.settings, fields.map { PerspectiveFields.grid(grid, $0) }, values: PerspectiveFields.gridValues(values)))
    }
}

/// kbd:[Option+Shift]-drag of the grid: one change in which the grid's edited registers move and
/// every object attached to it is duplicated -- a new wrapper and child just above the original,
/// pinned to a new grid (a copy of the old geometry, "<name> 2") -- so the copies stay where the
/// objects were while the originals travel with the grid.  Concurrent edits to the originals are
/// untouched.  Labelled "Clone on grid".
public struct CloneOnGrid: Command {
    public var edit: EditGrid

    public init(_ edit: EditGrid) {
        self.edit = edit
    }

    public var label: String { "Clone on grid" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let source = try PerspectiveEditing.liveGrid(edit.grid, in: state)
        let attached = Self.wrappers(on: edit.grid, in: state)
        var pinned = source.stored
        pinned.name = PerspectiveReading.unusedName(source.name.isEmpty ? "Grid" : source.name, in: state)
        let copy = try PerspectiveEditing.insert(pinned, in: state, builder: &builder)
        try edit.execute(&builder, state: state)
        var props = Wiretuner_Doc_V1_PerspectiveProps()
        props.grid = copy.elementID
        for wrapper in attached {
            let parent = Objects.parent(of: wrapper, in: state)!
            let key = try Arranging.keys(next: wrapper, above: true, count: 1, in: state)[0]
            let clone = try NodeCopier.create(NodeTree(wrapper, state: state), parent: parent, position: key, schema: state.schema, builder: &builder)
            builder.append(Ops.set(clone, [PerspectiveFields.grid], values: PerspectiveFields.values(props)))
        }
    }

    /// The live wrappers projecting onto `grid` (nil: the built-in grid), in tree order.
    static func wrappers(on grid: OpID?, in state: EngineState) -> [OpID] {
        var result: [OpID] = []
        func visit(_ node: OpID) {
            if PerspectiveReading.isWrapper(node, in: state) {
                if PerspectiveReading.grid(ofWrapper: node, in: state) == grid { result.append(node) }
                return
            }
            state.liveChildren(node).forEach(visit)
        }
        visit(WellKnown.layers)
        return result
    }
}
