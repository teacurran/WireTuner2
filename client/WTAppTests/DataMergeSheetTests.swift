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

/// DATA-017, DATA-020 and DATA-021's WTApp halves: the merge sheet to pages (one undo step, cancel
/// as undo, shrink-to-fit decided on the main actor), to PDF (nothing written to the document) and
/// to the printer (`knowsPageRange`, `rectForPage`), and the report.
@Suite(.serialized) @MainActor struct DataMergeSheetTests {
    static func labels(_ world: DataWorld) async throws -> (name: OpID, text: OpID) {
        let ids = await world.fields(["person", "day"], kinds: [.text, .date])
        let page = world.document.activePage.rect
        let text = try #require(await world.placeholderText("Hello ", field: ids[0], at: Point(x: page.minX + 72, y: page.minY + 72)))
        _ = await world.document.perform(InsertPlaceholder(node: text, at: .end, field: ids[1])).value
        await world.paste("person\tday\nAnn\t2026-09-21\nBo\tnot a date\nCy\t2026-01-01\n")
        return (ids[0], text)
    }

    @Test func mergeToPagesIsOneUndoStepWithAReport() async throws {
        let world = DataWorld()
        defer { world.close() }
        let (_, text) = try await Self.labels(world)
        let model = try #require(world.features.presentMerge())
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        #expect(model.target == .pages && model.recordCount == 3 && model.summary == "3 records on 3 pages" && model.problem == nil)
        #expect(model.warnings.isEmpty && model.templates == [world.document.activePage.id])
        Render.view(MergeSheet(model: model, close: {}))
        model.recordsText = "x"
        #expect(model.range == nil && model.problem != nil && model.summary.hasPrefix("Type records"))
        await model.merge()
        #expect(model.message == model.problem)
        model.recordsText = "9-"
        #expect(model.problem == "There are no records to merge.")
        model.recordsText = "1-2"
        #expect(model.summary == "2 records on 2 pages")
        let pages = world.document.pageList.pages.count
        await model.merge()
        await world.document.settle()
        #expect(world.document.pageList.pages.count == pages + 2 && world.document.undoTitle == "Undo Merge 2 records to pages")
        #expect(model.message == "Merged 2 records into 2 pages." && model.progress == nil)
        #expect(model.report?.map(\.record) == [2] && model.describe(model.report![0]).hasPrefix("Record 2 (day): “not a date”"))
        Render.view(MergeSheet(model: model, close: {}))
        MergeSheet.show(model.report![0], model)()
        #expect(world.session.preview.showing && world.session.currentIndex == 1)
        _ = await world.document.undo().value
        #expect(world.document.pageList.pages.count == pages)
        // Cancelling undoes what was made.
        model.recordsText = ""
        let cancelling = MergeSheetModel(window: world.window, session: world.session)
        cancelling.cancel()
        await cancelling.merge()
        await world.document.settle()
        #expect(world.document.pageList.pages.count == pages && cancelling.message == "The merge was cancelled; no pages were added.")
        // Shrink to fit is decided per record and text block before the command runs.
        model.shrinkToFit = true
        model.minimumSize = 4
        let fitted = model.fitted(world.session.records, indices: [0, 1, 2])
        #expect(fitted.texts.keys.contains(MergeFitKey(record: 0, node: text)) && fitted.texts.count == 3)
        model.shrinkToFit = false
        #expect(model.fitted(world.session.records, indices: [0]).texts.isEmpty)
        // A grid needs selected objects.
        model.usesGrid = true
        #expect(model.problem == "Select the objects that make one label for the grid.")
        world.window.selection.model.set(Selection([SelectionID(text)]))
        model.columns = 2
        model.rows = 1
        model.acrossFirst = false
        #expect(model.layout == .grid(columns: 2, rows: 1, gap: 4, margins: 36, order: .downThenAcross) && model.summary == "3 records on 2 pages")
        Render.view(MergeSheet(model: model, close: {}))
        model.shrinkToFit = true
        await model.merge()
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Merge 3 records to pages")
        MergeSheet.merge(model)()
        // A merge with no model yet open does nothing.
        let other = SetupWindow()
        defer { other.close() }
        let empty = MergeSheetModel(window: other.window, session: world.session)
        empty.target = .pages
        other.window.documentHandle.close()
        await empty.merge()
    }

    @Test func mergeToPDFWritesFilesAndNothingToTheDocument() async throws {
        let world = DataWorld()
        defer { world.close() }
        _ = try await Self.labels(world)
        let model = MergeSheetModel(window: world.window, session: world.session)
        let directory = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.chooseDirectory = { directory }
        model.target = .pdf
        Render.view(MergeSheet(model: model, close: {}))
        let changes = world.document.changeCount
        await model.merge()
        #expect(model.written.count == 1 && model.message == "Wrote 1 file." && world.document.changeCount == changes)
        #expect(PDFDocument(url: model.written[0])?.pageCount == 3)
        model.oneFile = false
        model.pattern = "label-{person}"
        await model.merge()
        #expect(model.written.map(\.lastPathComponent).sorted() == ["label-Ann.pdf", "label-Bo.pdf", "label-Cy.pdf"])
        #expect(model.report?.isEmpty == false)
        // Cancelled after the first record; a folder that cannot be written; no folder chosen.
        model.recordsText = "1-3"
        let partial = MergeSheetModel(window: world.window, session: world.session)
        partial.target = .pdf
        partial.oneFile = false
        partial.pattern = "p-{person}"
        partial.chooseDirectory = { directory }
        partial.cancel()
        await partial.merge()
        model.chooseDirectory = { URL(filePath: "/no/such/folder") }
        await model.merge()
        #expect(model.message?.hasPrefix("The PDF could not be written") == true)
        model.chooseDirectory = { nil }
        await model.merge()
    }

    @Test func aScriptsMergeToPDFWritesTheSheetsFile() async throws {
        // DATA-012: wt.records.merge({ to: "pdf" }) is the merge sheet's merge -- the same file
        // but the PDF writer's timestamps.
        let world = DataWorld()
        defer { world.close() }
        _ = try await Self.labels(world)
        let sheetFolder = TestEnvironment.temporaryDirectory(), scriptFolder = TestEnvironment.temporaryDirectory()
        for folder in [sheetFolder, scriptFolder] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let sheet = MergeSheetModel(window: world.window, session: world.session)
        sheet.target = .pdf
        sheet.chooseDirectory = { sheetFolder }
        await sheet.merge()
        let ui = ScriptUI(window: world.window, data: world.features)
        ui.prepareMerge = { $0.chooseDirectory = { scriptFolder } }
        #expect(await ui.handle("merge", [["to": "pdf"]]) as? String == "Wrote 1 file.")
        let written = try FileManager.default.contentsOfDirectory(at: scriptFolder, includingPropertiesForKeys: nil)
        #expect(written.map(\.lastPathComponent) == sheet.written.map(\.lastPathComponent))
        let fromSheet = try Data(contentsOf: try #require(sheet.written.first)), fromScript = try Data(contentsOf: try #require(written.first))
        #expect(ScriptingSurfaces.ScriptingExportTests.masked(fromSheet) == ScriptingSurfaces.ScriptingExportTests.masked(fromScript))
    }

    @Test func printMergeHandsThePrintDialogTheMergedPages() async throws {
        let world = DataWorld()
        defer { world.close() }
        _ = try await Self.labels(world)
        let model = MergeSheetModel(window: world.window, session: world.session)
        model.target = .printer
        var operations: [NSPrintOperation] = []
        model.runPrint = { operations.append($0) }
        await model.merge()
        #expect(operations.count == 1 && model.message == "Sent 3 pages to the printer." && operations[0].jobTitle == "Setup merge")
        let view = try #require(operations[0].view as? MergePrintView)
        var range = NSRange()
        #expect(view.knowsPageRange(&range) && range == NSRange(location: 1, length: 3))
        let page = world.document.activePage.rect
        #expect(view.rectForPage(2) == NSRect(x: 0, y: page.height, width: page.width, height: page.height) && view.isFlipped)
        #expect(view.rectForPage(0).minY == 0 && view.pdf(0) != nil)
        let image = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(page.width), pixelsHigh: Int(page.height), bitsPerSample: 8, samplesPerPixel: 4,
                                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        view.draw(view.rectForPage(1))
        NSGraphicsContext.restoreGraphicsState()
        view.draw(view.rectForPage(1))
        #expect(MergePrintView.printInfo().topMargin == 0)
        // A template that is not a page fails with the reason.
        world.window.selection.model.set(Selection([]))
        let broken = MergeSheetModel(window: world.window, session: world.session)
        broken.target = .printer
        world.document.selectPages([OpID(counter: 999, replica: 999)])
        #expect(broken.templates == [world.document.activePage.id])
        #expect(throws: Never.self) { _ = try broken.output() }
        // wt.records.merge from a script runs the same merge.
        let ui = ScriptUI(window: world.window, data: world.features)
        #expect(await ui.handle("merge", [["to": "pages", "records": "1"]]) as? String == "Merged 1 record into 1 page.")
        ui.prepareMerge = { merge in
            merge.runPrint = { _ in }
            merge.chooseDirectory = { nil }
        }
        #expect(await ui.handle("merge", [["to": "printer"]]) is String)
        #expect(await ui.handle("merge", [["to": "pdf", "fileName": "x-{name}"]]) is NSNull)
        let noWindow = ScriptUI(window: nil, data: nil)
        #expect(await noWindow.handle("merge", []) is NSNull)
    }
}
