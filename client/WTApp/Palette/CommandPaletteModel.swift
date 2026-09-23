import Foundation
import Observation

/// A palette row with its ranking.
struct PaletteResult: Identifiable, Sendable {
    let item: PaletteItem
    let score: Double

    var id: String { item.id }
}

/// The palette's keyboard: kbd:[Up], kbd:[Down], kbd:[Return], kbd:[Esc].
enum PaletteKey: Sendable {
    case up, down, run, dismiss
}

/// The command palette's search (customizing.adoc, "Command palette"; BASIC-033): the
/// registered sources, the query, the ranked results and the selection.  Ranking is
/// `recentScore × 4 + matchScore`; disabled items list last.
@MainActor
@Observable
final class CommandPaletteModel {
    static let recentWeight = 4.0
    static let resultLimit = 60

    @ObservationIgnored let history: PaletteHistory
    @ObservationIgnored private(set) var sources: [(id: String, source: any PaletteSource)] = []
    /// Each item's prepared title and title-plus-subtitle, by item id, so a keystroke does not
    /// fold every title again.
    @ObservationIgnored private var candidates: [String: PreparedItem] = [:]
    @ObservationIgnored var now: @MainActor () -> Int64 = { PaletteHistory.nowMs() }
    /// Called before an item runs (the panel closes and focus returns to the window).
    @ObservationIgnored var onRun: @MainActor () -> Void = {}
    /// Esc.
    @ObservationIgnored var onDismiss: @MainActor () -> Void = {}

    var query = "" {
        didSet { rerank() }
    }
    /// The sources' items as read when the palette opened (or a source was registered), with
    /// their prepared strings; typing only re-ranks them.
    @ObservationIgnored private var entries: [PaletteItem] = []
    /// Parallel to `entries`: the prepared strings, and the combined string's character mask
    /// in one contiguous array so a keystroke rejects most items without touching them.
    @ObservationIgnored private var preparedEntries: [PreparedItem] = []
    @ObservationIgnored private var masks: [UInt64] = []
    @ObservationIgnored private var enabledFlags: [Bool] = []
    @ObservationIgnored private var needsReload = true
    private(set) var results: [PaletteResult] = []
    var selection = 0

    init(history: PaletteHistory) {
        self.history = history
    }

    // MARK: Sources

    /// Adds `source`, replacing one registered under the same id.
    func register(_ source: any PaletteSource, id: String) {
        sources.removeAll { $0.id == id }
        sources.append((id, source))
        needsReload = true
    }

    func register(id: String, _ make: @escaping @MainActor () -> [PaletteItem]) {
        register(ClosurePaletteSource(make: make), id: id)
    }

    func unregister(id: String) {
        sources.removeAll { $0.id == id }
        needsReload = true
    }

    // MARK: Search

    struct PreparedItem {
        let title: String
        let subtitle: String
        let titleCandidate: FuzzyCandidate
        let combinedCandidate: FuzzyCandidate
    }

    private func prepared(_ item: PaletteItem) -> PreparedItem {
        if let cached = candidates[item.id], cached.title == item.title, cached.subtitle == item.subtitle { return cached }
        let made = PreparedItem(
            title: item.title, subtitle: item.subtitle, titleCandidate: FuzzyCandidate(item.title),
            combinedCandidate: FuzzyCandidate("\(item.title) \(item.subtitle)")
        )
        candidates[item.id] = made
        return made
    }

    /// Re-reads the sources and ranks them for the current query.
    func refresh() {
        needsReload = true
        rerank()
    }

    /// Ranks the items for the current query, reading the sources first when they changed.
    func rerank() {
        if needsReload {
            entries = sources.flatMap { $0.source.items() }
            preparedEntries = entries.map(prepared)
            masks = preparedEntries.map(\.combinedCandidate.mask)
            enabledFlags = entries.map(\.isEnabled)
            needsReload = false
        }
        results = rank()
        selection = 0
    }

    func rank() -> [PaletteResult] {
        let query = FuzzyMatcher.prepare(self.query)
        let recent = history.scores(for: self.query, now: now())
        let needed = FuzzyCandidate.mask(of: query)
        var scored: [(index: Int, score: Double, enabled: Bool)] = []
        // The combined string holds every character of the title: one test rejects most items.
        for index in masks.indices where masks[index] & needed == needed {
            let prepared = preparedEntries[index]
            guard let match = FuzzyMatcher.score(query, title: prepared.titleCandidate, combined: prepared.combinedCandidate) else { continue }
            let recentScore = recent.isEmpty ? 0 : recent[entries[index].id] ?? 0
            scored.append((index, recentScore * Self.recentWeight + match, enabledFlags[index]))
        }
        // Sorting small tuples, not items; equal scores keep the sources' order.
        scored.sort { lhs, rhs in
            if lhs.enabled != rhs.enabled { return lhs.enabled }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }
        return scored.prefix(Self.resultLimit).map { PaletteResult(item: entries[$0.index], score: $0.score) }
    }

    var selectedResult: PaletteResult? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    // MARK: Keyboard

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    /// Handles a navigation key; returns whether it did anything.
    @discardableResult
    func handle(_ key: PaletteKey) -> Bool {
        switch key {
        case .up:
            moveSelection(by: -1)
            return true
        case .down:
            moveSelection(by: 1)
            return true
        case .run:
            return runSelected()
        case .dismiss:
            onDismiss()
            return true
        }
    }

    /// kbd:[Return]: runs the selected item; a disabled one does nothing.
    @discardableResult
    func runSelected() -> Bool {
        guard let result = selectedResult else { return false }
        return run(result.item)
    }

    /// Runs `item` as its menu item would and remembers it for this query.
    @discardableResult
    func run(_ item: PaletteItem) -> Bool {
        guard item.isEnabled else { return false }
        history.record(query: query, itemID: item.id, now: now())
        onRun()
        item.run()
        return true
    }

    /// A click on row `index`.
    @discardableResult
    func run(at index: Int) -> Bool {
        guard results.indices.contains(index) else { return false }
        selection = index
        return runSelected()
    }

    /// The palette opened: an empty query over fresh sources.
    func reset() {
        needsReload = true
        query = ""
    }
}
