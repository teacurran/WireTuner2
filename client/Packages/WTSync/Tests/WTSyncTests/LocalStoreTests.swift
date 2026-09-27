import Foundation
import GRDB
import Synchronization
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// SYNC-001: the local store's schema, open/close with snapshot and replay, the periodic rewrite,
/// the hardware binding, and that an applied change is never lost.
@Suite struct LocalStoreTests {
    let scratch = Scratch()

    func open(_ name: String = "doc", _ options: LocalStore.Options = options(), id: String = "D1") async throws -> LocalStore {
        try await LocalStore.open(documentID: id, at: scratch.url(name), options: options)
    }

    /// Performs `count` renames of a new layer: count + 1 changes.
    @discardableResult
    func edit(_ store: LocalStore, renames count: Int) async throws -> OpID {
        let created = try await store.perform(createLayer("A"), recording: Fixture.recording()).change!
        let node = OpID(counter: created.startCounter, replica: created.replica)
        for index in 0..<count {
            _ = try await store.perform(OpsCommand("Rename", ops: [Fixture.rename(node, "N\(index)")]), recording: Fixture.recording())
        }
        return node
    }

    func rows(_ url: URL, _ sql: String) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { try Int.fetchOne($0, sql: sql)! }
    }

    @Test func createsTheSchemaAndReopensFromTheSnapshot() async throws {
        let store = try await open()
        #expect(store.report.created && store.report.rotatedFrom == nil && store.report.replayed == 0)
        #expect(await store.replica == 42 && store.documentID == "D1")
        try await edit(store, renames: 3)
        #expect(await store.nextSeq == 5)
        let hash = await store.read { $0.stateHash }
        try await store.close()
        try await store.close()   // closing twice is harmless
        for table in ["meta", "snapshot", "changes", "undo", "blobs_pending", "view"] {
            _ = try rows(scratch.url(), "SELECT COUNT(*) FROM \(table)")
        }
        #expect(try rows(scratch.url(), "SELECT COUNT(*) FROM snapshot") == 1)
        #expect(try rows(scratch.url(), "SELECT COUNT(*) FROM changes") == 4)   // unacked: kept, in the snapshot
        let reopened = try await open()
        #expect(!reopened.report.created && reopened.report.replayed == 0)
        #expect(await reopened.read { $0.stateHash } == hash)
        #expect(await reopened.replica == 42)
        #expect(await reopened.nextSeq == 5)
        #expect(try await reopened.outbox().map(\.seq) == [1, 2, 3, 4])
        let summary = await reopened.summary()
        #expect(summary.undo.undoTitle == "Undo Rename" && summary.undo.undoCount == 4)
    }

    /// A crash leaves the files as they are between two transactions; every change a perform call
    /// returned is in them.
    @Test func aCrashImageHoldsEveryAppliedChange() async throws {
        let store = try await open()
        let node = try await edit(store, renames: 50)
        let hash = await store.read { $0.stateHash }
        let copy = try scratch.crashImage(of: "doc", to: "crash")
        let recovered = try await LocalStore.open(documentID: "D1", at: copy, options: options())
        #expect(recovered.report.replayed == 51)
        #expect(await recovered.read { $0.stateHash } == hash)
        #expect(await recovered.read { $0.register(node, Fixture.name)?.value } == Fixture.nameValue("N49"))
        #expect(try await recovered.outbox().count == 51)
        #expect(await recovered.summary().undo.undoCount == 51)
    }

    /// A failure inside the transaction -- after the change was applied in memory, before it was
    /// written -- rolls the file back: the change was never reported applied, the ones before it
    /// are all there, and the store refuses further writes until reopened.
    @Test func aFailureMidChangeLosesNothingThatWasApplied() async throws {
        var opts = options()
        let failures = FailAfter(3)
        opts.fault = { try failures.check() }
        let store = try await open("doc", opts)
        let created = try await store.perform(createLayer("A"), recording: Fixture.recording()).change!
        let node = OpID(counter: created.startCounter, replica: created.replica)
        _ = try await store.perform(OpsCommand("Rename", ops: [Fixture.rename(node, "B")]), recording: Fixture.recording())
        let hash = await store.read { $0.stateHash }
        await #expect(throws: FailAfter.Crash.self) {
            try await store.perform(OpsCommand("Rename", ops: [Fixture.rename(node, "C")]), recording: Fixture.recording())
        }
        await #expect(throws: LocalStore.Failure.diverged) {
            try await store.perform(OpsCommand("Rename", ops: [Fixture.rename(node, "D")]), recording: Fixture.recording())
        }
        try await store.close()   // a diverged store closes without writing its state
        let reopened = try await open()
        #expect(await reopened.read { $0.stateHash } == hash)
        #expect(await reopened.read { $0.register(node, Fixture.name)?.value } == Fixture.nameValue("B"))
        #expect(try await reopened.outbox().count == 2)
        #expect(await reopened.nextSeq == 3)
    }

    @Test func aCommandThatThrowsDoesNotDivergeTheStore() async throws {
        let store = try await open()
        await #expect(throws: Failing.Failure.self) { try await store.perform(Failing(), recording: Fixture.recording()) }
        #expect(try await store.perform(createLayer("A"), recording: Fixture.recording()).change != nil)
        #expect(try await store.perform(OpsCommand("Nothing", ops: []), recording: Fixture.recording()).change == nil)
        // A change that changes nothing undoable is stored but is no undo step.
        let noop = try await store.perform(OpsCommand("Noop", ops: [Ops.noop()]), recording: Fixture.recording())
        #expect(noop.change != nil && noop.undo.undoCount == 1)
    }

    @Test func aStoreOnAnotherMacRotatesItsReplica() async throws {
        let replicas = Replicas()
        let store = try await open("doc", options(hardware: "MAC-A", replicas: replicas))
        try await edit(store, renames: 1)
        try await store.close()
        let moved = try await open("doc", options(hardware: "MAC-B", replicas: replicas))
        #expect(moved.report.rotatedFrom == 42)
        #expect(await moved.replica == 43)
        #expect(await moved.nextSeq == 1)
        #expect(try await moved.outbox().isEmpty)
        #expect(try await moved.retiredOutbox().count == 2)
        let change = try await moved.perform(createLayer("B", position: [0x90]), recording: Fixture.recording()).change!
        #expect(change.replica == 43 && change.seq == 1)
        try await moved.close()
        let again = try await open("doc", options(hardware: "MAC-B", replicas: replicas))
        #expect(again.report.rotatedFrom == nil)
        #expect(await again.replica == 43)
        #expect(await again.nextSeq == 2)
        // REPLICA_CONFLICT: rotate on demand.
        #expect(try await again.rotateReplica() == 44)
        #expect(await again.replica == 44)
        #expect(await again.nextSeq == 1)
        #expect(await again.summary().replica == 44)
    }

    @Test func aStoreOfAnotherDocumentIsRefused() async throws {
        let store = try await open()
        try await store.close()
        await #expect(throws: LocalStore.Failure.wrongDocument("D1")) { try await self.open("doc", options(), id: "D2") }
    }

    @Test func theSnapshotIsRewrittenPeriodically() async throws {
        let store = try await open("doc", options(interval: .milliseconds(20)))
        try await edit(store, renames: 2)
        // Two rewrites after the edits: one may have been under way while they were written (it
        // covers only the rows before it began); the second began after them.
        let written = await store.snapshotsWritten
        try await eventually("two rewrites after the edits") { await store.snapshotsWritten >= written + 2 }
        #expect(try rows(scratch.url(), "SELECT COUNT(*) FROM snapshot") == 1)
        #expect(try rows(scratch.url(), "SELECT COUNT(*) FROM changes WHERE in_snapshot = 0") == 0)
        try await store.close()
    }

    @Test func aRewriteDropsWhatTheSnapshotHoldsAndKeepsTheOutbox() async throws {
        let store = try await open()
        let node = try await edit(store, renames: 0)                                     // local seq 1
        _ = try await store.acknowledge(seq: 1, serverSeq: 1)
        _ = try await store.receive(Fixture.change(99, seq: 1, start: 100, [Fixture.rename(node, "R")]), serverSeq: 2)
        _ = try await store.perform(OpsCommand("Rename", ops: [Fixture.rename(node, "L")]), recording: Fixture.recording())  // seq 2, unacked
        _ = try await store.receive(Fixture.change(99, seq: 2, start: 200, [Fixture.createLayer("S")]), serverSeq: 3)
        try await store.rewriteSnapshot()
        // Rows before the oldest unacked local change go; it and everything after stay, in the snapshot.
        #expect(try rows(scratch.url(), "SELECT COUNT(*) FROM changes") == 2)
        #expect(try rows(scratch.url(), "SELECT COUNT(*) FROM changes WHERE in_snapshot = 0") == 0)
        let hash = await store.read { $0.stateHash }
        _ = try await store.acknowledge(seq: 2, serverSeq: 4)
        try await store.rewriteSnapshot()
        #expect(try rows(scratch.url(), "SELECT COUNT(*) FROM changes") == 0)
        try await store.close()
        let reopened = try await open()
        #expect(await reopened.read { $0.stateHash } == hash)
        #expect(await reopened.lastServerSeq == 3)
    }

    /// The snapshot is encoded off the actor: changes applied meanwhile are not in it, stay
    /// unmarked, and are replayed on open.
    @Test func changesDuringARewriteAreKept() async throws {
        let store = try await open()
        let node = try await edit(store, renames: 20)
        async let first: Void = store.rewriteSnapshot()
        async let second: Void = store.rewriteSnapshot()
        for index in 0..<20 {
            _ = try await store.perform(OpsCommand("Rename", ops: [Fixture.rename(node, "M\(index)")]), recording: Fixture.recording())
        }
        _ = try await (first, second)
        let hash = await store.read { $0.stateHash }
        let recovered = try await LocalStore.open(documentID: "D1", at: try scratch.crashImage(of: "doc", to: "crash"), options: options())
        #expect(await recovered.read { $0.stateHash } == hash)
        #expect(await recovered.read { $0.register(node, Fixture.name)?.value } == Fixture.nameValue("M19"))
        try await store.close()
        let reopened = try await open()
        #expect(await reopened.read { $0.stateHash } == hash && reopened.report.replayed == 0)
    }

    @Test func receiveRecordsRemoteChangesAndAcksEchoes() async throws {
        let store = try await open()
        let node = try await edit(store, renames: 1)
        let echo = try await store.outbox()[0]
        _ = try await store.receive(echo, serverSeq: 5)
        #expect(try await store.outbox().map(\.seq) == [2])
        #expect(await store.lastServerSeq == 5)
        let remote = Fixture.change(99, seq: 1, start: 100, [Fixture.rename(node, "R")])
        let update = try await store.receive(remote, serverSeq: 6)
        #expect(update.change == remote)
        _ = try await store.receive(remote, serverSeq: 6)   // delivered twice: recorded once
        #expect(try rows(scratch.url(), "SELECT COUNT(*) FROM changes WHERE local = 0") == 1)
        try await store.acknowledge(seq: 2, serverSeq: 7)
        #expect(try await store.outbox().isEmpty)
        #expect(await store.lastServerSeq == 6)
        let hash = await store.read { $0.stateHash }
        let copy = try scratch.crashImage(of: "doc", to: "crash")
        let recovered = try await LocalStore.open(documentID: "D1", at: copy, options: options())
        #expect(await recovered.read { $0.stateHash } == hash)
        #expect(await recovered.lastServerSeq == 6)
    }

    @Test func theUndoStackIsPersistedCappedAndRebased() async throws {
        let store = try await open()
        let doc = await Document(backend: store, undoLevels: 5)
        let created = try await doc.perform(createLayer("A"))!
        let node = OpID(counter: created.startCounter, replica: created.replica)
        for index in 0..<9 {
            try await doc.perform(OpsCommand("Rename", ops: [Fixture.rename(node, "N\(index)")]))
        }
        #expect(try rows(scratch.url(), "SELECT COUNT(*) FROM undo WHERE stack = 'undo'") == 5)
        try await doc.undo()                                  // N8 -> N7
        #expect(try rows(scratch.url(), "SELECT COUNT(*) FROM undo WHERE stack = 'redo'") == 1)
        try await store.close()
        // Relaunch: the rest of the stack is undoable, including the step the undo rebased.
        let reopened = try await open()
        let relaunched = await Document(backend: reopened, undoLevels: 5)
        #expect(await relaunched.undoTitle == "Undo Rename")
        #expect(await relaunched.redoTitle == "Redo Rename")
        try await relaunched.undo()                           // N7 -> N6
        #expect(await relaunched.read { $0.register(node, Fixture.name)?.value } == Fixture.nameValue("N6"))
        try await relaunched.redo()
        try await relaunched.redo()
        #expect(await relaunched.read { $0.register(node, Fixture.name)?.value } == Fixture.nameValue("N8"))
        // Typing joins the top step: persisted as a replaced row.
        let text = try await relaunched.perform(OpsCommand("Create Text", ops: [Ops.create(parent: Fixture.layers, position: [0x90],
                                                                                            props: Fixture.textBlock())]))!
        let block = OpID(counter: text.startCounter, replica: text.replica)
        let first = try await relaunched.perform(Typing(node: block, left: .zero, chars: "a"))!
        try await relaunched.perform(Typing(node: block, left: OpID(counter: first.startCounter, replica: first.replica), chars: "b"))
        try await reopened.close()
        let third = try await open()
        let summary = await third.summary()
        #expect(summary.undo.undoCount == 5 && summary.undo.undoTitle == "Undo Typing")
        _ = try await third.undo(recording: Fixture.recording())
        #expect(await third.read { $0.text(block, Fixture.text)?.string } == "")
    }

    @Test func anUndoThatFindsNothingStillMovesTheStep() async throws {
        let store = try await open()
        let node = try await edit(store, renames: 1)
        _ = try await store.receive(Fixture.change(99, seq: 1, start: 100, [Fixture.rename(node, "R")]), serverSeq: 1)
        let undo = try await store.undo(recording: Fixture.recording())
        #expect(undo.change == nil && undo.undo.canRedo)
        #expect(try await store.undo(recording: Fixture.recording()).change != nil)   // the creation
        #expect(try await store.undo(recording: Fixture.recording()).change == nil)   // empty
        #expect(try await store.outbox().count == 3)
    }

    @Test func pendingBlobsAndViewState() async throws {
        let store = try await open()
        try await store.addPendingBlob(.init(hash: "big", path: "/b", size: 900))
        try await store.addPendingBlob(.init(hash: "small", path: "/s", size: 10))
        try await store.addPendingBlob(.init(hash: "thumb1", path: "/t1", tag: LocalStore.thumbnailTag, size: 500))
        try await store.addPendingBlob(.init(hash: "thumb2", path: "/t2", tag: LocalStore.thumbnailTag, size: 600))
        #expect(try await store.pendingBlobs().map(\.hash) == ["thumb2", "small", "big"])
        try await store.removePendingBlob(hash: "small")
        #expect(try await store.pendingBlobs().map(\.hash) == ["thumb2", "big"])
        try await store.setViewValue(Data([1, 2]), forKey: "zoom")
        #expect(try await store.viewValue(forKey: "zoom") == Data([1, 2]))
        #expect(try await store.viewValue(forKey: "scroll") == nil)
    }

    @Test func aClosedStoreRefusesWork() async throws {
        let store = try await open()
        try await store.close()
        await #expect(throws: LocalStore.Failure.closed) { try await store.perform(createLayer("A"), recording: Fixture.recording()) }
        await #expect(throws: LocalStore.Failure.closed) { try await store.outbox() }
        await #expect(throws: LocalStore.Failure.closed) { try await store.pendingUpload() }
        await #expect(throws: LocalStore.Failure.closed) { try await store.pendingBlobs() }
        await #expect(throws: LocalStore.Failure.closed) { try await store.viewValue(forKey: "x") }
        await #expect(throws: LocalStore.Failure.closed) { try await store.rewriteSnapshot() }
    }

    @Test func aCorruptChangeRowIsReported() async throws {
        let store = try await open()
        try await store.close()
        let queue = try DatabaseQueue(path: scratch.url().path)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO changes (replica, seq, local, label, data) VALUES (5, 1, 0, '', ?)", arguments: [Data([0xFF, 0xFF])])
        }
        try queue.close()
        await #expect(throws: LocalStore.Failure.self) { try await self.open() }
    }

    @Test func theDefaultLocationAndTheHardwareUUID() throws {
        let url = try LocalStore.defaultURL(documentID: "abc")
        #expect(url.path.hasSuffix("WireTuner/Documents/abc/store.sqlite"))
        #expect(HardwareIdentity.platformUUID().count == 36)
        #expect(HardwareIdentity.registryString(service: "NoSuchService", key: "NoSuchKey") == "")
        #expect(LocalStore.Options().hardwareUUID() == HardwareIdentity.platformUUID())
        let defaults = LocalStore.Options()
        #expect(defaults.snapshotInterval == .seconds(300) && defaults.makeReplicaID() != 0 && defaults.featureLevel == 1)
    }
}

/// Throws on the `n`-th call.
final class FailAfter: Sendable {
    struct Crash: Error {}
    private let remaining: Mutex<Int>

    init(_ n: Int) {
        remaining = Mutex(n)
    }

    func check() throws {
        let hit = remaining.withLock { value -> Bool in
            value -= 1
            return value == 0
        }
        if hit { throw Crash() }
    }
}

/// A command that fails before appending anything that matters.
struct Failing: Command {
    struct Failure: Error {}
    var label: String { "Fail" }
    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        throw Failure()
    }
}

/// A command that types `chars` after `left` in a text block.
struct Typing: Command {
    let node: OpID
    let left: OpID
    let chars: String
    var label: String { "Typing" }
    var coalescing: UndoCoalescing { .typing(node: node, field: Fixture.text, endsWord: false) }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        builder.append(Ops.textInsert(node, Fixture.text, chars, left: left))
    }
}
