import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// SYNC-004: bootstrap from a snapshot, catch-up through FetchChanges with the snapshot hint,
/// the fallback when history is compacted, progress and cancellation.
@Suite(.timeLimit(.minutes(2))) struct CatchUpTests {
    /// A server holding `count` changes of another replica, with a snapshot through `snapshot`.
    func server(count: Int, snapshot: UInt64?) async throws -> FakeSyncServer {
        let server = FakeSyncServer()
        for seq in 1...count {
            try await server.inject(remoteChange(seq: UInt64(seq)))
        }
        if let snapshot {
            await server.takeSnapshot(through: snapshot)
        }
        return server
    }

    @Test func aNeverSeenDocumentBootstrapsFromTheSnapshot() async throws {
        let server = try await server(count: 60, snapshot: 45)
        let harness = try await Harness(server: server, options: steadyOptions())
        await harness.client.start()
        try await harness.waitFor(.saved)
        #expect(await server.fetchSnapshotCalls == 1)
        #expect(await server.fetchChangesCalls.map(\.after) == [45])
        try await harness.waitForTransition("saved") { _ in true }
        #expect(harness.transitions.all.first?.to == .saved)
        try await harness.expectConverged()
        // The collector drains the event stream on its own task: wait until it has the tail's
        // closing progress before reading what came before it.
        let done = CatchUpProgress(phase: .changes, completed: 15, total: 15)
        try await harness.waitForEvent("the tail's progress") { if case .catchUp(done) = $0 { true } else { false } }
        let events = harness.events.all
        #expect(events.contains { if case .stateReplaced(45) = $0 { true } else { false } })
        let progress = events.compactMap { if case .catchUp(let progress) = $0 { progress } else { nil } }
        #expect(progress.contains { $0.phase == .snapshot && $0.fraction == 1 })
        #expect(progress.last == done)
        try await harness.stop()
    }

    @Test func aSnapshotAtTheHeadNeedsNoTail() async throws {
        let server = try await server(count: 6, snapshot: 6)
        let harness = try await Harness(server: server)
        await harness.client.start()
        try await harness.expectConverged()
        #expect(await server.fetchChangesCalls.isEmpty)
        try await harness.stop()
    }

    @Test func aDocumentWithLocalStateReplaysTheTail() async throws {
        let server = try await server(count: 10, snapshot: nil)
        let harness = try await Harness(server: server)
        await harness.client.start()
        try await harness.waitFor(.saved)
        await harness.client.stop()
        for seq in 11...30 {
            try await server.inject(remoteChange(seq: UInt64(seq)))
        }
        await server.takeSnapshot(through: 25)
        try await harness.edit(3)
        await harness.client.start()
        try await harness.expectConverged()
        #expect(await server.fetchSnapshotCalls == 0)
        #expect(await server.fetchChangesCalls.contains { $0.after == 10 && $0.until == 30 })
        try await harness.stop()
    }

    @Test func compactedHistoryFallsBackToTheSnapshotAndKeepsTheOutbox() async throws {
        let server = try await server(count: 10, snapshot: nil)
        let harness = try await Harness(server: server)
        await harness.client.start()
        try await harness.edit(2)
        try await harness.expectConverged()
        await harness.client.stop()
        // Offline: local work, while the others go on and the server compacts.
        try await harness.edit(4, from: 10)
        for seq in 11...40 {
            try await server.inject(remoteChange(seq: UInt64(seq)))
        }
        await server.takeSnapshot(through: 35)
        await server.update { $0.compactedBelow = 35 }
        await harness.client.start()
        try await harness.expectConverged()
        #expect(await server.fetchSnapshotCalls == 1)
        #expect(await server.acceptedSeqs(42) == [1, 2, 3, 4, 5, 6])
        try await harness.stop()
    }

    @Test func acceptedChangesTheSnapshotHoldsAreAcknowledged() async throws {
        let server = FakeSyncServer()
        let harness = try await Harness(server: server, options: steadyOptions())
        try await harness.edit(3)
        // The pushes got in, but the client never heard: the snapshot now holds them.
        for seq in 1...3 {
            var change = try await harness.store.outbox()[seq - 1]
            change.seq = UInt64(seq)
            _ = try await server.accept(change)
        }
        await server.takeSnapshot()
        try await server.inject(remoteChange(seq: 1))
        await harness.client.start()
        try await harness.expectConverged()
        #expect(await server.pushes.isEmpty)
        try await harness.stop()
    }

    @Test func anUnreadableSnapshotTwiceIsAnError() async throws {
        let server = try await server(count: 8, snapshot: 4)
        await server.update { $0.compactedBelow = 0 }
        let harness = try await Harness(server: server)
        // The server lists a snapshot in Welcome but sends frames that do not make one.
        await server.setSnapshotFrames([], seq: 4)
        await harness.client.start()
        try await eventually("an unreadable snapshot twice is an error") {
            if case .error = await harness.client.state { true } else { false }
        }
        #expect(await server.fetchSnapshotCalls == 2)
        try await harness.stop()
    }

    @Test func snapshotUnavailableIsReplayedFromTheLog() async throws {
        let server = try await server(count: 8, snapshot: nil)
        let transport = NoSnapshotTransport(inner: FakeTransport(server: server), head: 8)
        let harness = try await Harness(server: server, transport: { _ in transport })
        await harness.client.start()
        try await harness.expectConverged()
        #expect(await server.fetchChangesCalls.first?.after == 0)
        try await harness.stop()
    }

    @Test func aShortFetchIsAViolationAndTheSessionRetries() async throws {
        let server = try await server(count: 8, snapshot: nil)
        let transport = ShortFetchTransport(inner: FakeTransport(server: server))
        let harness = try await Harness(server: server, transport: { _ in transport })
        await harness.client.start()
        try await eventually("violation") { harness.transitions.all.contains { $0.cause.contains("FetchChanges") } }
        try await harness.stop()
    }

    @Test func stoppingCancelsACatchUpInProgress() async throws {
        let server = try await server(count: 30, snapshot: 20)
        let transport = SlowTransport(inner: FakeTransport(server: server))
        let harness = try await Harness(server: server, transport: { _ in transport })
        await harness.client.start()
        try await eventually("snapshot requested") { await server.fetchSnapshotCalls == 1 }
        await harness.client.stop()
        #expect(await harness.store.lastServerSeq < 30)
        try await harness.store.close()
    }

    @Test func snapshotDownloadReadsTheContentSizeFromTheZstdFrame() throws {
        var state = EngineState()
        state.apply(remoteChange(seq: 1), serverSeq: 1)
        var frames = SnapshotTransfer.frames(state, serverSeq: 1)
        guard case .header(var header)? = frames[0].frame else { Issue.record("no header"); return }
        header.uncompressedSize = 0
        frames[0] = .with { $0.header = header }
        let decoded = try SnapshotDownload.state(frames, schema: .generated)
        #expect(decoded.serverSeq == 1 && decoded.state.stateHash == state.stateHash)
        #expect(throws: SnapshotDownload.Failure.self) { try SnapshotDownload.state([], schema: .generated) }
        var bad = frames
        bad[1] = .with { $0.chunk = Data([1, 2, 3, 4, 5, 6, 7]) }
        #expect(throws: SnapshotDownload.Failure.self) { try SnapshotDownload.state(bad, schema: .generated) }
        // Frame headers (RFC 8878): magic, descriptor, [window], [dictionary id], content size.
        let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        #expect(SnapshotDownload.contentSize(magic + [0x20, 42]) == 42)                     // single segment, 1 byte
        #expect(SnapshotDownload.contentSize(magic + [0x60, 0x01, 0x00]) == 257)            // 2 bytes, + 256
        #expect(SnapshotDownload.contentSize(magic + [0x80, 0x00, 0x10, 0, 0, 0]) == 16)    // window, 4 bytes
        #expect(SnapshotDownload.contentSize(magic + [0xC1, 0x00, 7, 1, 0, 0, 0, 0, 0, 0, 0]) == 1)  // window, dict, 8
        #expect(SnapshotDownload.contentSize(magic + [0x00, 0x00]) == nil)                  // no content size
        #expect(SnapshotDownload.contentSize(magic + [0x80, 0x00]) == nil)                  // truncated
        #expect(SnapshotDownload.contentSize([0, 0, 0, 0, 0, 0]) == nil)                    // not zstd
    }
}

/// FetchSnapshot answers HISTORY_UNAVAILABLE; Welcome still hints.
struct NoSnapshotTransport: SyncTransport {
    let inner: FakeTransport
    let head: UInt64

    func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error> {
        let frames = inner.subscribe(request, token: token)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await var frame in frames {
                        if case .welcome = frame.frame { frame.welcome.snapshotHint = true }
                        if case .change = frame.frame { continue }
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeResponse { try await inner.pushChange(request, token: token) }
    func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeBatchResponse { try await inner.pushChangeBatch(request, token: token) }
    func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) async throws -> Wiretuner_Sync_V1_PushChangesResponse { try await inner.pushChanges(frames, token: token) }
    func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) async throws { try await inner.updatePresence(request, token: token) }
    func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) async throws -> Wiretuner_Sync_V1_AckResponse { try await inner.ack(request, token: token) }
    func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error> { inner.fetchChanges(request, token: token) }
    func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error> {
        AsyncThrowingStream { $0.finish(throwing: SyncCallError(code: SyncCallError.failedPrecondition, reason: .historyUnavailable)) }
    }
}

/// FetchChanges stops one change short.
struct ShortFetchTransport: SyncTransport {
    let inner: FakeTransport

    func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error> {
        NoSnapshotTransport(inner: inner, head: 0).subscribe(request, token: token)
    }
    func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeResponse { try await inner.pushChange(request, token: token) }
    func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeBatchResponse { try await inner.pushChangeBatch(request, token: token) }
    func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) async throws -> Wiretuner_Sync_V1_PushChangesResponse { try await inner.pushChanges(frames, token: token) }
    func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) async throws { try await inner.updatePresence(request, token: token) }
    func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) async throws -> Wiretuner_Sync_V1_AckResponse { try await inner.ack(request, token: token) }
    func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error> {
        var shorter = request
        shorter.untilServerSeq -= 1
        return inner.fetchChanges(shorter, token: token)
    }
    func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error> {
        AsyncThrowingStream { $0.finish(throwing: SyncCallError(code: SyncCallError.failedPrecondition, reason: .historyUnavailable)) }
    }
}

/// FetchSnapshot that never finishes.
struct SlowTransport: SyncTransport {
    let inner: FakeTransport

    func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error> { inner.subscribe(request, token: token) }
    func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeResponse { try await inner.pushChange(request, token: token) }
    func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeBatchResponse { try await inner.pushChangeBatch(request, token: token) }
    func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) async throws -> Wiretuner_Sync_V1_PushChangesResponse { try await inner.pushChanges(frames, token: token) }
    func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) async throws { try await inner.updatePresence(request, token: token) }
    func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) async throws -> Wiretuner_Sync_V1_AckResponse { try await inner.ack(request, token: token) }
    func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error> { inner.fetchChanges(request, token: token) }
    func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error> {
        let frames = inner.fetchSnapshot(request, token: token)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for try await frame in frames {
                    continuation.yield(frame)
                    try await Task.sleep(for: .seconds(60))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
