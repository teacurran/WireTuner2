import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// LIB-025/026: instances draw their text overrides -- laid out by the scene's `TextSceneLayout`
/// from the override's characters, marks and paragraph registers in the master block's geometry
/// -- and the text-editing hooks the Text tool uses inside an instance (library.adoc, "Override
/// resolution", "Text tool inside an instance").
@Suite @MainActor struct SymbolTextOverrideSceneTests {
    /// A symbol of a group (moved) holding a rectangle and a two-paragraph text block, its first
    /// paragraph centred and its first three characters 20 pt; the instance made in place and a
    /// second one placed to the right.
    struct Fixture {
        var symbol: OpID, instance: OpID, other: OpID
        var text: OpID, rect: OpID, group: OpID
        /// The text block's pasteboard transform before it became master artwork.
        var placed: WTGeometry.AffineTransform

        init(on a: inout Replica) throws {
            rect = try a.perform(SymbolFixture.rect(x: 0))!.createdObjects[0]
            text = try TextFixture.block(&a, "Label\nTwo", at: Point(x: 0, y: 30))
            let node = text
            try a.perform(SetParagraph(node: node, from: TextFixture.at(a, node, 0), to: TextFixture.at(a, node, 1), props: .with { $0.alignment = .center },
                                       fields: [[1]]))
            try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, 0), to: TextFixture.at(a, node, 3), value: TextFixture.size(20)))
            group = try #require(try a.perform(GroupObjects([rect, text]))?.createdObjects.first)
            try a.perform(SetTransforms([(group, .translation(x: 5, y: 7))]))
            placed = Objects.pasteboardTransform(of: text, in: a.state)
            let change = try #require(try a.perform(ConvertToSymbol([group])))
            symbol = change.createdNodes[0]
            instance = change.createdNodes[1]
            other = try #require(try a.perform(PlaceInstance(symbol, at: Point(x: 300, y: 0)))?.createdObjects.first)
        }
    }

    static func builder(_ state: EngineState, fonts: DocumentFontIndex) -> DocumentDisplayListBuilder {
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.textLayout = TextSceneLayout(engine: fonts.layoutEngine)
        builder.rebuild(state)
        return builder
    }

    /// Every text run drawn in `item`, depth first.
    static func runs(_ item: DisplayItem?) -> [TextRunItem] {
        switch item {
        case .text(let run)?: [run]
        case .group(let group)?: group.children.flatMap { runs($0) }
        default: []
        }
    }

    static func words(_ builder: DocumentDisplayListBuilder, _ node: OpID) -> String {
        runs(builder.scene.object(node)?.item).map(\.text).joined()
    }

    /// The first run's baseline origin in pasteboard space.
    static func start(_ builder: DocumentDisplayListBuilder, _ node: OpID) -> Point? {
        runs(builder.scene.object(node)?.item).first.map { $0.transform.apply($0.origin) }
    }

    static func close(_ a: Point?, _ b: Point?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6
    }

    @Test func anInstanceDrawsItsTextOverrideWhereTheMastersWordsWere() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let fonts = DocumentFontIndex(state: a.state)
        var builder = Self.builder(a.state, fonts: fonts)
        #expect(Self.words(builder, f.instance).contains("Label") && Self.words(builder, f.instance).contains("Two"))
        let before = Self.start(builder, f.instance)
        let width = try #require(builder.scene.object(f.instance)?.bounds).width
        let change = try #require(try a.perform(OverrideText(f.instance, master: f.text, edit: .insert(" and more words", at: 5))))
        let (_, summary) = builder.apply(change, state: a.state, origin: .local)
        #expect(summary.touchedNodes.contains(NodeID(f.instance)) && !summary.touchedNodes.contains(NodeID(f.other)), "an override edit repaints its instance only")
        #expect(Self.words(builder, f.instance).contains("Label and more words"))
        #expect(!Self.words(builder, f.other).contains("more"), "the other instance keeps the master's words")
        #expect(Self.close(Self.start(builder, f.instance), before), "laid out in the master block's place")
        #expect(try #require(builder.scene.object(f.instance)?.bounds).width > width)
        // The same drawing a full rebuild gives.
        let fresh = Self.builder(a.state, fonts: fonts)
        #expect(fresh.scene.object(f.instance)?.item == builder.scene.object(f.instance)?.item)
    }

    @Test func anOverrideHoldingTheMastersTextDrawsExactlyAsTheMaster() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let fonts = DocumentFontIndex(state: a.state)
        let before = Self.builder(a.state, fonts: fonts).scene.object(f.instance)?.item
        try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("x", at: 0)))
        try a.perform(OverrideText(f.instance, master: f.text, edit: .delete(0..<1)))
        #expect(Symbols.resolvedArtwork(of: f.instance, in: a.state)?.texts[f.text]?.isOverride == true)
        // The copy kept the marks (20 pt) and the paragraph registers (centred first paragraph).
        let override = try #require(Symbols.textNode(f.text, in: f.instance, state: a.state))
        #expect(override.id == f.text && override.string == "Label\nTwo")
        #expect(override.paragraphs[0].props.alignment == .center && override.values(at: 0).contains { $0.size == 20 })
        #expect(Self.builder(a.state, fonts: fonts).scene.object(f.instance)?.item == before)
    }

    @Test func masterEditsReachEveryInstanceButAnOverrideKeepsItsWords() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let fonts = DocumentFontIndex(state: a.state)
        var builder = Self.builder(a.state, fonts: fonts)
        let change = try #require(try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("Mine ", at: 0))))
        builder.apply(change, state: a.state, origin: .local)
        let reword = try #require(try a.perform(InsertText(node: f.text, text: "New ", at: TextFixture.at(a, f.text, 0))))
        let (_, summary) = builder.apply(reword, state: a.state, origin: .remote)
        #expect(summary.touchedNodes.isSuperset(of: [NodeID(f.instance), NodeID(f.other)]))
        #expect(Self.words(builder, f.other).hasPrefix("New Label"))
        #expect(Self.words(builder, f.instance).hasPrefix("Mine Label"), "the override keeps its own words")
        // Moving the master block moves the override with it.
        let start = try #require(Self.start(builder, f.instance))
        let moved = try #require(try a.perform(SetTransforms([(f.text, Objects.transform(of: f.text, in: a.state).concatenating(.translation(x: 10, y: 4)))])))
        builder.apply(moved, state: a.state, origin: .local)
        #expect(Self.close(Self.start(builder, f.instance), Point(x: start.x + 10, y: start.y + 4)))
        // A hidden block draws nothing, override or not; reset brings the master's words back.
        let hide = try #require(try a.perform(SetOverride([f.instance], master: f.text, value: .hidden(true), in: a.state)))
        builder.apply(hide, state: a.state, origin: .local)
        #expect(Self.words(builder, f.instance).isEmpty)
        let reset = try #require(try a.perform(ResetOverrides([f.instance])))
        builder.apply(reset, state: a.state, origin: .local)
        #expect(Self.words(builder, f.instance) == Self.words(builder, f.other))
    }

    @Test func anEmptiedOverrideDrawsNoWords() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let fonts = DocumentFontIndex(state: a.state)
        var builder = Self.builder(a.state, fonts: fonts)
        let change = try #require(try a.perform(OverrideText(f.instance, master: f.text, edit: .delete(0..<9))))
        builder.apply(change, state: a.state, origin: .local)
        #expect(Symbols.textNode(f.text, in: f.instance, state: a.state)?.length == 0)
        #expect(Self.words(builder, f.instance).isEmpty && !Self.words(builder, f.other).isEmpty)
    }

    @Test func withoutATextLayoutNoOverrideIsLaidOut() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("x", at: 0)))
        let resolved = try #require(Symbols.resolvedArtwork(of: f.instance, in: a.state))
        #expect(TextSceneLayout(engine: DocumentFontIndex(state: a.state).layoutEngine).overrides(of: f.instance, artwork: nil, state: a.state).overrides.isEmpty)
        let laid = TextSceneLayout(engine: DocumentFontIndex(state: a.state).layoutEngine).overrides(of: f.instance, artwork: resolved, state: a.state)
        #expect(laid.overrides.map(\.node) == [NodeID(f.text)] && laid.sources.contains(WellKnown.settings))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(a.state)
        #expect(Self.words(builder, f.instance).isEmpty)
    }

    // MARK: Editing hooks

    @Test func theTextToolReadsTheBlockAndItsPlacementThroughTheInstance() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let resolved = try #require(Symbols.resolvedArtwork(of: f.instance, in: a.state))
        #expect(resolved.textBlocks == [f.text])
        #expect(Symbols.textNode(f.text, in: f.instance, state: a.state)?.string == "Label\nTwo")
        #expect(Symbols.textNode(f.rect, in: f.instance, state: a.state) == nil, "not a text block")
        #expect(Symbols.textNode(f.text, in: f.rect, state: a.state) == nil, "not an instance")
        // The instance is made in place, so the master reads where the block was.
        let placed = try #require(Symbols.pasteboardTransform(ofMaster: f.text, in: f.instance, state: a.state))
        let probe = Point(x: 3, y: 4)
        #expect(Self.close(placed.apply(probe), f.placed.apply(probe)))
        let there = try #require(Symbols.pasteboardTransform(ofMaster: f.text, in: f.other, state: a.state))
        #expect(!Self.close(there.apply(probe), f.placed.apply(probe)))
        #expect(Symbols.symbolSpaceTransform(of: f.text, in: f.rect, state: a.state) == nil)
        #expect(Symbols.pasteboardTransform(ofMaster: f.text, in: f.rect, state: a.state) == nil)
    }

    @Test func replacingTextCopiesFirstThenTypesOverTheRange() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let change = try #require(try a.perform(OverrideText(f.instance, master: f.text, edit: .replace(0..<5, with: "Hi"))))
        #expect(Symbols.textNode(f.text, in: f.instance, state: a.state)?.string == "Hi\nTwo")
        #expect(change.ops.count > 3)
        try a.perform(OverrideText(f.instance, master: f.text, edit: .replace(3..<6, with: "There")))
        #expect(Symbols.textNode(f.text, in: f.instance, state: a.state)?.string == "Hi\nThere")
        try a.perform(OverrideText(f.instance, master: f.text, edit: .replace(0..<2, with: "")))
        #expect(Symbols.textNode(f.text, in: f.instance, state: a.state)?.string == "\nThere")
        #expect(OverrideText(f.instance, master: f.text, edit: .replace(0..<1, with: "a")).coalescing == .none)
        #expect(throws: TextEditError.invalidValue("range")) { try a.perform(OverrideText(f.instance, master: f.text, edit: .replace(0..<40, with: "a"))) }
        a.undo()
        #expect(Symbols.textNode(f.text, in: f.instance, state: a.state)?.string == "Hi\nThere")
    }

    // MARK: Merge

    @Test func concurrentOverrideTypingAndMasterRewordConvergeInTheDrawing() throws {
        var pair = Pair()
        let f = try Fixture(on: &pair.a)
        pair.sync()
        try pair.a.perform(OverrideText(f.instance, master: f.text, edit: .insert("Mine ", at: 0)))
        let anchor = TextFixture.at(pair.b, f.text, 5)
        try pair.b.perform(InsertText(node: f.text, text: " here", at: anchor))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        let fontsA = DocumentFontIndex(state: pair.a.state)
        let fontsB = DocumentFontIndex(state: pair.b.state)
        let a = Self.builder(pair.a.state, fonts: fontsA)
        let b = Self.builder(pair.b.state, fonts: fontsB)
        #expect(Self.words(a, f.instance).hasPrefix("Mine Label") && !Self.words(a, f.instance).contains("here"),
                "the override was copied before the reword and keeps its words")
        #expect(Self.words(a, f.other).hasPrefix("Label here"))
        #expect(a.scene.object(f.instance)?.item == b.scene.object(f.instance)?.item)
        #expect(a.scene.object(f.other)?.item == b.scene.object(f.other)?.item)
    }

    @Test func concurrentTypingIntoOneOverrideMergesInTheDrawing() throws {
        var pair = Pair()
        let f = try Fixture(on: &pair.a)
        try pair.a.perform(OverrideText(f.instance, master: f.text, edit: .insert("!", at: 5)))
        pair.sync()
        try pair.a.perform(OverrideText(f.instance, master: f.text, edit: .insert("A", at: 0)))
        try pair.b.perform(OverrideText(f.instance, master: f.text, edit: .insert("B", at: 6)))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        let a = Self.builder(pair.a.state, fonts: DocumentFontIndex(state: pair.a.state))
        let b = Self.builder(pair.b.state, fonts: DocumentFontIndex(state: pair.b.state))
        #expect(Self.words(a, f.instance).hasPrefix("ALabel!B"))
        #expect(a.scene.object(f.instance)?.item == b.scene.object(f.instance)?.item)
    }
}
