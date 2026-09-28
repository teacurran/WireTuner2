import AppKit
import WTCRDT
import WTInterchange
import WTModel
import WTProto

/// menu:Object[Convert to Editable] and the imported EPS context menu's item (IMG-060,
/// import-formats.adoc "Converting a placed EPS"): each selected placed EPS whose file carries a
/// PDF-compatible stream (or is a PostScript Illustrator file the legacy reader reads) is
/// replaced by its artwork as editable objects, at the place and size of its preview.  The file's
/// bytes come from this Mac's blob cache; the conversion runs off the main actor, the images inside
/// are stored and queued before the change, and each file is one change "Convert to Editable".
/// Files that cannot be converted -- plain PostScript, or bytes this Mac does not have yet -- are
/// named in one alert and stay placed.
extension ImportController {
    static let notCached = "its file has not been downloaded to this Mac yet; try again once it has synced."

    /// The selected placed files.
    static func placedFiles(_ window: DocumentWindowController) -> [OpID] {
        let state = window.documentHandle.state
        return window.objectEditing.selectedNodes.filter { ConvertPlacedFile.accepts($0, in: state) }
    }

    /// Converts the selected placed files of `window`; returns the groups that replaced them and
    /// the reasons for those that were not.
    @discardableResult
    func convertToEditable(in window: DocumentWindowController) async -> ImportOutcome {
        var outcome = ImportOutcome()
        let document = window.documentHandle
        let context = context
        for node in Self.placedFiles(window) {
            let content = document.state.props(node).placedFile.content
            let name = content.sourceName.isEmpty ? "The placed file" : content.sourceName
            guard let data = blobs.cached(content.blobSha256) else {
                outcome.failures.append("“\(name)”: \(Self.notCached)")
                continue
            }
            do {
                let scene = try await Task.detached(priority: .userInitiated) { try EPSImporter.editable(data, name: name, context: context) }.value
                try await blobs.store(scene.blobs, for: document)
                outcome.notes += scene.notes
                guard let change = await window.objectEditing.perform(ConvertPlacedFile(node, scene: scene)).value,
                      let root = zip(change.ops, change.opIDs).first(where: { op, _ in if case .create = op.op { true } else { false } })?.1 else { continue }
                outcome.placed.append(root)
            } catch {
                outcome.failures.append(Self.failure(error, name: name))
            }
        }
        if !outcome.placed.isEmpty { window.selection.model.set(Selection(outcome.placed.map { SelectionID($0) })) }
        if !outcome.notes.isEmpty { window.statusBar.show(message: outcome.notes.joined(separator: "  ")) }
        if !outcome.failures.isEmpty {
            let message = outcome.failures.count == 1 ? "A placed file could not be converted." : "\(outcome.failures.count) placed files could not be converted."
            showAlert(message, outcome.failures.joined(separator: "\n"), window.window)
        }
        return outcome
    }
}

enum ConvertToEditableCommand {
    static let noPlacedFile = "Select a placed EPS file"

    @MainActor
    static func command(imports: ImportController, window: @escaping @MainActor @Sendable () -> DocumentWindowController?) -> Command {
        Command(id: ContextMenuCatalog.ID.convertToEditable, title: "Convert to Editable", menu: MenuPath(ContextMenuCatalog.Menu.object, section: 0),
                contexts: [.importedGraphic], keywords: ["eps", "placed", "editable", "pdf", "convert"],
                validation: {
                    guard let front = window() else { return .disabled(ImportCommands.noDocument) }
                    return ImportController.placedFiles(front).isEmpty ? .disabled(noPlacedFile) : .enabled
                },
                action: .perform { if let front = window() { Task { await imports.convertToEditable(in: front) } } })
    }

    /// Replaces the context menu catalog's placeholder in place.
    @MainActor
    static func install(into registry: CommandRegistry, imports: ImportController, window: @escaping @MainActor @Sendable () -> DocumentWindowController?) {
        registry.replace(command(imports: imports, window: window))
    }
}
