import Foundation
import WTGeometry
import WTRender

/// The pasteboard every document sits on: 222 × 222 inches, origin at its top-left corner,
/// y down (workspace.adoc, "The pasteboard").
enum Pasteboard {
    static let pointsPerInch = 72.0
    static let sideInches = 222.0
    static let side = sideInches * pointsPerInch
    static let bounds = Rect(x: 0, y: 0, width: side, height: side)

    /// US Letter, centred on the pasteboard: where a new document's first page goes.
    static let letterPage = Rect(x: (side - 612) / 2, y: (side - 792) / 2, width: 612, height: 792)
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

    /// A new document: one white Letter page with a hairline border on the pasteboard.
    static func blank(canvas: CanvasID, page: Rect = Pasteboard.letterPage) -> PlaceholderDocumentContent {
        let path = DisplayPath(rect: page)
        return PlaceholderDocumentContent(canvas: canvas, items: [
            .fill(FillItem(path: path, paint: .solid(.white))),
            .stroke(StrokeItem(path: path, style: StrokeStyle(width: 0.5), paint: .solid(Color(white: 0.6)))),
        ], fixedItemCount: 2)
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
    var title: String
    /// The document's pages in pasteboard coordinates (Fit to Page, Fit All).
    var pages: [Rect]
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

    init(
        id: String = UUID().uuidString, title: String, pages: [Rect] = [Pasteboard.letterPage],
        commandSink: CommandSink, firstSelectableIndex: Int = 0, displayList: @escaping @MainActor () -> DisplayList
    ) {
        self.id = id
        self.title = title
        self.pages = pages
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
        return handle
    }

    var displayList: DisplayList { displayListProvider() }

    /// Fit All's rectangle: every page.
    var allPagesBounds: Rect? { CanvasNavigation.union(pages) }

    /// The current page (the page selector's; BASIC-002 makes it selectable).
    var currentPage: Rect? { pages.first }

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
