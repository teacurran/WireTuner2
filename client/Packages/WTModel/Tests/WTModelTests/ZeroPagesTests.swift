import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// DOC-006's zero-pages review detection (pages.adoc, "Merge semantics").
@Suite struct ZeroPagesTests {
    @Test func bothSidesRemovingTheTwoPagesIsDetectedAndTheNextCommandWritesAPage() throws {
        var pair = Pair()
        try pair.a.perform(AddPages(count: 1))
        pair.sync()
        let base = pair.a.state
        let pages = PageList(base).pages.map(\.id)
        #expect(pages.count == 2)
        let local = try #require(try pair.a.perform(RemovePages([pages[0]])))
        let remote = try #require(try pair.b.perform(RemovePages([pages[1]])))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(PageList(pair.a.state).isSynthesized)
        #expect(ZeroPages.removedOnBothSides(base: base, local: [local], remote: [remote], merged: pair.a.state))
        #expect(!ZeroPages.removedOnBothSides(base: base, local: [local], remote: [], merged: pair.a.state))
        #expect(!ZeroPages.removedOnBothSides(base: pair.a.state, local: [local], remote: [remote], merged: pair.a.state), "no live pages to start from")
        #expect(ZeroPages.removedOnBothSides(local: [local], remote: [remote], merged: pair.a.state))
        #expect(!ZeroPages.removedOnBothSides(local: [local], remote: [local], merged: pair.a.state), "one side's pages only")
        #expect(!ZeroPages.removedOnBothSides(local: [local], remote: [], merged: pair.a.state))
        // Changes that delete nothing are passed over.
        var other = Replica(0xC)
        let unrelated = try #require(try other.perform(AddPages(count: 1)))
        #expect(ZeroPages.removedOnBothSides(base: base, local: [unrelated, local], remote: [remote], merged: pair.a.state))
        #expect(ZeroPages.removedOnBothSides(local: [unrelated, local], remote: [remote], merged: pair.a.state))
        #expect(ZeroPages.reviewMessage == "All pages were removed; a page was added.")
        // The reconcile measurement's form, from the merged state alone (DOC-031).
        #expect(ZeroPages.removedOnBothSides(local: [local], remote: [remote], merged: pair.a.state))
        #expect(!ZeroPages.removedOnBothSides(local: [local], remote: [], merged: pair.a.state))
        #expect(!ZeroPages.removedOnBothSides(local: [local], remote: [remote], merged: base), "pages are left")
        var restoring = local
        restoring.ops = restoring.ops.map { op in
            var op = op
            if case .setDeleted(var delete)? = op.op { delete.deleted = false; op.op = .setDeleted(delete) }
            return op
        }
        #expect(!ZeroPages.removedOnBothSides(local: [restoring], remote: [remote], merged: pair.a.state), "a restore removes nothing")
        #expect(!ZeroPages.removedOnBothSides(base: base, local: [restoring], remote: [remote], merged: pair.a.state))
        // The first command that touches pages writes the page.
        let add = try #require(try pair.a.perform(AddPages(count: 1)))
        #expect(add.createdNodes.count == 2 && PageList(pair.a.state).pages.count == 2)
    }

    @Test func oneSideRemovingAPageIsNotTheCase() throws {
        var a = Replica(0xA)
        try a.perform(AddPages(count: 1))
        let base = a.state
        let change = try #require(try a.perform(RemovePages([PageList(base).pages[0].id])))
        #expect(!ZeroPages.removedOnBothSides(base: base, local: [change], remote: [change], merged: a.state), "a page is left")
        #expect(!ZeroPages.removedOnBothSides(local: [change], remote: [change], merged: a.state), "a page is left")
    }
}
