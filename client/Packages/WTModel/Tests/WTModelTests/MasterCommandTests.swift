import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// DOC-010: master pages -- the commands, the effective-geometry read rule, the release tag, the
/// dangling-master normalizations and the merge cases (master-pages.adoc).
@Suite struct MasterCommandTests {
    /// A document with one page holding a rectangle, converted into a master and its child.
    static func converted(_ replica: inout Replica) throws -> (page: OpID, master: OpID, object: OpID) {
        let page = try PageFixture.onePage(&replica)
        try replica.perform(MovePage(page, by: Vector(dx: 100, dy: 50), withContents: false))
        let object = try PageFixture.rect(&replica, at: Point(x: 110, y: 60))
        let change = try #require(try replica.perform(ConvertToMasterPage(page)))
        #expect(change.label == "Convert to master page")
        return (page, PageList(replica.state).masters[0].id, object)
    }

    @Test func newMasterNamesAndGeometry() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        try a.perform(SetBleed([page], to: 12))
        let change = try #require(try a.perform(NewMasterPage(from: page)))
        #expect(change.label == "New master page")
        try a.perform(NewMasterPage())
        try a.perform(RenamePage(PageList(a.state).masters[1].id, to: "Master 7"))
        try a.perform(NewMasterPage())
        let masters = PageList(a.state).masters
        #expect(masters.map(\.name) == ["Master 1", "Master 7", "Master 8"])
        #expect(masters[0].bleed == 12 && masters[0].geometry == .letter)
        #expect(RenamePage(masters[0].id, to: "x", in: a.state).label == "Rename master page")
        #expect(RenamePage(page, to: "x", in: a.state).label == "Rename page" && RenamePage(page, to: "x").label == "Rename page")
        try a.perform(RenamePage(page, to: "Cover"))
        #expect(PageList(a.state).pages[0].name == "Cover")
        var b = Replica(0xB)
        try b.perform(RenamePage(PageList.synthesizedID, to: "Only"))
        #expect(PageList(b.state).pages[0].name == "Only" && !PageList(b.state).isSynthesized)
        #expect(throws: PageSetupError.notAPage(page)) { try a.perform(DeleteMasterPage(page)) }
    }

    @Test func convertMovesObjectsOntoTheMasterCanvas() throws {
        var a = Replica(0xA)
        let (page, master, object) = try Self.converted(&a)
        #expect(PageList(a.state).pages[0].master == master)
        #expect(MasterContent.objects(of: master, in: a.state).flatMap(\.objects) == [object])
        // Master coordinates: relative to the master's top-left.
        #expect(Objects.bounds(of: object, in: a.state) == Rect(x: 10, y: 10, width: 10, height: 10))
        #expect(PageObjects.objects(on: PageList(a.state).pages[0], in: a.state, pages: PageList(a.state)).isEmpty)
        a.undo()
        #expect(PageList(a.state).masters.isEmpty && !PageList(a.state).pages[0].isChild)
        #expect(Objects.bounds(of: object, in: a.state)?.origin == Point(x: 110, y: 60))
        _ = page
    }

    @Test func applyDetachAndDeleteMaster() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        try a.perform(NewMasterPage(from: page))
        let master = PageList(a.state).masters[0].id
        try a.perform(SetPageGeometry([master], to: PageGeometry(PagePreset.named("A4")!)))
        let apply = try #require(try a.perform(ApplyMasterPage(master, to: [page])))
        #expect(apply.label == "Apply master page")
        #expect(try a.perform(ApplyMasterPage(master, to: [page])) == nil)
        #expect(PageList(a.state).pages[0].geometry.preset == "A4" && PageList(a.state).pages[0].ownGeometry == .letter)
        let detach = try #require(try a.perform(DetachFromMaster([page])))
        #expect(detach.label == "Detach from master page")
        let read = PageList(a.state).pages[0]
        #expect(!read.isChild && read.geometry.preset == "A4" && read.ownGeometry.preset == "A4")
        #expect(try a.perform(DetachFromMaster([page])) == nil)
        a.undo()
        #expect(PageList(a.state).pages[0].isChild)
        let delete = try #require(try a.perform(DeleteMasterPage(master)))
        #expect(delete.label == "Delete master page" && !PageList(a.state).pages[0].isChild)
        #expect(PageList(a.state).pages[0].geometry == .letter)
        #expect(throws: PageSetupError.notAPage(master)) { try a.perform(ApplyMasterPage(master, to: [page])) }
        // Applying to a document without pages writes the page.
        var b = Replica(0xB)
        try b.perform(NewMasterPage())
        try b.perform(ApplyMasterPage(PageList(b.state).masters[0].id, to: [PageList.synthesizedID]))
        #expect(PageList(b.state).pages[0].isChild)
    }

    @Test func releaseCopiesMasterContentAndTagsTheLabel() throws {
        var a = Replica(0xA)
        let (page, master, object) = try Self.converted(&a)
        try a.perform(SetBleed([master], to: 6))
        let command = ReleaseChildPages([page], in: a.state)
        #expect(command.label == "Release page 1 from Master 1 \(MasterContent.tag(master))")
        #expect(MasterContent.releasedMaster(fromLabel: command.label) == master)
        let change = try #require(try a.perform(command))
        #expect(change.label.hasSuffix(MasterContent.tag(master)))
        let read = PageList(a.state).pages[0]
        #expect(!read.isChild && read.bleed == 6)
        let copies = PageObjects.objects(on: read, in: a.state, pages: PageList(a.state))
        #expect(copies.count == 1 && a.state.nodeKind(copies[0].id) == .group)
        #expect(copies[0].bounds == Rect(x: 110, y: 60, width: 10, height: 10))
        // The master keeps its own objects.
        #expect(MasterContent.objects(of: master, in: a.state).flatMap(\.objects) == [object])
        a.undo()
        #expect(PageList(a.state).pages[0].master == master)
        #expect(PageObjects.objects(on: PageList(a.state).pages[0], in: a.state, pages: PageList(a.state)).isEmpty)
        #expect(ReleaseChildPages([page]).label == "Release child page")
        #expect(ReleaseChildPages([page, page], in: a.state).label.hasPrefix("Release 2 pages from Master 1"))
        // An ordinary page has nothing to release.
        try a.perform(DetachFromMaster([page]))
        #expect(try a.perform(ReleaseChildPages([page])) == nil)
    }

    @Test func releaseTagParsing() {
        let id = OpID(counter: 12, replica: 34)
        #expect(MasterContent.releasedMaster(fromLabel: "Release page 2 from A \(MasterContent.tag(id))") == id)
        for label in ["Release page 2", "[master:1]", "[master:x:2]", "x [master:1:2] y", "[master:1:2:3]"] {
            #expect(MasterContent.releasedMaster(fromLabel: label) == nil, "\(label)")
        }
    }

    @Test func mergeMasterEditVersusReleaseLeavesAStaleCopy() throws {
        var pair = Pair()
        let (page, master, object) = try Self.converted(&pair.a)
        pair.sync()
        let release = try #require(try pair.a.perform(ReleaseChildPages([page], in: pair.a.state)))
        try pair.b.perform(MoveObjects([object], by: Vector(dx: 5, dy: 0)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(MasterContent.releasedMaster(fromLabel: release.label) == master)
        // The master moved; the released copy is as the releaser saw it.
        #expect(Objects.bounds(of: object, in: pair.a.state)?.minX == 15)
        let copy = PageObjects.objects(on: PageList(pair.a.state).pages[0], in: pair.a.state, pages: PageList(pair.a.state))
        #expect(copy.first?.bounds.minX == 110)
    }

    @Test func mergeDeleteVersusApplyPageReadsOrdinary() throws {
        var pair = Pair()
        let page = try PageFixture.onePage(&pair.a)
        try pair.a.perform(NewMasterPage(from: page))
        let master = PageList(pair.a.state).masters[0].id
        try pair.a.perform(SetPageGeometry([master], to: PageGeometry(PagePreset.named("A5")!)))
        pair.sync()
        try pair.a.perform(DeleteMasterPage(master))
        try pair.b.perform(ApplyMasterPage(master, to: [page]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let read = PageList(pair.a.state).pages[0]
        #expect(!read.isChild && read.geometry == .letter)
        // Restoring the master makes the page its child again.
        try pair.a.perform(OpsCommand("Restore", ops: [Ops.setDeleted(master, false)]))
        #expect(PageList(pair.a.state).pages[0].geometry.preset == "A5")
    }

    @Test func mergeReleaseVersusReleaseKeepsBothCopySets() throws {
        var pair = Pair()
        let (page, _, _) = try Self.converted(&pair.a)
        pair.sync()
        try pair.a.perform(ReleaseChildPages([page], in: pair.a.state))
        try pair.b.perform(ReleaseChildPages([page], in: pair.b.state))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let copies = PageObjects.objects(on: PageList(pair.a.state).pages[0], in: pair.a.state, pages: PageList(pair.a.state))
        #expect(copies.count == 2)
    }

    @Test func mergeConcurrentMasterGeometryChildrenFollowTheWinner() throws {
        var pair = Pair()
        let (page, master, _) = try Self.converted(&pair.a)
        pair.sync()
        let a = try #require(try pair.a.perform(SetPageGeometry([master], to: PageGeometry(PagePreset.named("A3")!))))
        let b = try #require(try pair.b.perform(SetPageGeometry([master], to: PageGeometry(PagePreset.named("B5")!))))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let preset = PageList(pair.a.state)[page]?.geometry.preset
        #expect(preset == (PageFixture.later(a, b) ? "A3" : "B5"))
    }
}
