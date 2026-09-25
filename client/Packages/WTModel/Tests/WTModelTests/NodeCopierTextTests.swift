import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Copies one tree under `parent` through `NodeCopier`.
private struct CopyTree: Command {
    var tree: NodeTree
    var parent: OpID
    var label: String { "Copy" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try NodeCopier.create(tree, parent: parent, position: [0x80], schema: state.schema, builder: &builder)
    }
}

/// Copies of text (copying.adoc, "Data model"): `NodeCopier` writes every TEXT field a tree
/// carries -- characters, marks (links, styles, placeholders, inline graphics), paragraph
/// registers and tab stops -- and rewrites inline graphics and flow links to the copies, through
/// every copy path.
@Suite struct NodeCopierTextTests {
    /// A text block as read, for comparing a copy with its source: the string, the winning runs
    /// (an inline graphic's node left out), the paragraphs (tab ids left out) and the inline
    /// graphics' kinds.
    struct Look: Equatable {
        var string: String
        var runs: [TextMarkRun]
        var paragraphs: [Wiretuner_Doc_V1_ParagraphProps]
        var graphics: [NodeKind?]
    }

    static func look(_ state: EngineState, _ node: OpID) -> Look? {
        guard let text = TextNode(node, in: state) else { return nil }
        let runs = text.runs.map { run in
            TextMarkRun(range: run.range, values: run.values.map { value in
                guard case .inlineGraphic? = value.value else { return value }
                var cleared = value
                cleared.inlineGraphic = .init()
                return cleared
            })
        }
        let paragraphs = text.paragraphs.map { paragraph in
            var props = paragraph.props
            for index in props.tabs.indices { props.tabs[index].clearID() }
            return props
        }
        return Look(string: text.string, runs: runs, paragraphs: paragraphs,
                    graphics: InlineGraphics.placements(text).map { state.nodeKind($0.graphic) })
    }

    /// Whether every inline graphic of `node` is a live child of it.
    static func graphicsAreOwnChildren(_ state: EngineState, _ node: OpID) -> Bool {
        guard let text = TextNode(node, in: state) else { return false }
        let placements = InlineGraphics.placements(text)
        return !placements.isEmpty && placements.allSatisfy { state.isLive($0.graphic) && state.store.placement($0.graphic)?.parent == node }
    }

    /// A styled, linked, multi-paragraph block with a character style, a data placeholder, a tab
    /// stop, paragraph settings (the tail's too) and an inline graphic:
    /// "Hello world\nSecond ␣line\nEnd{{name}}".
    static func styledBlock(_ a: inout Replica, placeholder: Bool = true) throws -> OpID {
        let node = try #require(try a.perform(CreateTextBlock(.area(Rect(x: 0, y: 0, width: 200, height: 120)),
                                                              text: "Hello world\nSecond line\nEnd"))).createdObjects[0]
        func at(_ offset: Int) -> Anchor { TextFixture.at(a, node, offset) }
        try a.perform(ApplyMark(node: node, from: at(0), to: at(5), value: TextFixture.size(24)))
        try a.perform(ApplyMark(node: node, from: at(6), to: at(11), value: TextFixture.mark { $0.link = "https://example.com" }))
        try a.perform(ApplyMark(node: node, from: at(0), to: at(20), value: TextFixture.family("Menlo")))
        try a.perform(ApplyMark(node: node, from: at(3), to: at(4), value: TextFixture.mark { $0.kerning = 20 }))
        try a.perform(ApplyMark(node: node, from: at(4), to: at(5), value: TextFixture.mark { $0.kerning = 20 }))
        let style = try TextStyleTests.style(&a, .character, name: "Em") { $0.character.size = 9 }
        try a.perform(ApplyCharacterStyle(node: node, from: at(12), to: at(18), style: style))
        try a.perform(SetParagraph(node: node, from: .start, to: .start, props: .with { $0.alignment = .center; $0.leftIndent = 4 }, fields: [[1], [4]]))
        let second = try #require(TextNode(node, in: a.state)?.paragraphs[1].terminator)
        try a.perform(OpsCommand("Tabs", ops: [Ops.elementInsert(node, TextFields.paragraph(second).child(9), positions: [[0x80]],
                                                                 values: TextEditing.paragraphValues(.with { $0.tabs = [.with { $0.position = 36 }] }, newline: true))]))
        try a.perform(SetParagraph(node: node, from: .end, to: .end, props: .with { $0.spaceAbove = 6 }, fields: [[7]]))
        let rect = try #require(try a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 20),
                                                          transform: .translation(x: 300, y: 300)))).createdObjects[0]
        try a.perform(PasteInlineGraphic(node: node, at: at(18), payload: ClipboardPayload(copying: [rect], from: a.state)))
        if placeholder {
            let fields = try DataFixture.fields(&a, ["name"])
            try a.perform(InsertPlaceholder(node: node, at: .end, field: fields[0]))
        }
        return node
    }

    static func checkCopy(_ copy: OpID, in state: EngineState, of source: OpID, in sourceState: EngineState,
                          sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(copy != source, sourceLocation: sourceLocation)
        let expected = look(sourceState, source)
        #expect(expected?.string.isEmpty == false, sourceLocation: sourceLocation)
        #expect(look(state, copy) == expected, sourceLocation: sourceLocation)
        #expect(graphicsAreOwnChildren(state, copy), "the inline graphic names the copy's own child", sourceLocation: sourceLocation)
    }

    // MARK: Copy paths

    @Test func pasteInTheSameDocumentAndInFrontKeepTheText() throws {
        var a = Replica(0xA)
        let node = try Self.styledBlock(&a)
        let payload = ClipboardPayload(copying: [node], from: a.state)
        let copy = try #require(try a.perform(Paste(payload))).createdRoots[0]
        Self.checkCopy(copy, in: a.state, of: node, in: a.state)
        let inFront = try #require(try a.perform(Paste(payload, placement: .inFront(of: node)))).createdRoots[0]
        Self.checkCopy(inFront, in: a.state, of: node, in: a.state)
        // The copy is independent: typing into the source leaves it alone.
        try a.perform(InsertText(node: node, text: "X", at: .start))
        #expect(TextNode(copy, in: a.state)?.string.hasPrefix("Hello") == true)
    }

    @Test func dragBetweenDocumentsCarriesTheTextOnThePasteboard() throws {
        var a = Replica(0xA)
        let node = try Self.styledBlock(&a)
        let payload = ClipboardPayload(copying: [node], from: a.state, document: "one")
        #expect(payload.nodes[0].text?.string == TextNode(node, in: a.state)?.string)
        let decoded = try #require(ClipboardPayload(decoding: payload.encoded()))
        #expect(decoded == payload)
        var b = Replica(0xB)
        let copy = try #require(try b.perform(Paste(decoded, placement: .top(layer: nil, center: Point(x: 50, y: 50))))).createdRoots[0]
        Self.checkCopy(copy, in: b.state, of: node, in: a.state)
    }

    @Test func duplicateCloneAndOptionDragKeepTheText() throws {
        var a = Replica(0xA)
        let node = try Self.styledBlock(&a)
        for command in [DuplicateObjects.duplicate([node]), DuplicateObjects.clone([node]),
                        DuplicateObjects([node], offset: .translation(x: 40, y: 0), label: "Copy")] {
            let copy = try #require(try a.perform(command)).createdRoots[0]
            Self.checkCopy(copy, in: a.state, of: node, in: a.state)
        }
    }

    @Test func pasteContentsKeepsTheText() throws {
        var a = Replica(0xA)
        let node = try Self.styledBlock(&a)
        let frame = try LayerFixture.object(PathFixture.closed([(0, 0), (300, 0), (300, 300), (0, 300)]), on: &a)
        let change = try #require(try a.perform(PasteContents(ClipboardPayload(copying: [node], from: a.state), into: frame)))
        let copy = try #require(change.createdNodes.first { a.state.nodeKind($0) == .text && Objects.parent(of: $0, in: a.state) != nil
            && a.state.store.placement($0)?.parent != node })
        Self.checkCopy(copy, in: a.state, of: node, in: a.state)
    }

    @Test func releaseCopiesTheMastersTextOrTheOverride() throws {
        var a = Replica(0xA)
        let node = try Self.styledBlock(&a, placeholder: false)
        let converted = try #require(try a.perform(ConvertToSymbol([node])))
        let (symbol, instance) = (converted.createdNodes[0], converted.createdNodes[1])
        let other = try #require(try a.perform(PlaceInstance(symbol, at: Point(x: 300, y: 0)))).createdObjects[0]
        try a.perform(OverrideText(other, master: node, edit: .insert("Big ", at: 0)))
        let release = try #require(try a.perform(ReleaseInstances([instance, other])))
        let groups = release.createdObjects.filter { a.state.nodeKind($0) == .group }
        #expect(groups.count == 2)
        let plain = try #require(a.state.liveChildren(groups[0]).first { a.state.nodeKind($0) == .text })
        Self.checkCopy(plain, in: a.state, of: node, in: a.state)
        let overridden = try #require(a.state.liveChildren(groups[1]).first { a.state.nodeKind($0) == .text })
        let text = try #require(TextNode(overridden, in: a.state))
        #expect(text.string == "Big " + TextNode(node, in: a.state)!.string)
        #expect(TextFixture.sizes(text)[4] == 24)
        #expect(Self.graphicsAreOwnChildren(a.state, overridden))
    }

    @Test func copiesOfAnInstanceKeepItsTextOverride() throws {
        var a = Replica(0xA)
        let label = try TextFixture.block(&a, "Label")
        let converted = try #require(try a.perform(ConvertToSymbol([label])))
        let instance = converted.createdNodes[1]
        try a.perform(OverrideText(instance, master: label, edit: .insert("My ", at: 0)))
        let copy = try #require(try a.perform(DuplicateObjects.duplicate([instance]))).createdRoots[0]
        #expect(Symbols.resolvedArtwork(of: copy, in: a.state)?.texts[label]?.string == "My Label")
        var b = Replica(0xB)
        _ = try TextFixture.block(&b, "unrelated")
        let decoded = try #require(ClipboardPayload(decoding: ClipboardPayload(copying: [instance], from: a.state).encoded()))
        #expect(decoded.nodes[0].texts.count == 1)
    }

    @Test func mergeToPagesCopiesKeepTheirMarksAndGraphics() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        let node = try Self.styledBlock(&a)
        let set = RecordSet(model: DataModel(a.state), source: nil, raw: [DataRecord(["name": "Ann"])])
        try a.perform(MergeToPages(templates: [page], records: set, indices: [0]))
        let copy = try #require(DataBindings.liveNodes(in: a.state).first {
            a.state.store.kind($0) == TextFields.kind && $0 != node && TextNode($0, in: a.state)?.string.hasSuffix("EndAnn") == true
        })
        let text = try #require(TextNode(copy, in: a.state))
        let source = try #require(Self.look(a.state, node))
        #expect(TextFixture.sizes(text)[0] == 24)
        #expect(text.runs.contains { $0.values.contains { $0.link == "https://example.com" } })
        #expect(Self.look(a.state, copy)?.paragraphs.dropLast() == source.paragraphs.dropLast())
        #expect(Self.graphicsAreOwnChildren(a.state, copy), "merged copies draw their own inline graphic")
    }

    // MARK: References

    @Test func flowLinksFollowTheCopiedBlocksAndDropTheRest() throws {
        var a = Replica(0xA)
        let blocks = try (0..<3).map { index in try TextFixture.block(&a, "b\(index)", at: Point(x: Double(index) * 100, y: 0)) }
        var ops: [Wiretuner_Doc_V1_Op] = []
        for index in 0..<2 {
            var next = Wiretuner_Doc_V1_NodeProps()
            next.text.nextLink.id = blocks[index + 1].proto
            var prev = Wiretuner_Doc_V1_NodeProps()
            prev.text.prevLink.id = blocks[index].proto
            ops += [Ops.set(blocks[index], [RegisterPath([130, 4])], values: next), Ops.set(blocks[index + 1], [RegisterPath([130, 5])], values: prev)]
        }
        try a.perform(OpsCommand("Link", ops: ops))
        let copies = try #require(try a.perform(DuplicateObjects.duplicate([blocks[0], blocks[1]]))).createdRoots
        #expect(copies.count == 2)
        let first = a.state.props(copies[0]).text
        let second = a.state.props(copies[1]).text
        #expect(OpID(first.nextLink.id) == copies[1] && !first.hasPrevLink)
        #expect(OpID(second.prevLink.id) == copies[0] && !second.hasNextLink, "a link to a block left behind is unset")
        #expect(TextNode(copies[0], in: a.state)?.string == "b0")
        // One member alone: no links at all.
        let alone = try #require(try a.perform(DuplicateObjects.clone([blocks[1]]))).createdRoots[0]
        #expect(!a.state.props(alone).text.hasNextLink && !a.state.props(alone).text.hasPrevLink)
    }

    @Test func textOnAPathKeepsItsPathAndText() throws {
        var a = Replica(0xA)
        let text = try TextFixture.block(&a, "Around")
        try a.perform(ApplyMark(node: text, from: TextFixture.at(a, text, 0), to: TextFixture.at(a, text, 3), value: TextFixture.size(30)))
        let path = try LayerFixture.object(PathFixture.open([(0, 0), (100, 50), (200, 0)]), on: &a)
        try a.perform(AttachTextToPath(text: text, path: path))
        let copy = try #require(try a.perform(DuplicateObjects.duplicate([text]))).createdRoots[0]
        #expect(Self.look(a.state, copy) == Self.look(a.state, text))
        #expect(a.state.props(copy).text.onPath == a.state.props(text).text.onPath)
        let children = a.state.liveChildren(copy)
        #expect(children.count == 1 && a.state.nodeKind(children[0]) == .path && children[0] != path)
    }

    @Test func anInlineGraphicOutsideTheCopyIsLeftUnset() throws {
        var a = Replica(0xA)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.text.block.autoWidth = true
        var graphic = Wiretuner_Doc_V1_TextMarkValue()
        graphic.inlineGraphic.id = OpID(counter: 77, replica: 9).proto
        let tree = NodeTree(props: props, texts: [
            TextFields.text: CopiedText(string: "a\u{FFFC}", runs: [TextMarkRun(range: 1..<2, values: [graphic])]),
            // A text inside an element that was not copied is left behind.
            SymbolFields.overrideText(OpID(counter: 5, replica: 5)): CopiedText(string: "lost"),
        ])
        let layer = try LayerFixture.layers(["L"], on: &a)[0]
        let change = try #require(try a.perform(CopyTree(tree: tree, parent: layer)))
        let copy = change.createdNodes[0]
        let text = try #require(TextNode(copy, in: a.state))
        #expect(text.string == "a\u{FFFC}")
        #expect(InlineGraphics.placements(text).isEmpty, "the reference is unset: the placeholder draws the empty box")
        #expect(a.state.store.textPaths(copy) == [TextFields.text])
    }

    @Test func longTextIsInsertedInChunks() throws {
        var a = Replica(0xA)
        let long = String(repeating: "abcdefgh", count: 2_500) + "\n" + String(repeating: "z", count: 100)
        let node = try TextFixture.block(&a, long)
        try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, 10), to: TextFixture.at(a, node, 19_000), value: TextFixture.size(7)))
        let change = try #require(try a.perform(DuplicateObjects.clone([node])))
        #expect(change.ops.filter { if case .textInsert? = $0.op { true } else { false } }.count == 2)
        #expect(Self.look(a.state, change.createdRoots[0]) == Self.look(a.state, node))
    }

    // MARK: Pasteboard encoding

    @Test func thePasteboardTextSkipsWhatDoesNotRead() throws {
        var rich = Wiretuner_Doc_V1_RichText()
        for (index, scalar) in ["a", "b", "\n", "c"].enumerated() {
            var char = Wiretuner_Doc_V1_TextChar()
            char.id = OpID(counter: UInt64(index + 1), replica: 0).elementID
            char.codepoint = Unicode.Scalar(scalar)!.value
            char.deleted = index == 1
            if scalar == "\n" { char.paragraph.alignment = .right }
            rich.chars.append(char)
        }
        var invalid = Wiretuner_Doc_V1_TextChar()
        invalid.codepoint = 0xD800
        rich.chars.append(invalid)
        func mark(_ start: (UInt64, Bool), _ end: (UInt64, Bool), size: Double? = 5) -> Wiretuner_Doc_V1_RichTextMark {
            var mark = Wiretuner_Doc_V1_RichTextMark()
            mark.start.char = OpID(counter: start.0, replica: 0).elementID
            mark.start.before = start.1
            mark.end.char = OpID(counter: end.0, replica: 0).elementID
            mark.end.before = end.1
            if let size { mark.value.size = size }
            return mark
        }
        rich.marks = [mark((0, true), (0, false)), mark((1, true), (9, false)), mark((4, true), (1, true)), mark((1, true), (3, false), size: nil)]
        let content = CopiedText(rich)
        #expect(content.string == "a\nc")
        #expect(content.paragraphs.map(\.alignment) == [.right])
        #expect(content.runs == [TextMarkRun(range: 0..<3, values: [TextFixture.size(5)])])
        // A text record whose path does not read is left out; the node still decodes.
        let props = Wire.field(1, Wire.bytes { try Wiretuner_Doc_V1_NodeProps.with { $0.text.block.width = 3 }.serializedBytes() })
        let node = props + Wire.field(5, Wire.field(1, [0xFF]))
        let payload = try #require(ClipboardPayload(decoding: Wire.field(1, node)))
        #expect(payload.nodes[0].texts.isEmpty && payload.nodes[0].props.text.block.width == 3)
        #expect(NodeCopier.wrapped(RegisterPath(segments: [.element(OpID(counter: 1, replica: 1))]), [1]) == [1])
    }

    // MARK: Merge

    @Test func aCopyRacingAnEditOfItsSourceConverges() throws {
        var pair = Pair()
        let node = try Self.styledBlock(&pair.a, placeholder: false)
        pair.sync()
        let before = try #require(Self.look(pair.a.state, node))
        // A duplicates the block while B edits the source's text, marks and paragraphs.
        let copy = try #require(try pair.a.perform(DuplicateObjects.duplicate([node]))).createdRoots[0]
        try pair.b.perform(InsertText(node: node, text: "New ", at: .start))
        try pair.b.perform(ApplyMark(node: node, from: TextFixture.at(pair.b, node, 0), to: TextFixture.at(pair.b, node, 3), value: TextFixture.size(40)))
        try pair.b.perform(SetParagraph(node: node, from: .start, to: .start, props: .with { $0.alignment = .right }, fields: [[1]]))
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(Self.look(replica.state, copy) == before, "the copy holds the text as copied")
            #expect(Self.graphicsAreOwnChildren(replica.state, copy))
            #expect(TextNode(node, in: replica.state)?.string.hasPrefix("New Hello") == true)
            #expect(TextNode(node, in: replica.state)?.paragraphs[0].props.alignment == .right)
        }
        #expect(Self.look(pair.a.state, node) == Self.look(pair.b.state, node))
        #expect(Self.look(pair.a.state, copy) == Self.look(pair.b.state, copy))
    }
}
