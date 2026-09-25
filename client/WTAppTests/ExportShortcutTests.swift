import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// Quick Export and the preset manager (IO-015), and drag export with its pasteboard flavors
/// (IO-016).
@Suite(.serialized) @MainActor struct ExportShortcutTests {
    static func directory() throws -> URL {
        let url = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Quick Export (IO-015)

    @Test func quickExportWritesThePNGSetAndRevealsIt() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let folder = try Self.directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let square = await world.document.addRectangles([Rect(x: 50, y: 50, width: 40, height: 40)])
        // The selection keeps the bitmaps small (a whole page at 3× is slow in a debug build).
        world.window.selection.model.set(Selection(square))
        let suite = TestDefaults()
        let exports = ExportController(defaults: suite.defaults)
        exports.progressDelay = .zero
        var revealed: [URL] = []
        exports.reveal = { revealed = $0 }
        let quick = QuickExport(exports: exports, preferences: world.setup.environment.preferences)
        quick.desktop = { folder }
        quick.optionHeld = { false }
        #expect(quick.preset.name == "PNG 1× 2× 3×")
        let outcome = await quick.perform(on: world.window)?.value
        guard case .exported(let summary)? = outcome else { Issue.record("\(String(describing: outcome))"); return }
        let names = summary.files.map(\.lastPathComponent).sorted()
        #expect(names.count == 3 && names.contains { $0.contains("@2x") } && names.contains { $0.contains("@3x") }, "\(names)")
        #expect(revealed == summary.files && summary.files.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL })
        // With Option, the chosen preset; cancelling the menu does nothing.
        quick.optionHeld = { true }
        quick.choosePreset = { $0.first { $0.name == "SVG for web" } }
        let svg = await quick.perform(on: world.window)?.value
        if case .exported(let written)? = svg { #expect(written.files.first?.pathExtension == "svg") } else { Issue.record("svg") }
        quick.choosePreset = { _ in nil }
        #expect(quick.perform(on: world.window) == nil)
        // The preference names the preset; the selection scopes it.
        _ = world.setup.environment.preferences.set("JPEG for web", for: PreferenceCatalog.Export.quickExportPreset)
        #expect(quick.preset.name == "JPEG for web")
        #expect(quick.settings(quick.preset, for: world.window).what == .selection)
        world.window.selection.model.clear()
        #expect(quick.settings(quick.preset, for: world.window).what == .currentPage)
        world.window.selection.model.set(Selection(square))
        _ = world.setup.environment.preferences.set("no such preset", for: PreferenceCatalog.Export.quickExportPreset)
        #expect(quick.preset.id == "shipped.png-scales")
        // The command, with and without Option.
        quick.optionHeld = { false }
        let commands = quick.commands { world.window }
        #expect(commands[0].defaultKey == KeyEquivalent("e", [.command, .option]) && commands[0].validation().title == "Quick Export")
        quick.optionHeld = { true }
        #expect(quick.commands(window: { world.window })[0].validation().title == "Quick Export As…")
        #expect(!quick.commands(window: { nil })[0].validation().isEnabled)
        quick.optionHeld = { false }
        if case .perform(let run) = commands[0].action { run() }
        _ = await quick.running?.value
        // A failed export shows an alert.
        var alerts: [String] = []
        exports.showAlert = { title, _, _ in alerts.append(title) }
        quick.desktop = { URL(fileURLWithPath: "/nonexistent/folder") }
        _ = await quick.run(world.window, preset: ExportPreset.shipped[0]).value
        #expect(alerts == ["The export failed"])
    }

    @Test func thePresetManagerRenamesDuplicatesDeletesAndSharesPresets() async throws {
        let suite = TestDefaults()
        let store = ExportPresetStore(defaults: suite.defaults)
        let manager = ExportPresetManager(store: store)
        #expect(manager.presets.count == ExportPreset.shipped.count)
        // A shipped preset cannot be renamed or deleted, only duplicated.
        manager.selected = ExportPreset.shipped[3].id
        #expect(manager.rename(to: "Mine") == nil)
        manager.delete()
        #expect(store.all.count == ExportPreset.shipped.count)
        let copy = try #require(manager.duplicate())
        #expect(copy.name == "PNG 1× 2× 3× copy" && manager.selected == copy.id)
        manager.selected = ExportPreset.shipped[3].id
        #expect(manager.duplicate()?.name == "PNG 1× 2× 3× copy 2")
        manager.selected = copy.id
        let renamed = try #require(manager.rename(to: "  App icons  "))
        #expect(renamed.name == "App icons" && renamed.settings.scales == [1, 2, 3])
        #expect(manager.rename(to: " ") == nil && manager.rename(to: String(repeating: "x", count: 65)) == nil)
        // Export and import as a file.
        let data = manager.exported()
        let folder = try Self.directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "presets.json")
        #expect(manager.export(to: file))
        manager.delete()
        #expect(!store.all.contains { $0.name == "App icons" })
        #expect(manager.importFile(file) == 2 && manager.message == "2 presets imported" && store.all.contains { $0.name == "App icons" })
        #expect(manager.importPresets(data) == 2)
        #expect(manager.importPresets(Data("nonsense".utf8)) == 0 && manager.message == "The file is not a preset file.")
        #expect(manager.importFile(folder.appending(path: "missing.json")) == 0)
        manager.selected = nil
        #expect(manager.duplicate() == nil)
        // The sheet and its command.
        var closed = false
        PanelRendering.host(ExportPresetManagerView(manager: manager, close: { closed = true }))
        ExportPresetManagerView.exporting(manager) { file }()
        ExportPresetManagerView.exporting(manager) { nil }()
        ExportPresetManagerView.importing(manager) { file }()
        ExportPresetManagerView.importing(manager) { nil }()
        manager.selected = store.userPresets.first?.id
        manager.renameText = "Renamed"
        ExportPresetManagerView.renaming(manager)()
        #expect(store.all.contains { $0.name == "Renamed" } && !closed)
        let world = TypeWorld()
        defer { world.close() }
        let command = ExportPresetManagerView.command(store: store) { world.window }
        #expect(command.validation().isEnabled && !ExportPresetManagerView.command(store: store, window: { nil }).validation().isEnabled)
        if case .perform(let run) = command.action { run() }
        if let sheet = world.window.window?.attachedSheet { world.window.window?.endSheet(sheet) }
    }

    // MARK: Drag export (IO-016)

    @Test func aDragCarriesLazyFlavorsAndAPromiseFromTheSnapshotAtDragStart() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let folder = try Self.directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = await world.document.addRectangles([Rect(x: 50, y: 50, width: 40, height: 40)])
        world.window.selection.model.set(Selection(ids))
        #expect(DragExport.format("svg") == .svg && DragExport.format("png") == .png && DragExport.format("jpeg") == .jpeg && DragExport.format("tiff") == .tiff)
        #expect(DragExport.format("pdf") == .pdf && DragExport.format("?") == .pdf)
        let payload = Data([1, 2, 3])
        let writers = DragExport.writers(payload, window: world.window, format: .pdf) { .png }
        let item = try #require(writers.first as? NSPasteboardItem)
        let promise = try #require(writers.last as? SnapshotPromise)
        #expect(item.data(forType: ObjectDragging.type) == payload)
        #expect(item.types.contains(NSPasteboard.PasteboardType(ClipboardFormat.pdfType)) && item.types.contains(NSPasteboard.PasteboardType(ClipboardFormat.pngType)))
        // The artwork changes after the drag began: the file is the snapshot's.
        _ = await world.document.perform(DeleteNodes(ids.map(\.opID))).value
        #expect(promise.filePromiseProvider(promise, fileNameForType: promise.fileType).hasSuffix(".pdf"))
        let url = folder.appending(path: "Drag.pdf")
        var failure: (any Error)? = CocoaError(.fileNoSuchFile)
        promise.filePromiseProvider(promise, writePromiseTo: url) { failure = $0 }
        #expect(failure == nil && ((try? Data(contentsOf: url))?.count ?? 0) > 100)
        // kbd:[Option] at the drop picks the format from the menu.
        promise.optionHeld = { true }
        #expect(promise.filePromiseProvider(promise, fileNameForType: promise.fileType).hasSuffix(".png") && promise.format == .png)
        let png = folder.appending(path: "Drag.png")
        promise.filePromiseProvider(promise, writePromiseTo: png) { failure = $0 }
        #expect(failure == nil && FileManager.default.fileExists(atPath: png.path))
        // A write that cannot happen reports its error.
        promise.filePromiseProvider(promise, writePromiseTo: URL(fileURLWithPath: "/nonexistent/x.png")) { failure = $0 }
        #expect(failure != nil)
        // The window's drags use these writers.
        _ = await world.document.undo().value
        world.window.selection.model.set(Selection(ids))
        let dragging = ObjectDragging(editing: world.window.objectEditing)
        world.window.canvas.objectDrop = dragging
        DragExport.attach(world.window, preferences: world.setup.environment.preferences)
        let items = dragging.draggingItems(image: nil, frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        #expect(items.count == 2)
        world.window.canvas.objectDrop?.makeWriters = nil
        #expect(dragging.draggingItems(image: nil, frame: NSRect(x: 0, y: 0, width: 10, height: 10)).count == 1)
        #expect(DragExport.formats.count == 5)
    }
}
