// Web export presets and the size estimate (web/web-compression.adoc, "Web presets", "Settings
// that matter"; WEB-006).  A preset fills in the format and every web-relevant option -- scale
// (1× or 2×), quality, *Strip metadata*, matte -- and the Export sheet shows the estimated file
// size before exporting.  Presets are the user's, kept in preferences (`wt.export.presets`) and
// exchanged as `.wtpreset` JSON files; nothing is written to the document.

import Foundation
import WTRender

/// The formats a web preset can name.
public enum WebPresetFormat: String, CaseIterable, Hashable, Sendable, Codable {
    case png
    case jpeg
    case webp
    case avif
    case gif
    case svg

    public var exportFormat: ExportFormat {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .webp: .webp
        case .avif: .avif
        case .gif: .gif
        case .svg: .svg
        }
    }

    /// Whether this Mac can write the format (AVIF needs macOS 14's encoder; hidden otherwise).
    public var isAvailable: Bool {
        switch self {
        case .webp, .avif: BitmapExporter.canEncode(exportFormat)
        default: true
        }
    }
}

/// One web export preset.
public struct WebExportPreset: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var format: WebPresetFormat
    /// CSS pixels per point: 1 or 2 (bitmaps).
    public var scale: Double
    /// JPEG, WebP and AVIF quality, 1 ... 100.
    public var quality: Int
    /// *Strip metadata*: no colour profile and no Document Info in the file.
    public var stripMetadata: Bool
    /// A transparent background where the format has one (PNG, WebP, AVIF, GIF).
    public var transparent: Bool
    /// The colour under transparent areas in formats without transparency (JPEG) and under
    /// anti-aliased edges in GIF: sRGB components 0 ... 1.
    public var matte: [Double]

    public init(id: String, name: String, format: WebPresetFormat, scale: Double = 2, quality: Int = 80, stripMetadata: Bool = true, transparent: Bool = true,
                matte: [Double] = [1, 1, 1]) {
        self.id = id
        self.name = name
        self.format = format
        self.scale = scale
        self.quality = quality
        self.stripMetadata = stripMetadata
        self.transparent = transparent
        self.matte = matte
    }

    /// The four *Web* presets the Export sheet's *Preset* pop-up includes.
    public static let builtIn: [WebExportPreset] = [
        WebExportPreset(id: "web.png-2x", name: "Web — PNG 2×", format: .png),
        WebExportPreset(id: "web.jpeg-80", name: "Web — JPEG 80", format: .jpeg, transparent: false),
        WebExportPreset(id: "web.webp-80", name: "Web — WebP 80", format: .webp),
        WebExportPreset(id: "web.svg", name: "Web — SVG", format: .svg, scale: 1),
    ]

    /// Rejects values outside the sheet's ranges.
    public func validate() throws {
        guard [1, 2].contains(scale) else { throw ExportError.invalidOption("Web presets export at 1× or 2×.") }
        guard (1...100).contains(quality) else { throw ExportError.invalidOption("Quality must be 1 to 100.") }
        guard matte.count == 3, matte.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw ExportError.invalidOption("The matte must be an sRGB colour.") }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ExportError.invalidOption("A preset needs a name.") }
    }

    var matteColor: Color { Color(red: matte[0], green: matte[1], blue: matte[2]) }

    /// The format's options with every setting of the preset applied.
    public func options() -> any ExportOptions {
        var common = BitmapCommonOptions(scales: [scale], background: transparent ? .transparent : .white, embedProfile: !stripMetadata)
        switch format {
        case .png:
            return PNGOptions(common: common, bits: transparent ? 32 : 24)
        case .jpeg:
            common.background = .white
            return JPEGOptions(common: common, quality: quality, progressive: true)
        case .webp:
            return WebPOptions(common: common, quality: quality)
        case .avif:
            return AVIFOptions(common: common, quality: quality)
        case .gif:
            return GIFOptions(common: common, transparent: transparent, matte: matteColor)
        case .svg:
            return SVGOptions(precision: 2, styling: .cssClasses, responsive: true, minify: true, includeDocumentInfo: !stripMetadata)
        }
    }

    /// `scene` as the preset exports it: without Document Info when stripping metadata.
    public func scene(_ scene: ExportScene) -> ExportScene {
        guard stripMetadata else { return scene }
        var stripped = scene
        stripped.info = ExportDocumentInfo(creator: scene.info.creator)
        return stripped
    }
}

/// `.wtpreset` files: a versioned JSON list of presets.
public enum WebPresetFile {
    public static let fileExtension = "wtpreset"
    static let version = 1

    struct Contents: Codable {
        var version: Int
        var presets: [WebExportPreset]
    }

    public static func data(_ presets: [WebExportPreset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Contents(version: version, presets: presets))
    }

    /// The presets of a `.wtpreset` file; throws for a file that is not one, from a newer
    /// version, or holding an invalid preset.
    public static func presets(from data: Data) throws -> [WebExportPreset] {
        guard let contents = try? JSONDecoder().decode(Contents.self, from: data) else {
            throw ExportError.invalidOption("The file is not a WireTuner preset file.")
        }
        guard contents.version <= version else { throw ExportError.invalidOption("The preset file was written by a newer version of WireTuner.") }
        for preset in contents.presets { try preset.validate() }
        return contents.presets
    }
}

/// The user's web presets in preferences (`wt.export.presets`), after the built-in ones.
public struct WebExportPresetStore: @unchecked Sendable {
    public static let key = "wt.export.presets"
    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The user's presets (invalid or unreadable entries dropped).
    public var userPresets: [WebExportPreset] {
        guard let data = defaults.data(forKey: Self.key), let presets = try? WebPresetFile.presets(from: data) else { return [] }
        return presets
    }

    /// The built-in presets whose format this Mac can write, then the user's.
    public var all: [WebExportPreset] {
        (WebExportPreset.builtIn + userPresets).filter(\.format.isAvailable)
    }

    /// Saves `preset` (replacing a user preset with its id); built-in ids cannot be overwritten.
    public func save(_ preset: WebExportPreset) throws {
        try preset.validate()
        guard !WebExportPreset.builtIn.contains(where: { $0.id == preset.id }) else { throw ExportError.invalidOption("Built-in presets cannot be changed.") }
        var presets = userPresets.filter { $0.id != preset.id }
        presets.append(preset)
        defaults.set(try WebPresetFile.data(presets), forKey: Self.key)
    }

    public func delete(_ id: String) throws {
        defaults.set(try WebPresetFile.data(userPresets.filter { $0.id != id }), forKey: Self.key)
    }

    /// Imports a `.wtpreset` file's presets, replacing user presets with the same ids; returns
    /// how many were imported.
    @discardableResult
    public func importFile(_ data: Data) throws -> Int {
        let imported = try WebPresetFile.presets(from: data).filter { preset in !WebExportPreset.builtIn.contains { $0.id == preset.id } }
        let ids = Set(imported.map(\.id))
        defaults.set(try WebPresetFile.data(userPresets.filter { !ids.contains($0.id) } + imported), forKey: Self.key)
        return imported.count
    }
}

/// The Export sheet's estimated file size: the export written to a scratch folder at the sheet's
/// settings and measured, so the estimate is the written size (the sheet runs it on a background
/// task, debounced and cancelled on change).
public enum ExportSizeEstimate {
    /// Bytes `scene` exports to in `format` with `options` (every file, linked images included).
    public static func bytes(scene: ExportScene, format: ExportFormat, options: any ExportOptions, registry: ExportRegistry = .standard) throws -> Int {
        let exporter = try registry.exporter(for: format)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-estimate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = ExportDestination(url: folder.appendingPathComponent("estimate.\(format.fileExtension)"), namePattern: FileNamePattern("{name}-{page}{scale}"))
        let summary = try exporter.export(scene: scene, options: options, to: destination)
        return try summary.files.reduce(0) { total, url in
            total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }

    /// Bytes `scene` exports to with `preset`.
    public static func bytes(scene: ExportScene, preset: WebExportPreset, registry: ExportRegistry = .standard) throws -> Int {
        try preset.validate()
        return try bytes(scene: preset.scene(scene), format: preset.format.exportFormat, options: preset.options(), registry: registry)
    }

    /// The readout: "About 240 KB".
    public static func label(_ bytes: Int) -> String {
        "About " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
