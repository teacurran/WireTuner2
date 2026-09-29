import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// `ReshapePageGrid` (perspective.adoc, "To reshape the grid on the canvas"): the Perspective tool's
/// handle drags, on a defined grid and on the built-in grid, which the same change defines.
@Suite struct PerspectiveGridReshapeTests {
    static func page(_ a: Replica) -> Page { PageList(a.state).pages[0] }

    /// What an attached object draws: its projected drawing's bounds.
    static func drawn(_ wrapper: OpID, _ a: Replica) -> Rect? {
        var scene = DocumentDisplayListBuilder(canvas: "reshape")
        return scene.rebuild(a.state).object(wrapper)?.item.bounds
    }

    /// The left vanishing point moved to (10, 20) in page coordinates.
    static func moveLeft(_ page: Page, grid: OpID?, mode: ReshapePageGrid.Mode = .edit) -> ReshapePageGrid {
        ReshapePageGrid(page: page.id, grid: grid, gesture: "Move vanishing point", mode: mode, fields: [.leftVP]) { $0.leftVp.x = 10; $0.leftVp.y = 20 }
    }

    @Test func draggingTheBuiltInGridDefinesItInTheSameChange() throws {
        var a = Replica(0xA)
        let (object, wrapper) = try PerspectiveCommandTests.attached(on: &a)
        let page = Self.page(a)
        let before = try #require(Self.drawn(wrapper, a))
        let change = try #require(try a.perform(Self.moveLeft(page, grid: nil)))
        #expect(change.label == "Move vanishing point")
        let grids = PerspectiveReading.grids(a.state)
        #expect(grids.map(\.name) == ["Grid"] && PerspectiveReading.grid(of: Self.page(a), in: a.state) == grids[0].id)
        // The built-in geometry with the edit applied.
        var expected = PerspectiveReading.defaultGrid(name: "Grid", page: page.rect)
        expected.leftVp.x = 10
        expected.leftVp.y = 20
        var stored = grids[0].stored
        stored.clearID()
        #expect(stored == expected)
        // The object attached to the built-in grid follows it.
        #expect(PerspectiveReading.grid(ofWrapper: wrapper, in: a.state) == grids[0].id && PerspectiveReading.wrapper(of: object, in: a.state) == wrapper)
        #expect(Self.drawn(wrapper, a) != before)
        // One undo: the built-in grid again.
        a.undo()
        #expect(PerspectiveReading.grids(a.state).isEmpty && Self.drawn(wrapper, a) == before)
        // A name is never a handle's register.
        #expect(throws: PerspectiveError.invalidValue("name")) {
            try a.perform(ReshapePageGrid(page: page.id, grid: nil, gesture: "x", fields: [.name]) { $0.name = "y" })
        }
    }

    @Test func onADefinedGridItIsTheEditForkOrClone() throws {
        var a = Replica(0xA)
        try a.perform(DefineGrid(name: "Street", page: Self.page(a).id, usedBy: Self.page(a).id))
        let grid = try #require(PerspectiveReading.grids(a.state).first?.id)
        let page = Self.page(a)
        let edit = try #require(try a.perform(Self.moveLeft(page, grid: grid)))
        #expect(edit.label == "Move vanishing point" && PerspectiveReading.grids(a.state)[0].stored.leftVp.x == 10)
        let fork = try #require(try a.perform(ReshapePageGrid(page: page.id, grid: grid, gesture: "Move horizon", mode: .fork, fields: [.horizonY]) { $0.horizonY = 100 }))
        #expect(fork.label == "Define grid")
        let grids = PerspectiveReading.grids(a.state)
        #expect(grids.map(\.name) == ["Street", "Street 2"] && grids[1].stored.horizonY == 100 && grids[0].stored.horizonY != 100)
        #expect(PerspectiveReading.grid(of: Self.page(a), in: a.state) == grids[1].id)
        _ = try PerspectiveCommandTests.attached(on: &a)
        let clone = try #require(try a.perform(Self.moveLeft(Self.page(a), grid: grids[1].id, mode: .clone)))
        #expect(clone.label == "Clone on grid" && PerspectiveReading.grids(a.state).count == 3)
    }

    @Test func forkingTheBuiltInGridKeepsItAndCloningPinsCopiesToIt() throws {
        var a = Replica(0xA)
        let page = Self.page(a)
        let fork = try #require(try a.perform(Self.moveLeft(page, grid: nil, mode: .fork)))
        #expect(fork.label == "Define grid")
        var grids = PerspectiveReading.grids(a.state)
        #expect(grids.map(\.name) == ["Grid", "Grid 2"] && grids[0].stored.leftVp.x != 10 && grids[1].stored.leftVp.x == 10)
        #expect(PerspectiveReading.grid(of: Self.page(a), in: a.state) == grids[1].id, "the edited copy is the page's grid")
        a.undo()
        // Option+Shift on the built-in grid with an object on it: the object travels with the
        // edited grid, its copy stays pinned to the old geometry.
        let (_, wrapper) = try PerspectiveCommandTests.attached(on: &a)
        let before = try #require(Self.drawn(wrapper, a))
        let clone = try #require(try a.perform(Self.moveLeft(Self.page(a), grid: nil, mode: .clone)))
        #expect(clone.label == "Clone on grid")
        grids = PerspectiveReading.grids(a.state)
        #expect(grids.map(\.name) == ["Grid", "Grid 2"] && grids[0].stored.leftVp.x == 10 && grids[1].stored.leftVp.x != 10)
        #expect(PerspectiveReading.grid(of: Self.page(a), in: a.state) == grids[0].id)
        let copy = try #require(clone.createdNodes.first { $0 != wrapper && PerspectiveReading.isWrapper($0, in: a.state) })
        #expect(PerspectiveReading.grid(ofWrapper: copy, in: a.state) == grids[1].id)
        #expect(Self.drawn(copy, a) == before && Self.drawn(wrapper, a) != before)
        #expect(ReshapePageGrid.nextName(after: "Grid", in: a.state) == "Grid 3")
    }

    @Test func everyGridFieldCopies() {
        var values = Wiretuner_Doc_V1_PerspectiveGrid()
        values.name = "n"
        values.vanishingPoints = 3
        values.cellSize = 9
        values.horizonY = 1
        values.leftVp.x = 2
        values.rightVp.x = 3
        values.verticalVp.x = 4
        values.leftWallX = 5
        values.rightWallX = 6
        values.floorFrontY = 7
        values.leftColor = ColorResolver.inline(Color(red: 1, green: 0, blue: 0))
        values.rightColor = ColorResolver.inline(Color(red: 0, green: 1, blue: 0))
        values.floorColor = ColorResolver.inline(Color(red: 0, green: 0, blue: 1))
        values.leftHidden = true
        values.rightHidden = true
        values.floorHidden = true
        var grid = Wiretuner_Doc_V1_PerspectiveGrid()
        ReshapePageGrid.assign(PerspectiveFields.GridField.allCases, from: values, to: &grid)
        #expect(grid == values)
    }

    @Test func twoPeopleDraggingTheBuiltInGridOfflineMergeToTwoGrids() throws {
        var pair = Pair()
        try pair.a.perform(Self.moveLeft(Self.page(pair.a), grid: nil))
        try pair.b.perform(ReshapePageGrid(page: Self.page(pair.b).id, grid: nil, gesture: "Move horizon", fields: [.horizonY]) { $0.horizonY = 50 })
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let grids = PerspectiveReading.grids(pair.a.state)
        // Both definitions keep (the later displays "Grid 2"); the page names one of them.
        #expect(grids.count == 2 && Set(grids.map(\.displayName)) == ["Grid", "Grid 2"])
        let used = PerspectiveReading.grid(of: Self.page(pair.a), in: pair.a.state)
        #expect(used != nil && grids.contains { $0.id == used })
    }

    @Test func attachingCanFlip() throws {
        var a = Replica(0xA)
        let object = try LayerFixture.object(LayerFixture.rect(on: nil, x: 100, size: 36), on: &a)
        let change = try #require(try a.perform(AttachToPerspectiveGrid([object], plane: .rightWall, at: .zero, flipped: true)))
        #expect(a.state.props(change.createdNodes[0]).perspective.flipped)
    }
}
