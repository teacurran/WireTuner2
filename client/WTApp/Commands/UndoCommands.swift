import AppKit

/// menu:Edit[Undo] and menu:Edit[Redo] over the front document's `WTModel.Document` (client.adoc,
/// "Undo"): the titles are the change labels ("Undo Rectangle"), disabled when the stack is empty.
/// While a text field edits, the keys go to the field's own undo through the responder chain.
@MainActor
enum UndoCommands {
    /// The document the commands act on.
    typealias WindowProvider = @MainActor () -> DocumentWindowController?

    static func commands(window: @escaping WindowProvider) -> [Command] {
        let menu = MenuPath(StandardCommands.Menu.edit)
        return [
            Command(
                id: StandardCommands.ID.undo, title: "Undo", key: KeyEquivalent("z", .command), menu: menu, keywords: ["revert"],
                validation: { validation(window(), undo: true) },
                action: .perform { perform(window(), undo: true) }
            ),
            Command(
                id: StandardCommands.ID.redo, title: "Redo", key: KeyEquivalent("z", [.command, .shift]), menu: menu,
                validation: { validation(window(), undo: false) },
                action: .perform { perform(window(), undo: false) }
            ),
        ]
    }

    /// Replaces the standard responder-chain Undo and Redo.
    static func install(into registry: CommandRegistry, window: @escaping WindowProvider) {
        for command in commands(window: window) { registry.replace(command) }
    }

    static func validation(_ window: DocumentWindowController?, undo: Bool) -> CommandValidation {
        guard let window else { return CommandValidation(isEnabled: false, title: undo ? "Undo" : "Redo") }
        if window.isEditingText { return CommandValidation(isEnabled: true, title: undo ? "Undo" : "Redo") }
        let document = window.documentHandle
        return undo
            ? CommandValidation(isEnabled: document.canUndo, title: document.undoTitle)
            : CommandValidation(isEnabled: document.canRedo, title: document.redoTitle)
    }

    static func perform(_ window: DocumentWindowController?, undo: Bool) {
        guard let window else { return }
        if window.isEditingText {
            NSApp.sendAction(Selector(undo ? "undo:" : "redo:"), to: nil, from: nil)
            return
        }
        if undo { window.documentHandle.undo() } else { window.documentHandle.redo() }
    }
}
