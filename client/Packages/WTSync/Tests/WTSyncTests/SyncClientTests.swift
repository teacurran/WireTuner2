import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// SYNC-003: the subscription, remote apply in order with own-echo reconciliation, pipelined and
/// batched pushes with SEQ_GAP drain-and-resend, acks, presence, heartbeat and reconnect, tokens,
/// rejections, and the published sync state.
@Suite(.timeLimit(.minutes(2))) struct SyncClientTests {
    @Test func subscribesAppliesRemoteChangesInOrderAndAcks() async throws {
        let server = FakeSyncServer()
        for seq in 1...5 {
            try await server.inject(remoteChange(seq: UInt64(seq)))
        }
        let harness = try await Harness(server: server)
        let states = Collector(await harness.client.states())
        await harness.client.start()
        await harness.client.start()   // idempotent
        try await eventually("replayed") { await harness.store.lastServerSeq == 5 }
        try await harness.waitFor(.saved)
        for seq in 6...8 {
            try await server.inject(remoteChange(seq: UInt64(seq)))
        }
        try await eventually("live changes applied") { await harness.store.lastServerSeq == 8 }
        try await eventually("acked") { await server.acks.last == 8 }
        let request = await server.subscribes[0]
        #expect(request.afterServerSeq == 0 && request.replica == 42 && request.documentID == "D1")
        try await harness.expectConverged()
        #expect(states.all.first == .opening)
        try await harness.waitForTransition("transition") { $0.from == .opening && $0.to == .saved && $0.cause == "session up" }
        try await harness.waitForEvent("event") { if case .stable(8) = $0 { true } else { false } }
        try await harness.waitForEvent("event") { if case .presence = $0 { true } else { false } }
        try await harness.stop()
        #expect(await harness.client.state == .offline(0))
    }

    @Test func pipelinesTheOutboxAndReconcilesOwnEchoes() async throws {
        let harness = try await Harness()
        await harness.client.start()
        try await harness.waitFor(.saved)
        try await harness.edit(80)
        try await harness.expectConverged()
        try await harness.waitFor(.saved)
        // The fake server takes concurrent calls in any order, so some pushes may be resent after
        // SEQ_GAP; every change is still in the log once.
        #expect(await harness.server.pushes.count >= 80)
        try await harness.waitForTransition("transition") { if case .syncing = $0.to { true } else { false } }
        // Resubscribing after a reconnect starts from the applied sequence.
        await harness.server.disconnect()
        try await eventually("resubscribed") { await harness.server.subscribes.count == 2 }
        #expect(await harness.server.subscribes[1].afterServerSeq == 80)
        try await harness.waitFor(.saved)
        try await harness.waitForTransition("transition") { $0.to == .offline(0) }
        try await harness.stop()
    }

    @Test func reorderedPushesDrainAndResendFromTheAckedSeq() async throws {
        let server = FakeSyncServer()
        await server.update { $0.delay = [3: .milliseconds(80), 9: .milliseconds(60)] }
        let harness = try await Harness(server: server)
        try await harness.edit(40)
        await harness.client.start()
        try await harness.expectConverged()
        #expect(await server.gaps > 0)
        #expect(!harness.events.all.contains { if case .replicaRotated = $0 { true } else { false } })
        try await harness.stop()
    }

    @Test func inFlightPushesAcrossADropResolveFromWelcome() async throws {
        let server = FakeSyncServer()
        // Seq 5 gets in but its response is lost, which ends the session; seq 8 is still on its
        // way then, so 9...12 arrive before it (SEQ_GAP).
        await server.update {
            $0.loseResponse = [5]
            $0.delay = [8: .milliseconds(300)]
        }
        let harness = try await Harness(server: server)
        try await harness.edit(12)
        await harness.client.start()
        try await eventually("resubscribed") { await server.welcomes.count >= 2 }
        try await harness.expectConverged()
        let welcomes = await server.welcomes
        let resumed = welcomes[1]
        #expect(resumed >= 5)
        // Nothing Welcome said got in was sent again, and no accepted change was sent twice.
        let later = await server.pushes.filter { $0.session >= 2 }.map(\.seq)
        #expect(!later.isEmpty && later.allSatisfy { $0 > resumed })
        #expect(await server.duplicates == 0)
        try await harness.stop()
    }

    @Test func gatewayModeSendsOneBatchAtATimeAndResumesAfterThePrefix() async throws {
        let server = FakeSyncServer()
        await server.update { $0.reject = [40: SyncCallError(code: SyncCallError.aborted, reason: .seqGap, message: "gap")] }
        let harness = try await Harness(server: server, options: fastOptions(gateway: true))
        try await harness.edit(70)
        await harness.client.start()
        try await harness.expectConverged()
        let batches = await server.batches
        #expect(batches.allSatisfy { $0.count <= 32 })
        #expect(batches.first == Array(1...32))
        #expect(batches.contains { $0.first == 40 })
        #expect(await server.pushes.isEmpty)
        #expect(await server.bulkFrames.isEmpty)
        try await harness.stop()
    }

    @Test func gapsAndDuplicatesOnTheStreamAreRepaired() async throws {
        let server = FakeSyncServer()
        await server.update { $0.dropLive = [3, 4]; $0.duplicateLive = true }
        let harness = try await Harness(server: server)
        await harness.client.start()
        try await harness.waitFor(.saved)
        for seq in 1...6 {
            try await server.inject(remoteChange(seq: UInt64(seq)))
        }
        try await eventually("gap filled") { await harness.store.lastServerSeq == 6 }
        #expect(await server.fetchChangesCalls.contains { $0.after == 2 && $0.until == 4 })
        try await harness.expectConverged()
        try await harness.stop()
    }

    @Test func silenceEndsTheSessionAfterTheHeartbeatTimeout() async throws {
        let server = FakeSyncServer()
        await server.update { $0.silentAfterWelcome = true }
        var options = fastOptions()
        options.heartbeatTimeout = .milliseconds(150)
        let harness = try await Harness(server: server, options: options)
        await harness.client.start()
        try await eventually("resubscribed after silence") { await server.subscribes.count >= 2 }
        try await harness.waitForTransition("transition") { $0.cause == "heartbeat timeout" }
        try await harness.stop()
    }

    @Test func pongsKeepTheSessionAndReconnectEventsEndIt() async throws {
        let server = FakeSyncServer()
        let harness = try await Harness(server: server)
        await harness.client.start()
        try await harness.waitFor(.saved)
        await server.send(.with { $0.pong = .with { $0.serverTimeMs = 1 } })
        await server.send(.with { $0.event = .with { $0.renamed = .with { $0.name = "Poster" } } })
        try await eventually("renamed event") {
            harness.events.all.contains { if case .document(let event) = $0 { event.renamed.name == "Poster" } else { false } }
        }
        await server.send(.with { $0.event = .with { $0.reconnect = Wiretuner_Sync_V1_Reconnect() } })
        try await eventually("resubscribed") { await server.subscribes.count == 2 }
        try await harness.waitForTransition("transition") { $0.cause == "server asked to reconnect" }
        try await harness.waitFor(.saved)
        await server.endStreams()
        try await eventually("resubscribed after the stream ended") { await server.subscribes.count == 3 }
        try await harness.stop()
    }

    @Test func aChangeBeforeWelcomeIsAProtocolViolation() async throws {
        let transport = ScriptedTransport(frames: [.with { $0.change = .with { $0.serverSeq = 1 } }])
        let harness = try await Harness(transport: { _ in transport })
        await harness.client.start()
        try await eventually("violation") {
            harness.transitions.all.contains { $0.cause.hasPrefix("protocol violation") }
        }
        try await harness.stop()
    }

    @Test func expiredTokensAreRefreshed() async throws {
        let server = FakeSyncServer()
        await server.update { $0.validToken = "token-2" }
        let harness = try await Harness(server: server)
        await harness.client.start()
        try await harness.waitFor(.saved)
        #expect(harness.tokens.refreshes == 1)
        // The token expires mid-session: the push is refused, refreshed, resent.
        await server.update { $0.validToken = "token-3" }
        try await harness.edit(3)
        try await harness.expectConverged()
        #expect(harness.tokens.refreshes >= 2)
        try await harness.stop()
    }

    @Test func aFailedRefreshAsksForSignInUntilSignedIn() async throws {
        let server = FakeSyncServer()
        let tokens = FakeTokens()
        tokens.fail(with: TokenFailure.signInRequired)
        let harness = try await Harness(server: server, tokens: tokens)
        await harness.client.start()
        try await harness.waitFor(.needsSignIn)
        tokens.fail(with: nil)
        await harness.client.signedIn()
        try await harness.waitFor(.saved)
        // A transient token failure is just a failed session.
        tokens.fail(with: URLError(.notConnectedToInternet))
        await server.update { $0.validToken = "token-2" }
        await server.disconnect()
        try await eventually("offline") { if case .offline = await harness.client.state { true } else { false } }
        tokens.fail(with: nil)
        try await harness.waitFor(.saved)
        try await harness.stop()
    }

    @Test func replicaConflictRotatesAndARepeatedOneIsAnError() async throws {
        let server = FakeSyncServer()
        let conflict = SyncCallError(code: SyncCallError.failedPrecondition, reason: .replicaConflict, message: "restored copy")
        await server.update { $0.reject = [1: conflict] }
        let harness = try await Harness(server: server)
        try await harness.edit(2)
        await harness.client.start()
        try await eventually("rotated") {
            harness.events.all.contains { if case .replicaRotated(42, 43) = $0 { true } else { false } }
        }
        try await eventually("resubscribed as the new replica") { await server.subscribes.last?.replica == 43 }
        // The unsent changes were salvaged: re-issued by the new replica on the server's state.
        try await harness.waitForEvent("salvaged") { if case .salvaged(let report) = $0 { report.recoveredChanges == 2 } else { false } }
        #expect(try await harness.store.retiredOutbox().isEmpty)
        try await harness.expectConverged()
        #expect(await server.acceptedSeqs(43) == [1, 2])
        #expect(await server.acceptedSeqs(42).isEmpty)
        try await harness.stop()
        // A refusal for the new replica before anything of it was accepted is an error.
        await server.update { $0.retired = [60, 61] }
        let rotated = try await Harness(server: server, name: "second", replicas: Replicas(from: 60))
        try await rotated.edit(1, from: 10)
        await rotated.client.start()
        try await eventually("error") { if case .error = await rotated.client.state { true } else { false } }
        await server.update { $0.retired = [] }
        await rotated.client.retry()
        // Expiry salvage waits for the review before sending.
        try await rotated.waitFor(.needsReview)
        try await rotated.client.resolveReview(.upload)
        try await rotated.expectConverged()
        try await rotated.stop()
    }

    @Test func subscribeRefusalsAreClassified() async throws {
        let server = FakeSyncServer()
        await server.update { $0.subscribeFailures = [
            SyncCallError(code: SyncCallError.failedPrecondition, reason: .replicaExpired, message: "retired"),
            SyncCallError(code: SyncCallError.unavailable, message: "down"),
        ] }
        let harness = try await Harness(server: server)
        await harness.client.start()
        try await harness.waitFor(.saved)
        #expect(await server.subscribes.map(\.replica) == [42, 43, 43])
        try await harness.waitForTransition("transition") { $0.from == .opening && $0.to == .offline(0) }

        await server.update { $0.subscribeFailures = [SyncCallError(code: SyncCallError.permissionDenied, message: "no access")] }
        await server.disconnect()
        try await harness.waitFor(.readOnly(.accessRemoved))
        await harness.client.retry()
        try await harness.waitFor(.saved)

        await server.update { $0.subscribeFailures = [SyncCallError(code: SyncCallError.notFound, message: "gone")] }
        await server.disconnect()
        try await harness.waitFor(.error("The document no longer exists."))
        await harness.client.retry()
        try await harness.waitFor(.saved)

        await server.update { $0.subscribeFailures = [SyncCallError(code: SyncCallError.permissionDenied, reason: .roleInsufficient, message: "viewer")] }
        await server.disconnect()
        try await harness.waitFor(.readOnly(.roleInsufficient))
        await harness.client.retry()
        await server.send(.with { $0.event = .with { $0.roleChanged = .with { $0.role = .owner } } })
        await server.disconnect()
        try await harness.waitFor(.saved)

        await server.update { $0.subscribeFailures = [SyncCallError(code: SyncCallError.permissionDenied, reason: .clientTooOld, message: "old")] }
        await server.disconnect()
        try await harness.waitFor(.readOnly(.clientTooOld))
        try await harness.stop()
    }

    @Test func unauthenticatedSubscribeRefreshesTheToken() async throws {
        let server = FakeSyncServer()
        await server.update { $0.subscribeFailures = [SyncCallError(code: SyncCallError.unauthenticated, message: "revoked")] }
        let tokens = FakeTokens(["token-1", "token-1"])
        let harness = try await Harness(server: server, tokens: tokens)
        await harness.client.start()
        try await harness.waitFor(.saved)
        #expect(tokens.refreshes == 1)
        tokens.fail(with: TokenFailure.signInRequired)
        await server.update { $0.subscribeFailures = [SyncCallError(code: SyncCallError.unauthenticated, message: "revoked")] }
        await server.disconnect()
        try await harness.waitFor(.needsSignIn)
        try await harness.stop()
    }

    @Test func rolesDecideWhetherTheOutboxGoesUp() async throws {
        let server = FakeSyncServer()
        await server.update { $0.role = .viewer }
        let harness = try await Harness(server: server)
        try await harness.edit(2)
        await harness.client.start()
        try await harness.waitFor(.readOnly(.role))
        #expect(await server.pushes.isEmpty)
        await server.update { $0.role = .editor }
        await server.send(.with { $0.event = .with { $0.roleChanged = .with { $0.role = .editor } } })
        try await harness.expectConverged()
        try await harness.waitFor(.saved)
        // Downgraded while offline: the push is refused and the document turns read-only.
        await server.update { $0.role = .commenter }
        try await harness.edit(1, from: 5)
        try await harness.waitFor(.readOnly(.roleInsufficient))
        #expect(try await harness.store.outboxCount() == 1)
        await server.send(.with { $0.event = .with { $0.accessRemoved = Wiretuner_Sync_V1_AccessRemoved() } })
        try await harness.waitFor(.readOnly(.accessRemoved))
        try await harness.stop()
    }

    @Test func aNewerFeatureLevelOrMergeTableIsReported() async throws {
        let server = FakeSyncServer()
        await server.update {
            $0.featureLevel = 2
            $0.mergeTable = Data(#"{"version":"abc","messages":{}}"#.utf8)
        }
        let harness = try await Harness(server: server)
        await harness.client.start()
        try await harness.waitFor(.readOnly(.clientTooOld))
        try await eventually("reported") {
            harness.events.all.contains { if case .mergeTableDiffers("abc") = $0 { true } else { false } }
        }
        #expect(SyncClient.tableVersion(Data("not json".utf8)) == nil)
        try await harness.stop()
    }

    @Test func pushRefusalsOfEveryKind() async throws {
        let server = FakeSyncServer()
        await server.update { $0.reject = [
            1: SyncCallError(code: SyncCallError.resourceExhausted, reason: .rateLimited, message: "slow down", retryAfter: .milliseconds(20)),
            2: SyncCallError(code: SyncCallError.invalidArgument, reason: .validationFailed, message: "bad op"),
            3: SyncCallError(code: SyncCallError.unauthenticated, message: "expired"),
            4: SyncCallError(code: SyncCallError.unauthenticated, reason: .tokenExpired, message: "expired"),
        ] }
        let harness = try await Harness(server: server, tokens: FakeTokens(["token-1", "token-1"]))
        try await harness.edit(5)
        await harness.client.start()
        try await eventually("all accepted") { await server.acceptedSeqs(42) == [1, 2, 3, 4, 5] }
        try await harness.waitForEvent("event") { if case .changeDropped(2, "bad op") = $0 { true } else { false } }
        let dropped = await server.log.first { $0.change.seq == 2 }!.change
        #expect(dropped.ops.allSatisfy { if case .noop = $0.op { true } else { false } })
        try await eventually("acked") { try await harness.store.outboxCount() == 0 }
        try await harness.stop()
    }

    @Test func clientTooOldOnPushAndUnknownRefusalsEndTheSession() async throws {
        let server = FakeSyncServer()
        await server.update { $0.reject = [1: SyncCallError(code: 13, message: "internal")] }
        let harness = try await Harness(server: server)
        try await harness.edit(1)
        await harness.client.start()
        try await harness.expectConverged()
        #expect(await server.subscribes.count >= 2)
        await server.update { $0.reject = [2: SyncCallError(code: SyncCallError.failedPrecondition, reason: .clientTooOld, message: "old")] }
        try await harness.edit(1, from: 1)
        try await harness.waitFor(.readOnly(.clientTooOld))
        try await harness.stop()
    }

    @Test func presenceGoesUpAtMostTwentyTimesASecondAndGoneOnStop() async throws {
        let server = FakeSyncServer()
        let presence = FakePresence()
        presence.move(tool: "pen")
        let harness = try await Harness(server: server, presence: presence)
        await harness.client.start()
        try await harness.waitFor(.saved)
        #expect(await server.subscribes[0].presence.tool == "pen")
        presence.move(tool: "rectangle")
        try await eventually("presence sent") { await server.presences.contains { $0.tool == "rectangle" } }
        // Unchanged presence is re-sent only as a keep-alive.
        let count = await server.presences.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.presences.count <= count + 1)
        try await eventually("keep-alive") { await server.presences.count > count }
        await server.send(.with { $0.presenceUpdate = .with { $0.tool = "zoom" } })
        try await eventually("presence frame") {
            harness.events.all.contains { if case .presenceUpdate(let update) = $0 { update.tool == "zoom" } else { false } }
        }
        await server.update { $0.presenceFailure = SyncCallError(code: SyncCallError.unavailable, message: "busy") }
        presence.move(tool: "type")
        try await Task.sleep(for: .milliseconds(50))
        await server.update { $0.presenceFailure = SyncCallError(code: SyncCallError.unauthenticated, message: "expired") }
        await server.update { $0.validToken = "token-2" }
        presence.move(tool: "brush")
        try await eventually("refreshed for presence") { harness.tokens.refreshes >= 1 }
        await server.update { $0.presenceFailure = nil }
        try await server.inject(remoteChange(seq: 1))
        try await eventually("applied") { await harness.store.lastServerSeq == 1 }
        await harness.client.stop()
        #expect(await server.presences.last?.state == .gone)
        #expect(await server.acks.last == 1)
        try await harness.store.close()
    }

    @Test func ackFailuresAreRetriedAndRefreshTheToken() async throws {
        let server = FakeSyncServer()
        await server.update { $0.ackFailure = SyncCallError(code: SyncCallError.unavailable, message: "busy") }
        let harness = try await Harness(server: server)
        await harness.client.start()
        try await harness.waitFor(.saved)
        try await server.inject(remoteChange(seq: 1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.acks.isEmpty)
        await server.update { $0.ackFailure = SyncCallError(code: SyncCallError.unauthenticated, message: "expired") }
        await server.update { $0.validToken = "token-2" }
        try await eventually("refreshed") { harness.tokens.refreshes >= 1 }
        await server.update { $0.ackFailure = nil }
        try await eventually("acked") { await server.acks.last == 1 }
        try await harness.stop()
    }

    @Test func blobsWaitingShowAsUploadingBlobs() async throws {
        let harness = try await Harness()
        try await harness.store.addPendingBlob(.init(hash: "a", path: "/tmp/a", size: 10))
        try await harness.store.addPendingBlob(.init(hash: "t", path: "/tmp/t", tag: LocalStore.thumbnailTag, size: 1))
        await harness.client.start()
        try await harness.waitFor(.uploadingBlobs(1))
        try await harness.store.removePendingBlob(hash: "a")
        await harness.client.localChangesAvailable()
        try await harness.waitFor(.saved)
        try await harness.stop()
    }

    @Test func aDocumentFacadeReceivesRemoteChangesAndTheHorizon() async throws {
        let server = FakeSyncServer()
        await server.update { $0.collectionPoint = (1, 1_234) }
        let harness = try await Harness(server: server, sink: { store in await Document(backend: store) })
        await harness.client.start()
        try await server.inject(remoteChange(seq: 1))
        try await harness.edit(1)
        try await harness.expectConverged()
        try await eventually("horizon") { await harness.store.horizon == 2 }
        try await harness.waitForEvent("collection point") { if case .collectionPoint(1, 1_234) = $0 { true } else { false } }
        try await harness.stop()
    }

    @Test func collectionPointsAreReadFromTheAckResponse() {
        #expect(CollectionPoint(Wiretuner_Sync_V1_AckResponse.with { $0.stableSeq = 5 }) == nil)
        #expect(CollectionPoint(Wiretuner_Sync_V1_AckResponse.with { $0.collectSeq = 7 })?.timeMs == 0)
        #expect(CollectionPoint(Wiretuner_Sync_V1_AckResponse.with {
            $0.collectSeq = 150
            $0.collectTimeMs = 2
        }) == CollectionPoint(seq: 150, timeMs: 2))
    }

    @Test func aClosedStoreCountsNothingAndAnAbsentPresenceSendsNothing() async throws {
        let server = FakeSyncServer()
        let harness = try await Harness(server: server, presence: FakePresence())
        try await harness.store.close()
        await harness.client.start()
        try await harness.waitFor(.saved)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await server.presences.isEmpty)
        await harness.client.stop()
    }

    @Test func rateLimitsWithoutADelayWaitASecond() async throws {
        let server = FakeSyncServer()
        await server.update { $0.reject = [1: SyncCallError(code: SyncCallError.resourceExhausted, reason: .rateLimited, message: "slow")] }
        let harness = try await Harness(server: server)
        try await harness.edit(1)
        let start = ContinuousClock.now
        await harness.client.start()
        try await harness.expectConverged()
        #expect(ContinuousClock.now - start >= .seconds(1))
        try await harness.stop()
    }

    @Test func stoppingBeforeStartingAndBackoffBounds() async throws {
        let harness = try await Harness()
        await harness.client.stop()
        #expect(await harness.client.state == .opening)
        var options = SyncClient.Options()
        options.random = { 0.999 }
        let client = SyncClient(store: harness.store, transport: FakeTransport(server: harness.server), tokens: FakeTokens(), options: options)
        #expect(await client.backoff(0) < .milliseconds(500))
        #expect(await client.backoff(0) > .milliseconds(490))
        #expect(await client.backoff(40) <= .seconds(30))
        try await harness.store.close()
    }
}

/// A transport that plays fixed frames on Subscribe and refuses everything else.
struct ScriptedTransport: SyncTransport {
    let frames: [Wiretuner_Sync_V1_ServerFrame]

    func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error> {
        AsyncThrowingStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }

    static let refused = SyncCallError(code: SyncCallError.unavailable, message: "scripted")

    func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeResponse { throw Self.refused }
    func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) async throws -> Wiretuner_Sync_V1_PushChangeBatchResponse { throw Self.refused }
    func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) async throws -> Wiretuner_Sync_V1_PushChangesResponse { throw Self.refused }
    func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) async throws { throw Self.refused }
    func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) async throws -> Wiretuner_Sync_V1_AckResponse { throw Self.refused }
    func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error> {
        AsyncThrowingStream { $0.finish(throwing: Self.refused) }
    }
    func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String) -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error> {
        AsyncThrowingStream { $0.finish(throwing: Self.refused) }
    }
}

