import Foundation

/// One remembered choice: the query it was chosen for, the item, how often, and when last.
struct PaletteHistoryEntry: Codable, Equatable, Sendable {
    var queryPrefix: String
    var itemID: String
    var count: Int
    var lastUsedMs: Int64

    enum CodingKeys: String, CodingKey {
        case queryPrefix = "query_prefix"
        case itemID = "item_id"
        case count
        case lastUsedMs = "last_used_ms"
    }
}

/// What the palette ran on this Mac (customizing.adoc, "Data model"):
/// `Application Support/WireTuner/palette-recents.json`, at most 500 entries, never synced.  An
/// item chosen for a query ranks higher for that query and every longer one that starts with it,
/// decaying with age.
@MainActor
final class PaletteHistory {
    static let fileName = "palette-recents.json"
    static let capacity = 500
    /// A choice counts half as much after this many days.
    static let halfLifeDays = 30.0
    static let msPerDay = 86_400_000.0

    let url: URL?
    private(set) var entries: [PaletteHistoryEntry] = []
    private(set) var lastSaveError: (any Error)?

    /// - Parameter url: the file; nil keeps the history in memory (tests).
    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([PaletteHistoryEntry].self, from: data) {
            entries = Array(saved.prefix(Self.capacity))
        }
    }

    static var defaultURL: URL {
        WindowStateStore.defaultURL.deletingLastPathComponent().appending(path: fileName)
    }

    /// The history key for a query: folded, spaces collapsed.
    static func normalize(_ query: String) -> String {
        FuzzyCandidate.fold(query).split(separator: " ").joined(separator: " ")
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// `itemID` was run for `query`: its entry counts one more, and the least recently used
    /// entries beyond the capacity are dropped.
    func record(query: String, itemID: String, now: Int64 = PaletteHistory.nowMs()) {
        let prefix = Self.normalize(query)
        if let index = entries.firstIndex(where: { $0.queryPrefix == prefix && $0.itemID == itemID }) {
            entries[index].count += 1
            entries[index].lastUsedMs = now
        } else {
            entries.append(PaletteHistoryEntry(queryPrefix: prefix, itemID: itemID, count: 1, lastUsedMs: now))
        }
        if entries.count > Self.capacity {
            entries.sort { $0.lastUsedMs > $1.lastUsedMs }
            entries.removeLast(entries.count - Self.capacity)
        }
        save()
    }

    /// Each item's recent score for `query`: the decayed counts of its entries whose query is a
    /// prefix of this one.
    func scores(for query: String, now: Int64 = PaletteHistory.nowMs()) -> [String: Double] {
        let normalized = Self.normalize(query)
        var result: [String: Double] = [:]
        for entry in entries where normalized.hasPrefix(entry.queryPrefix) {
            let ageDays = max(Double(now - entry.lastUsedMs), 0) / Self.msPerDay
            result[entry.itemID, default: 0] += Double(entry.count) * pow(0.5, ageDays / Self.halfLifeDays)
        }
        return result
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = error
        }
    }
}
