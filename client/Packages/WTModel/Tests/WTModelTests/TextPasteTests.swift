import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto

/// TYPE-009: pasting and dropping text into a block and as a new block (importing-text.adoc,
/// "Pasting", "Merge semantics").
@Suite @MainActor struct TextPasteTests {
    static let bold = TextFixture.mark { $0.fontStyle = "Bold" }

    /// "Hello world" with "Hello" bold, "world" 24 pt.
    static func source(_ replica: inout Replica) throws -> OpID {
        let node = try TextFixture.block(&replica, "Hello world")
        try replica.perform(ApplyMark(node: node, from: TextFixture.at(replica, node, 0), to: TextFixture.at(replica, node, 5), value: bold))
        try replica.perform(ApplyMark(node: node, from: TextFixture.at(replica, node, 6), to: .end, value: TextFixture.size(24)))
        return node
    }

    static func has(_ values: [Wiretuner_Doc_V1_TextMarkValue], _ value: Wiretuner_Doc_V1_TextMarkValue) -> Bool {
        values.contains(value)
    }

    @Test func aWireTunerCopyKeepsEveryAttributeWhenPastedIntoACaret() throws {
        var a = Replica(1)
        let source = try Self.source(&a)
        let clip = try #require(TextClip(copying: 3..<8, of: source, in: a.state))
        #expect(clip.string == "lo wo" && !clip.plain)
        // Through the pasteboard encoding.
        let decoded = try #require(TextClip(decoding: clip.encoded()))
        #expect(decoded == clip)
        let target = try TextFixture.block(&a, "[]", at: Point(x: 0, y: 100))
        let change = try #require(try a.perform(PasteText(node: target, from: TextFixture.at(a, target, 1), to: TextFixture.at(a, target, 1), clip: decoded)))
        #expect(change.label == "Paste")
        let text = TextFixture.text(a, target)
        #expect(text.string == "[lo wo]")
        #expect(Self.has(text.values(at: 1), Self.bold) && Self.has(text.values(at: 2), Self.bold))
        #expect(!Self.has(text.values(at: 3), Self.bold) && !Self.has(text.values(at: 3), TextFixture.size(24)))
        #expect(Self.has(text.values(at: 4), TextFixture.size(24)) && Self.has(text.values(at: 5), TextFixture.size(24)))
        #expect(text.values(at: 6).isEmpty && text.values(at: 0).isEmpty)
    }

    @Test func richTextReplacesTheSelectionAndDoesNotInheritTheLookBefore() throws {
        var a = Replica(1)
        let target = try TextFixture.block(&a, "AAxxBB")
        try a.perform(ApplyMark(node: target, from: TextFixture.at(a, target, 0), to: TextFixture.at(a, target, 2), value: TextFixture.size(40)))
        let file = ImportedTextFile(paragraphs: [
            ExportParagraph([ExportTextRun("one", attributes: ExportTextAttributes(size: 10, bold: true))], style: ExportParagraphStyle(alignment: .center)),
            ExportParagraph([ExportTextRun("two", attributes: ExportTextAttributes(size: 12))]),
        ], plain: false)
        let clip = TextClip(file)
        #expect(clip.string == "one\ntwo" && clip.text.paragraphs.count == 1)
        try a.perform(PasteText(node: target, from: TextFixture.at(a, target, 2), to: TextFixture.at(a, target, 4), clip: clip))
        let text = TextFixture.text(a, target)
        #expect(text.string == "AAone\ntwoBB")
        #expect(TextFixture.sizes(text) == [40, 40, 10, 10, 10, 10, 12, 12, 12, nil, nil])
        #expect(Self.has(text.values(at: 2), Self.bold) && !Self.has(text.values(at: 6), Self.bold))
        // Right after text with a growing mark: the rich text does not take it.
        try a.perform(PasteText(node: target, from: TextFixture.at(a, target, 1), to: TextFixture.at(a, target, 1),
                                clip: TextClip(ImportedTextFile(paragraphs: [ExportParagraph([ExportTextRun("q")])], plain: false))))
        let after = TextFixture.text(a, target)
        #expect(after.string == "AqAone\ntwoBB" && TextFixture.sizes(after)[1] != 40 && TextFixture.sizes(after)[2] == 40)
        // The pasted break brings its paragraph; the last paragraph keeps the one it joined.
        let joined = TextFixture.text(a, target)
        #expect(joined.paragraphs[0].props.alignment == .center && joined.paragraphs[1].props.alignment == .unspecified)
    }

    @Test func plainTextAndMatchStyleTakeTheLookOfTheInsertionPoint() throws {
        var a = Replica(1)
        let paragraph = Wiretuner_Doc_V1_ParagraphProps.with { $0.alignment = .right }
        let target = try TextFixture.block(&a, "ab", paragraph: paragraph)
        try a.perform(ApplyMark(node: target, from: .start, to: .end, value: TextFixture.size(30)))
        try a.perform(PasteText(node: target, from: TextFixture.at(a, target, 1), to: TextFixture.at(a, target, 1), clip: TextClip(plain: "x\r\ny")))
        var text = TextFixture.text(a, target)
        #expect(text.string == "ax\nyb" && TextFixture.sizes(text).allSatisfy { $0 == 30 })
        #expect(text.paragraphs.allSatisfy { $0.props.alignment == .right })
        // Rich text with Match Style: the characters take the look, the breaks copy the paragraph.
        var source = Replica(2)
        let copied = try Self.source(&source)
        let clip = try #require(TextClip(copying: 0..<11, of: copied, in: source.state))
        try a.perform(PasteText(node: target, from: .end, to: .end, clip: clip, matchStyle: true))
        text = TextFixture.text(a, target)
        #expect(text.string == "ax\nybHello world")
        #expect(TextFixture.sizes(text).allSatisfy { $0 == 30 } && !(0..<text.length).contains { Self.has(text.values(at: $0), Self.bold) })
        // A pending format given explicitly.
        try a.perform(PasteText(node: target, from: .start, to: .start, clip: TextClip(plain: "z"), look: [Self.bold]))
        text = TextFixture.text(a, target)
        #expect(text.string.hasPrefix("z") && Self.has(text.values(at: 0), Self.bold))
        #expect(TextClip.look(at: 0, in: text).contains(Self.bold))
        let empty = try TextFixture.block(&a, "", at: Point(x: 0, y: 80))
        #expect(TextClip.look(at: 0, in: TextFixture.text(a, empty)).isEmpty)
        #expect(throws: TextEditError.invalidValue("clip")) { try a.perform(PasteText(node: target, from: .end, to: .end, clip: TextClip(plain: ""))) }
    }

    @Test func inlineGraphicsAreCopiedWithTheText() throws {
        var a = Replica(1)
        let source = try TextFixture.block(&a, "ab")
        let payload = try TextInlineGraphicTests.payload(&a)
        try a.perform(PasteInlineGraphic(node: source, at: TextFixture.at(a, source, 1), payload: payload))
        let clip = try #require(TextClip(copying: 0..<3, of: source, in: a.state))
        #expect(clip.graphics.count == 1)
        let decoded = try #require(TextClip(decoding: clip.encoded()))
        #expect(decoded.graphics.count == 1)
        let target = try TextFixture.block(&a, "", at: Point(x: 0, y: 200))
        try a.perform(PasteText(node: target, from: .end, to: .end, clip: decoded))
        let placements = InlineGraphics.placements(TextFixture.text(a, target))
        #expect(placements.count == 1 && placements[0].offset == 1)
        #expect(a.state.store.placement(placements[0].graphic)?.parent == target)
        #expect(placements[0].graphic != InlineGraphics.placements(TextFixture.text(a, source))[0].graphic)
        // A new block from the clip carries its own copy too.
        let block = try #require(try a.perform(PasteTextBlock(decoded, at: Point(x: 0, y: 400)))?.createdObjects.first { a.state.store.kind($0) == TextFields.kind })
        let copied = InlineGraphics.placements(TextFixture.text(a, block))
        #expect(copied.count == 1 && a.state.store.placement(copied[0].graphic)?.parent == block)
        // Matching the style keeps the graphic (it is content, not formatting).
        let matched = try TextFixture.block(&a, "", at: Point(x: 0, y: 300))
        try a.perform(PasteText(node: matched, from: .end, to: .end, clip: decoded, matchStyle: true))
        let kept = InlineGraphics.placements(TextFixture.text(a, matched))
        #expect(kept.count == 1 && a.state.isLive(kept[0].graphic))
        // Replacing a selection that places a graphic deletes it.
        try a.perform(PasteText(node: matched, from: .start, to: .end, clip: TextClip(plain: "q")))
        #expect(!a.state.isLive(kept[0].graphic) && TextFixture.text(a, matched).string == "q")
    }

    @Test func aNewBlockHoldsTheClipAtThePoint() throws {
        var a = Replica(1)
        let source = try Self.source(&a)
        let clip = try #require(TextClip(copying: 0..<11, of: source, in: a.state))
        let change = try #require(try a.perform(PasteTextBlock(clip, at: Point(x: 40, y: 50))))
        #expect(change.label == "Paste")
        let node = try #require(change.createdObjects.first { a.state.store.kind($0) == TextFields.kind })
        let text = TextFixture.text(a, node)
        #expect(text.string == "Hello world" && text.props.block.autoWidth && text.props.common.transform.tx == 40)
        #expect(Self.has(text.values(at: 0), Self.bold) && Self.has(text.values(at: 8), TextFixture.size(24)))
        // Plain text takes the defaults.
        let plain = try #require(try a.perform(PasteTextBlock(TextClip(plain: "p\nq"), at: .zero, defaults: [TextFixture.size(9)])))
        let block = try #require(plain.createdObjects.first { a.state.store.kind($0) == TextFields.kind })
        #expect(TextFixture.sizes(TextFixture.text(a, block)).allSatisfy { $0 == 9 })
        #expect(throws: TextEditError.invalidValue("clip")) { try a.perform(PasteTextBlock(TextClip(plain: ""), at: .zero)) }
        // Rich external text with a picture run: the picture is left out of the clip.
        let file = ImportedTextFile(paragraphs: [ExportParagraph([ExportTextRun("a"), ExportTextRun("\u{FFFC}"), ExportTextRun("B", attributes: ExportTextAttributes(allCaps: true))])], plain: false)
        #expect(TextClip(file).string == "aB")
        #expect(TextClip(copying: 0..<0, of: source, in: a.state) == nil && TextClip(copying: 0..<1, of: WellKnown.layers, in: a.state) == nil)
        #expect(TextClip(decoding: [0xFF]) == nil && TextClip(decoding: Wire.field(2, [0x08])) == nil && TextClip(decoding: Wire.field(1, [0xFF])) == nil)
        #expect(TextClip(decoding: Wire.field(3, [1])) == nil)
        // A plain clip round-trips; a plain file maps no marks; a copy across a break keeps its paragraph.
        #expect(TextClip(decoding: TextClip(plain: "a").encoded())?.plain == true)
        let plainFile = ImportedTextFile(paragraphs: [ExportParagraph([ExportTextRun("x")]), ExportParagraph([ExportTextRun("y")])], plain: true)
        #expect(TextClip(plainFile).string == "x\ny" && TextClip(plainFile).text.runs.isEmpty && TextClip(plainFile).plain)
        let broken = try TextFixture.block(&a, "one\ntwo", paragraph: .with { $0.alignment = .center })
        #expect(TextClip(copying: 1..<6, of: broken, in: a.state)?.text.paragraphs.map(\.alignment) == [.center])
        #expect(TextClip(decoding: Wire.field(1, []) + Wire.field(9, [1]) + Wire.field(3, [1]))?.plain == true)
    }

    /// Merge test: a paste into a paragraph while another replica types elsewhere in it; both
    /// survive, in place.
    @Test func pasteIntoAParagraphWhileAnotherReplicaTypesElsewhereInIt() throws {
        var pair = Pair()
        let node = try TextFixture.block(&pair.a, "The quick fox")
        pair.sync()
        var source = Replica(3)
        let copied = try Self.source(&source)
        let clip = try #require(TextClip(copying: 0..<5, of: copied, in: source.state))
        // A pastes "Hello" after "The "; B types " jumps" at the end of the same paragraph.
        try pair.a.perform(PasteText(node: node, from: TextFixture.at(pair.a, node, 4), to: TextFixture.at(pair.a, node, 4), clip: clip))
        try pair.b.perform(InsertText(node: node, text: " jumps", at: .end))
        try pair.b.perform(InsertText(node: node, text: "!", at: TextFixture.at(pair.b, node, 3)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        for replica in [pair.a, pair.b] {
            let text = TextFixture.text(replica, node)
            #expect(text.string == "The! Helloquick fox jumps")
            #expect((5..<10).allSatisfy { Self.has(text.values(at: $0), Self.bold) })
            #expect(!Self.has(text.values(at: 10), Self.bold) && !Self.has(text.values(at: 20), Self.bold))
        }
    }
}
