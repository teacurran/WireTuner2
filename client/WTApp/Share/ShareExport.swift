import AppKit
import WTModel

/// menu:File[Share] and the toolbar's Share item for exports (exporting.adoc, "The Share menu and
/// Services"; IO-037): the files the *Quick Export preset* writes -- for the selection, else the
/// current page -- handed to the destinations macOS offers through `NSSharingServicePicker`.  The
/// files are written into a folder of their own under the temporary directory from the document as
/// it is when the command runs (deviation: written then, not promised, since Mail and Messages take
/// file URLs).  With kbd:[Option] the preset is chosen from a menu for this once.
@MainActor
final class ShareExport {
    static let id: CommandID = "file.shareExport"
    static let noDocument = QuickExport.noDocument

    let quickExport: QuickExport
    /// Where the prepared files go (a fresh folder per share).
    var folder: @MainActor () -> URL = {
        FileManager.default.temporaryDirectory.appendingPathComponent("WireTuner Share", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
    /// Shows the destinations for the prepared files; tests replace it.
    var present: @MainActor ([URL], DocumentWindowController) -> Void = { ShareExport.picker($0, window: $1) }
    private(set) var running: Task<[URL], Never>?

    init(quickExport: QuickExport) {
        self.quickExport = quickExport
    }

    /// Writes `window`'s export with `preset` and answers the files (empty when it failed).
    func prepare(_ window: DocumentWindowController, preset: ExportPreset) async -> [URL] {
        let settings = quickExport.settings(preset, for: window)
        let directory = folder()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(window.documentHandle.title).appendingPathExtension(settings.format.fileExtension)
        guard case .exported(let summary) = await quickExport.exports.perform(settings, to: url, from: window) else { return [] }
        return summary.files
    }

    /// The command: prepare with the preset (kbd:[Option]: the chosen one), then offer the files.
    @discardableResult
    func share(_ window: DocumentWindowController) -> Task<[URL], Never>? {
        let preset: ExportPreset
        if quickExport.optionHeld() {
            guard let chosen = quickExport.choosePreset(quickExport.exports.presets.all) else { return nil }
            preset = chosen
        } else {
            preset = quickExport.preset
        }
        let task = Task { @MainActor () -> [URL] in
            let files = await self.prepare(window, preset: preset)
            if !files.isEmpty { self.present(files, window) }
            return files
        }
        running = task
        return task
    }

    /// The system's picker under the window's toolbar (or its content's top edge).
    static func picker(_ files: [URL], window: DocumentWindowController) {
        guard let content = window.window?.contentView else { return }
        let picker = NSSharingServicePicker(items: files)
        let anchor = NSRect(x: content.bounds.midX - 1, y: content.bounds.maxY - 2, width: 2, height: 2)
        picker.show(relativeTo: anchor, of: content, preferredEdge: .minY)
    }

    func command(window: @escaping @MainActor () -> DocumentWindowController?) -> Command {
        let option = quickExport.optionHeld
        return Command(id: Self.id, title: "Share", menu: MenuPath(StandardCommands.Menu.file, section: 1),
                       keywords: ["share", "mail", "airdrop", "messages", "send", "export"],
                       validation: { window() == nil ? .disabled(Self.noDocument) : CommandValidation(title: option() ? "Share As…" : "Share") },
                       action: .perform { [weak self] in if let front = window() { self?.share(front) } })
    }

    /// Each app delegate's.
    static var instances: [ObjectIdentifier: ShareExport] = [:]
}
