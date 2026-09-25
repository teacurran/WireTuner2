import AppKit
import SwiftUI
import WTCRDT
import WTModel

/// Everything the destructive effect tasks add to the app, installed by `AppDelegate` in one call
/// (path-effects.adoc; FX-030, FX-032, FX-033): the Roughen, Fisheye Lens, Bend, Smudge and Shadow
/// tools in place of their catalog stubs, each with its options sheet; the Operations toolbar's
/// and menu:Extensions[Distort]'s *Add Points* and *Fractalize*; and the Distort submenu's tool
/// entries (*Roughen…*, *Fisheye Lens…*, *Bend…*, *Smudge…*, *3D Rotation…*), which choose the tool
/// in the front window and open its options.
@MainActor
enum DistortFeatures {
    typealias Target = ObjectMenuCommands.Target
    typealias Tools = ExtrudeMenu.Tools

    static let noPath = "Select a path"

    /// The Distort submenu's tool entries: extension id → tool.
    static let toolOperations: [(extension: String, tool: ToolID)] = [
        ("roughen", RoughenTool.id), ("fisheyeLens", FisheyeLensTool.id), ("bend", BendTool.id), ("smudge", SmudgeTool.id), ("rotation3D", Rotation3DTool.id),
    ]

    /// The tools, delivered over `store`; the Shadow tool's sheet previews through `target`.
    static func descriptors(store: PreferenceStore, target: @escaping Target) -> [ToolDescriptor] {
        func delivered(_ id: ToolID, _ make: @escaping @MainActor @Sendable () -> any Tool) -> ToolDescriptor {
            var descriptor = ToolCatalog.all.first { $0.id == id }!.delivering(make)
            if let keys = DistortPreferences.sheets[id] {
                let title = descriptor.title
                descriptor.options = { ToolOptionSheets.controller(title: title, keys: keys, store: store) }
            }
            return descriptor
        }
        var shadow = delivered(ShadowTool.id) { ShadowTool { ShadowSettings(preferences: store) } }
        shadow.options = { shadowOptions(store: store, target: target) }
        return [
            delivered(RoughenTool.id) { RoughenTool { RoughenSettings(preferences: store) } },
            delivered(FisheyeLensTool.id) { FisheyeLensTool { store[DistortPreferences.fisheyePerspective] } },
            delivered(BendTool.id) { BendTool { store[DistortPreferences.bendAmount] } },
            delivered(SmudgeTool.id) { SmudgeTool { SmudgeSettings(preferences: store) } },
            shadow,
        ]
    }

    /// The Shadow tool's options sheet (with btn:[Apply]).
    static func shadowOptions(store: PreferenceStore, target: @escaping Target) -> NSViewController {
        let preview = ShadowPreview(target: target) { ShadowSettings(preferences: store) }
        let holder = ControllerHolder()
        let controller = NSHostingController(rootView: ShadowOptionsSheet(store: store, preview: preview) { ToolOptionsPlaceholder.close(holder.controller?.view.window) })
        holder.controller = controller
        controller.title = "Shadow Options"
        return controller
    }

    // MARK: Operations

    /// The selected, unlocked paths.
    static func paths(_ editing: ObjectEditing) -> [OpID] {
        PathSplitting.targets(editing.selection.selection, document: editing.document).map(\.node)
    }

    /// menu:Extensions[Distort > Fractalize] (and the toolbar button): every segment of every
    /// selected path spiked, one change "Fractalize".
    static func fractalize(_ editing: ObjectEditing) -> (any WTModel.Command)? {
        let targets = PathSplitting.targets(editing.selection.selection, document: editing.document)
        guard !targets.isEmpty else { return nil }
        return DistortTargetsCommand.command(targets, label: "Fractalize", DistortKernels.fractalize)
    }

    /// The operations these tasks deliver, replacing their stubs.
    static func extensionDescriptors(existing: ExtensionRegistry, target: @escaping Target, tools: @escaping Tools, present: @escaping @MainActor (ToolDescriptor) -> Void,
                                     registry: ToolRegistry) -> [ExtensionDescriptor] {
        let pathSelected = BlendMenu.validation(target) { paths($0).isEmpty ? noPath : nil }
        var result: [ExtensionDescriptor] = []
        let operations: [(String, @MainActor (ObjectEditing) -> Void)] = [
            ("addPoints", { editing in editing.perform(AddPoints(paths(editing))) }),
            ("fractalize", { editing in if let command = fractalize(editing) { editing.perform(command) } }),
        ]
        for (id, run) in operations {
            guard var descriptor = existing.descriptor(for: id) else { continue }
            descriptor.validate = pathSelected
            descriptor.run = { _ in
                if let editing = target() { run(editing) }
                return nil
            }
            result.append(descriptor)
        }
        for (id, tool) in toolOperations {
            guard var descriptor = existing.descriptor(for: id) else { continue }
            descriptor.validate = { tools() == nil ? .disabled(BlendMenu.noDocument) : .enabled }
            descriptor.run = { _ in
                tools()?.select(tool)
                if let options = registry.descriptor(for: tool) { present(options) }
                return nil
            }
            result.append(descriptor)
        }
        return result
    }

    /// Delivers the tools and the operations.
    static func install(tools registry: ToolRegistry, extensions: ExtensionRegistry, store: PreferenceStore, target: @escaping Target, tools: @escaping Tools,
                        present: @escaping @MainActor (ToolDescriptor) -> Void) {
        for descriptor in descriptors(store: store, target: target) { registry.replace(descriptor) }
        for descriptor in extensionDescriptors(existing: extensions, target: target, tools: tools, present: present, registry: registry) {
            extensions.replace(descriptor)
        }
    }
}

/// Holds a sheet's controller weakly for its own dismiss action.
@MainActor
final class ControllerHolder {
    weak var controller: NSViewController?
}

/// A kernel applied to paths outside a drag (Fractalize).
@MainActor
enum DistortTargetsCommand {
    static func command(_ targets: [PathSplitting.Target], label: String, _ kernel: (DistortContour) -> DistortContour) -> any WTModel.Command {
        let commands: [any WTModel.Command] = targets.compactMap { target in
            guard let inverse = target.transform.inverted() else { return nil }
            let edits = target.contours.map { original in
                let shaped = kernel(DistortContour(points: PathSplitting.map(original.drawn, target.transform), closed: original.closed))
                return RewritePath.ContourEdit(contour: original.id, points: PathSplitting.restored(PathSplitting.map(shaped.points, inverse), from: original.drawn),
                                               closed: shaped.closed)
            }
            return RewritePath(node: target.node, edits: edits, label: label)
        }
        return CompositeCommand(label, commands)
    }
}
