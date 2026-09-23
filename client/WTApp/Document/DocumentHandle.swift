import Foundation
import WTGeometry
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
/// as the placeholder document keeps it until `WTModel`: the value with a Lamport stamp; the
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

/// One change a tool asks for.  Stands in for a `WTModel` `Command` until the model lands:
/// a label for the Undo menu and the drawing it adds.
struct DocumentEdit: Equatable, Sendable {
    let label: String
    let insertedItems: [DisplayItem]

    /// The pasteboard area the edit touches, for tile invalidation.
    var dirtyRect: Rect? {
        CanvasNavigation.union(insertedItems.compactMap(\.bounds))
    }
}

/// Where tools emit changes (client.adoc, "Tools": a `CommandSink` in the `ToolContext`).
/// A tool previews during a drag and submits exactly one edit on mouse-up.
@MainActor
protocol CommandSink: AnyObject {
    func submit(_ edit: DocumentEdit)
}

/// The placeholder document content: a display list the canvas draws and the rectangle tool
/// appends to.  `WTModel.Document` replaces it; nothing outside `WTApp/Document` and the
/// sample tool depends on its shape.
@MainActor
final class PlaceholderDocumentContent: CommandSink {
    let canvas: CanvasID
    private(set) var items: [DisplayItem]
    private(set) var displayList: DisplayList
    /// Every edit submitted, in order (the undo stack of the placeholder).
    private(set) var edits: [DocumentEdit] = []
    /// Called after each edit with the dirty rectangle.
    var onChange: (@MainActor (Rect?) -> Void)?
    /// Called when top-level items leave the list, before `onChange`.
    var onRemove: (@MainActor (IndexSet) -> Void)?
    /// The page background items `blank` adds: drawn, never selectable.
    let fixedItemCount: Int

    init(canvas: CanvasID, items: [DisplayItem], fixedItemCount: Int = 0) {
        self.canvas = canvas
        self.items = items
        self.fixedItemCount = fixedItemCount
        displayList = DisplayList(canvas: canvas, items: items)
    }

    /// A new document: one white Letter page with a hairline border and a shadow on the
    /// pasteboard.  The pages are one group at index 0, so adding or removing a page never
    /// renumbers the objects after it.
    static func blank(canvas: CanvasID, page: Rect = Pasteboard.letterPage) -> PlaceholderDocumentContent {
        PlaceholderDocumentContent(canvas: canvas, items: [pagesItem([page])], fixedItemCount: 1)
    }

    /// Every page's shadow, white sheet and border (BASIC-003: "background and page shadows
    /// drawn by the canvas").
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

    /// Redraws the page furniture for `pages`; with a `label` the change is also an edit
    /// ("Add Page").
    func setPages(_ pages: [Rect], label: String?, dirty: Rect?) {
        guard fixedItemCount == 1, !items.isEmpty else { return }
        items[0] = Self.pagesItem(pages)
        displayList = DisplayList(canvas: canvas, items: items)
        if let label { edits.append(DocumentEdit(label: label, insertedItems: [])) }
        onChange?(dirty)
    }

    /// A change that adds nothing to draw ("Change Units").
    func record(_ label: String) {
        edits.append(DocumentEdit(label: label, insertedItems: []))
    }

    func submit(_ edit: DocumentEdit) {
        edits.append(edit)
        items.append(contentsOf: edit.insertedItems)
        displayList = DisplayList(canvas: canvas, items: items)
        onChange?(edit.dirtyRect)
    }

    /// Deletes the top-level items at `indices` (the stand-in for a collaborator deleting
    /// objects, until `WTSync` delivers remote changes).  Fixed page items are never removed.
    func removeItems(at indices: IndexSet) {
        let removed = IndexSet(indices.filter { $0 >= fixedItemCount && $0 < items.count })
        guard !removed.isEmpty else { return }
        let dirty = CanvasNavigation.union(removed.compactMap { items[$0].bounds })
        for index in removed.reversed() { items.remove(at: index) }
        displayList = DisplayList(canvas: canvas, items: items)
        onRemove?(removed)
        onChange?(dirty)
    }
}

/// An open document as the window sees it: identity, title, pages and the display list to
/// draw.  A tiny stand-in for `WTModel.Document` (still a stub); the display list comes from
/// a provider closure so the model can supply it without the window changing.
@MainActor
final class DocumentHandle: Identifiable {
    struct ObservationToken: Hashable, Sendable {
        fileprivate let id: UUID
    }

    let id: String
    var title: String {
        didSet { if title != oldValue { structureDidChange() } }
    }
    /// The document's pages in pasteboard coordinates (Fit to Page, Fit All).
    var pages: [Rect] {
        didSet {
            currentPageIndex = min(currentPageIndex, max(pages.count - 1, 0))
            structureDidChange()
        }
    }
    /// The page the page selector shows (view state of the one window a document has until
    /// BASIC-016 opens more).
    private(set) var currentPageIndex = 0
    /// `settings.units`.
    private(set) var unitsRegister = UnitsRegister()
    /// This client's replica id for the units register's stamps (the local store's replica
    /// once `WTSync` lands).
    let replicaID: String
    let commandSink: CommandSink
    /// Top-level display items before this index are page furniture, not objects: drawn but
    /// never hit, selected or outlined.  `WTModel` display lists will mark this per item.
    let firstSelectableIndex: Int
    /// How many content changes the document has seen (the canvas's accessibility value
    /// reports it, so UI tests can count the changes a gesture made).
    private(set) var changeCount = 0
    private let displayListProvider: @MainActor () -> DisplayList
    private var observers: [UUID: @MainActor (Rect?) -> Void] = [:]
    private var removalObservers: [UUID: @MainActor (IndexSet) -> Void] = [:]
    private var structureObservers: [UUID: @MainActor () -> Void] = [:]
    /// Redraws the page furniture (the placeholder content's; nil when the provider draws its
    /// own pages).
    var drawPages: (@MainActor ([Rect], _ label: String?, _ dirty: Rect?) -> Void)?
    /// Records a change that draws nothing ("Change Units").
    var recordEdit: (@MainActor (String) -> Void)?

    init(
        id: String = UUID().uuidString, title: String, pages: [Rect] = [Pasteboard.letterPage], replicaID: String = UUID().uuidString,
        commandSink: CommandSink, firstSelectableIndex: Int = 0, displayList: @escaping @MainActor () -> DisplayList
    ) {
        self.id = id
        self.title = title
        self.pages = pages
        self.replicaID = replicaID
        self.commandSink = commandSink
        self.firstSelectableIndex = firstSelectableIndex
        self.displayListProvider = displayList
    }

    /// A document backed by `PlaceholderDocumentContent`.
    static func placeholder(id: String = UUID().uuidString, title: String, content: PlaceholderDocumentContent? = nil) -> DocumentHandle {
        let content = content ?? .blank(canvas: CanvasID(id))
        let handle = DocumentHandle(id: id, title: title, commandSink: content, firstSelectableIndex: content.fixedItemCount) { content.displayList }
        content.onChange = { [weak handle] dirty in handle?.contentDidChange(dirty: dirty) }
        content.onRemove = { [weak handle] removed in handle?.contentDidRemove(topLevel: removed) }
        handle.drawPages = { [weak content] pages, label, dirty in content?.setPages(pages, label: label, dirty: dirty) }
        handle.recordEdit = { [weak content] label in content?.record(label) }
        return handle
    }

    var displayList: DisplayList { displayListProvider() }

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

    /// btn:[Add Page]: a page the size of the current one after it; it becomes current.  One
    /// change labelled "Add Page".
    @discardableResult
    func addPage() -> Int {
        let current = currentPage ?? Pasteboard.letterPage
        let page = Pasteboard.placement(after: current, among: pages)
        let index = pages.isEmpty ? 0 : currentPageIndex + 1
        pages.insert(page, at: index)
        currentPageIndex = index
        if let drawPages { drawPages(pages, "Add Page", page) } else { contentDidChange(dirty: page) }
        structureDidChange()
        return index
    }

    /// A page deleted by someone else (the stand-in until `WTSync` delivers remote changes):
    /// a deleted current page moves the selector to the nearest remaining page.
    func removePage(at index: Int) {
        guard pages.indices.contains(index) else { return }
        let removed = pages[index]
        if index < currentPageIndex || (index == currentPageIndex && index == pages.count - 1) {
            currentPageIndex = max(currentPageIndex - 1, 0)
        }
        pages.remove(at: index)
        if let drawPages { drawPages(pages, nil, removed) } else { contentDidChange(dirty: removed) }
    }

    var units: DocumentUnits { unitsRegister.value }

    /// The units pop-up: one change labelled "Change Units".
    func setUnits(_ units: DocumentUnits) {
        guard units != self.units else { return }
        unitsRegister = unitsRegister.writing(units, replica: replicaID)
        recordEdit?("Change Units")
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

    @discardableResult
    func observe(_ handler: @escaping @MainActor (Rect?) -> Void) -> ObservationToken {
        let id = UUID()
        observers[id] = handler
        return ObservationToken(id: id)
    }

    /// Calls `handler` with the top-level indices that left the list, before the change
    /// notification for the same change (the selection follows its objects with it).
    @discardableResult
    func observeRemovals(_ handler: @escaping @MainActor (IndexSet) -> Void) -> ObservationToken {
        let id = UUID()
        removalObservers[id] = handler
        return ObservationToken(id: id)
    }

    func stopObserving(_ token: ObservationToken) {
        observers[token.id] = nil
        removalObservers[token.id] = nil
        structureObservers[token.id] = nil
    }

    /// Tells every view the content changed under `dirty` (nil: anywhere).
    func contentDidChange(dirty: Rect?) {
        changeCount += 1
        for observer in observers.values { observer(dirty) }
    }

    /// Tells the removal observers which top-level items left the list.
    func contentDidRemove(topLevel removed: IndexSet) {
        for observer in removalObservers.values { observer(removed) }
    }

    // MARK: Selectable objects

    /// The display item `id` names, if it still exists and is an object.
    func item(for id: SelectionID) -> DisplayItem? {
        let path = id.indexPath
        guard let top = path.first, top >= firstSelectableIndex else { return nil }
        let items = displayList.items
        guard items.indices.contains(top) else { return nil }
        var item = items[top]
        for index in path.dropFirst() {
            guard case let .group(group) = item, group.children.indices.contains(index) else { return nil }
            item = group.children[index]
        }
        return item
    }

    func isSelectable(_ id: SelectionID) -> Bool { item(for: id) != nil }

    /// Every top-level object that paints something, in draw order; with `rect`, only those
    /// whose bounds meet it (menu:Edit[Select > All] on the current page).
    func selectableIDs(intersecting rect: Rect? = nil) -> [SelectionID] {
        let list = displayList
        return list.itemBounds.indices.compactMap { index in
            guard index >= firstSelectableIndex, let bounds = list.itemBounds[index] else { return nil }
            if let rect, !bounds.intersects(rect) { return nil }
            return .item([index])
        }
    }
}
