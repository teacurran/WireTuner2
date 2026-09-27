import AppKit
import Foundation
import PDFKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The print plan's view, the Print dialog's session and its presets (PRINT-003, PRINT-004).
@Suite(.serialized) @MainActor struct PrintSessionTests {
    static func session(_ world: PrintWorld, info: NSPrintInfo = NSPrintInfo(), selection: Set<NodeID>? = nil) -> PrintSession {
        let document = world.document
        return PrintSession(document: document, info: info, selection: selection, imageStore: nil, blobs: BlobPlacement()) { document.perform($0) }
    }

    /// A spot swatch and a square filled with it.
    static func spotSquare(_ document: DocumentHandle, name: String, at rect: Rect) async -> OpID {
        let swatch = ColorWellActions.created(by: (await document.perform(AddSwatch(RenderColor(red: 1, green: 0.5, blue: 0), name: name, spot: true)).value)!)
        var appearance = Appearances.standard
        var fill = Wiretuner_Doc_V1_Fill()
        fill.settings.kind = .basic
        fill.settings.basic.color = SwatchList(document.state).resolver.reference(to: swatch)
        appearance.fills = [fill]
        _ = await document.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: rect.width, height: rect.height),
                                               transform: .translation(x: rect.minX, y: rect.minY), appearance: appearance)).value
        await document.settle()
        return swatch
    }

    /// The drawn items under `items`, groups opened.
    static func leaves(_ items: [DisplayItem]) -> Int {
        items.reduce(0) { count, item in
            if case .group(let group) = item { return count + leaves(group.children) }
            return count + 1
        }
    }

    // MARK: Paper and the plan's view

    @Test func thePaperIsThePrintInfosFlippedToATopLeftOrigin() {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        let paper = PrintJob.paper(info)
        let bounds = info.imageablePageBounds
        #expect(paper.size == Size(width: 612, height: 792))
        #expect(paper.imageable.width == Double(bounds.width) && paper.imageable.minX == Double(bounds.minX))
        #expect(paper.imageable.minY == 792 - Double(bounds.maxY))
        info.orientation = .landscape
        #expect(PrintJob.paper(info).size.width == Double(info.paperSize.width))
    }

    /// PRINT-013's Done when: a 200-sheet job, drawn from its snapshot off the main actor, leaves the
    /// document window responsive -- text typed during the job lands while sheets are still being
    /// drawn -- and the job reflects none of what was typed.
    @Test func aTwoHundredSheetJobKeepsTheWindowResponsiveAndIgnoresLaterEdits() async throws {
        let world = PrintWorld()
        defer { world.close() }
        await world.document.addRectangles([Rect(x: world.center.x - 50, y: world.center.y - 50, width: 100, height: 100)])
        _ = await world.document.perform(SetPrintSettings([.separations(true)])).value
        _ = await world.document.perform(AddPages(count: 49)).value
        await world.document.settle()
        let plan = PrintJob.plan(world.document, source: .pages, paper: .letter, selection: nil, blobs: BlobPlacement())
        #expect(plan.count == 200, "50 pages × 4 process plates")
        let run = PrintRun(plan: plan)
        let job = Task { try await run.pdfInBackground(title: "Job") }
        var landedDuringJob = 0
        for index in 0..<20 {
            _ = await world.document.addText("Typed during the job \(index)", at: Point(x: world.center.x, y: world.center.y + Double(index) * 14))
            if run.sheetsDrawn < plan.count { landedDuringJob += 1 }
        }
        let data = try await job.value
        #expect(landedDuringJob > 0, "edits landed while the job was drawing")
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 200 && run.plan == nil)
        #expect(!(pdf.string ?? "").contains("Typed"), "the job is the snapshot from before the typing")
        #expect(world.document.state.store.nodes.contains { world.document.state.textNode($0)?.string.hasPrefix("Typed") == true })
    }

    @Test func theViewPaginatesBySheetDrawsThemAndNamesThem() async throws {
        let world = PrintWorld()
        defer { world.close() }
        await world.document.addRectangles([Rect(x: world.center.x - 50, y: world.center.y - 50, width: 100, height: 100)])
        _ = await world.document.perform(SetPrintSettings([.separations(true), .mark(.crop, true), .mark(.separationNames, true)])).value
        let plan = PrintJob.plan(world.document, source: .pages, paper: .letter, selection: nil, blobs: BlobPlacement())
        #expect(plan.count == 4)
        let view = PrintPlanView(plan: plan, renderer: PrintJob.renderer(imageStore: nil), title: "Job")
        var range = NSRange()
        #expect(view.knowsPageRange(&range) && range == NSRange(location: 1, length: 4) && !view.isFlipped)
        #expect(view.frame.height == 792 * 4 && view.rectForPage(1).minY == 792 * 3 && view.rectForPage(9) == view.rectForPage(4))
        #expect(view.sheetName(2) == "Page 1, Magenta" && view.sheetName(9) == nil)
        #expect(view.printJobTitle == "Job" && view.pageHeader.string == "Job" && !view.isPreview())
        // Drawn with and without the preview overlays; a stripe outside the dirty rectangle is skipped.
        let context = PrintWorld.context(width: 612, height: 792 * 4)
        view.drawSheets(in: context, dirty: view.bounds, preview: true)
        view.drawSheets(in: context, dirty: view.rectForPage(4), preview: false)
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.rectForPage(1)))
        view.cacheDisplay(in: view.rectForPage(1), to: image)
        #expect(view.failedSheets == 0)
        // Without a graphics context there is nothing to draw into.
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = nil
        view.draw(view.bounds)
        NSGraphicsContext.current = saved
        // Pagination reports a new paper.
        var papers: [PrintPaper] = []
        view.onPaperChange = { papers.append($0) }
        view.currentPaper = { .letter }
        _ = view.knowsPageRange(&range)
        view.currentPaper = { PrintPaper(size: Size(width: 792, height: 612)) }
        _ = view.knowsPageRange(&range)
        #expect(papers == [PrintPaper(size: Size(width: 792, height: 612))])
        // A composite plan shrinks the view to one sheet.
        _ = await world.document.perform(SetPrintSettings(.separations(false))).value
        view.show(PrintJob.plan(world.document, source: .pages, paper: .letter, selection: nil, blobs: BlobPlacement()))
        #expect(view.plan.count == 1 && view.frame.height == 792)
        // A rasterized sheet that is cancelled is not drawn.
        _ = await world.document.perform(SetPrintSettings(.rasterizeDPI(72))).value
        view.show(PrintJob.plan(world.document, source: .pages, paper: .letter, selection: nil, blobs: BlobPlacement()))
        view.renderer.isCancelled = { true }
        view.drawSheets(in: context, dirty: view.bounds, preview: false)
        #expect(view.failedSheets == 1)
    }

    @Test func aPDFOperationPrintsEverySheetWithItsName() async throws {
        let world = PrintWorld()
        defer { world.close() }
        await world.document.addRectangles([Rect(x: world.center.x - 50, y: world.center.y - 50, width: 100, height: 100)])
        _ = await world.document.perform(SetPrintSettings(.separations(true))).value
        let info = NSPrintInfo()
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter.rawValue] = true
        let plan = PrintJob.plan(world.document, source: .pages, paper: PrintJob.paper(info), selection: nil, blobs: BlobPlacement())
        let view = PrintPlanView(plan: plan, renderer: PrintJob.renderer(imageStore: nil), title: "Job")
        // *Save as PDF*: the operation saves every sheet as a PDF page.
        let url = FileManager.default.temporaryDirectory.appending(path: "print-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        #expect(operation.run())
        let pdf = try #require(CGPDFDocument(url as CFURL))
        #expect(pdf.numberOfPages == 4)
    }

    // MARK: The session

    @Test func theSessionReplansOnRemoteChangesSelectionAndPaper() async throws {
        let world = PrintWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: world.center.x - 50, y: world.center.y - 50, width: 100, height: 100),
                                                      Rect(x: world.center.x + 60, y: world.center.y, width: 20, height: 20)])
        let session = Self.session(world, selection: [ids[0].node])
        session.start()
        #expect(session.rebuilds == 0 && session.pane.sheetCount == 1 && session.pane.lists?.count == 1 && !session.refresh())
        // A collaborator turns on separations: the plan, the view, the pane and the print info follow.
        await world.document.receiveRemote(SetPrintSettings(.separations(true)))
        #expect(session.plan.count == 4 && session.view.plan.count == 4 && session.pane.sheetCount == 4)
        #expect(session.accessory.revision >= 1 && session.rebuilds >= 1)
        // A notification with nothing new plans nothing.
        let revision = session.accessory.revision
        session.documentChanged()
        #expect(session.accessory.revision == revision)
        #expect((session.info.dictionary()["WTPrintSeparations"] as? NSNumber)?.boolValue == true)
        // *Selected objects only* prints the one selected square.
        let before = Self.leaves(session.plan.pages[0].displayList.items)
        PrintPaneView.selectedOnly(session.pane).wrappedValue = true
        #expect(PrintPaneView.selectedOnly(session.pane).wrappedValue && session.pane.effectiveSelection == [ids[0].node])
        #expect(Self.leaves(session.plan.pages[0].displayList.items) < before)
        #expect(session.pane.summary[0].value == "Pages, selected objects")
        // The panel's paper.
        let landscape = PrintPaper(size: Size(width: 792, height: 612))
        session.view.onPaperChange(landscape)
        #expect(session.plan.request.paper == landscape && session.paper == landscape)
        // Once the dialog closes, changes are no longer followed.
        session.end()
        let rebuilds = session.rebuilds
        await world.document.receiveRemote(SetPrintSettings(.separations(false)))
        #expect(session.rebuilds == rebuilds)
    }

    @Test func theInkListHoldsTheSpotsTheArtworkUses() async throws {
        let world = PrintWorld()
        defer { world.close() }
        _ = await world.document.perform(CreateDefaultSwatches()).value
        let orange = await Self.spotSquare(world.document, name: "Orange", at: Rect(x: world.center.x, y: world.center.y, width: 40, height: 40))
        _ = await world.document.perform(AddSwatch(RenderColor(red: 0, green: 0, blue: 1), name: "Unused", spot: true)).value
        let session = Self.session(world)
        #expect(session.pane.inks == [.cyan, .magenta, .yellow, .black, .spot(orange)])
        #expect(session.pane.plates.map(\.name) == ["Cyan", "Magenta", "Yellow", "Black", "Orange"])
        // Without a plan, the ink list reads the window's drawing.
        let bare = PrintPaneModel(document: world.document) { _ in }
        #expect(bare.inks == [.cyan, .magenta, .yellow, .black, .spot(orange)] && bare.sheetCount == 0)
    }

    @Test func marksOutsideThePrintableAreaWarnBeneathThePreview() async throws {
        let world = PrintWorld()
        defer { world.close() }
        _ = await world.document.perform(SetPrintSettings(.mark(.crop, true))).value
        let session = Self.session(world)
        #expect(session.pane.warning == session.plan.clippingWarning && session.pane.warning != nil)
        Render.view(PrintPaneView(model: session.pane), size: CGSize(width: 440, height: 600))
    }

    @Test func thePanelIsShowingWhileTheAccessoryIsOnScreen() async throws {
        let world = PrintWorld()
        defer { world.close() }
        let session = Self.session(world)
        #expect(!session.accessory.isShowing && !session.view.isPreview())
        let window = TestWindow.make(contentViewController: session.accessory)
        window.orderFront(nil)
        #expect(session.accessory.isShowing && session.view.isPreview())
        window.close()
    }

    // MARK: Presets

    @Test func aPresetCarriesThePaneSettingsToAnotherDocument() async throws {
        let world = PrintWorld()
        defer { world.close() }
        _ = await world.document.perform(SetPrintSettings([.bleed(9), .mark(.crop, true), .tile(.automatic), .includeHiddenLayers(true)])).value
        _ = await world.document.perform(SetPlate(.magenta, print: false, in: world.document.state)).value
        let saved = Self.session(world)
        #expect((saved.info.dictionary()["WTPrintBleed"] as? NSNumber)?.doubleValue == 9)
        #expect(saved.presetsApplied == 0)
        saved.loadPreset()
        #expect(saved.presetsApplied == 0)
        // The preset, as the panel's Presets menu would restore it into another document's dialog.
        let other = PrintWorld()
        defer { other.close() }
        let session = Self.session(other)
        session.start()
        defer { session.end() }
        for (key, value) in saved.infoEntries { session.info.dictionary()[key] = value }
        session.accessory.representedObject = session.info
        session.accessory.viewWillAppear()
        #expect(session.presetsApplied == 1)
        await other.document.settle()
        let settings = DocumentPrintSettings(other.document.state)
        #expect(settings.bleed == 9 && settings.marks == [.crop] && settings.tile == .automatic && settings.includeHiddenLayers)
        #expect(settings.plate(.magenta)?.print == false)
        #expect(other.document.model?.undoTitle.lowercased() == "undo apply print preset")
        // The print info now matches the document: nothing more to apply.
        _ = session.accessory.localizedSummaryItems()
        #expect(session.presetsApplied == 1)
        // A print info without the pane's keys is no preset.
        session.info.dictionary().removeAllObjects()
        session.loadPreset()
        #expect(session.presetsApplied == 1)
    }

    @Test func printingOffersTheWindowsSelection() async throws {
        let world = PrintWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: world.center.x - 50, y: world.center.y - 50, width: 100, height: 100)])
        world.window.selection.model.set(Selection(ids))
        world.features.runPrint = { _ in true }
        #expect(world.features.print())
        #expect(world.features.pane?.selection == Set(ids.map(\.node)))
        await world.document.settle()
    }
}
