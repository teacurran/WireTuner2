import Foundation
import OSLog
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import struct WTRender.StrokeStyle

/// The pasteboard every document sits on: 222 × 222 inches, origin at its top-left corner,
/// y down (workspace.adoc, "The pasteboard").
enum Pasteboard {
    static let pointsPerInch = 72.0
    static let sideInches = 222.0
    static let side = sideInches * pointsPerInch
    static let bounds = Rect(x: 0, y: 0, width: side, height: side)

    /// US Letter, centred on the pasteboard: where a new document's first page goes.
    static let letterPage = Rect(x: (side - 612) / 2, y: (side - 792) / 2, width: 612, height: 792)
    /// Space between pages that Add Page leaves.
    static let pageGap = 36.0

    /// `page` moved (not resized) so it lies on the pasteboard: a page dragged past the edge
    /// stops at it.  A page larger than the pasteboard is pinned to its origin.
    static func clamp(_ page: Rect) -> Rect {
        let x = min(max(page.minX, 0), max(side - page.width, 0))
        let y = min(max(page.minY, 0), max(side - page.height, 0))
        return Rect(x: x, y: y, width: page.width, height: page.height)
    }

    /// Where Add Page puts a page of `size` after `current`: to the right of the rightmost
    /// page in `current`'s row, or at the start of a new row below when the row is full.
    static func placement(after current: Rect, among pages: [Rect]) -> Rect {
        let row = pages.filter { $0.minY < current.maxY && current.minY < $0.maxY }
        let right = row.map { $0.maxX }.max() ?? current.maxX
        let beside = Rect(x: right + pageGap, y: current.minY, width: current.width, height: current.height)
        if beside.maxX <= side { return beside }
        let bottom = pages.map { $0.maxY }.max() ?? current.maxY
        let left = pages.map { $0.minX }.min() ?? current.minX
        return clamp(Rect(x: left, y: bottom + pageGap, width: current.width, height: current.height))
    }
}

/// The document's unit of measure (document-panel.adoc; the status bar's units pop-up).
enum DocumentUnits: String, CaseIterable, Codable, Sendable {
    case points, picas, inches, decimalInches, millimeters, centimeters, pixels

    var title: String {
        switch self {
        case .points: "Points"
        case .picas: "Picas"
        case .inches: "Inches"
        case .decimalInches: "Decimal Inches"
        case .millimeters: "Millimeters"
        case .centimeters: "Centimeters"
        case .pixels: "Pixels"
        }
    }
}

/// The `settings.units` register (ATOMIC, last writer wins, workspace.adoc "Merge semantics")
/// as the window keeps it until the settings node is wired: the value with a Lamport stamp; the
/// higher stamp wins, the replica id breaking ties, so every client converges on one value.
struct UnitsRegister: Equatable, Sendable {
    var value: DocumentUnits
    var counter: UInt64
    var replica: String

    init(value: DocumentUnits = .points, counter: UInt64 = 0, replica: String = "") {
        self.value = value
        self.counter = counter
        self.replica = replica
    }

    /// A local write by `replica`, stamped above everything seen.
    func writing(_ value: DocumentUnits, replica: String) -> UnitsRegister {
        UnitsRegister(value: value, counter: counter + 1, replica: replica)
    }

    /// The winner of the two.
    func merged(with other: UnitsRegister) -> UnitsRegister {
        (other.counter, other.replica) > (counter, replica) ? other : self
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
    /// The document's pages in pasteboard coordinates (Fit to Page, Fit All).
    var pages: [Rect] {
        didSet {
            currentPageIndex = min(currentPageIndex, max(pages.count - 1, 0))
            drawPages()
            structureDidChange()
        }
    }
    /// The page the page selector shows.
    private(set) var currentPageIndex = 0
    /// `settings.units`.
    private(set) var unitsRegister = UnitsRegister()
    /// This client's id for the units register's stamps.
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
    private var opening: Task<Void, Never>?
    /// The last command, undo or redo issued: `settle` waits for it.
    private var inflight: Task<Void, Never>?
    private var modelObservation: WTModel.Document.ObservationToken?
    private var observers: [UUID: @MainActor (ContentChange) -> Void] = [:]
    private var structureObservers: [UUID: @MainActor () -> Void] = [:]

    /// A document whose model is ready (a memory document, tests).
    init(id: String = UUID().uuidString, title: String, pages: [Rect] = [Pasteboard.letterPage], replicaID: String = UUID().uuidString,
         model: WTModel.Document, invalidation: InvalidationBatcher = InvalidationBatcher()) {
        self.id = id
        self.title = title
        self.pages = pages
        self.replicaID = replicaID
        self.invalidation = invalidation
        builder = DocumentDisplayListBuilder(canvas: CanvasID(id), background: [Self.pagesItem(pages)])
        attach(model)
    }

    /// A document whose model `open` produces (a `LocalStore`-backed document).  The scene shows
    /// the pages until it is ready; commands issued before wait for it.
    init(id: String = UUID().uuidString, title: String, pages: [Rect] = [Pasteboard.letterPage], replicaID: String = UUID().uuidString,
         invalidation: InvalidationBatcher = InvalidationBatcher(), open: @escaping @MainActor () async throws -> WTModel.Document) {
        self.id = id
        self.title = title
        self.pages = pages
        self.replicaID = replicaID
        self.invalidation = invalidation
        builder = DocumentDisplayListBuilder(canvas: CanvasID(id), background: [Self.pagesItem(pages)])
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
        builder.rebuild(model.state)
        modelObservation = model.observe { [weak self] event in self?.modelDidChange(event) }
        if model.state.store.nodes.contains(where: { model.state.store.isCreated($0) }) {
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

    /// Closes the model's backend (the window closed its last view).
    func close() {
        guard let model else { return }
        if let token = modelObservation { model.stopObserving(token) }
        let backend = model.backend
        Task { await DocumentOpener.close(backend) }
    }

    // MARK: Scene

    var scene: DocumentScene { builder.scene }
    var displayList: DisplayList { builder.scene.displayList }
    /// The merged state the scene was built from (empty until the model opens).
    var state: EngineState { model?.state ?? EngineState() }

    private func modelDidChange(_ event: DocumentEvent) {
        let before = builder.scene.displayList
        let origin: ChangeOrigin = event.origin == .remote || event.origin == .reload ? .remote : .local
        // A reload (the state replaced wholesale) rebuilds everything; a change the nodes it touched.
        let (scene, summary) = event.origin == .reload
            ? builder.reload(event.after, origin: origin)
            : builder.apply(event.change, state: event.after, origin: origin)
        changeCount += 1
        invalidation.submit(summary, before: [before], after: [scene.displayList])
        notify(ContentChange(summary: summary, before: before, after: scene.displayList, change: event.change))
    }

    private func drawPages() {
        let before = builder.scene.displayList
        let (scene, summary) = builder.setBackground([Self.pagesItem(pages)], state: state)
        invalidation.submit(summary, before: [before], after: [scene.displayList])
        notify(ContentChange(summary: summary, before: before, after: scene.displayList, change: nil))
    }

    /// Every page's shadow, white sheet and border (BASIC-003).  The pages are one group at index
    /// 0, so adding or removing a page never renumbers the objects after it.
    static func pagesItem(_ pages: [Rect]) -> DisplayItem {
        .group(GroupItem(children: pages.flatMap { page -> [DisplayItem] in
            let path = DisplayPath(rect: page)
            let shadow = DisplayPath(rect: Rect(x: page.minX + 3, y: page.minY + 3, width: page.width, height: page.height))
            return [
                .fill(FillItem(path: shadow, paint: .solid(Color(white: 0, alpha: 0.18)))),
                .fill(FillItem(path: path, paint: .solid(.white))),
                .stroke(StrokeItem(path: path, style: StrokeStyle(width: 0.5), paint: .solid(Color(white: 0.6)))),
            ]
        }))
    }

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
    var allPagesBounds: Rect? { CanvasNavigation.union(pages) }

    /// The current page (the page selector's).
    var currentPage: Rect? { pages.indices.contains(currentPageIndex) ? pages[currentPageIndex] : nil }

    // MARK: Pages and units (BASIC-002)

    /// Selects page `index` (clamped to the pages there are).
    func selectPage(_ index: Int) {
        let clamped = min(max(index, 0), max(pages.count - 1, 0))
        guard clamped != currentPageIndex else { return }
        currentPageIndex = clamped
        structureDidChange()
    }

    /// btn:[Add Page]: a page the size of the current one after it; it becomes current.
    @discardableResult
    func addPage() -> Int {
        let current = currentPage ?? Pasteboard.letterPage
        let page = Pasteboard.placement(after: current, among: pages)
        let index = pages.isEmpty ? 0 : currentPageIndex + 1
        changeCount += 1
        pages.insert(page, at: index)
        currentPageIndex = index
        structureDidChange()
        return index
    }

    /// A page deleted by someone else: a deleted current page moves the selector to the nearest
    /// remaining page.
    func removePage(at index: Int) {
        guard pages.indices.contains(index) else { return }
        if index < currentPageIndex || (index == currentPageIndex && index == pages.count - 1) {
            currentPageIndex = max(currentPageIndex - 1, 0)
        }
        changeCount += 1
        pages.remove(at: index)
    }

    var units: DocumentUnits { unitsRegister.value }

    /// The units pop-up: one change labelled "Change Units".
    func setUnits(_ units: DocumentUnits) {
        guard units != self.units else { return }
        unitsRegister = unitsRegister.writing(units, replica: replicaID)
        changeCount += 1
        structureDidChange()
    }

    /// A units register from another client (merge: last writer wins).
    func mergeUnits(_ remote: UnitsRegister) {
        let merged = unitsRegister.merged(with: remote)
        guard merged != unitsRegister else { return }
        unitsRegister = merged
        structureDidChange()
    }

    // MARK: Observers

    /// Calls `handler` after the title, pages, current page or units change (the status bar).
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

    func stopObserving(_ token: ObservationToken) {
        observers[token.id] = nil
        structureObservers[token.id] = nil
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

    /// The object whose display item sits at `itemPath`.
    func selectionID(atItemPath itemPath: [Int]) -> SelectionID? {
        builder.scene.object(atItemPath: itemPath).map { SelectionID(NodeID($0.id)) }
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
