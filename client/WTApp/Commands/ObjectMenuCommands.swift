import Foundation
import WTModel

/// The object commands of the Edit and Modify menus that OBJ-010 to OBJ-020 and OBJ-031 deliver
/// (replacing their placeholders): Duplicate, Clone, Paste In Front, Paste Behind, Group, Ungroup,
/// Lock, Unlock, the four Arrange commands, *Transform Again* and menu:Extensions[Distort > Add
/// Points].  Cut, Copy and Paste stay responder-chain commands (a text field keeps its own); the
/// document window implements them through the same `ObjectEditing`.
@MainActor
enum ObjectMenuCommands {
    typealias Target = @MainActor () -> ObjectEditing?

    enum ID {
        static let pasteInFront: CommandID = "edit.special.pasteInFront"
        static let pasteAndMatchStyle: CommandID = "edit.pasteAndMatchStyle"
        static let transformAgain: CommandID = "modify.transform.again"
        static let addPoints: CommandID = "extensions.distort.addPoints"
    }

    static let noSelection = "Nothing is selected"

    static func commands(target: @escaping Target) -> [Command] {
        let ids = ContextMenuCatalog.ID.self
        let edit = StandardCommands.Menu.edit, modify = ContextMenuCatalog.Menu.modify
        func selected(_ condition: @escaping @MainActor (ObjectEditing) -> Bool = { $0.hasSelection }, reason: String = noSelection)
            -> @MainActor @Sendable () -> CommandValidation {
            { target().map { condition($0) ? .enabled : .disabled(reason) } ?? .disabled("No document is open") }
        }
        func run(_ body: @escaping @MainActor (ObjectEditing) -> Void) -> CommandAction {
            .perform { if let editing = target() { body(editing) } }
        }
        let arrange: [(CommandID, Arrange.Direction, KeyEquivalent)] = [
            (ids.bringToFront, .bringToFront, KeyEquivalent("up", [.command, .shift])),
            (ids.bringForward, .bringForward, KeyEquivalent("up", .command)),
            (ids.sendBackward, .sendBackward, KeyEquivalent("down", .command)),
            (ids.sendToBack, .sendToBack, KeyEquivalent("down", [.command, .shift])),
        ]
        var commands: [Command] = [
            Command(id: ids.duplicate, title: "Duplicate", key: KeyEquivalent("d", .command), menu: MenuPath(edit, section: 1),
                    contexts: ContextMenuCatalog.objectContexts, keywords: ["copy", "power duplicate"],
                    validation: selected(), action: run { $0.duplicate() }),
            Command(id: ids.clone, title: "Clone", menu: MenuPath(edit, section: 1), contexts: ContextMenuCatalog.objectContexts,
                    keywords: ["copy"], validation: selected(), action: run { $0.clone() }),
            Command(id: ID.pasteInFront, title: "Paste In Front", key: KeyEquivalent("v", [.command, .option]), menu: MenuPath(edit, "Special", section: 1),
                    keywords: ["paste"], validation: selected({ $0.canPasteNextToSelection }, reason: "Select an object and copy something first"),
                    action: run { $0.paste(inFront: true) }),
            // With the Text tool's insertion point the key is *Paste and Match Style* (TYPE-009).
            Command(id: ids.pasteBehind, title: "Paste Behind", key: KeyEquivalent("v", [.command, .option, .shift]), menu: MenuPath(edit, "Special", section: 1),
                    contexts: [.pasteboard, .page], keywords: ["paste"],
                    validation: selected({ $0.textSession?.canPaste == true || $0.canPasteNextToSelection }, reason: "Select an object and copy something first"),
                    action: run { editing in
                        if let text = editing.textSession { text.pasteAndMatchStyle() } else { editing.paste(inFront: false) }
                    }),
            Command(id: ID.pasteAndMatchStyle, title: "Paste and Match Style", menu: MenuPath(edit, section: 1),
                    contexts: [.textEditing], keywords: ["paste", "plain text", "strip formatting"],
                    validation: selected({ $0.textSession?.canPaste == true }, reason: "Place the insertion point in text and copy some text first"),
                    action: run { $0.textSession?.pasteAndMatchStyle() }),
            Command(id: ids.group, title: "Group", key: KeyEquivalent("g", .command), menu: MenuPath(modify, section: 0),
                    contexts: ContextMenuCatalog.objectContexts, validation: selected(), action: run { $0.group() }),
            Command(id: ids.ungroup, title: "Ungroup", key: KeyEquivalent("g", [.command, .shift]), menu: MenuPath(modify, section: 0),
                    contexts: ContextMenuCatalog.objectContexts, keywords: ["convert to path"],
                    validation: selected({ $0.canUngroup }, reason: "Select a group, rectangle, ellipse or polygon"), action: run { $0.ungroup() }),
            Command(id: ids.lock, title: "Lock", key: KeyEquivalent("l", .command), menu: MenuPath(modify, section: 1),
                    contexts: ContextMenuCatalog.objectContexts,
                    validation: selected({ $0.canSetLocked(true) }, reason: "Nothing unlocked is selected"), action: run { $0.setLocked(true) }),
            Command(id: ids.unlock, title: "Unlock", key: KeyEquivalent("l", [.command, .shift]), menu: MenuPath(modify, section: 1),
                    contexts: ContextMenuCatalog.objectContexts,
                    validation: selected({ $0.canSetLocked(false) }, reason: "Nothing locked is selected"), action: run { $0.setLocked(false) }),
            Command(id: ID.transformAgain, title: "Transform Again", key: KeyEquivalent("t", [.command, .shift]), menu: MenuPath(modify, "Transform", section: 2, subsection: 1),
                    keywords: ["repeat"], validation: selected({ $0.canTransformAgain }, reason: "Nothing has been transformed yet"),
                    action: run { $0.transformAgain() }),
            Command(id: ID.addPoints, title: "Add Points", menu: MenuPath("Extensions", "Distort"), keywords: ["subdivide"],
                    validation: selected({ $0.hasSelectedPaths }, reason: "Select a path"), action: run { $0.addPoints() }),
        ]
        for (id, direction, key) in arrange {
            commands.append(Command(id: id, title: direction.title, key: key, menu: MenuPath(modify, "Arrange", section: 2),
                                    contexts: ContextMenuCatalog.objectContexts, keywords: ["stacking", "order"],
                                    validation: selected(), action: run { $0.arrange(direction) }))
        }
        return commands
    }

    static func install(into registry: CommandRegistry, target: @escaping Target) {
        for command in commands(target: target) { registry.replace(command) }
    }
}
