import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
import WTSync
@testable import WTTestSupport

/// The review sheet's rows as a person reads them (collaboration.adoc, "The Review Changes
/// sheet"): the object, the kind in the guide's words, and the attribute names -- the conflicting
/// properties' titles, or for a *Both edited* row the attributes each side wrote.  The titles come
/// from the merge table's field names as WTApp's `RegisterNames` makes them ("Name", "Transform",
/// "Locked"), so a scenario can assert the exact rows (COLLAB-003, LIB-023).
struct ReviewRow: Hashable, CustomStringConvertible {
    var node: OpID
    var kind: String
    var attributes: [String]

    init(node: OpID, kind: OverlapKind, attributes: [String]) {
        self.node = node
        self.kind = kind.title
        self.attributes = attributes
    }

    init(_ entry: ReviewEntry) {
        node = entry.node
        kind = entry.kind.title
        var names: Set<String>
        if entry.properties.isEmpty {
            names = Set((entry.localPaths + entry.remotePaths).map(Self.title))
        } else {
            names = Set(entry.properties.map { Self.title($0.property) })
        }
        if !entry.paragraphs.isEmpty { names.insert("Text") }
        attributes = names.sorted()
    }

    var description: String { "\(node) \(kind) [\(attributes.joined(separator: ", "))]" }

    /// The rows of `review`, by node.
    static func rows(_ review: ReviewModel) -> Set<ReviewRow> {
        Set(review.entries.filter { $0.setting == nil }.map(ReviewRow.init))
    }

    /// A property's title as the sheet shows it.
    static func title(_ property: ReviewProperty) -> String {
        switch property {
        case .register(let path): title(path)
        case .deleted: "Deleted"
        case .placement: "Position"
        case .elementPosition(let path): "\(title(path)) order"
        case .elementDeleted(let path): "\(title(path)) removed"
        }
    }

    /// The register's title: the first field under the kind's message, looking through `common`
    /// and `appearance` (WTApp's `RegisterNames.title`).
    static func title(_ path: RegisterPath) -> String {
        let schema = Schema.generated
        let fields = path.fields
        guard let kindNumber = fields.first, let kind = schema.field(Schema.root, Int(kindNumber)) else { return "Attribute" }
        var message = kind.typeName
        var chosen = kind.name
        for number in fields.dropFirst() {
            guard let current = message, let field = schema.field(current, Int(number)) else { break }
            chosen = field.name
            guard field.name == "common" || field.name == "appearance" else { break }
            message = field.typeName
        }
        let words = chosen.split(separator: "_").map(String.init)
        return ([words[0].prefix(1).uppercased() + words[0].dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}

/// Holds a value a closure fills in (the cluster a simulation's backend builds on its clock).
final class Box<Value>: @unchecked Sendable {
    var value: Value?
}

extension Simulation {
    /// A simulation whose clients reach its in-process server through `nodes` API nodes.
    static func clustered(name: String, seed: UInt64, scale: Double = 0.005, nodes: Int = 2,
                          fanOutDelay: Duration = .milliseconds(60)) async throws -> (Simulation, SimCluster) {
        let box = Box<SimCluster>()
        let sim = try await Simulation(name: name, seed: seed, scale: scale) { clock in
            let cluster = SimCluster(server: SimServer(clock: clock), clock: clock, nodes: nodes, fanOutDelay: fanOutDelay)
            box.value = cluster
            return .cluster(cluster)
        }
        return (sim, try #require(box.value))
    }

    /// Takes `client` offline for `hours` of simulated time around `work`, brings it back and
    /// returns what its reconcile measured: the review that holds its outbox, or the merge it
    /// reported (`decision` tells the three outcomes apart).  Nil when it had nothing unsent.
    func offline(_ client: SimClient, hours: Double = 12, _ work: () async throws -> Void) async throws -> ReviewModel? {
        client.goOffline()
        try await work()
        advance(by: .seconds(hours * 3600))
        let seen = client.events.count
        let unsent = try await client.store.outboxCount()
        client.goOnline()
        guard unsent > 0 else { return nil }
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            for event in client.events.dropFirst(seen) {
                switch event {
                case .merged(let review), .reviewNeeded(let review): return review
                default: continue
                }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw failure("\(client.name) did not reconcile after coming back online", clients: [client])
    }
}

/// The per-object choices the sheet performs (reconcile.adoc, "Per object"), as WTApp's
/// `ReviewSheetModel` performs them: *Use mine* and *Restore* are `ReviewModel`'s changes; *Keep
/// both copies* deep-copies the object from the *Mine* side (the merged state with the local
/// values written back, on a preview replica) beside the original; *Use theirs* writes nothing.
@MainActor
enum ReviewChoices {
    static let previewReplica: UInt64 = 0xFFFF_FFFF_FFFF_FFF0

    @discardableResult
    static func useMine(_ entry: ReviewEntry, on client: SimClient) async throws -> Wiretuner_Doc_V1_Change {
        let command = try #require(ReviewModel.useMine(entry))
        return try #require(await client.perform(command))
    }

    @discardableResult
    static func restore(_ entry: ReviewEntry, on client: SimClient) async throws -> Wiretuner_Doc_V1_Change {
        try #require(await client.perform(ReviewModel.restore(entry)))
    }

    /// Returns the copy.
    static func keepBoth(_ entry: ReviewEntry, on client: SimClient, offset: Double = 10) async throws -> OpID {
        var core = DocumentCore(state: client.state, replica: previewReplica)
        if let mine = ReviewModel.useMine(entry) {
            _ = try core.perform(mine, recording: DocumentCore.Recording(limit: 1, now: Date()))
        }
        let change = try #require(await client.perform(KeepBoth(tree: NodeTree(entry.node, state: core.state), original: entry.node, offset: offset)))
        return try #require(change.createdNodes.first)
    }

    struct KeepBoth: Command {
        let tree: NodeTree
        let original: OpID
        let offset: Double
        var label: String { "Keep both copies" }

        func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
            guard let placement = state.store.placement(original) else { return }
            var copy = tree
            copy.transform = copy.transform.concatenating(.translation(x: offset, y: offset))
            let key = try FractionalIndex.between(placement.position, nil, suffix: 1)
            try NodeCopier.create(copy, parent: placement.parent, position: key, schema: state.schema, builder: &builder)
        }
    }
}

/// `value`, or a recorded failure (`#require` cannot wrap an expression that itself uses `#require`).
func required<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}
