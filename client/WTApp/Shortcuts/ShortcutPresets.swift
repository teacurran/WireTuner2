import Foundation

/// A built-in shortcut set other than WireTuner's own (customizing.adoc, "Shortcut sets"): the
/// keys it binds differently from the WireTuner set.  It is stored as a `.wtkeys` JSON resource
/// in the app bundle and applied over the WireTuner set, so a command the preset does not
/// mention keeps WireTuner's keys and a command registered by a later epic is covered without
/// editing every preset.
struct ShortcutPreset: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    /// The preset's bindings; an empty key list unbinds the command.
    var overrides: [ShortcutBinding]

    /// The full set: `base` with every override applied.  A key an override binds is first
    /// taken away from every other command, so the result has no duplicate the preset did not
    /// intend.
    func resolved(over base: ShortcutSet) -> ShortcutSet {
        var set = ShortcutSet(id: id, name: name, basedOn: base.id, bindings: base.bindings, updatedAtMs: 0)
        for override in overrides {
            for index in set.bindings.indices where set.bindings[index].commandID != override.commandID {
                set.bindings[index].keys.removeAll { override.keys.contains($0) }
            }
            if let index = set.bindings.firstIndex(where: { $0.commandID == override.commandID }) {
                set.bindings[index].keys = override.keys
            } else {
                set.bindings.append(override)
            }
        }
        return set
    }
}

/// Why a built-in resource could not be read.
enum BuiltInShortcutSetError: Error, Equatable {
    case missingResource(String)
    case badKeys(String, [String])
}

/// The four built-in sets: WireTuner's (derived from every command's default key) and the
/// Illustrator, QuarkXPress and Photoshop presets (bundle resources).
enum BuiltInShortcutSets {
    static let illustratorID = "builtin.illustrator"
    static let quarkXPressID = "builtin.quarkxpress"
    static let photoshopID = "builtin.photoshop"
    /// The resources, in the order the set pop-up lists them after WireTuner.
    static let presetIDs = [illustratorID, quarkXPressID, photoshopID]

    /// Reads one preset resource.  Unlike a user import, a key that does not parse is an
    /// error: a built-in set must be exact.
    static func preset(named id: String, bundle: Bundle = .main) throws -> ShortcutPreset {
        guard let url = bundle.url(forResource: id, withExtension: "json") else { throw BuiltInShortcutSetError.missingResource(id) }
        return try preset(data: Data(contentsOf: url))
    }

    static func preset(data: Data) throws -> ShortcutPreset {
        let imported = try ShortcutSet.importJSON(data)
        guard imported.warnings.isEmpty else { throw BuiltInShortcutSetError.badKeys(imported.set.id, imported.warnings) }
        return ShortcutPreset(id: imported.set.id, name: imported.set.name, overrides: imported.set.bindings)
    }

    /// Every preset in the bundle; a missing or broken resource is skipped (the validation
    /// test fails on it, so it never ships).
    static func bundledPresets(bundle: Bundle = .main) -> [ShortcutPreset] {
        presetIDs.compactMap { try? preset(named: $0, bundle: bundle) }
    }

    /// One line of a set's validation report: every registered command, bound or explicitly
    /// unbound, and whether the preset says so itself or inherits WireTuner's binding.
    struct ReportEntry: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            case preset
            case inherited
        }

        let commandID: CommandID
        let keys: [KeyEquivalent]
        let source: Source
    }

    struct Report: Equatable, Sendable {
        var entries: [ReportEntry]
        /// Ids the preset names that the registry does not know: the build-time failure.
        var unknownCommandIDs: [CommandID]
    }

    /// The validation report of `preset` against the registered `commands`.
    static func report(for preset: ShortcutPreset, commands: [Command]) -> Report {
        let resolved = preset.resolved(over: ShortcutSet.builtInDefault(commands: commands))
        let named = Set(preset.overrides.map(\.commandID))
        let known = Set(commands.map(\.id))
        let entries = commands.map { command in
            ReportEntry(commandID: command.id, keys: resolved.keys(for: command.id), source: named.contains(command.id) ? .preset : .inherited)
        }
        return Report(entries: entries, unknownCommandIDs: preset.overrides.map(\.commandID).filter { !known.contains($0) })
    }
}

extension ShortcutSet {
    /// This set with bindings for the commands it says nothing about, taken from `base`, minus
    /// any key this set already uses (a user set made before a command was registered).
    func fillingMissing(from base: ShortcutSet) -> ShortcutSet {
        var result = self
        let present = Set(commandIDs)
        var used = Set(bindings.flatMap(\.keys))
        for binding in base.bindings where !present.contains(binding.commandID) {
            let keys = binding.keys.filter { !used.contains($0) }
            used.formUnion(keys)
            result.bindings.append(ShortcutBinding(commandID: binding.commandID, keys: keys))
        }
        return result
    }
}
