import Foundation

/// The selection tools' options (selecting.adoc, "Marquee behavior").  They are set in the
/// tool's options sheet (OBJ-005), not in the Preferences window, so they are not in
/// `PreferenceCatalog.all` (which mirrors the preferences page row by row); they are stored
/// and synced like any other key.
enum SelectionToolOptions {
    /// Shared by the Pointer and Subselect tools.
    static let contactSensitive = PreferenceKey<Bool>(
        "tools.pointer.contact_sensitive", "Contact-sensitive selection", category: .general, default: false,
        control: .toggle, help: "selecting"
    )
    static let lassoContactSensitive = PreferenceKey<Bool>(
        "tools.lasso.contact_sensitive", "Contact-sensitive selection", category: .general, default: false,
        control: .toggle, help: "selecting"
    )
}

/// What APP-006 installs: the Pointer tool in place of its stub, and menu:Edit[Select > All /
/// None / Invert Selection].  The three commands are responder-chain commands so a focused text
/// field keeps its own Select All, and so kbd:[Tab] (Select None) is disabled -- and reaches the
/// field -- while a field has focus; `DocumentWindowController` implements and validates them.
/// OBJ-006 adds *All in Document*, *Superselect* and *Subselect All* beside them.
enum SelectionCommands {
    enum ID {
        static let selectAll = StandardCommands.ID.selectAll
        static let selectNone: CommandID = "edit.select.none"
        static let invert: CommandID = "edit.select.invert"
    }

    static let submenu = "Select"
    static let selectAllSelector = "selectAll:"
    static let selectNoneSelector = "selectNone:"
    static let invertSelector = "invertSelection:"

    static func commands() -> [Command] {
        let edit = StandardCommands.Menu.edit
        let path = MenuPath(edit, submenu, section: 1)
        return [
            .responder(
                id: ID.selectAll, title: "All", key: KeyEquivalent("a", .command), menu: path,
                contexts: [.pasteboard, .page, .textEditing], keywords: ["select all"], selector: selectAllSelector
            ),
            .responder(id: ID.selectNone, title: "None", key: KeyEquivalent("tab"), menu: path, keywords: ["deselect"], selector: selectNoneSelector),
            .responder(id: ID.invert, title: "Invert Selection", menu: path, keywords: ["inverse"], selector: invertSelector),
        ]
    }

    @MainActor
    static func install(commands registry: CommandRegistry, tools: ToolRegistry) {
        tools.replace(PointerTool.descriptor)
        for command in commands() { registry.replace(command) }
    }
}
