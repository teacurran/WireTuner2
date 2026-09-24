import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// DOC-017: guide commands, their normalizations and merge cases (grid-guides.adoc).
@Suite struct GuideCommandTests {
    static func guides(_ state: EngineState, page index: Int = 0) -> [PageGuide] {
        PageList(state).pages[index].guides
    }

    @Test func placementByCountAndIncrement() {
        #expect(GuidePlacement.byCount(3, from: 0, to: 100) == [0, 50, 100])
        #expect(GuidePlacement.byCount(1, from: 7, to: 100) == [7])
        #expect(GuidePlacement.byCount(0, from: 0, to: 1).isEmpty && GuidePlacement.byCount(2, from: .nan, to: 1).isEmpty)
        #expect(GuidePlacement.byIncrement(36, from: 0, to: 100) == [0, 36, 72])
        #expect(GuidePlacement.byIncrement(50, from: 0, to: 100) == [0, 50, 100])
        #expect(GuidePlacement.byIncrement(0, from: 0, to: 1).isEmpty && GuidePlacement.byIncrement(1, from: 2, to: 1).isEmpty)
        #expect(GuidePlacement.byIncrement(0.001, from: 0, to: 10).count == 1000)
    }

    @Test func addMoveDeleteAndLabels() throws {
        var a = Replica(0xA)
        // Adding to a document without pages writes the page.
        let add = try #require(try a.perform(AddGuides(on: [PageList.synthesizedID], axis: .vertical, at: [100])))
        #expect(add.label == "Add guide")
        let page = PageList(a.state).pages[0].id
        try a.perform(AddGuides(on: [page], axis: .horizontal, at: GuidePlacement.byCount(3, from: 0, to: 200)))
        var guides = Self.guides(a.state)
        #expect(guides.map(\.axis) == [.vertical, .horizontal, .horizontal, .horizontal] && guides.map(\.position) == [100, 0, 100, 200])
        #expect(guides[0].snapGuide(origin: Point(x: 10, y: 20)) == .vertical(x: 110))
        #expect(guides[1].snapGuide(origin: Point(x: 10, y: 20)) == .horizontal(y: 20))
        #expect(AddGuides(on: [page, page], axis: .vertical, at: [1, 2]).label == "Add 4 guides")
        let move = try #require(try a.perform(MoveGuide(on: page, guides[0].ids, to: 150)))
        #expect(move.label == "Move guide" && Self.guides(a.state)[0].position == 150)
        let delete = try #require(try a.perform(DeleteGuides(on: page, [guides[3].id])))
        #expect(delete.label == "Delete guide" && Self.guides(a.state).count == 3)
        a.undo()
        guides = Self.guides(a.state)
        #expect(guides.count == 4)
        #expect(DeleteGuides(on: page, [guides[1].id, guides[2].id]).label == "Delete 2 guides")
        #expect(try a.perform(DeleteGuides(on: page, [])) == nil)
        // Refusals.
        #expect(throws: GuideEditError.invalidValue("position")) { try a.perform(AddGuides(on: [page], axis: .vertical, at: [.nan])) }
        #expect(throws: GuideEditError.invalidValue("position")) { try a.perform(AddGuides(on: [page], axis: .vertical, at: [])) }
        #expect(throws: GuideEditError.invalidValue("position")) { try a.perform(MoveGuide(on: page, [guides[0].id], to: .infinity)) }
        #expect(throws: GuideEditError.notAnOwner(guides[0].id)) { try a.perform(DeleteGuides(on: guides[0].id, [])) }
        #expect(throws: GuideEditError.unknownGuide(page)) { try a.perform(MoveGuide(on: page, [page], to: 1)) }
    }

    @Test func guidesAcrossPagesAndOnMasters() throws {
        var a = Replica(0xA)
        try a.perform(AddPages(count: 2))
        let ids = PageList(a.state).pages.map(\.id)
        let change = try #require(try a.perform(AddGuides(on: ids, axis: .vertical, at: [36, 72])))
        #expect(change.ops.count == 3 && change.label == "Add 6 guides")
        try a.perform(NewMasterPage(from: ids[0]))
        let master = PageList(a.state).masters[0].id
        try a.perform(AddGuides(on: [master], axis: .horizontal, at: [50]))
        try a.perform(ApplyMasterPage(master, to: [ids[1]]))
        let list = PageList(a.state)
        #expect(list.master(master)?.guides.map(\.position) == [50])
        #expect(list.guides(on: list.pages[1]).count == 3 && list.guides(on: list.pages[0]).count == 2)
        // Snap targets in pasteboard space, the master's on its child at the child's origin.
        let snap = list.snapGuides
        #expect(snap.contains(.horizontal(y: list.pages[1].origin.y + 50)) && snap.contains(.vertical(x: list.pages[2].origin.x + 72)))
        #expect(GuideOwner.of(master, in: list) == .master(master) && GuideOwner.of(ids[0], in: list) == .page(ids[0]))
        #expect(GuideOwner.master(master).node == master && GuideOwner.master(master).sequence == MasterPageFields.guides)
        #expect(GuideOwner.of(OpID(counter: 99, replica: 9), in: list) == nil)
        let masterGuide = list.master(master)!.guides[0]
        try a.perform(MoveGuide(on: master, masterGuide.ids, to: 60))
        #expect(PageList(a.state).master(master)?.guides[0].position == 60)
    }

    @Test func coincidentGuidesReadAsOneAndUnspecifiedAxisIsHorizontal() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        try a.perform(AddGuides(on: [page], axis: .vertical, at: [100, 100, 200]))
        var raw = Wiretuner_Doc_V1_Guide()
        raw.position = 30
        let key = try PathEditing.keys(between: nil, and: nil, count: 1)
        try a.perform(OpsCommand("raw", ops: [Ops.elementInsert(page, PageFields.guides, positions: key, values: PageFields.values { $0.guides = [raw] })]))
        let guides = Self.guides(a.state)
        let coincident = try #require(guides.first { $0.position == 100 })
        #expect(coincident.ids.count == 2 && coincident.ids == coincident.ids.sorted())
        #expect(guides.contains { $0.axis == .horizontal && $0.position == 30 })
        // Moving the row moves both.
        try a.perform(MoveGuide(on: page, coincident.ids, to: 120))
        #expect(Self.guides(a.state).filter { $0.position == 120 }.first?.ids.count == 2)
        // A guide outside the page after a resize is kept.
        try a.perform(AddGuides(on: [page], axis: .vertical, at: [5000]))
        #expect(Self.guides(a.state).contains { $0.position == 5000 })
    }

    @Test func releaseMakesALineAndUndoRestoresTheGuide() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        try a.perform(SetBleed([page], to: 9))
        try a.perform(AddGuides(on: [page], axis: .vertical, at: [100]))
        try a.perform(AddGuides(on: [page], axis: .horizontal, at: [40]))
        let guides = Self.guides(a.state)
        let change = try #require(try a.perform(ReleaseGuides(on: page, guides.map(\.id))))
        #expect(change.label == "Release 2 guides" && ReleaseGuides(on: page, [guides[0].id]).label == "Release guide")
        let lines = change.createdObjects
        #expect(lines.count == 2 && Self.guides(a.state).isEmpty)
        #expect(Objects.bounds(of: lines[0], in: a.state) == Rect(x: 100, y: -9, width: 0, height: 810))
        #expect(Objects.bounds(of: lines[1], in: a.state) == Rect(x: -9, y: 40, width: 630, height: 0))
        #expect(state(a).props(lines[0]).path.appearance.strokes.isEmpty)
        a.undo()
        #expect(Self.guides(a.state).count == 2 && !a.state.isLive(lines[0]))
    }

    @Test func releaseOnAMasterMakesMasterContent() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        try a.perform(NewMasterPage(from: page))
        let master = PageList(a.state).masters[0].id
        try a.perform(AddGuides(on: [master], axis: .vertical, at: [10]))
        let guide = PageList(a.state).master(master)!.guides[0].id
        let change = try #require(try a.perform(ReleaseGuides(on: master, [guide])))
        let line = try #require(change.createdObjects.first)
        #expect(MasterContent.objects(of: master, in: a.state).flatMap(\.objects) == [line])
        #expect(!PageObjects.topLevel(in: a.state).contains(line))
    }

    func state(_ replica: Replica) -> EngineState { replica.state }

    @Test func mergeMoveVersusMoveAddVersusAdd() throws {
        var pair = Pair()
        let page = try PageFixture.onePage(&pair.a)
        try pair.a.perform(AddGuides(on: [page], axis: .vertical, at: [100]))
        pair.sync()
        let guide = Self.guides(pair.a.state)[0].id
        let a = try #require(try pair.a.perform(MoveGuide(on: page, [guide], to: 110)))
        let b = try #require(try pair.b.perform(MoveGuide(on: page, [guide], to: 90)))
        try pair.a.perform(AddGuides(on: [page], axis: .horizontal, at: [5]))
        try pair.b.perform(AddGuides(on: [page], axis: .horizontal, at: [5]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let guides = Self.guides(pair.a.state)
        #expect(guides.first { $0.id == guide }?.position == (PageFixture.later(a, b) ? 110 : 90))
        // Both adds kept; coincident, they read as one row of two.
        #expect(guides.first { $0.axis == .horizontal }?.ids.count == 2)
        #expect(!pair.a.state.store.losingWrites(page, PageFields.guides.element(guide).child(3)).isEmpty)
    }

    @Test func mergeDeleteVersusMoveAndReleaseVersusMove() throws {
        var pair = Pair()
        let page = try PageFixture.onePage(&pair.a)
        try pair.a.perform(AddGuides(on: [page], axis: .vertical, at: [100, 200]))
        pair.sync()
        let ids = Self.guides(pair.a.state).map(\.id)
        try pair.a.perform(DeleteGuides(on: page, [ids[0]]))
        try pair.b.perform(MoveGuide(on: page, [ids[0]], to: 150))
        try pair.a.perform(ReleaseGuides(on: page, [ids[1]]))
        try pair.b.perform(MoveGuide(on: page, [ids[1]], to: 250))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(Self.guides(pair.a.state).isEmpty)
        // Restorable: the move applied to the tombstone.
        try pair.a.perform(OpsCommand("Restore", ops: [Ops.elementDelete(page, [PageFields.guides.element(ids[0])], deleted: false)]))
        #expect(Self.guides(pair.a.state).map(\.position) == [150])
    }
}
