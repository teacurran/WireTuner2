import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FX-041: the perspective commands and read-time normalizations.
@Suite struct PerspectiveCommandTests {
    /// A filled square attached to the left wall at cell (1, 2); returns the square and its wrapper.
    static func attached(on a: inout Replica, x: Double = 100) throws -> (object: OpID, wrapper: OpID) {
        let object = try LayerFixture.object(LayerFixture.rect(on: nil, x: x, size: 36), on: &a)
        try a.perform(AddAppearance.fill([object]))
        let change = try #require(try a.perform(AttachToPerspectiveGrid([object], plane: .leftWall, at: Point(x: 1, y: 2))))
        return (object, change.createdNodes[0])
    }

    @Test func attachingWrapsTheObjectInOneChange() throws {
        var a = Replica(0xA)
        let object = try LayerFixture.object(LayerFixture.rect(on: nil, x: 100, size: 36), on: &a)
        let change = try #require(try a.perform(AttachToPerspectiveGrid([object], plane: .leftWall, at: Point(x: 1, y: 2))))
        #expect(change.label == "Attach to perspective grid")
        let wrapper = change.createdNodes[0]
        #expect(PerspectiveReading.isWrapper(wrapper, in: a.state) && Objects.parent(of: object, in: a.state) == wrapper)
        #expect(PerspectiveReading.wrapper(of: object, in: a.state) == wrapper)
        #expect(PerspectiveReading.child(wrapper, in: a.state) == object)
        let props = a.state.props(wrapper).perspective
        #expect(props.plane == .leftWall && props.cellPosition.x == 1 && props.cellPosition.y == 2 && !props.hasGrid, "no grid defined: the built-in default")
        // Attaching again is refused.
        #expect(throws: PerspectiveError.alreadyAttached(object)) { try a.perform(AttachToPerspectiveGrid([object], plane: .floor, at: .zero)) }
        #expect(throws: PerspectiveError.invalidValue("cell")) { try a.perform(AttachToPerspectiveGrid([object], plane: .floor, at: Point(x: .nan, y: 0))) }
        // Undo unwraps.
        a.undo()
        #expect(!a.state.isLive(wrapper) && Objects.parent(of: object, in: a.state) != wrapper)
    }

    @Test func attachingRecordsThePageGrid() throws {
        var a = Replica(0xA)
        try a.perform(DefineGrid(name: "Street"))
        let grid = try #require(PerspectiveReading.grids(a.state).first?.id)
        let (_, wrapper) = try Self.attached(on: &a)
        #expect(OpID(element: a.state.props(wrapper).perspective.grid) == grid)
        #expect(PerspectiveReading.grid(ofWrapper: wrapper, in: a.state) == grid)
    }

    @Test func moveFlipAndResizeWriteTheirRegisters() throws {
        var a = Replica(0xA)
        let (object, wrapper) = try Self.attached(on: &a)
        let move = try #require(try a.perform(MoveOnGrid([object: Point(x: 4, y: 5)])))
        #expect(move.label == "Move on grid" && move.ops[0].set.paths.map(RegisterPath.init) == [PerspectiveFields.cellPosition])
        #expect(a.state.props(wrapper).perspective.cellPosition.x == 4)
        #expect(throws: PerspectiveError.invalidValue("cell_position")) { try a.perform(MoveOnGrid([wrapper: Point(x: .infinity, y: 0)])) }
        let flip = try #require(try a.perform(FlipOnGrid([object])))
        #expect(flip.label == "Flip on grid" && a.state.props(wrapper).perspective.flipped)
        try a.perform(FlipOnGrid([wrapper]))
        #expect(!a.state.props(wrapper).perspective.flipped)
        // The automatic size is the object's flat size in cells: 36 pt on 36 pt cells.
        let grow = try #require(try a.perform(ResizeOnGrid([object], width: 1, height: 1)))
        #expect(grow.label == "Resize on grid")
        #expect(a.state.props(wrapper).perspective.cellWidth == 2 && a.state.props(wrapper).perspective.cellHeight == 2)
        try a.perform(ResizeOnGrid([object], width: -5, height: 0))
        #expect(a.state.props(wrapper).perspective.cellWidth == 1 && a.state.props(wrapper).perspective.cellHeight == 2)
        #expect(try a.perform(ResizeOnGrid([object], width: 0, height: 0)) == nil)
        // Not attached.
        let loose = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        #expect(throws: PerspectiveError.notAttached(loose)) { try a.perform(FlipOnGrid([loose])) }
    }

    @Test func removeAndReleaseTakeTheObjectOffTheGrid() throws {
        var a = Replica(0xA)
        let (object, wrapper) = try Self.attached(on: &a)
        let remove = try #require(try a.perform(RemovePerspective([object])))
        #expect(remove.label == "Remove perspective")
        #expect(!a.state.isLive(wrapper) && Objects.parent(of: object, in: a.state) != wrapper && a.state.isLive(object))
        a.undo()
        #expect(a.state.isLive(wrapper) && Objects.parent(of: object, in: a.state) == wrapper)
        let release = try #require(try a.perform(ReleaseWithPerspective([wrapper])))
        #expect(release.label == "Release with perspective")
        #expect(!a.state.isLive(wrapper) && Objects.parent(of: object, in: a.state) == wrapper, "deleted with the object inside")
        let baked = release.createdObjects[0]
        let paths = a.state.liveChildren(baked).isEmpty ? [baked] : a.state.liveChildren(baked)
        #expect(paths.allSatisfy { a.state.nodeKind($0) == .path })
        // The projected square is no longer a square: its bounds are not 36 × 36.
        let bounds = try #require(Objects.bounds(of: baked, in: a.state))
        #expect(abs(bounds.width - 36) > 0.5 || abs(bounds.height - 36) > 0.5)
        a.undo()
        #expect(a.state.isLive(wrapper) && !a.state.isLive(baked))
    }

    @Test func theProjectedDrawingFollowsThePlacement() throws {
        var a = Replica(0xA)
        let (object, wrapper) = try Self.attached(on: &a)
        let first = try #require(PerspectiveBaking.item(wrapper, in: a.state)?.bounds)
        try a.perform(MoveOnGrid([object: Point(x: 3, y: 1)]))
        let second = try #require(PerspectiveBaking.item(wrapper, in: a.state)?.bounds)
        #expect(first != second)
        guard case .group(let group)? = PerspectiveBaking.item(wrapper, in: a.state), case .perspective(let spec)? = group.live else {
            Issue.record("no live group"); return
        }
        #expect(spec.cellPosition == Point(x: 3, y: 1) && spec.plane == .leftWall)
        // An empty wrapper draws nothing.
        try a.perform(OpsCommand("Delete", ops: [Ops.setDeleted(object)]))
        #expect(PerspectiveBaking.item(wrapper, in: a.state) == nil)
        #expect(PerspectiveReading.drawOrder(wrapper, in: a.state).isEmpty)
        let empty = try #require(try a.perform(ReleaseWithPerspective([wrapper])))
        #expect(!a.state.isLive(wrapper) && empty.createdObjects.count <= 1)
    }

    @Test func aWrapperWithTwoChildrenProjectsTheSmallestId() throws {
        var a = Replica(0xA)
        let (object, wrapper) = try Self.attached(on: &a)
        let extra = try LayerFixture.object(LayerFixture.rect(on: nil, x: 300), on: &a)
        try a.perform(OpsCommand("Move in", ops: [Ops.move(extra, parent: wrapper, position: [0x10])]))
        #expect(PerspectiveReading.child(wrapper, in: a.state) == min(object, extra))
        #expect(PerspectiveReading.drawOrder(wrapper, in: a.state) == [min(object, extra), max(object, extra)])
        guard case .group(let group)? = PerspectiveBaking.item(wrapper, in: a.state) else { Issue.record("item"); return }
        #expect(group.children.count == 2)
    }

    @Test func gridsAreDefinedRenamedAndDeleted() throws {
        var a = Replica(0xA)
        let define = try #require(try a.perform(DefineGrid(name: " Street ")))
        #expect(define.label == "Define grid")
        let street = try #require(PerspectiveReading.grids(a.state).first)
        #expect(street.name == "Street" && street.stored.vanishingPoints == 2 && street.stored.cellSize == 36)
        #expect(throws: PerspectiveError.duplicateName("Street")) { try a.perform(DefineGrid(name: "Street")) }
        #expect(throws: PerspectiveError.invalidValue("name")) { try a.perform(DefineGrid(name: "  ")) }
        #expect(throws: PerspectiveError.invalidValue("name")) { try a.perform(DefineGrid(name: String(repeating: "g", count: 65))) }
        // Duplicate: "Street 2", then "Street 3".
        try a.perform(DuplicateGrid(street.id))
        try a.perform(DuplicateGrid(street.id))
        #expect(PerspectiveReading.grids(a.state).map(\.name) == ["Street", "Street 2", "Street 3"])
        let copy = PerspectiveReading.grids(a.state)[1]
        #expect(copy.stored.leftVp == street.stored.leftVp)
        // Rename: its own name is fine, another's is not.
        let rename = try #require(try a.perform(RenameGrid(copy.id, to: "Street 2")))
        #expect(rename.label == "Rename grid")
        #expect(throws: PerspectiveError.duplicateName("Street")) { try a.perform(RenameGrid(copy.id, to: "Street")) }
        try a.perform(RenameGrid(copy.id, to: "Alley"))
        let delete = try #require(try a.perform(DeleteGrid(copy.id)))
        #expect(delete.label == "Delete grid")
        #expect(PerspectiveReading.grids(a.state).map(\.name) == ["Street", "Street 3"])
        #expect(throws: PerspectiveError.unknownGrid(copy.id)) { try a.perform(DeleteGrid(copy.id)) }
        #expect(throws: PerspectiveError.unknownGrid(copy.id)) { try a.perform(RenameGrid(copy.id, to: "X")) }
        #expect(throws: PerspectiveError.unknownGrid(copy.id)) { try a.perform(SetPageGrid(PageList(a.state).pages[0].id, grid: copy.id)) }
        // A grid without a name duplicates as "Grid".
        try a.perform(EditGrid(street.id, label: "x", fields: [.vanishingPoints]) { $0.vanishingPoints = 1 })
        #expect(PerspectiveReading.unusedName("Grid", in: a.state) == "Grid")
    }

    @Test func pagesPointAtGridsAndFallBack() throws {
        var a = Replica(0xA)
        try a.perform(AddPages(count: 1))
        let pages = PageList(a.state).pages
        try a.perform(DefineGrid(name: "One"))
        try a.perform(DefineGrid(name: "Two", page: pages[0].id, usedBy: pages[0].id))
        let grids = PerspectiveReading.grids(a.state)
        #expect(PerspectiveReading.grid(of: PageList(a.state).pages[0], in: a.state) == grids[1].id)
        #expect(PerspectiveReading.grid(of: PageList(a.state).pages.last!, in: a.state) == grids[0].id, "unset: the first grid")
        let set = try #require(try a.perform(SetPageGrid(pages[0].id, grid: nil)))
        #expect(set.label == "Set page grid")
        #expect(PerspectiveReading.grid(of: PageList(a.state).pages[0], in: a.state) == grids[0].id)
        try a.perform(SetPageGrid(pages[0].id, grid: grids[1].id))
        try a.perform(DeleteGrid(grids[1].id))
        #expect(PerspectiveReading.grid(of: PageList(a.state).pages[0], in: a.state) == grids[0].id, "dangling: the default")
        #expect(PerspectiveReading.resolve(OpID(counter: 99, replica: 9), in: a.state) == grids[0].id)
        // A synthesized page reads the default and is materialized when pointed at a grid.
        var b = Replica(0xB)
        #expect(PerspectiveReading.grid(of: PageList(b.state).pages[0], in: b.state) == nil)
        try b.perform(DefineGrid(name: "Only"))
        let only = PerspectiveReading.grids(b.state)[0].id
        try b.perform(SetPageGrid(PageList(b.state).pages[0].id, grid: only))
        #expect(!PageList(b.state).isSynthesized)
        #expect(PerspectiveReading.grid(of: PageList(b.state).pages[0], in: b.state) == only)
    }

    @Test func gridGeometryReadsInPasteboardSpace() throws {
        var a = Replica(0xA)
        let page = PageList(a.state).pages[0].rect
        #expect(PerspectiveReading.spec(grid: nil, page: page, in: a.state) == PerspectiveGridSpec.defaultGrid(page: page))
        try a.perform(DefineGrid(name: "Default"))
        let grid = PerspectiveReading.grids(a.state)[0].id
        // A new grid is the built-in one, stored in page coordinates.
        #expect(PerspectiveReading.spec(grid: grid, page: page, in: a.state) == PerspectiveGridSpec.defaultGrid(page: page))
        let edit = try #require(try a.perform(EditGrid(grid, label: "Move vanishing point", fields: [.leftVP]) { $0.leftVp.x = 10; $0.leftVp.y = 20 }))
        #expect(edit.label == "Move vanishing point")
        let spec = PerspectiveReading.spec(grid: grid, page: page, in: a.state)
        #expect(spec.leftVP == Point(x: page.minX + 10, y: page.maxY - 20))
        #expect(throws: PerspectiveError.invalidValue("vanishing_points")) { try a.perform(EditGrid(grid, label: "x", fields: [.vanishingPoints]) { $0.vanishingPoints = 4 }) }
        #expect(throws: PerspectiveError.invalidValue("cell_size")) { try a.perform(EditGrid(grid, label: "x", fields: [.cellSize]) { $0.cellSize = -1 }) }
        #expect(throws: PerspectiveError.invalidValue("name")) { try a.perform(EditGrid(grid, label: "x", fields: [.name]) { $0.name = "y" }) }
        #expect(throws: PerspectiveError.unknownGrid(OpID(counter: 5, replica: 5))) { try a.perform(EditGrid(OpID(counter: 5, replica: 5), label: "x", fields: [.cellSize]) { $0.cellSize = 1 }) }
    }

    @Test func planesReadAsTheProjectorNamesThem() {
        let pairs: [(Wiretuner_Doc_V1_PerspectivePlane, PerspectiveSpec.Plane)] = [
            (.unspecified, .leftWall), (.leftWall, .leftWall), (.rightWall, .rightWall), (.floorLeft, .floorLeft), (.floorRight, .floorRight),
            (.wall, .wall), (.floor, .floor), (.UNRECOGNIZED(42), .leftWall),
        ]
        for (stored, read) in pairs { #expect(PerspectiveReading.plane(stored) == read) }
    }

    @Test func duplicateNamesAfterAMergeDisplayWithASuffix() throws {
        var pair = Pair()
        try pair.a.perform(DefineGrid(name: "Street"))
        try pair.b.perform(DefineGrid(name: "Street"))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let grids = PerspectiveReading.grids(pair.a.state)
        #expect(grids.map(\.name) == ["Street", "Street"])
        let later = grids.max { $0.id < $1.id }!
        #expect(later.displayName == "Street 2" && grids.first { $0.id != later.id }?.displayName == "Street")
    }

    @Test func cloningTheGridLeavesPinnedCopies() throws {
        var a = Replica(0xA)
        try a.perform(DefineGrid(name: "Street"))
        let grid = PerspectiveReading.grids(a.state)[0].id
        let (object, wrapper) = try Self.attached(on: &a)
        let before = PerspectiveBaking.item(wrapper, in: a.state)?.bounds
        let change = try #require(try a.perform(CloneOnGrid(EditGrid(grid, label: "Move grid", fields: [.horizonY, .floorFrontY]) {
            $0.horizonY = 500
            $0.floorFrontY = 300
        })))
        #expect(change.label == "Clone on grid")
        let grids = PerspectiveReading.grids(a.state)
        #expect(grids.map(\.name) == ["Street", "Street 2"])
        let wrappers = CloneOnGrid.wrappers(on: grid, in: a.state)
        #expect(wrappers == [wrapper], "the original follows the moved grid")
        let pinned = CloneOnGrid.wrappers(on: grids[1].id, in: a.state)
        #expect(pinned.count == 1 && pinned[0] != wrapper)
        #expect(PerspectiveBaking.item(pinned[0], in: a.state)?.bounds == before, "the copy stays where the object was")
        #expect(PerspectiveBaking.item(wrapper, in: a.state)?.bounds != before)
        let copied = try #require(PerspectiveReading.child(pinned[0], in: a.state))
        #expect(copied != object)
    }
}

/// FX-041's merge tests.
@Suite struct PerspectiveMergeTests {
    @Test func aGridEditAndAnObjectMoveBothKeepWithOneProjection() throws {
        var pair = Pair()
        try pair.a.perform(DefineGrid(name: "Street"))
        let grid = PerspectiveReading.grids(pair.a.state)[0].id
        let (object, wrapper) = try PerspectiveCommandTests.attached(on: &pair.a)
        pair.sync()
        try pair.a.perform(EditGrid(grid, label: "Move vanishing point", fields: [.rightVP]) { $0.rightVp.x = 700; $0.rightVp.y = 400 })
        try pair.b.perform(MoveOnGrid([object: Point(x: 6, y: 3)]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let spec = PerspectiveReading.spec(wrapper, in: pair.a.state)
        #expect(spec == PerspectiveReading.spec(wrapper, in: pair.b.state))
        #expect(spec.cellPosition == Point(x: 6, y: 3))
        #expect(PerspectiveBaking.item(wrapper, in: pair.a.state) == PerspectiveBaking.item(wrapper, in: pair.b.state))
    }

    @Test func releaseVersusAChildEditIsRestorable() throws {
        var pair = Pair()
        let (object, wrapper) = try PerspectiveCommandTests.attached(on: &pair.a)
        pair.sync()
        let baked = try #require(try pair.a.perform(ReleaseWithPerspective([object]))).createdObjects[0]
        let row = AppearanceEditing.stack(object, in: pair.b.state).first { $0.list == .fills }!
        try pair.b.perform(SetAppearanceColor([(object, row)], color: Appearances.basicFill(red: 0, green: 0, blue: 1).settings.basic.color))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(!pair.a.state.isLive(wrapper) && pair.a.state.isLive(baked))
        #expect(Objects.parent(of: object, in: pair.a.state) == wrapper, "the edit landed under the deleted wrapper")
        // Restore: the wrapper back (the review's action), the baked copy deleted again.
        try pair.b.perform(OpsCommand("Restore", ops: [Ops.setDeleted(wrapper, false), Ops.setDeleted(baked)]))
        pair.sync()
        #expect(pair.a.state.isLive(wrapper) && !pair.a.state.isLive(baked))
        #expect(PerspectiveReading.wrapper(of: object, in: pair.a.state) == wrapper)
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }

    @Test func aGridDeletedWhileAPageUsesItFallsBackAndRestores() throws {
        var pair = Pair()
        try pair.a.perform(DefineGrid(name: "First"))
        try pair.a.perform(DefineGrid(name: "Street"))
        let grids = PerspectiveReading.grids(pair.a.state)
        let page = PageList(pair.a.state).pages[0].id
        pair.sync()
        try pair.a.perform(DeleteGrid(grids[1].id))
        try pair.b.perform(SetPageGrid(page, grid: grids[1].id))
        let (_, wrapper) = try PerspectiveCommandTests.attached(on: &pair.b)
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let current = PageList(pair.a.state).pages[0]
        #expect(PerspectiveReading.grid(of: current, in: pair.a.state) == grids[0].id, "falls back to the default grid")
        #expect(PerspectiveReading.grid(ofWrapper: wrapper, in: pair.a.state) == grids[0].id, "the object stays attached")
        // Restore re-inserts the grid; the page and the object read it again.
        try pair.a.perform(OpsCommand("Restore", ops: [Ops.elementDelete(WellKnown.settings, [PerspectiveFields.grids.element(grids[1].id)], deleted: false)]))
        pair.sync()
        #expect(PerspectiveReading.grid(of: PageList(pair.b.state).pages[0], in: pair.b.state) == grids[1].id)
        #expect(PerspectiveReading.grid(ofWrapper: wrapper, in: pair.b.state) == grids[1].id)
    }
}
