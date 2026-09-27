import Foundation
import WTCRDT
import WTProto

/// A call queued on this Mac until it can be made (history.adoc, "Offline behavior"; COLLAB-024):
/// a row of the store's `pending_calls`, keyed by the call's own id, its request as `payload`.
public struct PendingCall: Hashable, Sendable {
    public var id: String
    public var kind: String
    public var payload: Data
    public var createdAt: Date

    public init(id: String, kind: String, payload: Data, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
    }
}

/// The history the local store holds (history.adoc, "Offline behavior"): the changes sequenced
/// since its snapshot, this Mac's unsent changes (*Not yet synced*), and from which seq on it can
/// rebuild a state (`LocalStore.state(atServerSeq:)`); an older row shows *Available when online*.
public struct LocalHistory: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        /// Nil while unsent.
        public var serverSeq: UInt64?
        public var label: String
        /// Made on this Mac.
        public var local: Bool
        public var replica: UInt64
        public var wallTime: Date

        public init(serverSeq: UInt64?, label: String, local: Bool, replica: UInt64, wallTime: Date) {
            self.serverSeq = serverSeq
            self.label = label
            self.local = local
            self.replica = replica
            self.wallTime = wallTime
        }
    }

    /// The last `server_seq` applied.
    public var head: UInt64
    /// The oldest seq whose state the local log rebuilds (above `head`: none).
    public var rebuildableFrom: UInt64
    /// Sequenced changes the store holds, in log order.
    public var sequenced: [Entry]
    /// Unsent local changes, in the order they were made.
    public var unsent: [Entry]

    public init(head: UInt64 = 0, rebuildableFrom: UInt64 = 0, sequenced: [Entry] = [], unsent: [Entry] = []) {
        self.head = head
        self.rebuildableFrom = rebuildableFrom
        self.sequenced = sequenced
        self.unsent = unsent
    }

    /// Whether the state at `serverSeq` can be viewed and restored offline.
    public func canRebuild(_ serverSeq: UInt64) -> Bool {
        serverSeq >= rebuildableFrom && serverSeq <= head
    }

    /// The *Not yet synced* group: the unsent changes' labels, newest first.
    public var notYetSynced: [String] { unsent.reversed().map(\.label) }

    /// A stretch of one replica's sequenced changes, as the server groups sessions (one author,
    /// gaps under `gap`), for the panel offline before the server's timeline was read.
    public struct Session: Sendable, Hashable {
        public var replica: UInt64
        public var local: Bool
        /// In log order.
        public var entries: [Entry]
    }

    /// The sequenced changes as sessions, newest first.
    public func sessions(gap: TimeInterval = 600) -> [Session] {
        var sessions: [Session] = []
        for entry in sequenced {
            if let last = sessions.last, last.replica == entry.replica, let previous = last.entries.last,
               entry.wallTime.timeIntervalSince(previous.wallTime) < gap {
                sessions[sessions.count - 1].entries.append(entry)
            } else {
                sessions.append(Session(replica: entry.replica, local: entry.local, entries: [entry]))
            }
        }
        return sessions.reversed()
    }
}

/// Pages of `ListHistory` and `ListNodeHistory` read this session (history.adoc, "Client";
/// COLLAB-024), not persisted.  A live change -- appended to the local log without a fetch --
/// invalidates what it can change: the timeline's head pages (the newest sessions regroup; a page
/// continued by a cursor lies below the head and stays), and the node-history pages of the nodes
/// it touches.  Renaming or deleting a version drops everything (`removeAll`).
public struct HistoryCache<Page: Sendable>: Sendable {
    public enum Key: Hashable, Sendable {
        case timeline(cursor: String, query: String, expandSession: UInt64)
        case node(OpID, cursor: String)
    }

    private var pages: [Key: Page] = [:]
    /// The head the cached pages were read at.
    public private(set) var head: UInt64 = 0

    public init() {}

    public var count: Int { pages.count }

    public func page(_ key: Key) -> Page? { pages[key] }

    /// Keeps `page`, read with the log at `head`.
    public mutating func store(_ page: Page, for key: Key, head: UInt64) {
        pages[key] = page
        self.head = max(self.head, head)
    }

    /// `change` arrived live at `serverSeq`; returns whether a page was dropped.  A change at or
    /// below the head the pages were read at is already in them.
    @discardableResult
    public mutating func apply(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64) -> Bool {
        guard serverSeq > head else { return false }
        let touched = Self.nodes(of: change)
        let before = pages.count
        pages = pages.filter { key, _ in
            switch key {
            case .timeline(let cursor, _, _): !cursor.isEmpty
            case .node(let node, _): !touched.contains(node)
            }
        }
        return pages.count != before
    }

    public mutating func removeAll() {
        pages = [:]
    }

    /// Every node `change` names: created, written, moved, deleted or restored, or edited in its
    /// elements, text or sets.
    public static func nodes(of change: Wiretuner_Doc_V1_Change) -> Set<OpID> {
        var nodes: Set<OpID> = []
        var counter = change.startCounter
        for op in change.ops {
            switch op.op {
            case .create: nodes.insert(OpID(counter: counter, replica: change.replica))
            case .set(let set): nodes.insert(OpID(set.node))
            case .move(let move): nodes.insert(OpID(move.node))
            case .setDeleted(let deleted): nodes.insert(OpID(deleted.node))
            case .elementInsert(let insert): nodes.insert(OpID(insert.node))
            case .elementMove(let move): nodes.insert(OpID(move.node))
            case .elementDelete(let delete): nodes.insert(OpID(delete.node))
            case .textInsert(let insert): nodes.insert(OpID(insert.node))
            case .textDelete(let delete): nodes.insert(OpID(delete.node))
            case .textMark(let mark): nodes.insert(OpID(mark.node))
            case .setAdd(let add): nodes.insert(OpID(add.node))
            case .setRemove(let remove): nodes.insert(OpID(remove.node))
            default: break
            }
            counter &+= EngineState.counters(op)
        }
        return nodes
    }
}
