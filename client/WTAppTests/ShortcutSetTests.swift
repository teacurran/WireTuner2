import Foundation
import Testing
@testable import WireTuner

@Suite struct ShortcutSetTests {
    private let commands = StandardCommands.commands()

    @Test func defaultSetBindsEveryCommand() {
        let set = ShortcutSet.builtInDefault(commands: commands)
        #expect(set.id == ShortcutSet.defaultID)
        #expect(set.isBuiltIn)
        #expect(set.bindings.count == commands.count)
        #expect(set.commandIDs == commands.map(\.id))
        #expect(set.keys(for: StandardCommands.ID.quit) == [KeyEquivalent("q", .command)])
        #expect(set.keyEquivalent(for: StandardCommands.ID.redo) == KeyEquivalent("z", [.command, .shift]))
        #expect(set.keys(for: StandardCommands.ID.about).isEmpty)
        #expect(set.keyEquivalent(for: "unknown") == nil)
        #expect(set.commandIDs(for: KeyEquivalent("z", .command)) == [StandardCommands.ID.undo])
        #expect(set.missingCommandIDs(registeredIDs: commands.map(\.id)).isEmpty)
        #expect(set.unknownCommandIDs(knownIDs: Set(commands.map(\.id))).isEmpty)
    }

    @Test func defaultSetHasNoConflicts() {
        let set = ShortcutSet.builtInDefault(commands: commands)
        #expect(set.conflicts() == [])
    }

    @Test func copiesAreUserSets() {
        let set = ShortcutSet.builtInDefault(commands: commands)
        let copy = set.copy(id: "user-1", name: "Mine", now: 42)
        #expect(!copy.isBuiltIn)
        #expect(copy.basedOn == ShortcutSet.defaultID)
        #expect(copy.bindings == set.bindings)
        #expect(copy.updatedAtMs == 42)
        #expect(copy.name == "Mine")
        #expect(set.copy(name: "Auto").id.count == 36)
        #expect(ShortcutSet.nowMs() > 0)
    }

    @Test func bindingReplacesOrKeepsDuplicates() {
        var set = ShortcutSet.builtInDefault(commands: commands)
        let key = KeyEquivalent("n", .command)
        set.bind(key, to: StandardCommands.ID.open, now: 1)
        #expect(set.keys(for: StandardCommands.ID.new).isEmpty)
        #expect(set.keys(for: StandardCommands.ID.open) == [KeyEquivalent("o", .command), key])
        #expect(set.updatedAtMs == 1)
        set.bind(key, to: StandardCommands.ID.open, now: 2)
        #expect(set.keys(for: StandardCommands.ID.open).count == 2)

        set.bind(key, to: StandardCommands.ID.new, replacingExisting: false, now: 3)
        #expect(set.commandIDs(for: key) == [StandardCommands.ID.new, StandardCommands.ID.open])
        let conflicts = set.conflicts()
        #expect(conflicts == [ShortcutConflict(key: key, kind: .duplicate, commandIDs: [StandardCommands.ID.new, StandardCommands.ID.open])])
        #expect(conflicts[0].description == "cmd+n is bound to file.new, file.open")

        set.bind(KeyEquivalent("x", .control), to: "brand.new", now: 4)
        #expect(set.keys(for: "brand.new") == [KeyEquivalent("x", .control)])
    }

    @Test func unbindingLeavesExplicitlyUnboundEntries() {
        var set = ShortcutSet.builtInDefault(commands: commands)
        set.unbind(KeyEquivalent("q", .command), from: StandardCommands.ID.quit, now: 5)
        #expect(set.keys(for: StandardCommands.ID.quit).isEmpty)
        #expect(set.commandIDs.contains(StandardCommands.ID.quit))
        set.unbind(KeyEquivalent("q", .command), from: "unknown", now: 6)
        #expect(set.updatedAtMs == 5)
        set.unbindAll(from: StandardCommands.ID.open, now: 7)
        #expect(set.keys(for: StandardCommands.ID.open).isEmpty)
        set.unbindAll(from: "other", now: 8)
        #expect(set.bindings.last == ShortcutBinding(commandID: "other", keys: []))
    }

    @Test func reportsReservedKeys() {
        var set = ShortcutSet.builtInDefault(commands: commands)
        set.bind(KeyEquivalent("q", .command), to: StandardCommands.ID.new, replacingExisting: false)
        set.bind(KeyEquivalent("tab", .command), to: StandardCommands.ID.open)
        let conflicts = set.conflicts()
        #expect(conflicts.count == 3)
        #expect(conflicts.contains(ShortcutConflict(key: KeyEquivalent("q", .command), kind: .duplicate, commandIDs: [StandardCommands.ID.quit, StandardCommands.ID.new])))
        #expect(conflicts.contains(ShortcutConflict(key: KeyEquivalent("q", .command), kind: .reserved, commandIDs: [StandardCommands.ID.new])))
        #expect(conflicts.contains(ShortcutConflict(key: KeyEquivalent("tab", .command), kind: .reserved, commandIDs: [StandardCommands.ID.open])))
        #expect(conflicts.first { $0.kind == .reserved }?.description.contains("reserved by macOS") == true)

        let reserved = ReservedShortcuts.macOS
        #expect(reserved.isReserved(KeyEquivalent("q", .command)))
        #expect(!reserved.isReserved(KeyEquivalent("k", .command)))
        #expect(!reserved.isReserved(KeyEquivalent("q", .command), against: StandardCommands.ID.quit))
        #expect(reserved.isReserved(KeyEquivalent("q", .command), against: StandardCommands.ID.new))
        #expect(!reserved.isReserved(KeyEquivalent("k", .command), against: StandardCommands.ID.new))
    }

    @Test func reportsUnknownAndMissingCommands() {
        var set = ShortcutSet.builtInDefault(commands: commands)
        set.bind(KeyEquivalent("j", .command), to: "gone.away")
        #expect(set.unknownCommandIDs(knownIDs: Set(commands.map(\.id))) == ["gone.away"])
        #expect(set.missingCommandIDs(registeredIDs: commands.map(\.id) + ["fresh"]) == ["fresh"])
    }

    @Test func exportsAndImportsWtkeys() throws {
        var set = ShortcutSet.builtInDefault(commands: commands).copy(id: "user-2", name: "Shared", now: 99)
        set.bind(KeyEquivalent("+", .command), to: StandardCommands.ID.zoomIn, now: 100)
        let data = try set.exportJSON()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"format\" : \"wtkeys\""))
        #expect(text.contains("\"_comment\""))
        #expect(text.contains("\"command_id\" : \"view.zoomIn\""))
        #expect(text.contains("\"based_on\" : \"builtin.wiretuner\""))
        let imported = try ShortcutSet.importJSON(data)
        #expect(imported.warnings.isEmpty)
        #expect(imported.set == set)
        #expect(ShortcutSet.fileExtension == "wtkeys")
    }

    @Test func importSkipsBadKeysWithWarnings() throws {
        let json = """
        {"format":"wtkeys","version":1,"id":"u","name":"Hand edited","updated_at_ms":7,
         "bindings":[{"command_id":"file.new","keys":["cmd+n","cmd+bogus+n"]},{"command_id":"file.open","keys":["cmd+o"]}]}
        """
        let imported = try ShortcutSet.importJSON(Data(json.utf8))
        #expect(imported.warnings.count == 1)
        #expect(imported.warnings[0].hasPrefix("file.new: unknown modifier \"bogus\""))
        #expect(imported.set.keys(for: "file.new") == [KeyEquivalent("n", .command)])
        #expect(imported.set.keys(for: "file.open") == [KeyEquivalent("o", .command)])
        #expect(imported.set.basedOn == nil)
        #expect(imported.set.updatedAtMs == 7)
    }

    @Test func importRejectsOtherFiles() {
        #expect(throws: ShortcutSetImportError.wrongFormat("other")) {
            try ShortcutSet.importJSON(Data("{\"format\":\"other\",\"version\":1,\"id\":\"a\",\"name\":\"n\",\"updated_at_ms\":0,\"bindings\":[]}".utf8))
        }
        #expect(throws: ShortcutSetImportError.unsupportedVersion(2)) {
            try ShortcutSet.importJSON(Data("{\"format\":\"wtkeys\",\"version\":2,\"id\":\"a\",\"name\":\"n\",\"updated_at_ms\":0,\"bindings\":[]}".utf8))
        }
        #expect(throws: ShortcutSetImportError.self) { try ShortcutSet.importJSON(Data("not json".utf8)) }
    }

    @Test func codableUsesProtoFieldNames() throws {
        let set = ShortcutSet(id: "x", name: "X", basedOn: "builtin.wiretuner", bindings: [ShortcutBinding(commandID: "a", keys: [KeyEquivalent("a")])], updatedAtMs: 3)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = String(decoding: try encoder.encode(set), as: UTF8.self)
        #expect(text == "{\"based_on\":\"builtin.wiretuner\",\"bindings\":[{\"command_id\":\"a\",\"keys\":[\"a\"]}],\"id\":\"x\",\"name\":\"X\",\"updated_at_ms\":3}")
        #expect(try JSONDecoder().decode(ShortcutSet.self, from: Data(text.utf8)) == set)
    }
}
