import AppKit

/// The File menu's import and package commands: menu:File[Import…] (kbd:[Cmd+R], importing.adoc)
/// replaces the standard placeholder in place; menu:File[Open Package…] sits under Open… and
/// menu:File[Export a Package…] under Export… (saving.adoc).  The sync popover's *Export a
/// Package…* runs `file.exportPackage` too.
enum ImportCommands {
    enum ID {
        static let importFile = StandardCommands.ID.importFile
        static let openPackage: CommandID = "file.openPackage"
        static let exportPackage: CommandID = "file.exportPackage"
    }

    static let noDocument = "No document is open"

    /// What the commands act on.
    struct Hooks {
        /// The front document window.
        var window: @MainActor @Sendable () -> DocumentWindowController?
        var importFiles: @MainActor @Sendable (DocumentWindowController) -> Void
        var openPackage: @MainActor @Sendable () -> Void
        var exportPackage: @MainActor @Sendable (DocumentWindowController) -> Void
    }

    @MainActor
    static func commands(_ hooks: Hooks) -> [Command] {
        let file = StandardCommands.Menu.file
        let window = hooks.window
        let needsDocument: @MainActor @Sendable () -> CommandValidation = { window() == nil ? .disabled(noDocument) : .enabled }
        return [
            Command(id: ID.importFile, title: "Import…", key: KeyEquivalent("r", .command), menu: MenuPath(file, section: 2),
                    keywords: ["place", "image", "pdf", "svg", "file"], validation: needsDocument,
                    action: .perform { if let target = window() { hooks.importFiles(target) } }),
            Command(id: ID.openPackage, title: "Open Package…", menu: MenuPath(file), keywords: ["wiretuner", "package", "archive"],
                    action: .perform { hooks.openPackage() }),
            Command(id: ID.exportPackage, title: "Export a Package…", menu: MenuPath(file, section: 2),
                    keywords: ["wiretuner", "package", "backup", "archive"], validation: needsDocument,
                    action: .perform { if let target = window() { hooks.exportPackage(target) } }),
        ]
    }

    @MainActor
    static func install(into registry: CommandRegistry, hooks: Hooks) {
        for command in commands(hooks) { registry.replace(command) }
    }

    /// The hooks over the app's import and package controllers.
    @MainActor
    static func hooks(imports: ImportController, packages: PackageController,
                      window: @escaping @MainActor @Sendable () -> DocumentWindowController?) -> Hooks {
        Hooks(
            window: window,
            importFiles: { target in Task { await imports.runImport(on: target) } },
            openPackage: { Task { await packages.openPackage() } },
            exportPackage: { target in Task { await packages.exportPackage(of: target) } }
        )
    }
}
