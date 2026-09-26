import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// WEB-022: the Link tool's release rule.
@Suite struct PageLinkDragTests {
    /// Two pages and a rectangle on the first.
    static func document(_ replica: inout Replica) throws -> (pages: [Page], rect: OpID) {
        _ = try NavigationFixture.pages(&replica)
        let pages = PageList(replica.state).pages
        let layer = try NavigationFixture.layer(&replica)
        let origin = pages[0].origin
        let rect = try replica.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 20),
                                                   transform: .translation(x: origin.x + 50, y: origin.y + 50), layer: layer))!.createdObjects[0]
        return (pages, rect)
    }

    static func center(_ page: Page) -> Point { Point(x: page.rect.midX, y: page.rect.midY) }

    @Test func aDropOnAnotherPageLinksAndOnTheOwnPageClears() throws {
        var a = Replica(1)
        let (pages, rect) = try Self.document(&a)
        #expect(PageLinkDrag.isLinkable(rect, in: a.state))
        let outcome = PageLinkDrag.outcome(source: rect, drop: Self.center(pages[1]), option: false, in: a.state)
        #expect(outcome == .link(page: pages[1].id, number: 2))
        let command = try #require(PageLinkDrag.command(source: rect, outcome: outcome))
        let change = try #require(try a.perform(command))
        #expect(change.label == "Link to page 2" && change.ops.count == 1)
        #expect(NavigationInfo(rect, in: a.state).goToPage == pages[1].id)
        // The own page: clears; with Option: links to it.
        let own = PageLinkDrag.outcome(source: rect, drop: Self.center(pages[0]), option: false, in: a.state)
        #expect(own == .clear && PageLinkDrag.command(source: rect, outcome: own)?.label == "Remove page link")
        let back = PageLinkDrag.outcome(source: rect, drop: Self.center(pages[0]), option: true, in: a.state)
        #expect(back == .link(page: pages[0].id, number: 1))
        _ = try a.perform(PageLinkDrag.command(source: rect, outcome: own)!)
        #expect(NavigationInfo(rect, in: a.state).goToPage == nil)
        #expect(PageLinkDrag.outcome(source: rect, drop: Self.center(pages[0]), option: false, in: a.state) == .nothing, "nothing to remove")
        #expect(PageLinkDrag.outcome(source: rect, drop: Point(x: -5000, y: -5000), option: false, in: a.state) == .nothing, "the pasteboard")
        #expect(PageLinkDrag.command(source: rect, outcome: .nothing) == nil)
    }

    @Test func lockedObjectsAndTheSynthesizedPageAreRefused() throws {
        var a = Replica(1)
        let layer = try NavigationFixture.layer(&a)
        let rect = try NavigationFixture.rect(&a, on: layer)
        #expect(PageLinkDrag.page(at: Point(x: 5, y: 5), in: PageList(a.state)) == nil, "a document without pages")
        #expect(PageLinkDrag.outcome(source: rect, drop: Point(x: 5, y: 5), option: true, in: a.state) == .nothing)
        _ = try a.perform(SetLocked([rect], locked: true))
        #expect(!PageLinkDrag.isLinkable(rect, in: a.state))
        #expect(!PageLinkDrag.isLinkable(OpID(counter: 999, replica: 1), in: a.state))
    }

    @Test func twoReplicasLinkingOneObjectConvergeOnOnePage() throws {
        var pair = Pair()
        let (pages, rect) = try Self.document(&pair.a)
        pair.sync()
        try pair.a.perform(PageLinkDrag.command(source: rect, outcome: .link(page: pages[1].id, number: 2))!)
        try pair.b.perform(PageLinkDrag.command(source: rect, outcome: .link(page: pages[0].id, number: 1))!)
        pair.sync()
        let a = NavigationInfo(rect, in: pair.a.state).goToPage
        #expect(a != nil && a == NavigationInfo(rect, in: pair.b.state).goToPage)
    }
}
