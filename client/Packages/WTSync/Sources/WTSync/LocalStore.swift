import Foundation
import GRDB
import WTCRDT
import WTCRDTSchema
import WTModel
import WTProto

/// One open document's local store (docs/spec/offline.adoc, "Local store"; SYNC-001, SYNC-002):
/// a SQLite database (GRDB, WAL, synchronous = FULL) holding the newest snapshot, every change
/// since it (the outbox is the unacknowledged local ones), the undo stack, pending blobs and view
/// state.  The actor also holds the document's merge state (`DocumentCore`): a local change is
/// applied and appended to the outbox inside one database transaction, so a change that was
/// applied is on disk, and a transaction that fails leaves no trace in the file.
///
/// Opening loads the snapshot and replays the changes after it; the snapshot is rewritten on close
/// and every `Options.snapshotInterval` while open.  A local change's local-only writes
/// (crdt-model.adoc, "Local-only fields") are in neither: the outbox holds the change without them
/// and the `view` table keeps the registers they wrote (`LocalOnlyRows`), restored whenever the
/// state is loaded or replaced.  The store records the Mac it was created on:
/// opened on another Mac (a backup restore, a copy), it rotates to a new replica id.
public actor LocalStore: DocumentBackend {
    /// How a store opens.
    public struct Options: Sendable {
        /// How often the snapshot is rewritten while the store is open (offline.adoc: 5 minutes).
        public var snapshotInterval: Duration
        /// The Mac's hardware UUID.
        public var hardwareUUID: @Sendable () -> String
        /// A new random replica id (never 0).
        public var makeReplicaID: @Sendable () -> UInt64
        /// The merge table.
        public var schema: Schema
        /// Written to `meta` when the store is created.
        public var featureLevel: Int
        public var mergeTableVersion: String
        /// Test hook: called inside the transaction after a change has been applied in memory and
        /// before it is written; throwing aborts the transaction as a crash would.
        var fault: (@Sendable () throws -> Void)?

        /// Options; `hardwareUUID` defaults to `HardwareIdentity.platformUUID`, `makeReplicaID` to a
        /// random non-zero id.
        public init(snapshotInterval: Duration = .seconds(300), hardwareUUID: (@Sendable () -> String)? = nil,
                    makeReplicaID: (@Sendable () -> UInt64)? = nil,
                    schema: Schema = .generated, featureLevel: Int = 1, mergeTableVersion: String = WTMergeTable.version) {
            self.snapshotInterval = snapshotInterval
            self.hardwareUUID = hardwareUUID ?? HardwareIdentity.platformUUID
            self.makeReplicaID = makeReplicaID ?? { UInt64.random(in: 1...UInt64.max) }
            self.schema = schema
            self.featureLevel = featureLevel
            self.mergeTableVersion = mergeTableVersion
        }
    }

    /// What opening found.
    public struct OpenReport: Sendable, Hashable {
        /// The store did not exist and was created.
        public var created: Bool
        /// The replica id the store had before it rotated (opened on another Mac), else nil.
        public var rotatedFrom: UInt64?
        /// Changes replayed on top of the snapshot.
        public var replayed: Int
        /// Wall-clock time the open took.
        public var seconds: Double
    }

    /// Why a store operation failed.
    public enum Failure: Error, Equatable {
        /// The store at the path belongs to another document.
        case wrongDocument(String)
        /// The store is closed.
        case closed
        /// A write failed after its change was applied in memory: the in-memory state is ahead of
        /// the file and the store refuses further writes.  Reopening restores the stored state.
        case diverged
        /// A stored row could not be read.
        case corrupt(String)
        /// Local changes are refused: the caller can no longer edit the document (COLLAB-014).
        case readOnly
    }

    /// A pending blob upload (docs/spec/offline.adoc, `blobs_pending`).
    public struct PendingBlob: Sendable, Hashable {
        public var hash: String
        public var path: String
        public var tag: String?
        public var size: Int64
        /// The blob's media type, as its upload header declares it.
        public var mediaType: String

        public init(hash: String, path: String, tag: String? = nil, size: Int64, mediaType: String = "") {
            self.hash = hash
            self.path = path
            self.tag = tag
            self.size = size
            self.mediaType = mediaType
        }
    }

    /// The tag of the document's thumbnail in `blobs_pending`.
    public static let thumbnailTag = "THUMBNAIL"

    public nonisolated let documentID: String
    public nonisolated let url: URL
    /// What opening found.
    public nonisolated let report: OpenReport

    private let options: Options
    /// Whether local changes are refused (`setReadOnly`).
    public private(set) var isReadOnly = false
    private var database: DatabaseQueue?
    private var core: DocumentCore
    private var diverged = false
    private var timer: Task<Void, Never>?
    /// Snapshots written since the store opened (the periodic rewrite's test observable).
    private(set) var snapshotsWritten = 0
    /// The snapshot rewrite in flight, which the next one waits for.
    private var rewriting: Task<Void, Error>?

    /// The store file of `documentID`:
    /// `~/Library/Application Support/WireTuner/Documents/<document id>/store.sqlite`.
    public static func defaultURL(documentID: String) throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(components: "WireTuner", "Documents", documentID, "store.sqlite")
    }

    /// Opens (creating when absent) the store of `documentID` at `url` and starts the periodic
    /// snapshot rewrite.
    public static func open(documentID: String, at url: URL, options: Options = Options()) async throws -> LocalStore {
        let store = try LocalStore(documentID: documentID, url: url, options: options)
        await store.startTimer()
        return store
    }

    private init(documentID: String, url: URL, options: Options) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        self.documentID = documentID
        self.url = url
        self.options = options
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        let database = try DatabaseQueue(path: url.path, configuration: configuration)
        try StoreSchema.migrator.migrate(database)
        let hardware = options.hardwareUUID()
        let (loaded, created, rotatedFrom) = try database.write { db in
            try Self.load(db, documentID: documentID, hardware: hardware, options: options)
        }
        var core = loaded
        var replayed = 0
        try database.read { db in
            let rows = try Row.fetchCursor(db, sql: "SELECT server_seq, data FROM changes WHERE in_snapshot = 0 ORDER BY id")
            while let row = try rows.next() {
                core.replay(try Self.change(row["data"]), serverSeq: (row["server_seq"] as Int64?).map(UInt64.init(sql:)))
                replayed += 1
            }
            core.restoreLocalOnly(try LocalOnlyRows.all(db))
        }
        self.database = database
        self.core = core
        report = OpenReport(created: created, rotatedFrom: rotatedFrom, replayed: replayed,
                            seconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
    }

    // Reads (or writes, for a new store) `meta`, rotates the replica when the store is on another
    // Mac, and loads the snapshot and the undo stack.
    private static func load(_ db: Database, documentID: String, hardware: String, options: Options) throws
        -> (DocumentCore, created: Bool, rotatedFrom: UInt64?) {
        guard let meta = try Row.fetchOne(db, sql: "SELECT * FROM meta WHERE id = 1") else {
            let replica = options.makeReplicaID()
            try db.execute(sql: """
                INSERT INTO meta (id, document_id, replica_id, hardware_uuid, last_server_seq, next_seq, feature_level,
                                  merge_table_version)
                VALUES (1, ?, ?, ?, 0, 1, ?, ?)
                """, arguments: [documentID, replica.sql, hardware, options.featureLevel, options.mergeTableVersion])
            return (DocumentCore(state: EngineState(schema: options.schema), replica: replica), true, nil)
        }
        let stored: String = meta["document_id"]
        guard stored == documentID else { throw Failure.wrongDocument(stored) }
        var replica = UInt64(sql: meta["replica_id"])
        var nextSeq = UInt64(sql: meta["next_seq"])
        var rotatedFrom: UInt64?
        if meta["hardware_uuid"] != hardware {
            rotatedFrom = replica
            replica = options.makeReplicaID()
            nextSeq = 1
            try db.execute(sql: "UPDATE meta SET replica_id = ?, hardware_uuid = ?, next_seq = 1 WHERE id = 1",
                           arguments: [replica.sql, hardware])
        }
        var state = EngineState(schema: options.schema)
        if let snapshot = try Row.fetchOne(db, sql: "SELECT raw_size, data FROM snapshot WHERE id = 1") {
            let raw = try Zstd.decompress(Array(snapshot["data"] as Data), size: snapshot["raw_size"])
            state = try Snapshot.decode(raw, schema: options.schema)
        }
        var undo: [UndoEntry] = []
        var redo: [UndoEntry] = []
        for row in try Row.fetchAll(db, sql: "SELECT stack, label, inverse, updated_at FROM undo ORDER BY id") {
            let entry = UndoEntry(label: row["label"], inverse: try InverseCodec.decode(Array(row["inverse"] as Data)),
                                  updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
            if row["stack"] == "undo" {
                undo.append(entry)
            } else {
                redo.append(entry)
            }
        }
        let core = DocumentCore(state: state, replica: replica, nextSeq: nextSeq, lastServerSeq: UInt64(sql: meta["last_server_seq"]),
                                undoStack: UndoStack(undo: undo, redo: redo), horizon: UInt64(sql: meta["horizon_seq"]))
        return (core, false, rotatedFrom)
    }

    private static func change(_ data: Data) throws -> Wiretuner_Doc_V1_Change {
        do {
            return try Wiretuner_Doc_V1_Change(serializedBytes: data)
        } catch {
            throw Failure.corrupt("a stored change: \(error)")
        }
    }

    private func startTimer() {
        let interval = options.snapshotInterval
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.periodicSnapshot()
            }
        }
    }

    private func periodicSnapshot() async {
        try? await rewriteSnapshot()
    }

    // MARK: Writing

    // Runs `body` in one write transaction.  `body` reports through `applied` once it has changed
    // the in-memory state: a failure after that point marks the store diverged.
    private func write<T>(_ body: (Database, inout Bool) throws -> T) throws -> T {
        guard let database else { throw Failure.closed }
        guard !diverged else { throw Failure.diverged }
        var applied = false
        do {
            return try database.write { db in try body(db, &applied) }
        } catch {
            if applied {
                diverged = true
            }
            throw error
        }
    }

    private func checkFault() throws {
        try options.fault?()
    }

    private func appendLocal(_ change: Wiretuner_Doc_V1_Change, _ db: Database) throws {
        try db.execute(sql: "INSERT INTO changes (replica, seq, local, label, data) VALUES (?, ?, 1, ?, ?)",
                       arguments: [change.replica.sql, change.seq.sql, change.label, try change.serializedData()])
        try db.execute(sql: "UPDATE meta SET next_seq = ? WHERE id = 1", arguments: [core.nextSeq.sql])
    }

    private func persist(_ edit: UndoEdit?, _ db: Database) throws {
        switch edit {
        case nil:
            break
        case .push(let entry, let limit):
            try db.execute(sql: "DELETE FROM undo WHERE stack = 'redo'")
            try insert(entry, stack: "undo", db)
            try trim(limit, db)
        case .replaceTop(let entry):
            try db.execute(sql: "DELETE FROM undo WHERE stack = 'redo'")
            try db.execute(sql: """
                UPDATE undo SET label = ?, inverse = ?, updated_at = ?
                WHERE id = (SELECT MAX(id) FROM undo WHERE stack = 'undo')
                """, arguments: [entry.label, Data(InverseCodec.encode(entry.inverse)), entry.updatedAt.timeIntervalSince1970])
        case .undo(let entry):
            try db.execute(sql: "DELETE FROM undo WHERE id = (SELECT MAX(id) FROM undo WHERE stack = 'undo')")
            try insert(entry, stack: "redo", db)
            try rewriteStack(db)
        case .redo(let entry, let limit):
            try db.execute(sql: "DELETE FROM undo WHERE id = (SELECT MAX(id) FROM undo WHERE stack = 'redo')")
            try insert(entry, stack: "undo", db)
            try trim(limit, db)
            try rewriteStack(db)
        }
    }

    private func insert(_ entry: UndoEntry, stack: String, _ db: Database) throws {
        try db.execute(sql: "INSERT INTO undo (stack, label, inverse, updated_at) VALUES (?, ?, ?, ?)",
                       arguments: [stack, entry.label, Data(InverseCodec.encode(entry.inverse)), entry.updatedAt.timeIntervalSince1970])
    }

    private func trim(_ limit: Int, _ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM undo WHERE stack = 'undo' AND id NOT IN
                (SELECT id FROM undo WHERE stack = 'undo' ORDER BY id DESC LIMIT ?)
            """, arguments: [max(1, limit)])
    }

    // An undo or redo rebases the other steps (WTModel's UndoRebase): their stored inverses are
    // rewritten from the in-memory stack, which lists them in the same order as the rows.
    private func rewriteStack(_ db: Database) throws {
        for (stack, entries) in [("undo", core.undoStack.undo), ("redo", core.undoStack.redo)] {
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM undo WHERE stack = ? ORDER BY id", arguments: [stack])
            for (id, entry) in zip(ids, entries) {
                try db.execute(sql: "UPDATE undo SET inverse = ? WHERE id = ?", arguments: [Data(InverseCodec.encode(entry.inverse)), id])
            }
        }
    }

    // MARK: DocumentBackend

    public func summary() -> DocumentUpdate {
        update(nil)
    }

    public func perform(_ command: any Command, recording: DocumentCore.Recording) throws -> DocumentUpdate {
        guard !isReadOnly else { throw Failure.readOnly }
        let change = try write { db, applied -> Wiretuner_Doc_V1_Change? in
            guard let outcome = try core.perform(command, recording: recording) else { return nil }
            applied = true
            try checkFault()
            try appendLocal(outcome.outbox!, db)
            try LocalOnlyRows.keep(outcome.localOnly, db)
            try persist(outcome.edit, db)
            return outcome.change
        }
        return update(change)
    }

    public func undo(recording: DocumentCore.Recording) throws -> DocumentUpdate {
        try reverse { $0.undo(recording: recording) }
    }

    public func redo(recording: DocumentCore.Recording) throws -> DocumentUpdate {
        try reverse { $0.redo(recording: recording) }
    }

    private func reverse(_ body: (inout DocumentCore) -> DocumentCore.Outcome?) throws -> DocumentUpdate {
        guard !isReadOnly else { throw Failure.readOnly }
        let change = try write { db, applied -> Wiretuner_Doc_V1_Change? in
            guard let outcome = body(&core) else { return nil }
            applied = true
            try checkFault()
            if let change = outcome.outbox {
                try appendLocal(change, db)
                try LocalOnlyRows.keep(outcome.localOnly, db)
            }
            try persist(outcome.edit, db)
            return outcome.change
        }
        return update(change)
    }

    /// Applies a change from the server's log at `serverSeq`, recording it (or, for the echo of
    /// this replica's own change, its ack) and the new `last_server_seq` in the same transaction.
    public func receive(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64) throws -> DocumentUpdate {
        try write { db, applied in
            core.receive(change, serverSeq: serverSeq)
            applied = true
            try checkFault()
            if change.replica == core.replica {
                try markAcknowledged(seq: change.seq, serverSeq: serverSeq, db)
            } else {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO changes (replica, seq, server_seq, local, label, data) VALUES (?, ?, ?, 0, ?, ?)
                    """, arguments: [change.replica.sql, change.seq.sql, serverSeq.sql, change.label, try change.serializedData()])
            }
            try db.execute(sql: "UPDATE meta SET last_server_seq = ? WHERE id = 1", arguments: [core.lastServerSeq.sql])
        }
        return update(change)
    }

    public func read<T: Sendable>(_ body: @Sendable (EngineState) throws -> T) rethrows -> T {
        try body(core.state)
    }

    private func update(_ change: Wiretuner_Doc_V1_Change?) -> DocumentUpdate {
        DocumentUpdate(change: change, undo: UndoSummary(core.undoStack), replica: core.replica)
    }

    // MARK: Outbox (SYNC-002)

    /// The unacknowledged local changes of the current replica, in order: the outbox.
    public func outbox() throws -> [Wiretuner_Doc_V1_Change] {
        try changes(sql: "SELECT data FROM changes WHERE local = 1 AND server_seq IS NULL AND replica = ? ORDER BY id",
                    arguments: [core.replica.sql])
    }

    /// Unacknowledged local changes of replicas this store has rotated away from, in order: what
    /// replica salvage (offline.adoc, "Replica expiry and salvage") re-issues.
    public func retiredOutbox() throws -> [Wiretuner_Doc_V1_Change] {
        try changes(sql: "SELECT data FROM changes WHERE local = 1 AND server_seq IS NULL AND replica != ? ORDER BY id",
                    arguments: [core.replica.sql])
    }

    /// The outbox coalesced for sending (`Coalescer`), judged against everything applied since
    /// its first change.  Changes up to seq `fixedThrough` have already been sent as they were
    /// coalesced then (the sync client resends exactly those bytes, SYNC-003): they are neither
    /// returned nor rewritten, only judged against like any other applied change.
    public func pendingUpload(rules: Coalescer.Rules = .standard, fixedThrough: UInt64 = 0) throws -> [Wiretuner_Doc_V1_Change] {
        guard let database else { throw Failure.closed }
        let replica = core.replica
        let log = try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT replica, seq, local, server_seq, data FROM changes
                WHERE id >= (SELECT MIN(id) FROM changes WHERE local = 1 AND server_seq IS NULL AND replica = ? AND seq > ?)
                ORDER BY id
                """, arguments: [replica.sql, fixedThrough.sql])
            return try rows.map { row -> Coalescer.Entry in
                let change = try Self.change(row["data"])
                let local: Bool = row["local"]
                let serverSeq: Int64? = row["server_seq"]
                let rowReplica: Int64 = row["replica"]
                let unsent = local && serverSeq == nil && UInt64(sql: rowReplica) == replica && change.seq > fixedThrough
                return unsent ? .outbox(change) : .other(change)
            }
        }
        return Coalescer.coalesce(log, rules: rules)
    }

    /// The seq of the current replica's oldest local change still waiting for an acknowledgement.
    public func oldestUnacknowledgedSeq() throws -> UInt64? {
        guard let database else { throw Failure.closed }
        return try database.read { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(seq) FROM changes WHERE local = 1 AND server_seq IS NULL AND replica = ?",
                               arguments: [core.replica.sql]).map(UInt64.init(sql:))
        }
    }

    /// How many local changes of the current replica wait for an acknowledgement (the outbox).
    public func outboxCount() throws -> Int {
        guard let database else { throw Failure.closed }
        return try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM changes WHERE local = 1 AND server_seq IS NULL AND replica = ?",
                             arguments: [core.replica.sql])!
        }
    }

    /// Records every unacknowledged change of the current replica up to `seq` as acknowledged at
    /// `serverSeq`: `Welcome.last_accepted_seq` says they got in, and a snapshot that holds them
    /// (so no echo will come) is at `serverSeq`, an upper bound of their true positions.
    public func acknowledgeAccepted(through seq: UInt64, serverSeq: UInt64) throws {
        try write { db, applied in
            let seqs = try Int64.fetchAll(db, sql: """
                SELECT seq FROM changes WHERE local = 1 AND server_seq IS NULL AND replica = ? AND seq <= ?
                """, arguments: [core.replica.sql, seq.sql]).map(UInt64.init(sql:))
            guard !seqs.isEmpty else { return }
            applied = true
            for accepted in seqs {
                core.acknowledge(seq: accepted, serverSeq: serverSeq)
            }
            try db.execute(sql: """
                UPDATE changes SET server_seq = ?, sent_at = ? WHERE local = 1 AND server_seq IS NULL AND replica = ? AND seq <= ?
                """, arguments: [serverSeq.sql, Date().timeIntervalSince1970, core.replica.sql, seq.sql])
        }
    }

    /// Replaces the stored bytes of the unacknowledged local change with `change`'s replica and
    /// seq (a change the server refused with `VALIDATION_FAILED`, sent again as `Noop`s so the
    /// replica's seqs and counters stay dense).  The in-memory state is not reverted.
    public func replaceUnsent(_ change: Wiretuner_Doc_V1_Change) throws {
        try write { db, _ in
            try db.execute(sql: """
                UPDATE changes SET data = ? WHERE replica = ? AND seq = ? AND local = 1 AND server_seq IS NULL
                """, arguments: [try change.serializedData(), change.replica.sql, change.seq.sql])
        }
    }

    /// Replaces the merged state with a snapshot the server sent at `serverSeq` (bootstrap and
    /// catch-up, SYNC-004), replays every stored change on top -- the outbox, and remote changes
    /// the snapshot may not hold -- and rewrites the local snapshot from the result.
    public func installSnapshot(_ state: EngineState, serverSeq: UInt64) async throws {
        try write { db, applied in
            var fresh = DocumentCore(state: state, replica: core.replica, nextSeq: core.nextSeq,
                                     lastServerSeq: max(serverSeq, core.lastServerSeq), undoStack: core.undoStack,
                                     horizon: core.horizon)
            let rows = try Row.fetchCursor(db, sql: "SELECT server_seq, data FROM changes ORDER BY id")
            while let row = try rows.next() {
                fresh.replay(try Self.change(row["data"]), serverSeq: (row["server_seq"] as Int64?).map(UInt64.init(sql:)))
            }
            fresh.restoreLocalOnly(try LocalOnlyRows.all(db))
            core = fresh
            applied = true
            try checkFault()
            try db.execute(sql: "UPDATE meta SET last_server_seq = ? WHERE id = 1", arguments: [core.lastServerSeq.sql])
        }
        try await rewriteSnapshot()
    }

    /// Records a stable point the server published (`DocumentCore.advanceHorizon`, D-067), and
    /// keeps it in `meta.horizon_seq`: the server credits the changes this replica pushes after a
    /// relaunch with the publication it confirmed before it, so the horizon they are made under
    /// must not start again from 0.  A store that cannot be written keeps it in memory only.
    public func advanceHorizon(to stableSeq: UInt64) {
        guard stableSeq > core.horizon else { return }
        core.advanceHorizon(to: stableSeq)
        try? database?.write { db in
            try db.execute(sql: "UPDATE meta SET horizon_seq = ? WHERE id = 1", arguments: [stableSeq.sql])
        }
    }

    /// The newest stable point the server published to this replica.
    public var horizon: UInt64 { core.horizon }

    /// The merge table the store was opened with.
    public nonisolated var schema: Schema { options.schema }

    /// Records the server's acknowledgement of this replica's change `seq` at `serverSeq`.
    public func acknowledge(seq: UInt64, serverSeq: UInt64) throws {
        try write { db, applied in
            core.acknowledge(seq: seq, serverSeq: serverSeq)
            applied = true
            try markAcknowledged(seq: seq, serverSeq: serverSeq, db)
        }
    }

    private func markAcknowledged(seq: UInt64, serverSeq: UInt64, _ db: Database) throws {
        try db.execute(sql: """
            UPDATE changes SET server_seq = ?, sent_at = ? WHERE replica = ? AND seq = ? AND local = 1
            """, arguments: [serverSeq.sql, Date().timeIntervalSince1970, core.replica.sql, seq.sql])
    }

    private func changes(sql: String, arguments: StatementArguments) throws -> [Wiretuner_Doc_V1_Change] {
        guard let database else { throw Failure.closed }
        return try database.read { db in
            try Data.fetchAll(db, sql: sql, arguments: arguments).map(Self.change)
        }
    }

    // MARK: Snapshot, replica, close (SYNC-001)

    /// Rewrites the snapshot from the current state and drops the changes it now contains, keeping
    /// every row from the oldest unacknowledged local change on (the outbox, and what coalescing
    /// judges it against), marked as already in the snapshot.  The state is encoded and compressed
    /// off the actor (1.6 s at the design point), so changes keep applying meanwhile; they are not
    /// in this snapshot and stay unmarked.  Rewrites run one after another.
    public func rewriteSnapshot() async throws {
        let previous = rewriting
        let current = Task {
            _ = await previous?.result
            try await writeSnapshot()
        }
        rewriting = current
        try await current.value
    }

    private func lastRow(_ database: DatabaseQueue) throws -> Int64 {
        try database.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM changes") } ?? 0
    }

    private func writeSnapshot() async throws {
        guard let database else { throw Failure.closed }
        let state = core.state
        let serverSeq = core.lastServerSeq
        // Read without suspending: every applied change is committed, so the rows up to here are
        // exactly what `state` holds.
        let through = try lastRow(database)
        let (size, compressed) = await Task.detached(priority: .utility) {
            let snapshot = Snapshot.encode(state, serverSeq: serverSeq)
            return (snapshot.count, Zstd.compress(snapshot))
        }.value
        try write { db, _ in
            try db.execute(sql: """
                INSERT OR REPLACE INTO snapshot (id, server_seq, raw_size, data, written_at) VALUES (1, ?, ?, ?, ?)
                """, arguments: [serverSeq.sql, size, Data(compressed), Date().timeIntervalSince1970])
            let oldest = try Int64.fetchOne(db, sql: "SELECT MIN(id) FROM changes WHERE local = 1 AND server_seq IS NULL")
            try db.execute(sql: "DELETE FROM changes WHERE id < ? AND id <= ?", arguments: [oldest ?? Int64.max, through])
            try db.execute(sql: "UPDATE changes SET in_snapshot = 1 WHERE id <= ?", arguments: [through])
        }
        snapshotsWritten += 1
    }

    /// The current replica id.
    public var replica: UInt64 { core.replica }

    /// The seq the next local change takes.
    public var nextSeq: UInt64 { core.nextSeq }

    /// The highest server sequence applied from the server's log.
    public var lastServerSeq: UInt64 { core.lastServerSeq }

    /// Rotates to a new replica id (`REPLICA_CONFLICT`, `REPLICA_EXPIRED`; offline.adoc "Replica
    /// expiry and salvage") and returns it.  Unsent changes of the old id stay in `retiredOutbox`.
    @discardableResult
    public func rotateReplica() throws -> UInt64 {
        let replica = options.makeReplicaID()
        try write { db, applied in
            core.rotate(to: replica)
            applied = true
            try db.execute(sql: "UPDATE meta SET replica_id = ?, next_seq = 1, hardware_uuid = ? WHERE id = 1",
                           arguments: [replica.sql, options.hardwareUUID()])
        }
        return replica
    }

    /// Stops the periodic rewrite, writes the snapshot and closes the database.
    public func close() async throws {
        timer?.cancel()
        timer = nil
        guard database != nil else { return }
        if !diverged {
            try await rewriteSnapshot()
        }
        try database?.close()
        database = nil
    }

    // MARK: Reconcile (SYNC-006)

    /// A review holding the outbox, kept across relaunches until the user chooses.
    public struct ReviewHold: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable {
            /// A divergence review measured from `baseSeq`, the head before the reconnect.
            case merge
            /// A salvage review.
            case recovered
        }

        public var kind: Kind
        public var baseSeq: UInt64
        public var report: SalvageReport?

        public init(kind: Kind, baseSeq: UInt64, report: SalvageReport? = nil) {
            self.kind = kind
            self.baseSeq = baseSeq
            self.report = report
        }
    }

    /// The review holding the outbox, if any.
    public func reviewHold() throws -> ReviewHold? {
        guard let database else { throw Failure.closed }
        return try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT review_kind, review_base_seq, salvage_report FROM meta WHERE id = 1"),
                  let kind = (row["review_kind"] as String?).flatMap(ReviewHold.Kind.init) else { return nil }
            let report = (row["salvage_report"] as Data?).flatMap { try? JSONDecoder().decode(SalvageReport.self, from: $0) }
            return ReviewHold(kind: kind, baseSeq: UInt64(sql: (row["review_base_seq"] as Int64?) ?? 0), report: report)
        }
    }

    /// Records (or, with nil, clears) the review holding the outbox.
    public func setReviewHold(_ hold: ReviewHold?) throws {
        let report = try hold?.report.map { try JSONEncoder().encode($0) }
        try write { db, _ in
            try db.execute(sql: "UPDATE meta SET review_kind = ?, review_base_seq = ?, salvage_report = ? WHERE id = 1",
                           arguments: [hold?.kind.rawValue, hold.map { $0.baseSeq.sql }, report])
        }
    }

    /// When a session last caught up (the divergence measurement's gap).
    public func lastSyncedAt() throws -> Date? {
        guard let database else { throw Failure.closed }
        return try database.read { db in
            try Double.fetchOne(db, sql: "SELECT last_synced_at FROM meta WHERE id = 1").map(Date.init(timeIntervalSince1970:))
        }
    }

    /// Records that a session caught up at `date`.
    public func markSynced(at date: Date) throws {
        try write { db, _ in
            try db.execute(sql: "UPDATE meta SET last_synced_at = ? WHERE id = 1", arguments: [date.timeIntervalSince1970])
        }
    }

    /// Other replicas' changes sequenced after `serverSeq`, in log order.
    public func remoteChanges(after serverSeq: UInt64) throws -> [Wiretuner_Doc_V1_Change] {
        try changes(sql: "SELECT data FROM changes WHERE local = 0 AND server_seq > ? ORDER BY server_seq",
                    arguments: [serverSeq.sql])
    }

    /// Measures the outbox against the remote changes sequenced after `baseSeq`
    /// (`Divergence.measure`), off the actor on a copy of the state.
    public func divergence(since baseSeq: UInt64, gap: Duration, remoteComplete: Bool = true) async throws -> Divergence {
        let local = try outbox()
        let remote = try remoteChanges(after: baseSeq)
        let state = core.state
        return await Task.detached(priority: .userInitiated) {
            Divergence.measure(local: local, remote: remote, state: state, gap: gap, remoteComplete: remoteComplete)
        }.value
    }

    // MARK: Salvage (SYNC-010)

    /// Whether any local change, of this replica or a retired one, waits for an acknowledgement.
    public func hasUnsentChanges() throws -> Bool {
        guard let database else { throw Failure.closed }
        return try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM changes WHERE local = 1 AND server_seq IS NULL)")!
        }
    }

    /// Starts replica salvage (offline.adoc, "Replica expiry and salvage"): rotates to a new replica,
    /// moves every unacknowledged local change -- the retired replicas' and the current one's -- to
    /// the `salvage` table, and empties the store (snapshot, changes, undo, applied sequence), so
    /// that the next session downloads the server's state, on which `applySalvage` re-issues them.
    /// The old ids never reach the server, and a store copied to another Mac holds none of them.
    /// Returns the new replica id.
    @discardableResult
    public func beginSalvage(reason: SalvageReport.Reason) throws -> UInt64 {
        let replica = options.makeReplicaID()
        try write { db, applied in
            try db.execute(sql: """
                INSERT INTO salvage (reason, data)
                SELECT ?, data FROM changes WHERE local = 1 AND server_seq IS NULL ORDER BY id
                """, arguments: [reason.rawValue])
            applied = true
            try reset(to: replica, db)
        }
        return replica
    }

    /// Drops every unacknowledged local change and the local state, rotating to a new replica:
    /// the document reverts to the server's state on the next session (*Save my version as a
    /// copy…* and *Keep my changes on a branch*, reconcile.adoc).  Returns the new replica id.
    @discardableResult
    public func discardLocalChanges() throws -> UInt64 {
        let replica = options.makeReplicaID()
        try write { db, applied in
            applied = true
            try reset(to: replica, db)
        }
        return replica
    }

    private func reset(to replica: UInt64, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM changes; DELETE FROM snapshot; DELETE FROM undo")
        try db.execute(sql: """
            UPDATE meta SET replica_id = ?, next_seq = 1, last_server_seq = 0, hardware_uuid = ?,
                            review_kind = NULL, review_base_seq = NULL, salvage_report = NULL WHERE id = 1
            """, arguments: [replica.sql, options.hardwareUUID()])
        core = DocumentCore(state: EngineState(schema: options.schema), replica: replica, horizon: core.horizon)
        core.restoreLocalOnly(try LocalOnlyRows.all(db))
    }

    /// How many salvaged changes wait to be re-issued.
    public func pendingSalvageCount() throws -> Int {
        guard let database else { throw Failure.closed }
        return try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM salvage")! }
    }

    /// Re-issues the salvaged changes against the current state as local changes of the current
    /// replica (`SalvageRebase`), each as one change or, when it would not fit `limits`, as several
    /// consecutive ones, in one transaction, and returns what was recovered and dropped; nil when
    /// nothing waits.
    public func applySalvage(recording: DocumentCore.Recording, limits: ChangeLimits = .server) throws -> SalvageReport? {
        guard let database else { throw Failure.closed }
        let rows = try database.read { db in try Row.fetchAll(db, sql: "SELECT reason, data FROM salvage ORDER BY id") }
        guard let first = rows.first else { return nil }
        let reason = SalvageReport.Reason(rawValue: first["reason"]) ?? .conflict
        let shared = SalvageCommand.Shared(SalvageRebase(replica: core.replica, reason: reason, limits: limits))
        let changes = try rows.map { try Self.change($0["data"]) }
        try write { db, applied in
            for change in changes {
                var from = 0
                repeat {
                    let outcome = try core.perform(SalvageCommand(change: change, from: from, shared: shared), recording: recording)
                    from = max(shared.next, from + 1)
                    guard let outcome else { continue }
                    applied = true
                    try appendLocal(outcome.outbox!, db)
                    try LocalOnlyRows.keep(outcome.localOnly, db)
                    try persist(outcome.edit, db)
                } while from < change.ops.count
            }
            try db.execute(sql: "DELETE FROM salvage")
        }
        return shared.report
    }

    // MARK: Blobs and view state

    /// Queues a blob upload; a tagged blob replaces the pending blob with the same tag (a newer
    /// thumbnail replaces the pending one).
    public func addPendingBlob(_ blob: PendingBlob) throws {
        try write { db, _ in
            if let tag = blob.tag {
                try db.execute(sql: "DELETE FROM blobs_pending WHERE tag = ?", arguments: [tag])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO blobs_pending (hash, path, tag, size, media_type) VALUES (?, ?, ?, ?, ?)",
                           arguments: [blob.hash, blob.path, blob.tag, blob.size, blob.mediaType])
        }
    }

    /// Pending blobs in upload order: the thumbnail first, then colour profiles (CMS-008: a
    /// document renders through its working profiles, so they go before any image), then the
    /// rest, largest last.
    public func pendingBlobs() throws -> [PendingBlob] {
        guard let database else { throw Failure.closed }
        return try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT hash, path, tag, size, media_type FROM blobs_pending
                ORDER BY (CASE WHEN tag = ? THEN 0 WHEN media_type = ? THEN 1 ELSE 2 END), size, hash
                """, arguments: [Self.thumbnailTag, ProfileBlobs.mediaType])
                .map { PendingBlob(hash: $0["hash"], path: $0["path"], tag: $0["tag"], size: $0["size"], mediaType: $0["media_type"]) }
        }
    }

    /// How many blobs wait to upload, the thumbnail not counted (*Uploading N images*).
    public func pendingBlobCount() throws -> Int {
        guard let database else { throw Failure.closed }
        return try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM blobs_pending WHERE tag IS NULL OR tag != ?",
                             arguments: [Self.thumbnailTag])!
        }
    }

    /// Removes an uploaded blob from the queue.
    public func removePendingBlob(hash: String) throws {
        try write { db, _ in
            try db.execute(sql: "DELETE FROM blobs_pending WHERE hash = ?", arguments: [hash])
        }
    }

    /// Stores a `local_only` view value (zoom, scroll, open panels, current page).
    public func setViewValue(_ value: Data, forKey key: String) throws {
        try write { db, _ in
            try db.execute(sql: "INSERT OR REPLACE INTO view (key, value) VALUES (?, ?)", arguments: [key, value])
        }
    }

    /// The view value stored for `key`.
    public func viewValue(forKey key: String) throws -> Data? {
        guard let database else { throw Failure.closed }
        return try database.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM view WHERE key = ?", arguments: [key])
        }
    }

    // MARK: Access (COLLAB-014)

    /// Refuses (or accepts again) local changes: `perform`, `undo` and `redo` throw
    /// `Failure.readOnly` while set, so no local change enters the outbox while the caller cannot
    /// edit (sharing.adoc, "When your access changes mid-session").  Remote changes still apply.
    public func setReadOnly(_ readOnly: Bool) {
        isReadOnly = readOnly
    }

    /// Closes the store and deletes its directory (the caller's access was removed, and the offer
    /// for its unsent changes was settled).
    public func delete() async throws {
        timer?.cancel()
        timer = nil
        try database?.close()
        database = nil
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: Versions (COLLAB-021)

    /// The state at `serverSeq` rebuilt from the local log (history.adoc, "Offline behavior"), or
    /// nil when the log cannot rebuild it: the seq is before the local snapshot or after the
    /// applied head, or the snapshot holds a local change the server sequenced after `serverSeq`
    /// (or has not sequenced yet), whose effect cannot be taken out of it.
    public func state(atServerSeq serverSeq: UInt64) throws -> EngineState? {
        guard let database else { throw Failure.closed }
        guard serverSeq <= core.lastServerSeq else { return nil }
        return try database.read { db -> EngineState? in
            var state = EngineState(schema: options.schema)
            if let snapshot = try Row.fetchOne(db, sql: "SELECT server_seq, raw_size, data FROM snapshot WHERE id = 1") {
                guard UInt64(sql: snapshot["server_seq"]) <= serverSeq else { return nil }
                let impure = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM changes WHERE in_snapshot = 1 AND local = 1 AND (server_seq IS NULL OR server_seq > ?))
                    """, arguments: [serverSeq.sql])!
                guard !impure else { return nil }
                let raw = try Zstd.decompress(Array(snapshot["data"] as Data), size: snapshot["raw_size"])
                state = try Snapshot.decode(raw, schema: options.schema)
            }
            let rows = try Row.fetchCursor(db, sql: """
                SELECT server_seq, data FROM changes WHERE in_snapshot = 0 AND server_seq IS NOT NULL AND server_seq <= ?
                ORDER BY server_seq
                """, arguments: [serverSeq.sql])
            while let row = try rows.next() {
                state.apply(try Self.change(row["data"]), serverSeq: UInt64(sql: row["server_seq"]))
            }
            return state
        }
    }

    // MARK: Branches (COLLAB-017)

    /// One unsent change and one undo row as `exportBranch` copies them.
    struct OutboxRow: Sendable {
        var seq: UInt64
        var label: String
        var data: Data
    }

    struct UndoRow: Sendable {
        var stack: String
        var label: String
        var inverse: Data
        var updatedAt: Double
    }

    /// What a branch store is written from.
    struct BranchWrite: Sendable {
        var documentID: String
        var meta: BranchMeta
        var replica: UInt64
        var hardware: String
        var nextSeq: UInt64
        var horizon: UInt64
        var featureLevel: Int
        var mergeTableVersion: String
        var snapshotSize: Int
        var snapshot: Data
        var outbox: [OutboxRow]
        var undo: [UndoRow]
    }

    private func branchRows() throws -> ([OutboxRow], [UndoRow]) {
        guard let database else { throw Failure.closed }
        let replica = core.replica
        return try database.read { db in
            let outbox = try Row.fetchAll(db, sql: "SELECT seq, label, data FROM changes WHERE local = 1 AND server_seq IS NULL AND replica = ? ORDER BY id",
                                          arguments: [replica.sql])
                .map { OutboxRow(seq: UInt64(sql: $0["seq"]), label: $0["label"], data: $0["data"]) }
            let undo = try Row.fetchAll(db, sql: "SELECT stack, label, inverse, updated_at FROM undo ORDER BY id")
                .map { UndoRow(stack: $0["stack"], label: $0["label"], inverse: $0["inverse"], updatedAt: $0["updated_at"]) }
            return (outbox, undo)
        }
    }

    /// The metadata of a branch store already at `url` for `documentID`; nil when there is none.
    static func existingBranch(at url: URL, documentID: String) throws -> BranchMeta? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let existing = try DatabaseQueue(path: url.path)
        defer { try? existing.close() }
        let found = try existing.read { db -> (String, BranchMeta?)? in
            guard try db.tableExists("meta"), let id = try String.fetchOne(db, sql: "SELECT document_id FROM meta WHERE id = 1") else { return nil }
            return (id, try branchMeta(db))
        }
        guard let (id, meta) = found else { return nil }
        guard id == documentID, let meta else { throw Failure.wrongDocument(id) }
        return meta
    }

    static func writeBranch(_ branch: BranchWrite, at url: URL) throws {
        let database = try DatabaseQueue(path: url.path)
        try StoreSchema.migrator.migrate(database)
        try database.write { db in
            let meta = branch.meta
            try db.execute(sql: """
                INSERT INTO meta (id, document_id, replica_id, hardware_uuid, last_server_seq, next_seq, feature_level, merge_table_version,
                                  horizon_seq, parent_document_id, branch_name, fork_server_seq, on_server, parent_replica, moved_through_seq)
                VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                """, arguments: [branch.documentID, branch.replica.sql, branch.hardware, meta.forkServerSeq.sql, branch.nextSeq.sql,
                                 branch.featureLevel, branch.mergeTableVersion, branch.horizon.sql, meta.parentDocumentID, meta.name,
                                 meta.forkServerSeq.sql, meta.parentReplica.sql, meta.movedThroughSeq.sql])
            try db.execute(sql: "INSERT INTO snapshot (id, server_seq, raw_size, data, written_at) VALUES (1, ?, ?, ?, ?)",
                           arguments: [meta.forkServerSeq.sql, branch.snapshotSize, branch.snapshot, Date().timeIntervalSince1970])
            for row in branch.outbox {
                try db.execute(sql: "INSERT INTO changes (replica, seq, local, in_snapshot, label, data) VALUES (?, ?, 1, 1, ?, ?)",
                               arguments: [branch.replica.sql, row.seq.sql, row.label, row.data])
            }
            for row in branch.undo {
                try db.execute(sql: "INSERT INTO undo (stack, label, inverse, updated_at) VALUES (?, ?, ?, ?)",
                               arguments: [row.stack, row.label, row.inverse, row.updatedAt])
            }
        }
        try database.close()
    }

    /// Where a branch store came from (branches.adoc, "Client": `meta.parent_document_id`,
    /// `meta.fork_server_seq`, and whether the server holds the branch).
    public struct BranchMeta: Sendable, Hashable {
        public var parentDocumentID: String
        public var name: String
        /// The parent head the branch was forked from.
        public var forkServerSeq: UInt64
        /// Whether `CreateBranch` has succeeded ("not yet on the server" until then).
        public var onServer: Bool
        /// For a branch made from the parent's outbox: the parent replica the changes carry and
        /// the last seq moved; 0 otherwise.
        public var parentReplica: UInt64
        public var movedThroughSeq: UInt64

        public init(parentDocumentID: String, name: String, forkServerSeq: UInt64, onServer: Bool,
                    parentReplica: UInt64 = 0, movedThroughSeq: UInt64 = 0) {
            self.parentDocumentID = parentDocumentID
            self.name = name
            self.forkServerSeq = forkServerSeq
            self.onServer = onServer
            self.parentReplica = parentReplica
            self.movedThroughSeq = movedThroughSeq
        }
    }

    /// This store's branch metadata; nil for a document that is not a branch.
    public func branchMeta() throws -> BranchMeta? {
        guard let database else { throw Failure.closed }
        return try database.read { db in try Self.branchMeta(db) }
    }

    static func branchMeta(_ db: Database) throws -> BranchMeta? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT parent_document_id, branch_name, fork_server_seq, on_server, parent_replica, moved_through_seq FROM meta WHERE id = 1
            """), let parent = row["parent_document_id"] as String? else { return nil }
        return BranchMeta(parentDocumentID: parent, name: row["branch_name"] ?? "", forkServerSeq: UInt64(sql: row["fork_server_seq"] ?? 0),
                          onServer: row["on_server"] ?? false, parentReplica: UInt64(sql: row["parent_replica"] ?? 0),
                          movedThroughSeq: UInt64(sql: row["moved_through_seq"] ?? 0))
    }

    /// Records the branch's metadata (a branch opened from the server, or the server's answer).
    public func setBranchMeta(_ meta: BranchMeta) throws {
        try write { db, _ in
            try db.execute(sql: """
                UPDATE meta SET parent_document_id = ?, branch_name = ?, fork_server_seq = ?, on_server = ?, parent_replica = ?,
                                moved_through_seq = ? WHERE id = 1
                """, arguments: [meta.parentDocumentID, meta.name, meta.forkServerSeq.sql, meta.onServer, meta.parentReplica.sql,
                                 meta.movedThroughSeq.sql])
        }
    }

    /// *Keep my changes on a branch*, the local half (branches.adoc, "Offline-created branch"):
    /// writes a new store for document `documentID` at `url` holding this store's current state as
    /// its snapshot at the applied head (the fork point), this replica's unsent changes as its
    /// outbox -- same replica id and seqs, which the server binds to the branch document -- and the
    /// undo stack, with the branch metadata (`on_server` false).  The store is written in one
    /// transaction; exporting again to a store that already holds the branch answers its metadata.
    /// This store is not changed: the caller then reverts it (`SyncClient.discardUnsent`).
    public func exportBranch(documentID: String, name: String, to url: URL) async throws -> BranchMeta {
        guard database != nil else { throw Failure.closed }
        if let existing = try Self.existingBranch(at: url, documentID: documentID) {
            return existing
        }
        let (outbox, undo) = try branchRows()
        let replica = core.replica
        let meta = BranchMeta(parentDocumentID: self.documentID, name: name, forkServerSeq: core.lastServerSeq, onServer: false,
                              parentReplica: replica, movedThroughSeq: outbox.last?.seq ?? 0)
        let state = core.state
        let fork = core.lastServerSeq
        let (size, compressed) = await Task.detached(priority: .userInitiated) {
            let snapshot = Snapshot.encode(state, serverSeq: fork)
            return (snapshot.count, Zstd.compress(snapshot))
        }.value
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = URL(fileURLWithPath: url.path + ".partial")
        try? FileManager.default.removeItem(at: partial)
        let written = BranchWrite(documentID: documentID, meta: meta, replica: replica, hardware: options.hardwareUUID(),
                                  nextSeq: core.nextSeq, horizon: core.horizon, featureLevel: options.featureLevel,
                                  mergeTableVersion: options.mergeTableVersion, snapshotSize: size, snapshot: Data(compressed),
                                  outbox: outbox, undo: undo)
        try Self.writeBranch(written, at: partial)
        // The rename is the commit point: a crash before it leaves only the partial file.
        try FileManager.default.moveItem(at: partial, to: url)
        return meta
    }
}

/// The local-only registers of a store (crdt-model.adoc, "Local-only fields"), one `view` row
/// each under `crdt.local/<node>/<path>`: the value is the node and op ids (big-endian counter and
/// replica), the `FieldPath`'s length and bytes, then 1 and the register's records, or 0 for unset.
enum LocalOnlyRows {
    static let prefix = "crdt.local/"

    /// Upserts the rows of `writes` (each the write now holding its register).
    static func keep(_ writes: [Write], _ db: Database) throws {
        for write in writes {
            try db.execute(sql: "INSERT OR REPLACE INTO view (key, value) VALUES (?, ?)",
                           arguments: [key(write.node, write.path), try encode(write)])
        }
    }

    /// Every row, decoded; a row that does not decode is skipped.
    static func all(_ db: Database) throws -> [Write] {
        try Data.fetchAll(db, sql: "SELECT value FROM view WHERE key >= ? AND key < ? ORDER BY key",
                          arguments: [prefix, String(prefix.dropLast()) + "0"]).compactMap(decode)
    }

    static func key(_ node: OpID, _ path: RegisterPath) -> String {
        "\(prefix)\(node.counter):\(node.replica)/\(path)"
    }

    static func encode(_ write: Write) throws -> Data {
        var out = Data()
        for value in [write.node.counter, write.node.replica, write.op.counter, write.op.replica] {
            withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
        }
        let path = try write.path.proto.serializedData()
        withUnsafeBytes(of: UInt32(path.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(path)
        if let value = write.value {
            out.append(1)
            out.append(contentsOf: value)
        } else {
            out.append(0)
        }
        return out
    }

    static func decode(_ data: Data) -> Write? {
        let bytes = [UInt8](data)
        func integer(_ at: Int, _ width: Int) -> UInt64 {
            bytes[at..<at + width].reduce(0) { $0 << 8 | UInt64($1) }
        }
        guard bytes.count >= 37 else { return nil }
        let count = Int(integer(32, 4))
        guard bytes.count >= 37 + count,
              let proto = try? Wiretuner_Doc_V1_FieldPath(serializedBytes: Array(bytes[36..<36 + count])),
              let path = RegisterPath(proto) else { return nil }
        let flag = bytes[36 + count]
        return Write(node: OpID(counter: integer(0, 8), replica: integer(8, 8)), path: path,
                     value: flag == 1 ? Array(bytes[(37 + count)...]) : nil, op: OpID(counter: integer(16, 8), replica: integer(24, 8)))
    }
}
