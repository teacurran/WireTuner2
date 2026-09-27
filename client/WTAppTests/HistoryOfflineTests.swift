import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTSync
@testable import WireTuner

/// COLLAB-024's panel half: pending versions under *Not yet synced*, *Available when online* rows,
/// the local log's sessions offline, and the cache a live change invalidates.
@Suite(.serialized) @MainActor struct HistoryOfflineTests {
    typealias World = HistoryTests.World

    static func entry(_ seq: UInt64, replica: UInt64 = 7) -> LocalHistory.Entry {
        LocalHistory.Entry(serverSeq: seq, label: "Change \(seq)", local: replica == 1, replica: replica, wallTime: Date(timeIntervalSince1970: Double(seq) * 60))
    }

    @Test func pendingVersionsAreListedAndOfflineRowsNeedTheNetwork() async throws {
        let w = World()
        defer { w.close() }
        let pending = PendingVersion(id: "p1", name: "Before print", note: "", createdAt: Date(), serverSeq: 8)
        w.model.queuedVersions = { _ in [pending] }
        w.model.localHistory = { _ in LocalHistory(head: 12, rebuildableFrom: 10, sequenced: [Self.entry(11), Self.entry(12)]) }
        w.client.page = HistoryPage(rows: [.version(World.version), .session(World.session)], nextCursor: "", retainedFromSeq: 0)
        await w.model.load()
        #expect(w.model.pendingVersions == [pending] && !w.model.isOffline)
        #expect(w.model.rows.allSatisfy(w.model.isActionable))
        // Offline: the page read earlier stays; only what the local log rebuilds acts.
        w.model.client = { nil }
        await w.model.load()
        #expect(w.model.isOffline && w.model.rows.count == 2)
        let version = w.model.rows[0], session = w.model.rows[1]
        #expect(w.model.isActionable(version) && !w.model.isAvailableWhenOnline(version), "seq 12 is in the local log")
        #expect(!w.model.isActionable(session) && w.model.isAvailableWhenOnline(session), "seq 9 is older than the local snapshot")
        #expect(await w.model.view(session) == false)
        PanelRendering.host(HistoryPanelBody(model: w.model), size: NSSize(width: 420, height: 600))
        PanelRendering.host(HistoryRowView(model: w.model, row: session))
        // Online again: everything acts.
        w.model.client = { w.client }
        await w.model.load()
        #expect(!w.model.isOffline && w.model.isActionable(session))
    }

    @Test func offlineWithNothingReadTheLocalLogIsTheTimeline() async throws {
        let w = World()
        defer { w.close() }
        w.model.client = { nil }
        w.model.localHistory = { _ in LocalHistory(head: 3, sequenced: [Self.entry(1, replica: 1), Self.entry(2, replica: 1), Self.entry(3)]) }
        w.model.author = { _, replica in replica == 7 ? "Tom" : nil }
        await w.model.load()
        #expect(w.model.message == "History needs the network." && w.model.rows.count == 2)
        guard case .session(let newest) = w.model.rows[0], case .session(let older) = w.model.rows[1] else {
            Issue.record("expected sessions")
            return
        }
        #expect(newest.author == "Tom" && newest.firstSeq == 3 && newest.changeCount == 1)
        #expect(older.author == "You" && older.firstSeq == 1 && older.lastSeq == 2 && older.changes.map(\.label) == ["Change 2", "Change 1"])
        #expect(w.model.rows.allSatisfy(w.model.isActionable))
        // The window's own local history: a memory document has none.
        let fresh = HistoryPanelModel()
        #expect(await fresh.localHistory(w.collaboration.window) == nil)
        #expect(fresh.author(w.collaboration.window, 7) == nil)
        // Offline again with rows on show: they stay.
        await w.model.refresh()
        #expect(w.model.rows.count == 2)
        // A collaborator the roster does not know.
        let window = w.collaboration.window
        fresh.window = { window }
        fresh.client = { nil }
        fresh.localHistory = { _ in LocalHistory(head: 1, sequenced: [Self.entry(1, replica: 9)]) }
        fresh.author = { _, _ in nil }
        await fresh.load()
        guard case .session(let someone) = fresh.rows.first else {
            Issue.record("expected a session")
            return
        }
        #expect(someone.author == "Someone")
    }

    @Test func aLiveChangeRereadsOnlyWhenTheShownPageWent() async throws {
        let w = World()
        defer { w.close() }
        w.client.page = HistoryPage(rows: [.session(World.session)], nextCursor: "", retainedFromSeq: 0)
        await w.model.load()
        let asked = w.client.requests.count
        // A local change: the unsent group follows, the timeline is not read again.
        var outboxReads = 0
        w.model.outbox = { _ in outboxReads += 1; return ["Move"] }
        let change = Wiretuner_Doc_V1_Change.with { $0.replica = 3; $0.seq = 1; $0.startCounter = 10 }
        await w.model.liveChange(change, remote: false, in: w.collaboration.window)
        #expect(w.client.requests.count == asked && outboxReads == 1 && w.model.pending == ["Move"])
        // A remote change past the head read: the head page goes and is read again.
        await w.model.liveChange(change, remote: true, in: w.collaboration.window)
        #expect(w.client.requests.count == asked + 1)
        // Refresh reads again whatever is cached.
        await w.model.refresh()
        #expect(w.client.requests.count == asked + 2)
        HistoryPanelBody.refreshing(w.model)()
        try await Task.sleep(for: .milliseconds(50))
    }
}
