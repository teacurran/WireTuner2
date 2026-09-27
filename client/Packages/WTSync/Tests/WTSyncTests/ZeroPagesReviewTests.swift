import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// DOC-006's review entry (pages.adoc, "Merge semantics"): both sides removing different pages of
/// a two-page document leaves none; the review lists "All pages were removed; a page was added."
/// (no choice, so it asks at least *Review what changed* and holds nothing).
@Suite struct ZeroPagesReviewTests {
    @Test func removingBothPagesOnTwoSidesIsListedWithoutHoldingTheOutbox() throws {
        var world = Reconnect()
        try world.shared(AddPages(count: 1))
        let pages = PageList(world.mine.state).pages.map(\.id)
        #expect(pages.count == 2)
        try world.byMe(RemovePages([pages[0]]))
        try world.byThem(RemovePages([pages[1]]))
        let divergence = world.measure()
        #expect(divergence.zeroPages && divergence.hasRows && divergence.overlapCount == 0)
        #expect(divergence.decision(.standard) == .suggestReview)
        let review = ReviewModel(divergence, decision: .suggestReview)
        #expect(review.zeroPages && !review.holdsOutbox)
        // The next command that touches pages writes the page on both sides.
        try world.byMe(AddPages(count: 1))
        world.upload()
        #expect(PageList(world.theirs.state).pages.count == 2)
    }

    @Test func oneSideRemovingAPageIsNotListed() throws {
        var world = Reconnect()
        try world.shared(AddPages(count: 1))
        let pages = PageList(world.mine.state).pages.map(\.id)
        try world.byMe(RemovePages([pages[0]]))
        try world.byThem(SetNameOrNote([], .name, "x"))
        #expect(!world.measure().zeroPages)
    }
}
