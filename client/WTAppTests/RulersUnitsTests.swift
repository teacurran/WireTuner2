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

@Suite @MainActor struct RulerTests {
    @Test func labelledTicksFitAtEveryZoomInEveryUnit() {
        let feet = CustomUnit(id: OpID(counter: 1, replica: 1), name: "ft", amount: 12, base: .inches)
        let zooms = [0.06, 0.25, 1, 4, 32, 256]
        for unit in LengthUnit.standard + [.custom(feet.id)] {
            let units = Units(documentUnit: unit, customUnits: [feet])
            for zoom in zooms {
                let viewport = Viewport(scrollOrigin: Point(x: 7000, y: 7000), zoom: zoom, size: Size(width: 1200, height: 800))
                let mapping = RulerMapping(edge: .horizontal, viewport: viewport, zero: Point(x: 7686, y: 8388), units: units)
                let ruler = RulerStripView(orientation: .horizontal)
                ruler.frame = NSRect(x: 0, y: 0, width: 1200, height: 16)
                ruler.viewport = viewport
                ruler.frameOfReference = (units, Point(x: 7686, y: 8388))
                let ticks = ruler.ticks
                let labelled = ticks.filter { $0.level == 0 }
                #expect(!labelled.isEmpty, "\(unit) at \(zoom)")
                // Labels never overlap: each fits before the next labelled tick.
                for (a, b) in zip(labelled, labelled.dropFirst()) {
                    let width = Double(a.label?.count ?? 0) * RulerScale.characterWidth
                    #expect(b.position - a.position >= max(RulerScale.minimumLabelSpacing, width), "\(unit) at \(zoom)")
                }
                #expect(abs(mapping.position(of: mapping.value(at: 300)) - 300) < 1e-6)
            }
        }
        #expect(RulerScale.choose(unit: .points, viewPointsPerUnit: 0) { _ in 1 } == nil)
        #expect(RulerScale.choose(unit: .points, viewPointsPerUnit: 1e-9) { _ in 3 } == nil)
        #expect(RulerScale(step: 1, divisions: 2).ticks(from: 0, to: 10, offset: 0, slope: 0) { _ in "" }.isEmpty)
        #expect(RulerScale(step: 1e-9, divisions: 1).ticks(from: 0, to: 100, offset: 0, slope: 1) { _ in "" }.isEmpty, "too many ticks draws none")
        // Tick indices past 2^53, where adding 1 to a Double changes nothing: the loop still ends
        // (it used to append the same tick forever).
        let far = RulerScale(step: 1, divisions: 10).ticks(from: 0, to: 100, offset: 1e16, slope: 1e-3) { _ in "" }
        #expect(!far.isEmpty && far.count <= 10_000)
        // Picas subdivide into halves, inches into sixteenths when there is room.
        #expect(RulerScale.choose(unit: .inches, viewPointsPerUnit: 400) { _ in 3 } == RulerScale(step: 0.125, divisions: 8))
        #expect(RulerScale.divisions(for: .picas) == [12, 6, 2])
    }

    @Test func theRulersCountFromTheZeroPointUpwardAndTurnWithTheCanvas() {
        let units = Units()
        let viewport = Viewport(scrollOrigin: Point(x: 100, y: 200), zoom: 2, size: Size(width: 400, height: 300))
        let horizontal = RulerMapping(edge: .horizontal, viewport: viewport, zero: Point(x: 100, y: 300), units: units)
        #expect(horizontal.value(at: 0) == 0 && horizontal.value(at: 20) == 10)
        let vertical = RulerMapping(edge: .vertical, viewport: viewport, zero: Point(x: 100, y: 300), units: units)
        #expect(vertical.value(at: 0) == 100 && vertical.value(at: 20) == 90, "y grows upward")
        // A quarter turn: the top ruler measures the page's y.
        let turned = Viewport(scrollOrigin: Point(x: 100, y: 200), rotationDegrees: 90, zoom: 1, size: Size(width: 400, height: 300))
        let top = RulerMapping(edge: .horizontal, viewport: turned, zero: .zero, units: units)
        #expect(abs(top.slope) == 1)
        let left = RulerMapping(edge: .vertical, viewport: turned, zero: .zero, units: units)
        #expect(abs(left.slope) == 1)
    }

    @Test func theRulerDrawsTicksThePointerAndDraggedEdges() throws {
        let ruler = RulerStripView(orientation: .vertical)
        ruler.frame = NSRect(x: 0, y: 0, width: 16, height: 300)
        #expect(ruler.mapping == nil && ruler.ticks.isEmpty)
        let viewport = Viewport(scrollOrigin: .zero, zoom: 1, size: Size(width: 400, height: 300))
        ruler.viewport = viewport
        ruler.pointer = Point(x: 10, y: 20)
        ruler.trackedBounds = Rect(x: 5, y: 5, width: 50, height: 60)
        #expect(ruler.trackedPositions(viewport: viewport) == [20, 5, 65])
        let image = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        ruler.draw(ruler.bounds)
        let horizontal = RulerStripView(orientation: .horizontal)
        horizontal.frame = NSRect(x: 0, y: 0, width: 300, height: 16)
        horizontal.viewport = viewport
        horizontal.draw(horizontal.bounds)
        NSGraphicsContext.restoreGraphicsState()
        #expect(ruler.label(72) == "72" && horizontal.accessibilityIdentifier() == "ruler.horizontal")
    }

    @Test func theInfoBarReadsFromTheZeroPointInTheDocumentsUnits() async {
        let setup = SetupWindow()
        defer { setup.close() }
        let page = setup.page
        let frame = InfoReadout.frame(of: setup.document)
        #expect(frame.zero == Point(x: page.rect.minX, y: page.rect.maxY))
        let info = ToolInfo(position: Point(x: page.rect.minX + 72, y: page.rect.maxY - 36), delta: Vector(dx: 6, dy: -12))
        let fields = InfoReadout.fields(info, frame: InfoReadout.Frame(units: Units(documentUnit: .picas), zero: frame.zero))
        #expect(fields[0].value == "6p0, 3p0" && fields[1].value == "0p6, 1p0")
        #expect(InfoReadout.fields(info, frame: InfoReadout.Frame(units: Units(), zero: frame.zero))[0].value == "72, 36 pt")
        let model = InfoToolbarModel()
        model.document = setup.document
        model.info = info
        _ = InfoReadoutView(model: model).body
        // The dragged selection's edges are tracked on the rulers.
        #expect(setup.window.draggedSelectionBounds == nil)
    }
}

@Suite @MainActor struct SetupSheetTests {
    @Test func theGridSheetWritesWhatChanged() async {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        var performed: [any WTModel.Command] = []
        let model = GridSheetModel(document: document) { performed.append($0); document.perform($0) }
        #expect(model.sizeText == "12" && !model.relative)
        #expect(model.commit() && performed.isEmpty, "nothing changed, nothing written")
        model.sizeText = "1p6"
        model.relative = true
        #expect(model.commit())
        await document.settle()
        #expect(document.settings.grid == GridSettings(size: 18, relative: true) && document.undoTitle == "Undo Change grid")
        model.sizeText = "nonsense"
        #expect(!model.commit() && model.problem == GridSheetModel.invalidSize)
        let sheet = setup.window.presentGridSheet()
        #expect(sheet?.identifier?.rawValue == "sheet.grid")
        _ = GridSheet(model: model, close: {}).body
        if let sheet { setup.window.window?.endSheet(sheet) }
    }

    @Test func theGuidesSheetAddsEditsReleasesAndDeletes() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        await document.addPage().value
        let pages = document.pageList.pages
        let model = GuidesSheetModel(document: document, page: pages[0].id) { document.perform($0) }
        #expect(model.pagesText == "1" && model.rows.isEmpty)
        // Three guides from 1 in to 3 in up from the bottom, on both pages.
        model.axis = .horizontal
        model.placement = .count
        model.countText = "3"
        model.firstText = "1in"
        model.lastText = "3in"
        model.pagesText = "1-2"
        model.add()
        await document.settle()
        #expect(document.pageList.pages[0].guides.map(\.position) == [720.0, 648, 576])
        #expect(document.pageList.pages[1].guides.count == 3 && document.undoTitle == "Undo Add 6 guides")
        #expect(model.rows.map(\.position) == ["72 pt", "144 pt", "216 pt"] && model.rows[0].axisTitle == "Horizontal")
        // By increment, vertical.
        model.axis = .vertical
        model.placement = .increment
        model.incrementText = "100"
        model.firstText = "0"
        model.lastText = "250"
        model.pagesText = "1"
        model.add()
        await document.settle()
        #expect(document.pageList.pages[0].guides.filter { $0.axis == .vertical }.map(\.position) == [0, 100, 200])
        // Refused input says why.
        model.countText = "x"
        model.placement = .count
        model.add()
        #expect(model.problem == GuidesSheetModel.invalidPositions)
        model.countText = "1"
        model.pagesText = "9"
        model.add()
        #expect(model.problem == GuidesSheetModel.invalidPages)
        model.placement = .increment
        model.incrementText = "-1"
        #expect(model.positions() == nil)
        // Edit moves the selected rows; release and delete remove them.
        let first = model.rows[0]
        model.selection = [first.id]
        model.editText = "80"
        model.edit()
        await document.settle()
        #expect(document.pageList.pages[0].guides.contains { $0.axis == .horizontal && $0.position == 792 - 80 })
        model.selection = Set(model.rows.prefix(2).map(\.id))
        model.editText = "10"
        model.edit()
        await document.settle()
        #expect(document.undoTitle == "Undo Move 2 guides")
        model.editText = "?"
        model.edit()
        #expect(model.problem == GuidesSheetModel.invalidPositions)
        model.selection = [model.rows[0].id]
        model.release()
        await document.settle()
        #expect(document.undoTitle.hasPrefix("Undo Release"))
        model.selection = [model.rows[0].id]
        model.delete()
        await document.settle()
        #expect(document.undoTitle.hasPrefix("Undo Delete guide"))
        model.release()
        model.delete()
        // A master page's guides count from its bottom-left corner.
        _ = await document.perform(NewMasterPage(from: pages[0].id)).value
        let master = try #require(document.pageList.masters.first)
        let masterModel = GuidesSheetModel(document: document, page: master.id) { document.perform($0) }
        #expect(masterModel.zero == Point(x: 0, y: master.geometry.height) && masterModel.targetPages() == [master.id])
        #expect(masterModel.guides.isEmpty)
        let gone = GuidesSheetModel(document: document, page: OpID(counter: 99, replica: 9)) { document.perform($0) }
        #expect(gone.zero == .zero && gone.guides.isEmpty)
        _ = GuidesSheet(model: model, close: {}).body
        let sheet = setup.window.presentGuidesSheet()
        if let sheet { setup.window.window?.endSheet(sheet) }
    }

    @Test func theUnitsSheetDefinesUnitsThatFieldsRead() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        let model = UnitsSheetModel(document: document) { document.perform($0) }
        model.add()
        await document.settle()
        let unit = try #require(model.units.first)
        #expect(unit.name == "Unit 1" && document.undoTitle == "Undo Add unit")
        model.rename(unit, to: "ft")
        await document.settle()
        model.rename(model.units[0], to: "  ")
        let feet = model.units[0]
        model.redefine(feet, amount: 12, base: .inches)
        await document.settle()
        #expect(model.units[0].pointsPerUnit == 864 && document.undoTitle == "Undo Change unit")
        model.redefine(model.units[0], amount: -1)
        // Typing 2ft in a length field reads 1,728 pt.
        let format = FieldFormat<Double>.length(document.unitConverter)
        #expect(format.parse("2ft", nil) == 1728)
        #expect(format.parse("50%", 20) == 10, "percentages go through Measure")
        #expect(format.format(72) == "72" && format.format(nil) == "")
        #expect(format.step?(72, 1) == 73)
        // A duplicate name is marked; the smaller id wins the suffix.
        model.add()
        await document.settle()
        model.rename(model.units[1], to: "ft")
        await document.settle()
        #expect(!model.isDuplicate(model.units[0]) && model.isDuplicate(model.units[1]))
        // Removing the document's unit switches it to points in the same change.
        _ = await document.perform(SetUnits(.custom(feet.id))).value
        model.selection = feet.id
        model.remove()
        await document.settle()
        #expect(document.units == .points && document.undoTitle == "Undo Remove unit")
        model.selection = model.units[0].id
        model.remove()
        await document.settle()
        #expect(model.units.isEmpty)
        model.remove()
        _ = UnitsSheet(model: model, close: {}).body
        _ = UnitRow(model: model, unit: feet).body
        let sheet = setup.window.presentUnitsSheet()
        if let sheet { setup.window.window?.endSheet(sheet) }
    }

    @Test func lengthFieldsTakeTheDocumentsUnits() async {
        let units = Units(documentUnit: .kyus)
        _ = MeasureField(title: "W", value: 10, units: units, identifier: "w") { _ in }.body
        _ = MeasureField(title: "W", value: 10, unit: .points, identifier: "w") { _ in }.environment(\.documentUnits, units)
        let selection = ActiveSelection(document: .memory(title: "Units"))
        _ = DocumentUnitsScope(selection: selection) { Text("x") }.body
        let kyus = FieldFormat<Double>.length(units).parse("4", nil) ?? 0
        #expect(abs(kyus - 4 * 18 / 25.4) < 1e-9)
        _ = TransformPanelBody(selection: selection).body
    }
}
