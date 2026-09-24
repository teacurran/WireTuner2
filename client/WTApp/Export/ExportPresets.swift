import Foundation
import WTInterchange

/// A saved combination of format, options, *What* and naming pattern (exporting.adoc, "Export
/// presets").
struct ExportPreset: Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var settings: ExportSettings
    /// Shipped with the app: never deleted or overwritten.
    var isShipped = false

    /// The presets {product} ships.
    static let shipped: [ExportPreset] = {
        var print = ExportSettings(format: .pdf, what: .allPages)
        print.options.pdf = .printPDFX4
        var screen = ExportSettings(format: .pdf, what: .allPages)
        screen.options.pdf = PDFOptions(colorImages: .jpeg, jpegQuality: 75, downsample: true, downsampleAbovePPI: 225, downsampleToPPI: 150, colors: .convertToRGB)
        var svg = ExportSettings(format: .svg)
        svg.options.svg = SVGOptions(precision: 2, styling: .cssClasses, responsive: true, minify: true)
        var png = ExportSettings(format: .png, namePattern: "{name}-{page}{scale}")
        png.options.png.common.scales = [1, 2, 3]
        var jpeg = ExportSettings(format: .jpeg)
        jpeg.options.jpeg.quality = 70
        jpeg.options.jpeg.progressive = true
        let illustrator = ExportSettings(format: .illustrator, what: .allPages)
        return [
            ExportPreset(id: "shipped.pdf-print", name: "PDF for print (PDF/X-4)", settings: print, isShipped: true),
            ExportPreset(id: "shipped.pdf-screen", name: "PDF for screen", settings: screen, isShipped: true),
            ExportPreset(id: "shipped.svg-web", name: "SVG for web", settings: svg, isShipped: true),
            ExportPreset(id: "shipped.png-scales", name: "PNG 1× 2× 3×", settings: png, isShipped: true),
            ExportPreset(id: "shipped.jpeg-web", name: "JPEG for web", settings: jpeg, isShipped: true),
            ExportPreset(id: "shipped.illustrator", name: "Illustrator", settings: illustrator, isShipped: true),
        ]
    }()
}

/// The fields of a preset or remembered export that survive a relaunch.  The format options
/// have no stored form until `export_options.proto` is written (IO-015 stores presets in account
/// preferences); after a relaunch they are the format's defaults with the scales kept.
struct StoredExportSettings: Codable, Hashable, Sendable {
    var format: Int
    var what: ExportWhat
    var range: String
    var includePageBoundary: Bool
    var namePattern: String
    var scales: [Double]
    var openWith: String?
    var revealInFinder: Bool

    init(_ settings: ExportSettings) {
        format = settings.format.rawValue
        what = settings.what
        range = settings.range
        includePageBoundary = settings.includePageBoundary
        namePattern = settings.namePattern
        scales = settings.scales
        openWith = settings.openWith
        revealInFinder = settings.revealInFinder
    }

    var settings: ExportSettings {
        var settings = ExportSettings(format: ExportFormat(rawValue: format) ?? .pdf, what: what, range: range, includePageBoundary: includePageBoundary,
                                      namePattern: namePattern, openWith: openWith, revealInFinder: revealInFinder)
        var common = settings.options.common(settings.format)
        common.scales = scales
        settings.options.setCommon(common, for: settings.format)
        return settings
    }
}

/// The user's presets after the shipped ones, kept on this Mac (IO-015 moves them to account
/// preferences): the stored fields in `UserDefaults`, the full settings for this session.
@MainActor
final class ExportPresetStore {
    struct Saved: Codable, Hashable {
        var id: String
        var name: String
        var settings: StoredExportSettings
    }

    static let key = "export.presets"
    let defaults: UserDefaults
    private(set) var userPresets: [ExportPreset]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
        userPresets = saved.map { ExportPreset(id: $0.id, name: $0.name, settings: $0.settings.settings) }
    }

    /// The shipped presets, then the user's.
    var all: [ExportPreset] { ExportPreset.shipped + userPresets }

    func preset(_ id: String) -> ExportPreset? {
        all.first { $0.id == id }
    }

    /// Saves `settings` as a preset named `name`: a user preset with that name is overwritten
    /// (same id), otherwise a new one is added.  Returns it.
    @discardableResult
    func save(_ settings: ExportSettings, named name: String) -> ExportPreset {
        let stored = settings.stored
        if let index = userPresets.firstIndex(where: { $0.name == name }) {
            userPresets[index].settings = stored
            persist()
            return userPresets[index]
        }
        let preset = ExportPreset(id: UUID().uuidString, name: name, settings: stored)
        userPresets.append(preset)
        persist()
        return preset
    }

    func delete(_ id: String) {
        userPresets.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let saved = userPresets.map { Saved(id: $0.id, name: $0.name, settings: StoredExportSettings($0.settings)) }
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.key)
    }
}

/// The most recent export of each document on this Mac (*Export Again*; the `last_export`
/// memory, exporting.adoc "Data model"): a bookmark of the file and the settings.  Kept in
/// `UserDefaults` by document id -- per Mac, never synced -- until `SettingsProps.last_export`
/// is in the schema; the full settings last for the session, the stored fields for good.
@MainActor
final class ExportMemoryStore {
    struct Memory: Codable, Hashable {
        /// A security-scoped bookmark of the first file written.
        var bookmark: Data
        /// The first file written: Export Again needs it where it was.
        var written: String
        /// The location chosen in the sheet (a set of files is named from it).
        var path: String
        var settings: StoredExportSettings
        var exportedAt: Date
    }

    static let key = "export.lastExport"
    private let defaults: UserDefaults
    private var session: [String: ExportSettings] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private var memories: [String: Memory] {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Memory].self, from: $0) } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.key) }
    }

    /// Remembers that `document` was exported to `url` (writing `written` first) with
    /// `settings`.
    func remember(_ document: String, url: URL, written: URL, settings: ExportSettings, at date: Date = Date()) {
        let stored = settings.stored
        session[document] = stored
        let bookmark = (try? written.bookmarkData(options: .withSecurityScope)) ?? Data()
        memories[document] = Memory(bookmark: bookmark, written: written.path, path: url.path, settings: StoredExportSettings(stored), exportedAt: date)
    }

    /// The settings of `document`'s most recent export (for prefilling the sheet).
    func settings(for document: String) -> ExportSettings? {
        session[document] ?? memories[document]?.settings.settings
    }

    /// Where `document` was last exported, when the file is still where it was written: nil
    /// after it was moved, renamed or deleted, or when it was never exported on this Mac.  The
    /// security-scoped bookmark gives the sandbox access to that folder again.
    func file(for document: String) -> URL? {
        guard let memory = memories[document], FileManager.default.fileExists(atPath: memory.written) else { return nil }
        var stale = false
        let file = try? URL(resolvingBookmarkData: memory.bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        _ = file?.startAccessingSecurityScopedResource()
        return URL(fileURLWithPath: memory.path)
    }
}
