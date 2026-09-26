import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// Linked text flows (TYPE-007, text-blocks.adoc, "Linking text blocks").
@Suite struct TextChainsTests {
    static func area(_ replica: inout Replica, _ text: String = "", x: Double = 0, y: Double = 0, width: Double = 120, height: Double = 30) throws -> OpID {
        try #require(try replica.perform(CreateTextBlock(.area(Rect(x: x, y: y, width: width, height: height)), text: text))).createdObjects[0]
    }

    /// Writes raw link registers, as a remote replica or an old client might.
    static func write(_ replica: inout Replica, _ node: OpID, next: OpID? = nil, previous: OpID? = nil) throws {
        var ops: [Wiretuner_Doc_V1_Op] = []
        if let next { ops.append(TextChains.set(node, TextLinkFields.next, to: next)) }
        if let previous { ops.append(TextChains.set(node, TextLinkFields.previous, to: previous)) }
        try replica.perform(OpsCommand("Link", ops: ops))
    }

    static let story = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)

    // MARK: Reading

    @Test func chainsReadThroughReciprocalLinksOnly() throws {
        var a = Replica(0xA)
        let x = try Self.area(&a, "story")
        let y = try Self.area(&a, y: 50)
        let z = try Self.area(&a, y: 100)
        try a.perform(LinkTextBlocks(from: x, to: y))
        try a.perform(LinkTextBlocks(from: y, to: z))
        #expect(TextChains.chain(of: z, in: a.state) == [x, y, z])
        #expect(TextChains.head(of: z, in: a.state) == x && TextChains.next(x, in: a.state) == y && TextChains.previous(z, in: a.state) == y)
        #expect(TextChains.isDormant(y, in: a.state) && !TextChains.isDormant(x, in: a.state))
        #expect(TextChains.isLinked(z, in: a.state) && !TextChains.isCut(x, in: a.state))
        // A next_link whose target names someone else back reads unset; so does one to a non-text node.
        let w = try Self.area(&a, y: 150)
        try Self.write(&a, w, next: z)
        #expect(TextChains.next(w, in: a.state) == nil && TextChains.previous(z, in: a.state) == y)
        let rect = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 5, height: 5)), on: &a)
        try Self.write(&a, w, next: rect)
        #expect(TextChains.next(w, in: a.state) == nil && TextChains.chain(of: w, in: a.state) == [w])
        #expect(TextChains.chain(of: rect, in: a.state) == [rect] && TextChains.previous(rect, in: a.state) == nil)
        // A deleted target reads unset and ends the chain.
        try a.perform(OpsCommand("Delete", ops: [Ops.setDeleted(z)]))
        #expect(TextChains.chain(of: x, in: a.state) == [x, y])
    }

    @Test func aLoopIsCutAtItsSmallestMember() throws {
        var a = Replica(0xA)
        let x = try Self.area(&a, "x")
        let y = try Self.area(&a, "y", y: 50)
        try Self.write(&a, x, next: y, previous: y)
        try Self.write(&a, y, next: x, previous: x)
        let (small, large) = (min(x, y), max(x, y))
        #expect(TextChains.next(small, in: a.state) == nil && TextChains.isCut(small, in: a.state))
        #expect(TextChains.next(large, in: a.state) == small && TextChains.chain(of: small, in: a.state) == [large, small])
        #expect(TextChains.head(of: small, in: a.state) == large)
        #expect(TextChains.cycle(through: large, in: a.state)?.count == 2)
    }

    // MARK: Link and unlink

    @Test func linkingWritesBothRegistersAndReplacesEarlierLinks() throws {
        var a = Replica(0xA)
        let x = try Self.area(&a, "story")
        let y = try Self.area(&a, y: 50)
        let z = try Self.area(&a, y: 100)
        let w = try Self.area(&a, "w", y: 150)
        let change = try #require(try a.perform(LinkTextBlocks(from: x, to: y)))
        #expect(change.label == "Link text blocks" && change.ops.count == 2)
        #expect(a.state.props(x).text.nextLink.id == y.proto && a.state.props(y).text.prevLink.id == x.proto)
        // Relinking X to Z frees Y.
        try a.perform(LinkTextBlocks(from: x, to: z))
        #expect(!a.state.props(y).text.hasPrevLink && TextChains.chain(of: x, in: a.state) == [x, z])
        // Linking Y to Z takes Z from X.
        try a.perform(LinkTextBlocks(from: y, to: z))
        #expect(!a.state.props(x).text.hasNextLink && TextChains.chain(of: z, in: a.state) == [y, z])
        // Refused: a block with text, a loop, itself, a rectangle.
        #expect(!LinkTextBlocks.canLink(from: z, to: w, in: a.state))
        #expect(!LinkTextBlocks.canLink(from: z, to: y, in: a.state))
        #expect(!LinkTextBlocks.canLink(from: z, to: z, in: a.state))
        let rect = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 5, height: 5)), on: &a)
        #expect(!LinkTextBlocks.canLink(from: z, to: rect, in: a.state) && !LinkTextBlocks.canLink(from: rect, to: x, in: a.state))
        #expect(throws: TextLinkError.loop(y)) { try a.perform(LinkTextBlocks(from: z, to: y)) }
        // Unlink clears both; nothing to unlink is refused.
        let unlink = try #require(try a.perform(UnlinkTextBlocks(y)))
        #expect(unlink.label == "Unlink text blocks" && !a.state.props(z).text.hasPrevLink && !a.state.props(y).text.hasNextLink)
        #expect(!UnlinkTextBlocks.canUnlink(y, in: a.state))
        #expect(throws: TextLinkError.notABlock(y)) { try a.perform(UnlinkTextBlocks(y)) }
        a.undo()
        #expect(TextChains.chain(of: y, in: a.state) == [y, z])
    }

    @Test func linkingOntoAPathMakesItATextContainer() throws {
        var a = Replica(0xA)
        let x = try Self.area(&a, Self.story)
        let path = try LayerFixture.object(PathFixture.closed([(0, 100), (200, 100), (200, 300), (0, 300)]), on: &a)
        #expect(LinkTextBlocks.canLink(from: x, to: path, in: a.state))
        try a.perform(LinkTextBlocks(from: x, to: path))
        let container = try #require(TextChains.next(x, in: a.state))
        #expect(a.state.nodeKind(container) == .text && a.state.props(container).text.onPath.mode == .inside)
        #expect(Objects.parent(of: path, in: a.state) == container)
        let text = try #require(TextNode(container, in: a.state))
        #expect(TextLayoutReading.path(of: text, in: a.state) == path)
        #expect(LinkTextBlocks.canStart(container, in: a.state), "text inside a path links onward")
        // The path now holds text: it takes no second flow.
        let other = try Self.area(&a, y: 400)
        #expect(!LinkTextBlocks.canLink(from: other, to: path, in: a.state))
        // Text along a path has no link box.
        let along = try Self.area(&a, "along", y: 500)
        let curve = try LayerFixture.object(PathFixture.open([(0, 600), (100, 650)]), on: &a)
        try a.perform(AttachTextToPath(text: along, path: curve))
        #expect(!LinkTextBlocks.canStart(along, in: a.state))
    }

    // MARK: Delete and splice

    @Test func deletingAMiddleBlockClosesTheGap() throws {
        var a = Replica(0xA)
        let x = try Self.area(&a, Self.story)
        let y = try Self.area(&a, y: 50)
        let z = try Self.area(&a, y: 100)
        try a.perform(LinkTextBlocks(from: x, to: y))
        try a.perform(LinkTextBlocks(from: y, to: z))
        try a.perform(ClearObjects([y]))
        #expect(TextChains.chain(of: x, in: a.state) == [x, z])
        #expect(a.state.props(x).text.nextLink.id == z.proto && a.state.props(z).text.prevLink.id == x.proto)
        a.undo()
        #expect(TextChains.chain(of: x, in: a.state) == [x, y, z])
        // The last two go: the head's link is cleared.
        try a.perform(DeleteNodes([y, z]))
        #expect(!a.state.props(x).text.hasNextLink)
        a.undo()
        // The head goes: nothing is written for the links, the next block reads as a head.
        let change = try #require(try a.perform(DeleteNodes([x])))
        #expect(change.ops.count == 1 && TextChains.chain(of: y, in: a.state) == [y, z])
        a.undo()
        // A middle block inside a deleted group.
        let group = try #require(try a.perform(GroupObjects([y]))).createdObjects[0]
        try a.perform(DeleteNodes([group]))
        #expect(TextChains.chain(of: x, in: a.state) == [x, z])
    }

    // MARK: Layout

    @MainActor
    @Test func aThreeBlockChainAcrossTwoPagesReflowsWhenTheFirstBlocksFontGrows() throws {
        var a = Replica(0xA)
        try a.perform(AddPages(count: 1))
        let pages = PageList(a.state).pages
        let x = try Self.area(&a, Self.story, x: pages[0].origin.x + 36, y: pages[0].origin.y + 36, width: 200, height: 60)
        let y = try Self.area(&a, x: pages[0].origin.x + 36, y: pages[0].origin.y + 200, width: 200, height: 60)
        let z = try Self.area(&a, x: pages[1].origin.x + 36, y: pages[1].origin.y + 36, width: 200, height: 400)
        try a.perform(LinkTextBlocks(from: x, to: y))
        try a.perform(LinkTextBlocks(from: y, to: z))
        let engine = TextLayoutEngine()
        func characters(in container: Int, _ layout: TextLayout) -> Int {
            let counts = (0..<layout.containers.count).map(layout.lineCount(inContainer:))
            let start = counts.prefix(container).reduce(0, +)
            return layout.lineRanges[start..<start + counts[container]].reduce(0) { $0 + $1.count }
        }
        let (before, chain) = try #require(TextLayoutReading.chainLayout(y, engine: engine, state: a.state))
        #expect(chain == [x, y, z] && before.containers.count == 3 && !before.overflows)
        let first = characters(in: 0, before)
        #expect(first > 0 && characters(in: 1, before) > 0 && characters(in: 2, before) > 0)
        try a.perform(ApplyMark(node: x, from: TextFixture.at(a, x, 0), to: .end, value: TextFixture.size(24)))
        let (after, _) = try #require(TextLayoutReading.chainLayout(x, engine: engine, state: a.state))
        #expect(characters(in: 0, after) < first, "the first block's last lines move on")
        // Each member draws its own container of the head's flow; a block in no chain is laid out alone.
        #expect(TextLayoutReading.item(z, in: a.state, engine: engine) != nil)
        #expect(TextLayoutReading.sources(z, in: a.state).contains(x))
        let lone = try Self.area(&a, "alone", y: 900)
        #expect(TextLayoutReading.chainLayout(lone, engine: engine, state: a.state) == nil)
        #expect(TextLayoutReading.chainLayout(pages[0].id, engine: engine, state: a.state) == nil)
    }

    // MARK: Merge

    @Test func twoReplicasLinkingTheSameBlockToDifferentTargetsConverge() throws {
        var pair = Pair()
        let x = try Self.area(&pair.a, Self.story)
        let y = try Self.area(&pair.a, y: 50)
        let z = try Self.area(&pair.a, y: 100)
        pair.sync()
        try pair.a.perform(LinkTextBlocks(from: x, to: y))
        try pair.b.perform(LinkTextBlocks(from: x, to: z))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        for replica in [pair.a, pair.b] {
            let winner = try #require(TextChains.next(x, in: replica.state))
            let loser = winner == y ? z : y
            #expect(TextChains.chain(of: x, in: replica.state) == [x, winner])
            #expect(TextChains.previous(loser, in: replica.state) == nil && TextChains.head(of: loser, in: replica.state) == loser, "the loser is a head")
            #expect(TextNode(x, in: replica.state)?.string == Self.story, "no text is lost")
        }
    }

    @MainActor
    @Test func concurrentOpposingLinksConvergeToTheSameCutChain() throws {
        var pair = Pair()
        let x = try Self.area(&pair.a, "x")
        let y = try Self.area(&pair.a, y: 50)
        pair.sync()
        // Each replica links one way (Y is empty on A's side, X is emptied on B's side first).
        try pair.a.perform(LinkTextBlocks(from: x, to: y))
        try pair.b.perform(DeleteText(node: x, from: TextFixture.at(pair.b, x, 0), to: .end))
        try pair.b.perform(LinkTextBlocks(from: y, to: x))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        let small = min(x, y)
        for replica in [pair.a, pair.b] {
            #expect(TextChains.isCut(small, in: replica.state) && TextChains.chain(of: small, in: replica.state) == [max(x, y), small])
        }
    }
}
