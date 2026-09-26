// WEB-006: managing the user's web presets -- save as, rename, duplicate, delete, and `.wtpreset`
// files exported and imported without overwriting a preset of the same name.

import Foundation
import Testing
@testable import WTInterchange

@Suite struct WebPresetManagementTests {
    static func store() -> (WebExportPresetStore, UserDefaults, String) {
        let suite = "wt.test.presets.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (WebExportPresetStore(defaults: defaults), defaults, suite)
    }

    @Test func saveRenameDuplicateAndDelete() throws {
        let (store, defaults, suite) = Self.store()
        defer { defaults.removePersistentDomain(forName: suite) }
        let banner = try store.saveNew(.user(name: "Banner", format: .jpeg, quality: 70, transparent: false))
        #expect(banner.id.hasPrefix("user.") && !banner.isBuiltIn && store.userPresets == [banner])
        // The same name again, and a built-in name, are numbered.
        #expect(try store.saveNew(.user(name: "Banner", format: .png)).name == "Banner 2")
        #expect(store.uniqueName("Web — PNG 2×") == "Web — PNG 2× 2")
        #expect(store.uniqueName(" Banner ", except: banner.id) == "Banner")
        let renamed = try store.rename(banner.id, to: "Hero")
        #expect(renamed.name == "Hero" && renamed.id == banner.id && renamed.quality == 70)
        #expect(throws: ExportError.invalidOption("Built-in presets cannot be changed.")) { try store.rename("web.png-2x", to: "Mine") }
        #expect(throws: ExportError.invalidOption("There is no preset to rename.")) { try store.rename("nope", to: "Mine") }
        let copy = try store.duplicate("web.jpeg-80")
        #expect(copy.name == "Web — JPEG 80 2" && copy.format == .jpeg && !copy.isBuiltIn)
        #expect(try store.duplicate(renamed.id).name == "Hero 2")
        #expect(throws: ExportError.self) { try store.duplicate("nope") }
        #expect(WebExportPreset.builtIn.filter { !$0.isBuiltIn }.isEmpty)
        try store.delete(copy.id)
        #expect(!store.userPresets.contains(copy))
    }

    /// Presets exported to a file and imported into another Mac's preferences arrive as new
    /// presets; one whose name is taken is added as "Name 2".
    @Test func presetFilesRoundTripWithoutOverwriting() throws {
        let (store, defaults, suite) = Self.store()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mine = try store.saveNew(.user(name: "Mine", format: .webp, scale: 1, quality: 55))
        let file = try store.exportFile([mine.id, "web.svg"])
        #expect(try WebPresetFile.presets(from: file).map(\.name) == ["Web — SVG", "Mine"])
        #expect(throws: ExportError.self) { try store.exportFile(["nope"]) }
        let (other, otherDefaults, otherSuite) = Self.store()
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        try other.saveNew(.user(name: "Mine", format: .png))
        let imported = try other.importAsNew(file)
        #expect(imported.map(\.name) == ["Web — SVG 2", "Mine 2"])
        #expect(imported[1].format == .webp && imported[1].scale == 1 && imported[1].quality == 55 && imported[1].id != mine.id)
        #expect(other.userPresets.count == 3)
    }
}
