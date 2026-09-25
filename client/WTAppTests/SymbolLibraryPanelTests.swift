import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The Library panel over LIB-009's symbol commands, menu:Modify[Symbol], and the Layers panel's
/// Guides layer turning objects into guides and back (LIB-006's glue).
@Suite(.serialized) @MainActor struct SymbolLibraryPanelTests {
    @MainActor
    final class Fixture {
        let environment = TestEnvironment()
        let document = DocumentHandle.memory(title: "Library")
        let controller: DocumentWindowController
        let selection: ActiveSelection
        let model: SymbolLibraryModel
        var presented = 0
        var dismissed = 0

        init() {
            controller = DocumentWindowController(document: document, environment: environment.document)
            selection = ActiveSelection(model: controller.selection.model, document: document, editing: controller.objectEditing)
            model = SymbolLibraryModel(selection: selection)
            model.present = { [unowned self] _ in self.presented += 1 }
            model.dismiss = { [unowned self] in self.dismissed += 1 }
        }

        func select(_ ids: [OpID]) {
            controller.selection.model.set(Selection(ids.map(SelectionID.init)))
        }

        func settle(_ task: Task<Wiretuner_Doc_V1_Change?, Never>?) async {
            _ = await task?.value
            await document.settle()
        }

        var instances: [OpID] { document.state.store.nodes.filter { document.state.nodeKind($0) == .instance && document.state.isLive($0) } }
    }

    @Test func symbolsAreMadeListedSortedAndOrganizedInFolders() async throws {
        let f = Fixture()
        let rects = await f.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20), Rect(x: 40, y: 0, width: 20, height: 20)])
        #expect(f.model.rows.isEmpty && f.model.newSymbol() == nil && f.model.copyToSymbol() == nil)
        f.select([rects[0].opID])
        await f.settle(f.model.newSymbol())
        #expect(f.document.undoTitle == "Undo Convert to Symbol" && f.model.rows.count == 1 && f.model.rows[0].count == 1)
        f.select([rects[1].opID])
        await f.settle(f.model.copyToSymbol())
        #expect(f.model.rows.count == 2 && f.model.rows.contains { $0.count == 0 })
        // Rename the copy "Alpha".
        let copy = try #require(f.model.rows.first { $0.count == 0 })
        f.model.beginRename(copy.id)
        f.model.renameText = "Alpha"
        await f.settle(f.model.commitRename())
        #expect(f.model.rows.first?.name == "Alpha", "sorted by name")
        f.model.beginRename(copy.id)
        #expect(f.model.commitRename() == nil, "unchanged")
        f.model.sort(by: .count)
        #expect(f.model.rows.first?.count == 0)
        f.model.sort(by: .count)
        #expect(f.model.rows.first?.count == 1 && !f.model.ascending)
        f.model.sort(by: .name)
        // A folder, and symbols moved into it and back out.
        await f.settle(f.model.newFolder())
        let folder = try #require(f.model.rows.first { $0.kind == .folder })
        f.model.click(copy.id)
        f.model.click(folder.id, modifiers: .command)
        #expect(f.model.selected.count == 2)
        f.model.click(folder.id, modifiers: .command)
        await f.settle(f.model.move(to: folder.id))
        #expect(f.model.rows.first { $0.id == copy.id }?.folder == folder.id && f.model.rows.first { $0.id == copy.id }?.depth == 1)
        f.model.click(folder.id)
        await f.settle(f.model.newFolder())
        #expect(f.model.rows.filter { $0.kind == .folder }.count == 2, "a folder inside the selected folder")
        f.model.click(copy.id)
        await f.settle(f.model.move(to: nil))
        #expect(f.model.rows.first { $0.id == copy.id }?.folder == nil)
        // Shift-click selects the range.
        let rows = f.model.rows
        f.model.click(rows[0].id)
        f.model.click(rows[rows.count - 1].id, modifiers: .shift)
        #expect(f.model.selected.count == rows.count && f.model.selectedSymbol == nil)
        f.model.click(copy.id)
        await f.settle(f.model.duplicate())
        #expect(f.document.undoTitle == "Undo Duplicate Symbol")
        f.model.click(folder.id)
        #expect(f.model.duplicate() == nil && f.model.move(to: folder.id) == nil)
    }

    @Test func placeSwapReplaceAndRemoveWithTheInstancesSheet() async throws {
        let f = Fixture()
        let rects = await f.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20), Rect(x: 40, y: 0, width: 20, height: 20),
                                                     Rect(x: 80, y: 0, width: 10, height: 30)])
        f.select([rects[0].opID])
        await f.settle(f.model.newSymbol())
        let symbol = try #require(f.model.rows.first?.id)
        #expect(f.model.place() == nil && f.model.swap() == nil && f.model.replaceArtwork() == nil && f.model.preview() == nil)
        f.model.click(symbol)
        #expect(f.model.preview() != nil)
        await f.settle(f.model.place())
        #expect(f.instances.count == 2 && f.document.undoTitle == "Undo Place Symbol")
        f.select([rects[1].opID])
        await f.settle(f.model.swap())
        #expect(f.instances.count == 3)
        f.select([rects[2].opID])
        await f.settle(f.model.replaceArtwork())
        #expect(f.document.undoTitle == "Undo Replace Symbol Artwork")
        // Instances: the sheet asks, Cancel keeps the symbol, Release Instances removes it.
        #expect(f.model.remove() == nil && f.presented == 1 && f.model.pendingRemoval == [symbol])
        f.model.cancelRemove()
        #expect(f.dismissed == 1 && f.model.rows.count == 1 && f.model.confirmRemove(.delete) == nil)
        f.model.remove()
        await f.settle(f.model.confirmRemove(.release))
        #expect(f.model.rows.isEmpty && f.instances.isEmpty && f.document.undoTitle.hasPrefix("Undo Remove symbol"))
        // A folder of unused symbols goes without asking.
        let loose = await f.document.addRectangles([Rect(x: 0, y: 100, width: 5, height: 5)])[0]
        f.select([loose.opID])
        await f.settle(f.model.copyToSymbol())
        await f.settle(f.model.newFolder())
        f.model.click(try #require(f.model.rows.first { $0.kind == .folder }).id)
        await f.settle(f.model.remove())
        #expect(f.model.rows.count == 1 && f.presented == 2)
        f.model.click(try #require(f.model.rows.first).id)
        await f.settle(f.model.remove())
        #expect(f.model.rows.isEmpty)
        #expect(f.model.remove() == nil)
        // The body, the rows and the sheet render; the options menu runs.
        f.select([loose.opID])
        await f.settle(f.model.copyToSymbol())
        f.model.click(try #require(f.model.rows.first).id)
        PanelRendering.host(SymbolLibraryPanelBody(model: f.model))
        f.model.beginRename(try #require(f.model.rows.first).id)
        PanelRendering.host(SymbolLibraryPanelBody(model: f.model))
        f.model.renaming = nil
        PanelRendering.host(RemoveSymbolsSheet(model: f.model))
        _ = SymbolLibraryPanelBody.clicking(symbol, f.model)
        SymbolLibraryPanelBody.sorting(.count, f.model)()
        SymbolLibraryPanelBody.renaming(try #require(f.model.rows.first).id, f.model)()
        RemoveSymbolsSheet.choosing(.delete, f.model)()
        let menu = f.model.optionsMenu()
        #expect(menu.map(\.title).contains("Place") && menu.last?.title == "Hide Preview")
        menu.last?.action()
        #expect(!f.model.showsPreview && f.model.preview() == nil)
        PanelRendering.host(SymbolLibraryPanelBody(model: f.model))
        for item in f.model.optionsMenu() where item.title.hasPrefix("Move to") || item.title == "Show Preview" { item.action() }
        let away = SymbolLibraryModel(selection: ActiveSelection())
        PanelRendering.host(SymbolLibraryPanelBody(model: away))
        #expect(away.rows.isEmpty && away.perform(DeleteNodes([])) == nil && away.canvasObjects.isEmpty)
    }

    @Test func theSymbolMenuConvertsReleasesAndShowsInTheLibrary() async throws {
        let f = Fixture()
        let rect = await f.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)])[0]
        var shown = 0
        let commands = CommandRegistry()
        let panels = PanelRegistry()
        SymbolLibraryFeatures.install(commands: commands, panels: panels, model: f.model) { shown += 1 }
        #expect(panels.contains("library") && SymbolLibraryFeatures.descriptor(model: f.model).optionsMenu().count > 5)
        let convert = try #require(commands.command(SymbolLibraryFeatures.ID.convert))
        #expect(!convert.validation().isEnabled && convert.defaultKey == KeyEquivalent("f8", []))
        f.select([rect.opID])
        #expect(convert.validation().isEnabled)
        if case .perform(let run) = convert.action { run() }
        await f.document.settle()
        let instance = try #require(f.instances.first)
        f.select([instance])
        let show = try #require(commands.command(ContextMenuCatalog.ID.showInLibrary))
        #expect(show.validation().isEnabled)
        if case .perform(let run) = show.action { run() }
        #expect(shown == 1 && f.model.selectedSymbol != nil)
        let release = try #require(commands.command(ContextMenuCatalog.ID.releaseInstance))
        if case .perform(let run) = release.action { run() }
        await f.document.settle()
        #expect(f.instances.isEmpty && !release.validation().isEnabled)
        let copy = try #require(commands.command(SymbolLibraryFeatures.ID.copy))
        if case .perform(let run) = copy.action { run() }
        #expect(SymbolLibraryFeatures.instances(SymbolLibraryModel(selection: ActiveSelection())).isEmpty)
        let presenter = SheetPresenter()
        presenter.present = { _ in }
        SymbolLibraryFeatures.connectSheets(f.model, presenter: presenter)
        f.model.present(f.model)
        #expect(presenter.sheets[SymbolLibraryModel.removeSheet] != nil)
        f.model.dismiss()
        #expect(presenter.sheets.isEmpty)
    }

    @Test func movingObjectsOntoTheGuidesLayerMakesGuidesAndBackReleasesThem() async throws {
        let f = Fixture()
        let rect = await f.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)])[0]
        let layers = LayersPanelModel(document: f.document, editing: f.controller.objectEditing, state: LayersPanelState())
        #expect(layers.moveCommand([rect.opID], to: rect.opID) is MoveObjectsToLayer, "no Guides layer: an ordinary move")
        var props = Wiretuner_Doc_V1_NodeProps()
        props.layer.common.name = "Guides"
        props.layer.role = .guides
        props.layer.visible = true
        _ = await f.document.perform(OpsCommand("Guides", ops: [Ops.create(parent: WellKnown.layers, position: [0x40], props: props)])).value
        await f.document.settle()
        let guides = try #require(layers.order.guides)
        let art = try #require(Objects.parent(of: rect.opID, in: f.document.state))
        #expect(layers.moveCommand([rect.opID], to: guides).label == "Convert to Guide")
        f.select([rect.opID])
        await f.settle(layers.moveSelection(to: guides))
        #expect(Objects.parent(of: rect.opID, in: f.document.state) == guides)
        #expect(layers.moveCommand([rect.opID], to: art).label == "Release to Layer")
        await f.settle(layers.moveSelection(to: art))
        #expect(Objects.parent(of: rect.opID, in: f.document.state) == art)
        #expect(layers.moveCommand([rect.opID], to: art) is MoveObjectsToLayer)
    }
}
