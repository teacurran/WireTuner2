import Foundation
import WTProto
import WTSync

/// The shortcut sets on this Mac and which one is active (customizing.adoc, `ShortcutSets`):
/// the built-in sets, resolved against the registry on demand, and the user's own sets, kept in
/// `Application Support/WireTuner/ShortcutSets.json`.  Every change calls `onChange`, which
/// rebuilds the menu bar, so switching or editing a set rebinds every menu item and tool shortcut
/// without relaunch.
///
/// Sync (BASIC-028): every change made here also hands `onSyncChange` the `sync.shortcut_sets`
/// entry to queue -- the changed sets, only their bindings that differ from the set each was
/// copied from, a tombstone for a deleted one, and the active set when the choice changed -- and
/// `applySynced(_:)` takes the account's merged value (`ShortcutSetSync.apply`: newer sets replace
/// or join, newer tombstones delete, the newer choice of set wins).
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
        /// When the active set was chosen (absent in files written before BASIC-028).
        var activeSetUpdatedAtMs: Int64?

        enum CodingKeys: String, CodingKey {
            case activeSetID = "active_set_id"
            case sets
            case activeSetUpdatedAtMs = "active_set_updated_at_ms"
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
    /// The `sync.shortcut_sets` entry of each change made on this Mac, for `PreferenceSync.enqueue`.
    var onSyncChange: (@MainActor (Wiretuner_Account_V1_PreferenceValue) -> Void)?
    /// The wall clock in milliseconds.
    var now: @MainActor () -> Int64 = { ShortcutSet.nowMs() }
    private(set) var userSets: [ShortcutSet] = []
    private(set) var activeSetID = ShortcutSet.defaultID
    /// When `activeSetID` was chosen; 0 when never.
    private(set) var activeSetUpdatedAtMs: Int64 = 0
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
        activeSetUpdatedAtMs = now()
        didChange(synced: [])
    }

    /// A new user set copied from `id` (resolved, so it is complete), made active.
    @discardableResult
    func makeCopy(of id: String, name: String) throws -> ShortcutSet {
        guard let source = resolvedSet(id) else { throw Failure.unknownSet(id) }
        let name = try validName(name)
        guard userSets.count < Self.maximumUserSets else { throw Failure.tooManySets }
        let copy = source.copy(name: name, now: now())
        userSets.append(copy)
        activeSetID = copy.id
        activeSetUpdatedAtMs = copy.updatedAtMs
        didChange(synced: [copy.id])
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
        userSets[index].updatedAtMs = now()
        didChange(synced: [id], activeChanged: false)
    }

    /// Deletes a user set; deleting the active set switches to WireTuner's.
    func delete(_ id: String) throws {
        let index = try userIndex(id)
        userSets.remove(at: index)
        let stamp = now()
        let wasActive = activeSetID == id
        if wasActive {
            activeSetID = ShortcutSet.defaultID
            activeSetUpdatedAtMs = stamp
        }
        didChange(synced: [], tombstones: [ShortcutSetSync.tombstone(id, at: stamp)], activeChanged: wasActive)
    }

    /// Replaces the user set with `set.id`.
    func update(_ set: ShortcutSet) throws {
        let index = try userIndex(set.id)
        userSets[index] = set
        didChange(synced: [set.id], activeChanged: false)
    }

    /// Imports a `.wtkeys` file as a new user set (a fresh id when the file's id is taken or
    /// built in) and returns the import with its warnings.  The set is not activated.
    @discardableResult
    func importSet(_ data: Data) throws -> ShortcutSetImport {
        var imported = try ShortcutSet.importJSON(data)
        guard userSets.count < Self.maximumUserSets else { throw Failure.tooManySets }
        if imported.set.isBuiltIn || contains(imported.set.id) { imported.set.id = UUID().uuidString }
        imported.set.name = (try? validName(imported.set.name)) ?? copyName(for: ShortcutSet.defaultID)
        imported.set.updatedAtMs = now()
        userSets.append(imported.set)
        didChange(synced: [imported.set.id], activeChanged: false)
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

    var snapshot: File { File(activeSetID: activeSetID, sets: userSets, activeSetUpdatedAtMs: activeSetUpdatedAtMs) }

    /// Puts the sets back as `snapshot` had them.  To sync, that is a new edit: each set that
    /// differs is stamped now, each set the snapshot lacks is deleted.
    func restore(_ snapshot: File) {
        let stamp = now()
        let before = Dictionary(userSets.map { ($0.id, $0) }) { first, _ in first }
        var changed: [String] = []
        userSets = snapshot.sets.map { set in
            guard before[set.id] != set else { return set }
            var restamped = set
            restamped.updatedAtMs = stamp
            changed.append(set.id)
            return restamped
        }
        let kept = Set(userSets.map(\.id))
        let tombstones = before.keys.sorted().filter { !kept.contains($0) }.map { ShortcutSetSync.tombstone($0, at: stamp) }
        let activeChanged = activeSetID != snapshot.activeSetID
        activeSetID = snapshot.activeSetID
        if activeChanged { activeSetUpdatedAtMs = stamp }
        didChange(synced: changed, tombstones: tombstones, activeChanged: activeChanged)
    }

    // MARK: Sync (BASIC-028)

    /// `set` as synced: only the bindings that differ from the set it was copied from (an empty
    /// key list unbinds), so a set costs what it changes in the account's 64 KiB of preferences.
    func synced(_ set: ShortcutSet) -> ShortcutSetSync.Item {
        let origin = set.basedOn.flatMap { $0 == set.id ? nil : resolvedSet($0) } ?? defaultSet
        let originKeys = Dictionary(origin.bindings.map { ($0.commandID, $0.keys) }) { first, _ in first }
        var item = ShortcutSetSync.Item()
        item.id = set.id
        item.name = set.name
        item.basedOn = set.basedOn ?? ""
        item.updatedAtMs = max(set.updatedAtMs, 1)
        item.bindings = set.bindings.filter { originKeys[$0.commandID] != $0.keys }.map { binding in
            Wiretuner_Account_V1_Binding.with {
                $0.commandID = binding.commandID.rawValue
                $0.keys = binding.keys.map(\.canonical)
            }
        }
        return item
    }

    /// Every user set and the active set, for the first sync of this Mac's sets (sync turned on).
    var syncValue: Wiretuner_Account_V1_PreferenceValue {
        ShortcutSetSync.entry(userSets.map(synced), active: (activeSetID, max(activeSetUpdatedAtMs, 1)))
    }

    /// A set the account sent, as this Mac keeps it (a key string that does not parse is dropped).
    static func local(_ item: ShortcutSetSync.Item) -> ShortcutSet {
        ShortcutSet(id: item.id, name: item.name, basedOn: item.basedOn.isEmpty ? nil : item.basedOn,
                    bindings: item.bindings.map { ShortcutBinding(commandID: CommandID($0.commandID), keys: $0.keys.compactMap { try? KeyEquivalent(parsing: $0) }) },
                    updatedAtMs: item.updatedAtMs)
    }

    /// Applies the account's merged `sync.shortcut_sets` value; nothing is sent back.
    func applySynced(_ remote: ShortcutSetSync.Sets) {
        let mine = Dictionary(userSets.map { ($0.id, $0) }) { first, _ in first }
        let applied = ShortcutSetSync.apply(remote, to: userSets.map(synced), active: (activeSetID, activeSetUpdatedAtMs),
                                            fallback: ShortcutSet.defaultID)
        guard applied.changed else { return }
        userSets = applied.sets.prefix(Self.maximumUserSets).map { item in
            if let local = mine[item.id], max(local.updatedAtMs, 1) == item.updatedAtMs { return local }
            return Self.local(item)
        }
        activeSetID = contains(applied.activeSetID) ? applied.activeSetID : ShortcutSet.defaultID
        activeSetUpdatedAtMs = applied.activeSetUpdatedAtMs
        save()
        onChange?()
    }

    // MARK: Persistence

    /// Saves, rebuilds, and hands the sync entry of the change to `onSyncChange`.
    private func didChange(synced ids: [String], tombstones: [ShortcutSetSync.Item] = [], activeChanged: Bool = true) {
        save()
        onChange?()
        guard let onSyncChange else { return }
        let sets = userSets.filter { ids.contains($0.id) }.map(synced) + tombstones
        guard !sets.isEmpty || activeChanged else { return }
        onSyncChange(ShortcutSetSync.entry(sets, active: activeChanged ? (activeSetID, max(activeSetUpdatedAtMs, 1)) : nil))
    }

    /// Reads the file; a missing or unreadable one leaves WireTuner's set active and no user
    /// sets.
    func load() {
        guard let url, let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        userSets = file.sets
        activeSetID = file.activeSetID
        activeSetUpdatedAtMs = file.activeSetUpdatedAtMs ?? 0
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
