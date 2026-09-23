import Foundation
import Synchronization
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// SYNC-006 and SYNC-010 through the sync client: reconnecting after offline work measures the
/// divergence before anything is pushed, holds the outbox while a review is pending, and salvages
/// a retired replica's unsent changes.
@Suite(.timeLimit(.minutes(2))) struct ReconcileTests {
    /// A second client on a harness's store (the first one stopped: the app relaunched).
    static func client(_ harness: Harness, options: SyncClient.Options = fastOptions()) -> (SyncClient, Collector<SyncEvent>) {
        let client = SyncClient(store: harness.store, transport: FakeTransport(server: harness.server), tokens: FakeTokens(), options: options)
        return (client, Collector(client.events()))
    }

    static func waitFor(_ client: SyncClient, _ state: SyncState) async throws {
        try await eventually("state \(state)") { await client.state == state }
    }

    /// A document with layers N (1:9) and M (2:9) that the harness's client synced, then stopped.
    static func synced() async throws -> Harness {
        let server = FakeSyncServer()
        await server.update { $0.authors = [9: "Priya"] }
        try await server.inject(Fixture.change(9, seq: 1, start: 1, [Fixture.createLayer("N"), Fixture.createLayer("M", position: [0x90])]))
        let harness = try await Harness(server: server)
        await harness.client.start()
        try await harness.expectConverged()
        await harness.client.stop()
        return harness
    }

    static let n = OpID(counter: 1, replica: 9)
    static let m = OpID(counter: 2, replica: 9)

    static func rename(_ harness: Harness, _ node: OpID, _ name: String) async throws {
        _ = try await harness.store.perform(OpsCommand("Rename", ops: [Fixture.rename(node, name)]), recording: Fixture.recording())
    }

    @Test func anOverlapHoldsTheOutboxUntilTheReviewIsSettled() async throws {
        let harness = try await Self.synced()
        let server = harness.server
        try await Self.rename(harness, Self.n, "mine")
        try await server.inject(Fixture.change(9, seq: 2, start: 1_000, [Fixture.rename(Self.n, "theirs")]))
        let (client, events) = Self.client(harness)
        try await client.resolveReview(.upload)   // nothing pending: nothing happens
        await client.start()
        try await Self.waitFor(client, .needsReview)
        let review = try #require(await client.pendingReview)
        #expect(review.mode == .wholeDocument && review.entries.count == 1 && review.entries[0].localWriteLost)
        #expect(review.authors == [ReviewAuthor(replica: 9, name: "Priya", ops: 1)])
        try await eventually("review event") { events.all.contains { if case .reviewNeeded = $0 { true } else { false } } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.acceptedSeqs(42).isEmpty)
        #expect(await harness.store.lastServerSeq == 2)
        // The hold outlives the client: a relaunch shows the review again, even offline.
        await client.stop()
        await server.update { $0.subscribeFailures = Array(repeating: SyncCallError(code: SyncCallError.unavailable), count: 3) }
        let (relaunched, _) = Self.client(harness)
        await relaunched.start()
        try await Self.waitFor(relaunched, .needsReview)
        try await eventually("reconnected") { await server.subscriberCount == 1 }
        try await relaunched.resolveReview(.upload)
        try await harness.expectConverged()
        #expect(await relaunched.pendingReview == nil)
        #expect(await relaunched.lastMerge?.entries.count == 1)
        #expect(try await harness.store.reviewHold() == nil)
        await relaunched.stop()
    }

    @Test func discardingLocalChangesRevertsToTheServersState() async throws {
        let harness = try await Self.synced()
        let server = harness.server
        try await Self.rename(harness, Self.n, "mine")
        try await server.inject(Fixture.change(9, seq: 2, start: 1_000, [Fixture.rename(Self.n, "theirs")]))
        let (client, events) = Self.client(harness)
        await client.start()
        try await Self.waitFor(client, .needsReview)
        try await client.resolveReview(.discardLocalChanges)
        try await Self.waitFor(client, .saved)
        try await eventually("caught up again") { await harness.store.lastServerSeq == 2 }
        #expect(await harness.store.read { $0.stateHash } == (await server.stateHash()))
        #expect(await server.acceptedSeqs(42).isEmpty)
        #expect(await server.acceptedSeqs(43).isEmpty)
        try await eventually("event") { events.all.contains { if case .replicaRotated(42, 43) = $0 { true } else { false } } }
        try await eventually("event") { events.all.contains { if case .stateReplaced(0) = $0 { true } else { false } } }
        await client.stop()
    }

    @Test func aSmallMergeWithoutOverlapIsSilent() async throws {
        let harness = try await Self.synced()
        let server = harness.server
        try await Self.rename(harness, Self.n, "mine")
        try await server.inject(Fixture.change(9, seq: 2, start: 1_000, [Fixture.rename(Self.m, "theirs")]))
        let (client, events) = Self.client(harness)
        await client.start()
        try await harness.expectConverged()
        try await eventually("merged") { events.all.contains { if case .merged = $0 { true } else { false } } }
        let merge = try #require(await client.lastMerge)
        #expect(merge.decision == .silentMerge && merge.toast == "Merged 1 change from Priya")
        #expect(await client.pendingReview == nil)
        await client.stop()
    }

    @Test func aLongGapOffersAReviewWithoutHolding() async throws {
        let harness = try await Self.synced()
        let server = harness.server
        try await Self.rename(harness, Self.n, "mine")
        try await server.inject(Fixture.change(9, seq: 2, start: 1_000, [Fixture.rename(Self.m, "theirs")]))
        var options = fastOptions()
        options.clock = { Date().addingTimeInterval(13 * 3600) }
        let (client, _) = Self.client(harness, options: options)
        await client.start()
        try await harness.expectConverged()
        try await eventually("merged") { await client.lastMerge != nil }
        #expect(await client.lastMerge?.decision == .suggestReview)
        #expect(await client.lastMerge?.mode == .readOnly)
        await client.stop()
    }

    @Test func aSnapshotCatchUpAlwaysOffersAReview() async throws {
        let harness = try await Self.synced()
        let server = harness.server
        try await Self.rename(harness, Self.n, "mine")
        for seq in 2...4 {
            try await server.inject(Fixture.change(9, seq: UInt64(seq), start: 1_000 + UInt64(seq), [Fixture.rename(Self.m, "t\(seq)")]))
        }
        await server.takeSnapshot()
        await server.update { $0.compactedBelow = 4 }
        let (client, _) = Self.client(harness)
        await client.start()
        try await harness.expectConverged(sameState: false)
        try await eventually("merged") { await client.lastMerge != nil }
        #expect(await client.lastMerge?.decision == .suggestReview)
        await client.stop()
    }

    @Test func thePreferencesDecide() async throws {
        let harness = try await Self.synced()
        let server = harness.server
        try await Self.rename(harness, Self.n, "mine")
        try await Self.rename(harness, Self.m, "mine too")
        try await server.inject(Fixture.change(9, seq: 2, start: 1_000, [Fixture.note(Self.n, "theirs")]))
        var options = fastOptions()
        options.reconcile = { ReconcilePreferences(askOverlapShare: 1) }
        let (client, _) = Self.client(harness, options: options)
        await client.start()
        try await Self.waitFor(client, .needsReview)
        #expect(await client.pendingReview?.mode == .perObject)
        // Use mine, performed as an ordinary change, then Done.
        let entry = try #require(await client.pendingReview?.entries.first)
        #expect(ReviewModel.useMine(entry) == nil)   // both edited: nothing to re-assert
        try await client.resolveReview(.upload)
        try await harness.expectConverged()
        await client.stop()
    }

    @Test func aStaleHoldWithNothingToSendIsDropped() async throws {
        let harness = try await Self.synced()
        try await harness.store.setReviewHold(LocalStore.ReviewHold(kind: .merge, baseSeq: 0))
        let (client, _) = Self.client(harness)
        await client.start()
        try await Self.waitFor(client, .saved)
        #expect(try await harness.store.reviewHold() == nil)
        #expect(await client.pendingReview == nil)
        await client.stop()
    }

    @Test func aRecoveredReviewIsShownAgainAfterARelaunch() async throws {
        let harness = try await Self.synced()
        try await Self.rename(harness, Self.n, "recovered")
        let report = SalvageReport(reason: .expired, salvagedChanges: 1, recoveredChanges: 1, reissuedOps: 1)
        try await harness.store.setReviewHold(LocalStore.ReviewHold(kind: .recovered, baseSeq: 1, report: report))
        let (client, events) = Self.client(harness)
        await client.start()
        try await Self.waitFor(client, .needsReview)
        #expect(await client.pendingReview?.recovered == report)
        try await eventually("reconciled") { events.all.filter { if case .reviewNeeded = $0 { true } else { false } }.count >= 1 }
        try await eventually("connected") { events.all.contains { if case .connection(true) = $0 { true } else { false } } }
        try await client.resolveReview(.upload)
        try await harness.expectConverged()
        #expect(await client.lastMerge == nil)
        await client.stop()
    }

    // MARK: Salvage (SYNC-010)

    @Test func anExpiredReplicaIsSalvagedOntoTheCollectedState() async throws {
        let harness = try await Self.synced()
        let server = harness.server
        try await Self.rename(harness, Self.n, "renamed offline")
        _ = try await harness.store.perform(createLayer("New", position: [0x70]), recording: Fixture.recording())
        // Meanwhile N was deleted, the server collected it, and the replica expired.
        let deletion = Fixture.change(9, seq: 2, start: 500, [Ops.setDeleted(Self.n)])
        try await server.inject(deletion)
        let log = await server.log
        let collected = SalvageTests.collected(log.map(\.change))
        await server.setSnapshotFrames(SnapshotTransfer.frames(collected, serverSeq: 2), seq: 2)
        await server.update {
            $0.compactedBelow = 2
            $0.retired = [42]
        }
        let (client, events) = Self.client(harness)
        await client.start()
        try await Self.waitFor(client, .needsReview)
        let review = try #require(await client.pendingReview)
        #expect(review.mode == .recovered)
        #expect(review.recovered?.dropped.map(\.missing) == [Self.n])
        #expect(review.recovered?.recoveredChanges == 1)
        try await eventually("event") { events.all.contains { if case .salvaged(let report) = $0 { report.reason == .expired } else { false } } }
        try await eventually("event") { events.all.contains { if case .replicaRotated(42, 43) = $0 { true } else { false } } }
        #expect(await server.acceptedSeqs(43).isEmpty)
        try await client.resolveReview(.upload)
        try await eventually("sent") { await server.acceptedSeqs(43) == [1] }
        try await eventually("outbox empty") { try await harness.store.outboxCount() == 0 }
        let new = await server.log.last!.change
        #expect(new.replica == 43 && new.label == "Create Layer")
        await client.stop()
    }

    @Test func aStoreCopiedToASecondMacRecoversWithNoDuplicateIds() async throws {
        let server = FakeSyncServer()
        let first = try await Harness(server: server)
        try await first.edit(3)
        let copy = try first.scratch.crashImage(of: "doc", to: "copy")
        let second = try await LocalStore.open(documentID: server.documentID, at: copy,
                                               options: WTSyncTests.options(hardware: "MAC-B", replicas: Replicas(from: 100)))
        #expect(second.report.rotatedFrom == 42)
        #expect(try await second.retiredOutbox().count == 3)
        let client = SyncClient(store: second, transport: FakeTransport(server: server), tokens: FakeTokens(), options: fastOptions())
        let events = Collector(client.events())
        await client.start()
        await first.client.start()
        try await first.expectConverged(sameState: false)
        try await eventually("both converged") {
            let head = await server.head
            let outbox = try await second.outboxCount()
            let secondApplied = await second.lastServerSeq
            let firstApplied = await first.store.lastServerSeq
            return outbox == 0 && secondApplied == head && firstApplied == head && head == 6
        }
        #expect(await server.acceptedSeqs(42) == [1, 2, 3])
        #expect(await server.acceptedSeqs(101) == [1, 2, 3])
        let ids = await server.log.flatMap { entry in
            entry.change.ops.indices.map { OpID(counter: entry.change.startCounter + UInt64($0), replica: entry.change.replica) }
        }
        #expect(Set(ids).count == ids.count)
        let hash = await server.stateHash()
        #expect(await first.store.read { $0.stateHash } == hash)
        #expect(await second.read { $0.stateHash } == hash)
        #expect(await second.read { $0.store.children(Fixture.layers).count } == 6)
        try await eventually("event") { events.all.contains { if case .salvaged(let report) = $0 { report.reason == .conflict && !report.needsReview } else { false } } }
        try await eventually("event") { events.all.contains { if case .replicaRotated(100, 101) = $0 { true } else { false } } }
        await client.stop()
        try await second.close()
        try await first.stop()
    }
}
