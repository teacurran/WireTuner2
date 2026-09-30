import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FONT-008's clipboard and FONT-010's placeholders and reordering: copying glyphs, Paste into a selection of the
/// same count, Paste as new glyphs, Paste as Component, moving several glyphs, the encodings' empty slots, and the
/// Guides pane's colour wells (FONT-006).
@Suite struct GlyphClipboardTests {
    /// `A` (a box, width 600, a `top` anchor, red, a note), `B` (empty), `acutecomb` (a small box) and `Aacute`
    /// built from `A` and `acutecomb`.
    static func fixture() throws -> (Replica, a: OpID, b: OpID, mark: OpID, aacute: OpID) {
        var r = Replica(0xA)
        try TypefaceFixture.typeface(&r, set: nil)
        try r.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42), NewGlyph(scalar: 0x301), NewGlyph(scalar: 0xC1)]))
        let a = TypefaceFixture.glyph("A", in: r), b = TypefaceFixture.glyph("B", in: r)
        let mark = TypefaceFixture.glyph("acutecomb", in: r), aacute = TypefaceFixture.glyph("Aacute", in: r)
        try TypefaceFixture.box(100, -700, 400, 700, on: a, in: &r)
        try TypefaceFixture.box(0, -900, 100, 100, on: mark, in: &r)
        try r.perform(SetGlyphWidth([a], to: 600))
        try r.perform(AddAnchor("top", at: Point(x: 300, y: -700), to: a))
        try r.perform(SetGlyphAttributes([a], markColor: 1, note: "stem"))
        try r.perform(AddComponent(a, to: aacute))
        try r.perform(AddComponent(mark, to: aacute, transform: .translation(x: 250, y: 0)))
        return (r, a, b, mark, aacute)
    }

    static func glyph(_ id: OpID, _ r: Replica) -> Glyph { GlyphIndex(r.state)[id]! }

    @Test func copyEncodesAndDecodesEveryPart() throws {
        let (r, a, _, mark, aacute) = try Self.fixture()
        let payload = GlyphClipboardPayload(copying: [aacute, a, OpID(counter: 999, replica: 9)], from: r.state, document: "doc-1")
        // Grid order, live glyphs only.
        #expect(payload.glyphs.map(\.name) == ["A", "Aacute"] && payload.sourceDocument == "doc-1" && !payload.isEmpty)
        let copiedA = payload.glyphs[0]
        #expect(copiedA.codepoints == [0x41] && copiedA.advanceWidth == 600 && copiedA.markColor == 1 && copiedA.note == "stem")
        #expect(copiedA.anchors == [CopiedGlyph.Anchor(name: "top", position: Point(x: 300, y: -700), role: .base)])
        #expect(copiedA.objects.nodes.count == 1 && copiedA.objects.bounds != nil)
        let copiedAacute = payload.glyphs[1]
        #expect(copiedAacute.components.map(\.sourceName) == ["A", "acutecomb"] && copiedAacute.components.map(\.source) == [a, mark])
        #expect(copiedAacute.components[1].transform == .translation(x: 250, y: 0))
        // The resolved sources' outlines travel for a paste that cannot resolve them.
        #expect(!GlyphOutlines.decode(copiedAacute.components[0].outline).isEmpty)
        let decoded = try #require(GlyphClipboardPayload(decoding: payload.encoded()))
        #expect(decoded == payload)
        // The artwork of every copied glyph, as one objects payload.
        #expect(payload.artwork.nodes.count == 1 && payload.artwork.sourceDocument == "doc-1")
        #expect(GlyphClipboardPayload(glyphs: []).artwork.bounds == nil)
        #expect(GlyphClipboardPayload(decoding: [0x08, 0x01]) == nil)
        #expect(GlyphClipboardPayload(decoding: Wire.field(1, [0xFF])) == nil)
        #expect(GlyphClipboardPayload(decoding: Wire.field(1, Wire.field(3, [0x08]))) == nil)
        // Unknown fields are skipped; a component without a name reads as unnamed.
        let bare = CopiedGlyph(source: a, name: "x", components: [CopiedGlyph.Component(source: nil, sourceName: "")])
        var bytes = Wire.field(9, [1]) + Wire.field(1, GlyphClipboardPayload.encode(bare) + Wire.field(7, [1]))
        bytes += Wire.field(2, Array("d".utf8))
        let read = try #require(GlyphClipboardPayload(decoding: bytes))
        #expect(read.glyphs == [bare] && read.sourceDocument == "d")
        #expect(GlyphClipboardPayload.unique(copiedA.objects.colors + copiedA.objects.colors) == GlyphClipboardPayload.unique(copiedA.objects.colors))
    }

    @Test func edgeCasesOfCopyingAndPasting() throws {
        var (r, a, b, mark, aacute) = try Self.fixture()
        // A removed source: the component copies unnamed, with its cached outline.
        try r.perform(RemoveGlyphs([mark]))
        let payload = GlyphClipboardPayload(copying: [aacute], from: r.state, document: "doc-1")
        #expect(payload.glyphs[0].components.map(\.sourceName) == ["A", ""] && !payload.glyphs[0].components[1].outline.isEmpty)
        // Replacing a glyph that has components: they go.
        var copy = payload.glyphs[0]
        copy.components = []
        copy.anchors = [CopiedGlyph.Anchor(name: "top", position: Point(x: .nan, y: 0), role: .base)]
        copy.objects.layerNames = []
        let artwork = try #require(GlyphClipboardPayload(copying: [a], from: r.state).glyphs.first?.objects)
        copy.objects = ClipboardPayload(nodes: artwork.nodes)
        try r.perform(PasteGlyphs(GlyphClipboardPayload(glyphs: [copy]), .replace([aacute])))
        #expect(Self.glyph(aacute, r).components.isEmpty && Self.glyph(aacute, r).anchors.first?.position == .zero)
        #expect(GlyphArtwork.objectIDs(on: aacute, in: r.state).count == 1)
        // A decoded component past the names reads unnamed.
        var props = Wiretuner_Doc_V1_GlyphProps()
        props.components = [Wiretuner_Doc_V1_Component()]
        let bytes = Wire.field(1, Wire.bytes { try b.proto.serializedBytes() }) + Wire.field(2, Wire.bytes { try props.serializedBytes() })
        #expect(GlyphClipboardPayload.decode(bytes)?.components == [CopiedGlyph.Component(source: nil, sourceName: "")])
        let color = Wiretuner_Lib_V1_LibraryColor()
        #expect(GlyphClipboardPayload.unique([color, color]).count == 1)
    }

    @Test func anchorsDecodeTheirRoleOrTheConvention() throws {
        var props = Wiretuner_Doc_V1_GlyphProps()
        props.name = "a"
        var anchor = Wiretuner_Doc_V1_GlyphAnchor()
        anchor.name = "_top"
        props.anchors = [anchor]
        anchor.name = "top"
        anchor.role = .mark
        props.anchors.append(anchor)
        anchor.name = "bottom"
        anchor.role = .base
        props.anchors.append(anchor)
        props.advanceWidth = .nan
        let bytes = Wire.field(1, Wire.bytes { try OpID(counter: 5, replica: 1).proto.serializedBytes() }) + Wire.field(2, Wire.bytes { try props.serializedBytes() })
        let glyph = try #require(GlyphClipboardPayload.decode(bytes))
        #expect(glyph.anchors.map(\.role) == [.mark, .mark, .base] && glyph.advanceWidth == 0)
        #expect(GlyphClipboardPayload.decode(Wire.field(2, Wire.bytes { try props.serializedBytes() })) == nil)
    }

    @Test func pasteAsNewGlyphsRenamesTakenOnesAndKeepsReferences() throws {
        var (r, a, b, mark, aacute) = try Self.fixture()
        let payload = GlyphClipboardPayload(copying: [a, aacute], from: r.state, document: "doc-1")
        let command = PasteGlyphs(payload, .add(after: b), into: "doc-1")
        #expect(command.label == "Paste 2 glyphs" && PasteGlyphs(GlyphClipboardPayload(glyphs: [payload.glyphs[0]]), .add(after: nil)).label == "Paste glyph")
        try r.perform(command)
        let index = GlyphIndex(r.state)
        let copyA = try #require(index.glyph(named: "A.1")), copyAacute = try #require(index.glyph(named: "Aacute.1"))
        // Names taken: `.1`, no codepoints; right after B in grid order.
        #expect(copyA.codepoints.isEmpty && copyAacute.codepoints.isEmpty && copyA.order == Self.glyph(b, r).order + 1)
        #expect(copyA.advanceWidth == 600 && copyA.markColor == 1 && copyA.note == "stem" && copyA.anchors.map(\.name) == ["top"])
        #expect(GlyphArtwork.objectIDs(on: copyA.id, in: r.state).count == 1 && GlyphArtwork.objectIDs(on: a, in: r.state).count == 1)
        // In its own document a component keeps its source.
        #expect(copyAacute.components.map(\.source) == [a, mark])
        // A second paste counts on.
        try r.perform(PasteGlyphs(GlyphClipboardPayload(glyphs: [payload.glyphs[0]], sourceDocument: "doc-1"), .add(after: nil), into: "doc-1"))
        #expect(GlyphIndex(r.state).glyph(named: "A.2") != nil)
        // One undo step removes the pasted glyphs and their artwork.
        _ = r.undo()
        _ = r.undo()
        #expect(GlyphIndex(r.state).glyph(named: "A.1") == nil && GlyphArtwork.objectIDs(on: copyA.id, in: r.state).isEmpty)
        #expect(throws: GlyphEditError.invalidValue("advance width")) {
            var bad = payload.glyphs[0]
            bad.advanceWidth = -1
            try r.perform(PasteGlyphs(GlyphClipboardPayload(glyphs: [bad]), .add(after: nil)))
        }
        #expect(throws: GlyphEditError.invalidName("9.1")) {
            var bad = payload.glyphs[0]
            bad.name = "9"
            try r.perform(PasteGlyphs(GlyphClipboardPayload(glyphs: [bad, bad]), .add(after: nil)))
        }
        #expect(try r.perform(PasteGlyphs(GlyphClipboardPayload(glyphs: []), .add(after: nil))) == nil)
        #expect(PasteGlyphs.uniqueName("a", taken: ["a", "a.1"]) == "a.2")
    }

    @Test func pasteIntoAnotherDocumentResolvesByNameAndDrawsTheRest() throws {
        let (source, a, _, _, aacute) = try Self.fixture()
        let payload = GlyphClipboardPayload(copying: [a, aacute], from: source.state, document: "doc-1")
        var other = Replica(0xB)
        try TypefaceFixture.typeface(&other, set: nil)
        try other.perform(AddGlyphs([NewGlyph(scalar: 0x301)]))
        let otherMark = TypefaceFixture.glyph("acutecomb", in: other)
        try other.perform(PasteGlyphs(payload, .add(after: nil), into: "doc-2"))
        let index = GlyphIndex(other.state)
        let pastedA = try #require(index.glyph(named: "A")), pastedAacute = try #require(index.glyph(named: "Aacute"))
        // Free names and codepoints are kept; `A` resolves to the glyph pasted with it, `acutecomb` by name.
        #expect(pastedA.codepoints == [0x41] && pastedAacute.codepoints == [0xC1])
        #expect(pastedAacute.components.map(\.source) == [pastedA.id, otherMark])
        #expect(pastedAacute.components[1].transform == .translation(x: 250, y: 0))
        // A component whose source is nowhere is drawn from its outline.
        var lone = Replica(0xC)
        try TypefaceFixture.typeface(&lone, set: nil)
        try lone.perform(PasteGlyphs(GlyphClipboardPayload(glyphs: [payload.glyphs[1]], sourceDocument: "doc-1"), .add(after: nil), into: "doc-3"))
        let drawn = try #require(GlyphIndex(lone.state).glyph(named: "Aacute"))
        #expect(drawn.components.isEmpty && GlyphArtwork.objectIDs(on: drawn.id, in: lone.state).count == 2)
        #expect(GlyphOutlines.metrics(of: drawn.id, in: lone.state)?.bounds != nil)
        // An empty outline draws nothing.
        var empty = payload.glyphs[1]
        empty.name = "empty"
        empty.codepoints = []
        empty.components = [CopiedGlyph.Component(source: nil, sourceName: "gone")]
        try lone.perform(PasteGlyphs(GlyphClipboardPayload(glyphs: [empty]), .add(after: nil)))
        #expect(GlyphArtwork.objectIDs(on: GlyphIndex(lone.state).glyph(named: "empty")!.id, in: lone.state).isEmpty)
    }

    @Test func pasteReplacesTheArtworkAndMetricsOfTheSameCount() throws {
        var (r, a, b, mark, aacute) = try Self.fixture()
        let payload = GlyphClipboardPayload(copying: [a], from: r.state, document: "doc-1")
        #expect(throws: GlyphEditError.invalidValue("selection")) { try r.perform(PasteGlyphs(payload, .replace([b, mark]), into: "doc-1")) }
        let command = PasteGlyphs(payload, .replace([b]), into: "doc-1")
        #expect(command.label == "Paste into glyph")
        try r.perform(command)
        let replaced = Self.glyph(b, r)
        #expect(replaced.name == "B" && replaced.codepoints == [0x42] && replaced.advanceWidth == 600 && replaced.anchors.map(\.name) == ["top"])
        #expect(replaced.markColor == 0 && GlyphArtwork.objectIDs(on: b, in: r.state).count == 1)
        // Replacing drawn artwork, components and anchors: the old ones go.
        let old = GlyphArtwork.objectIDs(on: mark, in: r.state)
        let both = GlyphClipboardPayload(copying: [a, aacute], from: r.state, document: "doc-1")
        #expect(PasteGlyphs(both, .replace([mark, a])).label == "Paste into 2 glyphs")
        try r.perform(PasteGlyphs(both, .replace([mark, a]), into: "doc-1"))
        #expect(!r.state.isLive(old[0]) && Self.glyph(mark, r).anchors.map(\.name) == ["top"])
        // `A` now holds Aacute's parts: its own component would be a loop, so it is drawn instead.
        #expect(Self.glyph(a, r).components.map(\.source) == [mark] && Self.glyph(a, r).anchors.isEmpty)
        #expect(GlyphArtwork.objectIDs(on: a, in: r.state).count == 1)
        #expect(throws: GlyphEditError.notAGlyph(OpID(counter: 999, replica: 1))) {
            try r.perform(PasteGlyphs(payload, .replace([OpID(counter: 999, replica: 1)])))
        }
        #expect(throws: GlyphEditError.invalidValue("advance width")) {
            var bad = payload
            bad.glyphs[0].advanceWidth = .infinity
            try r.perform(PasteGlyphs(bad, .replace([b])))
        }
    }

    @Test func pastedArtworkGoesToItsLayerByName() throws {
        var (r, a, b, _, _) = try Self.fixture()
        var payload = GlyphClipboardPayload(copying: [a], from: r.state, document: "doc-1")
        let layer = LayerOrder(r.state).drawingLayer!
        payload.glyphs[0].objects.layerNames = [LayerOrder(r.state).layer(layer)!.name]
        try r.perform(PasteGlyphs(payload, .replace([b])))
        #expect(GlyphArtwork.objects(on: b, in: r.state).map(\.layer) == [layer])
        // An empty document gets one layer for everything pasted.
        var fresh = Replica(0xD)
        try TypefaceFixture.typeface(&fresh, set: nil)
        #expect(LayerOrder(fresh.state).layers.isEmpty || LayerOrder(fresh.state).drawingLayer != nil)
        var two = payload
        two.glyphs[0].objects.layerNames = ["Missing"]
        two.glyphs.append(two.glyphs[0])
        two.glyphs[1].name = "C"
        two.glyphs[1].codepoints = [0x43]
        try fresh.perform(PasteGlyphs(two, .add(after: nil)))
        let glyphs = GlyphIndex(fresh.state).glyphs
        #expect(Set(glyphs.flatMap { GlyphArtwork.objects(on: $0.id, in: fresh.state).map(\.layer) }).count == 1)
    }

    @Test func pasteAsComponentsAddsEachCopiedGlyphAtTheOrigin() throws {
        var (r, a, b, mark, aacute) = try Self.fixture()
        let payload = GlyphClipboardPayload(copying: [a, mark], from: r.state, document: "doc-1")
        let command = PasteAsComponents(payload, into: [b], document: "doc-1")
        #expect(command.label == "Paste 2 components" && PasteAsComponents(GlyphClipboardPayload(glyphs: [payload.glyphs[0]]), into: [b]).label == "Paste as component")
        try r.perform(command)
        let components = Self.glyph(b, r).components
        #expect(components.map(\.source) == [a, mark] && components.allSatisfy { $0.transform.isIdentity && !$0.cached.isEmpty })
        // A glyph is never its own component: pasting A into A and Aacute adds only what does not loop.
        try r.perform(PasteAsComponents(payload, into: [mark], document: "doc-1"))
        #expect(Self.glyph(mark, r).components.map(\.source) == [a])
        #expect(throws: GlyphEditError.componentLoop) {
            try r.perform(PasteAsComponents(GlyphClipboardPayload(copying: [aacute], from: r.state, document: "doc-1"), into: [a], document: "doc-1"))
        }
        // From another document, by name; a name the font lacks is left out.
        var other = Replica(0xB)
        try TypefaceFixture.typeface(&other, set: nil)
        try other.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x45)]))
        let otherA = TypefaceFixture.glyph("A", in: other), otherE = TypefaceFixture.glyph("E", in: other)
        try other.perform(PasteAsComponents(payload, into: [otherE], document: "doc-2"))
        #expect(Self.glyph(otherE, other).components.map(\.source) == [otherA])
        #expect(throws: GlyphEditError.notAGlyph(OpID(counter: 999, replica: 1))) {
            try other.perform(PasteAsComponents(payload, into: [OpID(counter: 999, replica: 1)]))
        }
        #expect(throws: GlyphEditError.componentLoop) {
            try other.perform(PasteAsComponents(GlyphClipboardPayload(glyphs: [CopiedGlyph(source: a, name: "")]), into: [otherE]))
        }
    }

    @Test func reorderingMovesSeveralGlyphsTogether() throws {
        var (r, a, b, mark, aacute) = try Self.fixture()
        let command = ReorderGlyphs([aacute, b], to: 1)
        #expect(command.label == "Move 2 glyphs" && ReorderGlyphs([a], to: 1).label == "Move glyph")
        try r.perform(command)
        #expect(GlyphIndex(r.state).glyphs.map(\.id) == [b, aacute, a, mark])
        // Already there: nothing.
        #expect(try r.perform(ReorderGlyphs([b, aacute], to: 1)) == nil)
        #expect(try r.perform(ReorderGlyphs([], to: 1)) == nil)
        // Clamped to the end.
        try r.perform(ReorderGlyphs([b], to: 99))
        #expect(GlyphIndex(r.state).glyphs.last?.id == b)
        try r.perform(ReorderGlyphs([b], to: -3))
        #expect(GlyphIndex(r.state).glyphs.first?.id == b)
        #expect(throws: GlyphEditError.notAGlyph(OpID(counter: 999, replica: 1))) { try r.perform(ReorderGlyphs([OpID(counter: 999, replica: 1)], to: 1)) }
        _ = r.undo()
        #expect(GlyphIndex(r.state).glyphs.last?.id == b)
    }

    @Test func encodingsListTheirEmptySlots() throws {
        let (r, _, _, _, _) = try Self.fixture()
        #expect(GlyphEncoding.ascii.codepoints.count == 95 && GlyphEncoding.ascii.codepoints.first == 0x20)
        let latin1 = GlyphEncoding.latin1.codepoints
        #expect(latin1.count == 95 + 95 && !latin1.contains(0xAD) && latin1.contains(0xE9) && !latin1.contains(0x7F) && !latin1.contains(0x85))
        let macRoman = GlyphEncoding.macRoman.codepoints
        #expect(macRoman.contains(0x2022) && macRoman.contains(0xE9) && macRoman.contains(0x41) && !macRoman.contains(0xF8FF))
        #expect(GlyphEncoding.greek.codepoints.contains(0x3B1) && !GlyphEncoding.greek.codepoints.contains(0x378))
        #expect(GlyphEncoding.codePages == [.ascii, .latin1, .macRoman] && GlyphEncoding.blocks.count == GlyphEncoding.allCases.count - 3)
        #expect(Set(GlyphEncoding.allCases.map(\.title)).count == GlyphEncoding.allCases.count && GlyphEncoding.greek.id == "greek")
        for block in GlyphEncoding.blocks { #expect(!block.codepoints.isEmpty) }
        #expect(!GlyphEncoding.isPrintable(0xD800) && !GlyphEncoding.isPrintable(0x110000) && GlyphEncoding.isPrintable(0x41))
        let index = GlyphIndex(r.state)
        let missing = GlyphEncoding.placeholders([.ascii], in: index)
        #expect(missing.count == 93 && !missing.contains(0x41) && missing.contains(0x43))
        // Several at once, without repeats (the soft hyphen is a format character); none chosen shows none.
        #expect(GlyphEncoding.placeholders([.ascii, .latin1], in: index).count == 95 + 95 - 3)
        #expect(GlyphEncoding.placeholders([], in: index).isEmpty)
    }

    @Test func guideColorWellsWriteAndClear() throws {
        var (r, _, _, _, _) = try Self.fixture()
        let red = Color(red: 1, green: 0, blue: 0)
        try r.perform(SetMetricGuides([.color(.baseline, red), .color(.metric, Color(red: 0, green: 1, blue: 0)), .color(.bearing, Color(red: 0, green: 0, blue: 1))]))
        var guides = FontInfo(r.state).guides
        #expect(guides.baselineColor == red && guides.metricColor == Color(red: 0, green: 1, blue: 0) && guides.bearingColor == Color(red: 0, green: 0, blue: 1))
        try r.perform(SetMetricGuides([.color(.baseline, nil)]))
        guides = FontInfo(r.state).guides
        #expect(guides.baselineColor == nil && guides.metricColor != nil)
        #expect(SetMetricGuides.ColorWell.allCases.map(\.rawValue) == [9, 10, 11])
    }
}
