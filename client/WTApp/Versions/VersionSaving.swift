import Foundation
import GRPCCore
import WTCRDT
import WTProto
import WTSync

/// One local change a version includes: the change's replica and seq in the local store, the
/// counter of its first op (`NameVersionRequest.through_local_change`) and its label, by which the
/// version is re-anchored when replica salvage re-issues the change.
struct LocalChangeRef: Codable, Hashable, Sendable {
    var replica: UInt64
    var seq: UInt64
    var counter: UInt64
    var label: String

    init(replica: UInt64, seq: UInt64, counter: UInt64, label: String) {
        self.replica = replica
        self.seq = seq
        self.counter = counter
        self.label = label
    }

    init(_ change: Wiretuner_Doc_V1_Change) {
        self.init(replica: change.replica, seq: change.seq, counter: change.startCounter, label: change.label)
    }

    var key: [UInt64] { [replica, seq] }
}

/// A version named while its state had not all reached the server (saving.adoc, "Offline
/// behavior"): kept on this Mac until the last local change it includes is acknowledged, then sent
/// to `VersionService.NameVersion`.  `serverSeq` is the remote head applied when it was named.
struct PendingVersion: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var note: String
    var createdAt: Date
    var serverSeq: UInt64
    /// The last local change it includes; nil when every change had been acknowledged.
    var anchor: LocalChangeRef?
}

/// Where a document's local changes stand, read from its local store.
struct VersionHead: Sendable {
    /// The last `server_seq` applied.
    var serverSeq: UInt64
    /// The store's replica now.
    var replica: UInt64
    /// The unacknowledged local changes of the current replica, in order (the outbox).
    var outbox: [LocalChangeRef]
    /// Unacknowledged changes of replicas rotated away from (what salvage re-issues).
    var retired: [LocalChangeRef]

    init(serverSeq: UInt64 = 0, replica: UInt64 = 0, outbox: [LocalChangeRef] = [], retired: [LocalChangeRef] = []) {
        self.serverSeq = serverSeq
        self.replica = replica
        self.outbox = outbox
        self.retired = retired
    }

    /// The head of `store`.
    static func of(_ store: LocalStore) async throws -> VersionHead {
        func refs(_ changes: [Wiretuner_Doc_V1_Change]) -> [LocalChangeRef] { changes.map { LocalChangeRef($0) } }
        return VersionHead(serverSeq: await store.lastServerSeq, replica: await store.replica,
                           outbox: refs(try await store.outbox()), retired: refs(try await store.retiredOutbox()))
    }

    /// What a pending version waits for, now.
    enum Resolution: Equatable {
        /// Send it, through `anchor` (nil: `serverSeq` alone places it).
        case ready(LocalChangeRef?)
        /// Its last change is not acknowledged yet.
        case waiting
    }

    /// Where `version` stands (re-anchored first when its change was re-issued under the current
    /// replica): waiting while its anchor is unacknowledged, else ready.  A change of an earlier
    /// replica that is no longer unacknowledged was either acknowledged before the rotation or
    /// re-issued by salvage -- the newest change of the outbox with the same label is then its
    /// re-issue.
    func resolve(_ version: inout PendingVersion) -> Resolution {
        guard var anchor = version.anchor else { return .ready(nil) }
        let unacknowledged = Set((outbox + retired).map(\.key))
        if anchor.replica != replica, !unacknowledged.contains(anchor.key), let rebased = outbox.last(where: { $0.label == anchor.label }) {
            anchor = rebased
            version.anchor = rebased
        }
        return unacknowledged.contains(anchor.key) ? .waiting : .ready(anchor)
    }
}

/// menu:File[Save Version…] for one document (saving.adoc, "Saving a version"; IO-003): a version
/// named with everything acknowledged goes to `VersionService.NameVersion` at once; otherwise --
/// offline, or with changes still in the outbox -- it waits in the store's `pending_versions` (kept
/// under that key in the local store's `view` table, so it survives relaunches) and goes up once
/// its last change is acknowledged (`flush`, run whenever the document reaches *Saved to cloud*).
/// Version ids are client UUIDv7s, the idempotency key, so two people saving at once get two
/// versions and a retried call never names one twice.
@MainActor
final class VersionSaving {
    static let viewKey = "pending_versions"

    /// Where the pending versions are kept.
    struct Storage {
        var load: @MainActor () async -> Data?
        var save: @MainActor (Data) async -> Void
    }

    /// What saving did.
    enum Outcome: Equatable {
        /// Named on the server.
        case named(Wiretuner_Docs_V1_Version)
        /// Kept on this Mac until its changes upload.
        case pending(PendingVersion)
    }

    let documentID: String
    let storage: Storage
    /// Where the document's changes stand; nil for a document without a local store (named at
    /// the current head).
    var head: @MainActor () async -> VersionHead?
    /// Sends a request; nil when there is no client (signed out, tests).
    var send: (@MainActor (Wiretuner_Docs_V1_NameVersionRequest) async throws -> Wiretuner_Docs_V1_Version)?
    var makeID: @MainActor () -> String = { UUIDv7.make() }
    var now: @MainActor () -> Date = { Date() }
    private(set) var pending: [PendingVersion] = []
    private var loaded = false
    private var flushing: Task<Int, Never>?

    init(documentID: String, storage: Storage, head: @escaping @MainActor () async -> VersionHead?) {
        self.documentID = documentID
        self.storage = storage
        self.head = head
    }

    /// The versions of the document `document`'s local store keeps.
    static func localStore(of document: DocumentHandle) -> (storage: Storage, head: @MainActor () async -> VersionHead?) {
        let store: @MainActor () async -> LocalStore? = { [weak document] in await document?.openedModel()?.backend as? LocalStore }
        return (
            Storage(
                load: { try? await store()?.viewValue(forKey: viewKey) },
                save: { data in try? await store()?.setViewValue(data, forKey: viewKey) }
            ),
            { guard let store = await store() else { return nil }; return try? await VersionHead.of(store) }
        )
    }

    /// Reads the pending versions once.
    func load() async {
        guard !loaded else { return }
        loaded = true
        if let data = await storage.load(), let stored = try? JSONDecoder().decode([PendingVersion].self, from: data) { pending = stored }
    }

    /// Names a version of the document as it is now.
    @discardableResult
    func save(name: String, note: String = "") async -> Outcome {
        await load()
        let head = await head() ?? VersionHead()
        let version = PendingVersion(id: makeID(), name: name, note: note, createdAt: now(), serverSeq: head.serverSeq,
                                     anchor: head.outbox.last ?? head.retired.last)
        if version.anchor == nil, let named = try? await sendVersion(version, anchor: nil) {
            return .named(named)
        }
        pending.append(version)
        await persist()
        return .pending(version)
    }

    /// Sends every pending version whose changes are acknowledged; returns how many were named.
    /// Concurrent calls share one pass.
    @discardableResult
    func flush() async -> Int {
        if let flushing { return await flushing.value }
        let task = Task { await self.runFlush() }
        flushing = task
        let count = await task.value
        flushing = nil
        return count
    }

    private func runFlush() async -> Int {
        await load()
        guard !pending.isEmpty, send != nil else { return 0 }
        let head = await head() ?? VersionHead()
        var count = 0
        var remaining: [PendingVersion] = []
        for var version in pending {
            guard case .ready(let anchor) = head.resolve(&version) else {
                remaining.append(version)
                continue
            }
            do {
                _ = try await sendVersion(version, anchor: anchor)
                count += 1
            } catch {
                remaining.append(version)
            }
        }
        pending = remaining
        await persist()
        return count
    }

    /// One `NameVersion` call; an anchor the server does not know (a change re-issued and
    /// acknowledged under another replica) falls back to the head alone.
    private func sendVersion(_ version: PendingVersion, anchor: LocalChangeRef?) async throws -> Wiretuner_Docs_V1_Version {
        guard let send else { throw RPCError(code: .unavailable, message: "No version client") }
        do {
            return try await send(VersionRequests.nameVersion(documentID: documentID, version: version, anchor: anchor))
        } catch let error as RPCError where anchor != nil && [.notFound, .failedPrecondition].contains(error.code) {
            return try await send(VersionRequests.nameVersion(documentID: documentID, version: version, anchor: nil))
        }
    }

    private func persist() async {
        // Strings, numbers and dates always encode.
        await storage.save(try! JSONEncoder().encode(pending))
    }
}
