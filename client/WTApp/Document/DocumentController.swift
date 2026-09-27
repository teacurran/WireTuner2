import AppKit

/// The open documents and their windows (no `NSDocument`: there is nothing to save, every
/// change is kept as it is made).  New documents open as tabs of the front window through
/// native window tabbing.  A document can have up to eight views (menu:Window[New Window],
/// BASIC-016), each a window controller over the same `DocumentHandle` with its own view
/// state; the first is the primary view, whose state persists.
@MainActor
final class DocumentController {
    /// The most views one document may have open.
    static let maximumViews = 8
    static let tooManyViews = "A document can have at most eight views"

    /// What the windows are made with; tests swap the model opener.
    var environment: DocumentEnvironment
    /// Builds a document's window; replaceable in tests.
    var makeWindowController: @MainActor (DocumentHandle, DocumentEnvironment, ToolID, DocumentWindowState?) -> DocumentWindowController = {
        DocumentWindowController(document: $0, environment: $1, initialTool: $2, initialState: $3)
    }
    /// Refusing a ninth view beeps; replaceable in tests.
    var beep: @MainActor () -> Void = { NSSound.beep() }
    /// Called after the open documents, the key window or its tool change (the Tools panel,
    /// menu validation).
    var onChange: (@MainActor () -> Void)?

    private(set) var documents: [DocumentHandle] = []
    /// Every document's views, the primary view first.
    private(set) var views: [String: [DocumentWindowController]] = [:]
    private(set) var activeDocumentID: String?
    /// The view last made active.
    private weak var activeView: DocumentWindowController?
    /// The tool the last active window had; a new window starts with it.
    private(set) var lastToolID: ToolID = .pointer
    private var untitledCount = 0

    init(environment: DocumentEnvironment) {
        self.environment = environment
    }

    /// Each document's primary view.
    var windowControllers: [String: DocumentWindowController] { views.compactMapValues(\.first) }

    /// Every view of every document, in document order.
    var allWindowControllers: [DocumentWindowController] { documents.flatMap { views[$0.id] ?? [] } }

    /// The window the View menu and tool shortcuts act on: the key/main window's, else the
    /// most recently active one.
    var activeWindowController: DocumentWindowController? {
        if let window = NSApp.mainWindow ?? NSApp.keyWindow,
            let controller = allWindowControllers.first(where: { $0.window === window })
        {
            return controller
        }
        if let activeView, activeView.documentHandle.id == activeDocumentID { return activeView }
        return activeDocumentID.flatMap { windowControllers[$0] }
    }

    func document(id: String) -> DocumentHandle? {
        documents.first { $0.id == id }
    }

    /// "Untitled", "Untitled 2", ...
    func nextUntitledTitle() -> String {
        untitledCount += 1
        return untitledCount == 1 ? "Untitled" : "Untitled \(untitledCount)"
    }

    /// menu:File[New]: a blank document in a new tab.
    @discardableResult
    func newDocument(show: Bool = true) -> DocumentWindowController {
        open(environment.makeDocument(title: nextUntitledTitle(), isNew: true), show: show)
    }

    /// Where a newly opened document's window goes.
    enum TabPlacement {
        /// A tab of the front window (the default).
        case front
        /// A window of its own.
        case alone
        /// A tab of `window`.
        case with(NSWindow)
    }

    /// Opens `document` (bringing its window forward if it is open already).
    @discardableResult
    func open(_ document: DocumentHandle, show: Bool = true, placement: TabPlacement = .front) -> DocumentWindowController {
        if let existing = windowControllers[document.id] {
            if show { existing.showWindow(nil) }
            activate(existing)
            return existing
        }
        let front = activeWindowController
        let controller = makeView(of: document, state: nil)
        documents.append(document)
        views[document.id] = [controller]
        present(controller, show: show, placement: placement, front: front)
        activate(controller)
        // A glyph tab borrows its document's model: the document opened with its first window.
        if document.canvasNode == nil { environment.documentDidOpen(controller) }
        return controller
    }

    private func makeView(of document: DocumentHandle, state: DocumentWindowState?) -> DocumentWindowController {
        let controller = makeWindowController(document, environment, lastToolID, state)
        controller.onClose = { [weak self] closed in self?.windowDidClose(closed) }
        controller.onBecomeMain = { [weak self] main in self?.activate(main) }
        controller.onToolChange = { [weak self] changed, tool in self?.toolDidChange(in: changed, to: tool) }
        controller.onSelectionChange = { [weak self] changed in self?.viewDidChange(in: changed) }
        controller.onViewStateChange = { [weak self] changed in self?.viewDidChange(in: changed) }
        controller.onCloseAllViews = { [weak self] closing in self?.close(closing.documentHandle.id) }
        return controller
    }

    // MARK: Views (BASIC-016)

    func canOpenView(of documentID: String) -> Bool {
        (views[documentID]?.count ?? 0) < Self.maximumViews
    }

    /// menu:Window[New Window]: another view of the front document (or of `source`'s), in a new
    /// tab, starting as a copy of that view's state.  A ninth view is refused with a beep.
    @discardableResult
    func newView(of source: DocumentWindowController? = nil, show: Bool = true) -> DocumentWindowController? {
        guard let source = source ?? activeWindowController else { return nil }
        let document = source.documentHandle
        guard canOpenView(of: document.id) else {
            beep()
            return nil
        }
        var state = source.currentState
        state.frame = nil
        let controller = makeView(of: document, state: state)
        controller.isPrimaryView = false
        views[document.id, default: []].append(controller)
        present(controller, show: show, placement: source.window.map { .with($0) } ?? .front, front: source)
        activate(controller)
        return controller
    }

    /// The views of `documentID`, primary first.
    func views(of documentID: String) -> [DocumentWindowController] { views[documentID] ?? [] }

    private func present(_ controller: DocumentWindowController, show: Bool, placement: TabPlacement, front: DocumentWindowController?) {
        if show, let window = controller.window {
            let target: NSWindow? = switch placement {
            case .front: front?.window
            case .alone: nil
            case let .with(window): window
            }
            if let target, target.isVisible, target !== window {
                target.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            } else {
                // A preferred-tabbing window would join the front window on its own.
                let mode = window.tabbingMode
                window.tabbingMode = .disallowed
                window.makeKeyAndOrderFront(nil)
                window.tabbingMode = mode
            }
        }
    }

    /// The front window's selection or view state changed: the panels follow.
    private func viewDidChange(in controller: DocumentWindowController) {
        guard controller.documentHandle.id == activeDocumentID else { return }
        onChange?()
    }

    // MARK: Session (BASIC-001)

    /// Every open window as `WindowState`: its tab group, its place in the group, and which
    /// window was key.  Windows of one tab group share a group number.
    func sessionState() -> [WindowState] {
        var groups: [ObjectIdentifier: Int] = [:]
        var states: [WindowState] = []
        // Glyph tabs (FONT-003) are views of their document's model, not documents to reopen.
        for controller in allWindowControllers where controller.documentHandle.canvasNode == nil {
            guard let window = controller.window else { continue }
            let siblings = window.tabbedWindows ?? [window]
            let groupKey = ObjectIdentifier(siblings.first ?? window)
            let group = groups[groupKey] ?? groups.count
            groups[groupKey] = group
            let frame = window.frame
            states.append(WindowState(
                documentID: controller.documentHandle.id, title: controller.documentHandle.title,
                frame: LayoutRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
                tabGroup: group, tabIndex: siblings.firstIndex(of: window) ?? 0,
                key: controller.documentHandle.id == activeDocumentID
            ))
        }
        return states
    }

    /// Reopens a saved session: the same tabs in the same windows, the key window key again.
    /// Documents `isAvailable` refuses (trashed) are skipped without an error.  Returns the
    /// documents opened.
    @discardableResult
    func restore(_ states: [WindowState], isAvailable: (String) -> Bool) -> [DocumentWindowController] {
        var firstOfGroup: [Int: NSWindow] = [:]
        var opened: [DocumentWindowController] = []
        var key: DocumentWindowController?
        for state in states.sorted(by: { ($0.tabGroup, $0.tabIndex) < ($1.tabGroup, $1.tabIndex) }) where isAvailable(state.documentID) {
            let placement: TabPlacement = firstOfGroup[state.tabGroup].map { .with($0) } ?? .alone
            // A document already reopened by this restore had several views: this is another.
            if let existing = opened.first(where: { $0.documentHandle.id == state.documentID }) {
                if let view = newView(of: existing) {
                    if state.key { key = view }
                    opened.append(view)
                }
                continue
            }
            let controller = open(environment.makeDocument(id: state.documentID, title: state.title), placement: placement)
            if firstOfGroup[state.tabGroup] == nil, let window = controller.window {
                firstOfGroup[state.tabGroup] = window
                if let frame = state.frame { window.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false) }
            }
            if state.key { key = controller }
            opened.append(controller)
        }
        if let key {
            key.window?.makeKeyAndOrderFront(nil)
            activate(key)
        }
        return opened
    }

    /// Forgets `documentID` and closes every view of it (Option-click on a close button).
    func close(_ documentID: String) {
        // Additional views first, so the primary view's state is the one saved.
        for controller in (views[documentID] ?? []).reversed() {
            controller.window?.close()
            forget(controller)
        }
    }

    private func windowDidClose(_ controller: DocumentWindowController) {
        forget(controller)
    }

    private func forget(_ controller: DocumentWindowController) {
        let id = controller.documentHandle.id
        guard var list = views[id], let index = list.firstIndex(where: { $0 === controller }) else { return }
        list.remove(at: index)
        if list.isEmpty {
            views[id] = nil
            environment.documentDidClose(controller.documentHandle)
            documents.removeAll { $0.id == id }
            if activeDocumentID == id { activeDocumentID = documents.last?.id }
        } else {
            // The next view becomes the primary one, whose state persists.
            list[0].isPrimaryView = true
            views[id] = list
        }
        onChange?()
    }

    private func activate(_ controller: DocumentWindowController) {
        activeDocumentID = controller.documentHandle.id
        activeView = controller
        lastToolID = controller.toolManager.baseToolID
        onChange?()
    }

    private func toolDidChange(in controller: DocumentWindowController, to tool: ToolID) {
        lastToolID = controller.toolManager.baseToolID
        onChange?()
    }

    /// Saves every window's state (at quit, where windows do not get `windowWillClose`).
    func saveAllStates() {
        for controller in allWindowControllers { controller.saveState() }
    }
}
