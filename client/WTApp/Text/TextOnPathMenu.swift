import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// menu:Text[Attach to Path] (kbd:[Cmd+Shift+Y]), menu:Text[Flow Inside Path] and menu:Text[Detach
/// from Path], the Text toolbar's buttons and the Object panel's (text-on-path.adoc; TYPE-017's
/// items for TYPE-041's commands).  Attach and Flow want one text block and one path selected (a
/// block already on a path is detached first); Detach takes every selected text on a path, or the
/// path of one.  Each is one change; the text stays selected.
@MainActor
enum TextOnPathMenu {
    typealias Target = ObjectMenuCommands.Target

    static let key = KeyEquivalent("y", [.command, .shift])
    static let pairNeeded = "Select a text block and a path"
    static let closedNeeded = "Select a text block and a closed path"
    static let alreadyOnPath = "The text is already on a path: detach it first"
    static let notOnPath = "Select text on a path"

    /// The text and path of the selection, when it is one text block and one path.
    static func pair(_ editing: ObjectEditing) -> (text: OpID, path: OpID)? {
        AttachTextToPath.pair(editing.selectedNodes, in: editing.document.state)
    }

    /// Whether text node `text` is on a path now (`on_path` set and a live `path` child).
    static func isOnPath(_ text: OpID, in state: EngineState) -> Bool {
        TextNode(text, in: state).map { TextLayoutReading.path(of: $0, in: state) != nil } ?? false
    }

    /// Why Attach (`mode` along) or Flow Inside (`inside`) cannot run, or nil.
    static func attachRefusal(_ editing: ObjectEditing, mode: Wiretuner_Doc_V1_PathTextMode) -> String? {
        let state = editing.document.state
        guard let (text, path) = pair(editing) else { return pairNeeded }
        if isOnPath(text, in: state) { return alreadyOnPath }
        if mode == .inside, !VectorPath(state.props(path).path, node: path, state: state).contours.contains(where: { $0.closed && $0.isRenderable }) {
            return closedNeeded
        }
        return nil
    }

    static func attachCommand(_ editing: ObjectEditing, mode: Wiretuner_Doc_V1_PathTextMode) -> AttachTextToPath? {
        guard attachRefusal(editing, mode: mode) == nil, let (text, path) = pair(editing) else { return nil }
        return AttachTextToPath(text: text, path: path, mode: mode)
    }

    /// The selected texts on a path, and the paths of texts on a path.
    static func detachTargets(_ editing: ObjectEditing) -> [OpID] {
        let state = editing.document.state
        return editing.selectedNodes.filter { node in
            switch state.nodeKind(node) {
            case .text: return isOnPath(node, in: state)
            case .path:
                guard let parent = Objects.parent(of: node, in: state), state.nodeKind(parent) == .text else { return false }
                return isOnPath(parent, in: state)
            default: return false
            }
        }
    }

    static func detachCommand(_ editing: ObjectEditing) -> DetachTextFromPath? {
        let targets = detachTargets(editing)
        return targets.isEmpty ? nil : DetachTextFromPath(targets)
    }

    /// Performs `command`, then selects the text alone.
    @discardableResult
    static func perform(_ command: any WTModel.Command, text: OpID, _ editing: ObjectEditing) -> Task<Void, Never> {
        let task = editing.perform(command)
        let model = editing.selection.model
        return Task { @MainActor in
            guard await task.value != nil else { return }
            model.set(Selection([SelectionID(text)]))
        }
    }

    /// Attach (`inside` false) or Flow Inside.
    @discardableResult
    static func attach(_ editing: ObjectEditing, mode: Wiretuner_Doc_V1_PathTextMode) -> Task<Void, Never>? {
        guard let command = attachCommand(editing, mode: mode) else { return nil }
        return perform(command, text: command.text, editing)
    }

    @discardableResult
    static func detach(_ editing: ObjectEditing) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        detachCommand(editing).map { editing.perform($0) }
    }

    static func commands(target: @escaping Target) -> [Command] {
        let ids = ContextMenuCatalog.ID.self
        let text = ContextMenuCatalog.Menu.text
        func run(_ body: @escaping @MainActor (ObjectEditing) -> Void) -> CommandAction {
            .perform { if let editing = target() { body(editing) } }
        }
        return [
            Command(id: ids.attachToPath, title: "Attach to Path", key: key, menu: MenuPath(text, section: 2),
                    keywords: ["text", "path", "curve"], validation: BlendMenu.validation(target) { attachRefusal($0, mode: .along) },
                    action: run { attach($0, mode: .along) }),
            Command(id: ids.detachFromPath, title: "Detach from Path", menu: MenuPath(text, section: 2),
                    keywords: ["text", "path"], validation: BlendMenu.validation(target) { detachTargets($0).isEmpty ? notOnPath : nil },
                    action: run { detach($0) }),
            Command(id: ids.flowInsidePath, title: "Flow Inside Path", menu: MenuPath(text, section: 2),
                    keywords: ["text", "path", "shape", "fill"], validation: BlendMenu.validation(target) { attachRefusal($0, mode: .inside) },
                    action: run { attach($0, mode: .inside) }),
        ]
    }

    static func install(into registry: CommandRegistry, target: @escaping Target) {
        for command in commands(target: target) { registry.replace(command) }
        InspectorRegistry.standard.register(section(target: target))
    }

    /// The Object panel's buttons: btn:[Attach to Path] and btn:[Flow Inside Path] for a text block
    /// and a path, btn:[Detach from Path] for text on a path.
    static func section(target: @escaping Target) -> InspectorSection {
        InspectorSection(id: "textPathActions", order: 14, kinds: [.text, .path]) { _ in
            guard let editing = target() else { return nil }
            let attach = pair(editing) != nil
            let detach = !detachTargets(editing).isEmpty
            guard attach || detach else { return nil }
            return AnyView(TextOnPathButtons(target: target, attach: attach, detach: detach,
                                             attachEnabled: attachRefusal(editing, mode: .along) == nil,
                                             flowEnabled: attachRefusal(editing, mode: .inside) == nil))
        }
    }
}

/// The Object panel's text-on-path buttons.
struct TextOnPathButtons: View {
    let target: TextOnPathMenu.Target
    let attach: Bool
    let detach: Bool
    let attachEnabled: Bool
    let flowEnabled: Bool

    static func attaching(_ target: @escaping TextOnPathMenu.Target, mode: Wiretuner_Doc_V1_PathTextMode) -> () -> Void {
        { if let editing = target() { TextOnPathMenu.attach(editing, mode: mode) } }
    }

    static func detaching(_ target: @escaping TextOnPathMenu.Target) -> () -> Void {
        { if let editing = target() { TextOnPathMenu.detach(editing) } }
    }

    var body: some View {
        HStack {
            if attach {
                Button("Attach to Path", action: Self.attaching(target, mode: .along)).disabled(!attachEnabled)
                    .accessibilityIdentifier("object.textPath.attach")
                Button("Flow Inside Path", action: Self.attaching(target, mode: .inside)).disabled(!flowEnabled)
                    .accessibilityIdentifier("object.textPath.flow")
            }
            if detach {
                Button("Detach from Path", action: Self.detaching(target)).accessibilityIdentifier("object.textPath.detach")
            }
        }
        .padding(.horizontal)
    }
}
