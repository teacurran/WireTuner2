import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTSync

/// The History panel (history.adoc, "The History panel"; COLLAB-022): the front document's timeline
/// newest first -- named versions, sessions of changes per person (expandable to their changes,
/// merged branches under the branch's name), the offline changes not yet synced on top -- with a
/// search field, *Hide comments*, and on each row btn:[View] (the read-only window), btn:[Restore]
/// (the summary confirmation, one change) and btn:[Compare] (with the document now); two rows
/// selected compare with each other (*Older* / *Newer*).  Named versions are renamed and deleted
/// from their context menu; rows older than the retention window are summarized and only named
/// versions among them act.
///
/// Offline (COLLAB-024; history.adoc, "Offline behavior"): versions named but not yet sent are
/// listed as pending under *Not yet synced* with the unsent changes; the timeline read earlier this
/// session (`HistoryCache`), or before that the local log's sessions, stays listed, and rows whose
/// state the local log cannot rebuild show *Available when online*.  A live change drops only the
/// cached pages it can change, and the timeline is read again only when the shown page went.
@MainActor
@Observable
final class HistoryPanelModel {
    static let shared = HistoryPanelModel()
    static let panelID: PanelID = "history"
    static let group = "History"

    private(set) var rows: [HistoryRow] = []
    private(set) var retainedFromSeq: UInt64 = 0
    /// The offline changes not yet sent, newest first, by label.
    private(set) var pending: [String] = []
    var query = ""
    var hideComments = false
    private(set) var expanded: UInt64?
    /// The selected rows (at most two: Compare).
    private(set) var selection: [String] = []
    private(set) var message: String?
    private(set) var loadedDocument: String?
    /// Versions named here that wait for their changes to upload (*Not yet synced*).
    private(set) var pendingVersions: [PendingVersion] = []
    /// The last read of the timeline failed or had no network: rows the local log cannot rebuild
    /// show *Available when online*.
    private(set) var isOffline = false
    /// What the local log holds (nil: a document without a local store).
    private(set) var local: LocalHistory?
    /// Timeline pages read this session, per document.
    @ObservationIgnored private(set) var caches: [String: HistoryCache<HistoryPage>] = [:]

    @ObservationIgnored var window: @MainActor () -> DocumentWindowController? = { nil }
    @ObservationIgnored var client: @MainActor () -> (any HistoryClient)? = { nil }
    /// The collaboration features: states at a seq, sheets, opening documents.
    @ObservationIgnored var features: CollaborationFeatures?
    @ObservationIgnored var outbox: @MainActor (DocumentWindowController) async -> [String] = { window in
        guard let store = window.session?.store else { return [] }
        return ((try? await store.outbox()) ?? []).map(\.label).reversed()
    }
    /// The front document's versions waiting to be named on the server.
    @ObservationIgnored var queuedVersions: @MainActor (DocumentWindowController) async -> [PendingVersion] = { _ in [] }
    /// What the window's local store holds of the history.
    @ObservationIgnored var localHistory: @MainActor (DocumentWindowController) async -> LocalHistory? = { window in
        try? await window.session?.store?.localHistory()
    }
    /// A replica's author, for the local log's sessions.
    @ObservationIgnored var author: @MainActor (DocumentWindowController, UInt64) -> String? = { window, replica in window.session?.author(of: replica)?.name }
    @ObservationIgnored var makeID: @MainActor () -> String = { UUIDv7.make() }
    @ObservationIgnored var showVersion: @MainActor (EngineState, String, DocumentWindowController, VersionWindows.Actions) -> Void = { state, name, window, actions in
        VersionWindows.shared.open(state, document: window.documentHandle.title, version: name, environment: window.environment, actions: actions)
    }

    init() {}

    // MARK: Loading

    /// Reads the front document's timeline (and its unsent changes).
    func load() async {
        guard let window = window() else {
            rows = []
            loadedDocument = nil
            return
        }
        let document = window.documentHandle.id
        pending = await outbox(window)
        pendingVersions = await queuedVersions(window)
        local = await localHistory(window)
        let key = currentKey
        guard let client = client() else {
            message = "History needs the network."
            showOffline(window, document, key)
            return
        }
        do {
            let page = try await client.history(of: document, cursor: "", query: query, expandSession: expanded ?? 0)
            caches[document, default: HistoryCache()].store(page, for: key, head: local?.head ?? 0)
            show(page, document)
            isOffline = false
            message = nil
        } catch {
            message = "History could not be read: \(error.localizedDescription)"
            showOffline(window, document, key)
        }
    }

    private var currentKey: HistoryCache<HistoryPage>.Key { .timeline(cursor: "", query: query, expandSession: expanded ?? 0) }

    private func show(_ page: HistoryPage, _ document: String) {
        rows = page.rows
        retainedFromSeq = page.retainedFromSeq
        loadedDocument = document
    }

    /// Offline: the page read earlier, else (another document's rows on show) the local log's sessions.
    private func showOffline(_ window: DocumentWindowController, _ document: String, _ key: HistoryCache<HistoryPage>.Key) {
        isOffline = true
        if let page = caches[document]?.page(key) {
            show(page, document)
        } else if loadedDocument != document || rows.isEmpty {
            show(HistoryPage(rows: localRows(window), nextCursor: "", retainedFromSeq: 0), document)
        }
    }

    /// The local log's sessions as timeline rows, newest first.
    func localRows(_ window: DocumentWindowController) -> [HistoryRow] {
        (local?.sessions() ?? []).map { session in
            let entries = session.entries
            let changes = entries.reversed().map { HistoryChange(serverSeq: $0.serverSeq ?? 0, label: $0.label, wallTime: $0.wallTime, nodes: [], names: []) }
            return .session(HistorySession(author: author(window, session.replica) ?? (session.local ? "You" : "Someone"),
                                           firstSeq: entries.first?.serverSeq ?? 0, lastSeq: entries.last?.serverSeq ?? 0,
                                           startedAt: entries.first?.wallTime, endedAt: entries.last?.wallTime,
                                           changeCount: entries.count, branch: nil, changes: changes))
        }
    }

    /// A live change reached the window's document: the cached pages it can change go, and the
    /// timeline is read again only when the page shown went (the unsent group always follows).
    func liveChange(_ change: Wiretuner_Doc_V1_Change?, remote: Bool, in window: DocumentWindowController) async {
        let document = window.documentHandle.id
        if remote, let change, var cache = caches[document] {
            let seq = await window.session?.store?.lastServerSeq ?? cache.head + 1
            cache.apply(change, serverSeq: seq)
            caches[document] = cache
        }
        if remote, caches[document]?.page(currentKey) == nil {
            await load()
        } else {
            pending = await outbox(window)
            pendingVersions = await queuedVersions(window)
            local = await localHistory(window)
        }
    }

    /// btn:[Refresh]: the timeline read again, whatever is cached.
    func refresh() async {
        if let document = window()?.documentHandle.id { caches[document]?.removeAll() }
        await load()
    }

    /// Expands `session` (or collapses it, when it is the expanded one).
    func toggle(_ session: HistorySession) async {
        expanded = expanded == session.firstSeq ? nil : session.firstSeq
        await load()
    }

    // MARK: Reading

    /// Whether a change's objects are all comment threads (*Hide comments* hides it).
    func isComment(_ change: HistoryChange) -> Bool {
        guard let state = window()?.documentHandle.state, !change.nodes.isEmpty else { return false }
        return change.nodes.allSatisfy { state.store.placement($0)?.parent == CommentFields.collection || state.store.kind($0) == CommentFields.kind }
    }

    /// The rows shown: *Hide comments* drops comment changes, and sessions left with none.
    var visibleRows: [HistoryRow] {
        guard hideComments else { return rows }
        return rows.compactMap { row in
            guard case .session(var session) = row, !session.changes.isEmpty else { return row }
            session.changes = session.changes.filter { !isComment($0) }
            return session.changes.isEmpty ? nil : .session(session)
        }
    }

    /// Older than the retention window: shown summarized.
    func isSummarized(_ row: HistoryRow) -> Bool { row.serverSeq < retainedFromSeq }

    /// Whether View, Restore and Compare act on `row`: offline, only on a row the local log can
    /// rebuild.
    func isActionable(_ row: HistoryRow) -> Bool {
        guard row.version != nil || !isSummarized(row) else { return false }
        return !isAvailableWhenOnline(row)
    }

    /// Offline, and the local log cannot rebuild the row's state: *Available when online*.
    func isAvailableWhenOnline(_ row: HistoryRow) -> Bool {
        isOffline && !(local?.canRebuild(row.serverSeq) ?? false)
    }

    /// "Priya · 14:02–15:40 · 312 changes", or the summarized "Priya · 14 March · 312 changes".
    func title(_ row: HistoryRow) -> String {
        switch row {
        case .version(let version):
            return version.name
        case .session(let session):
            let who = session.branch.map { "\(session.author) · merged \($0)" } ?? session.author
            let count = session.changeCount == 1 ? "1 change" : "\(session.changeCount) changes"
            let formatter = DateFormatter()
            if isSummarized(row) {
                formatter.dateFormat = "d MMMM"
                return [who, session.startedAt.map(formatter.string), count].compactMap { $0 }.joined(separator: " · ")
            }
            formatter.dateFormat = "HH:mm"
            let span = [session.startedAt, session.endedAt].compactMap { $0.map(formatter.string) }.joined(separator: "–")
            return [who, span.isEmpty ? nil : span, count].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// The name a row goes by in a window title or a restore ("Client review 2", "Priya, 15:40").
    func name(_ row: HistoryRow) -> String {
        switch row {
        case .version(let version): return version.name
        case .session(let session):
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM HH:mm"
            return "\(session.author), \(session.endedAt.map(formatter.string) ?? "change \(session.lastSeq)")"
        }
    }

    // MARK: Selection

    /// A click selects the row; kbd:[Cmd]-click adds a second.
    func select(_ row: HistoryRow, extend: Bool = false) {
        if extend, !selection.contains(row.id) {
            selection = Array((selection + [row.id]).suffix(2))
        } else {
            selection = [row.id]
        }
    }

    var selectedRows: [HistoryRow] { selection.compactMap { id in rows.first { $0.id == id } } }

    // MARK: Actions

    private func state(_ row: HistoryRow, _ window: DocumentWindowController) async -> EngineState? {
        guard let features else { return nil }
        return try? await features.versionState(window, row.serverSeq)
    }

    /// btn:[View] (or a double-click): the read-only window at the row.
    @discardableResult
    func view(_ row: HistoryRow) async -> Bool {
        guard isActionable(row), let window = window(), let state = await state(row, window) else { return false }
        let actions = VersionWindows.Actions(
            restore: { [weak self] in Task { await self?.restore(row) } },
            restoreAsCopy: { [weak self] in Task { await self?.restoreAsCopy(row) } },
            compare: { [weak self] in Task { await self?.compareWithCurrent(row) } }
        )
        showVersion(state, name(row), window, actions)
        return true
    }

    /// btn:[Restore]: the summary confirmation, then one change (`RestoreVersionModel`).
    @discardableResult
    func restore(_ row: HistoryRow) async -> RestoreVersionModel? {
        guard isActionable(row), let window = window(), let features else { return nil }
        let info = VersionInfo(id: row.id, name: name(row), serverSeq: row.serverSeq, createdAt: nil)
        let document = window.documentHandle
        let model = RestoreVersionModel(documentTitle: document.title, list: { [info] }, state: { seq in try await features.versionState(window, seq) },
                                        current: { document.state }, perform: { window.objectEditing.perform($0) })
        model.onClose = { features.dismiss(CollaborationFeatures.restoreSheet) }
        model.compare = { [weak window] compare in
            features.dismiss(CollaborationFeatures.restoreSheet)
            features.presentCompare(compare, window)
        }
        features.present(RestoreVersionSheet(model: model), identifier: CollaborationFeatures.restoreSheet, on: window)
        await model.load()
        await model.prepare()
        return model
    }

    /// *Restore as Copy…*: a new document holding the row's state, opened.
    @discardableResult
    func restoreAsCopy(_ row: HistoryRow, name copyName: String? = nil) async -> String? {
        guard isActionable(row), let window = window(), let client = client() else { return nil }
        let title = copyName ?? "\(window.documentHandle.title) (\(name(row)))"
        do {
            let id = try await client.restoreAsCopy(of: window.documentHandle.id, serverSeq: row.serverSeq, newID: makeID(), name: title)
            features?.openDocument(id, title)
            return id
        } catch {
            message = "The copy could not be made: \(error.localizedDescription)"
            return nil
        }
    }

    /// *Compare with Current*: the row against the document now.
    @discardableResult
    func compareWithCurrent(_ row: HistoryRow) async -> CompareSheetModel? {
        guard isActionable(row), let window = window(), let state = await state(row, window) else { return nil }
        let model = CompareSheetModel(comparison: DocumentComparison(a: state, b: window.documentHandle.state), titleA: "Older", titleB: "Now",
                                      heading: "Compare \u{201C}\(name(row))\u{201D} with now")
        features?.presentCompare(model, window)
        return model
    }

    /// btn:[Compare] with two rows selected: the older against the newer.
    @discardableResult
    func compareSelected() async -> CompareSheetModel? {
        let rows = selectedRows.sorted { $0.serverSeq < $1.serverSeq }
        guard rows.count == 2, rows.allSatisfy(isActionable), let window = window(),
              let older = await state(rows[0], window), let newer = await state(rows[1], window) else { return nil }
        let model = CompareSheetModel(comparison: DocumentComparison(a: older, b: newer), titleA: "Older", titleB: "Newer",
                                      heading: "Compare \u{201C}\(name(rows[0]))\u{201D} with \u{201C}\(name(rows[1]))\u{201D}")
        features?.presentCompare(model, window)
        return model
    }

    /// *Rename*.
    func rename(_ version: HistoryVersion, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != version.name, let client = client() else { return }
        do {
            try await client.rename(version: version.id, name: trimmed, note: nil)
            await refresh()
        } catch {
            message = "The version could not be renamed: \(error.localizedDescription)"
        }
    }

    /// *Delete*: the bookmark only.
    func delete(_ version: HistoryVersion) async {
        guard let client = client() else { return }
        do {
            try await client.delete(version: version.id)
            await refresh()
        } catch {
            message = "The version could not be deleted: \(error.localizedDescription)"
        }
    }

    /// The front window's document changed: `liveChange` (a collaborator's version appears on
    /// the next remote change or refresh).
    func follow(_ window: DocumentWindowController) {
        window.documentHandle.observe { [weak self, weak window] change in
            guard let self, let window, self.window() === window else { return }
            let remote = change.summary.origin == .remote
            Task { await self.liveChange(change.change, remote: remote, in: window) }
        }
    }
}

/// The panel's body.
struct HistoryPanelBody: View {
    @Bindable var model: HistoryPanelModel
    @State private var renaming: String?
    @State private var newName = ""

    static func loading(_ model: HistoryPanelModel) -> () -> Void { { Task { await model.load() } } }
    static func refreshing(_ model: HistoryPanelModel) -> () -> Void { { Task { await model.refresh() } } }
    static func viewing(_ model: HistoryPanelModel, _ row: HistoryRow) -> () -> Void { { Task { await model.view(row) } } }
    static func restoring(_ model: HistoryPanelModel, _ row: HistoryRow) -> () -> Void { { Task { await model.restore(row) } } }
    static func comparing(_ model: HistoryPanelModel, _ row: HistoryRow) -> () -> Void { { Task { await model.compareWithCurrent(row) } } }
    static func comparingSelected(_ model: HistoryPanelModel) -> () -> Void { { Task { await model.compareSelected() } } }
    static func toggling(_ model: HistoryPanelModel, _ session: HistorySession) -> () -> Void { { Task { await model.toggle(session) } } }
    static func deleting(_ model: HistoryPanelModel, _ version: HistoryVersion) -> () -> Void { { Task { await model.delete(version) } } }
    static func renaming(_ model: HistoryPanelModel, _ version: HistoryVersion, _ name: String) -> () -> Void { { Task { await model.rename(version, to: name) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search history", text: $model.query).onSubmit(Self.loading(model)).accessibilityIdentifier("history.search")
                Toggle("Hide comments", isOn: $model.hideComments).toggleStyle(.checkbox).accessibilityIdentifier("history.hideComments")
                Button("Compare", action: Self.comparingSelected(model)).disabled(model.selection.count != 2).accessibilityIdentifier("history.compare")
                Button(action: Self.refreshing(model)) { Image(systemName: "arrow.clockwise") }.help("Refresh").accessibilityIdentifier("history.refresh")
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("history.message") }
            List {
                if !model.pending.isEmpty || !model.pendingVersions.isEmpty {
                    Section("Not yet synced") {
                        ForEach(model.pendingVersions) { version in
                            Text("\(version.name) · pending").italic().fontWeight(.bold).accessibilityIdentifier("history.pendingVersion")
                        }
                        ForEach(Array(model.pending.enumerated()), id: \.offset) { Text($0.element).italic() }
                    }
                }
                ForEach(model.visibleRows) { row in
                    HistoryRowView(model: model, row: row)
                        .contextMenu {
                            if let version = row.version {
                                Button("Rename…") { renaming = row.id; newName = version.name }
                                Button("Delete", action: Self.deleting(model, version))
                            }
                        }
                    if renaming == row.id, let version = row.version {
                        TextField("Name", text: $newName).onSubmit {
                            Self.renaming(model, version, newName)()
                            renaming = nil
                        }
                    }
                }
            }
            .accessibilityIdentifier("history.list")
        }
        .padding(8)
        .task(id: model.window()?.documentHandle.id) { await model.load() }
    }
}

struct HistoryRowView: View {
    let model: HistoryPanelModel
    let row: HistoryRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if case .session(let session) = row, !model.isSummarized(row) {
                    Button(action: HistoryPanelBody.toggling(model, session)) {
                        Image(systemName: model.expanded == session.firstSeq ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                }
                Text(model.title(row)).fontWeight(row.version != nil ? .bold : .regular)
                    .foregroundStyle(model.isActionable(row) ? .primary : .secondary)
                Spacer()
                if model.isAvailableWhenOnline(row) && (row.version != nil || !model.isSummarized(row)) {
                    Text("Available when online").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("history.availableWhenOnline")
                }
                if model.isActionable(row) {
                    Button("View", action: HistoryPanelBody.viewing(model, row)).accessibilityIdentifier("history.view")
                    Button("Restore", action: HistoryPanelBody.restoring(model, row)).accessibilityIdentifier("history.restore")
                    Button("Compare", action: HistoryPanelBody.comparing(model, row)).accessibilityIdentifier("history.compareRow")
                }
            }
            if case .session(let session) = row, model.expanded == session.firstSeq {
                ForEach(session.changes) { change in
                    Text(change.label).font(.caption).padding(.leading, 18)
                }
            }
        }
        .contentShape(Rectangle())
        .background(model.selection.contains(row.id) ? SwiftUI.Color.accentColor.opacity(0.15) : SwiftUI.Color.clear)
        .onTapGesture { model.select(row, extend: NSEvent.modifierFlags.contains(.command)) }
    }
}

@MainActor
enum HistoryPanel {
    static func descriptor(model: HistoryPanelModel) -> PanelDescriptor {
        PanelDescriptor(id: HistoryPanelModel.panelID, title: "History", icon: "clock.arrow.circlepath", defaultGroup: HistoryPanelModel.group, menuOrder: 73,
                        helpSlug: "history") {
            HistoryPanelBody(model: model)
        }
    }

    /// menu:File[Show History] and menu:File[Name This Version…].
    static func commands(show: @escaping @MainActor () -> Void, nameVersion: @escaping @MainActor () -> Void,
                         window: @escaping @MainActor () -> DocumentWindowController?) -> [Command] {
        let validation: @MainActor @Sendable () -> CommandValidation = { window() == nil ? .disabled("No document is open") : .enabled }
        return [
            Command(id: "file.showHistory", title: "Show History", menu: MenuPath(StandardCommands.Menu.file, section: 1), keywords: ["history", "versions", "timeline"],
                    validation: validation, action: .perform(show)),
            Command(id: "file.nameVersion", title: "Name This Version…", menu: MenuPath(StandardCommands.Menu.file, section: 1), keywords: ["version", "name", "bookmark"],
                    validation: validation, action: .perform(nameVersion)),
        ]
    }
}
