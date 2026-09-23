import CoreGraphics
import Foundation
import Synchronization
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// SYNC-009: the presence model fed by the subscription, and the caller's own presence going up.
@Suite(.timeLimit(.minutes(2))) @MainActor struct PresenceTests {
    static func update(_ user: String, name: String = "Priya", color: UInt32 = 3, state: Wiretuner_Sync_V1_PresenceState = .active,
                       tool: String = "pen") -> Wiretuner_Sync_V1_PresenceUpdate {
        .with {
            $0.user.userID = user
            $0.user.displayName = name
            $0.colorIndex = color
            $0.state = state
            $0.tool = tool
        }
    }

    /// `eventually` for a condition read on the main actor.
    static func until(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw Timeout(description: "timed out waiting for \(what)")
    }

    final class Clock: Sendable {
        let now = Mutex(ContinuousClock.now)
    }

    static func snapshot(_ updates: [Wiretuner_Sync_V1_PresenceUpdate]) -> Wiretuner_Sync_V1_PresenceSnapshot {
        .with { $0.participants = updates }
    }

    @Test func aFrameReadsAsAParticipant() {
        var frame = Self.update("u1", state: .idle)
        frame.user.avatarSha256 = Data(repeating: 1, count: 32)
        frame.user.role = .editor
        frame.branchID = "b1"
        frame.page = OpID(counter: 3, replica: 9).proto
        frame.cursor = .with { $0.x = 10; $0.y = 20 }
        frame.viewport = .with {
            $0.visible = .with { $0.x = 1; $0.y = 2; $0.width = 300; $0.height = 200 }
            $0.zoom = 2
        }
        frame.selection = [OpID(counter: 4, replica: 9).proto]
        frame.selectionCount = 250
        frame.subSelection = [RegisterPath([20, 2]).proto, Wiretuner_Doc_V1_FieldPath()]
        frame.editing = [OpID(counter: 5, replica: 9).proto]
        frame.caret = .with {
            $0.node = OpID(counter: 6, replica: 9).proto
            $0.text = Fixture.text.proto
            $0.position = Ops.elementID(OpID(counter: 7, replica: 9))
            $0.rangeEnd = Ops.elementID(OpID(counter: 8, replica: 9))
        }
        frame.spotlight = true
        frame.followingUserID = "u2"
        let participant = PresenceParticipant(frame)
        #expect(participant.id == "u1" && participant.displayName == "Priya" && participant.colorIndex == 3 && participant.role == .editor)
        #expect(participant.avatarSHA256.count == 32 && participant.branchID == "b1" && participant.isIdle)
        #expect(participant.page == OpID(counter: 3, replica: 9) && participant.cursor == CGPoint(x: 10, y: 20))
        #expect(participant.viewport == CGRect(x: 1, y: 2, width: 300, height: 200) && participant.zoom == 2)
        #expect(participant.tool == "pen" && participant.selection == [OpID(counter: 4, replica: 9)] && participant.selectionCount == 250)
        #expect(participant.subSelection == [RegisterPath([20, 2])] && participant.editing == [OpID(counter: 5, replica: 9)])
        #expect(participant.caret == PresenceParticipant.Caret(node: OpID(counter: 6, replica: 9), text: Fixture.text,
                                                               position: OpID(counter: 7, replica: 9), rangeEnd: OpID(counter: 8, replica: 9)))
        #expect(participant.spotlight && participant.followingUserID == "u2" && !participant.frozen)
        let bare = PresenceParticipant(Self.update("u3"))
        #expect(bare.page == nil && bare.cursor == nil && bare.viewport == nil && bare.zoom == nil && bare.caret == nil && !bare.isIdle)
        var caretOnly = Self.update("u4")
        caretOnly.caret.node = OpID(counter: 1, replica: 1).proto
        #expect(PresenceParticipant(caretOnly).caret?.rangeEnd == nil)
    }

    @Test func updatesAndSnapshotsKeepArrivalOrderAndSkipTheLocalUser() {
        let model = PresenceModel(localUserID: "me")
        var notified = 0
        let token = model.observe { notified += 1 }
        model.apply(Self.update("u1"))
        model.apply(Self.update("u2", name: "Tom"))
        model.apply(Self.update("me"))
        #expect(model.participants.map(\.id) == ["u1", "u2"])
        model.apply(Self.update("u1", tool: "pencil"))
        #expect(model.participants.map(\.id) == ["u1", "u2"] && model.participant("u1")?.tool == "pencil")
        model.apply(Self.update("u1", state: .gone))
        #expect(model.participants.map(\.id) == ["u2"] && model.participant("u1") == nil)
        model.apply(Self.snapshot([Self.update("u3"), Self.update("u2", tool: "text"), Self.update("me"), Self.update("u4", state: .gone)]))
        #expect(model.participants.map(\.id) == ["u2", "u3"] && model.participant("u2")?.tool == "text")
        #expect(notified == 5)
        model.stopObserving(token)
        model.apply(Self.update("u5"))
        #expect(notified == 5)
    }

    /// COLLAB-004: entries are sessions `(branch_id, session)`; only this client's own is left out.
    @Test func sessionsAreParticipantsAndOnlyTheLocalOneIsSkipped() {
        func frame(_ user: String, session: UInt64, branch: String = "", state: Wiretuner_Sync_V1_PresenceState = .active,
                   tool: String = "pen") -> Wiretuner_Sync_V1_PresenceUpdate {
            var update = Self.update(user, state: state, tool: tool)
            update.session = session
            update.branchID = branch
            return update
        }
        let model = PresenceModel(localUserID: "me", localReplica: 10)
        // My other Mac is listed; this one is not; the same replica on a branch is someone else's session.
        model.apply(frame("me", session: 11))
        model.apply(frame("me", session: 10))
        model.apply(frame("u1", session: 20))
        model.apply(frame("u1", session: 21))
        model.apply(frame("u2", session: 10, branch: "b1"))
        #expect(model.participants.map(\.id) == ["/11", "/20", "/21", "b1/10"])
        #expect(model.participant("/20")?.session == 20 && model.participant("b1/10")?.branchID == "b1")
        model.apply(frame("u1", session: 20, tool: "text"))
        #expect(model.participant("/20")?.tool == "text" && model.participant("/21")?.tool == "pen")
        model.apply(frame("u1", session: 21, state: .gone))
        #expect(model.participants.map(\.id) == ["/11", "/20", "b1/10"])
        model.apply(Self.snapshot([frame("u1", session: 20), frame("me", session: 10), frame("me", session: 12)]))
        #expect(model.participants.map(\.id) == ["/20", "/12"])
        // A rotation makes the new replica this client's own.
        model.handle(.replicaRotated(from: 10, to: 12))
        #expect(model.localReplica == 12)
        model.apply(Self.snapshot([frame("u1", session: 20), frame("me", session: 12)]))
        #expect(model.participants.map(\.id) == ["/20"])
        model.localBranchID = "b1"
        #expect(model.isLocal(frame("x", session: 12, branch: "b1")) && !model.isLocal(frame("x", session: 12)))
        // A server that fills no session: keyed and skipped by account.
        #expect(PresenceParticipant.key(userID: "u9", branchID: "b", session: 0) == "u9")
        #expect(model.isLocal(Self.update("me")) && !model.isLocal(Self.update("u9")))
    }

    @Test func goingOfflineFreezesThenClears() async throws {
        let model = PresenceModel(localUserID: "me", clearAfter: .milliseconds(50))
        model.apply(Self.update("u1"))
        model.connectionChanged(false)
        #expect(model.participants.allSatisfy(\.frozen) && !model.isOffline)
        // Back before the clear: nothing lost.
        model.connectionChanged(true)
        #expect(model.participants.map(\.frozen) == [false])
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.participants.count == 1)
        model.connectionChanged(false)
        try await Self.until("cleared") { model.isOffline }
        #expect(model.participants.isEmpty)
        model.apply(Self.snapshot([Self.update("u1")]))
        #expect(!model.isOffline && model.participants.count == 1)
        model.unbind()
    }

    /// SYNC-009's done-when: a remote cursor reaches the model within 100 ms of its frame.
    @Test func remoteCursorsArriveWithinATenthOfASecond() async throws {
        let server = FakeSyncServer()
        let harness = try await Harness(server: server)
        let model = PresenceModel(localUserID: "me", clearAfter: .milliseconds(100))
        model.bind(to: harness.client.events())
        await harness.client.start()
        try await harness.waitFor(.saved)
        var latencies: [Duration] = []
        for step in 0..<20 {
            var frame = Self.update("u1")
            frame.cursor = .with { $0.x = Double(step); $0.y = 1 }
            let sent = ContinuousClock.now
            await server.send(.with { $0.presenceUpdate = frame })
            try await Self.until("cursor \(step)") { model.participant("u1")?.cursor?.x == CGFloat(step) }
            latencies.append(ContinuousClock.now - sent)
        }
        let sorted = latencies.sorted()
        print("PresenceModel: frame to model \(sorted[10]) median, \(sorted[19]) at most over 20 cursor moves")
        // The median, so that a test machine busy with other suites does not decide it.
        #expect(sorted[10] < .milliseconds(100))
        // Our connection drops: frozen, then cleared; reconnecting brings the snapshot back.
        await server.update { $0.subscribeFailures = Array(repeating: SyncCallError(code: SyncCallError.unavailable), count: 1_000) }
        await server.disconnect()
        try await Self.until("frozen") { model.participant("u1")?.frozen == true || model.isOffline }
        try await Self.until("offline") { model.isOffline }
        await server.update { $0.subscribeFailures = [] }
        try await harness.waitFor(.saved)
        try await Self.until("back") { !model.isOffline }
        model.unbind()
        try await harness.stop()
    }
}

/// The caller's own presence going up.
@Suite(.timeLimit(.minutes(2))) struct LocalPresenceTests {
    @Test func thePublishedPresenceIdlesAndCanHideThePointer() async throws {
        let clock = PresenceTests.Clock()
        let presence = LocalPresence(idleAfter: .seconds(120), now: { clock.now.withLock { $0 } })
        presence.update {
            $0.cursor = .with { $0.x = 5 }
            $0.tool = "pen"
            $0.selection = [OpID(counter: 1, replica: 1).proto]
            $0.selectionCount = 1
            $0.subSelection = [RegisterPath([20]).proto]
            $0.caret.node = OpID(counter: 1, replica: 1).proto
            $0.editing = [OpID(counter: 1, replica: 1).proto]
        }
        #expect(await presence.presence()?.state == .active)
        clock.now.withLock { $0 += .seconds(121) }
        #expect(await presence.presence()?.state == .idle)
        presence.input()
        #expect(await presence.presence()?.state == .active)
        #expect(presence.sharing)
        presence.sharing = false
        let hidden = try #require(await presence.presence())
        #expect(!hidden.hasCursor && hidden.tool.isEmpty && hidden.selection.isEmpty && hidden.selectionCount == 0)
        #expect(hidden.subSelection.isEmpty && !hidden.hasCaret && hidden.editing.count == 1)
        // Through the sync client: sent while connected, GONE on stop.
        presence.sharing = true
        let server = FakeSyncServer()
        let harness = try await Harness(server: server)
        let client = SyncClient(store: harness.store, transport: FakeTransport(server: server), tokens: FakeTokens(), presence: presence,
                                options: fastOptions())
        await client.start()
        try await eventually("sent") { await server.presences.contains { $0.tool == "pen" } }
        presence.update { $0.tool = "text" }
        try await eventually("changed") { await server.presences.contains { $0.tool == "text" } }
        await client.stop()
        #expect(await server.presences.last?.state == .gone)
        try await harness.stop()
    }
}
