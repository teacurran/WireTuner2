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

    init(canvas: CanvasID, items: [DisplayItem]) {
        self.canvas = canvas
        self.items = items
        displayList = DisplayList(canvas: canvas, items: items)
    }

    /// A new document: one white Letter page with a hairline border on the pasteboard.
    static func blank(canvas: CanvasID, page: Rect = Pasteboard.letterPage) -> PlaceholderDocumentContent {
        let path = DisplayPath(rect: page)
        return PlaceholderDocumentContent(canvas: canvas, items: [
            .fill(FillItem(path: path, paint: .solid(.white))),
            .stroke(StrokeItem(path: path, style: StrokeStyle(width: 0.5), paint: .solid(Color(white: 0.6)))),
        ])
    }

    func submit(_ edit: DocumentEdit) {
        edits.append(edit)
        items.append(contentsOf: edit.insertedItems)
        displayList = DisplayList(canvas: canvas, items: items)
        onChange?(edit.dirtyRect)
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
    private let displayListProvider: @MainActor () -> DisplayList
    private var observers: [UUID: @MainActor (Rect?) -> Void] = [:]

    init(
        id: String = UUID().uuidString, title: String, pages: [Rect] = [Pasteboard.letterPage],
        commandSink: CommandSink, displayList: @escaping @MainActor () -> DisplayList
    ) {
        self.id = id
        self.title = title
        self.pages = pages
        self.commandSink = commandSink
        self.displayListProvider = displayList
    }

    /// A document backed by `PlaceholderDocumentContent`.
    static func placeholder(id: String = UUID().uuidString, title: String, content: PlaceholderDocumentContent? = nil) -> DocumentHandle {
        let content = content ?? .blank(canvas: CanvasID(id))
        let handle = DocumentHandle(id: id, title: title, commandSink: content) { content.displayList }
        content.onChange = { [weak handle] dirty in handle?.contentDidChange(dirty: dirty) }
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

    func stopObserving(_ token: ObservationToken) {
        observers[token.id] = nil
    }

    /// Tells every view the content changed under `dirty` (nil: anywhere).
    func contentDidChange(dirty: Rect?) {
        for observer in observers.values { observer(dirty) }
    }
}
