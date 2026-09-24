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

/// DATA-017 and DATA-018's WTApp halves: the Object panel's *Data* and *Barcode* sections and
/// *Insert Barcode…*, each control one labelled change.
@Suite(.serialized) @MainActor struct DataObjectSectionTests {
    static func panel(_ document: DocumentHandle, _ ids: [OpID]) -> ObjectPanelModel {
        ObjectPanelModel(document: document, selection: Selection(ids.map(SelectionID.init)))
    }

    @Test func theDataSectionBindsAndUnbindsTheSelection() async throws {
        let world = DataWorld()
        defer { world.close() }
        let rect = await world.document.addRectangles([Rect(x: 20, y: 20, width: 40, height: 40)])[0].opID
        #expect(DataSectionModel(Self.panel(world.document, [rect])) == nil, "no fields, nothing bound: no section")
        #expect(DataSectionModel(Self.panel(world.document, [])) == nil)
        let ids = await world.fields(["vip", "site", "name"], kinds: [.boolean, .link, .text])
        let model = try #require(DataSectionModel(Self.panel(world.document, [rect])))
        #expect(model.kinds == [.visibility, .link] && model.kind == nil && model.field == nil && !model.isMissing)
        #expect(model.fields(for: .visibility).map(\.id) == [ids[0]] && model.fields(for: .text).count == 3)
        #expect(InspectorRegistry.standard.views(for: Self.panel(world.document, [rect])).map(\.id).contains("data"))
        Render.view(DataSectionView(model: model))
        DataSectionView.kind(model).wrappedValue = "Visibility"
        await world.document.settle()
        let bound = try #require(DataSectionModel(Self.panel(world.document, [rect])))
        #expect(bound.kind == .visibility && bound.field == ids[0] && world.document.undoTitle == "Undo Bind to field")
        #expect(DataSectionView.kind(bound).wrappedValue == "Visibility" && DataSectionView.field(bound, .visibility).wrappedValue == ids[0])
        Render.view(DataSectionView(model: bound))
        // Link: the first link field; the current field is kept when it suits.
        bound.bind(.link)
        await world.document.settle()
        let linked = try #require(DataSectionModel(Self.panel(world.document, [rect])))
        #expect(linked.field == ids[1])
        linked.bind(.link)
        DataSectionView.field(linked, .link).wrappedValue = ids[1]
        await world.document.settle()
        // A kind no field suits does nothing; None unbinds.
        _ = await world.document.perform(DeleteField(ids[1])).value
        await world.document.settle()
        let missing = try #require(DataSectionModel(Self.panel(world.document, [rect])))
        #expect(missing.isMissing && missing.kind == .link)
        Render.view(DataSectionView(model: missing))
        missing.bind(.link)
        DataSectionView.kind(missing).wrappedValue = DataSectionView.none
        await world.document.settle()
        #expect(DataSectionModel(Self.panel(world.document, [rect]))?.kind == nil && world.document.undoTitle == "Undo Unbind")
        DataSectionModel(Self.panel(world.document, [rect]))?.bind(nil)
        // Text blocks take a text binding; mixed selections show what they share.
        let text = try #require(await world.document.addText("x", at: Point(x: 200, y: 200)))
        let both = try #require(DataSectionModel(Self.panel(world.document, [rect, text])))
        #expect(both.kinds == [.visibility, .link])
        let textOnly = try #require(DataSectionModel(Self.panel(world.document, [text])))
        #expect(textOnly.kinds.contains(.text))
        textOnly.bind(.text)
        await world.document.settle()
        let mixed = try #require(DataSectionModel(Self.panel(world.document, [rect, text])))
        #expect(mixed.kind == nil && mixed.field == nil)
        #expect(DataBindingKind.allCases.map(DataSectionModel.title) == ["Image", "Visibility", "Link", "Text"])
    }

    @Test func theBarcodeSectionEditsKindContentLevelAndText() async throws {
        let world = DataWorld()
        defer { world.close() }
        let ids = await world.fields(["code"])
        let rect = await world.document.addRectangles([Rect(x: 20, y: 20, width: 40, height: 40)])[0].opID
        #expect(BarcodeSectionModel(Self.panel(world.document, [rect])) == nil)
        let insert = InsertBarcodeModel(fields: [])
        #expect(!insert.usesField && insert.field == nil && !insert.canInsert)
        insert.text = "HELLO"
        #expect(insert.canInsert)
        let barcode = try #require(await world.document.perform(insert.command(center: Point(x: 100, y: 100), layer: nil)).value?.createdObjects.first)
        await world.document.settle()
        let model = try #require(BarcodeSectionModel(Self.panel(world.document, [barcode])))
        #expect(model.symbology == .qr && model.value == "HELLO" && model.errorCorrection == .medium && model.quietZone == 4 && !model.showText && !model.isBound)
        #expect(InspectorRegistry.standard.views(for: Self.panel(world.document, [barcode])).map(\.id).contains("barcode"))
        Render.view(BarcodeSectionView(model: model))
        BarcodeSectionView.level(model).wrappedValue = .high
        BarcodeSectionView.level(model).wrappedValue = nil
        BarcodeSectionView.value(model)("WORLD")
        BarcodeSectionView.quietZone(model)(6)
        BarcodeSectionView.quietZone(model)(-1)
        await world.document.settle()
        let edited = try #require(BarcodeSectionModel(Self.panel(world.document, [barcode])))
        #expect(edited.errorCorrection == .high && edited.value == "WORLD" && edited.quietZone == 6 && world.document.undoTitle == "Undo Change barcode")
        #expect(BarcodeSectionView.level(edited).wrappedValue == .high)
        BarcodeSectionView.symbology(edited).wrappedValue = .code128
        BarcodeSectionView.symbology(edited).wrappedValue = nil
        await world.document.settle()
        let code128 = try #require(BarcodeSectionModel(Self.panel(world.document, [barcode])))
        #expect(code128.symbology == .code128 && BarcodeSectionView.symbology(code128).wrappedValue == .code128)
        Render.view(BarcodeSectionView(model: code128))
        BarcodeSectionView.showText(code128).wrappedValue = true
        await world.document.settle()
        let shown = try #require(BarcodeSectionModel(Self.panel(world.document, [barcode])))
        #expect(shown.showText && BarcodeSectionView.showText(shown).wrappedValue)
        // Content: a field binds, text unbinds.
        BarcodeSectionView.content(shown).wrappedValue = true
        await world.document.settle()
        let bound = try #require(BarcodeSectionModel(Self.panel(world.document, [barcode])))
        #expect(bound.isBound && bound.field == ids[0] && BarcodeSectionView.content(bound).wrappedValue && BarcodeSectionView.field(bound).wrappedValue == ids[0])
        Render.view(BarcodeSectionView(model: bound))
        BarcodeSectionView.field(bound).wrappedValue = ids[0]
        BarcodeSectionView.content(bound).wrappedValue = false
        await world.document.settle()
        let unbound = try #require(BarcodeSectionModel(Self.panel(world.document, [barcode])))
        #expect(!unbound.isBound && world.document.undoTitle == "Undo Unbind")
        unbound.useText()
        // Two barcodes that differ show mixed values; with no fields, Field does nothing.
        let second = try #require(await world.document.perform(InsertBarcode("X", symbology: .qr)).value?.createdObjects.first)
        await world.document.settle()
        let both = try #require(BarcodeSectionModel(Self.panel(world.document, [barcode, second])))
        #expect(both.symbology == nil && both.value == nil && !both.showText)
        _ = await world.document.perform(DeleteField(ids[0])).value
        await world.document.settle()
        let fieldless = try #require(BarcodeSectionModel(Self.panel(world.document, [second])))
        fieldless.setContent(field: nil)
        #expect(BarcodeSectionModel.levels.count == 4)
    }

    @Test func insertBarcodePlacesABoundOrFixedCodeAtTheCentreOfTheView() async throws {
        let world = DataWorld()
        defer { world.close() }
        let ids = await world.fields(["ticket"])
        let model = try #require(world.features.presentInsertBarcode())
        #expect(world.window.window?.attachedSheet?.identifier?.rawValue == "sheet.insertBarcode")
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        #expect(model.usesField && model.field == ids[0] && model.canInsert)
        Render.view(InsertBarcodeSheet(model: model, insert: {}, close: {}))
        model.symbology = .code128
        let command = model.command(center: Point(x: 500, y: 500), layer: nil)
        #expect(command.label == "Insert Barcode" && command.field == ids[0] && command.insert.symbology == .code128)
        let node = try #require(await world.document.perform(command).value?.createdObjects.first)
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Insert Barcode")
        let binding = try #require(DataModel(world.document.state).binding(of: node, in: world.document.state))
        #expect(binding.kind == .text && binding.field == ids[0])
        model.usesField = false
        Render.view(InsertBarcodeSheet(model: model, insert: {}, close: {}))
        #expect(!model.canInsert)
        model.text = "ABC"
        let fixed = model.command(center: .zero, layer: nil)
        #expect(fixed.field == nil && fixed.insert.value == "ABC")
        // The sheet's Insert places it through the window.
        let sheetModel = try #require(world.features.presentInsertBarcode())
        let sheet = try #require(world.window.window?.attachedSheet)
        let host = try #require(sheet.contentViewController as? NSHostingController<InsertBarcodeSheet>)
        host.rootView.insert()
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Insert Barcode" && sheetModel.canInsert)
        world.window.window?.endSheet(sheet)
    }
}
