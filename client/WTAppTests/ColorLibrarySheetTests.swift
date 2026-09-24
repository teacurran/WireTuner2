import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTInterchange
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// COLOR-013's library sheet, bundled libraries, *My Libraries*, *Import…* and *Import RGB Color
/// Table…*, and COLOR-018's *Export…* sheet (the Swatches panel's Options menu).
@Suite(.serialized) @MainActor struct ColorLibrarySheetTests {
    /// A library menu over a fixture, *My Libraries* in a throwaway folder, panels and alerts
    /// recorded.
    @MainActor
    final class World {
        let fixture = ColorPanelFixture()
        let directory = FileManager.default.temporaryDirectory.appending(path: "WireTunerColorLibraries-\(UUID().uuidString)")
        let menu: ColorLibraryMenu
        var alerts: [(String, String)] = []
        var opened: [URL] = []
        var saved: URL?
        var openPanels: [NSOpenPanel] = []
        var savePanels: [NSSavePanel] = []

        init() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            menu = ColorLibraryMenu(workspace: fixture.workspace, registry: ColorLibraryRegistry(directory: directory.appending(path: "Colors")))
            menu.showAlert = { [unowned self] message, detail, _ in alerts.append((message, detail)) }
            menu.runOpenPanel = { [unowned self] panel, _ in
                openPanels.append(panel)
                return opened
            }
            menu.runSavePanel = { [unowned self] panel, _ in
                savePanels.append(panel)
                return saved
            }
        }

        func file(_ name: String, _ data: Data) -> URL {
            let url = directory.appending(path: name)
            try? data.write(to: url)
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        /// The sheet model of the last library sheet presented.
        var sheetModel: ColorLibrarySheetModel? {
            (fixture.sheets.last?.contentViewController as? NSHostingController<ColorLibrarySheet>)?.rootView.model
        }

        var exportModel: ColorLibraryExportModel? {
            (fixture.sheets.last?.contentViewController as? NSHostingController<ColorLibraryExportSheet>)?.rootView.model
        }
    }

    /// A small library with a tint whose base is in it.
    static func library() -> ColorLibrary {
        var library = ColorLibrary()
        library.name = "Fruit"
        library.columns = 3
        for (key, name, color) in [("grape", "Grape", RenderColor(red: 0.5, green: 0, blue: 0.5)), ("lime", "Lime", RenderColor(red: 0.5, green: 1, blue: 0)),
                                   ("plum", "", RenderColor(red: 0.4, green: 0, blue: 0.4))] {
            var entry = LibraryColor()
            entry.key = key
            entry.name = name
            entry.value = ColorValues.stored(color)
            library.colors.append(entry)
        }
        var tint = LibraryColor()
        tint.key = "grape 40"
        tint.name = "Grape 40%"
        tint.tintOf = "grape"
        tint.tintPercent = 40
        tint.value = ColorValues.stored(RenderColor(red: 0.5, green: 0, blue: 0.5))
        library.colors.append(tint)
        library.colors.append(library.colors[0])
        return library
    }

    /// A Photoshop colour table of three colours with a trailer.
    static func colorTable() -> Data {
        var bytes = [UInt8](repeating: 0, count: 768)
        bytes[0...8] = [255, 0, 0, 0, 255, 0, 0, 0, 255]
        bytes += [0, 3, 0xFF, 0xFF]
        return Data(bytes)
    }

    // MARK: Library sheet

    @Test func theSheetSearchesSelectsAndAddsWithoutDuplicates() async throws {
        let world = World()
        defer { world.remove() }
        await world.fixture.settle()
        let model = ColorLibrarySheetModel(workspace: world.fixture.workspace, library: Self.library())
        #expect(model.allEntries.map(\.key) == ["grape", "lime", "plum", "grape 40"], "a repeated key is listed once")
        #expect(model.allEntries[2].name == "plum", "a nameless colour shows its key")
        #expect(model.allEntries[3].color == RenderColor(red: 0.5, green: 0, blue: 0.5).tinted(0.4))
        #expect(model.columns.count == 3 && model.origin == "Fruit")
        model.search = "gra"
        #expect(model.entries.map(\.key) == ["grape", "grape 40"])
        model.search = "  "
        #expect(model.entries.count == 4)
        // Click, Cmd-click, Shift-click.
        model.click("lime")
        #expect(model.selected == ["lime"])
        model.click("grape 40", modifiers: .shift)
        #expect(model.selected == ["lime", "plum", "grape 40"])
        model.click("plum", modifiers: .command)
        #expect(model.selected == ["lime", "grape 40"])
        model.click("plum", modifiers: .command)
        #expect(model.selected.contains("plum"))
        model.click("grape")
        #expect(model.selected == ["grape"])
        ColorLibrarySheet.clicking("lime", model) { .command }()
        #expect(model.selected == ["grape", "lime"])
        world.fixture.workspace.present(ColorLibrarySheet(model: model), title: "Fruit", identifier: ColorLibrarySheetModel.sheet)
        ColorPanelFixture.render(ColorLibrarySheet(model: model))
        _ = await model.add()?.value
        #expect(world.fixture.document.undoTitle == "Undo Import 2 colors from \"Fruit\"")
        #expect(model.present == ["grape", "lime"])
        #expect(world.fixture.list.swatches.filter { $0.library == "Fruit" }.count == 2)
        // Present colours are ticked, dimmed and not selectable.
        let again = ColorLibrarySheetModel(workspace: world.fixture.workspace, library: Self.library())
        again.click("grape")
        #expect(again.selected.isEmpty)
        again.click("plum")
        again.click("grape 40", modifiers: .shift)
        #expect(again.selected == ["plum", "grape 40"])
        ColorPanelFixture.render(ColorLibrarySheet(model: again))
        ColorPanelFixture.render(ColorLibraryChip(entry: again.allEntries[0], isSelected: true, isPresent: true))
        _ = await again.add()?.value
        #expect(world.fixture.list.swatches.filter { $0.library == "Fruit" }.count == 4)
        // Nothing selected adds nothing; Cancel closes.
        let empty = ColorLibrarySheetModel(workspace: world.fixture.workspace, library: Self.library(), origin: "Other")
        #expect(empty.add() == nil)
        empty.search = "zzz"
        ColorPanelFixture.render(ColorLibrarySheet(model: empty))
        empty.cancel()
        // Without a document nothing is present; the default modifier reader works.
        var wide = Self.library()
        wide.columns = 0
        let unbound = ColorLibrarySheetModel(workspace: ColorWorkspace(selection: ActiveSelection()), library: wide)
        #expect(unbound.present.isEmpty && unbound.columns.count == 1)
        ColorLibrarySheet.clicking("lime", unbound)()
        #expect(unbound.selected == ["lime"])
    }

    // MARK: Menu

    @Test func theMenuListsBundledAndMyLibrariesAndOpensThem() async throws {
        let world = World()
        defer { world.remove() }
        await world.fixture.settle()
        var titles = world.menu.menuItems().map(\.title)
        #expect(titles == ["Crayon", "Grays", "Web Safe", "Process", "Import…", "Export…"])
        #expect(ColorLibraryMenu(workspace: ColorWorkspace(selection: ActiveSelection()), registry: world.menu.registry).menuItems().allSatisfy { !$0.isEnabled })
        world.menu.menuItems()[0].action()
        #expect(world.fixture.lastSheet == ColorLibrarySheetModel.sheet && world.sheetModel?.library.name == "Crayon")
        // A saved library appears under My Libraries; an unreadable one says why.
        try world.menu.registry.save(Self.library())
        let broken = world.menu.registry.directory.appending(path: "Broken.ase")
        try Data("nope".utf8).write(to: broken)
        let items = world.menu.menuItems()
        titles = items.map(\.title)
        #expect(titles.contains("My Libraries") && titles.contains("    Fruit") && titles.contains("    Broken"))
        let header = try #require(items.first { $0.title == "My Libraries" })
        #expect(!header.isEnabled)
        header.action()
        try #require(items.first { $0.title == "    Fruit" }).action()
        #expect(world.sheetModel?.library.name == "Fruit")
        try #require(items.first { $0.title == "    Broken" }).action()
        #expect(world.alerts.last?.0 == "“Broken.ase” could not be opened.")
        // Export… opens the export sheet.
        try #require(items.first { $0.title == "Export…" }).action()
        #expect(world.fixture.lastSheet == ColorLibraryExportModel.sheet)
    }

    @Test func importCopiesTheFileIntoMyLibrariesAndShowsIt() async throws {
        let world = World()
        defer { world.remove() }
        await world.fixture.settle()
        let data = try ColorLibraryFiles.write(Self.library(), format: .wtcolors).data
        world.opened = [world.file("Fruit.wtcolors", data)]
        try #require(world.menu.menuItems().first { $0.title == "Import…" }).action()
        await world.menu.running?.value
        #expect(world.openPanels.last?.allowedContentTypes.count == 4)
        #expect(world.menu.registry.files().map(\.lastPathComponent) == ["Fruit.wtcolors"])
        #expect(world.sheetModel?.library.name == "Fruit")
        // A file that is not a library is refused; a cancelled panel does nothing.
        world.opened = [world.file("Junk.aco", Data("junk".utf8))]
        await world.menu.importLibrary()
        #expect(world.alerts.last?.0 == "“Junk.aco” could not be imported.")
        world.opened = []
        await world.menu.importLibrary()
        #expect(world.alerts.count == 1)
    }

    @Test func aColorTableAddsItsColorsInAGroupNamedAfterTheFile() async throws {
        let world = World()
        defer { world.remove() }
        await world.fixture.settle()
        world.opened = [world.file("Primaries.act", Self.colorTable())]
        world.menu.beginImportColorTable()
        await world.menu.running?.value
        let added = world.fixture.list.swatches.filter { $0.section == "Primaries" }
        #expect(added.count == 3 && added.allSatisfy { !$0.isSpot && $0.color.space == .sRGB })
        #expect(world.openPanels.last?.allowedContentTypes.count == 1)
        world.opened = [world.file("Short.act", Data([1, 2, 3]))]
        #expect(await world.menu.importColorTable() == nil)
        #expect(world.alerts.last?.0 == "“Short.act” could not be imported.")
        world.opened = []
        #expect(await world.menu.importColorTable() == nil)
        // The Extensions menu's stub now runs it.
        let features = ColorFeatures(selection: world.fixture.selection)
        let registry = ExtensionRegistry()
        let descriptor = try #require(features.extensionDescriptors(existing: registry).first { $0.id == "importRGBColorTable" })
        #expect(descriptor.validate?() == .enabled)
        features.libraries.runOpenPanel = { _, _ in [] }
        features.libraries.registry = world.menu.registry
        _ = descriptor.run?(nil)
        await features.libraries.running?.value
        #expect(features.swatchesMenu().contains { $0.title == "Crayon" })
    }

    // MARK: Export

    @Test func exportWritesTheTickedColorsAndListsTheWritersNotes() async throws {
        let world = World()
        defer { world.remove() }
        await world.fixture.settle()
        let grape = await world.fixture.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        let tint = await world.fixture.tint(of: grape, 40)
        let lime = await world.fixture.add(RenderColor(displayP3Red: 0.2, green: 1, blue: 0), name: "Lime")
        world.menu.showExport()
        let model = try #require(world.exportModel)
        #expect(model.name == "Colors" && model.swatches.map(\.id) == [grape, tint, lime] && model.ticked == [grape, tint, lime])
        ColorPanelFixture.render(ColorLibraryExportSheet(model: model))
        model.toggle(lime)
        #expect(!model.ticked.contains(lime))
        ColorLibraryExportSheet.toggling(lime, model).wrappedValue = true
        #expect(ColorLibraryExportSheet.toggling(lime, model).wrappedValue)
        model.name = ""
        model.rows = 2
        model.columns = 5000
        model.notes = "For print"
        var library = model.library()
        #expect(library.name == "Colors" && library.rows == 2 && library.columns == 1000 && library.notes == "For print")
        #expect(library.colors.map(\.name) == ["Grape", "40% Grape", "Lime"])
        // .wtcolors: no notes, no alert.
        model.name = "Fruit"
        world.saved = world.directory.appending(path: "Fruit.wtcolors")
        let written = await model.beginSave().value
        #expect(written == world.saved && world.alerts.isEmpty)
        #expect(world.savePanels.last?.nameFieldStringValue == "Fruit.wtcolors")
        library = try ColorLibraryFiles.read(contentsOf: try #require(written))
        #expect(library.colors.count == 3 && library.colors[1].tintOf == library.colors[0].key)
        // .ase gamut-maps the P3 colour and says so; *Save to My Libraries* writes a copy too.
        model.format = .ase
        model.saveToMyLibraries = true
        world.saved = world.directory.appending(path: "Fruit.ase")
        #expect(await model.save() == world.saved)
        #expect(world.alerts.last?.0 == "Fruit was exported.")
        #expect(world.alerts.last?.1.contains("Saved to My Libraries as Fruit.wtcolors") == true)
        #expect(world.alerts.last?.1.contains("Lime") == true)
        // A cancelled panel, an unwritable place and a read-only format are refused.
        world.saved = nil
        #expect(await model.save() == nil)
        world.saved = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.ase")
        #expect(await model.save() == nil && model.message?.hasPrefix("The library could not be saved") == true)
        ColorPanelFixture.render(ColorLibraryExportSheet(model: model))
        model.format = .act
        #expect(await model.save() == nil && model.message?.contains("imported but not written") == true)
        model.cancel()
        // Without a document there is nothing to export.
        let empty = ColorLibraryExportModel(workspace: ColorWorkspace(selection: ActiveSelection()), libraries: world.menu)
        #expect(empty.swatches.isEmpty && empty.library().colors.isEmpty)
        ColorPanelFixture.render(ColorLibraryExportSheet(model: empty))
    }
}
