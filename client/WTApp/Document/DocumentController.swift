import AppKit

/// The open documents and their windows (no `NSDocument`: there is nothing to save, every
/// change is kept as it is made).  New documents open as tabs of the front window through
/// native window tabbing.  One window per document until BASIC-016 adds more views.
@MainActor
final class DocumentController {
    let environment: DocumentEnvironment
    /// Builds a document's window; replaceable in tests.
    var makeWindowController: @MainActor (DocumentHandle, DocumentEnvironment, ToolID) -> DocumentWindowController = {
        DocumentWindowController(document: $0, environment: $1, initialTool: $2)
    }
    /// Called after the open documents, the key window or its tool change (the Tools panel,
    /// menu validation).
    var onChange: (@MainActor () -> Void)?

    private(set) var documents: [DocumentHandle] = []
    private(set) var windowControllers: [String: DocumentWindowController] = [:]
    private(set) var activeDocumentID: String?
    /// The tool the last active window had; a new window starts with it.
    private(set) var lastToolID: ToolID = .pointer
    private var untitledCount = 0

    init(environment: DocumentEnvironment) {
        self.environment = environment
    }

    /// The window the View menu and tool shortcuts act on: the key/main window's, else the
    /// most recently active one.
    var activeWindowController: DocumentWindowController? {
        if let window = NSApp.mainWindow ?? NSApp.keyWindow,
            let controller = windowControllers.values.first(where: { $0.window === window })
        {
            return controller
        }
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
        open(DocumentHandle.placeholder(title: nextUntitledTitle()), show: show)
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
        let controller = makeWindowController(document, environment, lastToolID)
        controller.onClose = { [weak self] closed in self?.windowDidClose(closed) }
        controller.onBecomeMain = { [weak self] main in self?.activate(main) }
        controller.onToolChange = { [weak self] changed, tool in self?.toolDidChange(in: changed, to: tool) }
        controller.onSelectionChange = { [weak self] changed in self?.viewDidChange(in: changed) }
        controller.onViewStateChange = { [weak self] changed in self?.viewDidChange(in: changed) }
        documents.append(document)
        windowControllers[document.id] = controller
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
        activate(controller)
        return controller
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
        let ordered = documents.compactMap { windowControllers[$0.id] }
        for controller in ordered {
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
            let controller = open(DocumentHandle.placeholder(id: state.documentID, title: state.title), placement: placement)
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

    /// Forgets `documentID` and closes its window if it is still open.
    func close(_ documentID: String) {
        guard let controller = windowControllers[documentID] else { return }
        controller.window?.close()
        forget(controller)
    }

    private func windowDidClose(_ controller: DocumentWindowController) {
        forget(controller)
    }

    private func forget(_ controller: DocumentWindowController) {
        let id = controller.documentHandle.id
        guard windowControllers[id] === controller else { return }
        windowControllers[id] = nil
        documents.removeAll { $0.id == id }
        if activeDocumentID == id { activeDocumentID = documents.last?.id }
        onChange?()
    }

    private func activate(_ controller: DocumentWindowController) {
        activeDocumentID = controller.documentHandle.id
        lastToolID = controller.toolManager.baseToolID
        onChange?()
    }

    private func toolDidChange(in controller: DocumentWindowController, to tool: ToolID) {
        lastToolID = controller.toolManager.baseToolID
        onChange?()
    }

    /// Saves every window's state (at quit, where windows do not get `windowWillClose`).
    func saveAllStates() {
        for controller in windowControllers.values { controller.saveState() }
    }
}
