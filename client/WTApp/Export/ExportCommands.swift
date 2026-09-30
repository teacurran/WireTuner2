import AppKit
import WTInterchange
import WTModel

/// menu:File[Export…] (kbd:[Cmd+Shift+R], replacing the standard placeholder) and menu:File
/// [Export Again] (kbd:[Cmd+Option+Shift+R]) (exporting.adoc).
enum ExportCommands {
    enum ID {
        static let export = StandardCommands.ID.export
        static let exportAgain: CommandID = "file.exportAgain"
    }

    static let noDocument = "No document is open"

    struct Hooks {
        var window: @MainActor @Sendable () -> DocumentWindowController?
        var export: @MainActor @Sendable (DocumentWindowController) -> Void
        var exportAgain: @MainActor @Sendable (DocumentWindowController) -> Void
    }

    @MainActor
    static func commands(_ hooks: Hooks) -> [Command] {
        let file = StandardCommands.Menu.file
        let window = hooks.window
        let needsDocument: @MainActor @Sendable () -> CommandValidation = { window() == nil ? .disabled(noDocument) : .enabled }
        return [
            Command(id: ID.export, title: "Export…", key: KeyEquivalent("r", [.command, .shift]), menu: MenuPath(file, section: 2),
                    keywords: ["pdf", "svg", "png", "jpeg", "eps", "save as", "file"], validation: needsDocument,
                    action: .perform { window().map(hooks.export) }),
            Command(id: ID.exportAgain, title: "Export Again", key: KeyEquivalent("r", [.command, .option, .shift]), menu: MenuPath(file, section: 2),
                    keywords: ["repeat", "export"], validation: needsDocument, action: .perform { window().map(hooks.exportAgain) }),
        ]
    }

    @MainActor
    static func install(into registry: CommandRegistry, hooks: Hooks) {
        for command in commands(hooks) { registry.replace(command) }
    }

    /// The hooks over the app's export controller.
    @MainActor
    static func hooks(exports: ExportController, window: @escaping @MainActor @Sendable () -> DocumentWindowController?) -> Hooks {
        Hooks(
            window: window,
            export: { target in Task { await exports.export(target) } },
            exportAgain: { target in Task { await exports.exportAgain(target) } }
        )
    }
}

extension AppDelegate {
    /// The export commands and the glue between the export, package and import controllers:
    /// the blob cache and the account.
    func installExports() {
        let documents = documents!
        let imports = imports
        let account = account
        exports.blobs = imports.blobs
        exports.account = { (account.profile?.accountID ?? "", account.profile?.displayName ?? "") }
        // Exports lay text out with the document's own engine, as the canvas does.
        exports.configureBuilder = { builder, document in builder.textLayout = TextSceneLayout(engine: document.textEngine) }
        // Exports decide their RGB space by the document gamut scan the colour panels keep (CMS-015).
        let workspace = colors.workspace
        exports.gamut = { workspace.swatches(for: $0)?.widestSpaceUsed }
        ExportCommands.install(into: commands, hooks: ExportCommands.hooks(exports: exports) { documents.activeWindowController })
    }
}
