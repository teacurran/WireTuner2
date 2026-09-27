import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel

// The symbol editing window (library.adoc, "Editing symbols", "Symbol editing window"; LIB-012): a
// second window over the document's model whose builder draws a symbol's artwork (`canvasNode` =
// the symbol) on a white pasteboard with the origin marked, and whose commands create into the
// symbol (`SymbolPlacedCommand`).  Tools, panels and undo work unchanged, because the model is the
// document's; it shares the document's session and presence, needs no save, is titled
// "Symbol: <name>", has a btn:[Done] button, and closes itself when the symbol is removed.

/// A symbol's canvas: the handle id, the title, the handle.
@MainActor
enum SymbolWindowCanvas {
    nonisolated static let marker = "#symbol-"

    /// The id a symbol window's handle goes by: its document's, the symbol's.
    static func handleID(document: String, symbol: OpID) -> String { "\(document)\(marker)\(symbol)" }

    /// Whether `id` names a symbol window's handle.
    static func isSymbolWindow(_ id: String) -> Bool { id.contains(marker) }

    /// "Symbol: <name>".
    static func title(of symbol: OpID, in state: EngineState) -> String {
        "Symbol: \(SymbolLibraryModel.name(of: symbol, in: state))"
    }

    /// A handle drawing `symbol`'s canvas over `document`'s open model.
    static func handle(for symbol: OpID, of document: DocumentHandle) -> DocumentHandle {
        let handle = DocumentHandle(id: handleID(document: document.id, symbol: symbol), title: title(of: symbol, in: document.state),
                                    replicaID: document.replicaID, model: document.model!, canvasNode: symbol)
        handle.canvasBackground = { state in Symbols.canvasBackground(of: symbol, in: state) }
        handle.refreshBackground()
        return handle
    }
}

extension DocumentHandle {
    /// The symbol this handle's canvas draws (a symbol editing window), nil otherwise.
    var symbolCanvasNode: OpID? {
        guard let canvasNode, state.store.kind(canvasNode) == NodeKind.symbol.rawValue else { return nil }
        return canvasNode
    }
}

/// Opens symbol editing windows and keeps them in step with their symbols.  One per app.
@MainActor
final class SymbolEditingWindows {
    static let noSymbol = "Select one instance"
    static let done = "Done"

    /// The open documents (windows open through it); nil in tests, which get a free-standing window.
    weak var documents: DocumentController?
    /// Every open symbol window by handle id.
    private(set) var windows: [String: DocumentWindowController] = [:]
    private var tokens: [String: DocumentHandle.ObservationToken] = [:]

    init() {}

    /// menu:Modify[Symbol > Edit Symbol]'s symbol: the one selected instance's (not a placeholder).
    static func editableSymbol(in window: DocumentWindowController) -> OpID? {
        let state = window.documentHandle.state
        let ids = window.selection.model.selection.ids.map(\.opID)
        guard ids.count == 1, state.nodeKind(ids[0]) == .instance else { return nil }
        return Symbols.symbol(of: ids[0], in: state)
    }

    /// The document window a symbol window (or a master or glyph tab) of `source`'s document
    /// belongs to (`source` itself for the document's own window).
    func documentWindow(of source: DocumentWindowController) -> DocumentWindowController {
        let id = GlyphCanvas.documentID(ofTab: source.documentHandle.id)
        return documents?.windowControllers[id] ?? source
    }

    /// Opens `symbol` in a window of its own (or brings its window forward); nil when it is not a
    /// live symbol or the document's model is not open.
    @discardableResult
    func open(_ symbol: OpID, from source: DocumentWindowController) -> DocumentWindowController? {
        let parent = documentWindow(of: source)
        let document = parent.documentHandle
        guard document.model != nil, document.state.isLive(symbol), document.state.nodeKind(symbol) == .symbol else { return nil }
        let id = SymbolWindowCanvas.handleID(document: GlyphCanvas.documentID(ofTab: document.id), symbol: symbol)
        if let existing = windows[id] {
            existing.showWindow(nil)
            return existing
        }
        let handle = SymbolWindowCanvas.handle(for: symbol, of: document)
        let controller: DocumentWindowController
        if let documents {
            controller = documents.open(handle, placement: .alone)
        } else {
            controller = DocumentWindowController(document: handle, environment: MasterTabs.environment(parent.environment, parent: parent))
        }
        controller.isPrimaryView = false
        configure(controller, symbol: symbol)
        return controller
    }

    /// A symbol window: no page controls, the artwork fitted, btn:[Done], the title following the
    /// symbol's name, closed when the symbol goes.
    func configure(_ controller: DocumentWindowController, symbol: OpID) {
        let id = controller.documentHandle.id
        windows[id] = controller
        for control in [controller.statusBar.addPage, controller.statusBar.previousPage, controller.statusBar.pageField, controller.statusBar.nextPage] {
            control.isHidden = true
        }
        controller.window?.tabbingMode = .disallowed
        if let window = controller.window {
            let accessory = NSTitlebarAccessoryViewController()
            let hosting = NSHostingView(rootView: SymbolWindowDoneButton { [weak window] in window?.performClose(nil) })
            hosting.frame = NSRect(x: 0, y: 0, width: 72, height: 28)
            accessory.view = hosting
            accessory.layoutAttribute = .trailing
            window.addTitlebarAccessoryViewController(accessory)
        }
        fit(controller, symbol: symbol)
        let handle = controller.documentHandle
        tokens[id] = handle.observe { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.symbolDidChange(controller, symbol: symbol)
        }
        let previous = controller.onClose
        controller.onClose = { [weak self] closed in
            previous?(closed)
            self?.forget(closed)
        }
    }

    /// The window shows the whole artwork.
    func fit(_ controller: DocumentWindowController, symbol: OpID) {
        let bounds = Symbols.canvasBounds(of: symbol, in: controller.documentHandle.state)
        controller.setViewport(controller.canvas.navigation.fit(controller.viewport, rect: bounds.expanded(by: 36)))
    }

    /// The document changed: the window follows the symbol's name, and closes once the
    /// symbol is deleted.
    func symbolDidChange(_ controller: DocumentWindowController, symbol: OpID) {
        let state = controller.documentHandle.state
        guard state.isLive(symbol) else {
            controller.window?.close()
            forget(controller)
            return
        }
        // The origin cross follows the symbol's origin through the handle's background.
        let title = SymbolWindowCanvas.title(of: symbol, in: state)
        if controller.documentHandle.title != title { controller.documentHandle.title = title }
    }

    /// The window closed.
    func forget(_ controller: DocumentWindowController) {
        let id = controller.documentHandle.id
        guard windows.removeValue(forKey: id) != nil else { return }
        if let token = tokens.removeValue(forKey: id) { controller.documentHandle.stopObserving(token) }
    }

    /// menu:Modify[Symbol > Edit Symbol].
    func command(window: @escaping @MainActor () -> DocumentWindowController?) -> Command {
        Command(id: ContextMenuCatalog.ID.editSymbol, title: "Edit Symbol", menu: MenuPath(ContextMenuCatalog.Menu.modify, "Symbol", section: 4),
                contexts: ContextMenuCatalog.objectContexts, keywords: ["symbol", "instance", "library"],
                validation: { window().flatMap(Self.editableSymbol) == nil ? .disabled(Self.noSymbol) : .enabled },
                action: .perform { [weak self] in
                    guard let window = window(), let symbol = Self.editableSymbol(in: window) else { return }
                    self?.open(symbol, from: window)
                })
    }
}

/// The symbol window's btn:[Done].
struct SymbolWindowDoneButton: View {
    let action: () -> Void

    var body: some View {
        Button(SymbolEditingWindows.done, action: action).accessibilityIdentifier("symbol.done").padding(.trailing, 8)
    }
}
