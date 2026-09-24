import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The DOC epic's controls as the views wire them: bindings, button actions and hosted bodies.
@Suite(.serialized) @MainActor struct DocumentSetupControlTests {
    /// Lays `view` out in a hosting view, so its body and its rows are built.
    func host<V: View>(_ view: V, size: NSSize = NSSize(width: 480, height: 640)) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
    }

    @Test func thePanelControlsBindToTheModel() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        let model = DocumentPanelModel(window: setup.window)
        let state = DocumentPanelState()
        state.window = { setup.window }
        _ = await document.perform(NewMasterPage(from: setup.page.id, name: "")).value
        _ = await document.perform(SetPrinterResolution(333)).value
        host(DocumentPanelControls(model: model, state: state))
        state.showsList = true
        host(DocumentPanelControls(model: model, state: state))
        host(DocumentPanelBody(state: state))
        #expect(DocumentPanelControls.resolutionItems(333).last == 333 && DocumentPanelControls.resolutionItems(300) == SetPrinterResolution.presets)
        #expect(DocumentPanelControls.masterName(model.masters[0]) == "Master")
        let size = DocumentPanelControls.pageSize(model)
        #expect(size.wrappedValue == "Letter")
        size.wrappedValue = "A5"
        await document.settle()
        #expect(document.activePage.geometry.preset == "A5")
        let resolution = DocumentPanelControls.resolution(model)
        #expect(resolution.wrappedValue == 333)
        resolution.wrappedValue = 600
        DocumentPanelControls.typedResolution(model)(1200)
        await document.settle()
        #expect(model.resolution == 1200)
        let master = DocumentPanelControls.master(model)
        #expect(master.wrappedValue == nil)
        master.wrappedValue = model.masters[0].id
        await document.settle()
        #expect(document.activePage.master == model.masters[0].id)
        master.wrappedValue = nil
        await document.settle()
        DocumentPanelControls.orientation(model, .landscape)()
        await document.settle()
        #expect(document.activePage.geometry.orientation == .landscape)
        DocumentPanelControls.scale(model, 1)()
        #expect(setup.window.documentPanelScale == 1)
        let list = DocumentPanelControls.showsList(state)
        list.wrappedValue = false
        #expect(!list.wrappedValue && !state.showsList)
        DocumentPanelControls.editSizes(model)()
        #expect(setup.window.window?.attachedSheet?.identifier?.rawValue == "sheet.pageSizes")
        setup.window.window?.attachedSheet.map { setup.window.window?.endSheet($0) }
        // The page list's rows select their page; dragging one moves it.
        await document.addPage().value
        let pages = document.pageList.pages
        PageListView.select(pages[0], in: model)()
        #expect(document.activePage.id == pages[0].id)
        PageListView.mover(model)([0], 2)
        await document.settle()
        #expect(document.pageList.pages[1].id == pages[0].id)
    }

    @Test func sheetButtonsCloseWhenTheyWentThrough() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        var closed = 0
        SheetButtons.closing({ false }, { closed += 1 })()
        SheetButtons.closing({ true }, { closed += 1 })()
        #expect(closed == 1)
        // The window's sheets perform through its object commands.
        setup.window.sheetPerform(SetGrid(size: 24))
        await setup.document.settle()
        #expect(setup.document.settings.grid.size == 24)
        #expect(setup.window.sheetLayer() == setup.window.pickingLayer)
        // Every sheet body builds with its rows.
        let document = setup.document
        _ = await document.perform(AddCustomUnit(name: "ft", amount: 12, base: .inches)).value
        _ = await document.perform(AddCustomUnit(name: "ft", amount: 1, base: .points)).value
        _ = await document.perform(AddCustomPageSize(name: "Poster", size: Size(width: 100, height: 200))).value
        _ = await document.perform(AddGuides(on: [setup.page.id], axis: .vertical, at: [10])).value
        _ = await document.perform(NewMasterPage(from: setup.page.id)).value
        let perform: @MainActor (any WTModel.Command) -> Void = { document.perform($0) }
        let units = UnitsSheetModel(document: document, perform: perform)
        host(UnitsSheet(model: units, close: {}))
        let sizes = PageSizesSheetModel(document: document, perform: perform)
        host(PageSizesSheet(model: sizes, close: {}))
        let guides = GuidesSheetModel(document: document, page: setup.page.id, perform: perform)
        host(GuidesSheet(model: guides, close: {}))
        guides.placement = .increment
        host(GuidesSheet(model: guides, close: {}))
        let grid = GridSheetModel(document: document, perform: perform)
        grid.sizeText = "?"
        grid.commit()
        host(GridSheet(model: grid, close: {}))
        let add = AddPagesSheetModel(document: document, perform: perform)
        add.size.preset = PageSizeChoice.custom
        add.countText = "?"
        add.add()
        host(AddPagesSheet(model: add, close: {}))
        let move = MovePageSheetModel(document: document, perform: perform)
        move.numberText = "?"
        move.move()
        host(MovePageSheet(model: move, close: {}))
        let modify = ModifyPageSheetModel(document: document, page: setup.page.id, perform: perform)
        modify.size.preset = PageSizeChoice.custom
        modify.bleedText = "?"
        modify.ok()
        host(ModifyPageSheet(model: modify, close: {}))
        // The rows' fields commit through their closures.
        let feet = units.units[0]
        UnitRow.rename(units, feet)("foot")
        UnitRow.amount(units, feet)(6)
        let base = UnitRow.base(units, feet)
        #expect(base.wrappedValue == .inches)
        base.wrappedValue = .millimeters
        await document.settle()
        #expect(units.units[0].name == "foot" && units.units[0].base == .millimeters)
        // A custom size and a pageless document's geometry read as the sheets show them.
        let choice = PageSizeChoice(PageGeometry(width: 100, height: 200), settings: document.settings, units: document.unitConverter)
        #expect(choice.isCustom && choice.geometry == PageGeometry(width: 100, height: 200))
        choice.widthText = "?"
        #expect(choice.geometry == nil)
        let pageless = DocumentHandle(title: "None", model: WTModel.Document(memory: DocumentTemplate.core(replica: 5)))
        let first = AddPagesSheetModel(document: pageless, perform: { pageless.perform($0) })
        #expect(first.command()?.after == nil)
    }

    @Test func theLinksButtonsActOnTheSelectedRow() async throws {
        let world = try await LinksTests.World.make()
        defer { world.close() }
        let model = world.model
        let selection = LinksView.selection(model)
        selection.wrappedValue = world.asset
        #expect(selection.wrappedValue == world.asset)
        model.showInfo()
        #expect(model.info == world.asset)
        host(LinksView(model: model), size: NSSize(width: 700, height: 500))
        model.updateSelected()
        await model.running?.value
        #expect(world.document.undoTitle == "Undo Update link")
        model.chooseFile = { nil }
        model.changeSelected()
        await model.running?.value
        model.extractSelected()
        await model.running?.value
        model.updateAllLinks()
        await model.running?.value
        model.embedSelected()
        await world.document.settle()
        #expect(world.link()?.kind == .embedded)
        model.selection = nil
        model.embedSelected()
        model.changeSelected()
        // A placed file and a library link show too.
        var library = Wiretuner_Doc_V1_NodeProps()
        library.asset.link.kind = .library
        library.asset.link.libraryDocument = "doc-1"
        library.asset.mediaType = "image/tiff"
        _ = await world.document.perform(OpsCommand("Library", ops: [Ops.create(parent: WellKnown.assets, position: [0x70], props: library)])).value
        let row = try #require(model.rows.first { $0.isLibrary })
        #expect(row.status == "Library" && row.page == "Pasteboard")
        #expect(model.infoLines(row.id).contains { $0.0 == "Library document" })
        model.info = row.id
        host(LinksView(model: model), size: NSSize(width: 700, height: 500))
        let embedded = try #require(model.rows.first { $0.status == "Embedded" })
        #expect(model.infoLines(embedded.id).contains { $0 == ("Source", "Embedded") })
        #expect(await MissingLinks.bookmark(OpID(counter: 1, replica: 1), of: world.document) == nil)
        await MissingLinks.keepBookmarks([FoundLink(asset: world.asset, path: "/x")], for: world.document)
    }

    @Test func theWindowWiresTheRulersCornerAndCanvas() async throws {
        let setup = SetupWindow(tools: [PointerTool.descriptor])
        defer { setup.close() }
        let window = setup.window
        let page = setup.page
        _ = await setup.document.perform(AddGuides(on: [page.id], axis: .horizontal, at: [100])).value
        #expect(window.furniture.participants().isEmpty)
        window.rulerHost.horizontalRuler.onDrag?(.began, setup.windowPoint(page.rect.center), [])
        window.rulerHost.horizontalRuler.onDrag?(.ended, setup.windowPoint(Point(x: page.rect.midX, y: page.origin.y + 300)), [])
        window.rulerHost.verticalRuler.onDrag?(.began, setup.windowPoint(page.rect.center), [])
        window.rulerHost.verticalRuler.onDrag?(.ended, setup.windowPoint(page.rect.center), .option)
        window.rulerHost.corner.onDrag?(.began, setup.windowPoint(page.rect.center), [])
        window.rulerHost.corner.onDrag?(.ended, setup.windowPoint(page.rect.center), [])
        window.rulerHost.corner.onReset?()
        await setup.document.settle()
        #expect(setup.document.pageList.pages[0].guides.count == 3)
        window.canvas.onPressAt?(page.rect.center)
        window.guideHandles.editGuides(page.id)
        #expect(window.window?.attachedSheet?.identifier?.rawValue == "sheet.guides")
        window.window?.attachedSheet.map { window.window?.endSheet($0) }
        window.toolManager.context.modifyPage?(page.id)
        #expect(window.window?.attachedSheet?.identifier?.rawValue == "sheet.modifyPage")
        window.window?.attachedSheet.map { window.window?.endSheet($0) }
        window.confirm = { _, _ in false }
        #expect(!window.toolManager.context.confirm("?", "?"))
        // The notice bar's buttons.
        let banner = window.collaboration.banner
        var acted: [UUID] = []
        banner.onAction = { acted.append($0) }
        banner.onDismissAction = { acted.append($0) }
        let action = BannerAction(id: UUID(), text: "t", button: "b")
        CollaborationBannerView.act(banner, action)()
        CollaborationBannerView.dismissAction(banner, action)()
        #expect(acted == [action.id, action.id])
        banner.actions = [action]
        host(CollaborationBannerView(model: banner))
        // The dragged selection's edges: the Pointer tool moving the selection.
        let squares = await setup.document.addRectangles([Rect(x: page.rect.minX + 10, y: page.rect.minY + 10, width: 20, height: 20)])
        window.selection.model.set(Selection(squares))
        let pointer = try #require(window.toolManager.activeTool as? PointerTool)
        pointer.mouseDown(setup.event(Point(x: page.rect.minX + 20, y: page.rect.minY + 20)))
        pointer.mouseDragged(setup.event(Point(x: page.rect.minX + 60, y: page.rect.minY + 20)))
        #expect(window.draggedSelectionBounds != nil)
        window.canvas.onPointer?(page.rect.center)
        #expect(window.rulerHost.horizontalRuler.trackedBounds != nil)
        pointer.cancel()
    }

    @Test func furnitureAndDragsCoverTheirEdges() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        let page = setup.page
        let furniture = setup.window.furniture
        furniture.showsGrid = true
        furniture.drawGrid(document.pageList, in: CGContext.test(), viewport: Viewport(size: Size(width: 0, height: 0)))
        _ = await document.perform(AddGuides(on: [page.id], axis: .vertical, at: [100])).value
        let guide = document.pageList.pages[0].guides[0]
        var drag = GuideDrag(source: .guide(page: page.id, ids: guide.ids), axis: .vertical, point: Point(x: page.origin.x + 150, y: page.rect.midY))
        #expect((drag.command(in: document.pageList, option: false) as? MoveGuide)?.position == 150)
        #expect(drag.readout(in: document.pageList, units: Units()) == "150 pt")
        drag.snapsToGrid = true
        #expect(drag.position(in: document.pageList) == page.origin.x + 156, "12.5 picas rounds up")
        var ruler = GuideDrag(source: .ruler, axis: .horizontal, point: page.rect.center)
        ruler.move(to: page.rect.center, modifiers: .option, pages: document.pageList)
        #expect((ruler.command(in: document.pageList, option: true) as? AddGuides)?.pages == [page.id], "the page under the release, crossed once")
        ruler.crossed = []
        #expect((ruler.command(in: document.pageList, option: true) as? AddGuides)?.pages == [page.id])
        // A ruler drag in the handles never "disappears"; a guide on a removed page does.
        let handles = setup.window.guideHandles
        let context = setup.window.toolManager.context
        furniture.drag = ruler
        handles.drag(setup.event(page.rect.center), context: context)
        #expect(furniture.drag != nil)
        furniture.drag = GuideDrag(source: .guide(page: OpID(counter: 9, replica: 9), ids: guide.ids), axis: .vertical, point: .zero)
        handles.drag(setup.event(page.rect.center), context: context)
        #expect(furniture.drag == nil)
    }

    @Test func pageToolEdges() async throws {
        let fixture = await PageToolTests.Fixture.make(pages: 3)
        defer { fixture.close() }
        let document = fixture.document
        let pages = fixture.pages
        // Removing two pages with objects asks in the plural.
        _ = await document.addRectangles([Rect(x: pages[1].rect.minX + 10, y: pages[1].rect.minY + 10, width: 20, height: 20),
                                          Rect(x: pages[2].rect.minX + 10, y: pages[2].rect.minY + 10, width: 20, height: 20)])
        var asked = ""
        var context = fixture.setup.window.toolManager.context
        context.confirm = { message, _ in asked = message; return false }
        document.selectPages([pages[1].id, pages[2].id])
        fixture.tool.removeSelected(in: context)
        #expect(asked == "Remove the 2 pages and the 2 objects on them?")
        // Control resizes without snapping; the other anchors and ratios.
        let rect = Rect(x: 0, y: 0, width: 100, height: 100)
        for anchor in HandleAnchor.allCases {
            let point = PageTool.point(anchor.opposite, of: rect) + Vector(dx: 10, dy: 10)
            _ = PageTool.resize(rect, anchor: anchor, to: point, proportional: true, fromCenter: false)
            _ = PageTool.resize(rect, anchor: anchor, to: point, proportional: true, fromCenter: true)
            _ = PageTool.resize(rect, anchor: anchor, to: point, proportional: false, fromCenter: true)
        }
        #expect(PageTool.rotates(.zero, from: Point(x: 1, y: 0.01), to: Point(x: -0.2, y: -1)))
        document.selectPage(id: pages[0].id)
        let a = pages[0]
        fixture.tool.mouseDown(fixture.setup.event(Point(x: a.rect.maxX, y: a.rect.maxY)))
        fixture.tool.mouseDragged(fixture.setup.event(Point(x: a.rect.maxX + 40, y: a.rect.maxY + 40), .control))
        fixture.tool.drawOverlay(in: CGContext.test(), viewport: fixture.setup.window.viewport)
        fixture.tool.mouseUp(fixture.setup.event(Point(x: a.rect.maxX + 40, y: a.rect.maxY + 40), .control))
        await document.settle()
        #expect(document.pageList.pages[0].rect.width == a.rect.width + 40)
        // A rotate that does not turn far enough and a tiny resize do nothing.
        let now = document.pageList.pages[0]
        let outside = Point(x: now.rect.maxX + 8, y: now.rect.maxY + 8)
        fixture.drag(outside, outside + Vector(dx: 5, dy: 0))
        fixture.drag(Point(x: now.rect.maxX, y: now.rect.maxY), Point(x: now.rect.maxX + 1, y: now.rect.maxY))
        await document.settle()
        #expect(document.pageList.pages[0].rect == now.rect)
        // Without a context the tool does nothing.
        let bare = PageTool()
        bare.mouseDown(fixture.setup.event(.zero))
        bare.mouseUp(fixture.setup.event(.zero))
        bare.drawOverlay(in: CGContext.test(), viewport: fixture.setup.window.viewport)
        #expect(bare.moveDelta(pages: [], document: document) == nil)
        #expect(bare.resizedRect(a, anchor: .top, to: fixture.setup.event(.zero)) == nil)
    }
}

@Suite(.serialized) @MainActor struct DocumentSetupEdgeTests {
    @Test func linksWiringStoresBlobsAndRepairsOnOpen() async throws {
        let moved = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: moved.appending(path: "photo.png"))
        let world = try await LinksTests.World.make(path: "/nowhere/photo.png")
        defer { world.close() }
        let features = DocumentSetupFeatures(preferences: world.setup.environment.preferences, device: "this-mac")
        let cache = TestEnvironment.temporaryDirectory()
        features.blobs = BlobPlacement(directory: { cache })
        let model = features.linksModel(for: world.setup.window)
        try await model.storeBlob(ImportedBlob(data: Data([4]), uti: "public.png"))
        #expect(model.cachedBlob(ImportedBlob.hash(Data([4]))) == Data([4]))
        world.setup.environment.preferences.set(moved.path, for: PreferenceCatalog.Document.missingLinksFolder)
        let found = await features.documentDidOpen(world.setup.window)?.value
        #expect(found?.count == 1 && world.link()?.path == moved.appending(path: "photo.png").path)
    }

    @Test func linkRowsForPlacedFilesDeletedObjectsAndThePasteboard() async throws {
        let world = try await LinksTests.World.make()
        defer { world.close() }
        let document = world.document
        let layer = try #require(LayerOrder(document.state).drawingLayer)
        var file = Wiretuner_Doc_V1_NodeProps()
        file.placedFile.source.id = world.asset.proto
        file.placedFile.common.transform.a = 1
        file.placedFile.common.transform.d = 1
        _ = await document.perform(OpsCommand("Place", ops: [Ops.create(parent: layer, position: [0x10], props: file)])).value
        _ = await document.perform(DeleteNodes([world.image])).value
        #expect(LinksModel.objects(placing: world.asset, in: document.state).count == 1)
        #expect(world.model.rows.first?.page == "Pasteboard")
        let odd = world.file.deletingLastPathComponent().appending(path: "noextension")
        try Data([1]).write(to: odd)
        #expect(try LinksModel.blob(at: odd).blob.uti == "public.data")
    }

    @Test func thePasteboardViewWithoutAWindowAndStrayEvents() async throws {
        let view = PasteboardMiniatureView(window: nil)
        #expect(view.scale > 0 && view.page(at: .zero) == nil)
        view.renderThumbnails()
        view.pressed(at: .zero, clickCount: 1)
        view.dragged(to: .zero)
        view.released(at: .zero)
        let image = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4,
                                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        view.draw(view.bounds)
        let setup = SetupWindow()
        defer { setup.close() }
        let window = PasteboardMiniatureView(window: setup.window)
        window.frame = NSRect(x: 0, y: 0, width: 240, height: 160)
        window.spaceDown = { false }
        window.dragged(to: .zero)
        window.pressed(at: Point(x: 1, y: 1), clickCount: 1)
        window.dragged(to: Point(x: 5, y: 5))
        window.released(at: Point(x: 5, y: 5))
        #expect(window.press == nil)
    }
}
