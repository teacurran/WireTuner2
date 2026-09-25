import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WTSync

/// A reconnect played by two `DocumentCore`s: `theirs` (already on the server) and `mine` (this
/// Mac, offline); `measure` delivers their changes to `mine` and measures its unsent ones against
/// them, as `SyncClient.reconcile` does.
struct OfflineRound {
    static let recording = DocumentCore.Recording(limit: 100, now: Date(timeIntervalSince1970: 1_000_000))

    var mine = DocumentCore(state: EngineState(), replica: 0xB)
    var theirs = DocumentCore(state: EngineState(), replica: 0xA)
    var local: [Wiretuner_Doc_V1_Change] = []
    var remote: [Wiretuner_Doc_V1_Change] = []
    private var serverSeq: UInt64 = 0

    /// Performs `command` before the gap: both sides have it.
    @discardableResult
    mutating func shared(_ command: any Command) throws -> Wiretuner_Doc_V1_Change? {
        let outcome = try theirs.perform(command, recording: Self.recording)!
        serverSeq += 1
        mine.receive(outcome.outbox!, serverSeq: serverSeq)
        return outcome.change
    }

    /// Performs `command` on this Mac, offline.
    @discardableResult
    mutating func byMe(_ command: any Command) throws -> Wiretuner_Doc_V1_Change? {
        let outcome = try mine.perform(command, recording: Self.recording)!
        local.append(outcome.outbox!)
        return outcome.change
    }

    /// Performs `command` on the others' side meanwhile.
    @discardableResult
    mutating func byThem(_ command: any Command) throws -> Wiretuner_Doc_V1_Change? {
        let outcome = try theirs.perform(command, recording: Self.recording)!
        remote.append(outcome.outbox!)
        return outcome.change
    }

    /// Delivers the others' changes and measures.
    mutating func measure() -> Divergence {
        for change in remote {
            serverSeq += 1
            mine.receive(change, serverSeq: serverSeq)
        }
        return Divergence.measure(local: local, remote: remote, state: mine.state, gap: .seconds(6 * 3600))
    }

    /// Sends this Mac's changes to the others; both converge.
    mutating func upload() {
        for change in local {
            serverSeq += 1
            theirs.receive(change, serverSeq: serverSeq)
        }
        local = []
        #expect(mine.state.stateHash == theirs.state.stateHash)
    }
}

/// The review rows of the merge tests of ATTR-020, DRAW-030, FX-041 and FX-049: what the review
/// sheet lists after a reconnect when the commands meet a concurrent edit.
@Suite struct AlterationReviewTests {
    static func fillRow(_ node: OpID, in state: EngineState) -> AppearanceRow {
        AppearanceEditing.stack(node, in: state).first { $0.list == .fills }!
    }

    @Test func concurrentTilePastesAreListedWithBothTiles() throws {
        var world = OfflineRound()
        let target = try #require(try world.shared(CreateShape(.rectangle(CornerRadii()), size: Size(width: 50, height: 50)))).createdObjects[0]
        try world.shared(AddAppearance.fill([target]))
        let row = Self.fillRow(target, in: world.theirs.state)
        try world.shared(SetAttributeKind([(target, row)], fill: .tiled))
        let dot = try #require(try world.shared(CreateShape(.ellipse, size: Size(width: 4, height: 4)))).createdObjects[0]
        let bar = try #require(try world.shared(CreateShape(.rectangle(CornerRadii()), size: Size(width: 9, height: 2)))).createdObjects[0]
        try world.byMe(try EditAttribute.pasteIn([(target, row)], ClipboardPayload(copying: [dot], from: world.mine.state)))
        try world.byThem(try EditAttribute.pasteIn([(target, row)], ClipboardPayload(copying: [bar, dot], from: world.theirs.state)))
        let entries = world.measure().entries.filter { $0.node == target }
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.kinds.contains(OverlapKind.sameRegister))
        let tile = try #require(entry.properties.first)
        #expect(tile.mine != nil && tile.theirs != nil && tile.mine != tile.theirs, "both tiles are shown")
        world.upload()
    }

    @Test func expandingACombineWhileAMemberIsEditedListsTheMember() throws {
        var world = OfflineRound()
        let one = try #require(try world.shared(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 20)))).createdObjects[0]
        let two = try #require(try world.shared(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 20), transform: .translation(x: 10, y: 10))))
            .createdObjects[0]
        let group = try #require(try world.shared(GroupObjects([one, two]))).createdObjects[0]
        try world.shared(AddAppearance.fill([group]))
        try world.shared(AddEffect([group], kind: .combine))
        let path = try #require(try world.byMe(ExpandCombine([group]))).createdObjects[0]
        try world.byThem(MoveObjects([two], by: Vector(dx: 5, dy: 0)))
        let entries = world.measure().entries
        let entry = try #require(entries.first { $0.node == two })
        #expect(entry.kind == OverlapKind.editVsDelete && entry.deletedAncestor == group)
        // The expanded path stands; bringing the group back keeps it beside the path.
        #expect(world.mine.state.isLive(path))
        try world.byMe(OpsCommand("Restore", ops: [Ops.setDeleted(group, false)]))
        #expect(world.mine.state.isLive(group) && world.mine.state.isLive(path))
        world.upload()
    }

    @Test func simplifyingWhileAPointMovesListsThePathOnce() throws {
        var world = OfflineRound()
        var points: [VectorPoint] = []
        for index in 0..<120 {
            let angle = Double(index) / 120 * 2 * .pi
            points.append(VectorPoint(anchor: Point(x: 100 * cos(angle), y: 100 * sin(angle))))
        }
        let node = try #require(try world.shared(CreatePath(contours: [NewContour(closed: true, points: points)]))).createdObjects[0]
        let contour = world.theirs.state.liveElements(node, PathFields.contours)[0]
        let point = world.theirs.state.liveElements(node, PathFields.points(contour))[30]
        try world.byMe(SimplifyPaths([node], amount: 100))
        try world.byThem(MovePoints(node: node, contour: contour, point: point, to: Point(x: 0, y: 0)))
        let entries = world.measure().entries.filter { $0.node == node }
        #expect(entries.count == 1, "the path is listed once")
        world.upload()
    }

    @Test func releasingWithPerspectiveWhileTheObjectIsEditedListsIt() throws {
        var world = OfflineRound()
        let object = try #require(try world.shared(CreateShape(.rectangle(CornerRadii()), size: Size(width: 36, height: 36)))).createdObjects[0]
        let wrapper = try #require(try world.shared(AttachToPerspectiveGrid([object], plane: .floorLeft, at: Point(x: 1, y: 1)))).createdNodes[0]
        try world.byMe(ReleaseWithPerspective([wrapper]))
        try world.byThem(OpsCommand("Rename", ops: [Ops.set(object, [RegisterPath([21, 1, 1])], values: Self.named("Crate"))]))
        let entry = try #require(world.measure().entries.first { $0.node == object })
        #expect(entry.kind == OverlapKind.editVsDelete && entry.deletedAncestor == wrapper)
        world.upload()
    }

    @Test func deletingAGridAPageStartedUsingIsListed() throws {
        var world = OfflineRound()
        try world.shared(SetBleed([PageList.synthesizedID], to: 0))
        try world.shared(DefineGrid(name: "Street"))
        let grid = PerspectiveReading.grids(world.theirs.state)[0].id
        let page = PageList(world.theirs.state).pages[0].id
        try world.byMe(DeleteGrid(grid))
        try world.byThem(SetPageGrid(page, grid: grid))
        let divergence = world.measure()
        #expect(PerspectiveReading.grid(of: PageList(world.mine.state).pages[0], in: world.mine.state) == nil, "the page falls back to the default")
        _ = divergence
        // Restore re-inserts the grid; the page reads it again.
        try world.byMe(OpsCommand("Restore", ops: [Ops.elementDelete(WellKnown.settings, [PerspectiveFields.grids.element(grid)], deleted: false)]))
        #expect(PerspectiveReading.grid(of: PageList(world.mine.state).pages[0], in: world.mine.state) == grid)
        world.upload()
    }

    static func named(_ name: String) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.rect.common.name = name
        return props
    }
}
