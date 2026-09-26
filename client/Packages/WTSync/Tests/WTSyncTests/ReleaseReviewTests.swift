import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WTSync

/// DOC-013: the master-page rows of the review sheet (master-pages.adoc, "Merge semantics"):
/// *released stale master* and *duplicate release*, measured on reconnect, with their choices as
/// single changes.
@Suite struct ReleaseReviewTests {
    struct Layout {
        var page: OpID
        var master: OpID
        var object: OpID
    }

    /// One page moved to (100, 50) holding a rectangle, converted into a master and its child, on
    /// both sides.
    static func layout(_ world: inout Reconnect) throws -> Layout {
        try world.shared(SetBleed([PageList.synthesizedID], to: 0))
        let page = PageList(world.theirs.state).pages[0].id
        try world.shared(MovePage(page, by: Vector(dx: 100, dy: 50), withContents: false))
        let created = try #require(try world.shared(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10),
                                                                transform: .translation(x: 110, y: 60))))
        let object = created.createdObjects[0]
        try world.shared(ConvertToMasterPage(page))
        return Layout(page: page, master: PageList(world.theirs.state).masters[0].id, object: object)
    }

    static func copies(_ page: OpID, in state: EngineState) -> [(id: OpID, bounds: Rect)] {
        PageObjects.objects(on: PageList(state).pages.first { $0.id == page }!, in: state, pages: PageList(state))
    }

    @Test func aReleaseWithAConcurrentMasterWriteIsOneStaleRowNamingThePage() throws {
        var world = Reconnect()
        let layout = try Self.layout(&world)
        try world.byMe(ReleaseChildPages([layout.page], in: world.mine.state))
        try world.byThem(MoveObjects([layout.object], by: Vector(dx: 5, dy: 0)))
        try world.byThem(MoveObjects([layout.object], by: Vector(dx: 5, dy: 0)))
        let divergence = world.measure()
        #expect(divergence.releaseOverlaps.count == 1)
        let row = try #require(divergence.releaseOverlaps.first)
        #expect(row.kind == .staleMaster && row.page == layout.page && row.master == layout.master)
        #expect(row.authors == [world.theirs.replica] && row.release.replica == world.mine.replica && row.release.groups.count == 1)
        #expect(row.id == "released-stale-master:\(layout.page)" && row.kind.title == "Released stale master")
        #expect(row.choices == [.updateCopies, .keepCopies] && row.choices.map(\.title) == ["Update the copies", "Keep my copies"])
        #expect(divergence.hasRows && divergence.overlapCount == 0 && divergence.decision(.standard) == .perObject)
        let review = ReviewModel(divergence, decision: .perObject)
        #expect(review.releaseOverlaps == [row])
        #expect(row.command(.keepCopies, in: world.mine.state) == nil)
        #expect(row.command(.removeDuplicates, in: world.mine.state) == nil)

        // *Update the copies*: one change; the copy now matches the moved master.
        #expect(Self.copies(layout.page, in: world.mine.state).first?.bounds.minX == 110)
        let update = try #require(row.command(.updateCopies, in: world.mine.state))
        #expect(update.label == "Update the copies")
        let change = try #require(try world.byMe(update))
        #expect(change.label == "Update the copies")
        let copies = Self.copies(layout.page, in: world.mine.state)
        #expect(copies.count == 1 && copies[0].bounds.minX == 120)
        #expect(!world.mine.state.isLive(row.release.groups[0]))
        world.upload()
        // Undo removes the new copies and brings the stale ones back, in one step.
        let undo = try #require(world.mine.undo(recording: Reconnect.recording)?.change)
        #expect(undo.label.contains("Update the copies"))
        #expect(Self.copies(layout.page, in: world.mine.state).map(\.bounds.minX) == [110])
    }

    @Test func aRemoteReleaseAgainstALocalMasterEditIsListedToo() throws {
        var world = Reconnect()
        let layout = try Self.layout(&world)
        try world.byMe(MoveObjects([layout.object], by: Vector(dx: 5, dy: 0)))
        try world.byThem(ReleaseChildPages([layout.page], in: world.theirs.state))
        let rows = world.measure().releaseOverlaps
        #expect(rows.map(\.kind) == [.staleMaster])
        #expect(rows[0].authors == [world.mine.replica] && rows[0].release.replica == world.theirs.replica)
    }

    @Test func nothingIsListedWithoutAConcurrentMasterWrite() throws {
        var world = Reconnect()
        let layout = try Self.layout(&world)
        try world.byMe(ReleaseChildPages([layout.page], in: world.mine.state))
        try world.byThem(CreateShape(.rectangle(CornerRadii()), size: Size(width: 4, height: 4), transform: .translation(x: 300, y: 300)))
        #expect(world.measure().releaseOverlaps.isEmpty)
        #expect(ReleaseReview.overlaps(local: [], remote: [], state: EngineState()).isEmpty)
    }

    @Test func twoReleasesOfOnePageAreADuplicate() throws {
        var world = Reconnect()
        let layout = try Self.layout(&world)
        try world.byMe(ReleaseChildPages([layout.page], in: world.mine.state))
        try world.byThem(ReleaseChildPages([layout.page], in: world.theirs.state))
        let divergence = world.measure()
        let row = try #require(divergence.releaseOverlaps.first)
        #expect(divergence.releaseOverlaps.count == 1)
        #expect(row.kind == .duplicateRelease && row.page == layout.page && row.kind.title == "Duplicate release")
        #expect(row.id == "duplicate-release:\(layout.page)" && row.choices == [.removeDuplicates, .keepCopies])
        let earlier = try #require(row.earlier)
        #expect(earlier.change < row.release.change)
        #expect(Self.copies(layout.page, in: world.mine.state).count == 2)
        #expect(row.command(.updateCopies, in: world.mine.state) == nil)
        let remove = try #require(row.command(.removeDuplicates, in: world.mine.state))
        let change = try #require(try world.byMe(remove))
        #expect(change.label == "Remove duplicate copies" && change.ops.count == 1)
        #expect(Self.copies(layout.page, in: world.mine.state).count == 1)
        #expect(world.mine.state.isLive(earlier.groups[0]))
        #expect(row.command(.removeDuplicates, in: world.mine.state) == nil)
        world.upload()
    }

    @Test func releasesAreReadFromTaggedChangesOnly() throws {
        var world = Reconnect()
        let layout = try Self.layout(&world)
        let release = try #require(try world.byMe(ReleaseChildPages([layout.page], in: world.mine.state)))
        let read = ReleaseReview.releases([release])
        #expect(read.count == 1 && read[0].page == layout.page && read[0].master == layout.master)
        var untagged = release
        untagged.label = "Release child page"
        var empty = release
        empty.ops = []
        #expect(ReleaseReview.releases([untagged, empty]).isEmpty)
        #expect(ReleaseReview.target(Wiretuner_Doc_V1_Op(), .zero) == nil)
    }

    @Test func updatingCopiesOfAMasterWithNothingLeftOnlyDeletes() throws {
        var world = Reconnect()
        let layout = try Self.layout(&world)
        try world.byMe(ReleaseChildPages([layout.page], in: world.mine.state))
        try world.byThem(OpsCommand("Delete", ops: [Ops.setDeleted(layout.object, true)]))
        let row = try #require(world.measure().releaseOverlaps.first)
        let update = try #require(row.command(.updateCopies, in: world.mine.state))
        let change = try #require(try world.byMe(update))
        #expect(change.ops.count == 1)
        #expect(Self.copies(layout.page, in: world.mine.state).isEmpty)
    }

    @Test func aDuplicateAndAStaleCopyOfOnePageAreBothListedStaleFirst() throws {
        var world = Reconnect()
        let layout = try Self.layout(&world)
        // The other side works a little first, so its release is the later change.
        try world.byThem(CreateShape(.rectangle(CornerRadii()), size: Size(width: 1, height: 1), transform: .translation(x: 400, y: 400)))
        try world.byThem(CreateShape(.rectangle(CornerRadii()), size: Size(width: 1, height: 1), transform: .translation(x: 410, y: 400)))
        try world.byMe(ReleaseChildPages([layout.page], in: world.mine.state))
        try world.byThem(ReleaseChildPages([layout.page], in: world.theirs.state))
        try world.byThem(MoveObjects([layout.object], by: Vector(dx: 5, dy: 0)))
        let rows = world.measure().releaseOverlaps
        #expect(rows.map(\.kind) == [.staleMaster, .duplicateRelease])
        #expect(rows[1].release.replica == world.theirs.replica && rows[1].earlier?.replica == world.mine.replica)
        #expect(ReleaseOverlap.Choice.allCases.map(\.title) == ["Update the copies", "Keep my copies", "Remove duplicates"])
        #expect(ReleaseOverlap.Kind.allCases.count == 2)
    }

    @Test func everyWritingOpNamesItsNode() {
        let node = OpID(counter: 3, replica: 4)
        let path = RegisterPath([1])
        let ops: [Wiretuner_Doc_V1_Op] = [
            Ops.move(node, parent: .wellKnown(4), position: [1]),
            Ops.setDeleted(node, true),
            Ops.elementMove(node, path.element(node), position: [1]),
            Ops.elementDelete(node, [path.element(node)], deleted: true),
            .with { $0.elementInsert.node = node.proto },
            .with { $0.textInsert.node = node.proto },
            .with { $0.textDelete.node = node.proto },
            .with { $0.textMark.node = node.proto },
        ]
        for op in ops {
            #expect(ReleaseReview.target(op, .zero) == node, "\(op)")
        }
    }
}
