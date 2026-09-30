import Foundation
import Synchronization
import Testing
import WTProto
@testable import WTSync

/// DOC-019, D-089: a document made on this Mac while offline defers `DocumentService.Create`;
/// when the network comes back its client must not subscribe or push before the `Create`, which
/// the server answers `NOT_FOUND` (the race the audit found: the client halted with *The document
/// no longer exists* and the outbox never went up).
@Suite(.timeLimit(.minutes(2))) struct DocumentCreationGateTests {
    /// The library's side of the gate: the document waits for its `Create` until the network is
    /// back, then `create` makes it on the fake server.
    final class Library: Sendable {
        struct Offline: Error {}
        let server: FakeSyncServer
        private let state = Mutex((online: false, pending: true, calls: 0))

        init(server: FakeSyncServer) {
            self.server = server
        }

        var online: Bool {
            get { state.withLock { $0.online } }
            set { state.withLock { $0.online = newValue } }
        }
        var calls: Int { state.withLock { $0.calls } }

        var gate: DocumentCreationGate {
            DocumentCreationGate(
                isPending: { [self] _ in state.withLock { $0.pending } },
                create: { [self] _ in
                    let online = state.withLock { state in
                        state.calls += 1
                        return state.online
                    }
                    guard online else { throw Offline() }
                    await server.create()
                    state.withLock { $0.pending = false }
                }
            )
        }
    }

    /// The reproduction: without a gate the reconnecting client subscribes to a document the
    /// server does not have yet and halts.
    @Test func withoutAGateTheReconnectBeforeCreateHalts() async throws {
        let server = FakeSyncServer()
        await server.update { $0.exists = false }
        let harness = try await Harness(server: server)
        try await harness.edit(2)
        await harness.client.start()
        try await harness.waitFor(.error("The document no longer exists."))
        #expect(await server.pushes.isEmpty)
        try await harness.stop()
    }

    /// With the gate, nothing is subscribed while the `Create` cannot run; once it can, the
    /// session creates the document first and then uploads the outbox.
    @Test func aDocumentMadeOfflineIsCreatedBeforeItsFirstSubscribe() async throws {
        let server = FakeSyncServer()
        await server.update { $0.exists = false }
        let library = Library(server: server)
        let harness = try await Harness(server: server, creation: library.gate)
        try await harness.edit(3)
        await harness.client.start()
        try await harness.waitFor(.offline(3))
        try await eventually("retried") { library.calls >= 2 }
        #expect(await server.subscribes.isEmpty, "no Subscribe before Create")
        try await harness.waitForTransition("waiting") { $0.cause.hasPrefix(DocumentCreationGate.waitingCause) }

        library.online = true
        try await harness.waitFor(.saved)
        #expect(await server.creates == [0], "Create ran once, before any Subscribe")
        try await harness.expectConverged()
        #expect(await server.acceptedSeqs(await harness.store.replica) == [1, 2, 3])
        try await harness.stop()
    }

    /// A `Create` that returns while the document is still waiting (the library's upload failed
    /// and said so elsewhere) counts as not created: the session does not subscribe.
    @Test func aCreateThatLeavesTheDocumentWaitingIsRetried() async throws {
        let server = FakeSyncServer()
        await server.update { $0.exists = false }
        let pending = Mutex(true)
        let attempts = Mutex(0)
        let gate = DocumentCreationGate(
            isPending: { _ in pending.withLock { $0 } },
            create: { _ in
                // The second attempt reaches the server.
                guard attempts.withLock({ $0 += 1; return $0 }) >= 2 else { return }
                await server.create()
                pending.withLock { $0 = false }
            }
        )
        let harness = try await Harness(server: server)
        await harness.client.setCreation(gate)
        try await harness.edit(1)
        await harness.client.start()
        try await harness.waitFor(.saved)
        #expect(await server.creates == [0])
        #expect(attempts.withLock { $0 } == 2)
        try await harness.waitForTransition("waiting") { $0.cause == DocumentCreationGate.waitingCause }
        try await harness.expectConverged()
        try await harness.stop()
    }

    /// `NOT_FOUND` for a document the gate names waiting is the wait for its `Create`, not *The
    /// document no longer exists*: the next session creates it first.
    @Test func notFoundWhileTheDocumentWaitsIsRetriedNotHalted() async throws {
        let server = FakeSyncServer()
        await server.update { $0.exists = false }
        // Recorded as made here only after the first check (the library learns of it late).
        let checks = Mutex(0)
        let pending = Mutex(true)
        let gate = DocumentCreationGate(
            isPending: { _ in
                let first = checks.withLock { $0 += 1; return $0 == 1 }
                return !first && pending.withLock { $0 }
            },
            create: { _ in
                await server.create()
                pending.withLock { $0 = false }
            }
        )
        let harness = try await Harness(server: server, creation: gate)
        try await harness.edit(2)
        await harness.client.start()
        try await harness.waitFor(.saved)
        #expect(await server.subscribes.count == 2, "the refused Subscribe, then the one after Create")
        #expect(await server.creates == [1])
        #expect(!harness.transitions.all.contains { if case .error = $0.to { true } else { false } })
        try await harness.expectConverged()
        try await harness.stop()
    }

    /// A document the server already has (not waiting) subscribes at once, and a real
    /// `NOT_FOUND` for it still halts.
    @Test func aCreatedDocumentSubscribesAtOnceAndAMissingOneStillHalts() async throws {
        let server = FakeSyncServer()
        let created = Mutex(0)
        let gate = DocumentCreationGate(isPending: { _ in false }, create: { _ in created.withLock { $0 += 1 } })
        let harness = try await Harness(server: server, creation: gate)
        await harness.client.start()
        try await harness.waitFor(.saved)
        await server.update { $0.subscribeFailures = [SyncCallError(code: SyncCallError.notFound, message: "gone")] }
        await server.disconnect()
        try await harness.waitFor(.error("The document no longer exists."))
        #expect(created.withLock { $0 } == 0)
        try await harness.stop()
    }
}
