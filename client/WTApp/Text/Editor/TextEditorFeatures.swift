import AppKit
import WTCRDT
import WTGeometry
import WTModel

/// The Text Editor's routes and windows (editing-text.adoc, "The Text Editor window"; TYPE-011):
/// menu:Text[Editor…] (kbd:[Cmd+Shift+E]) on the selected block or the Text tool's block,
/// kbd:[Option]-double-click with the Pointer, kbd:[Option]-click on a block with the Text tool, and
/// kbd:[Option]-click on empty page with the Text tool, which makes an empty block open in the
/// editor.  With *Always use Text Editor* the Text tool opens the window on any click into a
/// block.  One window per block; opening it again brings it forward.
@MainActor
final class TextEditorFeatures {
    static let shared = TextEditorFeatures()

    typealias Window = @MainActor () -> DocumentWindowController?
    static let noBlock = "Select a text block"

    /// The open editors by document and node.
    private(set) var controllers: [String: TextEditorController] = [:]
    /// Tests keep windows from ordering front.
    var showsWindows = true

    static func key(_ document: DocumentHandle, _ node: OpID) -> String { "\(document.id)#\(node)" }

    func controller(for node: OpID, in document: DocumentHandle) -> TextEditorController? {
        controllers[Self.key(document, node)]
    }

    /// The block menu:Text[Editor…] edits in `window`: the Text tool's block, else the one
    /// selected text block.
    static func target(in window: DocumentWindowController) -> OpID? {
        if let node = window.objectEditing.textSession?.node, window.objectEditing.textSession?.isLive == true { return node }
        let state = window.documentHandle.state
        let texts = window.selection.selection.ids.map(\.opID).filter { state.nodeKind($0) == .text }
        return texts.count == 1 ? texts[0] : nil
    }

    /// Opens (or brings forward) the editor of `node` in `window`; with no node, first creates an
    /// empty auto-expanding block at `point` (the Text tool's kbd:[Option]-click on empty page).
    /// The task answers the block edited.
    @discardableResult
    func open(_ node: OpID?, at point: Point = .zero, in window: DocumentWindowController) -> Task<OpID?, Never> {
        let document = window.documentHandle
        return Task { @MainActor in
            var target = node
            if target == nil {
                let command = CreateTextBlock(.point(point), text: "", layer: window.objectEditing.activeLayer)
                target = await window.objectEditing.perform(command).value?.createdObjects.first { document.state.nodeKind($0) == .text }
            }
            guard let target else { return nil }
            window.selection.model.set(Selection([SelectionID(target)]))
            self.show(target, in: window)
            return target
        }
    }

    /// The editor of `node` in `window`, made if needed, shown.
    @discardableResult
    func show(_ node: OpID, in window: DocumentWindowController) -> TextEditorController {
        let document = window.documentHandle
        let key = Self.key(document, node)
        if let existing = controllers[key] {
            if showsWindows { existing.window?.makeKeyAndOrderFront(nil) }
            return existing
        }
        let model = TextEditorModel(document: document, node: node, sink: window.objectEditing)
        let controller = TextEditorController(model: model, presence: window.presence)
        controller.onClose = { [weak self] in self?.controllers[key] = nil }
        controllers[key] = controller
        if showsWindows { controller.show() }
        return controller
    }

    /// Closes every editor of `document`.
    func closeAll(of document: DocumentHandle) {
        for (key, controller) in controllers where key.hasPrefix("\(document.id)#") { controller.close() }
    }

    func commands(window: @escaping Window) -> [Command] {
        [Command(id: ContextMenuCatalog.ID.textEditor, title: "Editor…", key: KeyEquivalent("e", [.command, .shift]),
                 menu: MenuPath(ContextMenuCatalog.Menu.text, section: 0), contexts: [.text], keywords: ["text editor", "edit text"],
                 validation: { window().flatMap(Self.target(in:)) == nil ? .disabled(Self.noBlock) : .enabled },
                 action: .perform { [weak self] in
                     guard let self, let front = window(), let node = Self.target(in: front) else { return }
                     self.open(node, in: front)
                 })]
    }

    func install(into registry: CommandRegistry, window: @escaping Window) {
        for command in commands(window: window) { registry.replace(command) }
    }
}
