import Foundation
import GRPCCore
import WTModel
import WTProto

/// One local change a version includes: the change's replica and seq in the local store, the
/// counter of its first op (`NameVersionRequest.through_local_change`) and its label, by which the
/// version is re-anchored when replica salvage re-issues the change.
public struct LocalChangeRef: Codable, Hashable, Sendable {
    public var replica: UInt64
    public var seq: UInt64
    public var counter: UInt64
    public var label: String

    public init(replica: UInt64, seq: UInt64, counter: UInt64, label: String) {
        self.replica = replica
        self.seq = seq
        self.counter = counter
        self.label = label
    }

    public init(_ change: Wiretuner_Doc_V1_Change) {
        self.init(replica: change.replica, seq: change.seq, counter: change.startCounter, label: change.label)
    }

    var key: [UInt64] { [replica, seq] }
}

/// A version named while its state had not all reached the server (saving.adoc, "Offline
/// behavior"; history.adoc, "Offline behavior"): a `NameVersion` call queued in the store's
/// `pending_calls` until the last local change it includes is acknowledged.  `serverSeq` is the
/// remote head applied when it was named.
public struct PendingVersion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var note: String
    public var createdAt: Date
    public var serverSeq: UInt64
    /// The last local change it includes; nil when every change had been acknowledged.
    public var anchor: LocalChangeRef?

    public init(id: String, name: String, note: String, createdAt: Date, serverSeq: UInt64, anchor: LocalChangeRef? = nil) {
        self.id = id
        self.name = name
        self.note = note
        self.createdAt = createdAt
        self.serverSeq = serverSeq
        self.anchor = anchor
    }

    /// The `NameVersion` request naming it in `documentID`, through `anchor` when given.
    public func request(documentID: String, anchor: LocalChangeRef?) -> Wiretuner_Docs_V1_NameVersionRequest {
        var message = Wiretuner_Docs_V1_NameVersionRequest()
        message.documentID = documentID
        message.versionID = id
        message.serverSeq = serverSeq
        if let anchor {
            var through = Wiretuner_Doc_V1_OpId()
            through.counter = anchor.counter
            through.replica = anchor.replica
            message.throughLocalChange = through
        }
        message.name = name
        message.note = note
        return message
    }
}

/// Where a document's local changes stand, read from its local store.
public struct VersionHead: Sendable {
    /// The last `server_seq` applied.
    public var serverSeq: UInt64
    /// The store's replica now.
    public var replica: UInt64
    /// The unacknowledged local changes of the current replica, in order (the outbox).
    public var outbox: [LocalChangeRef]
    /// Unacknowledged changes of replicas rotated away from (what salvage re-issues).
    public var retired: [LocalChangeRef]

    public init(serverSeq: UInt64 = 0, replica: UInt64 = 0, outbox: [LocalChangeRef] = [], retired: [LocalChangeRef] = []) {
        self.serverSeq = serverSeq
        self.replica = replica
        self.outbox = outbox
        self.retired = retired
    }

    /// The head of `store`.
    public static func of(_ store: LocalStore) async throws -> VersionHead {
        func refs(_ changes: [Wiretuner_Doc_V1_Change]) -> [LocalChangeRef] { changes.map { LocalChangeRef($0) } }
        return VersionHead(serverSeq: await store.lastServerSeq, replica: await store.replica,
                           outbox: refs(try await store.outbox()), retired: refs(try await store.retiredOutbox()))
    }

    /// What a pending version waits for, now.
    public enum Resolution: Equatable, Sendable {
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
    public func resolve(_ version: inout PendingVersion) -> Resolution {
        guard var anchor = version.anchor else { return .ready(nil) }
        let unacknowledged = Set((outbox + retired).map(\.key))
        if anchor.replica != replica, !unacknowledged.contains(anchor.key), let rebased = outbox.last(where: { $0.label == anchor.label }) {
            anchor = rebased
            version.anchor = rebased
        }
        return unacknowledged.contains(anchor.key) ? .waiting : .ready(anchor)
    }
}

/// The versions one document names (saving.adoc, "Saving a version"; IO-003, COLLAB-024): a
/// version named with everything acknowledged goes to `VersionService.NameVersion` at once;
/// otherwise -- offline, or with changes still in the outbox -- its call waits in the store's
/// `pending_calls` (so it survives the app being killed) and goes up once its last change is
/// acknowledged (`flush`, run whenever the document reaches *Saved to cloud*: after the outbox
/// drains, so `through_local_change` has been sequenced).  Version ids are client UUIDv7s, the
/// idempotency key, so two people saving at once get two versions and a retried call never names
/// one twice.  The History panel lists `pending` as pending rows.
@MainActor
public final class VersionQueue {
    /// The `pending_calls` kind of a queued `NameVersion`.
    public nonisolated static let callKind = "NameVersion"
    /// Where IO-003 kept the queue before `pending_calls` (the store's `view` table); read once
    /// and moved.
    public nonisolated static let viewKey = "pending_versions"

    /// Where the pending versions are kept: a JSON array of `PendingVersion`.
    public struct Storage {
        public var load: @MainActor () async -> Data?
        public var save: @MainActor (Data) async -> Void

        public init(load: @escaping @MainActor () async -> Data?, save: @escaping @MainActor (Data) async -> Void) {
            self.load = load
            self.save = save
        }

        /// The `pending_calls` rows of the store `store` gives (one `NameVersion` per version, its
        /// payload the version's JSON); the legacy `pending_versions` view value is moved into
        /// them on the first read.
        public static func localStore(_ store: @escaping @MainActor () async -> LocalStore?) -> Storage {
            Storage(
                load: {
                    guard let store = await store() else { return nil }
                    var versions = ((try? await store.pendingCalls(kind: callKind)) ?? []).compactMap { try? JSONDecoder().decode(PendingVersion.self, from: $0.payload) }
                    if let legacy = try? await store.viewValue(forKey: viewKey), let old = try? JSONDecoder().decode([PendingVersion].self, from: legacy), !old.isEmpty {
                        versions += old.filter { version in !versions.contains { $0.id == version.id } }
                        try? await store.replacePendingCalls(kind: callKind, with: calls(versions))
                        try? await store.setViewValue(Data("[]".utf8), forKey: viewKey)
                    }
                    return try? JSONEncoder().encode(versions)
                },
                save: { data in
                    guard let store = await store(), let versions = try? JSONDecoder().decode([PendingVersion].self, from: data) else { return }
                    try? await store.replacePendingCalls(kind: callKind, with: calls(versions))
                }
            )
        }

        nonisolated static func calls(_ versions: [PendingVersion]) -> [PendingCall] {
            // Strings, numbers and dates always encode.
            versions.map { PendingCall(id: $0.id, kind: callKind, payload: try! JSONEncoder().encode($0), createdAt: $0.createdAt) }
        }
    }

    /// What saving did.
    public enum Outcome: Equatable, Sendable {
        /// Named on the server.
        case named(Wiretuner_Docs_V1_Version)
        /// Kept on this Mac until its changes upload.
        case pending(PendingVersion)
    }

    public let documentID: String
    public let storage: Storage
    /// Where the document's changes stand; nil for a document without a local store (named at
    /// the current head).
    public var head: @MainActor () async -> VersionHead?
    /// Sends a request; nil when there is no client (signed out, tests).
    public var send: (@MainActor (Wiretuner_Docs_V1_NameVersionRequest) async throws -> Wiretuner_Docs_V1_Version)?
    public var makeID: @MainActor () -> String = { DocumentCreation.newDocumentID() }
    public var now: @MainActor () -> Date = { Date() }
    /// Called after the pending list changed (a version queued or sent): the History panel reloads.
    public var onChange: @MainActor () -> Void = {}
    public private(set) var pending: [PendingVersion] = []
    private var loaded = false
    private var flushing: Task<Int, Never>?

    public init(documentID: String, storage: Storage, head: @escaping @MainActor () async -> VersionHead?) {
        self.documentID = documentID
        self.storage = storage
        self.head = head
    }

    /// A queue over `store` (its head and its `pending_calls`).
    public convenience init(documentID: String, store: LocalStore) {
        self.init(documentID: documentID, storage: .localStore { store }, head: { try? await VersionHead.of(store) })
    }

    /// Reads the pending versions once.
    public func load() async {
        guard !loaded else { return }
        loaded = true
        if let data = await storage.load(), let stored = try? JSONDecoder().decode([PendingVersion].self, from: data) { pending = stored }
    }

    /// The pending versions, read first when not yet read.
    public func pendingVersions() async -> [PendingVersion] {
        await load()
        return pending
    }

    /// Names a version of the document as it is now.
    @discardableResult
    public func save(name: String, note: String = "") async -> Outcome {
        await load()
        let head = await head() ?? VersionHead()
        let version = PendingVersion(id: makeID(), name: name, note: note, createdAt: now(), serverSeq: head.serverSeq,
                                     anchor: head.outbox.last ?? head.retired.last)
        if version.anchor == nil, let named = try? await sendVersion(version, anchor: nil) {
            return .named(named)
        }
        pending.append(version)
        await persist()
        onChange()
        return .pending(version)
    }

    /// Sends every pending version whose changes are acknowledged, in the order they were named;
    /// returns how many were named.  Concurrent calls share one pass.
    @discardableResult
    public func flush() async -> Int {
        if let flushing { return await flushing.value }
        let task = Task { await self.runFlush() }
        flushing = task
        let count = await task.value
        flushing = nil
        return count
    }

    /// Flushes whenever `transitions` reaches *Saved to cloud* (the outbox drained); the task ends
    /// with the stream.
    public func follow(_ transitions: AsyncStream<SyncTransition>) -> Task<Void, Never> {
        Task { [weak self] in
            for await transition in transitions where transition.to == .saved {
                guard let self else { return }
                await self.flush()
            }
        }
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
        if count > 0 { onChange() }
        return count
    }

    /// One `NameVersion` call; an anchor the server does not know (a change re-issued and
    /// acknowledged under another replica) falls back to the head alone.
    private func sendVersion(_ version: PendingVersion, anchor: LocalChangeRef?) async throws -> Wiretuner_Docs_V1_Version {
        guard let send else { throw RPCError(code: .unavailable, message: "No version client") }
        do {
            return try await send(version.request(documentID: documentID, anchor: anchor))
        } catch let error as RPCError where anchor != nil && [.notFound, .failedPrecondition].contains(error.code) {
            return try await send(version.request(documentID: documentID, anchor: nil))
        }
    }

    private func persist() async {
        // Strings, numbers and dates always encode.
        await storage.save(try! JSONEncoder().encode(pending))
    }
}
