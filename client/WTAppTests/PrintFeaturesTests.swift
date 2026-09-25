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

/// A document window with the print features installed and snapping off, so dragged points land
/// where they are dropped.
@MainActor
struct PrintWorld {
    let setup: SetupWindow
    let features: PrintFeatures
    let selection = ActiveSelection()

    init() {
        setup = SetupWindow(tools: [OutputAreaTool.descriptor])
        features = PrintFeatures(defaults: setup.environment.suite.defaults)
        let window = setup.window
        features.install(commands: setup.environment.commands, tools: setup.environment.tools, panels: setup.environment.panels, selection: selection) { window }
        for kind in [SnapSettings.Kind.point, .object, .guides] where window.snap[kind] { window.toggleSnap(kind) }
        setup.environment.preferences.set(false, for: PreferenceCatalog.General.smartGuides)
        selection.model = window.selection.model
        selection.document = window.documentHandle
        selection.editing = window.objectEditing
    }

    var window: DocumentWindowController { setup.window }
    var document: DocumentHandle { setup.document }
    var commands: CommandRegistry { setup.environment.commands }
    var manager: ToolManager { window.toolManager }
    var center: Point { setup.page.rect.center }

    func point(_ dx: Double, _ dy: Double) -> Point { Point(x: center.x + dx, y: center.y + dy) }

    /// A drag of the active tool from `a` to `b`, with `modifiers` throughout.
    func drag(_ a: Point, _ b: Point, _ modifiers: KeyModifiers = []) async {
        manager.mouseDown(setup.event(a, modifiers))
        manager.mouseDragged(setup.event(Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), modifiers))
        manager.mouseDragged(setup.event(b, modifiers))
        manager.mouseUp(setup.event(b, modifiers))
        await document.settle()
    }

    var area: Rect? { OutputArea.read(document.state) }

    func close() {
        features.detach(window)
        setup.close()
    }

    static func context(width: Int = 600, height: Int = 400) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
}

@Suite(.serialized) @MainActor struct PrintFeaturesTests {
    static func near(_ a: Rect?, _ b: Rect, _ tolerance: Double = 1e-6) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance && abs(a.maxX - b.maxX) < tolerance && abs(a.maxY - b.maxY) < tolerance
    }

    // MARK: Geometry

    @Test func dragsMakeRectanglesSquaresAndCentredOnes() {
        let anchor = Point(x: 100, y: 100)
        #expect(OutputAreaGeometry.defined(from: anchor, to: Point(x: 160, y: 130), square: false, fromCenter: false) == Rect(x: 100, y: 100, width: 60, height: 30))
        #expect(OutputAreaGeometry.defined(from: anchor, to: Point(x: 160, y: 130), square: true, fromCenter: false) == Rect(x: 100, y: 100, width: 60, height: 60))
        #expect(OutputAreaGeometry.defined(from: anchor, to: Point(x: 40, y: 90), square: true, fromCenter: false) == Rect(x: 40, y: 40, width: 60, height: 60))
        #expect(OutputAreaGeometry.defined(from: anchor, to: Point(x: 110, y: 120), square: false, fromCenter: true) == Rect(x: 90, y: 80, width: 20, height: 40))
    }

    @Test func handlesResizeFromTheOppositeSideOrTheCentre() {
        let rect = Rect(x: 0, y: 0, width: 100, height: 50)
        typealias H = OutputAreaGeometry.Handle
        #expect(H.allCases.map { $0.isCorner } == [true, false, true, false, true, false, true, false])
        #expect(H.topLeft.opposite == .bottomRight && H.left.opposite == .right)
        #expect(OutputAreaGeometry.resized(rect, handle: .bottomRight, to: Point(x: 200, y: 60), proportional: false, aboutCenter: false) == Rect(x: 0, y: 0, width: 200, height: 60))
        #expect(OutputAreaGeometry.resized(rect, handle: .right, to: Point(x: 150, y: 999), proportional: false, aboutCenter: false) == Rect(x: 0, y: 0, width: 150, height: 50))
        #expect(OutputAreaGeometry.resized(rect, handle: .bottom, to: Point(x: 999, y: 80), proportional: false, aboutCenter: false) == Rect(x: 0, y: 0, width: 100, height: 80))
        // Shift keeps the proportions: the larger factor of a corner, the side's own factor.
        #expect(OutputAreaGeometry.resized(rect, handle: .bottomRight, to: Point(x: 200, y: 60), proportional: true, aboutCenter: false) == Rect(x: 0, y: 0, width: 200, height: 100))
        #expect(OutputAreaGeometry.resized(rect, handle: .right, to: Point(x: 200, y: 0), proportional: true, aboutCenter: false) == Rect(x: 0, y: -25, width: 200, height: 100))
        #expect(OutputAreaGeometry.resized(rect, handle: .top, to: Point(x: 0, y: -50), proportional: true, aboutCenter: false) == Rect(x: -50, y: -50, width: 200, height: 100))
        #expect(OutputAreaGeometry.resized(rect, handle: .topLeft, to: Point(x: 200, y: 60), proportional: true, aboutCenter: false).minX == 100)
        // Option resizes about the centre.
        #expect(OutputAreaGeometry.resized(rect, handle: .right, to: Point(x: 150, y: 0), proportional: false, aboutCenter: true) == Rect(x: -50, y: 0, width: 200, height: 50))
        let viewport = Viewport(scrollOrigin: .zero, zoom: 1, size: Size(width: 400, height: 300))
        #expect(OutputAreaGeometry.handle(at: Point(x: 101, y: 26), on: rect, viewport: viewport, distance: 3) == .right)
        #expect(OutputAreaGeometry.handle(at: Point(x: 50, y: 20), on: rect, viewport: viewport, distance: 3) == nil)
        #expect(OutputAreaGeometry.isOnArea(Point(x: 50, y: 20), rect: rect, viewport: viewport, distance: 3))
        #expect(!OutputAreaGeometry.isOnArea(Point(x: 150, y: 20), rect: rect, viewport: viewport, distance: 3))
    }

    // MARK: The tool

    @Test func theToolDefinesMovesResizesNudgesAndRemovesTheArea() async throws {
        let world = PrintWorld()
        defer { world.close() }
        world.manager.select(OutputAreaTool.id)
        let tool = try #require(world.manager.activeTool as? OutputAreaTool)
        #expect(tool.cursor == .crosshair && !tool.hasSomethingToCancel && tool.area == nil)
        // A click with no area does nothing.
        world.manager.mouseDown(world.setup.event(world.point(0, 0)))
        world.manager.mouseUp(world.setup.event(world.point(0, 0)))
        await world.document.settle()
        #expect(world.area == nil)
        // Define.
        await world.drag(world.point(-100, -80), world.point(100, 20))
        #expect(Self.near(world.area, Rect(x: world.center.x - 100, y: world.center.y - 80, width: 200, height: 100)))
        #expect(world.document.model?.undoTitle.lowercased() == "undo define output area")
        // Shift: a square; Option: from the centre (each replaces the area).
        await world.drag(world.point(-300, -300), world.point(-250, -200), .shift)
        #expect(Self.near(world.area, Rect(x: world.center.x - 300, y: world.center.y - 300, width: 100, height: 100)))
        await world.drag(world.point(250, 250), world.point(260, 270), .option)
        #expect(Self.near(world.area, Rect(x: world.center.x + 240, y: world.center.y + 230, width: 20, height: 40)))
        // Move by dragging inside; resize by a handle.
        let before = try #require(world.area)
        await world.drag(before.center, Point(x: before.center.x + 30, y: before.center.y + 10))
        #expect(Self.near(world.area, before.offset(by: Vector(dx: 30, dy: 10))))
        #expect(world.document.model?.undoTitle.lowercased() == "undo move output area")
        let moved = try #require(world.area)
        let corner = OutputAreaGeometry.Handle.bottomRight.point(on: moved)
        await world.drag(corner, Point(x: corner.x + 40, y: corner.y + 60))
        #expect(Self.near(world.area, Rect(x: moved.minX, y: moved.minY, width: moved.width + 40, height: moved.height + 60)))
        #expect(world.document.model?.undoTitle.lowercased() == "undo resize output area")
        // Arrow keys nudge by a unit (points here), Shift by ten; Delete removes.
        let resized = try #require(world.area)
        #expect(tool.handleKey(keyCode: 124, shift: false))
        await world.document.settle()
        #expect(Self.near(world.area, resized.offset(by: Vector(dx: 1, dy: 0))))
        #expect(tool.handleKey(keyCode: 125, shift: true))
        await world.document.settle()
        #expect(Self.near(world.area, resized.offset(by: Vector(dx: 1, dy: 10))))
        #expect(!tool.handleKey(keyCode: 0, shift: false))
        // The overlay draws the handles and, mid-drag, the preview.
        let context = PrintWorld.context()
        tool.drawOverlay(in: context, viewport: world.window.viewport)
        world.manager.mouseDown(world.setup.event(world.point(200, 200)))
        world.manager.mouseDragged(world.setup.event(world.point(260, 260)))
        #expect(tool.preview != nil && tool.hasSomethingToCancel)
        world.manager.flagsChanged([.shift])
        tool.drawOverlay(in: context, viewport: world.window.viewport)
        tool.cancel()
        #expect(tool.preview == nil)
        world.manager.mouseDragged(world.setup.event(world.point(270, 270)))
        // A click outside removes the area.
        world.manager.mouseDown(world.setup.event(world.point(-350, 300)))
        world.manager.mouseUp(world.setup.event(world.point(-350, 300)))
        await world.document.settle()
        #expect(world.area == nil)
        #expect(!tool.handleKey(keyCode: 51, shift: false))
        await world.drag(world.point(-100, -80), world.point(100, 20))
        #expect(tool.handleKey(keyCode: 51, shift: false))
        await world.document.settle()
        #expect(world.area == nil)
        // A zero-size drag writes nothing.
        await world.drag(world.point(0, 0), world.point(0, 10))
        #expect(world.area == nil)
        world.manager.select(.pointer)
    }

    @Test func thePointerShowsWhatAPressWouldDo() async throws {
        let world = PrintWorld()
        defer { world.close() }
        world.manager.select(OutputAreaTool.id)
        let tool = try #require(world.manager.activeTool as? OutputAreaTool)
        await world.drag(world.point(-100, -100), world.point(100, 100))
        let area = try #require(world.area)
        tool.pointerMoved(world.setup.event(area.center))
        #expect(tool.hover == .moving(start: area.center, rect: area) && tool.cursor == .openHand)
        tool.pointerMoved(world.setup.event(area.center))
        tool.pointerMoved(world.setup.event(OutputAreaGeometry.Handle.top.point(on: area)))
        #expect(tool.cursor == .crosshair)
        if case .resizing(.top, _)? = tool.hover {} else { Issue.record("expected the top handle") }
        tool.pointerMoved(world.setup.event(world.point(300, 300)))
        if case .defining? = tool.hover {} else { Issue.record("expected defining") }
        // Mid-gesture the hover is left alone.
        world.manager.mouseDown(world.setup.event(world.point(300, 300)))
        tool.pointerMoved(world.setup.event(area.center))
        tool.mouseDragged(world.setup.event(world.point(301, 301)))
        tool.cancel()
        // Without a context nothing happens.
        let bare = OutputAreaTool()
        bare.mouseDown(world.setup.event(.zero))
        bare.mouseDragged(world.setup.event(.zero))
        bare.mouseUp(world.setup.event(.zero))
        bare.flagsChanged(world.setup.event(.zero))
        bare.pointerMoved(world.setup.event(.zero))
        #expect(!bare.handleKey(keyCode: 124, shift: false) && bare.area == nil && !bare.isDragging)
        bare.drawOverlay(in: PrintWorld.context(), viewport: world.window.viewport)
        world.manager.select(.pointer)
        #expect(tool.context == nil)
    }

    // MARK: Window overlay and commands

    @Test func theOverlayFollowsTheAreaAndTheShowToggle() async throws {
        let world = PrintWorld()
        defer { world.close() }
        let print = world.features.attach(world.window)
        #expect(world.features.attach(world.window) === print)
        #expect(print.showsArea && print.area == nil)
        typealias ID = PrintFeatures.ID
        #expect(world.commands.command(ID.showOutputArea)?.validation() == .checked(true))
        #expect(world.commands.command(ID.removeOutputArea)?.validation() == .disabled(PrintFeatures.noArea))
        _ = await world.document.perform(SetOutputArea(Rect(x: 10, y: 10, width: 100, height: 50))).value
        await world.document.settle()
        #expect(print.area == Rect(x: 10, y: 10, width: 100, height: 50))
        print.documentDidChange()
        let context = PrintWorld.context()
        world.window.canvas.furnitureDrawer?(context)
        world.commands.perform(ID.showOutputArea)
        #expect(!print.showsArea && world.commands.command(ID.showOutputArea)?.validation() == .checked(false))
        print.draw(in: context)
        world.commands.perform(ID.showOutputArea)
        #expect(world.commands.command(ID.removeOutputArea)?.validation() == .enabled)
        world.commands.perform(ID.removeOutputArea)
        await world.document.settle()
        #expect(world.area == nil && world.features.removeArea() == nil)
        // The Export sheet's *Output area* reads the document's area.
        world.features.detach(world.window)
        world.features.detach(world.window)
        world.features.window = { nil }
        #expect(world.commands.command(ID.showOutputArea)?.validation() == .disabled(PrintFeatures.noDocument))
        #expect(world.commands.command(ID.removeOutputArea)?.validation() == .disabled(PrintFeatures.noDocument))
        #expect(world.commands.command(StandardCommands.ID.print)?.validation() == .disabled(PrintFeatures.noDocument))
        world.features.toggleShowsArea()
        #expect(world.features.pageSetup() == nil && !world.features.print())
    }

    @Test func pageSetupAndPrintKeepThePrintInfoOnThisMac() async throws {
        let world = PrintWorld()
        defer { world.close() }
        await world.document.addRectangles([Rect(x: world.center.x - 50, y: world.center.y - 50, width: 100, height: 100)])
        var laidOut = 0
        world.features.runPageLayout = { info in
            laidOut += 1
            info.orientation = .landscape
            return laidOut == 1
        }
        let task = try #require(world.features.pageSetup())
        #expect(await task.value?.label == "Page Setup")
        let info = PrintFeatures.printInfo(for: world.document)
        #expect(info.orientation == .landscape)
        #expect(world.features.pageSetup() == nil)
        // Print runs the operation with the pane; afterwards the print info is kept.
        var operations: [NSPrintOperation] = []
        world.features.runPrint = { operations.append($0); return true }
        #expect(world.commands.command(StandardCommands.ID.print)?.validation() == .enabled)
        world.commands.perform(StandardCommands.ID.print)
        await world.document.settle()
        let operation = try #require(operations.first)
        #expect(operation.jobTitle == world.document.title && operation.printPanel.accessoryControllers.count == 1)
        let view = try #require(operation.view as? PrintSheetsView)
        #expect(view.job.sheetCount == 1)
        // A pane change rebuilds the job (the output area, once there is one).
        let pane = try #require(world.features.pane)
        _ = await world.document.perform(SetOutputArea(Rect(x: world.center.x - 60, y: world.center.y - 60, width: 120, height: 120))).value
        pane.source = .outputArea
        pane.changed()
        #expect(view.job.sheetCount == 1 && view.job.scene.pages.first?.bounds.width == 120)
        world.features.runPrint = { _ in false }
        #expect(!world.features.print())
        // A damaged archive falls back to the shared print info.
        _ = await world.document.perform(SetPrintInfo(Data([1, 2, 3]))).value
        #expect(PrintFeatures.printInfo(for: world.document).paperSize.width > 0)
    }

    // MARK: The print job

    @Test func sheetsScaleCentreAndOffsetOnThePaper() async throws {
        let world = PrintWorld()
        defer { world.close() }
        await world.document.addRectangles([Rect(x: world.center.x - 50, y: world.center.y - 50, width: 100, height: 100)])
        let job = try #require(PrintJob.make(for: world.window, source: .pages, blobs: BlobPlacement()))
        #expect(job.sheetCount == 1)
        #expect(PrintJob.make(for: world.window, source: .outputArea, blobs: BlobPlacement()) == nil)
        let imageable = CGRect(x: 18, y: 18, width: 576, height: 756)
        let page = try #require(job.pdf?.page(at: 1)).getBoxRect(.mediaBox)
        let placed = try #require(job.placement(ofSheet: 0, imageable: imageable))
        #expect(abs(placed.width - page.width) < 1e-6 && abs(placed.midX - imageable.midX) < 1e-6)
        #expect(job.placement(ofSheet: 5, imageable: imageable) == nil)
        var variable = job
        variable.settings.scaleMode = .variable
        variable.settings.scaleX = 50
        variable.settings.scaleY = 200
        variable.settings.offset = Point(x: 10, y: 20)
        let stretched = try #require(variable.placement(ofSheet: 0, imageable: imageable))
        #expect(abs(stretched.width - page.width / 2) < 1e-6 && abs(stretched.height - page.height * 2) < 1e-6)
        #expect(abs(stretched.midX - (imageable.midX + 10)) < 1e-6 && abs(stretched.midY - (imageable.midY - 20)) < 1e-6)
        var fit = job
        fit.settings.scaleMode = .fit
        #expect(fit.scale(of: Size(width: 1152, height: 1512), imageable: imageable) == (0.5, 0.5))
        #expect(fit.scale(of: Size(width: 0, height: 10), imageable: imageable) == (1, 1))
        fit.settings.flatness = 2
        let context = PrintWorld.context(width: 612, height: 792)
        fit.draw(sheet: 0, in: context, imageable: imageable)
        fit.draw(sheet: 3, in: context, imageable: imageable)
        // The print view stacks one paper-sized stripe per sheet.
        let info = NSPrintInfo()
        let view = PrintSheetsView(job: job, printInfo: info)
        var range = NSRange()
        #expect(view.knowsPageRange(&range) && range == NSRange(location: 1, length: 1) && !view.isFlipped)
        #expect(view.rectForPage(1).height == info.paperSize.height && view.rectForPage(9) == view.rectForPage(1))
        view.drawSheets(in: context, dirty: view.bounds)
        view.drawSheets(in: context, dirty: .zero)
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let empty = PrintJob(scene: ExportSceneFallback.empty, settings: job.settings, pdf: nil)
        #expect(empty.sheetCount == 0)
    }

    // MARK: The pane

    @Test func everyPaneControlWritesOneLabelledChange() async throws {
        let world = PrintWorld()
        defer { world.close() }
        _ = await world.document.perform(CreateDefaultSwatches()).value
        var performed: [String] = []
        let document = world.document
        let pane = PrintPaneModel(document: document) { command in
            performed.append(command.label)
            document.perform(command)
        }
        var changes = 0
        pane.onChange = { changes += 1 }
        #expect(!pane.hasOutputArea && pane.effectiveSource == .pages)
        pane.commit(.bleed(9))
        pane.commit(.scaleMode(.variable))
        pane.commit(.mark(.crop, true))
        pane.center()
        pane.setDefaultScreen(shape: .line)
        pane.setDefaultScreen(frequency: 85)
        #expect(pane.inks.count >= 4)
        pane.setPlate(.magenta, print: false)
        await document.settle()
        #expect(performed == ["Change bleed", "Change scaling", "Turn on crop marks", "Change offset", "Change halftone screen", "Change halftone screen",
                              "Turn off Magenta plate"])
        #expect(changes == 7 && pane.revision == 7)
        let settings = pane.settings
        #expect(settings.bleed == 9 && settings.scaleMode == .variable && settings.marks == [.crop] && settings.defaultHalftone.frequency == 85)
        let rows = pane.plates
        #expect(Array(rows.map(\.name).prefix(4)) == ["Cyan", "Magenta", "Yellow", "Black"] && rows[1].print == false && rows[0].angle == 15 && rows[0].frequency == 85)
        #expect(pane.summary.map(\.value) == ["Pages", "100% × 100%", "Composite", "9 pt"])
        pane.commit(.scaleMode(.fit))
        await document.settle()
        #expect(pane.summary[1].value == "Fit on paper")
        pane.commit(.scaleMode(.uniform))
        await document.settle()
        #expect(pane.summary[1].value == "100%")
        #expect(PrintPaneModel.number(12.5) == "12.5")
        // The output area choice only with an area.
        pane.source = .outputArea
        #expect(pane.effectiveSource == .pages)
        _ = await document.perform(SetOutputArea(Rect(x: 0, y: 0, width: 10, height: 10))).value
        #expect(pane.hasOutputArea && pane.effectiveSource == .outputArea)
        // The pane renders, and its bindings commit.
        Render.view(PrintPaneView(model: pane), size: CGSize(width: 440, height: 560))
        PrintPaneView.source(pane).wrappedValue = .pages
        #expect(PrintPaneView.source(pane).wrappedValue == .pages)
        PrintPaneView.scaleMode(pane).wrappedValue = .variable
        PrintPaneView.separations(pane).wrappedValue = true
        PrintPaneView.mark(pane, .registration).wrappedValue = true
        PrintPaneView.shape(pane).wrappedValue = 4
        for item in [PrintPaneView.pageBoundaries] + PrintPaneView.outputSwitches + PrintPaneView.imagingSwitches {
            PrintPaneView.binding(pane, item).wrappedValue = true
            await document.settle()
            #expect(PrintPaneView.binding(pane, item).wrappedValue, "\(item.id)")
        }
        for item in [PrintPaneView.scaleX, PrintPaneView.scaleY, PrintPaneView.bleed] + PrintPaneView.offsets + PrintPaneView.imagingNumbers {
            PrintPaneView.commit(pane, item)(80)
            await document.settle()
            #expect(item.value(pane.settings) == 80, "\(item.id)")
        }
        PrintPaneView.commit(pane, PrintPaneView.imagingNumbers[1])(-5)
        await document.settle()
        #expect(pane.settings.rasterizeDPI == 0)
        #expect(PrintPaneView.scaleMode(pane).wrappedValue == .variable && PrintPaneView.separations(pane).wrappedValue)
        #expect(PrintPaneView.mark(pane, .registration).wrappedValue && PrintPaneView.shape(pane).wrappedValue == 4)
        let row = try #require(pane.plates.first)
        PrintPaneView.platePrint(pane, row).wrappedValue = false
        await document.settle()
        PrintPaneView.plateAngle(pane, row)(400)
        await document.settle()
        PrintPaneView.plateFrequency(pane, row)(120)
        await document.settle()
        PrintPaneView.screenFrequency(pane)(700)
        await document.settle()
        #expect(!PrintPaneView.platePrint(pane, pane.plates[0]).wrappedValue && pane.plates[0].angle == 360 && pane.plates[0].frequency == 120)
        #expect(pane.settings.defaultHalftone.frequency == 600 && PrintPaneModel.frequency(0, or: 60) == 60)
        Render.view(PrintPaneView(model: pane), size: CGSize(width: 440, height: 560))
        // The accessory controller hosts it, summarises it and bumps its preview key path.
        let accessory = PrintAccessoryController(model: pane)
        _ = accessory.view
        #expect(accessory.keyPathsForValuesAffectingPreview() == ["revision"])
        #expect(accessory.localizedSummaryItems().count == 4)
        pane.changed()
        #expect(accessory.revision == 1)
    }

    // MARK: Halftones panel

    @Test func theHalftonesPanelWritesWholeScreensAndShowsMixed() async throws {
        let world = PrintWorld()
        defer { world.close() }
        #expect(HalftonesPanelBody.model(world.selection) == nil)
        Render.view(HalftonesPanelBody(selection: world.selection))
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 20, y: 0, width: 10, height: 10)])
        world.window.selection.model.set(Selection(ids))
        let model = try #require(HalftonesPanelBody.model(world.selection))
        #expect(model.targets.count == 2 && model.shape == .unspecified && model.angle == 0 && model.frequency == 0)
        model.setShape(.line)
        await world.document.settle()
        #expect(world.document.model?.undoTitle.lowercased() == "undo change halftone of 2 objects")
        HalftonesPanelBody.model(world.selection)!.setAngle(405)
        await world.document.settle()
        HalftonesPanelBody.model(world.selection)!.setFrequency(1000)
        await world.document.settle()
        let set = try #require(HalftonesPanelBody.model(world.selection))
        #expect(set.shape == .line && set.angle == 45 && set.frequency == 600)
        // One object changed alone reads Mixed on the pair.
        _ = await world.document.perform(SetObjectHalftone([ids[0].opID], halftone: Wiretuner_Doc_V1_Halftone.with { $0.shape = .round; $0.angle = 15; $0.frequency = 40 })).value
        let mixed = try #require(HalftonesPanelBody.model(world.selection))
        #expect(mixed.shape == nil && mixed.angle == nil && mixed.frequency == nil)
        Render.view(HalftonesPanelBody(selection: world.selection))
        HalftonesPanelBody.shape(mixed).wrappedValue = 3
        await world.document.settle()
        HalftonesPanelBody.slider(HalftonesPanelBody.model(world.selection)!).wrappedValue = 1
        await world.document.settle()
        HalftonesPanelBody.dial(HalftonesPanelBody.model(world.selection)!).wrappedValue = 50
        await world.document.settle()
        let bound = try #require(HalftonesPanelBody.model(world.selection))
        #expect(HalftonesPanelBody.shape(bound).wrappedValue == 3 && bound.frequency == 600 && bound.angle == 45)
        #expect(HalftonesPanelBody.slider(bound).wrappedValue == 1 && HalftonesPanelBody.dial(bound).wrappedValue == 45)
        bound.useDocumentSettings()
        await world.document.settle()
        #expect(HalftonesPanelBody.model(world.selection)!.shape == .unspecified)
        #expect(HalftonesPanelModel.frequency(atSlider: 0) == 1 && abs(HalftonesPanelModel.sliderPosition(60) - log(60) / log(600)) < 1e-9)
        // Nothing to write without targets; the descriptor replaces the placeholder.
        let none = HalftonesPanelModel(document: world.document, nodes: []) { _ in Issue.record("nothing should be performed") }
        #expect(none.command { _ in } == nil)
        none.setShape(.round)
        none.setAngle(10)
        none.setFrequency(10)
        none.useDocumentSettings()
        #expect(world.setup.environment.panels.descriptor(for: "halftones")?.title == "Halftones")
        _ = HalftonesPanel.descriptor(selection: world.selection).makeView()
        world.selection.editing = nil
        HalftonesPanelBody.model(world.selection)?.setShape(.cross)
        await world.document.settle()
        #expect(HalftonesPanelBody.model(world.selection)?.shape == .cross)
    }
}
