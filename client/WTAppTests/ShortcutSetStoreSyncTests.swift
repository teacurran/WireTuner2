import Foundation
import Testing
import WTProto
import WTSync
@testable import WireTuner

/// BASIC-028: the shortcut set store hands every change to the `sync.shortcut_sets` entry and
/// applies the account's merged value.
@Suite @MainActor struct ShortcutSetStoreSyncTests {
    final class Sent {
        var entries: [Wiretuner_Account_V1_PreferenceValue] = []
        var sets: [ShortcutSetSync.Item] { entries.last?.shortcutSetsValue.sets ?? [] }
        var active: String? { entries.last.flatMap { $0.shortcutSetsValue.activeSetUpdatedAtMs > 0 ? $0.shortcutSetsValue.activeSetID : nil } }
    }

    private func makeStore(url: URL? = nil) -> (ShortcutSetStore, Sent, () -> Void) {
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        let store = ShortcutSetStore(url: url, presets: BuiltInShortcutSets.bundledPresets())
        store.commands = { registry.commands }
        var clock: Int64 = 1_000
        store.now = { clock }
        let sent = Sent()
        store.onSyncChange = { sent.entries.append($0) }
        return (store, sent, { clock += 10 })
    }

    @Test func everyChangeHandsOverItsEntry() throws {
        let (store, sent, tick) = makeStore()
        let copy = try store.makeCopy(of: ShortcutSet.defaultID, name: "Mine")
        #expect(sent.sets.map(\.id) == [copy.id] && sent.active == copy.id)
        #expect(sent.sets[0].bindings.isEmpty, "a fresh copy differs from nothing")
        #expect(sent.sets[0].basedOn == ShortcutSet.defaultID && sent.sets[0].updatedAtMs == 1_000)

        tick()
        var edited = store.userSets[0]
        edited.bind(WireTuner.KeyEquivalent("n", .command), to: StandardCommands.ID.open, now: 1_010)
        try store.update(edited)
        let bindings = Dictionary(uniqueKeysWithValues: sent.sets[0].bindings.map { ($0.commandID, $0.keys) })
        #expect(bindings == [StandardCommands.ID.open.rawValue: ["cmd+o", "cmd+n"], StandardCommands.ID.new.rawValue: []])
        #expect(sent.active == nil)

        tick()
        try store.rename(copy.id, to: "Renamed")
        #expect(sent.sets.map(\.name) == ["Renamed"] && sent.sets[0].updatedAtMs == 1_020)

        tick()
        try store.activate("builtin.photoshop")
        #expect(sent.sets.isEmpty && sent.active == "builtin.photoshop")

        tick()
        let imported = try store.importSet(try store.userSets[0].exportJSON())
        #expect(sent.sets.map(\.id) == [imported.set.id] && sent.sets[0].updatedAtMs == 1_040)

        tick()
        try store.activate(copy.id)
        tick()
        try store.delete(copy.id)
        #expect(sent.sets.map(\.id) == [copy.id] && sent.sets[0].deleted && sent.sets[0].updatedAtMs == 1_060)
        #expect(sent.active == ShortcutSet.defaultID)
        tick()
        try store.delete(imported.set.id)
        #expect(sent.active == nil, "deleting a set that is not active leaves the choice alone")

        let value = store.syncValue.shortcutSetsValue
        #expect(value.sets.isEmpty && value.activeSetID == ShortcutSet.defaultID)
    }

    @Test func revertIsANewEdit() throws {
        let (store, sent, tick) = makeStore()
        let copy = try store.makeCopy(of: ShortcutSet.defaultID, name: "Mine")
        let snapshot = store.snapshot
        tick()
        try store.rename(copy.id, to: "Renamed")
        let other = try store.makeCopy(of: ShortcutSet.defaultID, name: "Other")
        tick()
        store.restore(snapshot)
        #expect(store.userSets.map(\.name) == ["Mine"] && store.activeSetID == copy.id)
        let entry = try #require(sent.entries.last?.shortcutSetsValue)
        #expect(entry.sets.map(\.id) == [copy.id, other.id] && entry.sets[0].updatedAtMs == 1_020 && entry.sets[1].deleted)
        #expect(entry.activeSetID == copy.id)
        sent.entries = []
        store.restore(store.snapshot)
        #expect(sent.entries.isEmpty, "nothing changed, nothing to send")
    }

    @Test func theAccountsValueIsApplied() throws {
        let directory = FileManager.default.temporaryDirectory.appending(component: "shortcut-sync-\(UUID().uuidString)")
        let url = directory.appending(component: ShortcutSetStore.fileName)
        let (store, sent, _) = makeStore(url: url)
        var rebuilds = 0
        store.onChange = { rebuilds += 1 }
        let mine = try store.makeCopy(of: ShortcutSet.defaultID, name: "Mine")
        let count = sent.entries.count

        // Another Mac made "Laptop" (binding Open to ⌘N) and chose it later.
        var laptop = ShortcutSetSync.Item()
        laptop.id = "s-laptop"
        laptop.name = "Laptop"
        laptop.basedOn = ShortcutSet.defaultID
        laptop.updatedAtMs = 2_000
        laptop.bindings = [.with {
            $0.commandID = StandardCommands.ID.open.rawValue
            $0.keys = ["cmd+n", "not a key+"]
        }]
        var remote = ShortcutSetSync.Sets()
        remote.sets = [store.synced(mine), laptop]
        remote.activeSetID = "s-laptop"
        remote.activeSetUpdatedAtMs = 2_000
        store.applySynced(remote)
        #expect(store.userSets.map(\.name) == ["Mine", "Laptop"] && store.activeSetID == "s-laptop")
        #expect(store.userSets[0] == mine, "an unchanged set stays as this Mac keeps it")
        #expect(store.activeSet.keys(for: StandardCommands.ID.open) == [WireTuner.KeyEquivalent("n", .command)])
        #expect(store.activeSet.keys(for: StandardCommands.ID.new).isEmpty, "the set's key is taken from the set it was copied from")
        #expect(sent.entries.count == count, "applying sends nothing back")
        #expect(rebuilds == 2)

        // Persisted with the choice's stamp.
        let reloaded = ShortcutSetStore(url: url, presets: [])
        #expect(reloaded.activeSetID == "s-laptop" && reloaded.activeSetUpdatedAtMs == 2_000)

        // The same value again changes nothing; a newer tombstone deletes the active set.
        store.applySynced(remote)
        #expect(rebuilds == 2)
        remote.sets = [ShortcutSetSync.tombstone("s-laptop", at: 3_000)]
        store.applySynced(remote)
        #expect(store.userSets.map(\.name) == ["Mine"] && store.activeSetID == ShortcutSet.defaultID)
        try? FileManager.default.removeItem(at: directory)
    }
}
