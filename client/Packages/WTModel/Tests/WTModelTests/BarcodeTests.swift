import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// DATA-018's model half: the barcode node read, drawn, edited and converted.
@Suite struct BarcodeTests {
    @Test func insertReadAndDraw() throws {
        var a = Replica(0xA)
        let insert = InsertBarcode("https://example.com", at: Point(x: 10, y: 20))
        #expect(insert.label == "Insert Barcode")
        let node = try a.perform(insert)!.createdObjects[0]
        let props = a.state.props(node).barcode
        #expect(a.state.nodeKind(node) == .barcode && props.symbology == .qr && props.qrErrorCorrection == .m)
        let spec = Barcodes.spec(props, appearance: Appearances.resolve(props.appearance))
        #expect(spec.symbology == .qr && spec.errorCorrection == .medium && spec.quietZone == nil && spec.paint == .solid(Color(red: 0, green: 0, blue: 0)))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        let object = try #require(scene.object(node))
        guard case .group(let group) = object.item else { Issue.record("a barcode draws as a group"); return }
        #expect(group.atomic && object.kind == .barcode)
        let bounds = try #require(Objects.bounds(of: node, in: a.state))
        #expect(bounds.minX == 10 && bounds.minY == 20 && bounds.width == bounds.height)
        // Unset fields read as their defaults; the first fill paints the bars.
        var other = Wiretuner_Doc_V1_BarcodeProps()
        other.symbology = .code128
        other.qrErrorCorrection = .h
        other.quietZone = 3
        other.showText = true
        let code = Barcodes.spec(other, appearance: Appearance([.stroke(StrokePaint(paint: .solid(.white))), .fill(FillPaint(paint: .solid(.white)))]))
        #expect(code.symbology == .code128 && code.errorCorrection == .high && code.quietZone == 3 && code.showText && code.paint == .solid(.white))
        #expect(Barcodes.spec(Wiretuner_Doc_V1_BarcodeProps()).paint == .solid(.black))
        #expect(throws: ObjectEditError.invalidValue("point")) { try a.perform(InsertBarcode("x", at: Point(x: .infinity, y: 0))) }
        let origin = try a.perform(InsertBarcode("12345", symbology: .code128))!.createdObjects[0]
        #expect(a.state.props(origin).barcode.common.hasTransform == false)
    }

    @Test func fieldsAndConcurrentEdits() throws {
        var pair = Pair()
        let node = try pair.a.perform(InsertBarcode("A"))!.createdObjects[0]
        pair.sync()
        let change = try #require(try pair.a.perform(SetBarcodeFields([node], .init(value: "B"))))
        #expect(change.label == "Change barcode" && SetBarcodeFields([node, node], .init()).label == "Change 2 barcodes")
        try pair.b.perform(SetBarcodeFields([node], .init(symbology: .code128)))
        pair.sync()
        for replica in [pair.a, pair.b] {
            let props = replica.state.props(node).barcode
            #expect(props.value == "B" && props.symbology == .code128, "concurrent value and symbology edits both survive")
        }
        try pair.a.perform(SetBarcodeFields([node], .init(errorCorrection: .quartile, quietZone: 2, showText: true)))
        var props = pair.a.state.props(node).barcode
        #expect(props.qrErrorCorrection == .q && props.quietZone == 2 && props.showText)
        try pair.a.perform(SetBarcodeFields([node], .init(symbology: .qr, errorCorrection: .low)))
        props = pair.a.state.props(node).barcode
        #expect(props.symbology == .qr && props.qrErrorCorrection == .l)
        try pair.a.perform(SetBarcodeFields([node], .init(errorCorrection: .high)))
        #expect(pair.a.state.props(node).barcode.qrErrorCorrection == .h)
        #expect(try pair.a.perform(SetBarcodeFields([node], .init())) == nil)
        #expect(throws: ObjectEditError.invalidValue("quietZone")) { try pair.a.perform(SetBarcodeFields([node], .init(quietZone: -1))) }
        pair.a.undo()
        #expect(pair.a.state.props(node).barcode.qrErrorCorrection == .l)
    }

    @Test func convertToPathsKeepsTheBarsAndTheirPlace() throws {
        var a = Replica(0xA)
        let node = try a.perform(InsertBarcode("12345", symbology: .code128, at: Point(x: 5, y: 5)))!.createdObjects[0]
        let before = try #require(Objects.bounds(of: node, in: a.state))
        let change = try #require(try a.perform(ConvertBarcodesToPaths([node])))
        #expect(change.label == "Convert to Paths" && !a.state.isLive(node))
        let path = change.createdNodes[0]
        #expect(a.state.nodeKind(path) == .path)
        let converted = try #require(Objects.bounds(of: path, in: a.state))
        #expect(before.contains(converted) && converted.width > 50)
        #expect(a.state.props(path).path.appearance.fills.count == 1)
        a.undo()
        #expect(a.state.isLive(node) && !a.state.isLive(path))
        // An unencodable barcode is left alone.
        let bad = try a.perform(InsertBarcode("\u{1F600}", symbology: .code128))!.createdObjects[0]
        #expect(try a.perform(ConvertBarcodesToPaths([bad])) == nil)
        #expect(Objects.bounds(of: bad, in: a.state) == nil)
        var builder = DocumentDisplayListBuilder(canvas: "c")
        #expect(builder.rebuild(a.state).object(bad) != nil, "it draws the placeholder")
    }
}
