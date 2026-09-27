import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// COLOR-019's paste half (exporting-colors.adoc, "Sharing colors between documents"): a copy
/// carries the named colours its objects use; a paste into another document adds the missing
/// ones in the same change, reuses a same-name same-value swatch, and renames a same-name
/// different-value one to its mix values.
@Suite struct PastedColorsTests {
    static let grape = Color(red: 0.5, green: 0.1, blue: 0.6)

    static func fillSwatch(_ node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_ColorRef {
        state.props(node).rect.appearance.fills[0].settings.basic.color
    }

    static func name(_ swatch: OpID, in state: EngineState) -> String { state.props(swatch).swatch.common.name }

    /// A document with "Grape", a 50% tint of it, and a rectangle filled with each.
    static func source() throws -> (replica: Replica, payload: ClipboardPayload, grape: OpID, tint: OpID) {
        var source = Replica(0xA)
        let grape = try #require(try source.perform(AddSwatch(Self.grape, name: "Grape"))).createdNodes[0]
        let tint = try #require(try source.perform(AddTintSwatch(of: grape, percent: 50, name: "Grape 50"))).createdNodes[0]
        let a = try #require(try source.perform(SymbolTransferTests.swatched(x: 0, swatch: grape))).createdObjects[0]
        var tinted = SymbolTransferTests.swatched(x: 20, swatch: tint)
        tinted.appearance.fills[0].settings.basic.color = Wiretuner_Doc_V1_ColorRef()
        tinted.appearance.fills[0].settings.basic.color.tint.base.id = grape.proto
        tinted.appearance.fills[0].settings.basic.color.tint.percent = 25
        let b = try #require(try source.perform(tinted)).createdObjects[0]
        let c = try #require(try source.perform(SymbolTransferTests.swatched(x: 40, swatch: tint))).createdObjects[0]
        let payload = ClipboardPayload(copying: [a, b, c], from: source.state, document: "doc-a")
        return (source, payload, grape, tint)
    }

    @Test func aCopyCarriesItsSwatchesBasesFirstAndSurvivesThePasteboard() throws {
        let (_, payload, grape, tint) = try Self.source()
        #expect(payload.colors.map(\.key) == [PastedColors.key(grape), PastedColors.key(tint)])
        #expect(payload.colors[1].tintOf == PastedColors.key(grape) && payload.colors[1].tintPercent == 50)
        #expect(payload.colors.map(\.name) == ["Grape", "Grape 50"])
        let decoded = try #require(ClipboardPayload(decoding: payload.encoded()))
        #expect(decoded.colors == payload.colors)
        // A colour that does not read is left out.
        var bytes = payload.encoded()
        bytes += Wire.field(7, [0xFF])
        #expect(ClipboardPayload(decoding: bytes)?.colors.count == 2)
    }

    @Test func pasteIntoAnotherDocumentCreatesTheMissingSwatchesInTheSameChange() throws {
        let (_, payload, _, _) = try Self.source()
        var target = Replica(0xB)
        let change = try #require(try target.perform(Paste(payload)))
        let swatches = SymbolTransferTests.swatches(in: target.state)
        #expect(swatches.count == 2 && change.createdNodes.contains(swatches[0]) && change.createdNodes.contains(swatches[1]))
        #expect(Self.name(swatches[0], in: target.state) == "Grape" && Self.name(swatches[1], in: target.state) == "Grape 50")
        let list = SwatchList(target.state)
        #expect(list[swatches[1]]?.base == swatches[0] && list[swatches[1]]?.tintPercent == 50)
        let roots = change.createdRoots
        #expect(roots.count == 3)
        let first = Self.fillSwatch(roots[0], in: target.state)
        #expect(ColorResolver.swatch(of: first) == swatches[0])
        #expect(ColorValues.cachedColor(first.swatch.cached) == Self.grape, "the reference caches the colour")
        let second = Self.fillSwatch(roots[1], in: target.state)
        #expect(OpID(second.tint.base.id) == swatches[0] && second.tint.percent == 25, "an unnamed tint follows its base")
        #expect(ColorResolver.swatch(of: Self.fillSwatch(roots[2], in: target.state)) == swatches[1])
        // Pasting again reuses them all.
        try target.perform(Paste(payload))
        #expect(SymbolTransferTests.swatches(in: target.state).count == 2)
        // One undo removes the objects and the swatches together.
        target.undo()
        target.undo()
        #expect(SymbolTransferTests.swatches(in: target.state).isEmpty)
    }

    @Test func aSameNameDifferentValueSwatchArrivesRenamedToItsMixValues() throws {
        let (_, payload, _, _) = try Self.source()
        var target = Replica(0xB)
        let other = try #require(try target.perform(AddSwatch(Color(red: 0.2, green: 0.8, blue: 0.2), name: "Grape"))).createdNodes[0]
        let change = try #require(try target.perform(Paste(payload)))
        let list = SwatchList(target.state)
        let created = list.swatches.filter { $0.id != other }
        let renamed = try #require(created.first { !$0.isTint })
        #expect(renamed.plainName == ColorText.defaultName(Self.grape) && renamed.color == Self.grape)
        #expect(ColorResolver.swatch(of: Self.fillSwatch(change.createdRoots[0], in: target.state)) == renamed.id)
        #expect(Self.name(other, in: target.state) == "Grape", "the destination's own swatch is untouched")
        // The tint keeps its name (free here) and becomes a tint of the renamed base.
        #expect(created.first { $0.isTint }?.base == renamed.id)
        // Pasting again finds the mix-values swatch rather than adding another.
        try target.perform(Paste(payload))
        #expect(SwatchList(target.state).swatches.count == 3)
    }

    /// The app's copy also carries LIB-022's library; the cross-document paste resolves the swatches
    /// with the clash rule rather than by name, and imports none of the package's copies of them.
    @Test func aCrossDocumentPasteWithALibraryUsesTheClashRule() throws {
        let (source, plain, _, _) = try Self.source()
        let payload = plain.carryingLibrary(from: source.state)
        #expect(payload.library != nil && payload.colors == plain.colors)
        let decoded = try #require(ClipboardPayload(decoding: payload.encoded()))
        #expect(decoded == payload)
        var target = Replica(0xB)
        let other = try #require(try target.perform(AddSwatch(Color(red: 0.2, green: 0.8, blue: 0.2), name: "Grape"))).createdNodes[0]
        let change = try #require(try target.perform(PasteFromDocument(Paste(decoded))))
        #expect(change.createdRoots.count == 3)
        let list = SwatchList(target.state)
        #expect(list.swatches.count == 3, "the renamed base and its tint, nothing imported by name")
        let renamed = try #require(list.swatches.first { $0.id != other && !$0.isTint })
        #expect(renamed.plainName == ColorText.defaultName(Self.grape))
        #expect(ColorResolver.swatch(of: Self.fillSwatch(change.createdRoots[0], in: target.state)) == renamed.id)
        #expect(list.swatches.first { $0.isTint }?.base == renamed.id)
        // Again: everything is found.
        try target.perform(PasteFromDocument(Paste(decoded)))
        #expect(SwatchList(target.state).swatches.count == 3)
    }

    @Test func aSameNameSameValueSwatchIsReusedAndSameDocumentPastesKeepTheirSwatches() throws {
        var (source, payload, grape, tint) = try Self.source()
        let change = try #require(try source.perform(Paste(payload)))
        #expect(SymbolTransferTests.swatches(in: source.state) == [grape, tint], "nothing added in the same document")
        #expect(ColorResolver.swatch(of: Self.fillSwatch(change.createdRoots[0], in: source.state)) == grape)
        var target = Replica(0xB)
        let existing = try #require(try target.perform(AddSwatch(Self.grape, name: "Grape"))).createdNodes[0]
        let pasted = try #require(try target.perform(Paste(payload)))
        #expect(ColorResolver.swatch(of: Self.fillSwatch(pasted.createdRoots[0], in: target.state)) == existing)
        #expect(SwatchList(target.state).swatches.count == 2, "only the tint was added")
    }

    @Test func protectedSwatchesMapByNameAndPayloadsWithoutColoursPasteAsBefore() throws {
        var source = Replica(0xA)
        try source.perform(DocumentTemplate())
        let black = try #require(SwatchList(source.state).swatches.first { $0.isProtected && $0.plainName == "Black" })
        let rect = try #require(try source.perform(SymbolTransferTests.swatched(x: 0, swatch: black.id))).createdObjects[0]
        let payload = ClipboardPayload(copying: [rect], from: source.state)
        var target = Replica(0xB)
        try target.perform(DocumentTemplate())
        let before = SwatchList(target.state).swatches.count
        let change = try #require(try target.perform(Paste(payload)))
        let targetBlack = try #require(SwatchList(target.state).swatches.first { $0.isProtected && $0.plainName == "Black" })
        #expect(SwatchList(target.state).swatches.count == before)
        #expect(ColorResolver.swatch(of: Self.fillSwatch(change.createdRoots[0], in: target.state)) == targetBlack.id)
        // Without carried colours the references are pasted as they were.
        var bare = payload
        bare.colors = []
        let plain = try #require(try target.perform(Paste(bare)))
        #expect(ColorResolver.swatch(of: Self.fillSwatch(plain.createdRoots[0], in: target.state)) == black.id)
    }

    @Test func textFillsFollowTheirSwatchAndTwinColoursAreAddedOnce() throws {
        var source = Replica(0xA)
        let grape = try #require(try source.perform(AddSwatch(Self.grape, name: "Grape"))).createdNodes[0]
        let node = try TextFixture.block(&source, "Hi\nthere", at: Point(x: 10, y: 10))
        var fill = Wiretuner_Doc_V1_ColorRef()
        fill.swatch.id = grape.proto
        try source.perform(TextColor.fill(node: node, from: .start, to: TextFixture.at(source, node, 1), fill))
        var payload = ClipboardPayload(copying: [node], from: source.state)
        #expect(payload.colors.map(\.name) == ["Grape"])
        // Two carried colours of one name and value (from different documents) become one swatch.
        var twin = payload.colors[0]
        twin.key = "99.99"
        payload.colors.append(twin)
        var target = Replica(0xB)
        let change = try #require(try target.perform(Paste(payload)))
        let swatches = SymbolTransferTests.swatches(in: target.state)
        #expect(swatches.count == 1)
        let text = try #require(TextNode(change.createdRoots[0], in: target.state))
        guard case .fill(let ref)? = text.values(at: 0).first(where: { if case .fill? = $0.value { true } else { false } })?.value else {
            Issue.record("a fill mark")
            return
        }
        #expect(ColorResolver.swatch(of: ref) == swatches[0])
    }

    @Test func theRewriterKeepsEveryOtherByteAndRefusesMalformedInput() throws {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.rect.size = .with { $0.width = 3; $0.height = 4 }
        let schema = EngineState().schema
        let bytes = try props.serializedBytes() as [UInt8]
        #expect(ColorRefRewriter.rewrite(bytes, message: Schema.root, schema: schema) { _ in true } == nil, "no reference, nothing changed")
        #expect(ColorRefRewriter.rewrite([0x0A, 0x7F], message: Schema.root, schema: schema) { _ in true } == nil)
        #expect(ColorRefRewriter.rewrite([0x0B], message: Schema.root, schema: schema) { _ in true } == nil, "group wire types do not parse")
        #expect(ColorRefRewriter.rewrite([0x08, 0x01, 0x11, 0, 0, 0, 0, 0, 0, 0, 0, 0x1D, 0, 0, 0, 0], message: Schema.root, schema: schema) { _ in true } == nil)
        #expect(PastedColors.rewrite([NodeTree(props: props)], mapping: [:], schema: schema) == [NodeTree(props: props)])
        #expect(ColorRefRewriter.rewrite(bytes, message: Schema.root, schema: schema, depth: 16) { _ in true } == nil, "too deep")
    }

    @Test func theRewriterRefusesTruncatedFields() {
        let schema = EngineState().schema
        #expect(ColorRefRewriter.rewrite([0x80], message: Schema.root, schema: schema) { _ in true } == nil, "an unterminated key")
        #expect(ColorRefRewriter.rewrite([0x08, 0x80], message: Schema.root, schema: schema) { _ in true } == nil, "an unterminated varint")
        #expect(ColorRefRewriter.rewrite([0x09, 0, 0], message: Schema.root, schema: schema) { _ in true } == nil, "a short fixed64")
    }

    @Test func aSpotSwatchOfTheSameNameIsADifferentColour() throws {
        let (_, payload, _, _) = try Self.source()
        var target = Replica(0xB)
        let spot = try #require(try target.perform(AddSwatch(Self.grape, name: "Grape"))).createdNodes[0]
        try target.perform(SetSwatchSpot([spot], spot: true))
        try target.perform(Paste(payload))
        let names = SwatchList(target.state).swatches.map(\.plainName)
        #expect(names.contains("Grape") && names.contains(ColorText.defaultName(Self.grape)))
    }

    @Test func referencesToSwatchesNotCarriedAreLeftAndTwinTintsAreAddedOnce() throws {
        var (source, _, grape, tint) = try Self.source()
        let missing = OpID(counter: 9999, replica: 0xA)
        let stray = try #require(try source.perform(SymbolTransferTests.swatched(x: 60, swatch: missing))).createdObjects[0]
        var strayTint = SymbolTransferTests.swatched(x: 80, swatch: grape)
        strayTint.appearance.fills[0].settings.basic.color = Wiretuner_Doc_V1_ColorRef()
        strayTint.appearance.fills[0].settings.basic.color.tint.base.id = missing.proto
        strayTint.appearance.fills[0].settings.basic.color.tint.percent = 30
        let strayTinted = try #require(try source.perform(strayTint)).createdObjects[0]
        let rect = try #require(try source.perform(SymbolTransferTests.swatched(x: 100, swatch: tint))).createdObjects[0]
        var payload = ClipboardPayload(copying: [stray, strayTinted, rect], from: source.state)
        #expect(payload.colors.map(\.name) == ["Grape", "Grape 50"], "a swatch that is not there is not carried")
        var twin = payload.colors[1]
        twin.key = "99.99"
        payload.colors.append(twin)
        var target = Replica(0xB)
        let change = try #require(try target.perform(Paste(payload)))
        #expect(SymbolTransferTests.swatches(in: target.state).count == 2)
        #expect(ColorResolver.swatch(of: Self.fillSwatch(change.createdRoots[0], in: target.state)) == missing)
        #expect(OpID(Self.fillSwatch(change.createdRoots[1], in: target.state).tint.base.id) == missing)
    }
}
