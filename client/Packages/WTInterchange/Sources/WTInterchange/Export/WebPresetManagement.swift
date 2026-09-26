// Managing the user's web presets (WEB-006; web/web-compression.adoc, "Web presets": "Presets
// are yours, not the document's, and are edited in the same sheet").  What the Export sheet's
// preset editor does to `wt.export.presets`: save the sheet's current settings as a preset,
// rename, duplicate and delete one, and exchange presets as `.wtpreset` files -- an import
// never overwrites a preset of the same name silently, it adds "Name 2".

import Foundation

extension WebExportPreset {
    /// A user preset named `name` with the sheet's current settings; a fresh id.
    public static func user(name: String, format: WebPresetFormat, scale: Double = 2, quality: Int = 80, stripMetadata: Bool = true, transparent: Bool = true,
                            matte: [Double] = [1, 1, 1]) -> WebExportPreset {
        WebExportPreset(id: "user." + UUID().uuidString.lowercased(), name: name, format: format, scale: scale, quality: quality, stripMetadata: stripMetadata,
                        transparent: transparent, matte: matte)
    }

    /// Whether this is one of the four built-in presets (read-only in the editor).
    public var isBuiltIn: Bool { WebExportPreset.builtIn.contains { $0.id == id } }
}

extension WebExportPresetStore {
    /// `name`, or `name 2`, `name 3` ... -- the first not taken by a preset in `all` other than
    /// `except`.
    public func uniqueName(_ name: String, except id: String? = nil) -> String {
        let base = name.trimmingCharacters(in: .whitespaces)
        let taken = Set((WebExportPreset.builtIn + userPresets).filter { $0.id != id }.map(\.name))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// Saves the sheet's settings as a new user preset named `name` (made unique); returns it.
    @discardableResult
    public func saveNew(_ preset: WebExportPreset) throws -> WebExportPreset {
        var preset = preset
        preset.id = "user." + UUID().uuidString.lowercased()
        preset.name = uniqueName(preset.name)
        try save(preset)
        return preset
    }

    /// Renames user preset `id` (the name made unique); built-in presets cannot be renamed.
    @discardableResult
    public func rename(_ id: String, to name: String) throws -> WebExportPreset {
        guard var preset = userPresets.first(where: { $0.id == id }) else {
            throw ExportError.invalidOption(WebExportPreset.builtIn.contains { $0.id == id } ? "Built-in presets cannot be changed." : "There is no preset to rename.")
        }
        preset.name = uniqueName(name, except: id)
        try save(preset)
        return preset
    }

    /// A copy of preset `id` (built-in or user) saved as a user preset named "Name 2" etc.
    @discardableResult
    public func duplicate(_ id: String) throws -> WebExportPreset {
        guard let preset = all.first(where: { $0.id == id }) ?? WebExportPreset.builtIn.first(where: { $0.id == id }) else {
            throw ExportError.invalidOption("There is no preset to duplicate.")
        }
        return try saveNew(preset)
    }

    /// The `.wtpreset` file of the presets `ids` (built-in or user), in their `all` order.
    public func exportFile(_ ids: [String]) throws -> Data {
        let chosen = Set(ids)
        let presets = (WebExportPreset.builtIn + userPresets).filter { chosen.contains($0.id) }
        guard !presets.isEmpty else { throw ExportError.invalidOption("Choose the presets to export.") }
        return try WebPresetFile.data(presets)
    }

    /// Imports a `.wtpreset` file as new user presets: fresh ids, names made unique ("Name 2");
    /// returns them.
    @discardableResult
    public func importAsNew(_ data: Data) throws -> [WebExportPreset] {
        var imported: [WebExportPreset] = []
        for preset in try WebPresetFile.presets(from: data) {
            imported.append(try saveNew(preset))
        }
        return imported
    }
}
