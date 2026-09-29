import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// The sync client's pieces: state texts, reasons, signals, broadcasts, `Noop` rewrites, and the
/// local store's sync-facing API.
@Suite struct SyncSupportTests {
    let scratch = Scratch()

    @Test func statesReadAsTheIndicatorDoes() {
        let texts: [(SyncState, String)] = [
            (.opening, "Opening…"), (.saved, "Saved to cloud"), (.syncing(1), "Syncing 1 change"),
            (.syncing(3), "Syncing 3 changes"), (.uploadingBlobs(1), "Uploading 1 image"),
            (.uploadingBlobs(2), "Uploading 2 images"), (.offline(0), "Offline"),
            (.offline(1), "Offline — 1 change waiting"), (.offline(412), "Offline — 412 changes waiting"),
            (.uploadingBacklog(42), "Uploading backlog 42%"), (.needsReview, "Needs review"),
            (.readOnly(.role), "View only"), (.needsSignIn, "Sign in to sync"),
            (.storageFull(1), "Storage full — 1 image waiting"), (.storageFull(2), "Storage full — 2 images waiting"),
            (.error("x"), "Can't sync"), (.localOnly, "On this Mac"),
        ]
        for (state, text) in texts {
            #expect(state.description == text)
        }
        let transition = SyncTransition(from: .opening, to: .saved, cause: "session up")
        #expect(transition.from == .opening && transition.to == .saved)
        #expect(CatchUpProgress(phase: .changes, completed: 0, total: 0).fraction == 1)
        #expect(CatchUpProgress(phase: .changes, completed: 1, total: 4).fraction == 0.25)
    }

    @Test func reasonsReadBackFromTheirWireNames() {
        #expect(SyncCallError.reason(named: "SEQ_GAP") == .seqGap)
        #expect(SyncCallError.reason(named: "REPLICA_CONFLICT") == .replicaConflict)
        #expect(SyncCallError.reason(named: "NOT_A_REASON") == nil)
        #expect(SyncCallError.reason(named: "") == nil)
        #expect(SyncCallError.reason(named: #"X","y":"#) == nil)
        let rejected = SyncCallError(Wiretuner_Sync_V1_ChangeRejected.with {
            $0.reason = .validationFailed
            $0.code = 3
            $0.message = "bad"
        })
        #expect(rejected == SyncCallError(code: 3, reason: .validationFailed, message: "bad"))
        #expect(rejected.description.contains("bad"))
        #expect(SyncCallError(code: 14).description == "status 14: ")
        #expect(FakeGRPCService.reasonName(.unspecified) == nil)
    }

    @Test func signalsWakeWaitersAndLatch() async {
        let signal = Signal()
        signal.fire()
        await signal.wait()                                // pending fire
        await signal.wait(timeout: .milliseconds(10))      // times out
        let latch = Signal(latching: true)
        latch.fire()
        await latch.wait()
        await latch.wait()
        let waiting = Task { await signal.wait() }
        try? await Task.sleep(for: .milliseconds(20))
        signal.fire()
        await waiting.value
        let cancelled = Task { await signal.wait() }
        try? await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        await cancelled.value
    }

    @Test func broadcastsReachEveryOpenStream() async {
        let broadcast = Broadcast<Int>()
        var first: AsyncStream<Int>? = broadcast.stream(initial: 0)
        let second = broadcast.stream()
        broadcast.yield(1)
        var iterator = first!.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        #expect(await iterator.next() == 1)
        var other = second.makeAsyncIterator()
        #expect(await other.next() == 1)
        first = nil
        iterator = broadcast.stream().makeAsyncIterator()
        broadcast.yield(2)
        #expect(await iterator.next() == 2)
    }

    /// TEST-001 finding (b): a refused change becomes one `Noop` however many counters it took, so
    /// the replacement is never over the op limit itself; it keeps the seq and start counter, and
    /// is cut to what `Change` allows.
    @Test func aNoopRewriteIsOneOp() {
        let change = Fixture.change(7, seq: 3, start: 10, [
            Ops.textInsert(OpID(counter: 1, replica: 7), Fixture.text, String(repeating: "a", count: 20_000)), Fixture.createLayer("A"),
        ], label: "Type")
        let noop = noopChange(change)
        #expect(noop.ops == [Ops.noop()] && noop.seq == 3 && noop.startCounter == 10 && noop.label == "Type")
        #expect(noopChange(noop) == noop && isNoopOnly(noop) && !isNoopOnly(change))
        #expect(noopChange(Fixture.change(7, seq: 1, start: 1, [])).ops.count == 1)
        var odd = change
        odd.label = String(repeating: "é", count: 300)
        odd.wallTimeMs = -5
        let cut = noopChange(odd)
        #expect(cut.label.unicodeScalars.count == 256 && cut.wallTimeMs == 0 && noopChange(cut) == cut)
    }

    @Test func changeLimitsAreTheServers() {
        let small = Fixture.change(7, seq: 1, start: 1, [Fixture.createLayer("A"), Fixture.createLayer("B")])
        #expect(ChangeLimits.server == ChangeLimits(ops: 10_000, bytes: 4 << 20) && ChangeLimits.server.admits(small))
        #expect(!ChangeLimits(ops: 1).admits(small) && !ChangeLimits(bytes: 10).admits(small))
        #expect(ChangeLimits.size(of: Ops.noop()) == 4 && ChangeLimits.headerSize(small) > 64)
    }

    @Test func theStoreServesTheSyncClient() async throws {
        let store = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        for index in 0..<4 {
            _ = try await store.perform(createLayer("L\(index)"), recording: Fixture.recording())
        }
        #expect(try await store.outboxCount() == 4)
        #expect(try await store.pendingUpload(fixedThrough: 2).map(\.seq) == [3, 4])
        var dropped = try await store.outbox()[2]
        dropped.ops = [Ops.noop()]
        try await store.replaceUnsent(dropped)
        #expect(try await store.outbox()[2].ops == [Ops.noop()])
        try await store.acknowledgeAccepted(through: 2, serverSeq: 9)
        try await store.acknowledgeAccepted(through: 2, serverSeq: 9)   // nothing left to mark
        #expect(try await store.outbox().map(\.seq) == [3, 4])
        // A snapshot from the server replaces the state; the outbox is replayed on top.
        var remote = EngineState()
        remote.apply(remoteChange(seq: 1), serverSeq: 20)
        try await store.installSnapshot(remote, serverSeq: 20)
        #expect(await store.lastServerSeq == 20)
        let hash = await store.read { $0.stateHash }
        #expect(hash != remote.stateHash)   // the local layers are still there
        #expect(try await store.pendingBlobCount() == 0)
        #expect(store.schema.kinds == Schema.generated.kinds)
        try await store.close()
        await #expect(throws: LocalStore.Failure.closed) { try await store.outboxCount() }
        await #expect(throws: LocalStore.Failure.closed) { try await store.pendingBlobCount() }
        await #expect(throws: LocalStore.Failure.closed) { try await store.installSnapshot(remote, serverSeq: 21) }
    }
}
