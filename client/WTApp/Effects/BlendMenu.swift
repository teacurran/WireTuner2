import Foundation
import WTCRDT
import WTModel
import WTProto

/// The blend commands of the menus, the Operations toolbar and the Extensions menu (blends.adoc,
/// "Blending from the menu", "Joining a blend to a path", "Releasing a blend"; FX-028):
/// menu:Modify[Combine > Blend] (kbd:[Cmd+Shift+B]) and [Combine > Join Blend to Path],
/// menu:Modify[Split] on a joined blend, menu:Modify[Blend > Blend Steps…] and [Blend > Release],
/// and menu:Extensions[Create > Blend] (the toolbar's btn:[Blend]).  Every command is one change;
/// a selection that cannot be blended disables Blend with the sentence the model refuses with.
@MainActor
enum BlendMenu {
    typealias Target = ObjectMenuCommands.Target

    enum ID {
        static let joinBlendToPath: CommandID = "modify.combine.joinBlendToPath"
    }

    static let noDocument = "No document is open"
    static let noBlend = "Select a blend"
    static let notJoined = "Select a blend joined to a path"
    static let joinSelection = "Select a blend and a path"
    static let key = KeyEquivalent("b", [.command, .shift])

    // MARK: Reading the selection

    /// The selected objects in stacking order.
    static func objects(_ editing: ObjectEditing) -> [OpID] {
        let state = editing.document.state
        return Objects.stackingOrder(editing.selectedNodes.filter { Objects.isObject($0, in: state) }, in: state)
    }

    /// The selected blends.
    static func blends(_ editing: ObjectEditing) -> [OpID] {
        let state = editing.document.state
        return editing.selectedNodes.filter { state.nodeKind($0) == .blend && state.isLive($0) }
    }

    /// The selected blends that follow a path.
    static func joinedBlends(_ editing: ObjectEditing) -> [OpID] {
        let state = editing.document.state
        return blends(editing).filter { BlendReading.path(state.props($0).blend, children: state.liveChildren($0), in: state) != nil }
    }

    /// The point chosen on each object for a point-to-point blend: one selected point.
    static func points(_ editing: ObjectEditing) -> [OpID: BlendPointChoice] {
        var result: [OpID: BlendPointChoice] = [:]
        for id in editing.selection.selection.ids {
            guard case .points(let points)? = editing.selection.selection.subSelection(of: id), points.count == 1, let point = points.first else { continue }
            result[id.opID] = BlendPointChoice(contour: point.contour, point: point.point)
        }
        return result
    }

    /// Why the selection cannot be blended, or nil.
    static func refusal(_ editing: ObjectEditing) -> String? {
        BlendEligibility.refusal(objects(editing), in: editing.document.state)
    }

    /// The blend and the path of a Join Blend to Path selection.
    static func joinPair(_ editing: ObjectEditing) -> (blend: OpID, path: OpID)? {
        let state = editing.document.state
        let nodes = editing.selectedNodes
        guard nodes.count == 2, let blend = nodes.first(where: { state.nodeKind($0) == .blend }),
              let path = nodes.first(where: { state.nodeKind($0) == .path }) else { return nil }
        return (blend, path)
    }

    // MARK: Commands

    static func blendCommand(_ editing: ObjectEditing) -> (any WTModel.Command)? {
        guard refusal(editing) == nil else { return nil }
        return Blend(objects(editing), points: points(editing), layer: editing.activeLayer)
    }

    /// Blends the selection and selects the blend.
    @discardableResult
    static func blend(_ editing: ObjectEditing) -> Task<Void, Never>? {
        guard let command = blendCommand(editing) else { return nil }
        return performSelecting(command, editing)
    }

    /// Performs `command` and selects the first object it created.
    static func performSelecting(_ command: any WTModel.Command, _ editing: ObjectEditing) -> Task<Void, Never> {
        let task = editing.perform(command)
        let model = editing.selection.model
        return Task { @MainActor in
            guard let created = await task.value?.createdObjects.first else { return }
            model.set(Selection([SelectionID(created)]))
        }
    }

    static func validation(_ target: @escaping Target, _ reason: @escaping @MainActor (ObjectEditing) -> String?) -> @MainActor @Sendable () -> CommandValidation {
        { target().map { reason($0).map(CommandValidation.disabled) ?? .enabled } ?? .disabled(noDocument) }
    }

    static func commands(target: @escaping Target, blendSteps: @escaping @MainActor ([OpID]) -> Void) -> [Command] {
        let modify = ContextMenuCatalog.Menu.modify
        let ids = ContextMenuCatalog.ID.self
        func run(_ body: @escaping @MainActor (ObjectEditing) -> Void) -> CommandAction {
            .perform { if let editing = target() { body(editing) } }
        }
        return [
            Command(id: ids.combineBlend, title: "Blend", key: key, menu: MenuPath(modify, "Combine", section: 3), contexts: [.multiple],
                    keywords: ["blend", "steps", "interpolate"], validation: validation(target, refusal), action: run { blend($0) }),
            Command(id: ID.joinBlendToPath, title: "Join Blend to Path", menu: MenuPath(modify, "Combine", section: 3), keywords: ["blend", "path"],
                    validation: validation(target) { joinPair($0) == nil ? joinSelection : nil },
                    action: run { editing in
                        if let pair = joinPair(editing) { editing.perform(JoinBlendToPath(pair.blend, path: pair.path)) }
                    }),
            Command(id: ids.split, title: "Split", menu: MenuPath(modify, section: 3), keywords: ["blend", "path"],
                    validation: validation(target) { joinedBlends($0).isEmpty ? notJoined : nil },
                    action: run { editing in
                        let joined = joinedBlends(editing)
                        if !joined.isEmpty { editing.perform(SplitBlend(joined)) }
                    }),
            Command(id: ids.blendSteps, title: "Blend Steps…", menu: MenuPath(modify, "Blend", section: 4), contexts: [.blend], keywords: ["blend"],
                    validation: validation(target) { blends($0).isEmpty ? noBlend : nil },
                    action: run { editing in
                        let selected = blends(editing)
                        if !selected.isEmpty { blendSteps(selected) }
                    }),
            Command(id: ids.blendRelease, title: "Release", menu: MenuPath(modify, "Blend", section: 4), contexts: [.blend], keywords: ["blend", "ungroup"],
                    validation: validation(target) { blends($0).isEmpty ? noBlend : nil },
                    action: run { editing in
                        let selected = blends(editing)
                        if !selected.isEmpty { editing.perform(ReleaseBlend(selected)) }
                    }),
        ]
    }

    /// menu:Extensions[Create > Blend] and the Operations toolbar's btn:[Blend], replacing the stub.
    static func extensionDescriptor(existing: ExtensionRegistry, target: @escaping Target) -> ExtensionDescriptor? {
        guard var descriptor = existing.descriptor(for: "blend") else { return nil }
        descriptor.validate = validation(target, refusal)
        descriptor.run = { _ in
            if let editing = target() { blend(editing) }
            return nil
        }
        return descriptor
    }
}
