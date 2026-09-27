import AppKit
import Foundation
import Observation
import SwiftProtobuf
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync

/// What the review sheet needs from its document and session, injected so tests drive it without
/// a server.
@MainActor
struct ReviewContext {
    var documentID: String
    var documentTitle: String
    /// Performs a choice as one undoable change.
    var perform: @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>
    /// Ends the hold (`SyncClient.resolveReview`).
    var resolve: @MainActor (SyncClient.ReviewResolution) async throws -> Void
    /// The unsent local changes and the head before the reconnect.
    var localWork: @MainActor () async throws -> (changes: [Wiretuner_Doc_V1_Change], baseSeq: UInt64)
    /// Fork and CreateBranch; nil offline or signed out (the buttons say why).
    var work: (any ReviewWorkClient)?
    /// Opens a document the sheet made (the copy, the branch).
    var openDocument: @MainActor (String, String) -> Void = { _, _ in }
    /// *Keep both offset*, points.
    var keepBothOffset: @MainActor () -> Double = { 10 }
    /// *Keep my changes on a branch* on this Mac (`BranchStores`, `BranchCreator`): the unsent
    /// changes go to a new branch store, created on the server when possible; returns its id.
    /// Nil for a document without a local store, which falls back to `work`.
    var keepOnBranch: (@MainActor (String) async throws -> String)?
    /// The local user's name, for "Copy from Priya's offline edits".
    var userName: String = ""
    /// The state at a server seq (`LocalStore.state(atServerSeq:)`): the previous head the colour
    /// settings row reads what each side changed from (CMS-009); nil without a local store.
    var baseState: (@MainActor (UInt64) async -> EngineState?)?
    var makeID: @MainActor () -> String = { UUIDv7.make() }
    var now: @MainActor () -> Date = { Date() }
}

/// The review sheet (reconcile.adoc, "The review sheet"; collaboration.adoc, "The Review Changes
/// sheet"; SYNC-007): the header, the filters, one row per object with its overlap in the guide's
/// words, the *Mine* / *Theirs* / *Merged* / *Overlay* preview, each conflicting attribute with both
/// values and the one the merge kept, the per-object choices (each one undoable change), the
/// paragraph diff and choices of *Same text* rows, and the whole-document choices.
@MainActor
@Observable
final class ReviewSheetModel {
    enum Filter: String, CaseIterable, Identifiable {
        case everything, conflicts, mine, theirs
        var id: String { rawValue }
    }

    enum Side: String, CaseIterable, Identifiable {
        case mine, theirs, merged
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// One row of the list.
    struct Row: Identifiable, Equatable {
        let id: String
        let node: OpID
        let name: String
        /// The overlap in the guide's words, or who changed it.
        let kind: String
        /// The conflict entry; nil for an object only one side changed.
        let entry: ReviewEntry?
        /// A data-merge row (DATA-023) instead of an object's.
        var data: DataRow? = nil
    }

    /// The data-merge rows beside the objects (data-merge.adoc, "Review rows"): two merge runs
    /// after the same page, and a field removed while the other side used it.
    enum DataRow: Equatable {
        case mergeRuns(MergeRunConflict)
        case removedField(FieldRemovedEntry)
        /// A *released stale master* or *duplicate release* page (master-pages.adoc; DOC-013).
        case release(ReleaseOverlap)
        /// An object drawn while the font was rescaled (font-info.adoc; FONT-007).
        case rescale(RescaleEntry)
        /// An instance of a removed symbol, or an object using a removed style (LIB-023).
        case removedTarget(RemovedTargetEntry)
        /// Both sides removed different pages and none was left (DOC-006, DOC-031): told, no
        /// choice -- the document reads as one Letter page and the next page command writes it.
        case zeroPages
    }

    /// One conflicting attribute: both values and which the merge kept.
    struct PropertyRow: Identifiable, Equatable {
        let id: String
        let title: String
        let mine: String
        let theirs: String
        let kept: MergeSide
    }

    /// One *Same text* paragraph with its diff.
    struct ParagraphRow: Identifiable, Equatable {
        let id: String
        let field: RegisterPath
        let ids: [OpID]
        let diff: ParagraphDiff
    }

    let review: ReviewModel
    @ObservationIgnored let context: ReviewContext
    @ObservationIgnored private(set) var merged: EngineState
    @ObservationIgnored let sides: ChangeSides
    @ObservationIgnored private let localChanges: [Wiretuner_Doc_V1_Change]
    @ObservationIgnored private let remoteChanges: [Wiretuner_Doc_V1_Change]
    @ObservationIgnored private let localNodes: [OpID]
    @ObservationIgnored private let remoteNodes: [(node: OpID, replica: UInt64)]
    var filter: Filter
    var selectedID: String?
    var side: Side = .merged
    var overlay = false
    private(set) var reviewed: Set<String> = []
    /// A message under the whole-document buttons (an error, or where the copy went).
    private(set) var message: String?
    private(set) var isWorking = false
    /// The sheet is done (resolved or closed).
    private(set) var isFinished = false
    @ObservationIgnored var onFinish: @MainActor () -> Void = {}
    /// The colour settings row's reading (CMS-009): who changed what, and *Use mine* /
    /// *Use theirs*; nil until `loadColorSettings` finds a remote colour settings change.
    private(set) var colorSettings: ColorSettingsReview?

    init(review: ReviewModel, merged: EngineState, local: [Wiretuner_Doc_V1_Change] = [], remote: [Wiretuner_Doc_V1_Change] = [],
         context: ReviewContext) {
        self.review = review
        self.merged = merged
        self.context = context
        localChanges = local
        remoteChanges = remote
        sides = ChangeSides(local: local, remote: remote)
        let listed = Set(review.entries.map(\.node))
        var seen = listed
        localNodes = local.flatMap { RegisterNames.touched(by: $0).map(\.node) }.filter { seen.insert($0).inserted && merged.store.exists($0) }
        var remoteSeen = listed.union(localNodes)
        remoteNodes = remote.flatMap { change in RegisterNames.touched(by: change).map { ($0.node, change.replica) } }
            .filter { remoteSeen.insert($0.0).inserted && merged.store.exists($0.0) }
        filter = review.entries.isEmpty && review.mergeRuns.isEmpty && review.removedFields.isEmpty && review.releaseOverlaps.isEmpty
            && review.rescaleRows.isEmpty && review.removedTargets.isEmpty && !review.zeroPages ? .everything : .conflicts
        selectedID = nil
        selectedID = rows.first?.id
    }

    /// The merged state changed (a choice or someone's edit arrived): previews follow.
    func stateDidChange(_ state: EngineState) {
        merged = state
    }

    // MARK: Header and filters

    var title: String { review.mode == .recovered ? "Recovered changes" : "Review changes" }

    /// "You made 2,314 changes offline (14 h). Meanwhile Priya made 811 and Tom 40."
    var summary: String {
        guard let report = review.recovered else { return review.summary }
        let dropped = report.dropped.count
        return "WireTuner recovered \(report.salvagedChanges) changes from a session that expired."
            + (dropped == 0 ? "" : " \(dropped) could not be applied.")
    }

    /// "17 objects were changed by both you and someone else."
    var overlapLine: String? {
        let count = review.overlapCount
        guard count > 0 else { return nil }
        return count == 1 ? "1 object was changed by both you and someone else." : "\(count) objects were changed by both you and someone else."
    }

    func filterTitle(_ filter: Filter) -> String {
        switch filter {
        case .everything: "Everything"
        case .conflicts: "Conflicts (\(review.entries.count + dataRows.count))"
        case .mine: "Mine (\(localNodes.count) \(localNodes.count == 1 ? "object" : "objects"))"
        case .theirs: "Theirs (\(remoteNodes.count))"
        }
    }

    /// The rows of their own beside the objects: each pair of merge runs, each removed field,
    /// each released page, each object drawn while the font was rescaled, and each object that
    /// refers to a removed symbol or style.  A rescale row whose object is already listed (its
    /// transform written on both sides) is not a row: its *Rescale* sits on that object's row.
    var dataRows: [Row] {
        let listed = Set(review.entries.map(\.node))
        let merges = review.mergeRuns.map { conflict in
            Row(id: conflict.id, node: conflict.page, name: Self.mergeRunsName(conflict), kind: "Both merged", entry: nil, data: .mergeRuns(conflict))
        } + review.removedFields.map { field in
            Row(id: field.id, node: field.field, name: field.title, kind: field.deletedLocally ? "Removed by you" : "Removed by someone else", entry: nil,
                data: .removedField(field))
        }
        let releases = review.releaseOverlaps.map { overlap in
            Row(id: overlap.id, node: overlap.page, name: releaseName(overlap), kind: overlap.kind.title, entry: nil, data: .release(overlap))
        }
        let rescales = review.rescaleRows.filter { !listed.contains($0.node) }.map { entry in
            Row(id: entry.id, node: entry.node, name: ObjectNaming.name(of: entry.node, in: merged), kind: entry.reason.title, entry: nil,
                data: .rescale(entry))
        }
        let removed = review.removedTargets.map { entry in
            Row(id: entry.id, node: entry.object, name: ObjectNaming.name(of: entry.object, in: merged), kind: entry.kind.title, entry: nil,
                data: .removedTarget(entry))
        }
        return merges + releases + rescales + removed + (review.zeroPages ? [Self.zeroPagesRow] : [])
    }

    /// "Page 3 from Master A".
    func releaseName(_ overlap: ReleaseOverlap) -> String {
        "\(ObjectNaming.name(of: overlap.page, in: merged)) from \(ObjectNaming.name(of: overlap.master, in: merged))"
    }

    /// The rescale of a listed object whose transform both sides wrote (*Rescale* beside *Use mine*).
    func rescale(for entry: ReviewEntry) -> RescaleEntry? {
        review.rescaleRows.first { $0.node == entry.node }
    }

    /// *Rescale all*: every rescale row's objects in one change, while a held review lists any.
    var rescaleAll: RescaleObjects? {
        allowsChoices ? FontRescaleReview.rescaleAll(review.rescaleRows) : nil
    }

    /// Runs *Rescale all* as one change and marks every rescale row reviewed.
    @discardableResult
    func performRescaleAll() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let command = rescaleAll else { return nil }
        for row in review.rescaleRows { reviewed.insert(row.id) }
        for entry in review.entries where rescale(for: entry) != nil { reviewed.insert(entry.id) }
        return context.perform(command)
    }

    /// "All pages were removed; a page was added." (pages.adoc, "Merge semantics").
    static let zeroPagesRow = Row(id: "zero-pages", node: WellKnown.pages, name: ZeroPages.reviewMessage,
                                  kind: "Removed by both", entry: nil, data: .zeroPages)

    /// "Two merge runs: 3 pages and 4 pages".
    static func mergeRunsName(_ conflict: MergeRunConflict) -> String {
        func pages(_ run: MergeRun) -> String { run.pages.count == 1 ? "1 page" : "\(run.pages.count) pages" }
        return "Two merge runs: \(pages(conflict.mine)) and \(pages(conflict.theirs))"
    }

    var rows: [Row] {
        let conflicts = review.entries.sorted { ($0.kind, $0.id) < ($1.kind, $1.id) }.map { entry in
            Row(id: entry.id, node: entry.node, name: settingTitle(entry) ?? ObjectNaming.name(of: entry.node, in: merged),
                kind: entry.kind.title, entry: entry)
        } + dataRows
        let mine = localNodes.map { Row(id: "mine:\($0)", node: $0, name: ObjectNaming.name(of: $0, in: merged), kind: "Changed by you", entry: nil) }
        let theirs = remoteNodes.sorted { ($0.replica, $0.node) < ($1.replica, $1.node) }.map { item in
            Row(id: "theirs:\(item.node)", node: item.node, name: ObjectNaming.name(of: item.node, in: merged),
                kind: "Changed by \(authorName(item.replica))", entry: nil)
        }
        switch filter {
        case .everything: return conflicts + mine + theirs
        case .conflicts: return conflicts
        case .mine: return mine
        case .theirs: return theirs
        }
    }

    func authorName(_ replica: UInt64) -> String {
        let name = review.authors.first { $0.replica == replica }?.name ?? ""
        return name.isEmpty ? "someone" : name
    }

    var selectedRow: Row? {
        let rows = rows
        return rows.first { $0.id == selectedID } ?? rows.first
    }

    func select(_ id: String?) {
        selectedID = id
        side = .merged
    }

    func setFilter(_ filter: Filter) {
        self.filter = filter
        selectedID = rows.first?.id
    }

    // MARK: The selected object

    /// Every attribute that differs, with both values.
    var propertyRows: [PropertyRow] {
        guard let entry = selectedRow?.entry else { return [] }
        return entry.properties.map { conflict in
            PropertyRow(
                id: "\(conflict.property)", title: Self.title(conflict.property),
                mine: Self.describe(conflict.mine, property: conflict.property, state: merged),
                theirs: Self.describe(conflict.theirs, property: conflict.property, state: merged), kept: conflict.kept
            )
        }
    }

    /// The paragraphs of a *Same text* row, with their diffs.
    var paragraphRows: [ParagraphRow] {
        guard let entry = selectedRow?.entry else { return [] }
        return entry.paragraphs.compactMap { paragraph in
            guard let text = merged.store.text(entry.node, paragraph.text) else { return nil }
            let ids = ParagraphDiff.paragraph(text, terminator: paragraph.terminator)
            return ParagraphRow(id: "\(paragraph.text):\(paragraph.terminator)", field: paragraph.text, ids: ids,
                                diff: ParagraphDiff(text, ids: ids, sides: sides))
        }
    }

    /// Whether the per-object choices apply (a held review; a read-only one only looks).
    var allowsChoices: Bool { review.mode != .readOnly && !isFinished }

    /// The choices offered for the selected row (the colour settings row's own when it is read).
    var actions: [ReviewAction] {
        guard allowsChoices, let entry = selectedRow?.entry else { return [] }
        if entry.setting == .colorSettings, let colorSettings { return colorSettings.actions }
        return entry.actions
    }

    // MARK: The colour settings row (CMS-009)

    /// A setting entry's title: "Color settings changed by Priya" once read.
    func settingTitle(_ entry: ReviewEntry) -> String? {
        guard let setting = entry.setting else { return nil }
        if setting == .colorSettings, let colorSettings { return colorSettings.title }
        return setting.title
    }

    /// The changed settings' lines ("Working CMYK: Generic CMYK → Coated FOGRA39") of the selected
    /// colour settings row.
    var settingLines: [String] {
        guard selectedRow?.entry?.setting == .colorSettings, let colorSettings else { return [] }
        return colorSettings.changes.map(\.line)
    }

    /// Reads the colour settings row from the state at the previous head; nothing without a
    /// setting entry, a base state or a remote colour settings change.
    func loadColorSettings() async {
        guard review.entries.contains(where: { $0.setting == .colorSettings }), let baseState = context.baseState,
              let work = try? await context.localWork(), let base = await baseState(work.baseSeq) else { return }
        colorSettings = ColorSettingsReview(base: base, local: localChanges, remote: remoteChanges,
                                            authors: remoteChanges.map { authorName($0.replica) })
    }

    static func actionTitle(_ action: ReviewAction) -> String {
        switch action {
        case .useMine: "Use mine"
        case .useTheirs: "Use theirs"
        case .keepBoth: "Keep both copies"
        case .restore: "Restore"
        }
    }

    /// The label of *Use mine*'s change: "Use my fill for Logo mark".
    static func useMineLabel(_ entry: ReviewEntry, name: String) -> String {
        let titles = entry.properties.filter { $0.kept != .mine }.map { title($0.property).lowercased() }
        return titles.count == 1 ? "Use my \(titles[0]) for \(name)" : "Use my version of \(name)"
    }

    /// Runs `action` on the selected row; returns the change's task when one was performed.
    @discardableResult
    func perform(_ action: ReviewAction) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard allowsChoices, let row = selectedRow, let entry = row.entry else { return nil }
        reviewed.insert(entry.id)
        if entry.setting == .colorSettings, let colorSettings {
            return action == .useMine ? colorSettings.useMine.map(context.perform) : context.perform(colorSettings.useTheirs)
        }
        switch action {
        case .useTheirs:
            return nil
        case .useMine:
            guard let command = ReviewModel.useMine(entry) else { return nil }
            return context.perform(OpsCommand(Self.useMineLabel(entry, name: row.name), ops: command.ops))
        case .restore:
            return context.perform(OpsCommand("Restore \(row.name)", ops: ReviewModel.restore(entry).ops))
        case .keepBoth:
            let mine = ReviewSides.mine(entry, merged: merged)
            guard mine.store.exists(entry.node) else { return nil }
            let note = KeepBothCopies.noteText(user: context.userName, date: context.now())
            return context.perform(KeepBothCopies(tree: NodeTree(entry.node, state: mine), original: entry.node,
                                                  offset: context.keepBothOffset(), note: note, name: row.name))
        }
    }

    /// A paragraph choice of a *Same text* row.
    @discardableResult
    func perform(_ action: ReviewAction, paragraph: ParagraphRow) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard allowsChoices, let row = selectedRow, let entry = row.entry, let text = merged.store.text(entry.node, paragraph.field) else { return nil }
        reviewed.insert(paragraph.id)
        let command: OpsCommand? = switch action {
        case .useMine: ParagraphChoices.useMine(node: entry.node, field: paragraph.field, text: text, ids: paragraph.ids, sides: sides, name: row.name)
        case .keepBoth: ParagraphChoices.keepBoth(node: entry.node, field: paragraph.field, text: text, ids: paragraph.ids, sides: sides, name: row.name)
        default: nil
        }
        return command.map { context.perform($0) }
    }

    func isReviewed(_ id: String) -> Bool { reviewed.contains(id) }

    // MARK: Data-merge rows (DATA-023)

    /// The choices of the selected data-merge row: *Keep both, one after the other*, *Remove
    /// theirs*, *Remove mine* for two merge runs; *Restore* for a removed field.
    var dataChoices: [String] {
        guard allowsChoices, let row = selectedRow else { return [] }
        guard let data = row.data else {
            return row.entry.flatMap { rescale(for: $0) }.map { [$0.reason.actionTitle] } ?? []
        }
        switch data {
        case .mergeRuns: return MergeRunConflict.Choice.allCases.map(\.title)
        case .removedField: return ["Restore"]
        case .release(let overlap): return overlap.choices.map(\.title)
        case .rescale(let entry): return [entry.reason.actionTitle]
        case .removedTarget(let entry): return entry.choices.map(\.title)
        case .zeroPages: return []
        }
    }

    /// Runs the data-merge choice titled `title` on the selected row as one change; nil when it
    /// writes nothing (the runs already in order, the pages already gone).
    @discardableResult
    func performData(_ title: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard allowsChoices, let row = selectedRow, let index = dataChoices.firstIndex(of: title) else { return nil }
        reviewed.insert(row.id)
        guard let data = row.data else {
            // *Rescale* on a listed object whose transform both sides wrote.
            return row.entry.flatMap { rescale(for: $0) }.map { context.perform($0.command) }
        }
        switch data {
        case .mergeRuns(let conflict):
            return conflict.command(MergeRunConflict.Choice.allCases[index], in: merged).map { context.perform($0) }
        case .removedField(let field):
            return context.perform(field.restore)
        case .release(let overlap):
            return overlap.command(overlap.choices[index], in: merged).map { context.perform($0) }
        case .rescale(let entry):
            return context.perform(entry.command)
        case .removedTarget(let entry):
            do {
                return try entry.command(entry.choices[index], in: merged).map { context.perform($0) }
            } catch {
                message = "\(title) could not be applied: \(error.localizedDescription)"
                return nil
            }
        case .zeroPages:
            return nil
        }
    }

    // MARK: Preview

    /// The state a side shows for the selected row.
    func state(_ side: Side) -> EngineState {
        guard let entry = selectedRow?.entry else { return merged }
        return switch side {
        case .mine: ReviewSides.mine(entry, merged: merged)
        case .theirs: ReviewSides.theirs(entry, merged: merged)
        case .merged: merged
        }
    }

    /// The preview: the object drawn in place, zoomed to fit, everything else dimmed; with
    /// *Overlay*, mine and theirs at half strength on top of each other.
    func previewImage(size: Size = Size(width: 360, height: 240)) -> CGImage? {
        guard let row = selectedRow else { return nil }
        return ReviewPreview.image(node: row.node, states: overlay ? [state(.mine), state(.theirs)] : [state(side)], size: size)
    }

    // MARK: Whole document

    /// The document-level buttons.
    var documentActions: [ReviewModel.DocumentAction] {
        isFinished ? [] : review.documentActions
    }

    func documentActionTitle(_ action: ReviewModel.DocumentAction) -> String {
        switch action {
        case .keepMerged: review.mode == .recovered ? "Send" : "Keep the merged result"
        case .saveCopy: "Save my version as a copy…"
        case .keepBranch: "Keep my changes on a branch"
        }
    }

    /// Why a copy or branch cannot be made now, if it cannot.
    var workUnavailableReason: String? {
        context.work == nil ? "Connect to save your version elsewhere" : nil
    }

    /// Why `action` cannot run now: a branch kept on this Mac needs no connection.
    func unavailableReason(_ action: ReviewModel.DocumentAction) -> String? {
        switch action {
        case .keepMerged: nil
        case .keepBranch where context.keepOnBranch != nil: nil
        default: workUnavailableReason
        }
    }

    /// Runs a whole-document choice.
    @discardableResult
    func perform(_ action: ReviewModel.DocumentAction) -> Task<Void, Never> {
        Task { await run(action) }
    }

    func run(_ action: ReviewModel.DocumentAction) async {
        guard !isFinished, !isWorking else { return }
        switch action {
        case .keepMerged:
            await finish(.upload)
        case .keepBranch where context.keepOnBranch != nil:
            await keepOnBranch()
        case .saveCopy, .keepBranch:
            guard let work = context.work else {
                message = workUnavailableReason
                return
            }
            isWorking = true
            defer { isWorking = false }
            do {
                let (changes, base) = try await context.localWork()
                guard changes.count <= ReviewRequests.changeLimit else {
                    message = "Your version has more than \(ReviewRequests.changeLimit.formatted()) changes; keep the merged result instead"
                    return
                }
                let id = context.makeID()
                let name = Self.copyName(action, title: context.documentTitle, user: context.userName)
                if action == .saveCopy {
                    _ = try await work.fork(source: context.documentID, newID: id, atServerSeq: base, changes: changes, name: name)
                } else {
                    _ = try await work.createBranch(parent: context.documentID, branchID: id, name: name, forkServerSeq: base, changes: changes)
                }
                await finish(.discardLocalChanges)
                message = "Your version was saved as \(name)"
                context.openDocument(id, name)
            } catch {
                message = LibraryModel.message(for: error) ?? "Your version could not be saved: \(error.localizedDescription)"
            }
        }
    }

    /// *Keep my changes on a branch* through a branch store on this Mac: works offline.
    private func keepOnBranch() async {
        guard let keep = context.keepOnBranch else { return }
        isWorking = true
        defer { isWorking = false }
        let name = Self.copyName(.keepBranch, title: context.documentTitle, user: context.userName)
        do {
            let id = try await keep(name)
            await finish(.discardLocalChanges)
            message = "Your changes were kept on the branch \(name)"
            context.openDocument(id, name)
        } catch {
            message = "Your changes could not be kept on a branch: \(error.localizedDescription)"
        }
    }

    /// *Done*: uploads the merge with the choices made.
    func done() async {
        guard !isFinished else { return }
        if review.holdsOutbox {
            await finish(.upload)
        } else {
            isFinished = true
            onFinish()
        }
    }

    /// The sheet was dismissed: dismissing uploads the merge (reconcile.adoc).
    func dismiss() async { await done() }

    private func finish(_ resolution: SyncClient.ReviewResolution) async {
        do {
            try await context.resolve(resolution)
            isFinished = true
            onFinish()
        } catch {
            message = "The review could not be settled: \(error.localizedDescription)"
        }
    }

    /// "Logo refresh (my version)" / "Priya's offline edits".
    static func copyName(_ action: ReviewModel.DocumentAction, title: String, user: String) -> String {
        action == .saveCopy ? "\(title) (my version)" : (user.isEmpty ? "My offline edits" : "\(user)'s offline edits")
    }

    // MARK: Formatting

    /// A property's title: the attribute's name, *Position*, *Deleted*.
    static func title(_ property: ReviewProperty) -> String {
        switch property {
        case .register(let path): RegisterNames.title(path)
        case .deleted: "Deleted"
        case .placement: "Position"
        case .elementPosition(let path): "\(RegisterNames.title(path)) order"
        case .elementDeleted(let path): "\(RegisterNames.title(path)) removed"
        }
    }

    /// A side's value as text.
    static func describe(_ value: PropertyValue?, property: ReviewProperty, state: EngineState) -> String {
        switch value {
        case nil: return "Unchanged"
        case .flag(let flag)?:
            if case .deleted = property { return flag ? "Deleted" : "Kept" }
            return flag ? "Yes" : "No"
        case .placement(let parent, _)?:
            return "In \(ObjectNaming.name(of: parent, in: state))"
        case .register(nil)?:
            return "Not set"
        case .register(let bytes?)?:
            guard case .register(let path) = property else { return "\(bytes.count) bytes" }
            return describe(bytes, path: path)
        }
    }

    /// A register's field records as compact text: the value under the path's fields.
    static func describe(_ bytes: [UInt8], path: RegisterPath) -> String {
        var wrapped = bytes
        for field in path.fields.dropLast().reversed() {
            wrapped = varint(UInt64(field) << 3 | 2) + varint(UInt64(wrapped.count)) + wrapped
        }
        guard let props = try? Wiretuner_Doc_V1_NodeProps(serializedBytes: wrapped) else { return "\(bytes.count) bytes" }
        var text = props.textFormatString().split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        // Peel the message wrappers the path adds ("rect { common { transform { ... } } }").
        while let open = text.range(of: " {"), text.hasSuffix("}"), !text[..<open.lowerBound].contains(where: { $0 == " " || $0 == ":" }) {
            text = text[open.upperBound..<text.index(before: text.endIndex)].trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? "Default" : text
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        return bytes + [UInt8(value)]
    }
}

/// Renders the review preview (reconcile.adoc, "Per object"): the object in each given state
/// over the merged document dimmed, zoomed to fit the object in every state.
@MainActor
enum ReviewPreview {
    static let margin = 12.0
    static let dimming = 0.25

    static func image(node: OpID, states: [EngineState], size: Size) -> CGImage? {
        guard let background = states.last else { return nil }
        let canvas = CanvasID("review")
        var builder = DocumentDisplayListBuilder(canvas: canvas)
        let backdrop = builder.rebuild(background).displayList
        var items: [DisplayItem] = [.group(GroupItem(children: backdrop.items, opacity: dimming))]
        var bounds: Rect?
        for state in states {
            var sideBuilder = DocumentDisplayListBuilder(canvas: canvas)
            guard let object = sideBuilder.rebuild(state).object(node) else { continue }
            items.append(states.count > 1 ? .group(GroupItem(children: [object.item], opacity: 0.5)) : object.item)
            if let rect = object.bounds { bounds = bounds.map { $0.union(rect) } ?? rect }
        }
        guard let bounds else { return nil }
        let viewport = CanvasNavigation().fit(Viewport(size: size), rect: bounds.expanded(by: margin))
        return CoreGraphicsRenderer(background: .white).renderBitmap(DisplayList(canvas: canvas, items: items), viewport: viewport, scale: 2)
    }
}
