import Foundation
import WTProto

/// The keyboard shortcut sets as a synced preference (customizing.adoc, "Merge semantics";
/// BASIC-028): one entry, `sync.shortcut_sets`, whose `ShortcutSets` value is merged per set id
/// rather than replaced whole.  Of two versions of one set the greater `updated_at_ms` wins (the
/// incoming one on ties); deleting a set writes a tombstone that competes the same way, so a Mac
/// that was offline does not bring a deleted set back, and tombstones are dropped 30 days after
/// they were written; `active_set_id` is newest-wins on its own stamp.  The server runs the same
/// merge in `SetPreferences`; `PreferenceSync` runs it on its outbox, so several changes queued
/// while offline travel as one entry and a queued set the server has newer is dropped.
///
/// A device applies a merged value with `apply(_:to:active:)`: every set that is newer than the
/// device's own copy replaces it, every newer tombstone deletes it.
public enum ShortcutSetSync {
    public typealias Sets = Wiretuner_Account_V1_ShortcutSets
    public typealias Item = Wiretuner_Account_V1_ShortcutSet

    /// The preference id.
    public static let key = "sync.shortcut_sets"
    /// How long a tombstone is kept, in milliseconds.
    public static let tombstoneLifetimeMs: Int64 = 30 * 24 * 60 * 60 * 1000

    /// Two set lists merged per set id (in id order), tombstones older than the lifetime at `now`
    /// left out, and the newer choice of active set (`changes`' on a tie, when it carries one).
    public static func merge(_ stored: Sets, _ changes: Sets, now: Int64) -> Sets {
        var byID: [String: Item] = [:]
        for set in stored.sets + changes.sets {
            if let existing = byID[set.id], existing.updatedAtMs > set.updatedAtMs { continue }
            byID[set.id] = set
        }
        var out = Sets()
        out.sets = byID.keys.sorted().compactMap { id in
            let set = byID[id]!
            return set.deleted && now - set.updatedAtMs >= tombstoneLifetimeMs ? nil : set
        }
        let active = changes.activeSetUpdatedAtMs > 0 && changes.activeSetUpdatedAtMs >= stored.activeSetUpdatedAtMs ? changes : stored
        out.activeSetID = active.activeSetID
        out.activeSetUpdatedAtMs = active.activeSetUpdatedAtMs
        return out
    }

    /// One preference entry merged with a later one as the server merges it: two shortcut set
    /// values per set (stamped with the newer of the two), anything else newest-wins (`incoming` on
    /// a tie).
    public static func merge(_ current: Wiretuner_Account_V1_PreferenceValue?, _ incoming: Wiretuner_Account_V1_PreferenceValue,
                             now: Int64) -> Wiretuner_Account_V1_PreferenceValue {
        guard let current else { return incoming }
        if case .shortcutSetsValue(let stored)? = current.value, case .shortcutSetsValue(let changes)? = incoming.value {
            var merged = incoming
            merged.shortcutSetsValue = merge(stored, changes, now: now)
            merged.updatedAtMs = max(current.updatedAtMs, incoming.updatedAtMs)
            return merged
        }
        return incoming.updatedAtMs >= current.updatedAtMs ? incoming : current
    }

    /// `queued` with every set `server` holds at the same or a newer stamp left out, and the
    /// choice of active set left out when the server's is as new; nil when nothing is left to send.
    public static func unsent(_ queued: Sets, after server: Sets) -> Sets? {
        let known = Dictionary(server.sets.map { ($0.id, $0.updatedAtMs) }) { max($0, $1) }
        var out = Sets()
        out.sets = queued.sets.filter { set in known[set.id].map { $0 < set.updatedAtMs } ?? true }
        if queued.activeSetUpdatedAtMs > server.activeSetUpdatedAtMs {
            out.activeSetID = queued.activeSetID
            out.activeSetUpdatedAtMs = queued.activeSetUpdatedAtMs
        }
        return out.sets.isEmpty && out.activeSetUpdatedAtMs == 0 ? nil : out
    }

    /// The value to queue for a change on this Mac: the changed sets (tombstones for deleted
    /// ones) and, when the choice changed, the active set.
    public static func entry(_ sets: [Item], active: (id: String, at: Int64)? = nil) -> Wiretuner_Account_V1_PreferenceValue {
        var value = Sets()
        value.sets = sets
        if let active {
            value.activeSetID = active.id
            value.activeSetUpdatedAtMs = active.at
        }
        var entry = Wiretuner_Account_V1_PreferenceValue()
        entry.shortcutSetsValue = value
        return entry
    }

    /// A tombstone for set `id`, deleted at `at`.
    public static func tombstone(_ id: String, at: Int64) -> Item {
        var set = Item()
        set.id = id
        set.deleted = true
        set.updatedAtMs = at
        return set
    }

    /// The outcome of applying a merged value on one device.
    public struct Applied: Equatable, Sendable {
        /// The device's live sets afterwards, in their previous order with new ones appended.
        public var sets: [Item]
        /// The active set id afterwards and when it was chosen.
        public var activeSetID: String
        public var activeSetUpdatedAtMs: Int64
        /// Whether anything changed.
        public var changed: Bool
    }

    /// `remote` applied to a device's live sets `local` and its choice `active`: a set newer than
    /// the local copy (or unknown here) replaces or joins it, a tombstone newer than the local copy
    /// deletes it, a local set the value does not mention stays (it may not have been sent yet), and
    /// the newer choice of active set wins.  An active set that no longer exists falls back to
    /// `fallback` (WireTuner's set).
    public static func apply(_ remote: Sets, to local: [Item], active: (id: String, at: Int64), fallback: String) -> Applied {
        var sets = local
        var changed = false
        for set in remote.sets {
            let index = sets.firstIndex { $0.id == set.id }
            if let index, sets[index].updatedAtMs >= set.updatedAtMs { continue }
            if set.deleted {
                guard let index else { continue }
                sets.remove(at: index)
            } else if let index {
                sets[index] = set
            } else {
                sets.append(set)
            }
            changed = true
        }
        var chosen = active
        if remote.activeSetUpdatedAtMs > active.at {
            chosen = (remote.activeSetID, remote.activeSetUpdatedAtMs)
            changed = changed || remote.activeSetID != active.id
        }
        if !chosen.id.hasPrefix("builtin."), !sets.contains(where: { $0.id == chosen.id }) {
            changed = changed || chosen.id != fallback
            chosen.id = fallback
        }
        return Applied(sets: sets, activeSetID: chosen.id, activeSetUpdatedAtMs: chosen.at, changed: changed)
    }
}
