import Foundation
import GRDB
import WTCRDT
import WTCRDTSchema
import WTModel
import WTProto

/// One open document's local store (docs/spec/offline.adoc, "Local store"; SYNC-001, SYNC-002):
/// a SQLite database (GRDB, WAL, synchronous = FULL) holding the newest snapshot, every change
/// since it (the outbox is the unacknowledged local ones), the undo stack, pending blobs and view
/// state.  The document's merge state (`DocumentCore`) is the store's `engine`, which the
/// `Document` façade applies local changes to on the main actor (D-076): the store writes them
/// afterwards, off the main actor, every change applied since the last write in one transaction,
/// at most `Options.batchInterval` (250 ms) after the first of them, and at once before the outbox
/// is read or sent, before any other write and on close.  A crash loses at most that unwritten
/// batch; a transaction that fails leaves no trace in the file and the store diverged.  Within a
/// batch, an earlier write to a register a later change of the batch writes again is dropped
/// (`Coalescer.Rules.registers`), and the keystrokes of one word are one change
/// (`DocumentCore.open`), which is not sent while it can still grow.
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
        /// The longest a local change waits to be written (D-076): the first change after a write
        /// schedules the next write this much later.
        public var batchInterval: Duration = .milliseconds(250)
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
    public var isReadOnly: Bool { engine.gate.readOnly }
    /// Whether, while read-only, changes that concern comments only are still accepted (a
    /// commenter's role; `setReadOnly(_:commentsAllowed:)`).
    public var allowsComments: Bool { engine.gate.commentsAllowed }
    /// The merge state, shared with the `Document` façade.
    public nonisolated let engine: DocumentEngine
    private var database: DatabaseQueue?
    /// A copy of the merge state as of now.
    private var core: DocumentCore { engine.core }
    private var diverged = false
    /// The scheduled write of the pending batch.
    private var flushTask: Task<Void, Never>?
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
        engine = DocumentEngine(core: core, persists: true, refusal: Failure.readOnly)
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
        engine.onPending { [weak self] in
            Task { await self?.scheduleFlush() }
        }
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

    private struct Stamped<T>: Sendable where T: Sendable {
        var nextSeq: UInt64
        var stack: UndoStack
        var result: T
    }

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
                markDiverged()
            }
            throw error
        }
    }

    private func markDiverged() {
        diverged = true
        engine.fail(Failure.diverged)
    }

    /// What one step changed in memory, for `commit` to write: the local changes the engine had
    /// queued before it, and the seq the replica's next change takes after it.
    private struct Applied<T> {
        var pending: [DocumentCore.Outcome]
        var nextSeq: UInt64
        var stack: UndoStack
        var result: T
    }

    // Applies `mutation` to the core under the engine's lock -- taking, in the same step, the local
    // changes queued before it -- then, with the lock released, writes those changes and whatever
    // `persist` writes in one transaction.  So the file holds the changes in the order the state
    // saw them, and the main actor never waits on the disk.  `changed` says whether the mutation
    // changed the state (a failed write then leaves the store diverged, as queued changes do).
    private func commit<T: Sendable>(_ mutation: (inout DocumentCore, [DocumentCore.Outcome]) throws -> T, changed: (T) -> Bool = { _ in true },
                           persist: (Database, T) throws -> Void = { _, _ in }) throws -> T {
        guard database != nil else { throw Failure.closed }
        guard !diverged else { throw Failure.diverged }
        let step = try engine.mutate { core, pending -> Stamped<T> in
            let result = try mutation(&core, pending)
            return Stamped(nextSeq: core.nextSeq, stack: core.undoStack, result: result)
        }
        let applied = Applied(pending: step.pending, nextSeq: step.result.nextSeq, stack: step.result.stack, result: step.result.result)
        let dirty = !applied.pending.isEmpty || changed(applied.result)
        guard dirty else { return applied.result }
        guard let database else { throw Failure.closed }
        do {
            try database.write { db in
                try checkFault()
                try writePending(applied.pending, nextSeq: applied.nextSeq, stack: applied.stack, db)
                try persist(db, applied.result)
            }
        } catch {
            markDiverged()
            throw error
        }
        return applied.result
    }

    /// Writes every local change the engine has applied and not yet written, in one transaction.
    public func flush() throws {
        flushTask?.cancel()
        flushTask = nil
        guard engine.hasPending, database != nil, !diverged else { return }
        try commit({ _, _ in () }, changed: { false })
    }

    // The first change after a write schedules the next write `batchInterval` later.
    private func scheduleFlush() {
        guard flushTask == nil, database != nil else { return }
        let interval = options.batchInterval
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.scheduledFlush()
        }
    }

    private func scheduledFlush() {
        flushTask = nil
        try? flush()
    }

    private func checkFault() throws {
        try options.fault?()
    }

    // Writes queued local outcomes: each change's row (an open change that grew replaces its row),
    // its local-only registers and its undo edit.  Within the batch an open change's successive
    // versions collapse to the last, and an earlier write to a register a later change of the batch
    // writes again is dropped (`Coalescer.Rules.registers`; the batch holds only local changes, all
    // unsent).  The open change itself is left as it is, since it is rewritten when it grows.
    private func writePending(_ pending: [DocumentCore.Outcome], nextSeq: UInt64, stack: UndoStack, _ db: Database) throws {
        guard !pending.isEmpty else { return }
        struct Row {
            var change: Wiretuner_Doc_V1_Change
            var replaces: Bool
        }
        var rows: [Row] = []
        for outcome in pending {
            guard let change = outcome.outbox else { continue }
            if outcome.extends, let last = rows.last, last.change.replica == change.replica, last.change.seq == change.seq {
                rows[rows.count - 1].change = change
            } else {
                rows.append(Row(change: change, replaces: outcome.extends))
            }
        }
        let open = engine.core.open?.seq
        let closed = rows.indices.filter { rows[$0].change.seq != open || rows[$0].change.replica != engine.core.replica }
        if closed.count > 1 {
            let coalesced = Coalescer.coalesce(closed.map { .outbox(rows[$0].change) }, rules: .registers)
            for (index, change) in zip(closed, coalesced) {
                rows[index].change = change
            }
        }
        for row in rows {
            let data = try row.change.serializedData()
            if row.replaces {
                try db.execute(sql: "UPDATE changes SET data = ? WHERE replica = ? AND seq = ? AND local = 1 AND server_seq IS NULL",
                               arguments: [data, row.change.replica.sql, row.change.seq.sql])
                if db.changesCount > 0 { continue }
            }
            try db.execute(sql: "INSERT INTO changes (replica, seq, local, label, data) VALUES (?, ?, 1, ?, ?)",
                           arguments: [row.change.replica.sql, row.change.seq.sql, row.change.label, data])
        }
        for outcome in pending {
            try LocalOnlyRows.keep(outcome.localOnly, db)
            try persist(outcome.edit, stack: stack, db)
        }
        if !rows.isEmpty {
            try db.execute(sql: "UPDATE meta SET next_seq = ? WHERE id = 1", arguments: [nextSeq.sql])
        }
    }

    // `stack` is the undo stack after the batch: an undo or redo rewrites the rebased inverses of
    // the other steps from it.
    private func persist(_ edit: UndoEdit?, stack: UndoStack, _ db: Database) throws {
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
            try rewriteStack(stack, db)
        case .redo(let entry, let limit):
            try db.execute(sql: "DELETE FROM undo WHERE id = (SELECT MAX(id) FROM undo WHERE stack = 'redo')")
            try insert(entry, stack: "undo", db)
            try trim(limit, db)
            try rewriteStack(stack, db)
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
    private func rewriteStack(_ stack: UndoStack, _ db: Database) throws {
        for (name, entries) in [("undo", stack.undo), ("redo", stack.redo)] {
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM undo WHERE stack = ? ORDER BY id", arguments: [name])
            for (id, entry) in zip(ids, entries) {
                try db.execute(sql: "UPDATE undo SET inverse = ? WHERE id = ?", arguments: [Data(InverseCodec.encode(entry.inverse)), id])
            }
        }
    }

    // MARK: DocumentBackend

    public func summary() -> DocumentUpdate {
        engine.summary
    }

    /// Performs a local command and writes it (with every change queued before it) before
    /// returning.  The façade applies through `engine` instead and does not wait for the write.
    public func perform(_ command: any Command, recording: DocumentCore.Recording) throws -> DocumentUpdate {
        try writeThrough { try engine.perform(command, recording: recording) }
    }

    public func undo(recording: DocumentCore.Recording) throws -> DocumentUpdate {
        try writeThrough { try engine.undo(recording: recording) }
    }

    public func redo(recording: DocumentCore.Recording) throws -> DocumentUpdate {
        try writeThrough { try engine.redo(recording: recording) }
    }

    private func writeThrough(_ body: () throws -> DocumentUpdate) throws -> DocumentUpdate {
        guard database != nil else { throw Failure.closed }
        guard !diverged else { throw Failure.diverged }
        let update = try body()
        try flush()
        return update
    }

    /// Applies a change from the server's log at `serverSeq`, recording it (or, for the echo of
    /// this replica's own change, its ack) and the new `last_server_seq` in the same transaction,
    /// after the local changes applied before it.
    public func receive(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64) throws -> DocumentUpdate {
        try commit({ core, _ -> (UInt64, UInt64) in
            core.receive(change, serverSeq: serverSeq)
            return (core.replica, core.lastServerSeq)
        }, persist: { db, applied in
            let (replica, lastServerSeq) = applied
            if change.replica == replica {
                try Self.markAcknowledged(replica: replica, seq: change.seq, serverSeq: serverSeq, db)
            } else {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO changes (replica, seq, server_seq, local, label, data) VALUES (?, ?, ?, 0, ?, ?)
                    """, arguments: [change.replica.sql, change.seq.sql, serverSeq.sql, change.label, try change.serializedData()])
            }
            try db.execute(sql: "UPDATE meta SET last_server_seq = ? WHERE id = 1", arguments: [lastServerSeq.sql])
        })
        return update(change)
    }

    public func read<T: Sendable>(_ body: @Sendable (EngineState) throws -> T) rethrows -> T {
        try body(engine.state)
    }

    private func update(_ change: Wiretuner_Doc_V1_Change?) -> DocumentUpdate {
        let core = core
        return DocumentUpdate(change: change, undo: UndoSummary(core.undoStack), replica: core.replica)
    }

    // MARK: Outbox (SYNC-002)

    /// The unacknowledged local changes of the current replica, in order: the outbox.
    public func outbox() throws -> [Wiretuner_Doc_V1_Change] {
        try flush()
        return try changes(sql: "SELECT data FROM changes WHERE local = 1 AND server_seq IS NULL AND replica = ? ORDER BY id",
                    arguments: [core.replica.sql])
    }

    /// Unacknowledged local changes of replicas this store has rotated away from, in order: what
    /// replica salvage (offline.adoc, "Replica expiry and salvage") re-issues.
    public func retiredOutbox() throws -> [Wiretuner_Doc_V1_Change] {
        try flush()
        return try changes(sql: "SELECT data FROM changes WHERE local = 1 AND server_seq IS NULL AND replica != ? ORDER BY id",
                    arguments: [core.replica.sql])
    }

    /// The outbox coalesced for sending (`Coalescer`), judged against everything applied since
    /// its first change.  Changes up to seq `fixedThrough` have already been sent as they were
    /// coalesced then (the sync client resends exactly those bytes, SYNC-003): they are neither
    /// returned nor rewritten, only judged against like any other applied change.
    ///
    /// The batch is written first (D-076: "flush before push").  A change still taking keystrokes
    /// (`DocumentCore.open`) is not sent until the word ends or the typing pauses for
    /// `UndoStack.typingPause`, when it is sealed, so it never changes after leaving the Mac.
    public func pendingUpload(rules: Coalescer.Rules = .standard, fixedThrough: UInt64 = 0) throws -> [Wiretuner_Doc_V1_Change] {
        sealIfPaused()
        try flush()
        guard let database else { throw Failure.closed }
        let replica = core.replica
        let open = core.open?.seq
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
        return Coalescer.coalesce(log, rules: rules).filter { $0.seq != open }
    }

    /// Seals the open change once the typing has paused (`UndoStack.typingPause`).
    private func sealIfPaused() {
        guard core.open != nil else { return }
        let paused = engine.lastLocalChange.map { ContinuousClock.now - $0 >= .seconds(UndoStack.typingPause) } ?? true
        if paused { sealOpenChange() }
    }

    /// Seals the change still taking keystrokes (`DocumentCore.seal`): the next keystroke starts a
    /// change of its own, and this one may be sent.
    public func sealOpenChange() {
        engine.update { $0.seal() }
    }

    /// The seq of the current replica's oldest local change still waiting for an acknowledgement.
    public func oldestUnacknowledgedSeq() throws -> UInt64? {
        try flush()
        guard let database else { throw Failure.closed }
        return try database.read { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(seq) FROM changes WHERE local = 1 AND server_seq IS NULL AND replica = ?",
                               arguments: [core.replica.sql]).map(UInt64.init(sql:))
        }
    }

    /// How many local changes of the current replica wait for an acknowledgement (the outbox).
    public func outboxCount() throws -> Int {
        try flush()
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
        try flush()
        guard let database else { throw Failure.closed }
        let replica = core.replica
        let seqs = try database.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT seq FROM changes WHERE local = 1 AND server_seq IS NULL AND replica = ? AND seq <= ?
                """, arguments: [replica.sql, seq.sql]).map(UInt64.init(sql:))
        }
        guard !seqs.isEmpty else { return }
        try commit({ core, _ in
            for accepted in seqs {
                core.acknowledge(seq: accepted, serverSeq: serverSeq)
            }
        }, persist: { db, _ in
            try db.execute(sql: """
                UPDATE changes SET server_seq = ?, sent_at = ? WHERE local = 1 AND server_seq IS NULL AND replica = ? AND seq <= ?
                """, arguments: [serverSeq.sql, Date().timeIntervalSince1970, replica.sql, seq.sql])
        })
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
        try flush()
        guard !diverged else { throw Failure.diverged }
        let (stored, localOnly) = try storedLog()
        try commit({ core, pending -> UInt64 in
            var fresh = DocumentCore(state: state, replica: core.replica, nextSeq: core.nextSeq,
                                     lastServerSeq: max(serverSeq, core.lastServerSeq), undoStack: core.undoStack,
                                     horizon: core.horizon)
            for (change, sequenced) in stored {
                fresh.replay(change, serverSeq: sequenced)
            }
            // Local changes applied since the flush above are not stored yet: they go on top too.
            for change in pending.compactMap(\.change) {
                fresh.replay(change, serverSeq: nil)
            }
            fresh.restoreLocalOnly(localOnly + pending.flatMap(\.localOnly))
            core = fresh
            return core.lastServerSeq
        }, persist: { db, lastServerSeq in
            try db.execute(sql: "UPDATE meta SET last_server_seq = ? WHERE id = 1", arguments: [lastServerSeq.sql])
        })
        try await rewriteSnapshot()
    }

    // Every stored change in order, with its server sequence, and the local-only registers.
    private func storedLog() throws -> ([(Wiretuner_Doc_V1_Change, UInt64?)], [Write]) {
        guard let database else { throw Failure.closed }
        return try database.read { db in
            (try Row.fetchAll(db, sql: "SELECT server_seq, data FROM changes ORDER BY id").map { row in
                (try Self.change(row["data"]), (row["server_seq"] as Int64?).map(UInt64.init(sql:)))
            }, try LocalOnlyRows.all(db))
        }
    }

    /// Records a stable point the server published (`DocumentCore.advanceHorizon`, D-067), and
    /// keeps it in `meta.horizon_seq`: the server credits the changes this replica pushes after a
    /// relaunch with the publication it confirmed before it, so the horizon they are made under
    /// must not start again from 0.  A store that cannot be written keeps it in memory only.
    public func advanceHorizon(to stableSeq: UInt64) {
        guard stableSeq > core.horizon else { return }
        engine.update { $0.advanceHorizon(to: stableSeq) }
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
        try commit({ core, _ -> UInt64 in
            core.acknowledge(seq: seq, serverSeq: serverSeq)
            return core.replica
        }, persist: { db, replica in
            try Self.markAcknowledged(replica: replica, seq: seq, serverSeq: serverSeq, db)
        })
    }

    private static func markAcknowledged(replica: UInt64, seq: UInt64, serverSeq: UInt64, _ db: Database) throws {
        try db.execute(sql: """
            UPDATE changes SET server_seq = ?, sent_at = ? WHERE replica = ? AND seq = ? AND local = 1
            """, arguments: [serverSeq.sql, Date().timeIntervalSince1970, replica.sql, seq.sql])
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

    private func writeSnapshot() async throws {
        guard database != nil else { throw Failure.closed }
        // The state, and the changes queued before it written in the same step without suspending:
        // the rows up to `through` are then exactly what `state` holds.  The open change is sealed,
        // since a row the snapshot holds must never grow afterwards.
        let (state, serverSeq, through) = try commit({ core, _ -> Captured in
            core.seal()
            return Captured(state: core.state, serverSeq: core.lastServerSeq)
        }, changed: { _ in false }).withRow(try lastRow())
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

    private struct Captured: Sendable {
        var state: EngineState
        var serverSeq: UInt64

        func withRow(_ row: Int64) -> (EngineState, UInt64, Int64) { (state, serverSeq, row) }
    }

    private func lastRow() throws -> Int64 {
        guard let database else { throw Failure.closed }
        return try database.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM changes") } ?? 0
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
        let hardware = options.hardwareUUID()
        try commit({ core, _ in core.rotate(to: replica) }, persist: { db, _ in
            try db.execute(sql: "UPDATE meta SET replica_id = ?, next_seq = 1, hardware_uuid = ? WHERE id = 1",
                           arguments: [replica.sql, hardware])
        })
        return replica
    }

    /// Stops the periodic rewrite, writes the snapshot and closes the database.
    public func close() async throws {
        timer?.cancel()
        timer = nil
        flushTask?.cancel()
        flushTask = nil
        guard database != nil else { return }
        if !diverged {
            try await rewriteSnapshot()
        }
        engine.onPending(nil)
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

    /// How many local changes, of this replica or a retired one, wait for an acknowledgement.
    public func unsentChangeCount() throws -> Int {
        try flush()
        guard let database else { throw Failure.closed }
        return try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM changes WHERE local = 1 AND server_seq IS NULL")!
        }
    }

    /// How many calls of any kind wait in `pending_calls` (named versions, comment marks...).
    public func pendingCallCount() throws -> Int {
        guard let database else { throw Failure.closed }
        return try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_calls")! }
    }

    /// Whether any local change, of this replica or a retired one, waits for an acknowledgement.
    public func hasUnsentChanges() throws -> Bool {
        try flush()
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
        try reset(salvaging: reason)
    }

    /// Drops every unacknowledged local change and the local state, rotating to a new replica:
    /// the document reverts to the server's state on the next session (*Save my version as a
    /// copy…* and *Keep my changes on a branch*, reconcile.adoc).  Returns the new replica id.
    @discardableResult
    public func discardLocalChanges() throws -> UInt64 {
        try reset(salvaging: nil)
    }

    // Empties the store and the state for a new replica, first moving the unsent local changes --
    // the ones still queued included, which `commit` writes ahead -- to `salvage` when `reason`
    // is given.
    private func reset(salvaging reason: SalvageReport.Reason?) throws -> UInt64 {
        guard let database else { throw Failure.closed }
        let replica = options.makeReplicaID()
        let hardware = options.hardwareUUID()
        let schema = options.schema
        let localOnly = try database.read { db in try LocalOnlyRows.all(db) }
        try commit({ core, pending in
            core = DocumentCore(state: EngineState(schema: schema), replica: replica, horizon: core.horizon)
            core.restoreLocalOnly(localOnly + pending.flatMap(\.localOnly))
        }, persist: { db, _ in
            if let reason {
                try db.execute(sql: """
                    INSERT INTO salvage (reason, data)
                    SELECT ?, data FROM changes WHERE local = 1 AND server_seq IS NULL ORDER BY id
                    """, arguments: [reason.rawValue])
            }
            try db.execute(sql: "DELETE FROM changes; DELETE FROM snapshot; DELETE FROM undo")
            try db.execute(sql: """
                UPDATE meta SET replica_id = ?, next_seq = 1, last_server_seq = 0, hardware_uuid = ?,
                                review_kind = NULL, review_base_seq = NULL, salvage_report = NULL WHERE id = 1
                """, arguments: [replica.sql, hardware])
        })
        return replica
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
        try commit({ core, _ -> Reissued in
            // On a copy: a command that throws leaves the state as it was.
            var trial = core
            var outcomes: [DocumentCore.Outcome] = []
            for change in changes {
                var from = 0
                repeat {
                    let outcome = try trial.perform(SalvageCommand(change: change, from: from, shared: shared), recording: recording)
                    from = max(shared.next, from + 1)
                    if let outcome { outcomes.append(outcome) }
                } while from < change.ops.count
            }
            core = trial
            return Reissued(outcomes: outcomes, nextSeq: core.nextSeq, stack: core.undoStack)
        }, persist: { db, reissued in
            try writePending(reissued.outcomes, nextSeq: reissued.nextSeq, stack: reissued.stack, db)
            try db.execute(sql: "DELETE FROM salvage")
        })
        return shared.report
    }

    private struct Reissued: Sendable {
        var outcomes: [DocumentCore.Outcome]
        var nextSeq: UInt64
        var stack: UndoStack
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

    // MARK: Pending calls and local history (COLLAB-024)

    /// The calls of `kind` queued on this Mac, in the order they were queued.
    public func pendingCalls(kind: String) throws -> [PendingCall] {
        guard let database else { throw Failure.closed }
        return try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, kind, payload, created_at FROM pending_calls WHERE kind = ? ORDER BY ord", arguments: [kind])
                .map { PendingCall(id: $0["id"], kind: $0["kind"], payload: $0["payload"], createdAt: Date(timeIntervalSince1970: $0["created_at"])) }
        }
    }

    /// Makes the calls of `kind` exactly `calls`: a call already queued keeps its place (and takes
    /// the new payload), new ones go last, missing ones are removed.  One transaction.
    public func replacePendingCalls(kind: String, with calls: [PendingCall]) throws {
        try write { db, _ in
            let ids = calls.map(\.id)
            let existing = try String.fetchAll(db, sql: "SELECT id FROM pending_calls WHERE kind = ?", arguments: [kind])
            for id in existing where !ids.contains(id) {
                try db.execute(sql: "DELETE FROM pending_calls WHERE id = ?", arguments: [id])
            }
            for call in calls {
                try db.execute(sql: """
                    INSERT INTO pending_calls (id, kind, payload, created_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                    """, arguments: [call.id, kind, call.payload, call.createdAt.timeIntervalSince1970])
            }
        }
    }

    /// What the local `changes` table can show of the history (history.adoc, "Offline behavior"):
    /// the sequenced changes it still holds (remote ones and this Mac's acknowledged ones), the
    /// unsent ones, and the oldest seq whose state `state(atServerSeq:)` can rebuild.
    public func localHistory() throws -> LocalHistory {
        try flush()
        guard let database else { throw Failure.closed }
        let head = core.lastServerSeq
        return try database.read { db in
            var floor: UInt64 = 0
            if let snapshot = try Int64.fetchOne(db, sql: "SELECT server_seq FROM snapshot WHERE id = 1") {
                floor = UInt64(sql: snapshot)
            }
            // A local change the snapshot holds must be sequenced at or before the seq rebuilt.
            let unsequenced = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM changes WHERE in_snapshot = 1 AND local = 1 AND server_seq IS NULL)")!
            if unsequenced {
                floor = head &+ 1
            } else if let latest = try Int64.fetchOne(db, sql: "SELECT MAX(server_seq) FROM changes WHERE in_snapshot = 1 AND local = 1") {
                floor = max(floor, UInt64(sql: latest))
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT server_seq, local, label, data FROM changes
                WHERE server_seq IS NOT NULL OR local = 1 ORDER BY (server_seq IS NULL), server_seq, id
                """)
            var sequenced: [LocalHistory.Entry] = []
            var unsent: [LocalHistory.Entry] = []
            for row in rows {
                let change = try Self.change(row["data"])
                let serverSeq: Int64? = row["server_seq"]
                let entry = LocalHistory.Entry(serverSeq: serverSeq.map(UInt64.init(sql:)), label: row["label"], local: row["local"],
                                               replica: change.replica, wallTime: Date(timeIntervalSince1970: Double(change.wallTimeMs) / 1000))
                if entry.serverSeq == nil { unsent.append(entry) } else { sequenced.append(entry) }
            }
            return LocalHistory(head: head, rebuildableFrom: floor, sequenced: sequenced, unsent: unsent)
        }
    }

    // MARK: Access (COLLAB-014)

    /// Refuses (or accepts again) local changes: `perform`, `undo` and `redo` throw
    /// `Failure.readOnly` while set, so no local change enters the outbox while the caller cannot
    /// edit (sharing.adoc, "When your access changes mid-session").  Remote changes still apply.
    public func setReadOnly(_ readOnly: Bool) {
        setReadOnly(readOnly, commentsAllowed: false)
    }

    /// `setReadOnly`, still accepting changes that concern comments only when `commentsAllowed`
    /// (a commenter: comments.adoc, "Who may do what"; COLLAB-034).
    public func setReadOnly(_ readOnly: Bool, commentsAllowed: Bool) {
        engine.setGate(DocumentEngine.Gate(readOnly: readOnly, commentsAllowed: commentsAllowed))
    }

    /// Closes the store and deletes its directory (the caller's access was removed, and the offer
    /// for its unsent changes was settled).
    public func delete() async throws {
        timer?.cancel()
        timer = nil
        flushTask?.cancel()
        flushTask = nil
        engine.onPending(nil)
        _ = engine.takePending()
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
        try flush()
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
        try flush()
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
