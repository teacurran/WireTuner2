import WTCRDT
import WTProto

// WEB-001: the document's link list (`DocumentIndex.links`, urls.adoc "Client"): URL → the objects
// and text ranges using it, kept incrementally from applied changes.  It drives the Navigation
// panel's Link pop-up, btn:[Find] and the Find and Replace link criterion.
//
// The index keeps the *carriers* -- every node whose own registers or text hold a link, whether
// or not it is currently reachable -- and filters by reachability when read.  A change can only
// alter a node's carried links through an op naming that node (create, set, text insert, delete
// or mark), so updating is per node; deleting, restoring and moving (including a concurrent move
// the tree's move log re-orders) change reachability only, which is read, never cached.

/// The uses of one URL (or any set of link uses): whole objects and text ranges.
public struct LinkUses: Hashable, Sendable {
    /// A linked run of characters in a text block.
    public struct TextRange: Hashable, Sendable {
        public var node: OpID
        public var range: Range<Int>

        public init(node: OpID, range: Range<Int>) {
            self.node = node
            self.range = range
        }
    }

    /// Objects whose `url` is the link, in node-id order.
    public var nodes: [OpID]
    /// Text ranges carrying the link as a mark, by node id then offset.
    public var ranges: [TextRange]

    public init(nodes: [OpID] = [], ranges: [TextRange] = []) {
        self.nodes = nodes
        self.ranges = ranges
    }

    /// How many objects and ranges use the link (the status bar's count after btn:[Find]).
    public var count: Int { nodes.count + ranges.count }
    public var isEmpty: Bool { nodes.isEmpty && ranges.isEmpty }
}

/// The links one node carries: its object-level `url` and its text-range links.
public struct LinkCarrier: Hashable, Sendable {
    public var url: String?
    public var runs: [TextLinks.Run]

    public init(url: String? = nil, runs: [TextLinks.Run] = []) {
        self.url = url
        self.runs = runs
    }

    public var isEmpty: Bool { url == nil && runs.isEmpty }

    /// What `node` carries in `state` (reachable or not).
    public init(_ node: OpID, in state: EngineState) {
        self.init()
        guard state.store.exists(node), NavigationFields.isLinkableKind(state.store.kind(node)) else { return }
        url = NavigationFields.common(of: node, in: state).flatMap { NavigationInfo.normalized($0.url) }
        runs = TextLinks.runs(node, in: state)
    }
}

extension NavigationFields {
    /// Whether nodes of `kind` may carry links (objects, not layers, pages or settings).
    static func isLinkableKind(_ kind: UInt32) -> Bool {
        kind != 0 && !nonObjects.contains(kind)
    }
}

/// The link index: carriers by node, updated per applied change.
public struct LinkIndex: Hashable, Sendable {
    /// Every node carrying a link, reachable or not.
    public private(set) var carriers: [OpID: LinkCarrier] = [:]

    public init() {}

    /// The index of `state` by a full scan of every node.
    public init(_ state: EngineState) {
        for node in state.store.nodes {
            let carrier = LinkCarrier(node, in: state)
            if !carrier.isEmpty { carriers[node] = carrier }
        }
    }

    /// Brings the index up to date with `change`, just applied to `state` (local, remote, undo or
    /// redo alike).
    public mutating func apply(_ change: Wiretuner_Doc_V1_Change, state: EngineState) {
        for node in Self.touched(change) {
            let carrier = LinkCarrier(node, in: state)
            carriers[node] = carrier.isEmpty ? nil : carrier
        }
    }

    /// The nodes whose own registers or text `change` writes.
    static func touched(_ change: Wiretuner_Doc_V1_Change) -> Set<OpID> {
        var nodes: Set<OpID> = []
        var counter = change.startCounter
        for op in change.ops {
            switch op.op {
            case .create: nodes.insert(OpID(counter: counter, replica: change.replica))
            case .set(let set): nodes.insert(OpID(set.node))
            case .textInsert(let insert): nodes.insert(OpID(insert.node))
            case .textDelete(let delete): nodes.insert(OpID(delete.node))
            case .textMark(let mark): nodes.insert(OpID(mark.node))
            default: break
            }
            counter &+= EngineState.counters(op)
        }
        return nodes
    }

    /// Every distinct link used by a reachable object or text range, with its uses.
    public func links(in state: EngineState) -> [String: LinkUses] {
        var result: [String: LinkUses] = [:]
        for node in carriers.keys.sorted() where Reachability.isReachable(node, in: state) {
            let carrier = carriers[node]!
            if let url = carrier.url { result[url, default: LinkUses()].nodes.append(node) }
            for run in carrier.runs { result[run.url, default: LinkUses()].ranges.append(.init(node: node, range: run.range)) }
        }
        return result
    }

    /// The distinct links, sorted (the Link pop-up menu).
    public func urls(in state: EngineState) -> [String] {
        links(in: state).keys.sorted()
    }

    /// The uses of `url` (btn:[Find]); empty when nothing uses it.
    public func uses(of url: String, in state: EngineState) -> LinkUses {
        links(in: state)[url] ?? LinkUses()
    }
}
