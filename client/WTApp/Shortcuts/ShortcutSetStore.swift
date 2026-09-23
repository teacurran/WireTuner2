import Foundation

/// The shortcut sets on this Mac and which one is active (customizing.adoc, `ShortcutSets`):
/// the built-in sets, resolved against the registry on demand, and the user's own sets, kept in
/// `Application Support/WireTuner/ShortcutSets.json` until BASIC-028 syncs them with the
/// account.  Every change calls `onChange`, which rebuilds the menu bar, so switching or editing
/// a set rebinds every menu item and tool shortcut without relaunch.
@MainActor
final class ShortcutSetStore {
    static let fileName = "ShortcutSets.json"
    /// `ShortcutSets.sets` holds at most 32 sets (preferences.proto).
    static let maximumUserSets = 32
    static let maximumNameLength = 64

    enum Failure: Error, Equatable {
        case tooManySets
        case unknownSet(String)
        case builtInSet(String)
        case invalidName
    }

    /// The file's shape: the proto's `ShortcutSets`.
    struct File: Codable, Equatable {
        var activeSetID: String
        var sets: [ShortcutSet]

        enum CodingKeys: String, CodingKey {
            case activeSetID = "active_set_id"
            case sets
        }
    }

    /// One entry of the set pop-up.
    struct Summary: Equatable, Sendable {
        let id: String
        let name: String
        let isBuiltIn: Bool
    }

    let url: URL?
    let presets: [ShortcutPreset]
    /// The registered commands, read whenever a set is resolved.
    var commands: @MainActor () -> [Command] = { [] }
    var onChange: (@MainActor () -> Void)?
    private(set) var userSets: [ShortcutSet] = []
    private(set) var activeSetID = ShortcutSet.defaultID
    private(set) var lastSaveError: (any Error)?

    /// - Parameter url: the file; nil keeps the sets in memory (tests).
    init(url: URL?, presets: [ShortcutPreset] = BuiltInShortcutSets.bundledPresets()) {
        self.url = url
        self.presets = presets
        load()
    }

    static var defaultURL: URL {
        WindowStateStore.defaultURL.deletingLastPathComponent().appending(path: fileName)
    }

    // MARK: Sets

    var summaries: [Summary] {
        [Summary(id: ShortcutSet.defaultID, name: ShortcutSet.defaultName, isBuiltIn: true)]
            + presets.map { Summary(id: $0.id, name: $0.name, isBuiltIn: true) }
            + userSets.map { Summary(id: $0.id, name: $0.name, isBuiltIn: false) }
    }

    func contains(_ id: String) -> Bool { summaries.contains { $0.id == id } }

    var defaultSet: ShortcutSet { ShortcutSet.builtInDefault(commands: commands()) }

    /// The complete set `id` names, resolved against the registered commands; nil for an
    /// unknown id.
    func resolvedSet(_ id: String) -> ShortcutSet? {
        resolve(id, base: defaultSet, visited: [])
    }

    /// A user set fills its gaps from the set it was copied from (a cycle of copies stops at
    /// WireTuner's).
    private func resolve(_ id: String, base: ShortcutSet, visited: Set<String>) -> ShortcutSet? {
        if id == ShortcutSet.defaultID { return base }
        if let preset = presets.first(where: { $0.id == id }) { return preset.resolved(over: base) }
        guard let user = userSets.first(where: { $0.id == id }) else { return nil }
        let seen = visited.union([id])
        let origin = user.basedOn.flatMap { seen.contains($0) ? nil : resolve($0, base: base, visited: seen) } ?? base
        return user.fillingMissing(from: origin)
    }

    /// The active set, resolved; WireTuner's when the active id no longer exists.
    var activeSet: ShortcutSet { resolvedSet(activeSetID) ?? defaultSet }

    var isActiveSetBuiltIn: Bool { activeSetID.hasPrefix(ShortcutSet.builtInIDPrefix) }

    func activate(_ id: String) throws {
        guard contains(id) else { throw Failure.unknownSet(id) }
        activeSetID = id
        didChange()
    }

    /// A new user set copied from `id` (resolved, so it is complete), made active.
    @discardableResult
    func makeCopy(of id: String, name: String) throws -> ShortcutSet {
        guard let source = resolvedSet(id) else { throw Failure.unknownSet(id) }
        let name = try validName(name)
        guard userSets.count < Self.maximumUserSets else { throw Failure.tooManySets }
        let copy = source.copy(name: name)
        userSets.append(copy)
        activeSetID = copy.id
        didChange()
        return copy
    }

    /// "WireTuner Copy", "WireTuner Copy 2", ...
    func copyName(for id: String) -> String {
        let base = "\(summaries.first { $0.id == id }?.name ?? ShortcutSet.defaultName) Copy"
        var name = base
        var number = 2
        while summaries.contains(where: { $0.name == name }) {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    func rename(_ id: String, to name: String) throws {
        let name = try validName(name)
        let index = try userIndex(id)
        userSets[index].name = name
        userSets[index].updatedAtMs = ShortcutSet.nowMs()
        didChange()
    }

    /// Deletes a user set; deleting the active set switches to WireTuner's.
    func delete(_ id: String) throws {
        let index = try userIndex(id)
        userSets.remove(at: index)
        if activeSetID == id { activeSetID = ShortcutSet.defaultID }
        didChange()
    }

    /// Replaces the user set with `set.id`.
    func update(_ set: ShortcutSet) throws {
        let index = try userIndex(set.id)
        userSets[index] = set
        didChange()
    }

    /// Imports a `.wtkeys` file as a new user set (a fresh id when the file's id is taken or
    /// built in) and returns the import with its warnings.  The set is not activated.
    @discardableResult
    func importSet(_ data: Data) throws -> ShortcutSetImport {
        var imported = try ShortcutSet.importJSON(data)
        guard userSets.count < Self.maximumUserSets else { throw Failure.tooManySets }
        if imported.set.isBuiltIn || contains(imported.set.id) { imported.set.id = UUID().uuidString }
        imported.set.name = (try? validName(imported.set.name)) ?? copyName(for: ShortcutSet.defaultID)
        userSets.append(imported.set)
        didChange()
        return imported
    }

    private func userIndex(_ id: String) throws -> Int {
        if let index = userSets.firstIndex(where: { $0.id == id }) { return index }
        throw contains(id) ? Failure.builtInSet(id) : Failure.unknownSet(id)
    }

    private func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumNameLength else { throw Failure.invalidName }
        return trimmed
    }

    // MARK: Snapshot (Revert)

    var snapshot: File { File(activeSetID: activeSetID, sets: userSets) }

    func restore(_ snapshot: File) {
        userSets = snapshot.sets
        activeSetID = snapshot.activeSetID
        didChange()
    }

    // MARK: Persistence

    private func didChange() {
        save()
        onChange?()
    }

    /// Reads the file; a missing or unreadable one leaves WireTuner's set active and no user
    /// sets.
    func load() {
        guard let url, let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        userSets = file.sets
        activeSetID = file.activeSetID
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = error
        }
    }
}
