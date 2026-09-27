import Foundation
import GRPCCore
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// COLLAB-024's WTSync half: `pending_calls`, the version queue over a local store, the local
/// history the panel shows offline, and the history cache's invalidation by live changes.
@MainActor
@Suite(.timeLimit(.minutes(2))) struct PendingVersionsTests {
    /// Answers `NameVersion` as the server does for a known change; records every request.
    @MainActor final class Names {
        var requests: [Wiretuner_Docs_V1_NameVersionRequest] = []
        var failure: (any Error)?

        func send(_ request: Wiretuner_Docs_V1_NameVersionRequest) async throws -> Wiretuner_Docs_V1_Version {
            requests.append(request)
            if let failure {
                self.failure = nil
                throw failure
            }
            return .with { $0.id = request.versionID; $0.name = request.name; $0.serverSeq = request.serverSeq }
        }
    }

    @Test func pendingCallsKeepTheirOrderAndSurviveReopening() async throws {
        let scratch = Scratch()
        let url = scratch.url()
        var store = try await LocalStore.open(documentID: "doc", at: url, options: options())
        let first = PendingCall(id: "a", kind: "NameVersion", payload: Data("1".utf8), createdAt: Date(timeIntervalSince1970: 10))
        let second = PendingCall(id: "b", kind: "NameVersion", payload: Data("2".utf8), createdAt: Date(timeIntervalSince1970: 20))
        let other = PendingCall(id: "c", kind: "MarkRead", payload: Data(), createdAt: Date(timeIntervalSince1970: 30))
        try await store.replacePendingCalls(kind: "NameVersion", with: [first, second])
        try await store.replacePendingCalls(kind: "MarkRead", with: [other])
        var changed = first
        changed.payload = Data("1b".utf8)
        // `a` keeps its place with its new payload; `b` goes; `d` goes last.
        let third = PendingCall(id: "d", kind: "NameVersion", payload: Data("3".utf8), createdAt: Date(timeIntervalSince1970: 40))
        try await store.replacePendingCalls(kind: "NameVersion", with: [third, changed])
        try await store.close()
        store = try await LocalStore.open(documentID: "doc", at: url, options: options())
        #expect(try await store.pendingCalls(kind: "NameVersion") == [changed, third])
        #expect(try await store.pendingCalls(kind: "MarkRead") == [other])
        try await store.close()
        await #expect(throws: LocalStore.Failure.closed) { try await store.pendingCalls(kind: "NameVersion") }
        await #expect(throws: LocalStore.Failure.closed) { try await store.localHistory() }
    }

    /// Named offline: pending at once, kept when the app is killed, sent through the change once
    /// it is acknowledged -- and only then.
    @Test func aVersionNamedOfflineWaitsForItsChangeAndSurvivesAKill() async throws {
        let scratch = Scratch()
        let url = scratch.url()
        var store = try await LocalStore.open(documentID: "doc", at: url, options: options())
        try await store.receive(remoteChange(seq: 1), serverSeq: 1)
        let change = try #require(try await store.perform(createLayer("mine"), recording: Fixture.recording()).change)
        let queue = VersionQueue(documentID: "doc", store: store)
        queue.makeID = { "v-1" }
        var changes = 0
        queue.onChange = { changes += 1 }
        guard case .pending(let version) = await queue.save(name: "Before print", note: "n") else {
            Issue.record("expected a pending version")
            return
        }
        #expect(version.anchor == LocalChangeRef(change) && version.serverSeq == 1 && changes == 1)
        #expect(await queue.pendingVersions().map(\.name) == ["Before print"])
        // Killed: the store is closed with the version queued and opened again.
        try await store.close()
        store = try await LocalStore.open(documentID: "doc", at: url, options: options())
        let reopened = VersionQueue(documentID: "doc", store: store)
        let names = Names()
        reopened.send = { try await names.send($0) }
        #expect(await reopened.pendingVersions() == [version])
        #expect(await reopened.flush() == 0 && names.requests.isEmpty, "the change is not acknowledged yet")
        try await store.acknowledge(seq: change.seq, serverSeq: 2)
        #expect(await reopened.flush() == 1)
        let request = try #require(names.requests.first)
        #expect(request.versionID == "v-1" && request.throughLocalChange.counter == change.startCounter && request.serverSeq == 1)
        let left = try await store.pendingCalls(kind: VersionQueue.callKind)
        #expect(reopened.pending.isEmpty && left.isEmpty)
        try await store.close()
    }

    @Test func aVersionNamedWithEverythingAcknowledgedIsNamedAtOnce() async throws {
        let scratch = Scratch()
        let store = try await LocalStore.open(documentID: "doc", at: scratch.url(), options: options())
        try await store.receive(remoteChange(seq: 1), serverSeq: 1)
        let queue = VersionQueue(documentID: "doc", store: store)
        let names = Names()
        queue.send = { try await names.send($0) }
        let now = await queue.save(name: "Now")
        var expected = Wiretuner_Docs_V1_Version()
        expected.id = names.requests[0].versionID
        expected.name = "Now"
        expected.serverSeq = 1
        #expect(now == .named(expected))
        // A failed call keeps it pending; an unknown anchor falls back to the head.
        names.failure = RPCError(code: .unavailable, message: "down")
        guard case .pending = await queue.save(name: "Later") else {
            Issue.record("expected pending")
            return
        }
        #expect(await queue.flush() == 1)
        try await store.close()
    }

    @Test func theLegacyViewValueMovesIntoPendingCalls() async throws {
        let scratch = Scratch()
        let store = try await LocalStore.open(documentID: "doc", at: scratch.url(), options: options())
        let old = PendingVersion(id: "old", name: "IO-003", note: "", createdAt: Date(timeIntervalSince1970: 5), serverSeq: 0)
        try await store.setViewValue(try JSONEncoder().encode([old]), forKey: VersionQueue.viewKey)
        let storage = VersionQueue.Storage.localStore { store }
        let loaded = try #require(await storage.load())
        #expect(try JSONDecoder().decode([PendingVersion].self, from: loaded) == [old])
        #expect(try await store.pendingCalls(kind: VersionQueue.callKind).map(\.id) == ["old"])
        #expect(try await store.viewValue(forKey: VersionQueue.viewKey) == Data("[]".utf8))
        // Without a store nothing is read or written.
        let none = VersionQueue.Storage.localStore { nil }
        #expect(await none.load() == nil)
        await none.save(Data("[]".utf8))
        // An unreadable array is not written.
        await storage.save(Data("x".utf8))
        #expect(try await store.pendingCalls(kind: VersionQueue.callKind).map(\.id) == ["old"])
        try await store.close()
    }

    @Test func theQueueFlushesWhenTheDocumentIsSavedToTheCloud() async throws {
        let queue = VersionQueue(documentID: "doc", storage: .init(load: { nil }, save: { _ in }), head: { VersionHead(serverSeq: 3) })
        let names = Names()
        let (stream, continuation) = AsyncStream<SyncTransition>.makeStream()
        let task = queue.follow(stream)
        names.failure = RPCError(code: .unavailable, message: "offline")
        queue.send = { try await names.send($0) }
        _ = await queue.save(name: "Offline")
        #expect(queue.pending.count == 1)
        continuation.yield(SyncTransition(from: .offline(1), to: .saved, cause: "caught up"))
        continuation.finish()
        await task.value
        #expect(queue.pending.isEmpty && names.requests.count == 2)
    }

    static func ref(_ replica: UInt64, _ seq: UInt64, _ label: String = "Move") -> LocalChangeRef {
        LocalChangeRef(replica: replica, seq: seq, counter: seq * 10, label: label)
    }

    @Test func reanchoringAndTheFallbacks() async throws {
        // After a rotation the anchor waits in the retired outbox, then moves to its re-issue.
        var version = PendingVersion(id: "v", name: "n", note: "", createdAt: Date(), serverSeq: 1, anchor: Self.ref(1, 9, "Recolor"))
        #expect(VersionHead(serverSeq: 1, replica: 2, retired: [Self.ref(1, 9, "Recolor")]).resolve(&version) == .waiting)
        let reissued = VersionHead(serverSeq: 1, replica: 2, outbox: [Self.ref(2, 1), Self.ref(2, 2, "Recolor")])
        #expect(reissued.resolve(&version) == .waiting && version.anchor == Self.ref(2, 2, "Recolor"))
        // No store and no client: pending, and a flush sends nothing.
        let bare = VersionQueue(documentID: "d", storage: .init(load: { nil }, save: { _ in }), head: { nil })
        guard case .pending(let kept) = await bare.save(name: "x") else {
            Issue.record("expected pending")
            return
        }
        #expect(kept.anchor == nil && kept.serverSeq == 0)
        #expect(await bare.flush() == 0)
        // An anchor the server does not know is sent again without it; concurrent flushes share a pass.
        var head = VersionHead(serverSeq: 4, replica: 1, outbox: [Self.ref(1, 3)])
        let queue = VersionQueue(documentID: "d", storage: .init(load: { nil }, save: { _ in }), head: { head })
        let names = Names()
        queue.send = { try await names.send($0) }
        _ = await queue.save(name: "Anchored")
        head = VersionHead(serverSeq: 5, replica: 1)
        names.failure = RPCError(code: .notFound, message: "unknown change")
        async let first = queue.flush()
        async let second = queue.flush()
        let counts = await [first, second]
        #expect(counts == [1, 1] && names.requests.count == 2)
        #expect(names.requests[0].hasThroughLocalChange && !names.requests[1].hasThroughLocalChange)
        // Another failure keeps it.
        names.failure = RPCError(code: .unavailable, message: "down")
        _ = await queue.save(name: "Kept")
        names.failure = RPCError(code: .unavailable, message: "down")
        let sent = await queue.flush()
        #expect(sent == 0 && queue.pending.count == 1)
    }

    @Test func aVersionInBothTheTableAndTheLegacyValueIsKeptOnce() async throws {
        let scratch = Scratch()
        let store = try await LocalStore.open(documentID: "doc", at: scratch.url(), options: options())
        let version = PendingVersion(id: "same", name: "Both", note: "", createdAt: Date(timeIntervalSince1970: 5), serverSeq: 0)
        let other = PendingVersion(id: "other", name: "Legacy", note: "", createdAt: Date(timeIntervalSince1970: 6), serverSeq: 0)
        try await store.replacePendingCalls(kind: VersionQueue.callKind, with: VersionQueue.Storage.calls([version]))
        try await store.setViewValue(try JSONEncoder().encode([version, other]), forKey: VersionQueue.viewKey)
        let queue = VersionQueue(documentID: "doc", store: store)
        #expect(await queue.pendingVersions().map(\.id) == ["same", "other"])
        try await store.close()
    }

    @Test func theLocalHistoryListsTheLogAndWhatItCanRebuild() async throws {
        let scratch = Scratch()
        let store = try await LocalStore.open(documentID: "doc", at: scratch.url(), options: options())
        #expect(try await store.localHistory() == LocalHistory())
        for seq in 1...3 { try await store.receive(remoteChange(seq: UInt64(seq)), serverSeq: UInt64(seq)) }
        let sent = try #require(try await store.perform(createLayer("sent"), recording: Fixture.recording()).change)
        try await store.acknowledge(seq: sent.seq, serverSeq: 4)
        _ = try await store.perform(createLayer("unsent"), recording: Fixture.recording())
        var history = try await store.localHistory()
        // The acknowledgement records the change's seq; the applied head moves with the echo.
        #expect(history.head == 3 && history.rebuildableFrom == 0)
        #expect(history.sequenced.map(\.serverSeq) == [1, 2, 3, 4] && history.sequenced.map(\.local) == [false, false, false, true])
        #expect(history.notYetSynced == ["Create Layer"] && history.unsent.first?.serverSeq == nil)
        #expect(history.canRebuild(2) && !history.canRebuild(4))
        // A snapshot holding the unsent change rebuilds nothing; once it is sequenced, from its seq.
        try await store.rewriteSnapshot()
        history = try await store.localHistory()
        #expect(history.rebuildableFrom == 4 && !history.canRebuild(3))
        let none = try await store.state(atServerSeq: 3)
        #expect(none == nil)
        try await store.acknowledge(seq: sent.seq + 1, serverSeq: 5)
        try await store.receive(remoteChange(seq: 6), serverSeq: 6)
        history = try await store.localHistory()
        let rebuilt = try await store.state(atServerSeq: 5), older = try await store.state(atServerSeq: 4)
        #expect(history.rebuildableFrom == 5 && history.canRebuild(5) && rebuilt != nil)
        #expect(!history.canRebuild(4) && older == nil)
        try await store.close()
    }

    @Test func sequencedChangesGroupIntoSessionsNewestFirst() {
        func entry(_ seq: UInt64, _ replica: UInt64, _ minutes: Double) -> LocalHistory.Entry {
            LocalHistory.Entry(serverSeq: seq, label: "c\(seq)", local: replica == 1, replica: replica, wallTime: Date(timeIntervalSince1970: minutes * 60))
        }
        let history = LocalHistory(head: 5, sequenced: [entry(1, 1, 0), entry(2, 1, 5), entry(3, 1, 30), entry(4, 2, 31), entry(5, 2, 32)])
        let sessions = history.sessions()
        #expect(sessions.map { $0.entries.map(\.serverSeq) } == [[4, 5], [3], [1, 2]])
        #expect(sessions.map(\.local) == [false, true, true] && sessions[0].replica == 2)
    }

    @Test func liveChangesInvalidateTheHeadPagesAndTheNodesTheyTouch() {
        var cache = HistoryCache<String>()
        let head = HistoryCache<String>.Key.timeline(cursor: "", query: "", expandSession: 0)
        let older = HistoryCache<String>.Key.timeline(cursor: "c1", query: "", expandSession: 0)
        let touched = OpID(counter: 5, replica: 7)
        let untouched = OpID(counter: 9, replica: 7)
        cache.store("head", for: head, head: 10)
        cache.store("older", for: older, head: 10)
        cache.store("n5", for: .node(touched, cursor: ""), head: 10)
        cache.store("n9", for: .node(untouched, cursor: ""), head: 10)
        let rename = Fixture.change(7, seq: 3, start: 20, [Fixture.rename(touched, "x")])
        let stale = cache.apply(rename, serverSeq: 10)
        #expect(!stale, "already in the pages")
        let dropped = cache.apply(rename, serverSeq: 11)
        #expect(dropped)
        #expect(cache.page(head) == nil && cache.page(older) == "older")
        #expect(cache.page(.node(touched, cursor: "")) == nil && cache.page(.node(untouched, cursor: "")) == "n9")
        #expect(cache.count == 2 && cache.head == 10)
        cache.removeAll()
        #expect(cache.count == 0)
    }

    @Test func everyOpKindNamesItsNode() {
        let node = Wiretuner_Doc_V1_OpId.with { $0.counter = 1; $0.replica = 2 }
        let path = Wiretuner_Doc_V1_FieldPath()
        let ops: [Wiretuner_Doc_V1_Op] = [
            .with { $0.create = .init() },
            .with { $0.set = .with { $0.node = node } },
            .with { $0.move = .with { $0.node = node } },
            .with { $0.setDeleted = .with { $0.node = node } },
            .with { $0.elementInsert = .with { $0.node = node; $0.sequence = path } },
            .with { $0.elementMove = .with { $0.node = node } },
            .with { $0.elementDelete = .with { $0.node = node } },
            .with { $0.textInsert = .with { $0.node = node } },
            .with { $0.textDelete = .with { $0.node = node } },
            .with { $0.textMark = .with { $0.node = node } },
            .with { $0.setAdd = .with { $0.node = node } },
            .with { $0.setRemove = .with { $0.node = node } },
            .with { $0.noop = .init() },
        ]
        let change = Fixture.change(3, seq: 1, start: 40, ops)
        #expect(HistoryCache<Int>.nodes(of: change) == [OpID(counter: 40, replica: 3), OpID(counter: 1, replica: 2)])
    }
}
