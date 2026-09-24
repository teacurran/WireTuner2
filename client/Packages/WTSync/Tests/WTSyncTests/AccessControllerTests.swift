import Foundation
import Synchronization
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// A `DocumentCopyTransport` recording its calls; `failures` are thrown first, in order.
final class FakeCopies: DocumentCopyTransport {
    let forks = Mutex<[Wiretuner_Docs_V1_ForkRequest]>([])
    let branches = Mutex<[Wiretuner_Docs_V1_CreateBranchRequest]>([])
    let failures = Mutex<[any Error]>([])

    func fork(_ request: Wiretuner_Docs_V1_ForkRequest, token: String) async throws -> Wiretuner_Docs_V1_ForkResponse {
        if let failure = failures.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { throw failure }
        forks.withLock { $0.append(request) }
        return .with { $0.document.id = request.newDocumentID }
    }

    func createBranch(_ request: Wiretuner_Docs_V1_CreateBranchRequest, token: String) async throws -> Wiretuner_Docs_V1_CreateBranchResponse {
        if let failure = failures.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { throw failure }
        branches.withLock { $0.append(request) }
        return .with { $0.branch.branchDocumentID = request.branchDocumentID }
    }
}

/// A `SyncTransport` that only takes bulk uploads (a copy's remaining changes), accepting through
/// `acceptThrough` (nil: everything).
final class BulkSink: SyncTransport {
    let frames = Mutex<[Wiretuner_Sync_V1_PushChangesRequest]>([])
    let acceptThrough: UInt64?

    init(acceptThrough: UInt64? = nil) {
        self.acceptThrough = acceptThrough
    }

    struct Unused: Error {}

    func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error> {
        AsyncThrowingStream { $0.finish(throwing: Unused()) }
    }
    func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeResponse { throw Unused() }
    func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) async throws
        -> Wiretuner_Sync_V1_PushChangeBatchResponse { throw Unused() }
    func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) async throws -> Wiretuner_Sync_V1_PushChangesResponse {
        self.frames.withLock { $0 += frames }
        let last = frames.flatMap(\.changes).last?.seq ?? 0
        return .with { $0.lastAcceptedSeq = acceptThrough ?? last }
    }
    func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) async throws { throw Unused() }
    func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) async throws -> Wiretuner_Sync_V1_AckResponse { throw Unused() }
    func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error> {
        AsyncThrowingStream { $0.finish(throwing: Unused()) }
    }
    func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error> {
        AsyncThrowingStream { $0.finish(throwing: Unused()) }
    }
}

/// COLLAB-014: role changes during a session (sharing.adoc, "When your access changes mid-session").
@Suite(.timeLimit(.minutes(2))) struct AccessControllerTests {
    struct Setup {
        let harness: Harness
        let copies = FakeCopies()
        let bulk: BulkSink
        let controller: AccessController
        let statuses: Collector<AccessController.Status>

        init(bulk: BulkSink = BulkSink()) async throws {
            harness = try await Harness()
            self.bulk = bulk
            controller = AccessController(store: harness.store, client: harness.client, sync: bulk, copies: copies, tokens: harness.tokens)
            statuses = Collector(await controller.statuses())
        }

        func waitForStatus(_ what: String, _ match: @escaping @Sendable (AccessController.Status) -> Bool) async throws {
            try await eventually(what) { match(await controller.status) }
        }
    }

    /// A viewer with unsent changes: the outbox freezes, nothing is sent, and *Save as a Copy*
    /// forks with exactly the unsent changes at the applied head.
    @Test func loweredWithUnsentChangesFreezesAndSavesACopy() async throws {
        let setup = try await Setup()
        let harness = setup.harness
        try await harness.server.inject(remoteChange(seq: 1))
        try await harness.edit(1_003)
        await harness.server.update { $0.role = .viewer }
        await setup.controller.start()
        await harness.client.start()
        try await setup.waitForStatus("frozen") { $0.unsent == 1_003 && !$0.editable }
        let status = await setup.controller.status
        #expect(status.reason == .role && status.banner == "You can no longer edit this document" && !status.isRemoved)
        try await harness.waitFor(.readOnly(.role))
        #expect(await harness.client.readOnlyReason == .role)
        // No local change enters the outbox; the remote log keeps applying.
        await #expect(throws: LocalStore.Failure.readOnly) { try await harness.store.perform(createLayer("no"), recording: Fixture.recording()) }
        await #expect(throws: LocalStore.Failure.readOnly) { try await harness.store.undo(recording: Fixture.recording()) }
        try await harness.server.inject(remoteChange(seq: 2))
        try await eventually("remote applied") { await harness.store.lastServerSeq == 2 }
        #expect(await harness.server.pushes.isEmpty)
        let before = await harness.store.read { $0.stateHash }
        let outbox = try await harness.store.outbox()
        let copy = try await setup.controller.saveAsCopy(name: String(repeating: "n", count: 300), newDocumentID: "copy-1")
        #expect(copy == "copy-1")
        let fork = try #require(setup.copies.forks.withLock { $0.first })
        #expect(fork.sourceDocumentID == harness.server.documentID && fork.atServerSeq == 2 && fork.name.count == 256)
        let rest = setup.bulk.frames.withLock { $0.flatMap(\.changes) }
        #expect(fork.changes + rest == outbox)
        #expect(fork.changes.count == AccessController.forkChanges)
        // The copy holds the local state: the server's state plus the changes, in order.
        var copied = EngineState()
        for entry in await harness.server.log { copied.apply(entry.change, serverSeq: entry.serverSeq) }
        for change in fork.changes + rest { copied.apply(change) }
        #expect(copied.stateHash == before)
        // The document reverts to the server's state and the offer is settled.
        try await eventually("reverted") {
            let outbox = try await harness.store.outboxCount()
            let local = await harness.store.read { $0.stateHash }
            let remote = await harness.server.stateHash()
            return outbox == 0 && local == remote
        }
        #expect(await setup.controller.status.unsent == 0)
        #expect(await harness.server.pushes.isEmpty)
        // Raised again: editable without reopening; a new change uploads and both converge.
        await harness.server.update { $0.role = .editor }
        await harness.server.send(.with { $0.event.roleChanged.role = .editor })
        try await setup.waitForStatus("editable") { $0.editable }
        try await harness.edit(1, from: 5_000)
        try await harness.expectConverged()
        #expect(setup.statuses.all.contains { $0.unsent == 1_003 })
        await setup.controller.stop()
        try await harness.stop()
    }

    /// Raising the role before deciding keeps the frozen changes unsent; *Discard* then drops them
    /// and later edits upload.
    @Test func raisedBeforeDecidingKeepsTheFrozenChangesUntilDiscard() async throws {
        let setup = try await Setup()
        let harness = setup.harness
        try await harness.edit(3)
        await harness.server.update { $0.role = .commenter }
        await setup.controller.start()
        await setup.controller.start()
        await harness.client.start()
        try await setup.waitForStatus("frozen") { $0.unsent == 3 }
        await harness.server.update { $0.role = .editor }
        await harness.server.send(.with { $0.event.roleChanged.role = .editor })
        try await setup.waitForStatus("editable") { $0.editable && $0.unsent == 3 }
        #expect(await setup.controller.status.banner == "Changes you made while you could not edit have not been sent")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.server.pushes.isEmpty)
        try await setup.controller.discard()
        #expect(await setup.controller.status == AccessController.Status())
        #expect(await setup.controller.status.banner == nil)
        try await harness.waitFor(.saved)
        try await harness.edit(2, from: 10)
        try await harness.expectConverged()
        await setup.controller.stop()
        try await harness.stop()
    }

    /// A push refused with `ROLE_INSUFFICIENT` (lowered while offline) freezes like `RoleChanged`.
    @Test func roleInsufficientOnAPushFreezes() async throws {
        let setup = try await Setup()
        let harness = setup.harness
        await setup.controller.start()
        await harness.client.start()
        try await harness.waitFor(.saved)
        await harness.server.update { $0.role = .viewer }
        try await harness.edit(2)
        try await setup.waitForStatus("frozen") { $0.reason == .roleInsufficient && $0.unsent == 2 }
        #expect(await harness.server.log.isEmpty)
        await setup.controller.stop()
        try await harness.stop()
    }

    /// Removed: the bar says so, the offer settles, and the store is deleted.
    @Test func accessRemovedDeletesTheStoreAfterTheOffer() async throws {
        let setup = try await Setup()
        let harness = setup.harness
        await setup.controller.start()
        await harness.client.start()
        try await harness.waitFor(.saved)
        await harness.server.update { $0.role = .viewer }
        await harness.server.send(.with { $0.event.accessRemoved = .init() })
        try await setup.waitForStatus("removed") { $0.isRemoved }
        #expect(await setup.controller.status.banner == "You no longer have access")
        try await setup.controller.discard()
        try await setup.controller.deleteStore()
        #expect(!FileManager.default.fileExists(atPath: harness.store.url.path))
    }

    /// A copy whose remaining changes did not all get in reports how far they did.
    @Test func anIncompleteCopyIsReported() async throws {
        let setup = try await Setup(bulk: BulkSink(acceptThrough: 1_000))
        let harness = setup.harness
        try await harness.edit(1_002)
        await harness.server.update { $0.role = .viewer }
        await setup.controller.start()
        await harness.client.start()
        try await setup.waitForStatus("frozen") { $0.unsent == 1_002 }
        await #expect(throws: AccessController.Failure.copyIncomplete(acceptedThrough: 1_000)) {
            try await setup.controller.saveAsCopy(name: "Mine")
        }
        #expect(await setup.controller.status.unsent == 1_002)
        await setup.controller.stop()
        try await harness.stop()
    }

    /// A client too old to edit is read-only without an offer.
    @Test func aClientTooOldIsReadOnlyWithoutAnOffer() async throws {
        let setup = try await Setup()
        let harness = setup.harness
        try await harness.edit(1)
        await harness.server.update { $0.featureLevel = 9 }
        await setup.controller.start()
        await harness.client.start()
        try await setup.waitForStatus("read-only") { $0.reason == .clientTooOld }
        let status = await setup.controller.status
        #expect(status.unsent == 0 && status.banner == "This document needs a newer version of WireTuner to edit")
        await setup.controller.stop()
        try await harness.stop()
    }
}
