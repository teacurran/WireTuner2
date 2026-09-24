import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// DOC-006: the page commands and their merge cases (pages.adoc, "Data model", "Merge
/// semantics").
@Suite struct PageCommandTests {
    @Test func addPagesPlacesThemRightOfTheRightmostPage() throws {
        var a = Replica(0xA)
        // On a document with no page, Add writes the synthesized page first.
        let change = try #require(try a.perform(AddPages(count: 2)))
        #expect(change.label == "Add 2 pages" && change.createdNodes.count == 3)
        var list = PageList(a.state)
        #expect(list.pages.map(\.origin.x) == [0, 684, 1368])
        try a.perform(SetBleed([list.pages[2].id], to: 18))
        try a.perform(AddPages(count: 1, geometry: PageGeometry(PagePreset.named("A5")!), bleed: 9, after: list.pages[0].id))
        list = PageList(a.state)
        // After page 1 in page order, right of page 3's bleed rectangle plus an inch plus its bleed.
        #expect(list.pages.count == 4 && list.pages[1].geometry.preset == "A5" && list.pages[1].bleed == 9)
        #expect(list.pages[1].origin.x == 1368 + 612 + 18 + 72 + 9)
        #expect(AddPages().label == "Add page")
        #expect(throws: PageSetupError.invalidValue("count")) { try a.perform(AddPages(count: 0)) }
        #expect(throws: PageSetupError.invalidValue("geometry")) { try a.perform(AddPages(geometry: PageGeometry(width: -1, height: 1))) }
        #expect(throws: PageSetupError.invalidValue("bleed")) { try a.perform(AddPages(bleed: 800)) }
        #expect(throws: PageSetupError.notAPage(list.pages[0].id)) { try a.perform(AddPages(master: .some(list.pages[0].id))) }
    }

    @Test func addPagesWithAMasterUsesItsGeometry() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        try a.perform(NewMasterPage(from: page, name: "Spread"))
        let master = PageList(a.state).masters[0].id
        try a.perform(SetPageGeometry([master], to: PageGeometry(PagePreset.named("Tabloid")!)))
        try a.perform(AddPages(count: 2, master: .some(master)))
        let list = PageList(a.state)
        #expect(list.pages[1].master == master && list.pages[2].master == master)
        #expect(list.pages[2].origin.x == list.pages[1].origin.x + 792 + 72)
    }

    @Test func duplicateCopiesThePageAndItsObjects() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        let object = try PageFixture.rect(&a, at: Point(x: 100, y: 100))
        try PageFixture.rect(&a, at: Point(x: 100, y: 3000))
        let change = try #require(try a.perform(DuplicatePage(page)))
        #expect(change.label == "Duplicate page")
        let list = PageList(a.state)
        #expect(list.pages.count == 2 && list.pages[1].origin == Point(x: 684, y: 0))
        let copies = PageObjects.objects(on: list.pages[1], in: a.state, pages: list)
        #expect(copies.count == 1 && copies[0].id != object)
        #expect(copies[0].bounds == Rect(x: 784, y: 100, width: 10, height: 10))
        a.undo()
        #expect(PageList(a.state).pages.count == 1)
    }

    @Test func removeFollowsTheStraddleRuleAndUndoRestores() throws {
        var a = Replica(0xA)
        _ = try PageFixture.onePage(&a)
        try a.perform(AddPages(count: 1))
        let second = PageList(a.state).pages[1]
        let inside = try PageFixture.rect(&a, at: Point(x: 700, y: 100))
        let straddling = try PageFixture.rect(&a, at: Point(x: 680, y: 100))
        let command = RemovePages([second.id], in: a.state)
        #expect(command.label == "Remove page 2")
        let change = try #require(try a.perform(command))
        #expect(change.label == "Remove page 2")
        #expect(PageList(a.state).pages.count == 1 && !a.state.isLive(inside) && a.state.isLive(straddling))
        a.undo()
        #expect(PageList(a.state).pages.count == 2 && a.state.isLive(inside))
        #expect(RemovePages([second.id]).label == "Remove page" && RemovePages([second.id, second.id]).label == "Remove 2 pages")
        // A document keeps one page.
        let list = PageList(a.state)
        #expect(throws: PageSetupError.lastPage) { try a.perform(RemovePages(list.pages.map(\.id))) }
        #expect(throws: PageSetupError.lastPage) { try Replica(0xB).state.trial(RemovePages([PageList.synthesizedID])) }
    }

    @Test func moveWithAndWithoutContents() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        let object = try PageFixture.rect(&a, at: Point(x: 100, y: 100))
        try a.perform(MovePage(page, by: Vector(dx: 50, dy: 20)))
        #expect(PageList(a.state).pages[0].origin == Point(x: 50, y: 20))
        #expect(Objects.bounds(of: object, in: a.state) == Rect(x: 150, y: 120, width: 10, height: 10))
        try a.perform(MovePage(page, by: Vector(dx: 10, dy: 0), withContents: false))
        #expect(PageList(a.state).pages[0].origin == Point(x: 60, y: 20))
        #expect(Objects.bounds(of: object, in: a.state)?.minX == 150)
        // The page stays on the pasteboard.
        try a.perform(MovePage(page, by: Vector(dx: -1000, dy: 0), withContents: false))
        #expect(PageList(a.state).pages[0].origin == Point(x: 0, y: 20))
        #expect(try a.perform(MovePage(page, by: Vector(dx: -10, dy: 0))) == nil)
        #expect(throws: PageSetupError.invalidValue("delta")) { try a.perform(MovePage(page, by: Vector(dx: .nan, dy: 0))) }
        #expect(MovePage(page, by: .zero).label == "Move page")
    }

    @Test func reorderRotateAndModify() throws {
        var a = Replica(0xA)
        _ = try a.perform(AddPages(count: 2))
        var ids = PageList(a.state).pages.map(\.id)
        let change = try #require(try a.perform(ReorderPage(ids[0], to: 3)))
        #expect(change.label == "Move page 3")
        #expect(PageList(a.state).pages.map(\.id) == [ids[1], ids[2], ids[0]])
        try a.perform(ReorderPage(ids[0], to: 1))
        #expect(PageList(a.state).pages.map(\.id) == ids)
        #expect(try a.perform(ReorderPage(ids[1], to: 2)) == nil)
        try a.perform(ReorderPage(ids[2], to: -5))
        ids = PageList(a.state).pages.map(\.id)
        let rotate = try #require(try a.perform(RotatePages([ids[0]])))
        #expect(rotate.label == "Rotate page" && RotatePages([ids[0], ids[1]]).label == "Rotate 2 pages")
        #expect(PageList(a.state).pages[0].geometry.orientation == .landscape && PageList(a.state).pages[0].geometry.width == 792)
        try a.perform(RotatePages([ids[0]]))
        #expect(PageList(a.state).pages[0].geometry == .letter)
        try a.perform(NewMasterPage(from: ids[0]))
        let master = PageList(a.state).masters[0].id
        let modify = try #require(try a.perform(ModifyPage(ids[1], geometry: PageGeometry(PagePreset.named("A4")!), bleed: 4, master: .some(master))))
        #expect(modify.label == "Modify page" && modify.ops.count == 1)
        let page = PageList(a.state).pages[1]
        #expect(page.ownGeometry.preset == "A4" && page.ownBleed == 4 && page.master == master)
        try a.perform(ModifyPage(ids[1], master: .some(nil)))
        #expect(!PageList(a.state).pages[1].isChild)
        #expect(try a.perform(ModifyPage(ids[1], bleed: 4)) == nil)
        #expect(throws: PageSetupError.invalidValue("geometry")) { try a.perform(ModifyPage(ids[1], geometry: PageGeometry(width: 0, height: 0))) }
        #expect(throws: PageSetupError.invalidValue("bleed")) { try a.perform(ModifyPage(ids[1], bleed: -2)) }
        #expect(throws: PageSetupError.notAPage(ids[0])) { try a.perform(ModifyPage(ids[1], master: .some(ids[0]))) }
        // A document without pages: reorder does nothing; modify writes the page.
        var b = Replica(0xB)
        #expect(try b.perform(ReorderPage(PageList.synthesizedID, to: 2)) == nil)
        try b.perform(ModifyPage(PageList.synthesizedID, bleed: 3))
        #expect(!PageList(b.state).isSynthesized && PageList(b.state).pages[0].bleed == 3)
    }

    @Test func mergeResizeVersusResizeLaterWinsWhole() throws {
        var pair = Pair()
        let page = try PageFixture.onePage(&pair.a)
        pair.sync()
        let a = try #require(try pair.a.perform(RotatePages([page])))
        let b = try #require(try pair.b.perform(SetPageGeometry([page], to: PageGeometry(PagePreset.named("A3")!))))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let geometry = PageList(pair.a.state).pages[0].geometry
        #expect(geometry == (PageFixture.later(a, b) ? PageGeometry.letter.oriented(.landscape) : PageGeometry(PagePreset.named("A3")!)))
    }

    @Test func mergeRemoveVersusCreateOnPageLeavesObjectsOnThePasteboard() throws {
        var pair = Pair()
        _ = try PageFixture.onePage(&pair.a)
        try pair.a.perform(AddPages(count: 1))
        pair.sync()
        let second = PageList(pair.a.state).pages[1].id
        try pair.a.perform(RemovePages([second]))
        let drawn = try PageFixture.rect(&pair.b, at: Point(x: 700, y: 100))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(pair.a.state.isLive(drawn))
        let list = PageList(pair.a.state)
        #expect(list.pages.count == 1 && list.page(ofBounds: Objects.bounds(of: drawn, in: pair.a.state)!) == nil)
        // Restore page: the object is on it again.
        try pair.a.perform(OpsCommand("Restore page", ops: [Ops.setDeleted(second, false)]))
        #expect(PageList(pair.a.state).page(ofBounds: Objects.bounds(of: drawn, in: pair.a.state)!)?.id == second)
    }

    @Test func mergeMoveVersusMoveObjectsFollowTheLaterDrag() throws {
        var pair = Pair()
        let page = try PageFixture.onePage(&pair.a)
        let object = try PageFixture.rect(&pair.a, at: Point(x: 100, y: 100))
        pair.sync()
        let a = try #require(try pair.a.perform(MovePage(page, by: Vector(dx: 100, dy: 0))))
        let b = try #require(try pair.b.perform(MovePage(page, by: Vector(dx: 0, dy: 300))))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let origin = PageList(pair.a.state).pages[0].origin
        let bounds = try #require(Objects.bounds(of: object, in: pair.a.state))
        #expect(origin == (PageFixture.later(a, b) ? Point(x: 100, y: 0) : Point(x: 0, y: 300)))
        #expect(bounds.origin == Point(x: 100 + origin.x, y: 100 + origin.y))
    }

    @Test func mergeReorderVersusReorderConverges() throws {
        var pair = Pair()
        try pair.a.perform(AddPages(count: 3))
        pair.sync()
        let ids = PageList(pair.a.state).pages.map(\.id)
        try pair.a.perform(ReorderPage(ids[0], to: 4))
        try pair.b.perform(ReorderPage(ids[3], to: 1))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let order = PageList(pair.a.state).pages.map(\.id)
        #expect(order.first == ids[3] && order.last == ids[0] && Set(order) == Set(ids))
        // The same page moved on both sides: one position wins.
        try pair.a.perform(ReorderPage(ids[1], to: 1))
        try pair.b.perform(ReorderPage(ids[1], to: 4))
        pair.sync()
        #expect(PageList(pair.a.state).pages.map(\.id) == PageList(pair.b.state).pages.map(\.id))
    }

    @Test func mergeBothPagesRemovedNormalizesToOnePageAndTheNextCommandWritesIt() throws {
        var pair = Pair()
        _ = try PageFixture.onePage(&pair.a)
        try pair.a.perform(AddPages(count: 1))
        pair.sync()
        let ids = PageList(pair.a.state).pages.map(\.id)
        try pair.a.perform(RemovePages([ids[0]]))
        try pair.b.perform(RemovePages([ids[1]]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let list = PageList(pair.a.state)
        #expect(list.isSynthesized && list.pages[0].geometry == .letter && list.pages[0].origin == .zero)
        // Nothing was written by reading.
        #expect(pair.a.state.liveChildren(WellKnown.pages).isEmpty)
        let change = try #require(try pair.a.perform(SetBleed([PageList.synthesizedID], to: 6)))
        #expect(change.createdNodes.count == 1)
        #expect(!PageList(pair.a.state).isSynthesized && PageList(pair.a.state).pages[0].bleed == 6)
    }
}

extension EngineState {
    /// Performs `command` on a scratch replica of this state (for commands expected to throw).
    func trial(_ command: any Command) throws {
        var builder = ChangeBuilder(replica: 0xF, startCounter: 1)
        try command.execute(&builder, state: self)
    }
}
