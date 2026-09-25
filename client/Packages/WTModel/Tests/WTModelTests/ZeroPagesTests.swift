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
        #expect(ZeroPages.reviewMessage == "All pages were removed; a page was added.")
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
    }
}
