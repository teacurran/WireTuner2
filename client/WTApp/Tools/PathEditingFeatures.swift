import AppKit
import WTModel

/// The path tools and commands of DRAW-018, DRAW-020, DRAW-027, DRAW-028 and OBJ-035: the
/// Variable Stroke Pen, the Knife, the Freeform tool, Mirror and 3D Rotation replace their
/// catalog placeholders, each with its options sheet over `PathToolPreferences`, and
/// menu:Modify[Split] splits the selected paths at their selected points.
@MainActor
enum PathEditingFeatures {
    typealias Target = @MainActor () -> ObjectEditing?

    static let noPoints = "Select points to split at"

    /// The tools, delivered over `store`.
    static func descriptors(store: PreferenceStore) -> [ToolDescriptor] {
        func delivered(_ id: ToolID, _ make: @escaping @MainActor @Sendable () -> any Tool) -> ToolDescriptor {
            var descriptor = ToolCatalog.all.first { $0.id == id }!.delivering(make)
            if let keys = PathToolPreferences.sheets[id] {
                let title = descriptor.title
                descriptor.options = { ToolOptionSheets.controller(title: title, keys: keys, store: store) }
            }
            return descriptor
        }
        return [
            delivered(VariableStrokePen.id) { VariableStrokePen { VariableStrokeSettings(preferences: store) } },
            delivered(KnifeTool.id) { KnifeTool { KnifeSettings(preferences: store) } },
            delivered(FreeformTool.id) { FreeformTool { FreeformSettings(preferences: store) } },
            delivered(MirrorTool.id) { MirrorTool { MirrorSettings(preferences: store) } },
            delivered(Rotation3DTool.id) { Rotation3DTool { Rotation3DSettings(preferences: store) } },
        ]
    }

    /// menu:Modify[Split] at the selected points.  The one Split item is shared: with no points to
    /// split at it does what `previous` does (a blend's Split, and OBJ-024's composite split once
    /// it is registered under the same id).
    static func commands(target: @escaping Target, previous: Command? = nil) -> [Command] {
        let fallback = previous?.validation ?? { .disabled(noPoints) }
        let previousAction = previous?.action
        return [
            Command(id: ContextMenuCatalog.ID.split, title: "Split", menu: MenuPath(ContextMenuCatalog.Menu.modify, section: 3),
                    contexts: ContextMenuCatalog.objectContexts, keywords: ["cut", "points", "blend", "path"],
                    validation: {
                        guard let editing = target(), PathSplitting.canSplit(editing.selection.selection, document: editing.document) else { return fallback() }
                        return .enabled
                    },
                    action: .perform {
                        if let editing = target(), let command = PathSplitting.split(editing.selection.selection, document: editing.document) {
                            editing.perform(command)
                        } else if case .perform(let run)? = previousAction {
                            run()
                        }
                    }),
        ]
    }

    /// Delivers the tools, and the Split item over whatever Split `commands` holds now (install
    /// after the blend commands).
    static func install(tools: ToolRegistry, commands: CommandRegistry, store: PreferenceStore, target: @escaping Target) {
        for descriptor in descriptors(store: store) { tools.replace(descriptor) }
        for command in self.commands(target: target, previous: commands.command(ContextMenuCatalog.ID.split)) { commands.replace(command) }
    }
}
