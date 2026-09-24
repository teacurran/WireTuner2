import Foundation
import OSLog
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import struct WTRender.StrokeStyle
import WTText

/// The pasteboard every document sits on: 222 × 222 inches, origin at its top-left corner,
/// y down (workspace.adoc, "The pasteboard").
enum Pasteboard {
    static let pointsPerInch = 72.0
    static let sideInches = 222.0
    static let side = sideInches * pointsPerInch
    static let bounds = Rect(x: 0, y: 0, width: side, height: side)

    /// US Letter, centred on the pasteboard: where a new document's first page goes.
    static let letterPage = Rect(x: (side - 612) / 2, y: (side - 792) / 2, width: 612, height: 792)
    /// `page` moved (not resized) so it lies on the pasteboard: a page dragged past the edge
    /// stops at it.  A page larger than the pasteboard is pinned to its origin.
    static func clamp(_ page: Rect) -> Rect {
        let x = min(max(page.minX, 0), max(side - page.width, 0))
        let y = min(max(page.minY, 0), max(side - page.height, 0))
        return Rect(x: x, y: y, width: page.width, height: page.height)
    }
}

/// Where tools emit changes (client.adoc, "Tools": a `CommandSink` in the `ToolContext`).  A tool
/// previews during a drag and performs exactly one command on mouse-up (one per placed point for
/// the Pen); the returned task finishes once the change is applied and drawn.
@MainActor
protocol CommandSink: AnyObject {
    @discardableResult
    func perform(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>
}

/// What one applied change did to the window's drawing: the change summary and the display lists
/// before and after it.
struct ContentChange: Sendable {
    let summary: ChangeSummary
    let before: DisplayList
    let after: DisplayList
    /// The change applied (nil for a page-furniture change, which is not a document change).
    let change: Wiretuner_Doc_V1_Change?
}

/// The pages before and after an applied change that changed them (the live notices for lost
/// page settings and removed pages, DOC-004 and DOC-008).
struct PageListChange {
    let before: PageList
    let after: PageList
    let origin: ChangeOrigin
    let change: Wiretuner_Doc_V1_Change?
}

/// An open document as the window sees it: identity, title, pages, the `WTModel.Document` and the
/// scene built from it.  The model opens asynchronously (`LocalStore.open`); until then the scene
/// is the page furniture alone and commands wait for it.  Every applied change -- local, undo,
/// redo or remote -- rebuilds the touched nodes (`DocumentDisplayListBuilder`) and goes to the
/// canvases through one `InvalidationBatcher`.
@MainActor
final class DocumentHandle: Identifiable, CommandSink {
    struct ObservationToken: Hashable, Sendable {
        fileprivate let id: UUID
    }

    static let logger = Logger(subsystem: "com.villagecompute.wiretuner", category: "document")

    let id: String
    var title: String {
        didSet { if title != oldValue { structureDidChange() } }
    }
    /// The document's pages, master pages and setup settings as read (DOC-002 `PageList`): every
    /// page in page order with its effective geometry, and the one Letter page a document without
    /// pages reads as (until the model opens, too).
    private(set) var pageList = PageList(EngineState())
    /// The active page (pages.adoc, "Selecting pages"): the page the page selector, page settings,
    /// the zero point and *Go to Page* refer to.  Presence, not document state; nil is page 1.
    private(set) var activePageID: OpID?
    /// The pages the Page tool or the Document panel selected (page settings apply to all of
    /// them); empty selects the active page.
    private(set) var selectedPageIDs: [OpID] = []
    /// This client's id (the window's presence).
    let replicaID: String
    /// Top-level display items before this index are page furniture, not objects.
    let firstSelectableIndex = 1
    /// How many content changes the document has seen (the canvas's accessibility value).
    private(set) var changeCount = 0
    /// The model, once open.
    private(set) var model: WTModel.Document?
    /// Why the model failed to open, if it did.
    private(set) var openError: (any Error)?
    /// Delivers change summaries to the canvases (local at once, remote once per frame).
    let invalidation: InvalidationBatcher
    private var builder: DocumentDisplayListBuilder
    /// The engine the document's text is laid out with: the shared fonts until the document's
    /// own font index is ready (`useTextEngine`, DocumentFonts).
    private(set) var textEngine = TextLayoutEngine(fonts: .shared)
    /// Each text node's layout as of `changeCount` (the Text tool's carets, remote carets).
    private var textLayouts: [OpID: (count: Int, layout: TextLayout)] = [:]
    private var opening: Task<Void, Never>?
    /// The last command, undo or redo issued: `settle` waits for it.
    private var inflight: Task<Void, Never>?
    private var modelObservation: WTModel.Document.ObservationToken?
    private var observers: [UUID: @MainActor (ContentChange) -> Void] = [:]
    private var structureObservers: [UUID: @MainActor () -> Void] = [:]
    private var pageObservers: [UUID: @MainActor (PageListChange) -> Void] = [:]
    /// The command the canvases show as if performed (`preview`), and the scene drawn with it.
    private(set) var previewCommand: (any WTModel.Command)?
    private var previewScene: DocumentScene?
    /// The nodes the preview draws differently: repainted when it changes or ends.
    private var previewTouched: Set<NodeID> = []

    /// A document whose model is ready (a memory document, tests).
    init(id: String = UUID().uuidString, title: String, replicaID: String = UUID().uuidString,
         model: WTModel.Document, invalidation: InvalidationBatcher = InvalidationBatcher()) {
        self.id = id
        self.title = title
        self.replicaID = replicaID
        self.invalidation = invalidation
        builder = DocumentDisplayListBuilder(canvas: CanvasID(id), background: [Self.pagesItem(pageList)])
        builder.textLayout = TextSceneLayout(engine: textEngine)
        attach(model)
    }

    /// A document whose model `open` produces (a `LocalStore`-backed document).  The scene shows
    /// the pages until it is ready; commands issued before wait for it.
    init(id: String = UUID().uuidString, title: String, replicaID: String = UUID().uuidString,
         invalidation: InvalidationBatcher = InvalidationBatcher(), open: @escaping @MainActor () async throws -> WTModel.Document) {
        self.id = id
        self.title = title
        self.replicaID = replicaID
        self.invalidation = invalidation
        builder = DocumentDisplayListBuilder(canvas: CanvasID(id), background: [Self.pagesItem(pageList)])
        builder.textLayout = TextSceneLayout(engine: textEngine)
        opening = Task { [weak self] in
            do {
                let model = try await open()
                self?.attach(model)
            } catch {
                self?.openError = error
                Self.logger.error("document \(id, privacy: .public) failed to open: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A new document in memory with a random replica.
    static func memory(id: String = UUID().uuidString, title: String) -> DocumentHandle {
        DocumentHandle(id: id, title: title, model: DocumentOpener.memoryDocument())
    }

    private func attach(_ model: WTModel.Document) {
        self.model = model
        pageList = PageList(model.state)
        builder.rebuild(model.state)
        _ = builder.setBackground([Self.pagesItem(pageList)], state: model.state)
        modelObservation = model.observe { [weak self] event in self?.modelDidChange(event) }
        // The template's swatches and first page are not content to draw.
        let template: Set<UInt32> = [SwatchFields.kind, PageFields.kind]
        if model.state.store.nodes.contains(where: { model.state.store.isCreated($0) && !template.contains(model.state.store.kind($0)) }) {
            changeCount += 1
            let summary = ChangeSummary(origin: .local, isStructural: true)
            invalidation.submit(summary, after: [builder.scene.displayList])
            notify(ContentChange(summary: summary, before: builder.scene.displayList, after: builder.scene.displayList, change: nil))
        }
        structureDidChange()
    }

    /// Waits until the model is open and every command issued so far has been applied.
    func settle() async {
        await opening?.value
        while let last = inflight {
            await last.value
            if inflight == last { break }
        }
        await model?.settle()
    }

    /// The model once it is open; nil when it failed to open.
    func openedModel() async -> WTModel.Document? {
        await opening?.value
        return model
    }

    /// Closes the model's backend (the window closed its last view).
    func close() {
        guard let model else { return }
        if let token = modelObservation { model.stopObserving(token) }
        let backend = model.backend
        Task { await DocumentOpener.close(backend) }
    }

    // MARK: Scene

    var scene: DocumentScene { builder.scene }
    /// What the canvases draw: the scene, or the preview over it while there is one.
    var displayList: DisplayList { previewScene?.displayList ?? builder.scene.displayList }
    /// The merged state the scene was built from (empty until the model opens).
    var state: EngineState { model?.state ?? EngineState() }

    private func modelDidChange(_ event: DocumentEvent) {
        let before = displayList
        let origin: ChangeOrigin = event.origin == .remote || event.origin == .reload ? .remote : .local
        // A reload (the state replaced wholesale) rebuilds everything; a change the nodes it touched.
        let (_, applied) = event.origin == .reload
            ? builder.reload(event.after, origin: origin)
            : builder.apply(event.change, state: event.after, origin: origin)
        var summary = applied
        let previousPages = pageList
        let pagesChanged = readPages(event.after)
        if pagesChanged.furniture {
            // The page furniture is the scene's background: a page added, moved or resized redraws it.
            let (_, redrawn) = builder.setBackground([Self.pagesItem(pageList)], state: event.after)
            summary.merge(redrawn)
        }
        if previewCommand != nil { summary = refreshPreview(summary) }
        changeCount += 1
        invalidation.submit(summary, before: [before], after: [displayList])
        notify(ContentChange(summary: summary, before: before, after: displayList, change: event.change))
        if pagesChanged.structure { structureDidChange() }
        if pagesChanged.structure || (origin == .local && !event.change.createdObjects.isEmpty) {
            let pageChange = PageListChange(before: previousPages, after: pageList, origin: origin, change: event.change)
            for observer in pageObservers.values { observer(pageChange) }
        }
    }

    /// Re-reads the pages and settings from `state`: whether the furniture (a page's rectangle or
    /// bleed) changed, and whether anything the status bar and panels show did (pages, names,
    /// masters, units, custom sizes, the grid).  A removed active page hands over to the nearest
    /// page in page order.
    private func readPages(_ state: EngineState) -> (furniture: Bool, structure: Bool) {
        let old = pageList
        let next = PageList(state)
        guard next != old else { return (false, false) }
        pageList = next
        selectedPageIDs.removeAll { next[$0] == nil }
        if let active = activePageID, next[active] == nil {
            let index = old.number(of: active).map { $0 - 1 } ?? 0
            activePageID = next.pages[min(index, next.pages.count - 1)].id
        }
        return (old.frames() != next.frames(), true)
    }

    // MARK: Preview (COLOR-017)

    /// Shows `command` on every canvas of the document as if it were performed, without a change
    /// (Color Control's *Preview*, editing-colors.adoc): nothing reaches the outbox or the undo
    /// list.  Changes keep applying underneath -- a remote edit of a previewed object redraws with
    /// the preview still over it -- until `preview(nil)` shows the document again.
    func preview(_ command: (any WTModel.Command)?) {
        let before = displayList
        previewCommand = command
        var summary = ChangeSummary(origin: .local)
        for node in previewTouched { summary.touch(node) }
        summary = refreshPreview(summary)
        invalidation.submit(summary, before: [before], after: [displayList])
        notify(ContentChange(summary: summary, before: before, after: displayList, change: nil))
    }

    /// Whether the canvases show a preview.
    var isPreviewing: Bool { previewScene != nil }

    /// Rebuilds the preview over the current scene: the command's change applied to a copy of the
    /// state and of the scene builder.  The nodes it draws differently, before and now, join
    /// `summary`.  No preview when the command writes nothing or fails.
    private func refreshPreview(_ summary: ChangeSummary) -> ChangeSummary {
        var merged = summary
        for node in previewTouched { merged.touch(node) }
        previewScene = nil
        previewTouched = []
        guard let command = previewCommand, let model else { return merged }
        var state = model.state
        var changes = ChangeBuilder(replica: model.replica, startCounter: state.clock.peek)
        guard (try? command.execute(&changes, state: state)) != nil, !changes.ops.isEmpty else { return merged }
        var change = Wiretuner_Doc_V1_Change()
        change.replica = model.replica
        change.startCounter = changes.startCounter
        change.label = command.label
        change.ops = changes.ops
        _ = state.applyLocal(change)
        var copy = builder
        let (scene, previewed) = copy.apply(change, state: state, origin: .local)
        previewScene = scene
        previewTouched = previewed.touchedNodes
        for node in previewTouched { merged.touch(node) }
        merged.isStructural = merged.isStructural || previewed.isStructural
        return merged
    }

    /// Lays out and draws `nodes` again without a change to the document: text whose fonts now
    /// resolve differently (`DocumentFontIndex.fontsChanged`, DOC-024).
    func relayout(_ nodes: Set<OpID>) {
        for node in nodes { textLayouts[node] = nil }
        let before = builder.scene.displayList
        let (scene, summary) = builder.invalidate(nodes, state: state)
        invalidation.submit(summary, before: [before], after: [scene.displayList])
        notify(ContentChange(summary: summary, before: before, after: scene.displayList, change: nil))
    }

    // MARK: Text

    /// Lays out and draws the document's text with `engine` from now on (the document's
    /// `DocumentFontIndex.layoutEngine`, whose substitutions are the document's own).
    func useTextEngine(_ engine: TextLayoutEngine) {
        guard engine !== textEngine else { return }
        textEngine = engine
        textLayouts = [:]
        builder.textLayout = TextSceneLayout(engine: engine)
        let text = Set(state.store.nodes.filter { state.nodeKind($0) == .text })
        if !text.isEmpty { relayout(text) }
    }

    /// The layout of text node `node` as the canvas draws it (container space: the node's own
    /// space; `Objects.pasteboardTransform` places it), nil when it is not a text node.
    func textLayout(for node: OpID) -> TextLayout? {
        if let cached = textLayouts[node], cached.count == changeCount { return cached.layout }
        let state = state
        guard let text = state.textNode(node) else { return nil }
        let layout = TextLayoutReading.layout(text, engine: textEngine, colors: ColorResolver(state))
        textLayouts[node] = (changeCount, layout)
        return layout
    }

    /// The page furniture (DOC-009, `PageRendering`): the pasteboard, every page's white sheet,
    /// bleed line and outline, as one group at index 0 so adding or removing a page never
    /// renumbers the objects after it.  The active page's emphasis, the grid, guides and presence
    /// dots are the canvas's own (`CanvasFurniture`), so choosing a page repaints no tile.
    static func pagesItem(_ pages: PageList) -> DisplayItem {
        PageRendering.item(pages.frames(), style: pageStyle)
    }

    /// The furniture's look: the canvas's pasteboard colour.
    static let pageStyle = PageStyle(pasteboardColor: CanvasView.pasteboardTileColor)

    // MARK: Commands and undo

    /// Performs `command` as one change once the model is open.  A command that fails (a stale
    /// selection, an invalid value) is logged and performs nothing.
    @discardableResult
    func perform(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        run { model in try await model.perform(command) }
    }

    /// menu:Edit[Undo].
    @discardableResult
    func undo() -> Task<Wiretuner_Doc_V1_Change?, Never> {
        run { model in try await model.undo() }
    }

    /// menu:Edit[Redo].
    @discardableResult
    func redo() -> Task<Wiretuner_Doc_V1_Change?, Never> {
        run { model in try await model.redo() }
    }

    /// The model's state was replaced wholesale (WTSync's `SyncEvent.stateReplaced`: a snapshot
    /// bootstrap or a salvage): re-reads it and redraws everything; the selection drops what no
    /// longer resolves.
    @discardableResult
    func reload() -> Task<Void, Never> {
        let opening = opening
        return Task { [weak self] in
            await opening?.value
            await self?.model?.reload()
        }
    }

    /// Applies a change from the server's log (the sync client's path in; tests stand in for it).
    @discardableResult
    func receive(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64 = 0) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        run { model in
            try await model.receive(change, serverSeq: serverSeq)
            return change
        }
    }

    private func run(_ body: @escaping @MainActor (WTModel.Document) async throws -> Wiretuner_Doc_V1_Change?) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        let opening = opening
        let previous = inflight
        let task = Task { [weak self] () -> Wiretuner_Doc_V1_Change? in
            await opening?.value
            await previous?.value
            guard let model = self?.model else { return nil }
            do {
                return try await body(model)
            } catch {
                Self.logger.error("command failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        inflight = Task { _ = await task.value }
        return task
    }

    /// Opens an undo group: every command until `endGroup` is one undo step (a drag).
    func beginGroup() { model?.beginGroup() }
    func endGroup() { model?.endGroup() }

    /// The Edit menu's titles and states.
    var undoTitle: String { model?.undoTitle ?? "Undo" }
    var redoTitle: String { model?.redoTitle ?? "Redo" }
    var canUndo: Bool { model?.canUndo ?? false }
    var canRedo: Bool { model?.canRedo ?? false }

    /// Fit All's rectangle: every page.
    var allPagesBounds: Rect? { pageList.bounds }

    // MARK: Pages and units (DOC-002, DOC-008)

    /// The page rectangles in page order (Fit to Page, the page selector, the Export sheet).
    /// Setting them replaces the document's pages with pages of those rectangles, in one change
    /// ("Set pages"), after every command issued before (tests and templates).
    var pages: [Rect] {
        get { pageList.pages.map(\.rect) }
        set { perform(ReplacePageRects(newValue, recordsUndo: false)) }
    }

    /// The active page as read.
    var activePage: Page { activePageID.flatMap { pageList[$0] } ?? pageList.pages[0] }
    /// Its index in page order (the page selector's).
    var currentPageIndex: Int { activePage.number - 1 }
    /// The active page's rectangle.
    var currentPage: Rect? { activePage.rect }
    /// The document's setup settings as read.
    var settings: DocumentSettings { pageList.settings }
    /// The document's unit (`settings.units`).
    var units: LengthUnit { settings.units }
    /// Field entry and display in the document's units, custom ones included.
    var unitConverter: Units { settings.unitConverter }

    /// The selected pages as read, in page order: the Page tool's selection, else the active page.
    var selectedPages: [Page] {
        let live = pageList.pages.filter { selectedPageIDs.contains($0.id) }
        return live.isEmpty ? [activePage] : live
    }

    /// Selects `ids` (pages the Page tool clicked or marqueed); the last becomes the active page.
    func selectPages(_ ids: [OpID]) {
        let live = ids.filter { pageList[$0] != nil }
        guard live != selectedPageIDs else { return }
        selectedPageIDs = live
        if let last = live.last { activePageID = last }
        structureDidChange()
    }

    /// Makes page `index` (clamped to the pages there are) the active page.
    func selectPage(_ index: Int) {
        let clamped = min(max(index, 0), pageList.pages.count - 1)
        selectPage(id: pageList.pages[clamped].id)
    }

    /// Makes the page `id` names the active page; an id naming no page is ignored.
    func selectPage(id: OpID) {
        guard pageList[id] != nil, id != activePage.id || activePageID == nil || selectedPageIDs != [id] else { return }
        activePageID = id
        selectedPageIDs = [id]
        structureDidChange()
    }

    /// btn:[Add Page]: a page like the active one after it in page order (`AddPages`, "Add page"),
    /// which becomes active once it exists.
    @discardableResult
    func addPage() -> Task<Void, Never> {
        let after = activePage
        let task = perform(AddPages(after: after.isSynthesized ? nil : after.id))
        return Task { [weak self] in
            guard await task.value != nil, let self else { return }
            self.selectPage(after.number)
        }
    }

    /// The units pop-up: one change, "Change units".
    @discardableResult
    func setUnits(_ units: LengthUnit) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard units != self.units else { return nil }
        return perform(SetUnits(units))
    }

    // MARK: Observers

    /// Calls `handler` after the title, the pages, the active page or the settings change (the
    /// status bar, the Document panel).
    @discardableResult
    func observeStructure(_ handler: @escaping @MainActor () -> Void) -> ObservationToken {
        let id = UUID()
        structureObservers[id] = handler
        return ObservationToken(id: id)
    }

    private func structureDidChange() {
        for observer in structureObservers.values { observer() }
    }

    /// Calls `handler` after every change to what the canvas draws.
    @discardableResult
    func observe(_ handler: @escaping @MainActor (ContentChange) -> Void) -> ObservationToken {
        let id = UUID()
        observers[id] = handler
        return ObservationToken(id: id)
    }

    /// Calls `handler` after a change that changed the pages or settings, and after a local change
    /// that created objects (the page notices follow what this person drew).
    @discardableResult
    func observePages(_ handler: @escaping @MainActor (PageListChange) -> Void) -> ObservationToken {
        let id = UUID()
        pageObservers[id] = handler
        return ObservationToken(id: id)
    }

    func stopObserving(_ token: ObservationToken) {
        observers[token.id] = nil
        structureObservers[token.id] = nil
        pageObservers[token.id] = nil
    }

    private func notify(_ change: ContentChange) {
        for observer in observers.values { observer(change) }
    }

    // MARK: Selectable objects

    /// The scene object `id` names, if it is drawn.
    func object(for id: SelectionID) -> SceneObject? {
        builder.scene.objects[id.node]
    }

    /// The display item `id` names, if it is drawn.
    func item(for id: SelectionID) -> DisplayItem? {
        object(for: id)?.item
    }

    func isSelectable(_ id: SelectionID) -> Bool { object(for: id)?.bounds != nil }

    /// Whether the point still exists (live, in a live object).
    func contains(_ point: PointReference) -> Bool {
        object(for: SelectionID(point.node))?.path?.contour(point.contour)?.points.contains { $0.id == point.point } ?? false
    }

    /// Whether the segment still exists.
    func contains(_ segment: SegmentReference) -> Bool {
        object(for: SelectionID(segment.node))?.path?.contour(segment.contour)?.segments.contains { $0.from.id == segment.from } ?? false
    }

    /// The object whose display item sits at `itemPath`, or holds it: a hit on part of an
    /// object's drawing (a text block's glyph run) names the object.
    func selectionID(atItemPath itemPath: [Int]) -> SelectionID? {
        var path = itemPath
        while !path.isEmpty {
            if let object = builder.scene.object(atItemPath: path) { return SelectionID(NodeID(object.id)) }
            path.removeLast()
        }
        return nil
    }

    /// Every top-level object that paints something, in draw order; with `rect`, only those
    /// whose bounds meet it (menu:Edit[Select > All] on the current page).
    func selectableIDs(intersecting rect: Rect? = nil) -> [SelectionID] {
        let scene = builder.scene
        return scene.topLevel.filter { node in
            rect.map { scene.objects[node]?.bounds?.intersects($0) == true } ?? true
        }.map(SelectionID.init)
    }
}
