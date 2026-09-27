import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WTInterchange

/// The Export sheet's *Web* presets and size readout (WEB-006's sheet half; web-compression.adoc,
/// "Web presets"): the built-in four and the user's (`WebExportPresetStore`), each filling the
/// format and its options; the readout is the written size of the current page at those
/// settings (`ExportSizeEstimate`, a scratch export), worked out off the main actor.
@MainActor
@Observable
final class ExportWebPresetModel {
    @ObservationIgnored let store: WebExportPresetStore
    /// The current page as the exporters read it; nil when there is nothing to estimate.
    @ObservationIgnored let scene: @MainActor () -> ExportScene?
    var choice = ""
    private(set) var estimate: String?
    private(set) var isEstimating = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(defaults: UserDefaults, scene: @escaping @MainActor () -> ExportScene?) {
        store = WebExportPresetStore(defaults: defaults)
        self.scene = scene
    }

    var presets: [WebExportPreset] { store.all }
    var preset: WebExportPreset? { presets.first { $0.id == choice } }

    // MARK: The preset editor (WEB-006's rest)

    /// What the name field is for.
    enum Naming: Equatable {
        case saving
        case renaming
    }

    /// The name field's purpose while it shows, and its text.
    var naming: Naming?
    var name = ""
    /// The last refusal or result of the editor ("Built-in presets cannot be changed.").
    private(set) var message: String?
    /// Moves when the user's presets change, so the pop-up re-reads them.
    private(set) var revision = 0
    /// Chooses where to write a `.wtpreset` file, and which to read; nil when cancelled.
    @ObservationIgnored var chooseExportURL: @MainActor (String) -> URL? = ExportWebPresetModel.savePanel
    @ObservationIgnored var chooseImportURL: @MainActor () -> URL? = ExportWebPresetModel.openPanel

    /// Whether the chosen preset is the user's (rename and delete).
    var canEdit: Bool { preset.map { !$0.isBuiltIn } ?? false }

    /// *Save as Preset…* and *Rename…* show the name field.
    func beginNaming(_ purpose: Naming) {
        naming = purpose
        name = purpose == .renaming ? preset?.name ?? "" : ""
        message = nil
    }

    /// The name field's btn:[OK].
    @discardableResult
    func commitName(sheet: ExportSheetModel) -> WebExportPreset? {
        defer { naming = nil }
        switch naming {
        case .saving?: return saveCurrent(named: name, sheet: sheet)
        case .renaming?: return renameChosen(to: name)
        case nil: return nil
        }
    }

    /// The sheet's current format and options as a new preset named `name`, then chosen.
    @discardableResult
    func saveCurrent(named name: String, sheet: ExportSheetModel) -> WebExportPreset? {
        guard let options = Self.options(of: sheet.settings.format, in: sheet.settings.options),
              let captured = WebExportPreset.capturing(options, name: name.isEmpty ? "Preset" : name) else {
            message = "Web presets are PNG, JPEG, WebP, AVIF, GIF or SVG."
            return nil
        }
        return edit { store in
            let saved = try store.saveNew(captured)
            choice = saved.id
            return saved
        }
    }

    @discardableResult
    func renameChosen(to name: String) -> WebExportPreset? {
        let id = choice
        return edit { try $0.rename(id, to: name) }
    }

    /// *Duplicate*: a copy of the chosen preset (built-in too), then chosen.
    @discardableResult
    func duplicateChosen() -> WebExportPreset? {
        let id = choice
        return edit { store in
            let copy = try store.duplicate(id)
            choice = copy.id
            return copy
        }
    }

    /// *Delete*: the chosen user preset; the pop-up falls back to *None*.
    func deleteChosen() {
        guard canEdit else {
            message = "Built-in presets cannot be changed."
            return
        }
        let id = choice
        _ = edit { store -> WebExportPreset? in
            try store.delete(id)
            choice = ""
            estimate = nil
            return nil
        }
    }

    /// *Export Presets…*: the user's presets as a `.wtpreset` file; the URL written.
    @discardableResult
    func exportPresets() -> URL? {
        let ids = store.userPresets.map(\.id)
        guard !ids.isEmpty else {
            message = "There are no presets of yours to export."
            return nil
        }
        guard let url = chooseExportURL("Web Presets.\(WebPresetFile.fileExtension)") else { return nil }
        do {
            try store.exportFile(ids).write(to: url, options: .atomic)
            message = ids.count == 1 ? "Exported 1 preset." : "Exported \(ids.count) presets."
            return url
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// *Import Presets…*: every preset of a file added under a unique name; how many.
    @discardableResult
    func importPresets() -> Int {
        guard let url = chooseImportURL() else { return 0 }
        do {
            let imported = try store.importAsNew(Data(contentsOf: url))
            revision += 1
            message = imported.count == 1 ? "Imported 1 preset." : "Imported \(imported.count) presets."
            return imported.count
        } catch {
            message = "The file is not a preset file."
            return 0
        }
    }

    private func edit(_ body: (WebExportPresetStore) throws -> WebExportPreset?) -> WebExportPreset? {
        do {
            let result = try body(store)
            revision += 1
            message = nil
            return result
        } catch let ExportError.invalidOption(text) {
            message = text
        } catch {
            message = error.localizedDescription
        }
        return nil
    }

    /// The sheet's options of `format` (nil for a format no web preset names).
    static func options(of format: ExportFormat, in options: ExportFormatOptions) -> (any ExportOptions)? {
        switch format {
        case .png: options.png
        case .jpeg: options.jpeg
        case .webp: options.webp
        case .avif: options.avif
        case .gif: options.gif
        case .svg: options.svg
        default: nil
        }
    }

    static let fileType = UTType(filenameExtension: WebPresetFile.fileExtension) ?? .json

    static func savePanel(_ name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [fileType]
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func openPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [fileType]
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Chooses preset `id`: the sheet's format and options follow, and the size is estimated.
    @discardableResult
    func choose(_ id: String, sheet: ExportSheetModel) -> Task<Void, Never>? {
        choice = id
        guard let preset else {
            estimate = nil
            return nil
        }
        sheet.settings.format = preset.format.exportFormat
        Self.apply(preset, to: &sheet.settings.options)
        return estimateSize(preset)
    }

    /// The preset's options written into the sheet's per-format options.
    static func apply(_ preset: WebExportPreset, to options: inout ExportFormatOptions) {
        switch preset.options() {
        case let png as PNGOptions: options.png = png
        case let jpeg as JPEGOptions: options.jpeg = jpeg
        case let webp as WebPOptions: options.webp = webp
        case let avif as AVIFOptions: options.avif = avif
        case let gif as GIFOptions: options.gif = gif
        case let svg as SVGOptions: options.svg = svg
        default: break
        }
    }

    /// The readout: "About 142 KB", written in a scratch folder at the preset's settings.
    @discardableResult
    func estimateSize(_ preset: WebExportPreset) -> Task<Void, Never>? {
        task?.cancel()
        guard let scene = scene() else {
            estimate = nil
            return nil
        }
        isEstimating = true
        let task = Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) { try? ExportSizeEstimate.bytes(scene: scene, preset: preset) }.value
            guard let self, !Task.isCancelled else { return }
            self.isEstimating = false
            self.estimate = bytes.map { "About \(ExportSizeEstimate.label($0))" } ?? "The size could not be estimated"
        }
        self.task = task
        return task
    }
}

/// The *Web preset* pop-up and its readout, under the sheet's *Preset* pop-up.
struct ExportWebPresetSection: View {
    let model: ExportSheetModel
    let web: ExportWebPresetModel

    static func choice(_ model: ExportSheetModel, _ web: ExportWebPresetModel) -> Binding<String> {
        Binding(get: { web.choice }, set: { web.choose($0, sheet: model) })
    }

    static func naming(_ web: ExportWebPresetModel) -> Binding<Bool> {
        Binding(get: { web.naming != nil }, set: { if !$0 { web.naming = nil } })
    }
    static func name(_ web: ExportWebPresetModel) -> Binding<String> {
        Binding(get: { web.name }, set: { web.name = $0 })
    }
    static func begin(_ web: ExportWebPresetModel, _ purpose: ExportWebPresetModel.Naming) -> () -> Void { { web.beginNaming(purpose) } }
    static func commit(_ model: ExportSheetModel, _ web: ExportWebPresetModel) -> () -> Void { { web.commitName(sheet: model) } }
    static func duplicate(_ web: ExportWebPresetModel) -> () -> Void { { web.duplicateChosen() } }
    static func delete(_ web: ExportWebPresetModel) -> () -> Void { { web.deleteChosen() } }
    static func export(_ web: ExportWebPresetModel) -> () -> Void { { web.exportPresets() } }
    static func `import`(_ web: ExportWebPresetModel) -> () -> Void { { web.importPresets() } }

    var body: some View {
        HStack {
            Picker("Web preset", selection: Self.choice(model, web)) {
                Text("None").tag("")
                ForEach(web.presets) { Text($0.name).tag($0.id) }
            }
            .id(web.revision)
            .accessibilityIdentifier("export.webPreset")
            // The preset editor: presets are yours and are edited in this sheet (WEB-006).
            Menu("Presets") {
                Button("Save Current Settings as Preset…", action: Self.begin(web, .saving))
                Button("Rename…", action: Self.begin(web, .renaming)).disabled(!web.canEdit)
                Button("Duplicate", action: Self.duplicate(web)).disabled(web.preset == nil)
                Button("Delete", action: Self.delete(web)).disabled(!web.canEdit)
                Divider()
                Button("Export Presets…", action: Self.export(web))
                Button("Import Presets…", action: Self.import(web))
            }
            .fixedSize()
            .accessibilityIdentifier("export.webPreset.menu")
        }
        .alert(web.naming == .renaming ? "Rename Preset" : "Save Preset", isPresented: Self.naming(web)) {
            TextField("Name", text: Self.name(web))
            Button("OK", action: Self.commit(model, web))
            Button("Cancel", role: .cancel) {}
        }
        if let message = web.message {
            Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("export.webPreset.message")
        }
        if web.isEstimating {
            Text("Estimating size…").font(.caption).foregroundStyle(.secondary)
        } else if let estimate = web.estimate {
            Text(estimate).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("export.webEstimate")
        }
    }
}

extension ExportController {
    /// The sheet's *Web* presets over `window`'s current page.
    func webPresets(for window: DocumentWindowController, sheet: ExportSheetModel) -> ExportWebPresetModel {
        ExportWebPresetModel(defaults: presets.defaults) { [weak self, weak window, weak sheet] in
            guard let self, let window, let sheet else { return nil }
            var settings = sheet.settings
            settings.what = .currentPage
            return try? self.capture(settings, model: sheet, from: window).resolved()
        }
    }
}
