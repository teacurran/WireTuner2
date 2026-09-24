import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// COLLAB-021's WTSync half: the state at a version's seq, from the local log or the server.
@Suite(.timeLimit(.minutes(2))) struct VersionStateTests {
    static func replay(_ changes: [Wiretuner_Doc_V1_Change]) -> [UInt8] {
        var state = EngineState()
        for (index, change) in changes.enumerated() {
            state.apply(change, serverSeq: UInt64(index) + 1)
        }
        return state.stateHash
    }

    /// Serves `FetchChanges` with a gap and no snapshot.
    struct GapTransport: SyncTransport {
        let inner = BulkSink()

        func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error> {
            inner.subscribe(request, token: token)
        }
        func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeResponse {
            try await inner.pushChange(request, token: token)
        }
        func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) async throws
            -> Wiretuner_Sync_V1_PushChangeBatchResponse { try await inner.pushChangeBatch(request, token: token) }
        func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) async throws -> Wiretuner_Sync_V1_PushChangesResponse {
            try await inner.pushChanges(frames, token: token)
        }
        func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) async throws {
            try await inner.updatePresence(request, token: token)
        }
        func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) async throws -> Wiretuner_Sync_V1_AckResponse {
            try await inner.ack(request, token: token)
        }
        func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.with {
                    $0.changes = [UInt64(1), 3].map { seq in .with { $0.serverSeq = seq; $0.change = remoteChange(seq: seq) } }
                })
                continuation.finish()
            }
        }
        func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error> {
            AsyncThrowingStream { $0.finish(throwing: SyncCallError(code: SyncCallError.failedPrecondition, reason: .historyUnavailable)) }
        }
    }

    @Test func theLocalLogRebuildsSeqsFromItsSnapshotOn() async throws {
        let scratch = Scratch()
        let store = try await LocalStore.open(documentID: "doc", at: scratch.url(), options: options())
        let remote = (1...4).map { remoteChange(seq: UInt64($0)) }
        for (index, change) in remote.enumerated() {
            try await store.receive(change, serverSeq: UInt64(index) + 1)
        }
        #expect(try await store.state(atServerSeq: 2)?.stateHash == Self.replay(Array(remote.prefix(2))))
        #expect(try await store.state(atServerSeq: 5) == nil)
        try await store.rewriteSnapshot()
        #expect(try await store.state(atServerSeq: 3) == nil)
        #expect(try await store.state(atServerSeq: 4)?.stateHash == Self.replay(remote))
        // A local change the snapshot holds but the server has not sequenced cannot be taken out.
        _ = try await store.perform(createLayer("mine"), recording: Fixture.recording())
        try await store.rewriteSnapshot()
        #expect(try await store.state(atServerSeq: 4) == nil)
        // Through the entry point: offline, a seq the log cannot rebuild throws.
        await #expect(throws: VersionStates.Failure.incomplete(through: 0)) {
            try await VersionStates.state(at: 4, store: store, transport: nil, token: { "t" })
        }
        try await store.close()
        await #expect(throws: LocalStore.Failure.closed) { try await store.state(atServerSeq: 1) }
    }

    @Test func theServerAnswersFromTheNewestSnapshotAtOrBeforeTheSeq() async throws {
        let server = FakeSyncServer()
        let remote = (1...6).map { remoteChange(seq: UInt64($0)) }
        for change in remote {
            _ = try await server.inject(change)
        }
        let transport = FakeTransport(server: server)
        // No snapshot: the log from the start.
        #expect(try await VersionStates.fetch(server.documentID, at: 4, transport: transport, token: "token-1").stateHash
                == Self.replay(Array(remote.prefix(4))))
        await server.takeSnapshot(through: 3)
        #expect(try await VersionStates.fetch(server.documentID, at: 5, transport: transport, token: "token-1").stateHash
                == Self.replay(Array(remote.prefix(5))))
        #expect(try await VersionStates.fetch(server.documentID, at: 3, transport: transport, token: "token-1").stateHash
                == Self.replay(Array(remote.prefix(3))))
        // A snapshot after the seq is not used.
        await server.takeSnapshot(through: 6)
        #expect(try await VersionStates.fetch(server.documentID, at: 2, transport: transport, token: "token-1").stateHash
                == Self.replay(Array(remote.prefix(2))))
        await #expect(throws: VersionStates.Failure.incomplete(through: 6)) {
            try await VersionStates.fetch(server.documentID, at: 9, transport: transport, token: "token-1")
        }
        await #expect(throws: VersionStates.Failure.gap(expected: 2, got: 3)) {
            try await VersionStates.fetch(server.documentID, at: 3, transport: GapTransport(), token: "token-1")
        }
        // The entry point goes to the server when the local log cannot rebuild the seq.
        let scratch = Scratch()
        let store = try await LocalStore.open(documentID: server.documentID, at: scratch.url(), options: options())
        #expect(try await VersionStates.state(at: 5, store: store, transport: transport, token: { "token-1" }).stateHash
                == Self.replay(Array(remote.prefix(5))))
        try await store.receive(remote[0], serverSeq: 1)
        #expect(try await VersionStates.state(at: 1, store: store, transport: nil, token: { "t" }).stateHash == Self.replay([remote[0]]))
        try await store.close()
    }
}
