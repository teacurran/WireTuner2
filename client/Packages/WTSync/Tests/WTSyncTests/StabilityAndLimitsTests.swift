import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// TEST-001's findings on the client side: acks that let the collection point rise (D-067, finding
/// a), changes over the server's limits split instead of refused forever (finding b), and requests
/// the server refuses as malformed parked in the error state (finding d).
@Suite(.timeLimit(.minutes(2))) struct StabilityAndLimitsTests {
    // MARK: Acks and the horizon (finding a)

    @Test func anAnswerThatRaisesTheStablePointIsConfirmedOnce() async throws {
        let server = FakeSyncServer()
        for seq in 1...3 {
            try await server.inject(remoteChange(seq: UInt64(seq)))
        }
        let harness = try await Harness(server: server)
        await harness.client.start()
        try await eventually("acked") { await server.acks.count >= 2 }
        try await Task.sleep(for: .milliseconds(300))
        // The first ack reports 3 and is answered 3; the second confirms that answer; then nothing
        // has moved and nobody lags, so nothing more goes up.
        #expect(await server.acks == [3, 3])
        try await server.inject(remoteChange(seq: 4))
        try await eventually("acked again") { await server.acks.count >= 4 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await server.acks == [3, 3, 4, 4])
        #expect(await harness.store.horizon == 4)
        try await harness.stop()
    }

    @Test func aLaggingStablePointIsPolledWithBackoffUntilItRises() async throws {
        let server = FakeSyncServer()
        await server.update { $0.stableCap = 1 }
        for seq in 1...3 {
            try await server.inject(remoteChange(seq: UInt64(seq)))
        }
        var options = fastOptions()
        options.ackPollMax = .milliseconds(160)
        let harness = try await Harness(server: server, options: options)
        await harness.client.start()
        try await eventually("polling") { await server.acks.count >= 4 }
        // Ticks every 40 ms, but the delay doubles to 160 ms: a second holds a handful of polls.
        let before = await server.acks.count
        try await Task.sleep(for: .seconds(1))
        let polled = await server.acks.count - before
        #expect(polled >= 3 && polled <= 12, "\(polled) polls in a second")
        await server.update { $0.stableCap = nil }
        try await harness.waitForEvent("risen") { if case .stable(3) = $0 { true } else { false } }
        try await Task.sleep(for: .milliseconds(300))
        let settled = await server.acks.count
        try await Task.sleep(for: .milliseconds(400))
        #expect(await server.acks.count == settled)
        #expect(await harness.store.horizon == 3)
        try await harness.stop()
    }

    @Test func aConfirmingAckWaitsForTheChangesMadeBeforeIt() async throws {
        let server = FakeSyncServer()
        try await server.inject(remoteChange(seq: 1))
        await server.update { $0.delay = [1: .milliseconds(600)] }
        let harness = try await Harness(server: server)
        try await harness.edit(1)   // made before the session, under an older horizon
        await harness.client.start()
        try await eventually("caught up") { await harness.store.lastServerSeq >= 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await server.acks.isEmpty, "no ack while a change made before its answer is unaccepted")
        try await harness.expectConverged()
        try await eventually("acked") { await server.acks.last == 2 }
        try await harness.stop()
    }

    @Test func theHorizonSurvivesARelaunch() async throws {
        let scratch = Scratch()
        let store = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        await store.advanceHorizon(to: 5)
        await store.advanceHorizon(to: 3)
        #expect(await store.horizon == 5)
        try await store.discardLocalChanges()
        #expect(await store.horizon == 5)
        try await store.close()
        let reopened = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        #expect(await reopened.horizon == 5)
        try await reopened.close()
        await reopened.advanceHorizon(to: 9)   // closed: kept in memory only
        #expect(await reopened.horizon == 9)
    }

    // MARK: Refusals (finding b)

    @Test func aRefusedChangeIsReplacedByOneNoop() async throws {
        let server = FakeSyncServer()
        await server.update { $0.maxBytes = 60 }
        var options = fastOptions()
        options.changeLimits = ChangeLimits(bytes: 60)
        let harness = try await Harness(server: server, options: options)
        // One op, too large for the limit: it cannot be split, goes up, and is replaced.
        _ = try await harness.store.perform(createLayer(String(repeating: "n", count: 80)), recording: Fixture.recording())
        await harness.client.localChangesAvailable()
        await harness.client.start()
        try await eventually("replacement accepted") { await server.acceptedSeqs(42) == [1] }
        #expect(await server.log[0].change.ops == [Ops.noop()])
        #expect(await server.validationFailures == 1)
        try await harness.waitForEvent("dropped") { if case .changeDropped(1, _) = $0 { true } else { false } }
        #expect(await harness.store.replica == 42)
        try await harness.expectConverged(sameState: false)
        try await harness.stop()
    }

    @Test func aRefusedReplacementIsAnErrorNotALoop() async throws {
        let server = FakeSyncServer()
        await server.update { $0.maxBytes = 8 }
        let harness = try await Harness(server: server)
        try await harness.edit(1)
        await harness.client.start()
        try await harness.waitFor(.error("A change could not be sent: the server refused it (change outside the limits)."))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await server.validationFailures == 2)
        #expect(await server.pushes.count == 2)
        // *Retry now* sends the replacement once more.
        await server.update { $0.maxBytes = nil }
        await harness.client.retry()
        try await harness.expectConverged(sameState: false)
        try await harness.waitFor(.saved)
        try await harness.stop()
    }

    enum Route: String, CaseIterable, CustomTestStringConvertible {
        case pipelined, bulk, gateway
        var testDescription: String { rawValue }
    }

    @Test(arguments: Route.allCases) func aChangeOverTheLimitsIsSplitBeforeItIsSent(route: Route) async throws {
        let server = FakeSyncServer()
        await server.update { $0.maxOps = 3 }
        var options = fastOptions(gateway: route == .gateway)
        options.changeLimits = ChangeLimits(ops: 3)
        options.bulkChanges = route == .bulk ? 2 : 200
        let harness = try await Harness(server: server, options: options)
        try await harness.edit(2)   // seqs 1 and 2 fit
        let paste = (0..<7).map { Fixture.createLayer("P\($0)", position: [0x80, UInt8($0)]) }
        _ = try await harness.store.perform(OpsCommand("Paste", ops: paste), recording: Fixture.recording())
        await harness.client.start()
        try await eventually("split and sent") { await server.acceptedSeqs(43).count == 3 }
        try await harness.expectConverged()
        #expect(await server.acceptedSeqs(42) == [1, 2])
        #expect(await server.validationFailures == 0)
        #expect(await server.log.allSatisfy { $0.change.ops.count <= 3 })
        #expect(await server.log.filter { $0.change.label == "Paste" }.map(\.change.ops.count) == [3, 3, 1])
        try await harness.waitForEvent("rotated") { if case .replicaRotated(42, 43) = $0 { true } else { false } }
        try await harness.waitForEvent("salvaged") {
            if case .salvaged(let report) = $0 { report.reason == .oversized && report.reissuedOps == 7 && report.dropped.isEmpty } else { false }
        }
        #expect(await harness.client.pendingReview == nil)
        try await harness.stop()
    }

    // MARK: Malformed requests (finding d)

    @Test func aMalformedRequestIsAnErrorUntilRetried() async throws {
        let server = FakeSyncServer()
        await server.update { $0.subscribeFailures = [SyncCallError(code: SyncCallError.invalidArgument, message: "wt-device must be a UUID")] }
        let harness = try await Harness(server: server)
        await harness.client.start()
        try await harness.waitFor(.error("The server refused this Mac's request: wt-device must be a UUID"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.subscribes.count == 1)
        await harness.client.retry()
        try await harness.waitFor(.saved)
        try await harness.stop()
    }
}
