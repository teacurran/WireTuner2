import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

@Suite @MainActor struct DocumentPanelTests {
    @Test func pageOptionsAreOneChangeEach() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        let model = DocumentPanelModel(window: setup.window)
        #expect(model.pageSize == "Letter" && model.orientation == .portrait && model.bleed == 0 && model.resolution == 300)
        #expect(model.presetItems.first == "Letter" && model.presetItems.last == DocumentPanelModel.customTitle)
        #expect(model.sizeLine == "612 × 792 pt")
        model.choosePageSize("A4")
        await document.settle()
        #expect(document.activePage.geometry.preset == "A4" && document.undoTitle == "Undo Change page size")
        model.setOrientation(.landscape)
        await document.settle()
        #expect(document.activePage.geometry.orientation == .landscape && document.undoTitle == "Undo Change orientation")
        model.setOrientation(.landscape)
        model.setBleed(9)
        await document.settle()
        #expect(document.activePage.bleed == 9 && document.undoTitle == "Undo Change bleed")
        model.setBleed(9)
        model.setBleed(-1)
        model.setResolution(600)
        await document.settle()
        #expect(model.resolution == 600 && document.undoTitle == "Undo Change printer resolution")
        model.setResolution(10)
        model.choosePageSize(DocumentPanelModel.customTitle)
        await document.settle()
        #expect(model.pageSize == DocumentPanelModel.customTitle)
        model.choosePageSize(DocumentPanelModel.customTitle)
        model.choosePageSize("No such size")
        // Several selected pages: the pop-up shows them only when they agree.
        await document.addPage().value
        document.selectPages(document.pageList.pages.map(\.id))
        model.choosePageSize("Legal")
        await document.settle()
        #expect(model.pageSize == "Legal" && model.sizeLine == nil)
        _ = await document.perform(SetPageGeometry([document.pageList.pages[1].id], to: PageGeometry(PagePreset.named("A5")!))).value
        #expect(model.pageSize == nil)
        model.choosePageSize(DocumentPanelModel.customTitle)
        await document.settle()
        #expect(document.undoTitle == "Undo Change page size")
    }

    @Test func mastersApplyAndDetachFromThePopUp() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        let model = DocumentPanelModel(window: setup.window)
        let page = setup.page
        _ = await document.perform(NewMasterPage(from: page.id)).value
        let master = try #require(model.masters.first)
        #expect(model.master == .some(nil))
        model.chooseMaster(master.id)
        await document.settle()
        #expect(document.activePage.master == master.id && model.followsMaster && document.undoTitle == "Undo Apply master page")
        model.chooseMaster(master.id)
        model.choosePageSize("A4")
        model.setOrientation(.landscape)
        model.setBleed(3)
        model.chooseMaster(nil)
        await document.settle()
        #expect(document.activePage.master == nil && document.undoTitle == "Undo Detach from master page")
        model.chooseMaster(nil)
    }

    @Test func theOptionsMenuRunsThePageCommands() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        let model = DocumentPanelModel(window: setup.window)
        var items = model.optionsMenu()
        #expect(items.map(\.title) == ["Add Pages…", "Duplicate", "Remove", "Move Page…", "New Master Page", "Convert to Master Page", "Release Child Page"])
        #expect(!items[2].isEnabled && !items[3].isEnabled && !items[6].isEnabled)
        items[1].action()
        await document.settle()
        #expect(document.pageList.pages.count == 2 && document.undoTitle == "Undo Duplicate page")
        items = model.optionsMenu()
        document.selectPage(1)
        items[2].action()
        await document.settle()
        #expect(document.pageList.pages.count == 1)
        items[4].action()
        await document.settle()
        #expect(document.pageList.masters.count == 1)
        items = model.optionsMenu()
        items[5].action()
        await document.settle()
        #expect(document.activePage.isChild)
        items = model.optionsMenu()
        #expect(items[6].isEnabled && !items[5].isEnabled)
        items[6].action()
        await document.settle()
        #expect(!document.activePage.isChild && document.undoTitle.hasPrefix("Undo Release page 1"))
        items[0].action()
        #expect(setup.window.window?.attachedSheet?.identifier?.rawValue == "sheet.addPages")
        setup.window.window?.attachedSheet.map { setup.window.window?.endSheet($0) }
        await document.addPage().value
        model.optionsMenu()[3].action()
        #expect(setup.window.window?.attachedSheet?.identifier?.rawValue == "sheet.movePage")
        setup.window.window?.attachedSheet.map { setup.window.window?.endSheet($0) }
    }

    @Test func theBodyFollowsTheFrontWindow() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let state = DocumentPanelState()
        _ = DocumentPanelBody(state: state).body
        state.window = { setup.window }
        _ = DocumentPanelBody(state: state).body
        let revision = state.revision
        state.follow(setup.document)
        state.follow(setup.document)
        setup.document.selectPage(0)
        await setup.document.addPage().value
        #expect(state.revision > revision)
        state.showsList = true
        _ = DocumentPanelControls(model: DocumentPanelModel(window: setup.window), state: state).body
        _ = PageListView(model: DocumentPanelModel(window: setup.window)).body
        state.touch()
        state.follow(nil)
        let descriptor = DocumentPanel.descriptor(state: state)
        #expect(descriptor.id == "document" && descriptor.optionsMenu().count == 7)
        state.window = { nil }
        #expect(descriptor.optionsMenu().isEmpty)
        _ = descriptor.makeView()
        // The page list reorders by dragging a row.
        let model = DocumentPanelModel(window: setup.window)
        let pages = setup.document.pageList.pages
        PageListView.move(from: [0], to: 2, in: model)
        await setup.document.settle()
        #expect(setup.document.pageList.pages.map(\.id) == [pages[1].id, pages[0].id] && setup.document.undoTitle == "Undo Move page 2")
        PageListView.move(from: [1], to: 0, in: model)
        await setup.document.settle()
        #expect(setup.document.pageList.pages.map(\.id) == pages.map(\.id))
        PageListView.move(from: [0], to: 0, in: model)
        PageListView.move(from: [9], to: 0, in: model)
        // The magnification is per window view state.
        setup.window.documentPanelScale = 2
        #expect(setup.window.currentState.documentPanelScale == 2)
    }

    @Test func thePasteboardViewSelectsMovesAndScrolls() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        await document.addPage().value
        let view = PasteboardMiniatureView(window: setup.window)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 160)
        view.spaceDown = { false }
        let pages = document.pageList.pages
        let first = pages[0]
        let center = Point(x: view.viewRect(first.rect).midX, y: view.viewRect(first.rect).midY)
        #expect(view.page(at: center)?.id == first.id && view.page(at: Point(x: 1, y: 1)) == nil)
        view.pressed(at: center, clickCount: 1)
        view.released(at: center)
        #expect(document.activePage.id == first.id)
        view.pressed(at: center, clickCount: 2)
        view.released(at: center)
        // Dragging a thumbnail moves the page and its objects.
        view.pressed(at: center, clickCount: 1)
        view.dragged(to: Point(x: center.x, y: center.y + 5))
        #expect(view.dragDelta != nil)
        view.renderThumbnails()
        #expect(view.thumbnails[first.id] != nil)
        let image = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4,
                                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        view.released(at: Point(x: center.x, y: center.y + 5))
        await document.settle()
        #expect(document.pageList.pages[0].origin.y > first.origin.y && document.undoTitle == "Undo Move page")
        // Space-drag scrolls, inside the pasteboard.
        setup.window.documentPanelScale = 2
        view.spaceDown = { true }
        view.pressed(at: Point(x: 100, y: 100), clickCount: 1)
        view.dragged(to: Point(x: 60, y: 70))
        view.released(at: Point(x: 60, y: 70))
        #expect(view.scroll == Point(x: 40, y: 30))
        view.reveal(first)
        #expect(view.scroll.x > 0)
        // A later change re-renders the thumbnails after the delay.
        view.contentDidChange()
        #expect(await eventually { view.thumbnails[first.id]?.count == document.changeCount })
        view.follow(nil)
        view.follow(setup.window)
        view.pressed(at: Point(x: 1, y: 1), clickCount: 1)
        view.dragged(to: Point(x: 2, y: 2))
        view.released(at: Point(x: 2, y: 2))
        _ = PasteboardMiniature(window: setup.window, revision: 0)
    }
}

@Suite @MainActor struct PageSheetTests {
    @Test func addPagesWithAMaster() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        _ = await document.perform(NewMasterPage(from: setup.page.id)).value
        let model = AddPagesSheetModel(document: document) { document.perform($0) }
        #expect(model.countText == "1" && model.size.preset == "Letter" && !model.childOfMaster && model.master != nil)
        model.countText = "3"
        model.size.preset = PageSizeChoice.custom
        model.size.widthText = "5in"
        model.size.heightText = "7in"
        model.bleedText = "9"
        model.childOfMaster = true
        #expect(model.add())
        await document.settle()
        #expect(document.pageList.pages.count == 4 && document.undoTitle == "Undo Add 3 pages")
        #expect(document.pageList.pages[1].isChild && document.pageList.pages[1].ownGeometry.width == 360)
        model.countText = "0"
        #expect(!model.add() && model.problem == AddPagesSheetModel.invalid)
        model.countText = "1"
        model.size.widthText = "0"
        #expect(model.size.geometry == nil)
        _ = AddPagesSheet(model: model, close: {}).body
        _ = PageSizeFields(size: model.size).body
    }

    @Test func movePageTakesAPageNumber() async {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        await document.addPage().value
        document.selectPage(0)
        let model = MovePageSheetModel(document: document) { document.perform($0) }
        #expect(model.numberText == "1" && model.pageCount == 2)
        model.numberText = "3"
        #expect(!model.move() && model.problem != nil)
        model.numberText = "1"
        #expect(model.move())
        model.numberText = "2"
        let id = document.activePage.id
        #expect(model.move())
        await document.settle()
        #expect(document.pageList.pages[1].id == id && document.undoTitle == "Undo Move page 2")
        _ = MovePageSheet(model: model, close: {}).body
    }

    @Test func modifyPageWritesWhatChanged() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        let page = setup.page
        let model = ModifyPageSheetModel(document: document, page: page.id) { document.perform($0) }
        #expect(model.command() == nil && model.ok(), "nothing changed")
        model.size.preset = "A4"
        model.bleedText = "18"
        #expect(model.ok())
        await document.settle()
        #expect(document.activePage.geometry.preset == "A4" && document.activePage.bleed == 18 && document.undoTitle == "Undo Modify page")
        model.bleedText = "?"
        #expect(!model.ok() && model.problem == ModifyPageSheetModel.invalid)
        _ = await document.perform(NewMasterPage(from: page.id)).value
        let master = try #require(document.pageList.masters.first)
        let child = ModifyPageSheetModel(document: document, page: page.id) { document.perform($0) }
        child.master = master.id
        #expect(child.followsMaster && child.ok())
        await document.settle()
        #expect(document.activePage.master == master.id)
        let gone = ModifyPageSheetModel(document: document, page: OpID(counter: 99, replica: 9)) { document.perform($0) }
        #expect(gone.command() == nil)
        _ = ModifyPageSheet(model: child, close: {}).body
        let sheet = setup.window.presentModifyPageSheet(page: page.id)
        if let sheet { setup.window.window?.endSheet(sheet) }
    }

    @Test func pageSizesAreDefinedEditedAndDeleted() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        let model = PageSizesSheetModel(document: document) { document.perform($0) }
        model.add()
        await document.settle()
        let size = try #require(model.sizes.first)
        #expect(size.name == "Size 1" && size.size == Size(width: 612, height: 792) && document.undoTitle == "Undo Add page size")
        model.rename(size, to: "Poster")
        await document.settle()
        model.rename(model.sizes[0], to: "")
        _ = await document.perform(SetPageGeometry([setup.page.id], to: PageGeometry(preset: "Poster", portrait: Size(width: 612, height: 792)))).value
        PageSizeRow.width(model, model.sizes[0])(720)
        await document.settle()
        #expect(model.sizes[0].size.width == 720 && document.activePage.geometry.width == 720, "pages using the size follow it")
        PageSizeRow.height(model, model.sizes[0])(0)
        PageSizeRow.rename(model, model.sizes[0])("Poster")
        model.selection = model.sizes[0].id
        model.delete()
        await document.settle()
        #expect(model.sizes.isEmpty && document.activePage.geometry.preset.isEmpty && document.activePage.geometry.width == 720)
        model.delete()
        _ = PageSizesSheet(model: model, close: {}).body
        _ = PageSizeRow(model: model, size: size).body
        let sheet = setup.window.presentPageSizesSheet()
        if let sheet { setup.window.window?.endSheet(sheet) }
    }
}

@Suite @MainActor struct PageNoticeTests {
    @Test func aLostPageSizeOffersReapplyMine() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        let window = setup.window
        let page = setup.page
        _ = await document.perform(SetPageGeometry([page.id], to: PageGeometry(PagePreset.named("Legal")!))).value
        await document.receiveRemote(SetPageGeometry([page.id], to: PageGeometry(PagePreset.named("A4")!)))
        let notice = try #require(window.pageNotices.notices.first)
        #expect(notice.text == "Someone changed page 1 to A4 while you set it to Legal" && notice.action == "Reapply mine")
        #expect(window.collaboration.banner.actions.count == 1 && !window.collaboration.banner.isEmpty)
        window.collaboration.banner.onAction(notice.id)
        await document.settle()
        #expect(document.activePage.geometry.preset == "Legal" && window.pageNotices.notices.isEmpty)
        // A remote size of a page not set here is not a loss.
        await document.receiveRemote(SetBleed([page.id], to: 4))
        #expect(window.pageNotices.notices.isEmpty)
        #expect(PageNotices.describe(PageGeometry(width: 100, height: 200), units: Units()) == "100 × 200 pt")
    }

    @Test func aRemovedPageWithMyObjectsOffersRestore() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        let window = setup.window
        await document.addPage().value
        let second = document.pageList.pages[1]
        _ = await document.addRectangles([Rect(x: second.rect.minX + 10, y: second.rect.minY + 10, width: 20, height: 20)])
        await document.receiveRemote(OpsCommand("Remove", ops: [Ops.setDeleted(second.id)]))
        let notice = try #require(window.pageNotices.notices.first)
        #expect(notice.text == "Page 2 was removed by Someone; your object is on the pasteboard" && notice.action == "Restore page")
        window.collaboration.banner.onDismissAction(notice.id)
        #expect(window.pageNotices.notices.isEmpty && window.collaboration.banner.actions.isEmpty)
        let notices = PageNotices()
        var now = Date()
        notices.clock = { now }
        _ = notices.pagesChanged(PageListChange(before: document.pageList, after: document.pageList, origin: .local, change: nil), author: "A", units: Units(),
                                 state: document.state)
        now += PageNotices.recent + 1
        #expect(!notices.pagesChanged(PageListChange(before: document.pageList, after: document.pageList, origin: .remote, change: nil), author: "A",
                                      units: Units(), state: document.state))
        // Restore brings it back.
        _ = await document.perform(notice.command).value
        #expect(document.pageList.pages.count == 2)
    }
}
