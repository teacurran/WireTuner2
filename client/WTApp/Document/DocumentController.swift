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

    /// Opens `document` (bringing its window forward if it is open already).
    @discardableResult
    func open(_ document: DocumentHandle, show: Bool = true) -> DocumentWindowController {
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
        documents.append(document)
        windowControllers[document.id] = controller
        if show, let window = controller.window {
            if let frontWindow = front?.window, frontWindow.isVisible {
                frontWindow.addTabbedWindow(window, ordered: .above)
            }
            window.makeKeyAndOrderFront(nil)
        }
        activate(controller)
        return controller
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
