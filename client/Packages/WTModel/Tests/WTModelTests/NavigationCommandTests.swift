import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Documents for the WEB-001 tests: a layer with objects, built through the commands.
enum NavigationFixture {
    /// A layer on `replica`; returns it.
    static func layer(_ replica: inout Replica, _ name: String = "Layer 1") throws -> OpID {
        try replica.perform(CreateLayer(name: name))!.createdNodes[0]
    }

    /// A rectangle on `layer`.
    static func rect(_ replica: inout Replica, on layer: OpID, x: Double = 0) throws -> OpID {
        try replica.perform(LayerFixture.rect(on: layer, x: x))!.createdObjects[0]
    }

    static func url(_ replica: Replica, _ node: OpID) -> String? {
        NavigationInfo(node, in: replica.state).url
    }

    /// Two live pages on `replica`.
    static func pages(_ replica: inout Replica) throws -> [OpID] {
        try replica.perform(AddPages(count: 2))
        return PageList(replica.state).pages.map(\.id)
    }
}

@Suite struct NavigationCommandTests {
    @Test func settingChangingAndClearingAnObjectLinkAreOneChangeEachWithInverses() throws {
        var a = Replica(1)
        let layer = try NavigationFixture.layer(&a)
        let rect = try NavigationFixture.rect(&a, on: layer)
        let set = try a.perform(SetLink([rect], url: "example.com"))!
        #expect(set.label == "Link" && set.ops.count == 1)
        #expect(NavigationFixture.url(a, rect) == "example.com")
        let change = try a.perform(SetLink([rect], url: "https://other.example"))!
        #expect(change.ops.count == 1)
        let clear = try a.perform(SetLink([rect], url: ""))!
        #expect(clear.label == "Remove Link")
        #expect(NavigationFixture.url(a, rect) == nil)
        a.undo()
        #expect(NavigationFixture.url(a, rect) == "https://other.example")
        a.undo()
        #expect(NavigationFixture.url(a, rect) == "example.com")
        a.undo()
        #expect(NavigationFixture.url(a, rect) == nil)
        #expect(a.core.undoStack.undoTitle == "Undo Rectangle")
    }

    @Test func severalObjectsChangeInOneLabelledChange() throws {
        var a = Replica(1)
        let layer = try NavigationFixture.layer(&a)
        let one = try NavigationFixture.rect(&a, on: layer)
        let two = try NavigationFixture.rect(&a, on: layer, x: 20)
        let change = try a.perform(SetLink([one, two, one], url: "https://a.example"))!
        #expect(change.label == "Change link on 3 objects")
        #expect(change.ops.count == 2)
        #expect(NavigationFixture.url(a, one) == "https://a.example" && NavigationFixture.url(a, two) == "https://a.example")
    }

    @Test func undoRestoresOnlyWhereTheRegisterIsStillThisUsersWrite() throws {
        var pair = Pair()
        let layer = try NavigationFixture.layer(&pair.a)
        let rect = try NavigationFixture.rect(&pair.a, on: layer)
        pair.sync()
        try pair.a.perform(SetLink([rect], url: "https://mine.example"))
        pair.sync()
        try pair.b.perform(SetLink([rect], url: "https://theirs.example"))
        pair.sync()
        pair.a.undo()
        pair.sync()
        #expect(NavigationFixture.url(pair.a, rect) == "https://theirs.example")
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }

    @Test func textRangeLinksAreMarksWithInverses() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "Order form here")
        let text = TextFixture.text(a, node)
        let change = try a.perform(SetTextLink(node: node, from: text.anchor(at: 0), to: text.anchor(at: 10), url: "https://order.example"))!
        #expect(change.label == "Link" && change.ops.count == 1)
        #expect(TextLinks.runs(node, in: a.state) == [TextLinks.Run(range: 0..<10, url: "https://order.example")])
        #expect(TextLinks.link(covering: 2..<5, in: TextFixture.text(a, node)) == "https://order.example")
        #expect(TextLinks.link(covering: 8..<12, in: TextFixture.text(a, node)) == nil)
        #expect(TextLinks.link(covering: 3..<3, in: TextFixture.text(a, node)) == nil)
        try a.perform(SetTextLink(node: node, from: text.anchor(at: 6), to: text.anchor(at: 10), url: "https://form.example"))
        #expect(TextLinks.runs(node, in: a.state).map(\.url) == ["https://order.example", "https://form.example"])
        let clear = try a.perform(SetTextLink(node: node, from: .start, to: .end, url: ""))!
        #expect(clear.label == "Remove Link")
        #expect(TextLinks.runs(node, in: a.state).isEmpty)
        a.undo()
        #expect(TextLinks.runs(node, in: a.state).count == 2)
        a.undo()
        a.undo()
        #expect(TextLinks.runs(node, in: a.state).isEmpty)
        // Typing at the end of a link does not extend it (links never grow, TYPE pages).
        try a.perform(SetTextLink(node: node, from: text.anchor(at: 0), to: text.anchor(at: 5), url: "https://x.example"))
        try a.perform(InsertText(node: node, text: "Z", at: TextFixture.text(a, node).anchor(at: 5)))
        #expect(TextLinks.runs(node, in: a.state) == [TextLinks.Run(range: 0..<5, url: "https://x.example")])
        #expect(TextLinks.runs(OpID(counter: 999, replica: 9), in: a.state).isEmpty)
    }

    @Test func altTargetAndPageLinkReadWithTheirNormalizations() throws {
        var a = Replica(1)
        let layer = try NavigationFixture.layer(&a)
        let rect = try NavigationFixture.rect(&a, on: layer)
        let pages = try NavigationFixture.pages(&a)
        #expect(NavigationInfo(rect, in: a.state) == NavigationInfo())
        #expect(NavigationInfo(rect, in: a.state).onClick == .nothing)
        #expect(try a.perform(SetLinkAlt([rect], alt: "Order form"))!.label == "Link Alt Text")
        #expect(try a.perform(SetLinkTarget([rect], target: .newTab))!.label == "Opens In")
        try a.perform(SetLink([rect], url: "   "))
        var info = NavigationInfo(rect, in: a.state)
        #expect(info.alt == "Order form" && info.target == .newTab && info.url == nil)
        try a.perform(SetLink([rect], url: "https://a.example"))
        #expect(NavigationInfo(rect, in: a.state).onClick == .openLink("https://a.example"))
        let link = try a.perform(SetGoToPage([rect], page: pages[1], pageNumber: 2))!
        #expect(link.label == "Link to page 2")
        #expect(SetGoToPage([rect], page: pages[1]).label == "Link to page")
        info = NavigationInfo(rect, in: a.state)
        #expect(info.goToPage == pages[1] && info.onClick == .goToPage(pages[1]) && info.hasUnusedLink)
        // Deleting the target page leaves the reference dangling: it reads unset, nothing is written.
        try a.perform(RemovePages([pages[1]]))
        info = NavigationInfo(rect, in: a.state)
        #expect(info.goToPage == nil && info.danglingPage == pages[1] && info.onClick == .openLink("https://a.example"))
        a.undo()
        #expect(NavigationInfo(rect, in: a.state).goToPage == pages[1])
        let clear = try a.perform(SetGoToPage([rect], page: nil))!
        #expect(clear.label == "Remove page link")
        info = NavigationInfo(rect, in: a.state)
        #expect(info.goToPage == nil && info.danglingPage == nil && info.url == "https://a.example")
        #expect(NavigationInfo(OpID(counter: 999, replica: 9), in: a.state) == NavigationInfo())
    }

    @Test func refusesWhatCannotCarryALink() throws {
        var a = Replica(1)
        let layer = try NavigationFixture.layer(&a)
        let rect = try NavigationFixture.rect(&a, on: layer)
        #expect(throws: NavigationError.notLinkable(layer)) { try a.perform(SetLink([layer], url: "x")) }
        #expect(throws: NavigationError.notLinkable(WellKnown.settings)) { try a.perform(SetLinkAlt([WellKnown.settings], alt: "x")) }
        #expect(throws: NavigationError.tooLong("url")) { try a.perform(SetLink([rect], url: String(repeating: "a", count: 2049))) }
        #expect(throws: NavigationError.tooLong("url")) {
            try a.perform(SetTextLink(node: rect, from: .start, to: .end, url: String(repeating: "a", count: 2049)))
        }
        #expect(throws: NavigationError.tooLong("alt")) { try a.perform(SetLinkAlt([rect], alt: String(repeating: "a", count: 1025))) }
        #expect(throws: NavigationError.notAPage(rect)) { try a.perform(SetGoToPage([rect], page: rect)) }
        #expect(throws: NavigationError.tooLong("url")) { try a.perform(ReplaceLink(LinkUses(nodes: [rect]), with: String(repeating: "a", count: 2049))) }
        // A deleted object is still linkable (its link comes back with it); an orphan is not.
        try a.perform(DeleteNodes([rect]))
        #expect(NavigationFields.isLinkable(rect, in: a.state) == false)
        #expect(Reachability.root(of: rect, in: a.state) == nil)
    }

    @Test func linksLiveOnAnyKindThroughItsCommonProps() throws {
        var a = Replica(1)
        let layer = try NavigationFixture.layer(&a)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.svgAnimation.naturalSize.width = 10
        let node = try a.perform(OpsCommand("Place", ops: [Ops.create(parent: layer, position: [0x80], props: props)]))!.createdNodes[0]
        try a.perform(SetLink([node], url: "https://anim.example"))
        try a.perform(SetLinkTarget([node], target: .newTab))
        #expect(a.state.props(node).svgAnimation.common.url == "https://anim.example")
        #expect(a.state.props(node).svgAnimation.naturalSize.width == 10)
        #expect(NavigationInfo(node, in: a.state).target == .newTab)
        #expect(NavigationFields.url(190) == RegisterPath([190, 1, 6]))
        #expect(WireFields.payload(of: 1, in: [0xFF]) == nil)
        #expect(WireFields.payload(of: 1, in: [0x09, 1, 2, 3, 4, 5, 6, 7, 8, 0x15, 1, 2, 3, 4]) == nil)
        #expect(WireFields.payload(of: 1, in: [0x0B]) == nil)
        #expect(WireFields.payload(of: 1, in: [0x08, 0x96]) == nil)
    }
}

@Suite struct NavigationMergeTests {
    struct Shared {
        var pair = Pair()
        var layer: OpID
        var rect: OpID

        init() throws {
            layer = try NavigationFixture.layer(&pair.a)
            rect = try NavigationFixture.rect(&pair.a, on: layer)
            pair.sync()
        }

        mutating func converge() {
            pair.sync()
            #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        }
    }

    @Test func concurrentDifferentURLsConvergeOnTheGreaterOpID() throws {
        var s = try Shared()
        try s.pair.a.perform(SetLink([s.rect], url: "https://a.example"))
        try s.pair.b.perform(SetLink([s.rect], url: "https://b.example"))
        s.converge()
        // Same counters, replica 0xB > 0xA.
        #expect(NavigationFixture.url(s.pair.a, s.rect) == "https://b.example")
        #expect(!s.pair.a.state.losingWrites(s.rect, NavigationFields.url(21)).isEmpty)
    }

    @Test func altAndTargetFromTwoPeopleBothStand() throws {
        var s = try Shared()
        try s.pair.a.perform(SetLinkAlt([s.rect], alt: "Company home page"))
        try s.pair.b.perform(SetLinkTarget([s.rect], target: .newTab))
        s.converge()
        let info = NavigationInfo(s.rect, in: s.pair.a.state)
        #expect(info.alt == "Company home page" && info.target == .newTab)
    }

    @Test func overlappingTextLinksConvergePerTheMarkRules() throws {
        var pair = Pair()
        let node = try TextFixture.block(&pair.a, "abcdefgh")
        pair.sync()
        let text = TextFixture.text(pair.a, node)
        try pair.a.perform(SetTextLink(node: node, from: text.anchor(at: 0), to: text.anchor(at: 5), url: "https://a.example"))
        try pair.b.perform(SetTextLink(node: node, from: text.anchor(at: 3), to: text.anchor(at: 8), url: "https://b.example"))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        // In the overlap d-e the greater OpId (B's) wins; outside it each range keeps its own.
        #expect(TextLinks.runs(node, in: pair.a.state) == [
            TextLinks.Run(range: 0..<3, url: "https://a.example"), TextLinks.Run(range: 3..<8, url: "https://b.example"),
        ])
    }

    @Test func aLinkGrowsOverTextTypedInsideItAndVanishesWithDeletedCharacters() throws {
        var pair = Pair()
        let node = try TextFixture.block(&pair.a, "abcdef")
        pair.sync()
        let text = TextFixture.text(pair.a, node)
        try pair.a.perform(SetTextLink(node: node, from: text.anchor(at: 1), to: text.anchor(at: 4), url: "https://a.example"))
        try pair.b.perform(InsertText(node: node, text: "XY", at: text.anchor(at: 2)))
        try pair.b.perform(DeleteText(node: node, from: text.anchor(at: 3), to: text.anchor(at: 4)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(TextFixture.text(pair.a, node).string == "abXYcef")
        #expect(TextLinks.runs(node, in: pair.a.state) == [TextLinks.Run(range: 1..<5, url: "https://a.example")])
    }

    @Test func aLinkWrittenToADeletedObjectComesBackWithIt() throws {
        var s = try Shared()
        try s.pair.a.perform(DeleteNodes([s.rect]))
        try s.pair.b.perform(SetLink([s.rect], url: "https://b.example"))
        s.converge()
        #expect(!s.pair.a.state.isLive(s.rect))
        try s.pair.a.perform(OpsCommand("Restore", ops: [Ops.setDeleted(s.rect, false)]))
        s.converge()
        #expect(NavigationFixture.url(s.pair.b, s.rect) == "https://b.example")
    }

    @Test func concurrentPageTargetsConvergeAndADeletedPageDanglesWithoutAWrite() throws {
        var s = try Shared()
        let pages = try NavigationFixture.pages(&s.pair.a)
        s.pair.sync()
        try s.pair.a.perform(SetGoToPage([s.rect], page: pages[0]))
        try s.pair.b.perform(SetGoToPage([s.rect], page: pages[1]))
        s.converge()
        #expect(NavigationInfo(s.rect, in: s.pair.a.state).goToPage == pages[1])
        let before = s.pair.b.sent.count
        try s.pair.a.perform(RemovePages([pages[1]]))
        s.converge()
        #expect(s.pair.b.sent.count == before)
        #expect(NavigationInfo(s.rect, in: s.pair.b.state).danglingPage == pages[1])
    }

    @Test func updateEverywhereLeavesAConcurrentAttachOfTheOldLinkAlone() throws {
        var s = try Shared()
        let text = try TextFixture.block(&s.pair.a, "linked words")
        try s.pair.a.perform(SetLink([s.rect], url: "https://old.example"))
        try s.pair.a.perform(SetTextLink(node: text, from: .start, to: TextFixture.at(s.pair.a, text, 6), url: "https://old.example"))
        s.pair.sync()
        let uses = LinkIndex(s.pair.a.state).uses(of: "https://old.example", in: s.pair.a.state)
        #expect(uses.count == 2)
        let rewrite = try s.pair.a.perform(ReplaceLink(uses, with: "https://new.example"))!
        #expect(rewrite.label == "Change link on 2 objects")
        #expect(ReplaceLink(LinkUses(nodes: [s.rect]), with: "").label == "Remove Link")
        #expect(ReplaceLink(LinkUses(nodes: [s.rect]), with: "x").label == "Link")
        let fresh = try NavigationFixture.rect(&s.pair.b, on: s.layer, x: 50)
        try s.pair.b.perform(SetLink([fresh], url: "https://old.example"))
        s.converge()
        let index = LinkIndex(s.pair.a.state)
        #expect(index.uses(of: "https://new.example", in: s.pair.a.state).count == 2)
        #expect(index.uses(of: "https://old.example", in: s.pair.a.state).nodes == [fresh])
        // Undo restores every rewritten link in one step.
        s.pair.a.undo()
        s.converge()
        #expect(LinkIndex(s.pair.a.state).uses(of: "https://old.example", in: s.pair.a.state).count == 3)
    }
}
