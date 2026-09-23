import AppKit
import Observation
import SwiftUI

/// The Keyboard Shortcuts window's state and every action it offers (customizing.adoc,
/// "Keyboard shortcuts"; BASIC-027).  AppKit panels and alerts are injected so the whole flow
/// runs in tests without a screen.
@MainActor
@Observable
final class KeyboardShortcutsModel {
    struct Row: Identifiable, Hashable, Sendable {
        let id: CommandID
        let title: String
        let shortcut: String
    }

    struct Category: Identifiable, Hashable, Sendable {
        let id: String
        let rows: [Row]
    }

    /// The window's actions, one entry point so the view's buttons share one closure.
    enum Action: Hashable, Sendable {
        case newSet, rename, duplicate, delete, exportSet, importSet, exportText
        case assign, remove, revert, showCard, printCard, saveCardPDF, closeCard
    }

    static let reservedReason = "This shortcut is reserved by macOS."
    static let copyPrompt = "Built-in sets cannot be edited. Make a copy of this set and change the copy?"

    @ObservationIgnored let store: ShortcutSetStore
    @ObservationIgnored let registry: CommandRegistry

    var searchText = ""
    var selectedCommandID: CommandID? {
        didSet { if oldValue != selectedCommandID { selectedKey = nil } }
    }
    /// The key pressed in *Press new shortcut*.
    var capturedKey: KeyEquivalent?
    /// The shortcut selected under *Current shortcuts* (for Remove).
    var selectedKey: KeyEquivalent?
    var goToConflictOnAssign = false
    /// The last result shown under the form ("Imported 3 of 4 bindings…").
    var message: String?
    var includeUnboundOnCard = false
    var showingCardPreview = false
    private var collapsed: Set<String> = []
    /// Bumped when the store changes so views reading through it redraw.
    private(set) var revision = 0

    @ObservationIgnored private var sessionSnapshot: ShortcutSetStore.File?
    /// Asks whether to copy a built-in set before editing it.
    @ObservationIgnored var confirm: @MainActor (String) -> Bool = { _ in true }
    /// Asks for a set name, prefilled; nil cancels.
    @ObservationIgnored var askName: @MainActor (_ title: String, _ suggested: String) -> String? = { _, suggested in suggested }
    /// Where to write an exported file; nil cancels.
    @ObservationIgnored var chooseSaveURL: @MainActor (_ suggestedName: String) -> URL? = { _ in nil }
    /// Which file to import; nil cancels.
    @ObservationIgnored var chooseOpenURL: @MainActor () -> URL? = { nil }
    /// Runs the card's print operation (the system dialog).
    @ObservationIgnored var runPrint: @MainActor (NSPrintOperation) -> Void = { _ in }

    init(store: ShortcutSetStore, registry: CommandRegistry) {
        self.store = store
        self.registry = registry
    }

    /// The window opened: Revert goes back to this state.
    func beginSession() {
        sessionSnapshot = store.snapshot
        revision += 1
    }

    // MARK: Sets

    var summaries: [ShortcutSetStore.Summary] {
        _ = revision
        return store.summaries
    }

    /// The set pop-up.
    var activeSetID: String {
        get {
            _ = revision
            return store.activeSetID
        }
        set { perform { try store.activate(newValue) } }
    }

    var activeSet: ShortcutSet {
        _ = revision
        return store.activeSet
    }

    var isEditable: Bool { !store.isActiveSetBuiltIn }

    // MARK: Commands list

    var categories: [Category] {
        let set = activeSet
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        return ShortcutCategories.grouped(registry.commands).compactMap { group in
            let rows = group.commands.compactMap { command -> Row? in
                let keys = set.keys(for: command.id)
                let shortcut = ShortcutCategories.display(keys)
                guard needle.isEmpty || Self.matches(needle, command: command, shortcut: shortcut) else { return nil }
                return Row(id: command.id, title: ShortcutCategories.qualifiedTitle(of: command), shortcut: shortcut)
            }
            return rows.isEmpty ? nil : Category(id: group.title, rows: rows)
        }
    }

    static func matches(_ needle: String, command: Command, shortcut: String) -> Bool {
        ([command.title, command.id.rawValue, shortcut, ShortcutCategories.location(of: command)] + command.keywords).contains {
            $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// A category's disclosure state; every category is open while searching.
    func isExpanded(_ category: String) -> Bool {
        !searchText.isEmpty || !collapsed.contains(category)
    }

    func setExpanded(_ expanded: Bool, _ category: String) {
        if expanded { collapsed.remove(category) } else { collapsed.insert(category) }
    }

    func expansion(for category: String) -> Binding<Bool> {
        Binding(get: { self.isExpanded(category) }, set: { self.setExpanded($0, category) })
    }

    // MARK: Detail

    var selectedCommand: Command? { selectedCommandID.flatMap(registry.command) }

    /// Shown below the list: where the command lives and what it is called in full.
    var commandDescription: String {
        guard let command = selectedCommand else { return "Select a command to see its shortcuts." }
        return "\(ShortcutCategories.location(of: command)) — \(command.title)"
    }

    var currentShortcuts: [KeyEquivalent] {
        selectedCommandID.map { activeSet.keys(for: $0) } ?? []
    }

    /// Other commands the captured key is bound to (*Currently assigned to*).
    var conflictOwners: [CommandID] {
        guard let capturedKey else { return [] }
        return activeSet.commandIDs(for: capturedKey).filter { $0 != selectedCommandID }
    }

    var conflictText: String? {
        let titles = conflictOwners.map { registry.command($0)?.title ?? $0.rawValue }
        return titles.isEmpty ? nil : "Currently assigned to: \(titles.joined(separator: ", "))"
    }

    /// Why the captured key cannot be assigned; nil when it can.
    var refusal: String? {
        guard let capturedKey, let selectedCommandID else { return nil }
        return ReservedShortcuts.macOS.isReserved(capturedKey, against: selectedCommandID) ? Self.reservedReason : nil
    }

    var canAssign: Bool { selectedCommandID != nil && capturedKey != nil && refusal == nil }

    func capture(_ key: KeyEquivalent) {
        capturedKey = key
    }

    // MARK: Actions

    func handle(_ action: Action) {
        switch action {
        case .newSet: newSet()
        case .rename: renameActive()
        case .duplicate: newSet()
        case .delete: perform { try store.delete(store.activeSetID) }
        case .exportSet: exportSet()
        case .importSet: importSet()
        case .exportText: exportText()
        case .assign: assign()
        case .remove: remove()
        case .revert: revert()
        case .showCard: showingCardPreview = true
        case .printCard: runPrint(cardView().printOperation())
        case .saveCardPDF: saveCardPDF()
        case .closeCard: showingCardPreview = false
        }
    }

    /// Runs a store operation and reports a failure in `message`.
    private func perform(_ operation: () throws -> Void) {
        message = nil
        do {
            try operation()
        } catch {
            message = "\(error)"
        }
        revision += 1
    }

    /// btn:[+] and *Duplicate…*: a named copy of the current set, made active.
    func newSet() {
        let current = store.activeSetID
        guard let name = askName("New Shortcut Set", store.copyName(for: current)) else { return }
        perform { try store.makeCopy(of: current, name: name) }
    }

    func renameActive() {
        let current = store.activeSetID
        guard let name = askName("Rename Shortcut Set", store.summaries.first { $0.id == current }?.name ?? "") else { return }
        perform { try store.rename(current, to: name) }
    }

    /// A built-in set is copied (after asking) before any edit; returns whether editing may go on.
    func ensureEditable() -> Bool {
        guard store.isActiveSetBuiltIn else { return true }
        guard confirm(Self.copyPrompt) else { return false }
        let current = store.activeSetID
        perform { try store.makeCopy(of: current, name: store.copyName(for: current)) }
        return !store.isActiveSetBuiltIn
    }

    /// btn:[Assign]: the captured key moves to the selected command, taken from any other;
    /// with *Go to conflict on assign* the list then selects the command that lost it.
    @discardableResult
    func assign() -> Bool {
        guard canAssign, let key = capturedKey, let command = selectedCommandID, ensureEditable() else { return false }
        let losers = conflictOwners
        var set = store.activeSet
        set.bind(key, to: command)
        perform { try store.update(set) }
        capturedKey = nil
        if goToConflictOnAssign, let loser = losers.first { selectedCommandID = loser }
        return true
    }

    /// btn:[Remove]: the selected current shortcut is unbound.
    @discardableResult
    func remove() -> Bool {
        guard let key = selectedKey, let command = selectedCommandID, currentShortcuts.contains(key), ensureEditable() else { return false }
        var set = store.activeSet
        set.unbind(key, from: command)
        perform { try store.update(set) }
        selectedKey = nil
        return true
    }

    /// btn:[Revert]: every change since the window opened is undone.
    func revert() {
        guard let sessionSnapshot else { return }
        store.restore(sessionSnapshot)
        revision += 1
    }

    // MARK: Files

    private func write(_ data: Data, suggestedName: String) {
        guard let url = chooseSaveURL(suggestedName) else { return }
        perform { try data.write(to: url, options: .atomic) }
    }

    func exportSet() {
        let set = activeSet
        perform { write(try set.exportJSON(), suggestedName: "\(set.name).\(ShortcutSet.fileExtension)") }
    }

    func importSet() {
        guard let url = chooseOpenURL() else { return }
        perform {
            let imported = try store.importSet(Data(contentsOf: url))
            revision += 1
            let skipped = imported.warnings.isEmpty ? "" : " Skipped: \(imported.warnings.joined(separator: "; "))"
            message = "Imported \(imported.set.name).\(skipped)"
        }
    }

    func exportText() {
        let set = activeSet
        write(Data(ShortcutCSV.export(set: set, commands: registry.commands).utf8), suggestedName: "\(set.name) Shortcuts.csv")
    }

    // MARK: Card

    func cardView() -> ShortcutCardView {
        let set = activeSet
        return ShortcutCardView(title: "WireTuner Keyboard Shortcuts — \(set.name)", commands: registry.commands, set: set, includeUnbound: includeUnboundOnCard)
    }

    func saveCardPDF() {
        write(cardView().pdfData(), suggestedName: "\(activeSet.name) Shortcuts.pdf")
    }
}
