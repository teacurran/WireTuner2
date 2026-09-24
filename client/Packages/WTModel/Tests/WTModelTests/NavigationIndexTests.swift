import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The link index (WEB-001, `DocumentIndex.links`): kept incrementally, it equals a full scan
/// after any sequence of local and remote changes.
@Suite struct NavigationIndexTests {
    /// A replica with its incrementally maintained index.
    struct Indexed {
        var replica: Replica
        var index = LinkIndex()
        var received = 0

        init(_ id: UInt64) {
            replica = Replica(id)
        }

        mutating func perform(_ command: any Command) throws -> Wiretuner_Doc_V1_Change? {
            let change = try replica.perform(command)
            if let change { index.apply(change, state: replica.state) }
            return change
        }

        mutating func undo() {
            if let change = replica.undo() { index.apply(change, state: replica.state) }
        }

        mutating func receive(from other: Indexed) {
            let changes = Array(other.replica.sent[received...])
            for change in changes {
                replica.receive([change])
                index.apply(change, state: replica.state)
            }
            received = other.replica.sent.count
        }

        /// The links as a full scan reads them, independently of `LinkIndex`.
        var scanned: [String: LinkUses] {
            let state = replica.state
            var result: [String: LinkUses] = [:]
            for node in state.store.nodes.sorted() where Reachability.isReachable(node, in: state) && NavigationFields.isLinkableKind(state.store.kind(node)) {
                if let url = NavigationInfo(node, in: state).url { result[url, default: LinkUses()].nodes.append(node) }
                for run in TextLinks.runs(node, in: state) { result[run.url, default: LinkUses()].ranges.append(.init(node: node, range: run.range)) }
            }
            return result
        }

        func check() {
            #expect(index.links(in: replica.state) == scanned)
            #expect(LinkIndex(replica.state).links(in: replica.state) == scanned)
        }
    }

    /// A small deterministic generator (SplitMix64).
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let urls = ["https://a.example", "https://b.example", "mailto:x@example.com", ""]

    /// One random edit on `side`.
    static func step(_ side: inout Indexed, layer: OpID, _ random: inout Generator) throws {
        let state = side.replica.state
        let objects = state.store.nodes.filter { Objects.isObject($0, in: state) && state.isLive($0) && Reachability.isReachable($0, in: state) }.sorted()
        let texts = objects.filter { state.store.kind($0) == TextFields.kind }
        let url = urls.randomElement(using: &random)!
        switch Int.random(in: 0..<11, using: &random) {
        case 0:
            _ = try side.perform(LayerFixture.rect(on: layer, x: Double.random(in: 0...100, using: &random)))
        case 1:
            _ = try side.perform(CreateTextBlock(.point(Point(x: 0, y: Double.random(in: 0...50, using: &random))), text: "linked text", layer: layer))
        case 2, 3:
            guard let node = objects.randomElement(using: &random) else { return }
            _ = try side.perform(SetLink([node], url: url))
        case 4:
            guard let node = texts.randomElement(using: &random), let text = TextNode(node, in: state), text.length > 2 else { return }
            let start = Int.random(in: 0..<text.length - 1, using: &random)
            let end = Int.random(in: start + 1...text.length, using: &random)
            _ = try side.perform(SetTextLink(node: node, from: text.anchor(at: start), to: text.anchor(at: end), url: url))
        case 5:
            guard let node = texts.randomElement(using: &random), let text = TextNode(node, in: state), text.length > 3 else { return }
            let start = Int.random(in: 0..<text.length - 2, using: &random)
            _ = try side.perform(DeleteText(node: node, from: text.anchor(at: start), to: text.anchor(at: start + 2)))
        case 6:
            guard let node = texts.randomElement(using: &random), let text = TextNode(node, in: state) else { return }
            _ = try side.perform(InsertText(node: node, text: "xy", at: text.anchor(at: Int.random(in: 0...text.length, using: &random))))
        case 7:
            guard let node = objects.randomElement(using: &random) else { return }
            _ = try side.perform(DeleteNodes([node]))
        case 8:
            let deleted = state.store.nodes.filter { state.store.exists($0) && !state.isLive($0) && Objects.kinds.contains(state.nodeKind($0) ?? .layer) }.sorted()
            guard let node = deleted.randomElement(using: &random) else { return }
            _ = try side.perform(OpsCommand("Restore", ops: [Ops.setDeleted(node, false)]))
        case 9:
            let top = objects.filter { Objects.parent(of: $0, in: state) == layer }
            guard top.count >= 2 else { return }
            let pick = Array(top.shuffled(using: &random).prefix(2))
            _ = try? side.perform(GroupObjects(pick, layer: layer))
        default:
            side.undo()
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6])
    func indexEqualsAFullScanAfterAnySequenceOfLocalAndRemoteChanges(seed: Int) throws {
        var random = Generator(state: UInt64(seed))
        var a = Indexed(0xA)
        var b = Indexed(0xB)
        let layer = try #require(try a.perform(CreateLayer(name: "Layer 1"))?.createdNodes.first)
        b.receive(from: a)
        a.received = b.replica.sent.count
        for _ in 0..<60 {
            if Bool.random(using: &random) {
                try Self.step(&a, layer: layer, &random)
                a.check()
            } else {
                try Self.step(&b, layer: layer, &random)
                b.check()
            }
            if Int.random(in: 0..<4, using: &random) == 0 {
                b.receive(from: a)
                a.receive(from: b)
                a.check()
                b.check()
            }
        }
        b.receive(from: a)
        a.receive(from: b)
        #expect(a.replica.state.stateHash == b.replica.state.stateHash)
        #expect(a.index.links(in: a.replica.state) == b.index.links(in: b.replica.state))
        a.check()
        b.check()
    }

    @Test func deletingAContainerDropsItsLinksAndRestoringBringsThemBack() throws {
        var a = Indexed(1)
        let layer = try #require(try a.perform(CreateLayer(name: "Layer 1"))?.createdNodes.first)
        let one = try #require(try a.perform(LayerFixture.rect(on: layer))?.createdObjects.first)
        let two = try #require(try a.perform(LayerFixture.rect(on: layer, x: 30))?.createdObjects.first)
        _ = try a.perform(SetLink([one, two], url: "https://a.example"))
        let group = try #require(try a.perform(GroupObjects([one, two], layer: layer))?.createdObjects.first)
        #expect(a.index.urls(in: a.replica.state) == ["https://a.example"])
        #expect(a.index.uses(of: "https://a.example", in: a.replica.state).nodes == [one, two].sorted())
        _ = try a.perform(DeleteNodes([group]))
        #expect(a.index.urls(in: a.replica.state).isEmpty)
        #expect(a.index.uses(of: "https://a.example", in: a.replica.state).isEmpty)
        a.undo()
        #expect(a.index.uses(of: "https://a.example", in: a.replica.state).count == 2)
        _ = try a.perform(SetLink([one, two], url: ""))
        #expect(a.index.carriers.isEmpty)
        a.check()
    }
}
