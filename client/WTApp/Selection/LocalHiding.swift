import Foundation
import WTCRDT
import WTModel
import WTSync

/// menu:View[Hide Selection] and menu:View[Show All] (selecting.adoc, "What cannot be selected"
/// and "Data model"; OBJ-007): a set of node ids hidden on this Mac only.  It is view state, kept
/// in the local store's `view` table (`local_only`, never sent), so hidden objects stay hidden
/// when the document reopens on this Mac and another Mac never sees them hidden.  Hidden objects
/// are left out of the screen's scene (`DocumentDisplayListBuilder.locallyHidden`), so they are
/// neither drawn, hit-tested nor selected by any command; print and export still draw them.  A
/// hidden node that is deleted -- by anyone -- leaves the set.
@MainActor
final class LocalHiding {
    static let viewKey = "hidden"

    /// Where the set is kept.
    struct Storage {
        var load: @MainActor () async -> Data?
        var save: @MainActor (Data) async -> Void
    }

    /// The document (which owns this); weak, so a restore still running when it goes does nothing.
    private(set) weak var document: DocumentHandle?
    let storage: Storage
    private var observation: DocumentHandle.ObservationToken?
    /// The last write, so writes land in order.
    private var saving: Task<Void, Never>?
    /// Reading the stored set when the document opened.
    private(set) var restoring: Task<Void, Never>?

    init(document: DocumentHandle, storage: Storage? = nil) {
        self.document = document
        self.storage = storage ?? Self.localStore(of: document)
        observation = document.observe { [weak self] change in self?.documentDidChange(change) }
        restoring = Task { [weak self] in await self?.restore() }
    }

    /// The document's `LocalStore` `view` table; a document without one keeps the set in memory.
    static func localStore(of document: DocumentHandle) -> Storage {
        Storage(
            load: { [weak document] in
                guard let store = await document?.openedModel()?.backend as? LocalStore else { return nil }
                return try? await store.viewValue(forKey: viewKey)
            },
            save: { [weak document] data in
                guard let store = await document?.openedModel()?.backend as? LocalStore else { return }
                try? await store.setViewValue(data, forKey: viewKey)
            }
        )
    }

    var hidden: Set<OpID> { document?.locallyHidden ?? [] }
    var canShowAll: Bool { !hidden.isEmpty }

    /// Reads the stored set once the model is open, dropping nodes that no longer exist.
    func restore() async {
        guard let data = await storage.load(), let stored = Self.decode(data), let document else { return }
        _ = await document.openedModel()
        let live = stored.filter { document.state.isLive($0) }
        document.setLocallyHidden(hidden.union(live))
        if live.count != stored.count { persist() }
    }

    /// menu:View[Hide Selection].
    func hide(_ nodes: [OpID]) {
        guard !nodes.isEmpty, let document else { return }
        document.setLocallyHidden(hidden.union(nodes))
        persist()
    }

    /// Shows `nodes` again and leaves the rest hidden (an object row's eye in the Layers panel,
    /// D-092).
    func show(_ nodes: [OpID]) {
        guard let document, !hidden.isDisjoint(with: nodes) else { return }
        document.setLocallyHidden(hidden.subtracting(nodes))
        persist()
    }

    /// menu:View[Show All].
    func showAll() {
        guard canShowAll, let document else { return }
        document.setLocallyHidden([])
        persist()
    }

    /// A document change that deleted hidden nodes drops them from the set.
    private func documentDidChange(_ change: ContentChange) {
        guard change.change != nil, !hidden.isEmpty, let document else { return }
        let state = document.state
        let live = hidden.filter { state.isLive($0) }
        guard live.count != hidden.count else { return }
        document.setLocallyHidden(live)
        persist()
    }

    private func persist() {
        let data = Self.encode(hidden)
        let previous = saving
        let storage = storage
        saving = Task {
            await previous?.value
            await storage.save(data)
        }
    }

    /// Waits for the restore and every write so far (tests, closing).
    func settle() async {
        await restoring?.value
        await saving?.value
    }

    /// `[[counter, replica], ...]`, sorted, as JSON.
    static func encode(_ nodes: Set<OpID>) -> Data {
        // An array of number pairs always encodes.
        try! JSONEncoder().encode(nodes.sorted().map { [$0.counter, $0.replica] })
    }

    static func decode(_ data: Data) -> Set<OpID>? {
        guard let pairs = try? JSONDecoder().decode([[UInt64]].self, from: data) else { return nil }
        return Set(pairs.compactMap { $0.count == 2 ? OpID(counter: $0[0], replica: $0[1]) : nil })
    }
}

/// menu:View[Hide Selection] (kbd:[Cmd+Shift+H]) and menu:View[Show All]
/// (kbd:[Cmd+Shift+Option+H]) in place of their placeholders, acting on the key window's document.
enum VisibilityCommands {
    static let nothingHidden = "Nothing is hidden"

    @MainActor
    static func commands(target: @escaping @MainActor @Sendable () -> DocumentWindowController?) -> [Command] {
        let ids = StandardCommands.ID.self
        let menu = StandardCommands.Menu.view
        let section = StandardCommands.Section.viewVisibility
        return [
            Command(
                id: ids.showAllObjects, title: "Show All", key: KeyEquivalent("h", [.command, .shift, .option]), menu: MenuPath(menu, section: section),
                contexts: [.pasteboard, .page], keywords: ["hidden", "unhide"],
                validation: {
                    guard let window = target() else { return .disabled(ViewCommands.noDocument) }
                    return window.hiding.canShowAll ? .enabled : .disabled(nothingHidden)
                },
                action: .perform { target()?.hiding.showAll() }
            ),
            Command(
                id: ids.hideSelection, title: "Hide Selection", key: KeyEquivalent("h", [.command, .shift]), menu: MenuPath(menu, section: section),
                contexts: ContextMenuCatalog.objectContexts, keywords: ["hide"],
                validation: {
                    guard let window = target() else { return .disabled(ViewCommands.noDocument) }
                    return window.selection.model.isEmpty ? .disabled(ViewCommands.nothingSelected) : .enabled
                },
                action: .perform {
                    guard let window = target() else { return }
                    window.hiding.hide(window.selection.model.ids.map(\.opID))
                }
            ),
        ]
    }

    @MainActor
    static func install(into registry: CommandRegistry, target: @escaping @MainActor @Sendable () -> DocumentWindowController?) {
        for command in commands(target: target) { registry.replace(command) }
    }
}
