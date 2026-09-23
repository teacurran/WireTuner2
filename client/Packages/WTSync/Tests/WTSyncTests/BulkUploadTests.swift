import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// SYNC-005: a backlog at or over the bulk threshold goes up through PushChanges in frames of at
/// most 1 MiB, with progress from the own echoes, resuming from Welcome.last_accepted_seq.
@Suite(.timeLimit(.minutes(5))) struct BulkUploadTests {
    /// A command creating `count` layers: `count` ops in one change.
    func createLayers(_ count: Int, from start: Int) -> OpsCommand {
        OpsCommand("Create Layers", ops: (start..<(start + count)).map { Fixture.createLayer("B\($0)") })
    }

    @Test func aTwentyThousandOpBacklogUploadsThroughThreeForcedDisconnects() async throws {
        let server = FakeSyncServer()
        await server.update { $0.bulkDisconnectAfter = [300, 500, 400] }
        var options = fastOptions()
        options.frameBytes = 64 * 1024   // many frames from a modest backlog
        let harness = try await Harness(server: server, options: options)
        let start = ContinuousClock.now
        for index in 0..<2_000 {
            _ = try await harness.store.perform(createLayers(10, from: index * 10), recording: Fixture.recording())
        }
        let states = Collector(await harness.client.states())
        await harness.client.start()
        try await harness.expectConverged()
        try await harness.waitFor(.saved)
        let elapsed = ContinuousClock.now - start
        #expect(await server.acceptedSeqs(42).count == 2_000)
        #expect(await server.subscribes.count >= 4)
        #expect(await server.duplicates == 0)
        let frames = await server.bulkFrames
        #expect(frames.allSatisfy { $0.count <= 256 })
        let percents = states.all.compactMap { if case .uploadingBacklog(let percent) = $0 { percent } else { nil } }
        #expect(percents.contains(0) && percents.contains { $0 > 0 })
        #expect(await server.pushes.count < 200)
        print("20,000-op backlog through three disconnects: \(elapsed)")
        try await harness.stop()
    }

    @Test func aBulkRejectionIsHandledLikeAUnaryOne() async throws {
        let server = FakeSyncServer()
        await server.update {
            $0.bulkReject = [120: SyncCallError(code: SyncCallError.invalidArgument, reason: .validationFailed, message: "bad")]
        }
        let harness = try await Harness(server: server)
        try await harness.edit(250)
        await harness.client.start()
        // The refused change went up as Noops; its layer stays on this Mac (see sync-protocol.adoc).
        try await harness.expectConverged(sameState: false)
        try await harness.waitForEvent("event") { if case .changeDropped(120, "bad") = $0 { true } else { false } }
        try await harness.stop()
    }

    @Test func largeChangesMakeABacklogByBytesAndAnExpiredTokenIsRefreshed() async throws {
        let server = FakeSyncServer()
        var options = fastOptions()
        options.bulkBytes = 1_000
        let harness = try await Harness(server: server, options: options, tokens: FakeTokens(["token-1", "token-2"]))
        await harness.client.start()
        try await harness.waitFor(.saved)
        await server.update { $0.validToken = "token-2" }
        for index in 0..<3 {
            _ = try await harness.store.perform(createLayers(40, from: index * 40), recording: Fixture.recording())
        }
        await harness.client.localChangesAvailable()
        try await harness.expectConverged()
        #expect(await server.bulkFrames.count >= 1)
        #expect(harness.tokens.refreshes == 1)
        try await harness.stop()
    }

    @Test func framesAreCappedByBytesAndCount() {
        let small = (1...600).map { remoteChange(seq: UInt64($0)) }
        let byCount = BulkFrames.pack(small, documentID: "D1")
        #expect(byCount.map(\.changes.count) == [256, 256, 88])
        #expect(byCount.allSatisfy { $0.documentID == "D1" })
        let byBytes = BulkFrames.pack(small, documentID: "D1", maxBytes: 2_000)
        #expect(byBytes.count > 3 && byBytes.allSatisfy { encodedSize($0) <= 2_000 })
        #expect(byBytes.flatMap(\.changes).map(\.seq) == (1...600).map(UInt64.init))
        let huge = Fixture.change(7, seq: 1, start: 1, [Fixture.createLayer(String(repeating: "x", count: 5_000))])
        let alone = BulkFrames.pack([remoteChange(seq: 1), huge, remoteChange(seq: 2)], documentID: "D1", maxBytes: 2_000)
        #expect(alone.map(\.changes.count) == [1, 1, 1])
        #expect(BulkFrames.pack([], documentID: "D1").isEmpty)
        #expect(BulkFrames.varintSize(127) == 1 && BulkFrames.varintSize(128) == 2 && BulkFrames.varintSize(1 << 20) == 3)
    }

    @Test func backlogProgressIsAckedBytesOverTotal() {
        let changes = (1...4).map { remoteChange(seq: UInt64($0)) }
        let backlog = Backlog(changes)
        #expect(backlog.percent(acked: 0) == 0)
        #expect(backlog.percent(acked: 2) == 50)
        #expect(backlog.percent(acked: 4) == 100)
        #expect(backlog.percent(acked: 9) == 100)
        #expect(Backlog([]).percent(acked: 0) == 100)
    }
}
