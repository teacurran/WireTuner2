import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// LIB-025: text overrides, `resolvedArtwork(of:)` and its cache, the read-time rules under merge,
/// and Release applying every override (library.adoc).
@Suite struct SymbolOverrideTests {
    /// A symbol of a blue rectangle, a text block "Label" and an image, with one instance.
    struct Fixture {
        var symbol: OpID, instance: OpID
        var rect: OpID, text: OpID, image: OpID

        init(on a: inout Replica) throws {
            rect = try a.perform(SymbolFixture.rect(x: 0))!.createdObjects[0]
            text = try TextFixture.block(&a, "Label", at: Point(x: 0, y: 30))
            let layer = try #require(Objects.parent(of: rect, in: a.state))
            var props = Wiretuner_Doc_V1_NodeProps()
            props.image.dpiX = 72
            props.image.dpiY = 72
            props.image.pixels.blobSha256 = Data(repeating: 1, count: 32)
            image = try a.perform(OpsCommand("Image", ops: [Ops.create(parent: layer, position: [0xF0], props: props)]))!.createdNodes[0]
            let change = try #require(try a.perform(ConvertToSymbol([rect, text, image])))
            symbol = change.createdNodes[0]
            instance = change.createdNodes[1]
        }
    }

    static func shown(_ fixture: Fixture, _ instance: OpID? = nil, in state: EngineState) -> String? {
        Symbols.resolvedArtwork(of: instance ?? fixture.instance, in: state)?.texts[fixture.text]?.string
    }

    @Test func theFirstTextEditCreatesTheElementWithTheMastersCharactersInOneChange() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        #expect(Self.shown(f, in: a.state) == "Label")
        #expect(Symbols.resolvedArtwork(of: f.instance, in: a.state)?.texts[f.text]?.isOverride == false)
        let command = OverrideText(f.instance, master: f.text, edit: .insert("!", at: 5))
        #expect(command.label == "Override text")
        let change = try #require(try a.perform(command))
        #expect(change.ops.count == 3, "the element, the copied characters, the typed one")
        #expect(Self.shown(f, in: a.state) == "Label!")
        #expect(Symbols.resolvedArtwork(of: f.instance, in: a.state)?.texts[f.text]?.isOverride == true)
        #expect(TextNode(f.text, in: a.state)?.string == "Label", "the master is untouched")
        // Later edits go to the same element.
        try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("My ", at: 0)))
        try a.perform(OverrideText(f.instance, master: f.text, edit: .delete(8..<9)))
        #expect(Self.shown(f, in: a.state) == "My Label")
        #expect(a.state.liveElements(f.instance, SymbolFields.overrides).count == 1)
        // A first edit that deletes also copies first.
        let other = try #require(try a.perform(PlaceInstance(f.symbol, at: Point(x: 200, y: 0))))
        let second = other.createdObjects[0]
        try a.perform(OverrideText(second, master: f.text, edit: .delete(0..<2)))
        #expect(Self.shown(f, second, in: a.state) == "bel")
        // Undo takes the whole first edit back.
        a.undo()
        #expect(Self.shown(f, second, in: a.state) == "Label" && a.state.liveElements(second, SymbolFields.overrides).isEmpty)
    }

    @Test func theCopiedTextKeepsTheMastersMarks() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let chars = try #require(TextNode(f.text, in: a.state)).chars
        var mark = Wiretuner_Doc_V1_TextMark()
        mark.node = f.text.proto
        mark.text = TextFields.text.proto
        mark.start.char = chars[0].elementID
        mark.start.before = true
        mark.end.char = chars[2].elementID
        mark.value.size = 30
        var op = Wiretuner_Doc_V1_Op()
        op.textMark = mark
        try a.perform(OpsCommand("Size", ops: [op]))
        try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("!", at: 5)))
        let text = try #require(Symbols.resolvedArtwork(of: f.instance, in: a.state)?.texts[f.text])
        #expect(text.string == "Label!" && text.isOverride)
        #expect(text.runs.contains { run in run.range == 0..<3 && run.values.contains { $0.size == 30 } })
    }

    @Test func textEditsAreValidated() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        #expect(throws: SymbolError.notOverridable(f.rect)) { try a.perform(OverrideText(f.instance, master: f.rect, edit: .insert("x", at: 0))) }
        #expect(throws: SymbolError.notAnInstance(f.rect)) { try a.perform(OverrideText(f.rect, master: f.text, edit: .insert("x", at: 0))) }
        #expect(throws: TextEditError.invalidValue("offset")) { try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("x", at: 9))) }
        #expect(throws: TextEditError.invalidValue("range")) { try a.perform(OverrideText(f.instance, master: f.text, edit: .delete(3..<9))) }
        try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("", at: 0)))
        #expect(Self.shown(f, in: a.state) == "Label", "an empty insert still copies, and types nothing")
        #expect(try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("", at: 0))) == nil)
        #expect(throws: TextEditError.invalidValue("offset")) { try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("x", at: 9))) }
        try a.perform(SetLocked([f.instance], locked: true))
        #expect(try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("x", at: 0))) == nil)
        // Typing coalesces per word; deleting is its own step.
        #expect(OverrideText(f.instance, master: f.text, edit: .insert("a", at: 0)).coalescing
            == .typing(node: f.instance, field: SymbolFields.overrides.element(f.text), endsWord: false))
        #expect(OverrideText(f.instance, master: f.text, edit: .insert(" ", at: 0)).coalescing
            == .typing(node: f.instance, field: SymbolFields.overrides.element(f.text), endsWord: true))
        #expect(OverrideText(f.instance, master: f.text, edit: .delete(0..<1)).coalescing == .none)
    }

    @Test func resolvedArtworkAppliesEveryOverride() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let asset = try a.perform(OpsCommand("Asset", ops: [Ops.create(parent: OpID.wellKnown(9), position: [0x80], props: .with {
            $0.asset.sha256 = Data(repeating: 7, count: 32)
            $0.asset.mediaType = "public.png"
        })]))!.createdNodes[0]
        try a.perform(SetOverride([f.instance], master: f.rect, value: .fill(SymbolFixture.red()), in: a.state))
        try a.perform(SetOverride([f.instance], master: f.image, value: .image(asset), in: a.state))
        try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("New ", at: 0)))
        let artwork = try #require(Symbols.resolvedArtwork(of: f.instance, in: a.state))
        #expect(artwork.symbol == f.symbol && artwork.nodes.map(\.source) == [f.rect, f.text, f.image])
        #expect(artwork.nodes[0].props.rect.appearance.fills[0].settings.basic.color == SymbolFixture.red())
        #expect(artwork.nodes[2].props.image.pixels.blobSha256 == Data(repeating: 7, count: 32))
        #expect(artwork.nodes[2].props.image.pixels.format == "public.png")
        #expect(artwork.texts[f.text]?.string == "New Label")
        try a.perform(SetOverride([f.instance], master: f.text, value: .hidden(true), in: a.state))
        let hidden = try #require(Symbols.resolvedArtwork(of: f.instance, in: a.state))
        #expect(hidden.nodes.map(\.source) == [f.rect, f.image] && hidden.texts[f.text] == nil)
        // A dangling image override reads as the master's image.
        try a.perform(DeleteNodes([asset]))
        try a.perform(OpsCommand("Gone", ops: [Ops.setDeleted(asset)]))
        #expect(Symbols.resolvedArtwork(of: f.instance, in: a.state)?.nodes.last?.props.image.pixels.blobSha256 == Data(repeating: 1, count: 32))
        // A missing symbol resolves to nothing.
        try a.perform(OpsCommand("Remove", ops: [Ops.setDeleted(f.symbol)]))
        #expect(Symbols.resolvedArtwork(of: f.instance, in: a.state) == nil)
    }

    @Test func theCacheBuildsOncePerInstanceAndASymbolEditInvalidatesOnlyItsInstances() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        // Ten overrides on the instance.
        let extra = try (0..<8).map { index in try a.perform(SymbolFixture.rect(x: 100 + Double(index) * 20))!.createdObjects[0] }
        for node in extra { try a.perform(OpsCommand("Into", ops: [Ops.move(node, parent: f.symbol, position: [0xF8, UInt8(node.counter % 200)])])) }
        for node in extra { try a.perform(SetOverride([f.instance], master: node, value: .fill(SymbolFixture.red()), in: a.state)) }
        try a.perform(SetOverride([f.instance], master: f.rect, value: .stroke(SymbolFixture.red()), in: a.state))
        try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("x", at: 0)))
        #expect(Symbols.liveOverrides(of: f.instance, in: a.state).count == 10)
        let other = try a.perform(SymbolFixture.rect(x: 500))!.createdObjects[0]
        let otherChange = try #require(try a.perform(ConvertToSymbol([other])))
        let otherInstance = otherChange.createdNodes[1]
        let cache = ResolvedArtworkCache()
        let first = cache.artwork(of: f.instance, in: a.state)
        #expect(cache.artwork(of: f.instance, in: a.state) == first)
        _ = cache.artwork(of: otherInstance, in: a.state)
        #expect(cache.builds == 2, "one build per instance")
        // An edit inside the first symbol rebuilds only its instance.
        let edit = try #require(try a.perform(SetTransforms([(f.rect, .translation(x: 3, y: 0))])))
        cache.invalidate(by: edit, state: a.state)
        _ = cache.artwork(of: f.instance, in: a.state)
        _ = cache.artwork(of: otherInstance, in: a.state)
        #expect(cache.builds == 3)
        // An override edit rebuilds only its instance; a folder change everything.
        let override = try #require(try a.perform(ResetOverrides([otherInstance])) ?? a.perform(SetOverride([otherInstance], master: other, value: .hidden(true), in: a.state)))
        cache.invalidate(by: override, state: a.state)
        _ = cache.artwork(of: f.instance, in: a.state)
        _ = cache.artwork(of: otherInstance, in: a.state)
        #expect(cache.builds == 4)
        let folder = try #require(try a.perform(CreateSymbolFolder()))
        cache.invalidate(by: folder, state: a.state)
        _ = cache.artwork(of: f.instance, in: a.state)
        #expect(cache.builds == 5)
        // A missing symbol caches its nil too.
        #expect(cache.artwork(of: f.rect, in: a.state) == nil && cache.artwork(of: f.rect, in: a.state) == nil)
        #expect(cache.builds == 6)
    }

    @Test func aNestedSymbolEditReachesItsHostsInstances() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let host = try a.perform(ConvertToSymbol([f.instance]))!
        let hostInstance = host.createdNodes[1]
        let cache = ResolvedArtworkCache()
        _ = cache.artwork(of: hostInstance, in: a.state)
        let edit = try #require(try a.perform(SetTransforms([(f.rect, .translation(x: 3, y: 0))])))
        cache.invalidate(by: edit, state: a.state)
        _ = cache.artwork(of: hostInstance, in: a.state)
        #expect(cache.builds == 2)
    }

    @Test func releaseAppliesTextAndImageOverrides() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let asset = try a.perform(OpsCommand("Asset", ops: [Ops.create(parent: OpID.wellKnown(9), position: [0x80], props: .with {
            $0.asset.sha256 = Data(repeating: 9, count: 32)
        })]))!.createdNodes[0]
        try a.perform(SetOverride([f.instance], master: f.image, value: .image(asset), in: a.state))
        try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("Big ", at: 0)))
        let other = try a.perform(PlaceInstance(f.symbol, at: Point(x: 300, y: 0)))!.createdObjects[0]
        let release = try #require(try a.perform(ReleaseInstances([f.instance, other])))
        let groups = release.createdObjects.filter { a.state.nodeKind($0) == .group }
        #expect(groups.count == 2)
        let copies = a.state.liveChildren(groups[0])
        let texts = copies.compactMap { TextNode($0, in: a.state)?.string }
        #expect(texts == ["Big Label"])
        let pixels = copies.compactMap { a.state.nodeKind($0) == .image ? a.state.props($0).image.pixels.blobSha256 : nil }
        #expect(pixels == [Data(repeating: 9, count: 32)])
        #expect(a.state.liveChildren(groups[1]).compactMap { TextNode($0, in: a.state)?.string } == ["Label"], "without an override, the master's text")
    }

    // MARK: Merge

    static func pair() throws -> (Pair, Fixture) {
        var pair = Pair()
        let f = try Fixture(on: &pair.a)
        pair.sync()
        return (pair, f)
    }

    @Test func resetVersusEditLeavesTheElementDeletedAndRestoreBringsTheEditBack() throws {
        var (pair, f) = try Self.pair()
        try pair.a.perform(OverrideText(f.instance, master: f.text, edit: .insert("A", at: 0)))
        pair.sync()
        let element = try #require(pair.a.state.liveElements(f.instance, SymbolFields.overrides).first)
        try pair.a.perform(ResetOverrides([f.instance]))
        try pair.b.perform(OverrideText(f.instance, master: f.text, edit: .insert("B", at: 0)))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(Self.shown(f, in: pair.a.state) == "Label", "the element stays deleted")
        try pair.a.perform(OpsCommand("Restore", ops: [Ops.elementDelete(f.instance, [SymbolFields.override(element)], deleted: false)]))
        #expect(Self.shown(f, in: pair.a.state) == "BALabel")
    }

    @Test func duplicateCreationRendersTheGreaterIdOnBothReplicas() throws {
        var (pair, f) = try Self.pair()
        try pair.a.perform(OverrideText(f.instance, master: f.text, edit: .insert("A ", at: 0)))
        try pair.b.perform(OverrideText(f.instance, master: f.text, edit: .insert("B ", at: 0)))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(pair.a.state.liveElements(f.instance, SymbolFields.overrides).count == 2)
        #expect(Self.shown(f, in: pair.a.state) == "B Label" && Self.shown(f, in: pair.b.state) == "B Label")
    }

    @Test func masterNodeDeletedVersusOverrideEditRendersNothingUntilRestored() throws {
        var (pair, f) = try Self.pair()
        try pair.a.perform(OpsCommand("Delete master", ops: [Ops.setDeleted(f.text)]))
        try pair.b.perform(OverrideText(f.instance, master: f.text, edit: .insert("B", at: 0)))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(Symbols.liveOverrides(of: f.instance, in: pair.a.state).isEmpty && Self.shown(f, in: pair.a.state) == nil)
        try pair.a.perform(OpsCommand("Restore", ops: [Ops.setDeleted(f.text, false)]))
        #expect(Self.shown(f, in: pair.a.state) == "BLabel")
    }

    @Test func swapVersusOverrideEditSetsItAsideAndSwapBackRestores() throws {
        var (pair, f) = try Self.pair()
        let other = try pair.a.perform(SymbolFixture.rect(x: 900))!.createdObjects[0]
        let second = try pair.a.perform(ConvertToSymbol([other]))!.createdNodes[0]
        pair.sync()
        try pair.a.perform(SwapSymbol([f.instance], to: second))
        try pair.b.perform(OverrideText(f.instance, master: f.text, edit: .insert("B", at: 0)))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(Symbols.liveOverrides(of: f.instance, in: pair.a.state).isEmpty, "set aside under the other symbol")
        try pair.a.perform(SwapSymbol([f.instance], to: f.symbol))
        #expect(Self.shown(f, in: pair.a.state) == "BLabel")
    }
}
