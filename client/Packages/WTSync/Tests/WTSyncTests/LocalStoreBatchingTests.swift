import Foundation
import GRDB
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// D-076: the `Document` façade applies local changes at once and the store writes them in
/// batches -- at most `batchInterval` later, before the outbox is read or sent, before any other
/// write and on close -- collapsing same-register writes within a batch and keeping a word's
/// keystrokes in one change.  The result is the unbatched pipeline's: the same state here, after a
/// relaunch, and on a replica that receives the uploads.
@MainActor @Suite struct LocalStoreBatchingTests {
    let scratch = Scratch()
    nonisolated static let now = Date(timeIntervalSince1970: 1_000)

    func open(_ name: String = "doc", batch: Duration = .seconds(60), fault: (@Sendable () throws -> Void)? = nil,
              replicas: Replicas = Replicas()) async throws -> LocalStore {
        var opts = options(replicas: replicas)
        opts.batchInterval = batch
        opts.fault = fault
        return try await LocalStore.open(documentID: "D1", at: scratch.url(name), options: opts)
    }

    func document(_ store: LocalStore) async -> Document {
        await Document(backend: store, clock: { LocalStoreBatchingTests.now })
    }

    func rows(_ name: String = "doc", _ sql: String = "SELECT COUNT(*) FROM changes") throws -> Int {
        let queue = try DatabaseQueue(path: scratch.url(name).path)
        defer { try? queue.close() }
        return try queue.read { try Int.fetchOne($0, sql: sql)! }
    }

    /// The `local` flag of every stored change, in order.
    func localFlags() throws -> [Int64] {
        let queue = try DatabaseQueue(path: scratch.url().path)
        defer { try? queue.close() }
        return try queue.read { try Int64.fetchAll($0, sql: "SELECT local FROM changes ORDER BY id") }
    }

    /// The state a replica that has only received `changes` holds.
    static func synced(_ changes: [Wiretuner_Doc_V1_Change]) -> [UInt8] {
        var state = EngineState()
        for change in changes { state.apply(change) }
        return StateHash.of(state.store)
    }

    @Test func aLocalChangeIsAppliedAtOnceAndWrittenWithinTheBatchInterval() async throws {
        let store = try await open(batch: .milliseconds(30))
        let doc = await document(store)
        try doc.performNow(createLayer("A"))
        #expect(doc.revision == 1 && store.engine.hasPending, "on screen, not yet written")
        #expect(try rows() == 0)
        let deadline = ContinuousClock.now + .seconds(5)
        while store.engine.hasPending, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let written = try rows()
        #expect(!store.engine.hasPending && written == 1, "written by the scheduled batch")
        try await store.close()
    }

    /// The same edits through the batched façade and through the unbatched pipeline (every command
    /// written as it is made, every keystroke its own change) give the same state hash, locally and
    /// after a relaunch, and the same synced result on a replica that receives the uploads.
    @Test func batchedAndUnbatchedGiveTheSameStateAndTheSameSyncedResult() async throws {
        let batchedStore = try await open("batched")
        let unbatched = try await open("unbatched")
        let doc = await document(batchedStore)
        func edits(_ perform: (any Command) async throws -> Wiretuner_Doc_V1_Change?) async throws {
            let layer = try #require(try await perform(createLayer("A")))
            let node = OpID(counter: layer.startCounter, replica: layer.replica)
            for index in 0..<40 {
                _ = try await perform(OpsCommand("Rename", ops: [Fixture.rename(node, "N\(index)")]))
            }
            let text = try #require(try await perform(OpsCommand("Create Text", ops: [Ops.create(parent: Fixture.layers, position: [0x90],
                                                                                                   props: Fixture.textBlock())])))
            let block = OpID(counter: text.startCounter, replica: text.replica)
            var left = OpID.zero
            for character in "typed as one word" {
                let typed = try #require(try await perform(Typing(node: block, left: left, chars: String(character))))
                left = OpID(counter: typed.startCounter, replica: typed.replica)
            }
            _ = try await perform(OpsCommand("Rename", ops: [Fixture.rename(node, "Last")]))
        }
        try await edits { try doc.performNow($0) }
        try await edits { command in
            let change = try await unbatched.perform(command, recording: Fixture.recording()).change
            await unbatched.sealOpenChange()
            return change
        }
        let local = await batchedStore.read { StateHash.of($0.store) }
        #expect(await unbatched.read { StateHash.of($0.store) } == local)
        let batchedUpload = try await batchedStore.pendingUpload()
        let unbatchedUpload = try await unbatched.pendingUpload()
        #expect(batchedUpload.count < unbatchedUpload.count, "\(batchedUpload.count) changes instead of \(unbatchedUpload.count)")
        #expect(batchedUpload.map(\.seq) == Array(1...UInt64(batchedUpload.count)), "seqs stay dense")
        #expect(Self.synced(batchedUpload) == local && Self.synced(unbatchedUpload) == local)
        // A relaunch replays the same state.
        try await batchedStore.close()
        try await unbatched.close()
        let reopened = try await open("batched")
        #expect(await reopened.read { StateHash.of($0.store) } == local)
        #expect(await reopened.summary().undo.undoTitle == "Undo Rename")
        try await reopened.close()
    }

    @Test func aHundredTypedCharactersAreAHandfulOfChanges() async throws {
        let store = try await open()
        let doc = await document(store)
        let created = try #require(try doc.performNow(CreateTextBlock(.point(.zero), text: "")))
        let node = created.createdObjects[0]
        let sentence = "the quick brown fox jumps over the lazy dog and keeps running far away until the night falls anew..."
        #expect(sentence.count == 100)
        let before = try await store.outboxCount()
        for character in sentence {
            try doc.performNow(InsertText(node: node, text: String(character), at: .end, typing: true))
        }
        #expect(doc.state.text(node, TextFields.text)?.string == sentence)
        let typed = try await store.outboxCount() - before
        let words = sentence.split(separator: " ").count
        #expect(typed == words, "one change per word: \(typed)")
        // The last word is still open: it is not sent until sealed (a pause or the end of the word).
        #expect(try await store.pendingUpload().count == before + words - 1)
        await store.sealOpenChange()
        let upload = try await store.pendingUpload()
        let localHash = await store.read { StateHash.of($0.store) }
        #expect(upload.count == before + words && Self.synced(upload) == localHash)
        try await store.close()
    }

    @Test func anOpenChangeGrowsInPlaceAcrossWritesAndIsSealedBeforeASnapshot() async throws {
        let store = try await open()
        let doc = await document(store)
        let created = try #require(try doc.performNow(CreateTextBlock(.point(.zero), text: "")))
        let node = created.createdObjects[0]
        for character in "ab" { try doc.performNow(InsertText(node: node, text: String(character), at: .end, typing: true)) }
        try await store.flush()
        let written = try rows()
        for character in "cd" { try doc.performNow(InsertText(node: node, text: String(character), at: .end, typing: true)) }
        try await store.flush()
        #expect(try rows() == written, "the open change's row is rewritten, not appended")
        let outbox = try await store.outbox()
        #expect(outbox.last!.ops.count == 4)
        // A snapshot seals it: a row the snapshot holds never grows.
        try await store.rewriteSnapshot()
        #expect(store.engine.core.open == nil)
        try doc.performNow(InsertText(node: node, text: "e", at: .end, typing: true))
        try await store.close()
        let reopened = try await open()
        #expect(await reopened.read { $0.text(node, TextFields.text)?.string } == "abcde")
        #expect(try await reopened.outbox().count == outbox.count + 1)
        try await reopened.close()
    }

    @Test func sameRegisterWritesInOneBatchKeepOnlyTheLatest() async throws {
        let store = try await open()
        let doc = await document(store)
        let layer = try #require(try doc.performNow(createLayer("A")))
        let node = OpID(counter: layer.startCounter, replica: layer.replica)
        for index in 0..<20 { try doc.performNow(OpsCommand("Rename", ops: [Fixture.rename(node, "N\(index)")])) }
        let outbox = try await store.outbox()
        #expect(outbox.count == 21, "every change keeps its seq and label")
        let kept = outbox.dropFirst().filter { change in change.ops.contains { if case .set = $0.op { true } else { false } } }
        #expect(kept.count == 1 && kept[0].seq == 21, "only the last rename's write is stored")
        #expect(await store.read { $0.register(node, Fixture.name)?.value } == Fixture.nameValue("N19"))
        try await store.close()
        let reopened = try await open()
        #expect(await reopened.read { $0.register(node, Fixture.name)?.value } == Fixture.nameValue("N19"))
        try await reopened.close()
    }

    /// A crash loses at most the unwritten batch; a failed write leaves the store diverged, and
    /// reopening restores what was written.
    @Test func aFailedBatchWriteDivergesAndReopeningKeepsWhatWasWritten() async throws {
        let failures = FailAfter(2)
        let store = try await open(fault: { try failures.check() })
        let doc = await document(store)
        let layer = try #require(try doc.performNow(createLayer("A")))
        let node = OpID(counter: layer.startCounter, replica: layer.replica)
        try await store.flush()
        try doc.performNow(OpsCommand("Rename", ops: [Fixture.rename(node, "B")]))
        await #expect(throws: FailAfter.Crash.self) { try await store.flush() }
        #expect(throws: LocalStore.Failure.diverged) { try doc.performNow(OpsCommand("Rename", ops: [Fixture.rename(node, "C")])) }
        await #expect(throws: LocalStore.Failure.diverged) { try await store.receive(Fixture.change(99, seq: 1, start: 100, [Ops.noop()]), serverSeq: 1) }
        try await store.close()
        let reopened = try await open()
        #expect(await reopened.read { $0.register(node, Fixture.name)?.value } == Fixture.nameValue("A"))
        #expect(await reopened.nextSeq == 2)
        try await reopened.close()
    }

    @Test func otherWritesAndReadsWriteThePendingBatchFirst() async throws {
        let store = try await open()
        let doc = await document(store)
        let layer = try #require(try doc.performNow(createLayer("A")))
        let node = OpID(counter: layer.startCounter, replica: layer.replica)
        // A remote change lands after the local one applied before it.
        _ = try await store.receive(Fixture.change(99, seq: 1, start: 100, [Fixture.rename(node, "R")]), serverSeq: 1)
        #expect(try localFlags() == [1, 0])
        // Acknowledgements, counts and history see the batch.
        try doc.performNow(OpsCommand("Rename", ops: [Fixture.rename(node, "L")]))
        let unsent = try await store.unsentChangeCount()
        let hasUnsent = try await store.hasUnsentChanges()
        #expect(unsent == 2 && hasUnsent)
        #expect(try await store.oldestUnacknowledgedSeq() == 1)
        try doc.performNow(OpsCommand("Rename", ops: [Fixture.rename(node, "M")]))
        try await store.acknowledge(seq: 1, serverSeq: 2)
        #expect(try await store.outboxCount() == 2)
        try doc.performNow(OpsCommand("Rename", ops: [Fixture.rename(node, "N")]))
        try await store.acknowledgeAccepted(through: 4, serverSeq: 5)
        #expect(try await store.outboxCount() == 0)
        try doc.performNow(OpsCommand("Rename", ops: [Fixture.rename(node, "O")]))
        #expect(try await store.localHistory().unsent.count == 1)
        try doc.performNow(OpsCommand("Rename", ops: [Fixture.rename(node, "P")]))
        let retired = try await store.retiredOutbox()
        let outboxNow = try await store.outbox()
        #expect(retired.isEmpty && outboxNow.count == 2)
        // A snapshot installed from the server keeps the local changes applied since the last write.
        try doc.performNow(OpsCommand("Rename", ops: [Fixture.rename(node, "Q")]))
        let hash = await store.read { StateHash.of($0.store) }
        let server = await store.read { $0 }
        try await store.installSnapshot(server, serverSeq: 5)
        #expect(await store.read { StateHash.of($0.store) } == hash)
        // Rotation writes the old replica's changes first.
        try doc.performNow(OpsCommand("Rename", ops: [Fixture.rename(node, "S")]))
        try await store.rotateReplica()
        #expect(try await store.retiredOutbox().count == 4)
        try doc.performNow(OpsCommand("Rename", ops: [Fixture.rename(node, "T")]))
        #expect(try await store.outbox().map(\.seq) == [1])
        try await store.close()
    }

    @Test func salvageAndDiscardTakeThePendingBatch() async throws {
        let store = try await open()
        let doc = await document(store)
        try doc.performNow(createLayer("A"))
        try await store.beginSalvage(reason: .conflict)
        let salvaged = try await store.pendingSalvageCount()
        let left = try await store.outboxCount()
        #expect(salvaged == 1 && left == 0)
        await doc.reload()
        _ = try await store.applySalvage(recording: Fixture.recording())
        #expect(try await store.outboxCount() == 1)
        try doc.performNow(createLayer("B"))
        try await store.discardLocalChanges()
        let unsentAfter = try await store.unsentChangeCount()
        let next = await store.nextSeq
        #expect(unsentAfter == 0 && next == 1)
        try await store.close()
    }

    @Test func closeWritesTheBatchAndDeleteDropsIt() async throws {
        let store = try await open()
        let doc = await document(store)
        try doc.performNow(createLayer("A"))
        try await store.close()
        let reopened = try await open()
        #expect(try await reopened.outboxCount() == 1)
        let again = await document(reopened)
        try again.performNow(createLayer("B"))
        try await reopened.delete()
        #expect(!FileManager.default.fileExists(atPath: scratch.url().path))
        await #expect(throws: LocalStore.Failure.closed) { try await reopened.outbox() }
    }
}
