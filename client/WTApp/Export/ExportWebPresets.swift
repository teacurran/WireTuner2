import Foundation
import Observation
import SwiftUI
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

    var body: some View {
        Picker("Web preset", selection: Self.choice(model, web)) {
            Text("None").tag("")
            ForEach(web.presets) { Text($0.name).tag($0.id) }
        }
        .accessibilityIdentifier("export.webPreset")
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
