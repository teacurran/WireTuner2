import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// IMG-023's *Trace layers* and FX-043's `ForkGrid` and `MoveOffGrid`.
@Suite struct TraceLayersAndGridEditsTests {
    @Test func traceLayersPickPrintingOrNonPrintingLayers() throws {
        var a = Replica(0xA)
        let layers = try LayerFixture.layers(["Scan", "Art"], on: &a)
        try a.perform(ReorderLayer(layers[0], to: 0, printing: false))
        let scan = try LayerFixture.object(LayerFixture.rect(on: layers[0]), on: &a)
        let art = try LayerFixture.object(LayerFixture.rect(on: layers[1], x: 20), on: &a)
        try a.perform(LayerFixture.guides())
        let order = LayerOrder(a.state)
        #expect(TraceLayers.background.includes(node: scan, in: a.state) && !TraceLayers.background.includes(node: art, in: a.state))
        #expect(TraceLayers.foreground.includes(node: art, in: a.state, order: order) && !TraceLayers.foreground.includes(node: scan, in: a.state))
        #expect(TraceLayers.all.includes(node: scan, in: a.state) && TraceLayers.all.includes(node: art, in: a.state))
        let guides = try #require(order.layers.first { $0.role == .guides })
        #expect(TraceLayers.allCases.allSatisfy { !$0.includes(guides) }, "the Guides layer is never traced")
        #expect(!TraceLayers.background.includes(node: OpID(counter: 99, replica: 9), in: a.state))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let list = builder.rebuild(a.state).displayList
        #expect(TraceLayers.all.filter(list, in: a.state) == list)
        #expect(TraceLayers.background.filter(list, in: a.state).nodeIDs == [NodeID(scan)])
        #expect(TraceLayers.foreground.filter(list, in: a.state).nodeIDs == [NodeID(art)])
        // Items without a node are furniture: left out of a filtered list.
        let bare = DisplayList(canvas: "c", items: list.items)
        #expect(TraceLayers.foreground.filter(bare, in: a.state).isEmpty)
        #expect(TraceLayers.allCases.map(\.title) == ["All", "Foreground", "Background"])
    }

    /// A page with a defined grid, used by it.
    static func grid(_ a: inout Replica) throws -> (page: OpID, grid: OpID) {
        try a.perform(AddPages(count: 1))
        let page = PageList(a.state).pages[0].id
        try a.perform(DefineGrid(name: "Grid", page: page, usedBy: page))
        return (page, PerspectiveReading.grids(a.state)[0].id)
    }

    @Test func forkGridCopiesTheGridForThePageAndEditsTheCopy() throws {
        var a = Replica(0xA)
        let (page, grid) = try Self.grid(&a)
        let before = PerspectiveReading.grids(a.state)[0].stored
        let edit = EditGrid(grid, label: "Move horizon", fields: [.horizonY]) { $0.horizonY = 42 }
        let change = try #require(try a.perform(ForkGrid(edit, page: page)))
        #expect(change.label == "Define grid")
        let grids = PerspectiveReading.grids(a.state)
        #expect(grids.map(\.name) == ["Grid", "Grid 2"] && grids[0].stored == before && grids[1].stored.horizonY == 42)
        #expect(PerspectiveReading.grid(of: PageList(a.state).pages[0], in: a.state) == grids[1].id)
        #expect(throws: PerspectiveError.self) { try a.perform(ForkGrid(EditGrid(grid, label: "Name", fields: [.name]) { _ in }, page: page)) }
        #expect(throws: PerspectiveError.self) { try a.perform(ForkGrid(EditGrid(OpID(counter: 1, replica: 1), label: "x", fields: []) { _ in }, page: page)) }
        try a.perform(ForkGrid(EditGrid(grid, label: "Copy", fields: []) { _ in }, page: page))
        #expect(PerspectiveReading.grids(a.state).map(\.name) == ["Grid", "Grid 2", "Grid 3"])
        a.undo()
        a.undo()
        #expect(PerspectiveReading.grids(a.state).count == 1 && PerspectiveReading.grid(of: PageList(a.state).pages[0], in: a.state) == grid)
    }

    /// A grid with no name (one written by a peer outside the commands' checks).
    struct InsertUnnamedGrid: Command {
        var label: String { "Unnamed" }
        func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
            var grid = PerspectiveReading.grids(state)[0].stored
            grid.name = ""
            _ = try PerspectiveEditing.insert(grid, in: state, builder: &builder)
        }
    }

    @Test func forkingAnUnnamedGridNamesTheCopyGrid() throws {
        var a = Replica(0xA)
        let (page, _) = try Self.grid(&a)
        try a.perform(InsertUnnamedGrid())
        let unnamed = try #require(PerspectiveReading.grids(a.state).first { $0.name.isEmpty }).id
        try a.perform(ForkGrid(EditGrid(unnamed, label: "Copy", fields: []) { _ in }, page: page))
        #expect(PerspectiveReading.grids(a.state).map(\.name).last == "Grid 2")
    }

    @Test func movingAttachedObjectsReleasesThemMoved() throws {
        var a = Replica(0xA)
        _ = try Self.grid(&a)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil, x: 100), on: &a)
        let flat = try LayerFixture.object(LayerFixture.rect(on: nil, x: 300), on: &a)
        try a.perform(AttachToPerspectiveGrid([rect], plane: .leftWall, at: Point(x: 1, y: 1)))
        let wrapper = try #require(PerspectiveReading.wrapper(of: rect, in: a.state))
        // Where Release with Perspective puts the drawing.
        let release = try #require(try a.perform(ReleaseWithPerspective([wrapper])))
        let releasedGroup = try #require(release.createdRoots.first)
        let drawn = try #require(Objects.bounds(of: releasedGroup, in: a.state))
        a.undo()
        #expect(MoveOffGrid.command([flat], by: Vector(dx: 5, dy: 0), in: a.state) is MoveObjects)
        let command = MoveOffGrid.command([rect, flat], by: Vector(dx: 5, dy: 7), in: a.state)
        let change = try #require(try a.perform(command))
        #expect(change.label == "Move" && !a.state.isLive(wrapper))
        let group = try #require(change.createdRoots.first)
        #expect(a.state.nodeKind(group) == .group)
        let moved = try #require(Objects.bounds(of: group, in: a.state))
        #expect(abs(moved.minX - drawn.minX - 5) < 0.5 && abs(moved.minY - drawn.minY - 7) < 0.5, "\(moved) vs \(drawn)")
        #expect(Objects.bounds(of: flat, in: a.state)?.minX == 305)
        // A wrapper named twice is released once; undo brings the attached object back.
        a.undo()
        try a.perform(MoveOffGrid([wrapper, rect], by: .zero))
        #expect(a.state.liveChildren(try #require(a.state.store.placement(wrapper)?.parent)).filter { a.state.nodeKind($0) == .group }.count == 1)
        a.undo()
        #expect(a.state.isLive(wrapper))
    }
}
