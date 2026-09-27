import Foundation
import Testing
import WTProto
import WTSync
@testable import WTTestSupport

/// BASIC-028: shortcut sets synced as the `sync.shortcut_sets` preference, per set newest-wins with
/// deletion tombstones, between two Macs of one person through the simulator.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct ShortcutSetScenarioTests {
    /// One Mac: its preference sync and the sets it holds.
    @MainActor final class Mac {
        let sync: PreferenceSync
        let clock: @Sendable () -> Date
        var sets: [ShortcutSetSync.Item] = []
        var active = (id: "builtin.wiretuner", at: Int64(0))

        init(_ client: SimClient, _ service: SimAccountService, in sim: Simulation) throws {
            clock = client.clock
            sync = try AccountAndPublishScenarioTests.preferences(client, service, in: sim)
        }

        var nowMs: Int64 { Int64(clock().timeIntervalSince1970 * 1000) }

        /// Saves `set` here (stamped now) and queues it.
        func save(_ name: String, id: String, keys: [String]) async throws {
            var set = ShortcutSetSync.Item()
            set.id = id
            set.name = name
            set.basedOn = "builtin.wiretuner"
            set.bindings = [.with {
                $0.commandID = "tool.pen"
                $0.keys = keys
            }]
            set.updatedAtMs = nowMs
            if let index = sets.firstIndex(where: { $0.id == id }) { sets[index] = set } else { sets.append(set) }
            try await sync.enqueue([ShortcutSetSync.key: ShortcutSetSync.entry([set])])
        }

        /// Deletes set `id` here and queues its tombstone.
        func delete(_ id: String) async throws {
            sets.removeAll { $0.id == id }
            try await sync.enqueue([ShortcutSetSync.key: ShortcutSetSync.entry([ShortcutSetSync.tombstone(id, at: nowMs)])])
        }

        /// Fetches the account's map (sending what is queued) and applies the sets.
        func refresh() async throws {
            guard let map = try await sync.refresh(), let value = map[ShortcutSetSync.key], case .shortcutSetsValue(let remote)? = value.value else { return }
            let applied = ShortcutSetSync.apply(remote, to: sets, active: active, fallback: "builtin.wiretuner")
            sets = applied.sets
            active = (applied.activeSetID, applied.activeSetUpdatedAtMs)
        }

        func keys(of id: String) -> [String]? { sets.first { $0.id == id }?.bindings.first?.keys }
    }

    @Test func anEditAndADeleteMadeApartResolveByTheNewerChange() async throws {
        let sim = try await Simulation(name: "shortcut-sets", seed: Simulation.seed(2801))
        defer { Task { await sim.shutdown() } }
        let priya = SimUser(id: "u-priya", name: "Priya")
        let studio = try await sim.addClient("studio", user: priya)
        let laptop = try await sim.addClient("laptop", user: priya, device: "laptop")
        try await sim.settle()
        let clock = sim.clock
        let service = SimAccountService(now: { clock.nowMs() })
        let a = try Mac(studio, service, in: sim)
        let b = try Mac(laptop, service, in: sim)

        // Both Macs have "Mine" and "Other".
        try await a.save("Mine", id: "s-mine", keys: ["p"])
        sim.advance(by: .seconds(1))
        try await a.save("Other", id: "s-other", keys: ["b"])
        try await a.refresh()
        try await b.refresh()
        #expect(b.sets.map(\.name) == ["Mine", "Other"])

        // Apart: A edits "Mine", then B deletes it later.  B's change is newer: deleted on both.
        studio.goOffline()
        laptop.goOffline()
        sim.advance(by: .seconds(60))
        try await a.save("Mine", id: "s-mine", keys: ["p", "shift+p"])
        sim.advance(by: .seconds(60))
        try await b.delete("s-mine")
        studio.goOnline()
        try await a.refresh()
        laptop.goOnline()
        try await b.refresh()
        try await a.refresh()
        #expect(a.keys(of: "s-mine") == nil && b.keys(of: "s-mine") == nil)
        #expect(a.sets.map(\.id) == ["s-other"] && b.sets.map(\.id) == ["s-other"])

        // Apart: B deletes "Other", then A edits it later.  A's edit is newer: restored on both.
        studio.goOffline()
        laptop.goOffline()
        sim.advance(by: .seconds(60))
        try await b.delete("s-other")
        sim.advance(by: .seconds(60))
        try await a.save("Other", id: "s-other", keys: ["shift+b"])
        laptop.goOnline()
        try await b.refresh()
        studio.goOnline()
        try await a.refresh()
        try await b.refresh()
        #expect(a.keys(of: "s-other") == ["shift+b"] && b.keys(of: "s-other") == ["shift+b"])
        let pendingB = try await b.sync.pending()
        let pendingA = try await a.sync.pending()
        #expect(pendingB.isEmpty && pendingA.isEmpty)

        // The server keeps the tombstone of "Mine" for 30 days, then drops it on the next write.
        let stored = try #require(service.preferences(of: priya.id)[ShortcutSetSync.key]?.shortcutSetsValue)
        #expect(stored.sets.map(\.id) == ["s-mine", "s-other"] && stored.sets[0].deleted)
        sim.advance(by: .seconds(31 * 24 * 3600))
        try await a.save("Other", id: "s-other", keys: ["b"])
        try await a.refresh()
        #expect(service.preferences(of: priya.id)[ShortcutSetSync.key]?.shortcutSetsValue.sets.map(\.id) == ["s-other"])
        try await sim.expectConverged()
    }
}
