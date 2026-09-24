import Foundation
import GRDB
import WTProto

/// Branch stores on this Mac (COLLAB-017; branches.adoc, "Client" and "Offline-created branch"): a
/// branch store is a normal document store whose `meta` names the parent, the fork point and
/// whether the server holds the branch yet.  Each branch has its own store (one local store per
/// branch), opened like any document's, so a branch opened once works fully offline and switching
/// is closing one store and opening another (`LocalStore.defaultURL(documentID:)` of the branch;
/// view state lives in each store's `view` table, so it is per branch).
public enum BranchStores {
    /// One branch store found on disk.
    public struct Entry: Sendable, Hashable {
        public var documentID: String
        public var url: URL
        public var meta: LocalStore.BranchMeta
    }

    /// `~/Library/Application Support/WireTuner/Documents`, where every document's store lives.
    public static func defaultRoot() throws -> URL {
        try LocalStore.defaultURL(documentID: "x").deletingLastPathComponent().deletingLastPathComponent()
    }

    /// *Keep my changes on a branch*, on this Mac and without the network: writes the branch store
    /// under `root` (its id `branchID`) from `parent`'s current state and unsent changes
    /// (`LocalStore.exportBranch`) and returns it.  The caller then reverts the parent
    /// (`SyncClient.discardUnsent`, which also discards its undo stack for them -- the notice is
    /// the app's) and has `BranchCreator` create the branch on the server when online.  A crash
    /// between the two steps loses nothing: `completeMoves` finishes the revert on the next open.
    public static func keepChangesOnBranch(parent: LocalStore, name: String, branchID: String = DocumentIdentifier.make(),
                                           root: URL? = nil) async throws -> Entry {
        let url = try (root ?? defaultRoot()).appending(components: branchID, "store.sqlite")
        let meta = try await parent.exportBranch(documentID: branchID, name: name, to: url)
        return Entry(documentID: branchID, url: url, meta: meta)
    }

    /// The branch stores under `root`, all of them or those of `parent`, by name then id.
    public static func branches(of parent: String? = nil, in root: URL? = nil) throws -> [Entry] {
        let root = try root ?? defaultRoot()
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var found: [Entry] = []
        for directory in directories {
            let url = directory.appending(component: "store.sqlite")
            guard FileManager.default.fileExists(atPath: url.path), let entry = read(url) else { continue }
            if parent == nil || entry.meta.parentDocumentID == parent {
                found.append(entry)
            }
        }
        return found.sorted { ($0.meta.name, $0.documentID) < ($1.meta.name, $1.documentID) }
    }

    /// The branch stores the server does not hold yet ("not yet on the server"): what
    /// `BranchCreator` creates at the next opportunity, such as the next launch.
    public static func pendingCreations(in root: URL? = nil) throws -> [Entry] {
        try branches(in: root).filter { !$0.meta.onServer }
    }

    /// The branch metadata of the store at `url`, read without opening it for writing.
    static func read(_ url: URL) -> Entry? {
        guard let database = try? DatabaseQueue(path: url.path, configuration: readOnly()) else { return nil }
        defer { try? database.close() }
        return try? database.read { db -> Entry? in
            let columns = try db.columns(in: "meta").map(\.name)
            guard columns.contains("parent_document_id"),
                  let id = try String.fetchOne(db, sql: "SELECT document_id FROM meta WHERE id = 1"),
                  let meta = try LocalStore.branchMeta(db) else { return nil }
            return Entry(documentID: id, url: url, meta: meta)
        }
    }

    private static func readOnly() -> Configuration {
        var configuration = Configuration()
        configuration.readonly = true
        return configuration
    }

    /// Finishes moves a crash interrupted: when a branch store under `root` holds `parent`'s
    /// unsent changes (the same replica, through the same seq) and the parent still has them, the
    /// parent reverts to the server's state now.  Returns whether it did.  Call before starting
    /// the parent's sync client.
    @discardableResult
    public static func completeMoves(parent: LocalStore, in root: URL? = nil) async throws -> Bool {
        let replica = await parent.replica
        for entry in try branches(of: parent.documentID, in: root) where entry.meta.parentReplica == replica {
            if let oldest = try await parent.oldestUnacknowledgedSeq(), oldest <= entry.meta.movedThroughSeq {
                try await parent.discardLocalChanges()
                return true
            }
        }
        return false
    }
}

/// Creates on the server the branches this Mac made (COLLAB-017; `BranchSyncState` tracks
/// `on_server`): `CreateBranch` with the branch's first unsent changes as `initial_changes` (at
/// most `initialChanges` and `initialBytes`), which the server binds to the branch document so the
/// store's replica continues its seqs there; the rest go up through the branch's own sync session
/// (`PushChanges` for a backlog).  `REPLICA_CONFLICT` (a copy of the store raced) takes the
/// rotation path: the unsent changes go to salvage (SYNC-010), the branch is created without them
/// and the session re-issues them from a fresh replica.
///
/// WTApp calls `ensureOnServer` before starting a branch store's `SyncClient` (and at launch for
/// `BranchStores.pendingCreations`); offline it throws and the branch stays "not yet on the
/// server", editable, until the next try.
public actor BranchCreator {
    public static let initialChanges = 1_000
    public static let initialBytes = 1 << 20

    let transport: any DocumentCopyTransport
    let tokens: any TokenProvider

    public init(transport: any DocumentCopyTransport, tokens: any TokenProvider) {
        self.transport = transport
        self.tokens = tokens
    }

    /// Creates `store`'s branch on the server unless it is there already; returns whether this
    /// call created it.  A store that is not a branch is left alone.
    @discardableResult
    public func ensureOnServer(_ store: LocalStore) async throws -> Bool {
        guard var meta = try await store.branchMeta(), !meta.onServer else { return false }
        let pending = try await store.pendingUpload()
        var initial: [Wiretuner_Doc_V1_Change] = []
        var bytes = 0
        for change in pending.prefix(Self.initialChanges) {
            let size = encodedSize(change)
            guard initial.isEmpty || bytes + size <= Self.initialBytes else { break }
            bytes += size
            initial.append(change)
        }
        var request = Wiretuner_Docs_V1_CreateBranchRequest()
        request.parentDocumentID = meta.parentDocumentID
        request.branchDocumentID = store.documentID
        request.name = String((meta.name.isEmpty ? "Branch" : meta.name).prefix(256))
        request.forkServerSeq = meta.forkServerSeq
        request.initialChanges = initial
        let token = try await tokens.accessToken(forceRefresh: false)
        do {
            _ = try await transport.createBranch(request, token: token)
            // The server appended them right after the fork point, in order.
            for (index, change) in initial.enumerated() {
                try await store.acknowledge(seq: change.seq, serverSeq: meta.forkServerSeq + UInt64(index) + 1)
            }
        } catch let error as SyncCallError where error.reason == .replicaConflict {
            try await store.beginSalvage(reason: .conflict)
            request.initialChanges = []
            _ = try await transport.createBranch(request, token: token)
        }
        meta.onServer = true
        try await store.setBranchMeta(meta)
        return true
    }
}
