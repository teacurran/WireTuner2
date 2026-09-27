import Foundation
import Testing
import WTProto
@testable import WTSync

/// BASIC-028: `sync.shortcut_sets` merged per set with tombstones, on the outbox and on a device.
@Suite struct ShortcutSetSyncTests {
    typealias Item = ShortcutSetSync.Item

    static func set(_ id: String, _ name: String, at: Int64, keys: [String] = ["p"]) -> Item {
        var set = Item()
        set.id = id
        set.name = name
        set.updatedAtMs = at
        set.bindings = [.with {
            $0.commandID = "tool.pen"
            $0.keys = keys
        }]
        return set
    }

    static func sets(_ items: [Item], active: String = "", at: Int64 = 0) -> ShortcutSetSync.Sets {
        var out = ShortcutSetSync.Sets()
        out.sets = items
        out.activeSetID = active
        out.activeSetUpdatedAtMs = at
        return out
    }

    @Test func setsMergePerIDAndTombstonesExpire() {
        let day: Int64 = 24 * 3600 * 1000
        let now = 100 * day
        let stored = Self.sets([Self.set("b", "Kept", at: now - 5), Self.set("a", "Old", at: now - 9),
                                ShortcutSetSync.tombstone("x", at: now - 31 * day), ShortcutSetSync.tombstone("y", at: now - day)],
                               active: "a", at: now - 5)
        let changes = Self.sets([Self.set("a", "New", at: now - 9), Self.set("b", "Older", at: now - 6), ShortcutSetSync.tombstone("c", at: now)],
                                active: "b", at: now - 6)
        let merged = ShortcutSetSync.merge(stored, changes, now: now)
        #expect(merged.sets.map(\.id) == ["a", "b", "c", "y"])
        #expect(merged.sets[0].name == "New" && merged.sets[1].name == "Kept" && merged.sets[2].deleted)
        #expect(merged.activeSetID == "a")
        #expect(ShortcutSetSync.merge(stored, Self.sets([], active: "c", at: now - 5), now: now).activeSetID == "c")
        #expect(ShortcutSetSync.merge(stored, Self.sets([]), now: now).activeSetID == "a")
    }

    @Test func entriesMergeAsTheServerMergesThem() {
        var a = ShortcutSetSync.entry([Self.set("a", "A", at: 5)])
        a.updatedAtMs = 5
        var b = ShortcutSetSync.entry([Self.set("b", "B", at: 3)], active: (id: "b", at: 3))
        b.updatedAtMs = 3
        b.device = "laptop"
        let merged = ShortcutSetSync.merge(a, b, now: 10)
        #expect(merged.shortcutSetsValue.sets.map(\.id) == ["a", "b"] && merged.updatedAtMs == 5 && merged.device == "laptop")
        #expect(merged.shortcutSetsValue.activeSetID == "b")
        #expect(ShortcutSetSync.merge(nil, b, now: 10) == b)
        var plain = Wiretuner_Account_V1_PreferenceValue.bool(true)
        plain.updatedAtMs = 4
        #expect(ShortcutSetSync.merge(a, plain, now: 10) == a)
        #expect(ShortcutSetSync.merge(plain, b, now: 10) == plain)
        plain.updatedAtMs = 6
        #expect(ShortcutSetSync.merge(a, plain, now: 10) == plain)
    }

    @Test func unsentLeavesOutWhatTheServerHasNewer() {
        let server = Self.sets([Self.set("a", "A", at: 5), Self.set("b", "B", at: 5)], active: "a", at: 5)
        #expect(ShortcutSetSync.unsent(Self.sets([Self.set("a", "A", at: 5)], active: "a", at: 4), after: server) == nil)
        let rest = ShortcutSetSync.unsent(Self.sets([Self.set("a", "A", at: 5), Self.set("b", "B", at: 6), Self.set("c", "C", at: 1)],
                                                    active: "c", at: 6), after: server)
        #expect(rest?.sets.map(\.id) == ["b", "c"] && rest?.activeSetID == "c")
        let choiceOnly = ShortcutSetSync.unsent(Self.sets([], active: "b", at: 9), after: server)
        #expect(choiceOnly?.sets.isEmpty == true && choiceOnly?.activeSetUpdatedAtMs == 9)
    }

    @Test func applyingReplacesDeletesAndChooses() {
        let local = [Self.set("a", "A", at: 5), Self.set("b", "B", at: 5), Self.set("d", "Unsent", at: 1)]
        let remote = Self.sets([Self.set("a", "A2", at: 6), ShortcutSetSync.tombstone("b", at: 6), Self.set("c", "C", at: 2),
                                ShortcutSetSync.tombstone("z", at: 2), Self.set("d", "Older", at: 0)], active: "c", at: 3)
        let applied = ShortcutSetSync.apply(remote, to: local, active: (id: "a", at: 2), fallback: "builtin.wiretuner")
        #expect(applied.sets.map(\.name) == ["A2", "Unsent", "C"])
        #expect(applied.activeSetID == "c" && applied.activeSetUpdatedAtMs == 3 && applied.changed)

        // Nothing newer: unchanged.  The active set deleted: WireTuner's.
        let same = ShortcutSetSync.apply(Self.sets([Self.set("a", "A", at: 5)], active: "a", at: 1), to: local, active: (id: "a", at: 2),
                                         fallback: "builtin.wiretuner")
        #expect(!same.changed && same.activeSetID == "a")
        let gone = ShortcutSetSync.apply(Self.sets([ShortcutSetSync.tombstone("a", at: 9)]), to: local, active: (id: "a", at: 2),
                                         fallback: "builtin.wiretuner")
        #expect(gone.activeSetID == "builtin.wiretuner" && gone.changed)
        let builtIn = ShortcutSetSync.apply(Self.sets([], active: "builtin.photoshop", at: 9), to: local, active: (id: "a", at: 2),
                                            fallback: "builtin.wiretuner")
        #expect(builtIn.activeSetID == "builtin.photoshop" && builtIn.changed)
        let stale = ShortcutSetSync.apply(Self.sets([]), to: [], active: (id: "gone", at: 2), fallback: "builtin.wiretuner")
        #expect(stale.activeSetID == "builtin.wiretuner" && stale.changed)
    }

    /// The outbox: changes queued apart join into one entry; what the server has newer is dropped;
    /// queued sets lie over the server's in the delivered map.
    @Test func theOutboxMergesShortcutSetsPerSet() async throws {
        let directory = try PreferenceSyncTests.directory()
        let server = FakePreferenceServer()
        let clock = Clock(1_000)
        let studio = try PreferenceSyncTests.device(server, "studio", clock: clock, in: directory)
        let laptop = try PreferenceSyncTests.device(server, "laptop", clock: clock, in: directory)

        server.offline = true
        try await studio.enqueue([ShortcutSetSync.key: ShortcutSetSync.entry([Self.set("a", "A", at: 1_000)])])
        clock.advance(10)
        try await studio.enqueue([ShortcutSetSync.key: ShortcutSetSync.entry([Self.set("b", "B", at: 1_010)], active: (id: "b", at: 1_010))])
        let queued = try await studio.pending()[ShortcutSetSync.key]?.shortcutSetsValue
        #expect(queued?.sets.map(\.id) == ["a", "b"] && queued?.activeSetID == "b")

        // The laptop meanwhile renamed "a" later; the studio's older "a" is not sent.
        server.offline = false
        clock.advance(10)
        try await laptop.enqueue([ShortcutSetSync.key: ShortcutSetSync.entry([Self.set("a", "A laptop", at: 1_020)])])
        try await laptop.push()
        clock.advance(10)
        try await laptop.enqueue([ShortcutSetSync.key: ShortcutSetSync.entry([Self.set("c", "C", at: 1_030)])])
        let map = try #require(try await studio.refresh())
        let value = try #require(map[ShortcutSetSync.key]?.shortcutSetsValue)
        #expect(value.sets.map(\.name) == ["A laptop", "B"] && value.activeSetID == "b")
        #expect(server.sets.last?[ShortcutSetSync.key]?.shortcutSetsValue.sets.map(\.id) == ["b"])
        #expect(try await studio.pending().isEmpty)

        // Queued on the laptop and not sent: it lies over the server's sets when the map arrives.
        let seen = try #require(try await laptop.refresh())
        #expect(seen[ShortcutSetSync.key]?.shortcutSetsValue.sets.map(\.id) == ["a", "b", "c"])

        // A queued entry the server has as new everywhere is dropped without sending.
        server.offline = true
        try await laptop.enqueue([ShortcutSetSync.key: ShortcutSetSync.entry([Self.set("c", "C", at: 1_030)])])
        server.offline = false
        let sent = server.sets.count
        try await laptop.refresh()
        let left = try await laptop.pending()
        #expect(server.sets.count == sent && left.isEmpty)
    }
}
