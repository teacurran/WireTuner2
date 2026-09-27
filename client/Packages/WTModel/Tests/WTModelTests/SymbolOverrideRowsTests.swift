import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// LIB-027: the Overrides section's rows, values and editors' commands.
@Suite struct SymbolOverrideRowsTests {
    typealias Fixture = SymbolOverrideTests.Fixture

    @Test func rowsListEveryOverridablePropertyInStackingOrder() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let rows = Symbols.overrideRows(of: f.symbol, in: a.state)
        #expect(rows.map(\.property) == [.fill, .stroke, .hidden, .text, .hidden, .hidden, .image])
        #expect(rows.map(\.master) == [f.rect, f.rect, f.rect, f.text, f.text, f.image, f.image])
        #expect(rows[3].name == "Text: Label" && rows[0].name == "Rect" && rows[5].name == "Image" && rows.allSatisfy { $0.depth == 0 })
        try a.perform(SetNameOrNote([f.rect], .name, "Badge"))
        #expect(Symbols.partTitle(f.rect, in: a.state) == "Badge")
        // Values: the master's until overridden.
        let text = rows[3], fill = rows[0], visible = rows[2], image = rows[6]
        #expect(Symbols.overrideValue(text, of: f.instance, in: a.state) == (.text("Label"), false))
        #expect(Symbols.overrideValue(visible, of: f.instance, in: a.state) == (.visible(true), false))
        #expect(Symbols.overrideValue(image, of: f.instance, in: a.state) == (.image(nil), false))
        guard case (.color(let blue?), false) = Symbols.overrideValue(fill, of: f.instance, in: a.state) else { Issue.record("no colour"); return }
        #expect(blue == Appearances.basicFill(red: 0, green: 0, blue: 1).settings.basic.color)
        try a.perform(SetOverride([f.instance], master: f.rect, value: .hidden(true), in: a.state))
        #expect(Symbols.overrideValue(visible, of: f.instance, in: a.state) == (.visible(false), true))
        try a.perform(SetOverride([f.instance], master: f.rect, value: .stroke(SymbolFixture.red()), in: a.state))
        #expect(Symbols.overrideValue(rows[1], of: f.instance, in: a.state) == (.color(SymbolFixture.red()), true))
        try a.perform(SetOverride([f.instance], master: f.rect, value: .fill(SymbolFixture.red()), in: a.state))
        #expect(Symbols.overrideValue(fill, of: f.instance, in: a.state) == (.color(SymbolFixture.red()), true))
        // Names: a long text is cut; something that is not a node is a part.
        let long = try TextFixture.block(&a, "Extraordinarily unbelievable celebrations tonight", at: .zero)
        #expect(Symbols.partTitle(long, in: a.state) == "Text: Extraordinarily unbeliev…")
        #expect(Symbols.partTitle(OpID(counter: 999, replica: 9), in: a.state) == "Part")
        #expect(Symbols.overrideValue(text, of: long, in: a.state) == (.text(""), false), "not an instance of the symbol")
    }

    @Test func nestedInstancesAndGroupsAreWalkedToOneLevel() throws {
        var a = Replica(0xA)
        let (inner, _, _) = try SymbolFixture.converted(on: &a)
        let first = try a.perform(SymbolFixture.rect(x: 100))!.createdObjects[0]
        let second = try a.perform(SymbolFixture.rect(x: 120))!.createdObjects[0]
        let group = try #require(try a.perform(GroupObjects([first, second]))?.createdObjects.first)
        let nested = try a.perform(PlaceInstance(inner, at: Point(x: 300, y: 0)))!.createdObjects[0]
        let outer = try #require(try a.perform(ConvertToSymbol([group, nested]))?.createdNodes.first)
        let rows = Symbols.overrideRows(of: outer, in: a.state)
        #expect(rows.first?.master == group && rows.first?.property == .hidden && rows.first?.depth == 0)
        #expect(rows.contains { $0.master == first && $0.depth == 1 } && rows.contains { $0.master == nested && $0.property == .hidden })
        #expect(!rows.contains { Symbols.artworkNodes(of: inner, in: a.state).contains($0.master) }, "not inside the nested instance")
    }

    @Test func thePanelsTextEditorTypesOverTheWholeTextAndEmptyResets() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let second = try a.perform(PlaceInstance(f.symbol, at: Point(x: 300, y: 0)))!.createdObjects[0]
        let change = try #require(try a.perform(OverrideTextValue([f.instance, second], master: f.text, text: "Buy now")))
        #expect(change.label == "Override text")
        #expect(Symbols.textNode(f.text, in: f.instance, state: a.state)?.string == "Buy now")
        #expect(Symbols.textNode(f.text, in: second, state: a.state)?.string == "Buy now")
        #expect(try a.perform(OverrideTextValue([f.instance], master: f.text, text: "Buy now")) == nil, "nothing changes")
        let reset = try #require(try a.perform(OverrideTextValue([f.instance, second], master: f.text, text: "")))
        #expect(reset.label == "Reset override" && Symbols.liveOverrides(of: f.instance, in: a.state).isEmpty)
        #expect(throws: SymbolError.notOverridable(f.symbol)) { try a.perform(OverrideTextValue([f.instance], master: f.symbol, text: "x")) }
    }

    @Test func chooseMakesAnAssetForThePictureOnce() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let blob = ImportedBlob(data: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), uti: "public.png")
        let change = try #require(try a.perform(OverrideImage([f.instance], master: f.image, blob: blob, name: "photo.png")))
        #expect(change.label == "Override image")
        let asset = try #require(change.createdNodes.first)
        #expect(a.state.props(asset).asset.sha256 == blob.sha256)
        let row = try #require(Symbols.overrideRows(of: f.symbol, in: a.state).first { $0.property == .image })
        #expect(Symbols.overrideValue(row, of: f.instance, in: a.state) == (.image(asset), true))
        // The same bytes again: the asset is reused.
        let again = try #require(try a.perform(OverrideImage([f.instance], master: f.image, blob: blob, name: "photo.png")))
        #expect(again.createdNodes.isEmpty)
        #expect(throws: SymbolError.notOverridable(f.text)) { try a.perform(OverrideImage([f.instance], master: f.text, blob: blob, name: "x")) }
    }
}
