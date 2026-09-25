import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WTInterchange
import WTModel

/// menu:File[Quick Export] (exporting.adoc, "Quick Export"; IO-015): the export the *Quick Export
/// preset* describes (by name; default *PNG 1× 2× 3×*) without the sheet -- the selection, else the
/// current page -- next to the last place this document was exported to, or the Desktop, named
/// after the document, then revealed in the Finder.  kbd:[Option] (*Quick Export As…*) picks
/// another preset for this once.
@MainActor
final class QuickExport {
    static let id: CommandID = "file.quickExport"
    /// Each app delegate's.
    static var instances: [ObjectIdentifier: QuickExport] = [:]
    static let noDocument = "Open a document to export"

    let exports: ExportController
    let preferences: PreferenceStore
    /// kbd:[Option] held when the command runs.
    var optionHeld: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.option) }
    /// Picks a preset for *Quick Export As…*; nil cancels.
    var choosePreset: @MainActor ([ExportPreset]) -> ExportPreset? = QuickExport.menu
    /// Where the first Quick Export of a document goes.
    var desktop: @MainActor () -> URL = { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory }
    private(set) var running: Task<ExportOutcome?, Never>?

    init(exports: ExportController, preferences: PreferenceStore) {
        self.exports = exports
        self.preferences = preferences
    }

    /// The *Quick Export preset*: the preset of that name, else the shipped PNG set.
    var preset: ExportPreset {
        let name = preferences[PreferenceCatalog.Export.quickExportPreset]
        return exports.presets.all.first { $0.name == name } ?? ExportPreset.shipped.first { $0.id == "shipped.png-scales" }!
    }

    /// Where `window`'s Quick Export writes: beside its last export, else on the Desktop.
    func destination(for window: DocumentWindowController, format: ExportFormat) -> URL {
        let document = window.documentHandle
        let directory = exports.memory.file(for: document.id)?.deletingLastPathComponent() ?? desktop()
        return directory.appendingPathComponent(document.title).appendingPathExtension(format.fileExtension)
    }

    /// The settings: the preset's, scoped to the selection or else the current page.
    func settings(_ preset: ExportPreset, for window: DocumentWindowController) -> ExportSettings {
        var settings = preset.settings
        settings.what = window.selection.selection.isEmpty ? .currentPage : .selection
        return settings
    }

    /// Runs Quick Export on `window` with `preset`; the written files are revealed.
    @discardableResult
    func run(_ window: DocumentWindowController, preset: ExportPreset) -> Task<ExportOutcome?, Never> {
        let settings = settings(preset, for: window)
        let url = destination(for: window, format: settings.format)
        let exports = exports
        let task = Task { @MainActor () -> ExportOutcome? in
            let outcome = await exports.perform(settings, to: url, from: window)
            if case .exported(let summary) = outcome { exports.reveal(summary.files) }
            if case .failed(let message) = outcome { exports.showAlert("The export failed", message, window.window) }
            return outcome
        }
        running = task
        return task
    }

    /// The command: the Quick Export preset, or with kbd:[Option] the chosen one.
    @discardableResult
    func perform(on window: DocumentWindowController) -> Task<ExportOutcome?, Never>? {
        if optionHeld() {
            guard let chosen = choosePreset(exports.presets.all) else { return nil }
            return run(window, preset: chosen)
        }
        return run(window, preset: preset)
    }

    /// A pop-up menu of the presets at the pointer.
    static func menu(_ presets: [ExportPreset]) -> ExportPreset? {
        let menu = NSMenu(title: "Quick Export As")
        for (index, preset) in presets.enumerated() {
            let item = NSMenuItem(title: preset.name, action: nil, keyEquivalent: "")
            item.tag = index
            menu.addItem(item)
        }
        guard menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil), let chosen = menu.highlightedItem else { return nil }
        return presets[chosen.tag]
    }

    func commands(window: @escaping @MainActor () -> DocumentWindowController?) -> [Command] {
        let option = optionHeld
        return [Command(id: Self.id, title: "Quick Export", key: KeyEquivalent("e", [.command, .option]), menu: MenuPath(StandardCommands.Menu.file, section: 3),
                        keywords: ["export", "png", "share"],
                        validation: { window() == nil ? .disabled(Self.noDocument) : CommandValidation(title: option() ? "Quick Export As…" : "Quick Export") },
                        action: .perform { [weak self] in if let front = window() { self?.perform(on: front) } })]
    }
}

/// menu:File[Manage Export Presets…] (exporting.adoc, "Export presets"): the presets listed -- the
/// shipped ones read-only -- with rename, duplicate, delete, and import or export as a file to share
/// with a team.  The user's presets live on this Mac (`ExportPresetStore`).
@MainActor
@Observable
final class ExportPresetManager {
    @ObservationIgnored let store: ExportPresetStore
    var selected: String?
    var renameText = ""
    private(set) var message: String?
    /// Bumped by every edit, so the list re-reads the store.
    private(set) var revision = 0

    init(store: ExportPresetStore) {
        self.store = store
    }

    var presets: [ExportPreset] {
        _ = revision
        return store.all
    }

    var selection: ExportPreset? { selected.flatMap(store.preset) }

    /// Renames the selected user preset (its settings kept).
    @discardableResult
    func rename(to name: String) -> ExportPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let preset = selection, !preset.isShipped, !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        store.delete(preset.id)
        let renamed = store.save(preset.settings, named: trimmed)
        selected = renamed.id
        revision += 1
        return renamed
    }

    /// Duplicates the selected preset as "<name> copy".
    @discardableResult
    func duplicate() -> ExportPreset? {
        guard let preset = selection else { return nil }
        var name = "\(preset.name) copy"
        var index = 2
        while store.all.contains(where: { $0.name == name }) {
            name = "\(preset.name) copy \(index)"
            index += 1
        }
        let copy = store.save(preset.settings, named: name)
        selected = copy.id
        revision += 1
        return copy
    }

    /// Deletes the selected user preset.
    func delete() {
        guard let preset = selection, !preset.isShipped else { return }
        store.delete(preset.id)
        selected = nil
        revision += 1
    }

    /// The user's presets as a file's bytes.
    func exported() -> Data {
        let saved = store.userPresets.map { ExportPresetStore.Saved(id: $0.id, name: $0.name, settings: StoredExportSettings($0.settings)) }
        return (try? JSONEncoder().encode(saved)) ?? Data()
    }

    /// Adds the presets of a file (a preset of the same name is overwritten); the count added.
    @discardableResult
    func importPresets(_ data: Data) -> Int {
        guard let saved = try? JSONDecoder().decode([ExportPresetStore.Saved].self, from: data) else {
            message = "The file is not a preset file."
            return 0
        }
        for preset in saved { store.save(preset.settings.settings, named: preset.name) }
        message = saved.count == 1 ? "1 preset imported" : "\(saved.count) presets imported"
        revision += 1
        return saved.count
    }

    /// Writes the user's presets to `url`.
    @discardableResult
    func export(to url: URL) -> Bool {
        (try? exported().write(to: url)) != nil
    }

    /// Imports the presets at `url`.
    @discardableResult
    func importFile(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else {
            message = "The file could not be read."
            return 0
        }
        return importPresets(data)
    }
}

/// The Manage Export Presets sheet.
struct ExportPresetManagerView: View {
    @Bindable var manager: ExportPresetManager
    let close: () -> Void
    var saveURL: @MainActor () -> URL? = ExportPresetManagerView.chooseSave
    var openURL: @MainActor () -> URL? = ExportPresetManagerView.chooseOpen

    static func chooseSave() -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Export Presets.json"
        panel.allowedContentTypes = [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseOpen() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func exporting(_ manager: ExportPresetManager, _ url: @escaping @MainActor () -> URL?) -> () -> Void {
        { if let target = url() { manager.export(to: target) } }
    }

    static func importing(_ manager: ExportPresetManager, _ url: @escaping @MainActor () -> URL?) -> () -> Void {
        { if let source = url() { manager.importFile(source) } }
    }

    static func duplicating(_ manager: ExportPresetManager) -> () -> Void {
        { manager.duplicate() }
    }

    static func renaming(_ manager: ExportPresetManager) -> () -> Void {
        { manager.rename(to: manager.renameText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export Presets").font(.headline)
            List(manager.presets, selection: $manager.selected) { preset in
                Text(preset.name).italic(preset.isShipped).tag(preset.id)
            }
            .frame(height: 200)
            .accessibilityIdentifier("presets.list")
            HStack {
                TextField("Name", text: $manager.renameText).accessibilityIdentifier("presets.name")
                Button("Rename", action: Self.renaming(manager)).disabled(manager.selection?.isShipped != false)
            }
            HStack {
                Button("Duplicate", action: Self.duplicating(manager)).disabled(manager.selection == nil)
                Button("Delete", action: manager.delete).disabled(manager.selection?.isShipped != false)
                Spacer()
                Button("Import…", action: Self.importing(manager, openURL))
                Button("Export…", action: Self.exporting(manager, saveURL))
            }
            if let message = manager.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    static func command(store: ExportPresetStore, window: @escaping @MainActor () -> DocumentWindowController?) -> Command {
        Command(id: "file.managePresets", title: "Manage Export Presets…", menu: MenuPath(StandardCommands.Menu.file, section: 3),
                keywords: ["export", "presets"], validation: { window() == nil ? .disabled(QuickExport.noDocument) : .enabled },
                action: .perform {
                    guard let front = window() else { return }
                    let manager = ExportPresetManager(store: store)
                    front.presentSheet("export-presets") { close in ExportPresetManagerView(manager: manager, close: close) }
                })
    }
}
