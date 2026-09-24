import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import WTGeometry
import WTInterchange
import WTModel

/// What the Export sheet knows about the window it exports from.
struct ExportContext: Sendable {
    var title: String
    /// The document's pages on the pasteboard.
    var pages: [Rect]
    var currentPage: Int
    /// The pages as the export snapshot takes them (names and bleed, `PageList.exportPages`);
    /// empty takes `pages` as they are.
    var snapshotPages: [ExportSnapshot.Page] = []
    /// The selected objects' bounds, nil with nothing selected.
    var selectionBounds: Rect?
    /// The output area, once one exists (the Output Area tool).
    var outputArea: Rect?
    /// The sync-state line ("Offline — changes from others since 10:42 can't be included").
    var syncNote: String?
    /// Placed files whose pixels are not on this Mac yet ("Not yet downloaded").
    var missing: [String] = []

    /// The note for `state` (exporting.adoc, "Offline behavior").
    static func syncNote(_ state: SyncState, lastSynced: Date?) -> String? {
        switch state {
        case .offline:
            let time = lastSynced.map { $0.formatted(date: .omitted, time: .shortened) }
            return time.map { "Offline — changes from others since \($0) can't be included" } ?? "Offline — changes from others can't be included"
        case .needsReview:
            return "You have a merge to review; the export includes the merged result"
        default:
            return nil
        }
    }
}

/// An application *Open with* can name.
struct ExportApplication: Hashable, Identifiable, Sendable {
    var id: String
    var name: String
}

/// The Export sheet's state (exporting.adoc, "Client"): the settings the accessory view and the
/// options sheets edit, the preset they came from, and everything derived from them -- the page
/// indices, the files that will be written and why btn:[Export] is refused.
@MainActor
@Observable
final class ExportSheetModel {
    var settings: ExportSettings {
        didSet { if settings.format != oldValue.format { onFormatChange(settings.format) } }
    }
    /// The preset the settings came from.
    private(set) var presetID: String?
    /// The *Save as Preset…* field.
    var presetName = ""
    let context: ExportContext
    let presets: ExportPresetStore
    let registry: ExportRegistry
    /// The applications that open the chosen format (*Open with*).
    var applications: @MainActor (ExportFormat) -> [ExportApplication] = ExportSheetModel.applications
    /// Called when the format changes (the save panel's type and extension follow).
    var onFormatChange: @MainActor (ExportFormat) -> Void = { _ in }
    /// btn:[Options…]: shows the format's options sheet.
    var onShowOptions: @MainActor () -> Void = {}
    /// Dismisses the options sheet.
    var onCloseOptions: @MainActor () -> Void = {}

    init(context: ExportContext, settings: ExportSettings, presets: ExportPresetStore, registry: ExportRegistry, presetID: String? = nil) {
        self.context = context
        self.settings = settings
        self.presets = presets
        self.registry = registry
        self.presetID = presetID
    }

    // MARK: Choices

    /// The Format menu: every format this Mac can write.
    var formats: [ExportFormat] { registry.availableFormats }

    /// The *What* choices that are available now.
    var whatChoices: [ExportWhat] {
        ExportWhat.allCases.filter { what in
            switch what {
            case .outputArea: context.outputArea != nil
            case .selection: context.selectionBounds != nil
            default: true
            }
        }
    }

    var usesRange: Bool { settings.what == .range }

    // MARK: Presets

    var presetList: [ExportPreset] { presets.all }

    /// The preset's name, or nil when the settings came from none.
    var presetTitle: String? { presetID.flatMap(presets.preset)?.name }

    /// A control changed since the preset was chosen: its name shows in italics.
    var isModified: Bool {
        guard let preset = presetID.flatMap(presets.preset) else { return false }
        return preset.settings.stored != settings.stored
    }

    /// The *Preset* menu's choice.
    var presetChoice: String {
        get { presetID ?? "" }
        set { choosePreset(newValue) }
    }

    /// Fills every control from preset `id`.
    func choosePreset(_ id: String) {
        guard let preset = presets.preset(id) else { return }
        presetID = id
        settings = preset.settings
    }

    /// *Save as Preset…* under the typed name (overwriting a user preset of that name).
    func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        presetID = presets.save(settings, named: name).id
        presetName = ""
    }

    /// Deletes the chosen user preset.
    func deletePreset() {
        guard let preset = presetID.flatMap(presets.preset), !preset.isShipped else { return }
        presets.delete(preset.id)
        presetID = nil
    }

    var canDeletePreset: Bool { presetID.flatMap(presets.preset).map { !$0.isShipped } == true }

    // MARK: Pages and files

    /// The pages exported, 0-based, or why the range is refused.
    var pageIndices: Result<[Int], PageRange.Problem> {
        switch settings.what {
        case .currentPage: .success(context.pages.isEmpty ? [] : [min(context.currentPage, context.pages.count - 1)])
        case .allPages: .success(Array(context.pages.indices))
        case .range: Result { () throws(PageRange.Problem) -> [Int] in try PageRange.parse(settings.range, pageCount: context.pages.count) }
        case .outputArea, .selection: .success([0])
        }
    }

    /// The pages exported, none while the range is refused.
    var pages: [Int] { (try? pageIndices.get()) ?? [] }

    /// How many pages (or areas) the export holds.
    var pageCount: Int { pages.count }

    /// The registry's request for the settings.
    var request: ExportRequest {
        ExportRequest(format: settings.format, pageCount: pageCount, scales: settings.scales, transparentBackground: settings.transparentBackground,
                      namePattern: FileNamePattern(settings.namePattern))
    }

    /// How many files the export writes.
    var fileCount: Int { request.fileCount }

    /// The *File names* field shows when more than one file will be written.
    var showsFileNames: Bool { fileCount > 1 }

    /// The first few file names the pattern gives, for the field's help line.
    var sampleNames: [String] {
        let pattern = FileNamePattern(settings.namePattern)
        let perPage = settings.format.capabilities.contains(.multiPage) ? Array(pages.prefix(1)) : pages
        let names = perPage.prefix(2).flatMap { page in
            settings.scales.map { scale in
                var name = pattern.expand(FileNamePattern.Values(name: context.title, page: page + 1, scale: scale))
                if scale != 1 && !settings.namePattern.contains("{scale}") { name += FileNamePattern.scaleSuffix(scale) }
                return name + "." + settings.format.fileExtension
            }
        }
        return Array(names.prefix(3))
    }

    /// Why btn:[Export] is refused, nil when it is not.
    var problem: String? {
        if case .failure(let problem) = pageIndices { return problem.description }
        if settings.what == .outputArea && context.outputArea == nil { return "Draw an output area with the Output Area tool first." }
        if settings.what == .selection && context.selectionBounds == nil { return "Select the objects to export first." }
        do {
            try registry.validate(request)
        } catch {
            return String(describing: error)
        }
        if settings.format.family == .animation && settings.what == .selection { return "Animations export whole pages or the output area." }
        return nil
    }

    // MARK: After export

    /// The *Open with* choice (the application's bundle id, "" for none).
    var openWithChoice: String {
        get { settings.openWith ?? "" }
        set { settings.openWith = newValue.isEmpty ? nil : newValue }
    }

    var openWithApplications: [ExportApplication] { applications(settings.format) }

    /// The applications macOS lists for opening `format`'s files.
    static func applications(_ format: ExportFormat) -> [ExportApplication] {
        NSWorkspace.shared.urlsForApplications(toOpen: format.utType).prefix(12).compactMap { url in
            Bundle(url: url)?.bundleIdentifier.map { ExportApplication(id: $0, name: FileManager.default.displayName(atPath: url.path)) }
        }
    }

    // MARK: Size

    /// The *Estimated size* line of the bitmap formats (export-bitmap.adoc): the pixel count of
    /// the first page at the first scale times a typical number of bytes per pixel for the format
    /// and its quality.  An estimate; the file may be larger or smaller.
    var sizeEstimate: String? {
        guard settings.format.family == .bitmap, let page = exportBounds else { return nil }
        let common = settings.options.common(settings.format)
        let scale = common.scales.prefix(1).reduce(1) { $1 }
        let pixels = (page.width * common.ppi / 72 * scale).rounded() * (page.height * common.ppi / 72 * scale).rounded()
        let bytes = pixels * bytesPerPixel
        return "About " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " per file"
    }

    /// The area the first file shows.
    var exportBounds: Rect? {
        switch settings.what {
        case .outputArea: context.outputArea
        case .selection: context.selectionBounds
        default: pages.first.map { context.pages[$0] }
        }
    }

    /// Typical encoded bytes per pixel for flat artwork in the chosen format.
    var bytesPerPixel: Double {
        let options = settings.options
        switch settings.format {
        case .jpeg: return 0.1 + 0.9 * Double(options.jpeg.quality) / 100
        case .webp: return options.webp.lossless ? 0.6 : 0.05 + 0.5 * Double(options.webp.quality) / 100
        case .heic: return 0.05 + 0.45 * Double(options.heic.quality) / 100
        case .avif: return 0.04 + 0.4 * Double(options.avif.quality) / 100
        case .gif: return 0.3
        case .bmp, .targa: return Double(settings.format == .bmp ? options.bmp.bits : options.targa.bits) / 8
        case .tiff: return options.tiff.compression == .none ? Double(options.tiff.bits) / 8 : Double(options.tiff.bits) / 16
        case .psd: return Double(options.psd.bitsPerChannel) / 2
        default: return options.png.bits == 8 ? 0.3 : Double(options.png.bits) / 16
        }
    }

    // MARK: Options sheet

    func showOptions() { onShowOptions() }
    func closeOptions() { onCloseOptions() }
}
