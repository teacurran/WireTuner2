import AppKit
import Foundation
import Testing
@testable import WireTuner

/// A launched app's registry: every command the menus, tools and panels register.
@MainActor
func launchedDelegate(_ suite: TestDefaults, shortcutSetsURL: URL? = nil) -> AppDelegate {
    let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, shortcutSetsURL: shortcutSetsURL)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    return delegate
}

@MainActor
func closeAll(_ delegate: AppDelegate) {
    for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
}

/// The menu bar item running `id`, searched depth first.
@MainActor
func menuItem(_ id: CommandID, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
    for item in menu?.items ?? [] {
        if CommandMenuTarget.commandID(of: item) == id { return item }
        if let found = menuItem(id, in: item.submenu) { return found }
    }
    return nil
}

@Suite(.serialized) @MainActor struct ShortcutPresetTests {
    @Test func everyBuiltInSetValidatesAgainstTheRegistry() throws {
        let suite = TestDefaults()
        let delegate = launchedDelegate(suite)
        defer { closeAll(delegate) }
        let commands = delegate.commands.commands
        let presets = BuiltInShortcutSets.bundledPresets()
        #expect(presets.map(\.id) == BuiltInShortcutSets.presetIDs)
        #expect(presets.map(\.name) == ["Illustrator", "QuarkXPress", "Photoshop"])
        for preset in presets {
            let report = BuiltInShortcutSets.report(for: preset, commands: commands)
            #expect(report.unknownCommandIDs.isEmpty, "\(preset.id): \(report.unknownCommandIDs)")
            #expect(report.entries.map(\.commandID) == commands.map(\.id), "every registered command is in the report")
            #expect(report.entries.contains { $0.source == .preset } && report.entries.contains { $0.source == .inherited })
            let resolved = try #require(delegate.shortcutSets.resolvedSet(preset.id))
            #expect(resolved.conflicts().isEmpty, "\(preset.id): \(resolved.conflicts())")
            #expect(resolved.missingCommandIDs(registeredIDs: commands.map(\.id)).isEmpty)
        }
        #expect(delegate.shortcutSets.defaultSet.conflicts().isEmpty)
    }

    @Test func smartGuidesAndSettingsKeysPerSet() throws {
        let suite = TestDefaults()
        let delegate = launchedDelegate(suite)
        defer { closeAll(delegate) }
        let store = delegate.shortcutSets
        let cmdU = KeyEquivalent("u", .command), cmdK = KeyEquivalent("k", .command), cmdSlash = KeyEquivalent("/", .command)
        for summary in store.summaries {
            let set = try #require(store.resolvedSet(summary.id))
            #expect(set.commandIDs(for: cmdU) == [StandardCommands.ID.smartGuides], "\(summary.name)")
            #expect(set.commandIDs(for: cmdSlash) == [StandardCommands.ID.commandPalette], "\(summary.name)")
            let settingsOnK = set.commandIDs(for: cmdK) == [StandardCommands.ID.settings]
            #expect(settingsOnK == (summary.id == BuiltInShortcutSets.illustratorID), "\(summary.name)")
        }
        #expect(store.resolvedSet("nope") == nil)
    }

    @Test func switchingSetsRebindsTheMenuBarAndTools() throws {
        let suite = TestDefaults()
        let delegate = launchedDelegate(suite)
        defer { closeAll(delegate) }
        #expect(menuItem(StandardCommands.ID.settings)?.keyEquivalent == ",")
        #expect(menuItem(StandardCommands.ID.keyline)?.keyEquivalent == "k")
        try delegate.shortcutSets.activate(BuiltInShortcutSets.illustratorID)
        #expect(menuItem(StandardCommands.ID.settings)?.keyEquivalent == "k")
        #expect(menuItem(StandardCommands.ID.keyline)?.keyEquivalent == "y")
        #expect(menuItem(StandardCommands.ID.smartGuides)?.keyEquivalent == "u")
        // Tool keys go through the active set: M is the Rectangle in the Illustrator set.
        let window = try #require(delegate.activeDocumentWindow)
        #expect(window.environment.runShortcut(KeyEquivalent("m")))
        #expect(window.toolManager.activeToolID == .rectangle)
        #expect(delegate.shortcuts.keys(for: ToolRegistry.commandID(for: "lasso")) == [KeyEquivalent("q")])
        try delegate.shortcutSets.activate(ShortcutSet.defaultID)
        #expect(menuItem(StandardCommands.ID.settings)?.keyEquivalent == ",")
        #expect(!window.environment.runShortcut(KeyEquivalent("m")))
    }

    @Test func presetsOverrideAndFallBack() throws {
        let base = ShortcutSet(id: ShortcutSet.defaultID, name: "WireTuner", bindings: [
            ShortcutBinding(commandID: "a", keys: [KeyEquivalent("x")]),
            ShortcutBinding(commandID: "b", keys: [KeyEquivalent("y")]),
        ])
        let preset = ShortcutPreset(id: "builtin.test", name: "Test", overrides: [
            ShortcutBinding(commandID: "b", keys: [KeyEquivalent("x")]),
            ShortcutBinding(commandID: "c", keys: [KeyEquivalent("z")]),
        ])
        let resolved = preset.resolved(over: base)
        #expect(resolved.keys(for: "a").isEmpty, "the override took X away")
        #expect(resolved.keys(for: "b") == [KeyEquivalent("x")])
        #expect(resolved.keys(for: "c") == [KeyEquivalent("z")])
        #expect(resolved.basedOn == ShortcutSet.defaultID && resolved.isBuiltIn)
    }

    @Test func brokenResourcesAreErrors() throws {
        #expect(throws: BuiltInShortcutSetError.missingResource("builtin.none")) { try BuiltInShortcutSets.preset(named: "builtin.none") }
        var file = try JSONSerialization.jsonObject(with: ShortcutSet(id: "builtin.x", name: "X").exportJSON()) as! [String: Any]
        file["bindings"] = [["command_id": "app.quit", "keys": ["hyper+q"]]]
        let data = try JSONSerialization.data(withJSONObject: file)
        #expect(throws: BuiltInShortcutSetError.self) { try BuiltInShortcutSets.preset(data: data) }
        #expect(BuiltInShortcutSets.bundledPresets(bundle: Bundle(for: NSObject.self)).isEmpty)
    }

    @Test func fillingMissingSkipsKeysInUse() {
        let user = ShortcutSet(id: "u", name: "Mine", basedOn: ShortcutSet.defaultID, bindings: [ShortcutBinding(commandID: "a", keys: [KeyEquivalent("y")])])
        let base = ShortcutSet(id: ShortcutSet.defaultID, name: "WireTuner", bindings: [
            ShortcutBinding(commandID: "a", keys: [KeyEquivalent("x")]),
            ShortcutBinding(commandID: "b", keys: [KeyEquivalent("y"), KeyEquivalent("z")]),
        ])
        let filled = user.fillingMissing(from: base)
        #expect(filled.keys(for: "a") == [KeyEquivalent("y")])
        #expect(filled.keys(for: "b") == [KeyEquivalent("z")])
        #expect(filled.id == "u")
    }
}

@Suite @MainActor struct ShortcutSetStoreTests {
    private func store(url: URL? = nil) -> ShortcutSetStore {
        let store = ShortcutSetStore(url: url, presets: BuiltInShortcutSets.bundledPresets())
        store.commands = { StandardCommands.commands() }
        return store
    }

    @Test func userSetsCopyRenameDeleteAndPersist() throws {
        let url = TestEnvironment.temporaryDirectory().appending(path: ShortcutSetStore.fileName)
        let store = store(url: url)
        var changes = 0
        store.onChange = { changes += 1 }
        #expect(store.summaries.count == 4 && store.isActiveSetBuiltIn)
        #expect(store.copyName(for: ShortcutSet.defaultID) == "WireTuner Copy")
        let copy = try store.makeCopy(of: ShortcutSet.defaultID, name: "  Mine ")
        #expect(copy.name == "Mine" && store.activeSetID == copy.id && !store.isActiveSetBuiltIn)
        #expect(store.activeSet.keys(for: StandardCommands.ID.quit) == [KeyEquivalent("q", .command)])
        _ = try store.makeCopy(of: ShortcutSet.defaultID, name: "WireTuner Copy")
        #expect(store.copyName(for: ShortcutSet.defaultID) == "WireTuner Copy 2")
        try store.rename(copy.id, to: "Renamed")
        #expect(store.summaries.last?.name != nil && store.userSets.first?.name == "Renamed")
        #expect(throws: ShortcutSetStore.Failure.invalidName) { try store.rename(copy.id, to: " ") }
        #expect(throws: ShortcutSetStore.Failure.builtInSet(ShortcutSet.defaultID)) { try store.rename(ShortcutSet.defaultID, to: "X") }
        #expect(throws: ShortcutSetStore.Failure.unknownSet("zz")) { try store.delete("zz") }
        #expect(throws: ShortcutSetStore.Failure.unknownSet("zz")) { try store.activate("zz") }
        #expect(throws: ShortcutSetStore.Failure.unknownSet("zz")) { try store.makeCopy(of: "zz", name: "A") }
        try store.activate(copy.id)
        var edited = store.activeSet
        edited.bind(KeyEquivalent("q", [.command, .option]), to: StandardCommands.ID.new)
        try store.update(edited)
        #expect(store.activeSet.keys(for: StandardCommands.ID.new).contains(KeyEquivalent("q", [.command, .option])))
        #expect(store.lastSaveError == nil)

        let reloaded = self.store(url: url)
        #expect(reloaded.activeSetID == copy.id && reloaded.userSets.count == 2)
        #expect(store.copyName(for: "unknown") == "WireTuner Copy 2")
        let kept = try store.importSet(ShortcutSet(id: "fresh-id", name: "Fresh").exportJSON())
        #expect(kept.set.id == "fresh-id")
        try store.delete("fresh-id")
        try store.delete(copy.id)
        #expect(store.activeSetID == ShortcutSet.defaultID, "deleting the active set switches to WireTuner")
        #expect(changes >= 6)
    }

    @Test func userSetsFillFromTheirOriginAndSurviveCycles() throws {
        let store = store()
        let copy = try store.makeCopy(of: BuiltInShortcutSets.illustratorID, name: "Ill")
        var trimmed = copy
        trimmed.bindings.removeAll { $0.commandID == StandardCommands.ID.settings }
        try store.update(trimmed)
        #expect(store.activeSet.keys(for: StandardCommands.ID.settings).first == KeyEquivalent("k", .command), "inherits from Illustrator")
        var cyclic = trimmed
        cyclic.basedOn = cyclic.id
        try store.update(cyclic)
        #expect(store.activeSet.keys(for: StandardCommands.ID.settings).first == KeyEquivalent(",", .command), "a cycle falls back to WireTuner")
    }

    @Test func importAddsASetWithAFreshIDAndReportsBadKeys() throws {
        let store = store()
        var file = try JSONSerialization.jsonObject(with: ShortcutSet(id: ShortcutSet.defaultID, name: "", bindings: [
            ShortcutBinding(commandID: StandardCommands.ID.new, keys: [KeyEquivalent("n", .command)]),
        ]).exportJSON()) as! [String: Any]
        file["bindings"] = [["command_id": "file.new", "keys": ["cmd+n", "cmd+bogus+x"]], ["command_id": "file.open", "keys": ["hyper+o"]]]
        let imported = try store.importSet(JSONSerialization.data(withJSONObject: file))
        #expect(imported.warnings.count == 2)
        #expect(!imported.set.isBuiltIn && imported.set.name == "WireTuner Copy")
        #expect(store.userSets.map(\.id) == [imported.set.id])
        #expect(store.activeSetID == ShortcutSet.defaultID, "an import is not activated")
        #expect(throws: ShortcutSetImportError.self) { try store.importSet(Data("nope".utf8)) }
    }

    @Test func theSetLimitIsEnforced() throws {
        let store = store()
        for index in 0..<ShortcutSetStore.maximumUserSets { try store.makeCopy(of: ShortcutSet.defaultID, name: "S\(index)") }
        #expect(throws: ShortcutSetStore.Failure.tooManySets) { try store.makeCopy(of: ShortcutSet.defaultID, name: "More") }
        let data = try ShortcutSet(id: "x", name: "X").exportJSON()
        #expect(throws: ShortcutSetStore.Failure.tooManySets) { try store.importSet(data) }
    }

    @Test func aMissingActiveSetReadsAsWireTuners() throws {
        let url = TestEnvironment.temporaryDirectory().appending(path: ShortcutSetStore.fileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ShortcutSetStore.File(activeSetID: "gone", sets: [])).write(to: url)
        let store = store(url: url)
        #expect(store.activeSetID == "gone" && store.activeSet.id == ShortcutSet.defaultID)
    }

    @Test func snapshotsRestoreAndUnwritableFilesAreReported() throws {
        let store = store(url: URL(fileURLWithPath: "/dev/null/sets.json"))
        let before = store.snapshot
        try store.makeCopy(of: ShortcutSet.defaultID, name: "A")
        #expect(store.lastSaveError != nil)
        store.restore(before)
        #expect(store.userSets.isEmpty && store.activeSetID == ShortcutSet.defaultID)
        #expect(ShortcutSetStore.defaultURL.lastPathComponent == ShortcutSetStore.fileName)
    }
}
