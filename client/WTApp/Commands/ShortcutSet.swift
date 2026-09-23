import Foundation

/// The keys bound to one command.  `keys` may be empty: an explicitly unbound command, which
/// the built-in sets list so validation can tell "unbound on purpose" from "forgotten".
struct ShortcutBinding: Codable, Equatable, Sendable {
    var commandID: CommandID
    /// Canonical key strings; the first one shows in the menu.
    var keys: [KeyEquivalent]

    enum CodingKeys: String, CodingKey {
        case commandID = "command_id"
        case keys
    }
}

/// A named set of bindings (Customizing page: `ShortcutSet` in `preferences.proto`).  Built-in
/// sets have ids under `builtin.`; user sets are full copies with a UUID id and `basedOn`
/// naming the set they were copied from.
struct ShortcutSet: Codable, Equatable, Sendable, Identifiable {
    static let builtInIDPrefix = "builtin."
    static let defaultID = "builtin.wiretuner"
    static let defaultName = "WireTuner"
    static let fileExtension = "wtkeys"

    var id: String
    var name: String
    var basedOn: String?
    var bindings: [ShortcutBinding]
    var updatedAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, bindings
        case basedOn = "based_on"
        case updatedAtMs = "updated_at_ms"
    }

    init(id: String, name: String, basedOn: String? = nil, bindings: [ShortcutBinding] = [], updatedAtMs: Int64 = 0) {
        self.id = id
        self.name = name
        self.basedOn = basedOn
        self.bindings = bindings
        self.updatedAtMs = updatedAtMs
    }

    var isBuiltIn: Bool { id.hasPrefix(Self.builtInIDPrefix) }

    /// The built-in default set, derived from every command's `defaultKey`: one binding per
    /// command, bound or explicitly unbound, in registration order.
    static func builtInDefault(commands: [Command]) -> ShortcutSet {
        ShortcutSet(
            id: defaultID, name: defaultName,
            bindings: commands.map { ShortcutBinding(commandID: $0.id, keys: ($0.defaultKey.map { [$0] } ?? []) + $0.alternateKeys) }
        )
    }

    /// A user-editable copy of this set.
    func copy(id: String = UUID().uuidString, name: String, now: Int64 = Self.nowMs()) -> ShortcutSet {
        ShortcutSet(id: id, name: name, basedOn: self.id, bindings: bindings, updatedAtMs: now)
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: Lookup

    func keys(for commandID: CommandID) -> [KeyEquivalent] {
        bindings.first { $0.commandID == commandID }?.keys ?? []
    }

    /// The key shown in the menu for `commandID`.
    func keyEquivalent(for commandID: CommandID) -> KeyEquivalent? {
        keys(for: commandID).first
    }

    func commandIDs(for key: KeyEquivalent) -> [CommandID] {
        bindings.filter { $0.keys.contains(key) }.map(\.commandID)
    }

    var commandIDs: [CommandID] { bindings.map(\.commandID) }

    // MARK: Editing

    /// Binds `key` to `commandID`, appending to the command's keys.  With `replacingExisting`
    /// the key is first taken away from every other command, as the editor's Assign does;
    /// without it a duplicate is kept and `conflicts()` reports it.
    mutating func bind(_ key: KeyEquivalent, to commandID: CommandID, replacingExisting: Bool = true, now: Int64 = Self.nowMs()) {
        if replacingExisting {
            for index in bindings.indices where bindings[index].commandID != commandID {
                bindings[index].keys.removeAll { $0 == key }
            }
        }
        if let index = bindings.firstIndex(where: { $0.commandID == commandID }) {
            if !bindings[index].keys.contains(key) { bindings[index].keys.append(key) }
        } else {
            bindings.append(ShortcutBinding(commandID: commandID, keys: [key]))
        }
        updatedAtMs = now
    }

    /// Removes `key` from `commandID`; the binding stays, explicitly unbound, when empty.
    mutating func unbind(_ key: KeyEquivalent, from commandID: CommandID, now: Int64 = Self.nowMs()) {
        guard let index = bindings.firstIndex(where: { $0.commandID == commandID }) else { return }
        bindings[index].keys.removeAll { $0 == key }
        updatedAtMs = now
    }

    mutating func unbindAll(from commandID: CommandID, now: Int64 = Self.nowMs()) {
        if let index = bindings.firstIndex(where: { $0.commandID == commandID }) {
            bindings[index].keys = []
        } else {
            bindings.append(ShortcutBinding(commandID: commandID, keys: []))
        }
        updatedAtMs = now
    }

    // MARK: Validation

    /// Duplicate bindings (one key on several commands) and bindings to macOS-reserved keys
    /// by a command other than the key's standard owner.
    func conflicts(reserved: ReservedShortcuts = .macOS) -> [ShortcutConflict] {
        var owners: [KeyEquivalent: [CommandID]] = [:]
        for binding in bindings {
            for key in binding.keys where !owners[key, default: []].contains(binding.commandID) {
                owners[key, default: []].append(binding.commandID)
            }
        }
        var result: [ShortcutConflict] = []
        for key in owners.keys.sorted(by: { $0.canonical < $1.canonical }) {
            let commands = owners[key]!
            if commands.count > 1 {
                result.append(ShortcutConflict(key: key, kind: .duplicate, commandIDs: commands))
            }
            let intruders = commands.filter { reserved.isReserved(key, against: $0) }
            if !intruders.isEmpty {
                result.append(ShortcutConflict(key: key, kind: .reserved, commandIDs: intruders))
            }
        }
        return result
    }

    /// Command ids in this set that the registry does not know.
    func unknownCommandIDs(knownIDs: Set<CommandID>) -> [CommandID] {
        bindings.map(\.commandID).filter { !knownIDs.contains($0) }
    }

    /// Registered commands this set says nothing about (neither bound nor explicitly unbound).
    func missingCommandIDs(registeredIDs: [CommandID]) -> [CommandID] {
        let present = Set(commandIDs)
        return registeredIDs.filter { !present.contains($0) }
    }

    // MARK: .wtkeys export and import

    /// The `.wtkeys` file: the set as JSON with a header naming the format and version.
    func exportJSON() throws -> Data {
        let file = ShortcutSetFile(
            comment: ShortcutSetFile.comment, format: ShortcutSetFile.format, version: ShortcutSetFile.version,
            id: id, name: name, basedOn: basedOn, updatedAtMs: updatedAtMs,
            bindings: bindings.map { ShortcutSetFile.Binding(commandID: $0.commandID.rawValue, keys: $0.keys.map(\.canonical)) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// Reads a `.wtkeys` file.  A binding whose key string does not parse is dropped with a
    /// warning naming the command and the string, and the rest of the file is imported.
    static func importJSON(_ data: Data) throws -> ShortcutSetImport {
        let file: ShortcutSetFile
        do {
            file = try JSONDecoder().decode(ShortcutSetFile.self, from: data)
        } catch {
            throw ShortcutSetImportError.malformed("\(error)")
        }
        guard file.format == ShortcutSetFile.format else { throw ShortcutSetImportError.wrongFormat(file.format) }
        guard file.version == ShortcutSetFile.version else { throw ShortcutSetImportError.unsupportedVersion(file.version) }
        var warnings: [String] = []
        let bindings = file.bindings.map { raw -> ShortcutBinding in
            let keys = raw.keys.compactMap { string -> KeyEquivalent? in
                do {
                    return try KeyEquivalent(parsing: string)
                } catch {
                    warnings.append("\(raw.commandID): \(error)")
                    return nil
                }
            }
            return ShortcutBinding(commandID: CommandID(raw.commandID), keys: keys)
        }
        let set = ShortcutSet(id: file.id, name: file.name, basedOn: file.basedOn, bindings: bindings, updatedAtMs: file.updatedAtMs)
        return ShortcutSetImport(set: set, warnings: warnings)
    }
}

struct ShortcutSetImport: Equatable, Sendable {
    var set: ShortcutSet
    var warnings: [String]
}

enum ShortcutSetImportError: Error, Equatable {
    case malformed(String)
    case wrongFormat(String)
    case unsupportedVersion(Int)
}

/// The on-disk shape of a `.wtkeys` file.  Keys stay strings here so a bad one can be reported
/// instead of failing the whole file.
struct ShortcutSetFile: Codable, Equatable {
    static let format = "wtkeys"
    static let version = 1
    static let comment = "WireTuner shortcut set. Keys are cmd/ctrl/opt/shift + key, e.g. \"cmd+shift+k\"."

    struct Binding: Codable, Equatable {
        var commandID: String
        var keys: [String]

        enum CodingKeys: String, CodingKey {
            case commandID = "command_id"
            case keys
        }
    }

    var comment: String?
    var format: String
    var version: Int
    var id: String
    var name: String
    var basedOn: String?
    var updatedAtMs: Int64
    var bindings: [Binding]

    enum CodingKeys: String, CodingKey {
        case comment = "_comment"
        case format, version, id, name, bindings
        case basedOn = "based_on"
        case updatedAtMs = "updated_at_ms"
    }
}

/// One problem in a shortcut set.
struct ShortcutConflict: Equatable, Sendable, CustomStringConvertible {
    enum Kind: Equatable, Sendable {
        /// The key is bound to more than one command.
        case duplicate
        /// The key is reserved by macOS (or by its standard owner) and bound to another command.
        case reserved
    }

    let key: KeyEquivalent
    let kind: Kind
    let commandIDs: [CommandID]

    var description: String {
        let commands = commandIDs.map(\.rawValue).joined(separator: ", ")
        switch kind {
        case .duplicate: return "\(key.canonical) is bound to \(commands)"
        case .reserved: return "\(key.canonical) is reserved by macOS but bound to \(commands)"
        }
    }
}

/// Keys the user cannot assign.  Each maps to the command that legitimately owns it (Quit owns
/// Command-Q) or to `nil` when no command may take it (Command-Tab).  The list is explicit, as
/// the Customizing page requires; `NSEvent` is not consulted.
struct ReservedShortcuts: Sendable {
    var owners: [KeyEquivalent: CommandID?]

    static let macOS = ReservedShortcuts(owners: [
        KeyEquivalent("tab", .command): nil,
        KeyEquivalent("tab", [.command, .shift]): nil,
        KeyEquivalent("space", .command): nil,
        KeyEquivalent("space", [.command, .option]): nil,
        KeyEquivalent("escape", [.command, .option]): nil,
        KeyEquivalent("3", [.command, .shift]): nil,
        KeyEquivalent("4", [.command, .shift]): nil,
        KeyEquivalent("5", [.command, .shift]): nil,
        KeyEquivalent("q", .command): StandardCommands.ID.quit,
        KeyEquivalent("h", .command): StandardCommands.ID.hide,
        KeyEquivalent("h", [.command, .option]): StandardCommands.ID.hideOthers,
        KeyEquivalent(",", .command): StandardCommands.ID.settings,
    ])

    func isReserved(_ key: KeyEquivalent) -> Bool { owners[key] != nil }

    /// `true` when `key` is reserved and `commandID` is not its owner.
    func isReserved(_ key: KeyEquivalent, against commandID: CommandID) -> Bool {
        guard let owner = owners[key] else { return false }
        return owner != commandID
    }
}
