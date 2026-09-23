import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// Text blocks built through the commands, read back through `TextNode`.
enum TextFixture {
    /// Creates a point-text block holding `text` on `replica`; returns the node.
    @discardableResult
    static func block(_ replica: inout Replica, _ text: String = "", at point: Point = .zero,
                      paragraph: Wiretuner_Doc_V1_ParagraphProps = .init()) throws -> OpID {
        let change = try replica.perform(CreateTextBlock(.point(point), text: text, paragraph: paragraph))
        return change!.createdObjects[0]
    }

    static func text(_ replica: Replica, _ node: OpID) -> TextNode {
        TextNode(node, in: replica.state)!
    }

    static func mark(_ build: (inout Wiretuner_Doc_V1_TextMarkValue) -> Void) -> Wiretuner_Doc_V1_TextMarkValue {
        var value = Wiretuner_Doc_V1_TextMarkValue()
        build(&value)
        return value
    }

    static func size(_ size: Double) -> Wiretuner_Doc_V1_TextMarkValue { mark { $0.size = size } }
    static func family(_ name: String) -> Wiretuner_Doc_V1_TextMarkValue { mark { $0.fontFamily = name } }

    static func feature(_ tag: String, _ state: Wiretuner_Doc_V1_FeatureState) -> Wiretuner_Doc_V1_TextMarkValue {
        mark { $0.feature = .with { $0.tag = tag; $0.state = state } }
    }

    /// The anchor before live offset `offset` of `node`.
    static func at(_ replica: Replica, _ node: OpID, _ offset: Int) -> Anchor {
        text(replica, node).anchor(at: offset)
    }

    static func sizes(_ text: TextNode) -> [Double?] {
        (0..<text.length).map { offset in
            text.values(at: offset).compactMap { if case .size(let size)? = $0.value { return size } else { return nil } }.first
        }
    }
}

@Suite struct TextCommandTests {
    // MARK: Creating

    @Test func clickCreatesAnAutoExpandingBlockWithItsFirstCharactersInOneChange() throws {
        var a = Replica(1)
        let change = try a.perform(CreateTextBlock(.point(Point(x: 10, y: 20)), text: "Hi"))!
        #expect(change.label == "Type")
        let node = change.createdObjects[0]
        let text = TextFixture.text(a, node)
        #expect(text.string == "Hi")
        #expect(text.props.block.autoWidth && text.props.block.autoHeight)
        #expect(text.props.common.transform.tx == 10 && text.props.common.transform.ty == 20)
        #expect(a.state.textNode(node)?.length == 2)
        #expect(a.core.undoStack.undoTitle == "Undo Type")
    }

    @Test func dragCreatesAFixedSizeBlock() throws {
        var a = Replica(1)
        let change = try a.perform(CreateTextBlock(.area(Rect(x: 0, y: 0, width: 200, height: 80))))!
        #expect(change.label == "Text Block")
        let text = TextFixture.text(a, change.createdObjects[0])
        #expect(text.string.isEmpty)
        #expect(text.props.block.width == 200 && text.props.block.height == 80)
        #expect(!text.props.block.autoWidth && !text.props.block.autoHeight)
        #expect(!text.props.common.hasTransform)
        #expect(throws: TextEditError.invalidValue("frame")) {
            try a.perform(CreateTextBlock(.area(Rect(x: 0, y: 0, width: 0, height: 10))))
        }
        #expect(throws: TextEditError.invalidValue("frame")) {
            try a.perform(CreateTextBlock(.point(Point(x: .infinity, y: 0))))
        }
    }

    @Test func createdTextTakesThePendingFormatAndTheBlocksParagraph() throws {
        var a = Replica(1)
        var paragraph = Wiretuner_Doc_V1_ParagraphProps()
        paragraph.alignment = .center
        paragraph.tabs = [.with { $0.position = 36 }]   // ignored: tabs are element ops
        let change = try a.perform(CreateTextBlock(.point(.zero), text: "ab\ncd", marks: [TextFixture.size(24)], paragraph: paragraph))!
        let text = TextFixture.text(a, change.createdObjects[0])
        #expect(TextFixture.sizes(text) == [24, 24, 24, 24, 24])
        #expect(text.paragraphs.map(\.props.alignment) == [.center, .center])
        #expect(text.paragraphs.map(\.range) == [0..<3, 3..<5])
        #expect(text.paragraphs[0].terminator == text.chars[2])
        #expect(text.paragraphs.allSatisfy { $0.props.tabs.isEmpty })
    }

    // MARK: Inserting and deleting

    @Test func insertAtAnchors() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "hello")
        try a.perform(InsertText(node: node, text: " world", at: .end))
        try a.perform(InsertText(node: node, text: ">", at: .start))
        let text = TextFixture.text(a, node)
        #expect(text.string == ">hello world")
        // After a character: its offset plus one.
        try a.perform(InsertText(node: node, text: "!", at: Anchor(char: text.chars[5], before: false)))
        #expect(TextFixture.text(a, node).string == ">hello! world")
        #expect(throws: TextEditError.unknownAnchor(Anchor(char: OpID(counter: 999, replica: 9), before: true))) {
            try a.perform(InsertText(node: node, text: "x", at: Anchor(char: OpID(counter: 999, replica: 9), before: true)))
        }
        #expect(throws: TextEditError.notText(WellKnown.layers)) {
            try a.perform(InsertText(node: WellKnown.layers, text: "x", at: .start))
        }
        #expect(try a.perform(InsertText(node: node, text: "", at: .start)) == nil)
    }

    @Test func deleteRangesAcrossInterleavedInserts() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "abc")
        try a.perform(InsertText(node: node, text: "XY", at: TextFixture.at(a, node, 1)))
        #expect(TextFixture.text(a, node).string == "aXYbc")
        let text = TextFixture.text(a, node)
        let change = try a.perform(DeleteText(node: node, from: text.anchor(at: 4), to: text.anchor(at: 0)))!
        #expect(change.label == "Delete text")
        #expect(change.ops.count == 3)   // a | XY | b: three runs of consecutive ids
        #expect(TextFixture.text(a, node).string == "c")
        a.undo()
        #expect(TextFixture.text(a, node).string == "aXYbc")
    }

    @Test func anchorsOfTombstonesAndEdges() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "abc")
        let before = TextFixture.text(a, node)
        let b = before.chars[1]
        try a.perform(DeleteText(node: node, from: before.anchor(at: 1), to: before.anchor(at: 2)))
        let text = TextFixture.text(a, node)
        #expect(try text.offset(of: Anchor(char: b, before: true)) == 1)
        #expect(try text.offset(of: Anchor(char: b, before: false)) == 1)
        #expect(try text.offset(of: .start) == 0 && (try text.offset(of: .end)) == 2)
        #expect(text.anchor(at: -1) == Anchor(char: text.chars[0], before: true))
        #expect(text.anchor(at: 2) == .end)
        #expect(try text.range(.end, .start) == 0..<2)
        #expect(text.scalar(at: 1) == "c" && text.scalar(at: 5) == nil)
        let empty = try TextFixture.block(&a)
        #expect(TextFixture.text(a, empty).anchor(at: 0) == .end)
        #expect(TextFixture.text(a, empty).paragraphs.count == 1)
    }

    // MARK: Undo grouping of typing

    /// Types `string` one keystroke at a time at the end of `node`, `pause` seconds apart.
    static func type(_ string: String, into node: OpID, _ core: inout DocumentCore, clock: TestClock, pause: TimeInterval = 0.1) throws {
        for character in string {
            clock.advance(pause)
            let command = InsertText(node: node, text: String(character), at: .end, typing: true)
            _ = try core.perform(command, recording: DocumentCore.Recording(limit: 100, now: clock.now))
        }
    }

    static func core(_ text: String = "") throws -> (DocumentCore, OpID, TestClock) {
        var core = DocumentCore(state: EngineState(), replica: 1)
        let clock = TestClock()
        let outcome = try core.perform(CreateTextBlock(.point(.zero), text: text), recording: DocumentCore.Recording(limit: 100, now: clock.now))
        return (core, outcome!.change!.createdObjects[0], clock)
    }

    static func string(_ core: DocumentCore, _ node: OpID) -> String {
        TextNode(node, in: core.state)!.string
    }

    @Test func typingHelloWorldIsTwoUndoSteps() throws {
        var (core, node, clock) = try Self.core()
        let before = core.undoStack.undo.count
        try Self.type("hello world", into: node, &core, clock: clock)
        #expect(core.undoStack.undo.count == before + 2)
        #expect(core.undoStack.undoTitle == "Undo Type")
        _ = core.undo(recording: DocumentCore.Recording(limit: 100, now: clock.now))
        #expect(Self.string(core, node) == "hello ")
        _ = core.undo(recording: DocumentCore.Recording(limit: 100, now: clock.now))
        #expect(Self.string(core, node).isEmpty)
    }

    @Test func aPauseMidWordSplitsTheGroup() throws {
        var (core, node, clock) = try Self.core()
        let before = core.undoStack.undo.count
        try Self.type("hel", into: node, &core, clock: clock)
        try Self.type("l", into: node, &core, clock: clock, pause: 1.5)
        try Self.type("o", into: node, &core, clock: clock)
        #expect(core.undoStack.undo.count == before + 2)
        _ = core.undo(recording: DocumentCore.Recording(limit: 100, now: clock.now))
        #expect(Self.string(core, node) == "hel")
    }

    @Test func movingTheCaretReturnAndPastesStartNewSteps() throws {
        var (core, node, clock) = try Self.core()
        let before = core.undoStack.undo.count
        try Self.type("ab", into: node, &core, clock: clock)
        // The caret moved to the start.
        _ = try core.perform(InsertText(node: node, text: "x", at: .start, typing: true), recording: .init(limit: 100, now: clock.now))
        // Whitespace after whitespace stays in the word's step; Return is a step of its own.
        try Self.type("  ", into: node, &core, clock: clock)
        try Self.type("\n", into: node, &core, clock: clock)
        try Self.type("c", into: node, &core, clock: clock)
        // A committed string of several characters is its own step.
        _ = try core.perform(InsertText(node: node, text: "de", at: .end, typing: true), recording: .init(limit: 100, now: clock.now))
        #expect(Self.string(core, node) == "xab  \ncde")
        #expect(core.undoStack.undo.count == before + 6)   // ab, x, "  ", \n, c, de
    }

    @Test func backspaceRunsGroupSeparatelyFromTyping() throws {
        var (core, node, clock) = try Self.core()
        let before = core.undoStack.undo.count
        try Self.type("abc", into: node, &core, clock: clock)
        for _ in 0..<2 {
            clock.advance(0.1)
            let text = TextNode(node, in: core.state)!
            let last = text.chars[text.length - 1]
            _ = try core.perform(DeleteText(node: node, from: Anchor(char: last, before: true), to: .end, backspace: true),
                                 recording: .init(limit: 100, now: clock.now))
        }
        #expect(Self.string(core, node) == "a")
        #expect(core.undoStack.undo.count == before + 2)
        #expect(core.undoStack.undoTitle == "Undo Delete text")
        _ = core.undo(recording: .init(limit: 100, now: clock.now))
        #expect(Self.string(core, node) == "abc")
        // A backspace of the first character closes at the start; one of two characters is not a keystroke.
        clock.advance(0.1)
        _ = try core.perform(DeleteText(node: node, from: .start, to: TextNode(node, in: core.state)!.anchor(at: 2), backspace: true),
                             recording: .init(limit: 100, now: clock.now))
        clock.advance(0.1)
        _ = try core.perform(DeleteText(node: node, from: .start, to: TextNode(node, in: core.state)!.anchor(at: 1), backspace: true),
                             recording: .init(limit: 100, now: clock.now))
        #expect(Self.string(core, node).isEmpty)
    }

    @Test func typingInsideAGroupJoinsTheGroup() throws {
        var (core, node, clock) = try Self.core()
        let before = core.undoStack.undo.count
        _ = try core.perform(InsertText(node: node, text: "a", at: .end, typing: true), recording: .init(group: 7, limit: 100, now: clock.now))
        _ = try core.perform(InsertText(node: node, text: " ", at: .end, typing: true), recording: .init(group: 7, limit: 100, now: clock.now))
        _ = try core.perform(InsertText(node: node, text: "b", at: .end, typing: true), recording: .init(group: 7, limit: 100, now: clock.now))
        #expect(core.undoStack.undo.count == before + 1)
    }

    // MARK: Paragraphs

    @Test func returnCopiesTheTerminatorsPropertiesExplicitly() throws {
        var a = Replica(1)
        var paragraph = Wiretuner_Doc_V1_ParagraphProps()
        paragraph.alignment = .right
        paragraph.leftIndent = 12
        paragraph.hyphenation.enabled = true
        let node = try TextFixture.block(&a, "abcd", paragraph: paragraph)
        // A tab stop on the tail paragraph (a SEQUENCE element).
        var tabs = Wiretuner_Doc_V1_NodeProps()
        tabs.text.tailParagraph.tabs = [.with { $0.kind = .right; $0.position = 72; $0.leader = "." }]
        try a.perform(OpsCommand("Tab", ops: [Ops.elementInsert(node, TextFields.tailParagraph.child(9), positions: [[0x80]], values: tabs)]))
        let change = try a.perform(SplitParagraph(node: node, at: TextFixture.at(a, node, 2)))!
        #expect(change.label == "Type")
        let text = TextFixture.text(a, node)
        #expect(text.string == "ab\ncd")
        let newline = text.chars[2]
        #expect(a.state.register(node, TextFields.paragraph(newline).child(1))?.isSet == true)
        #expect(text.paragraphs[0].props.alignment == .right)
        #expect(text.paragraphs[0].props.leftIndent == 12)
        #expect(text.paragraphs[0].props.hyphenation.enabled)
        #expect(text.paragraphs[0].props.tabs.map(\.position) == [72])
        #expect(text.paragraphs[0].props.tabs.map(\.leader) == ["."])
        // Splitting the first paragraph again copies the newline's registers and tabs.
        try a.perform(SplitParagraph(node: node, at: TextFixture.at(a, node, 1)))
        let again = TextFixture.text(a, node)
        #expect(again.paragraphs.map(\.props.alignment) == [.right, .right, .right])
        #expect(again.paragraphs[0].props.tabs.map(\.position) == [72])
        #expect(again.paragraphIndex(at: 2) == 1 && again.paragraphIndex(at: 99) == 2)
    }

    @Test func returnCopiesEveryParagraphRegister() throws {
        var a = Replica(1)
        var paragraph = Wiretuner_Doc_V1_ParagraphProps()
        paragraph.alignment = .justified
        paragraph.raggedWidth = 80
        paragraph.flushZone = 50
        paragraph.leftIndent = 1
        paragraph.rightIndent = 2
        paragraph.firstLineIndent = 3
        paragraph.spaceAbove = 4
        paragraph.spaceBelow = 5
        paragraph.hyphenation.language = "en"
        paragraph.rule.widthPercent = 50
        paragraph.hangPunctuation = true
        paragraph.keepLines = 2
        paragraph.keepWithNext = true
        paragraph.wordSpacing = .with { $0.opt = 100 }
        paragraph.letterSpacing = .with { $0.max = 5 }
        paragraph.style = .with { $0.id = OpID(counter: 5, replica: 5).proto }
        let node = try TextFixture.block(&a, "abcd", paragraph: paragraph)
        try a.perform(SplitParagraph(node: node, at: TextFixture.at(a, node, 2)))
        let text = TextFixture.text(a, node)
        #expect(text.paragraphs[0].props == paragraph)
        #expect(text.paragraphs[1].props == paragraph)
    }

    @Test func theKeyedUndoOverloadAndTheClosingOne() {
        let stack = UndoStack()
        let key = CoalesceKey.text(TextEditKey(node: OpID(counter: 1, replica: 1), kind: .typing, caret: .zero))
        let inverse = Inverse(steps: [.created(node: OpID(counter: 1, replica: 1))])
        guard case .push(let entry, _)? = stack.recording(inverse, label: "Type", key: key, stillOpen: false, now: Date(), limit: 10) else {
            Issue.record("push"); return
        }
        #expect(entry.openKey == nil)
    }

    @Test func joinKeepsTheSurvivingTerminator() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "ab\ncd")
        let text = TextFixture.text(a, node)
        var props = Wiretuner_Doc_V1_ParagraphProps()
        props.alignment = .center
        try a.perform(SetParagraph(node: node, from: text.anchor(at: 0), to: text.anchor(at: 0), props: props, fields: [[1]]))
        #expect(TextFixture.text(a, node).paragraphs.map(\.props.alignment) == [.center, .unspecified])
        let change = try a.perform(JoinParagraph(node: node, at: TextFixture.at(a, node, 1)))!
        #expect(change.label == "Delete text")
        let joined = TextFixture.text(a, node)
        #expect(joined.string == "abcd")
        #expect(joined.paragraphs.map(\.props.alignment) == [.unspecified])
        #expect(try a.perform(JoinParagraph(node: node, at: .end)) == nil)
    }

    @Test func setParagraphWritesEveryParagraphTheRangeTouches() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "ab\ncd\nef")
        let text = TextFixture.text(a, node)
        var props = Wiretuner_Doc_V1_ParagraphProps()
        props.alignment = .justified
        props.hyphenation.consecutive = 2
        let change = try a.perform(SetParagraph(node: node, from: text.anchor(at: 4), to: .end, props: props, fields: [[1], [10, 3]]))!
        #expect(change.ops.count == 2)
        let after = TextFixture.text(a, node)
        #expect(after.paragraphs.map(\.props.alignment) == [.unspecified, .justified, .justified])
        #expect(after.paragraphs[2].props.hyphenation.consecutive == 2)
        #expect(after.paragraphs(touching: 1..<1).count == 1)
        #expect(throws: TextEditError.invalidValue("fields")) {
            try a.perform(SetParagraph(node: node, from: .start, to: .end, props: props, fields: [[9]]))
        }
        #expect(throws: TextEditError.invalidValue("fields")) {
            try a.perform(SetParagraph(node: node, from: .start, to: .end, props: props, fields: []))
        }
    }

    // MARK: Marks

    @Test func expandingMarksGrowAtTheirEndOnly() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "abcd")
        let text = TextFixture.text(a, node)
        let change = try a.perform(ApplyMark(node: node, from: text.anchor(at: 1), to: text.anchor(at: 3), value: TextFixture.size(30)))!
        #expect(change.label == "Size")
        #expect(TextFixture.sizes(TextFixture.text(a, node)) == [nil, 30, 30, nil])
        // Typing at the end of the span extends it; at its start it does not.
        try a.perform(InsertText(node: node, text: "X", at: TextFixture.at(a, node, 3)))
        try a.perform(InsertText(node: node, text: "Y", at: TextFixture.at(a, node, 1)))
        #expect(TextFixture.text(a, node).string == "aYbcXd")
        #expect(TextFixture.sizes(TextFixture.text(a, node)) == [nil, nil, 30, 30, 30, nil])
        // A mark reaching the end of the text grows with typing at the end.
        try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, 5), to: .end, value: TextFixture.family("Menlo")))
        try a.perform(InsertText(node: node, text: "Z", at: .end))
        #expect(TextFixture.text(a, node).values(at: 6).contains(TextFixture.family("Menlo")))
    }

    @Test func linksNeverGrowAndRemovingClearsTheAttribute() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "abcd")
        let link = TextFixture.mark { $0.link = "https://example.com" }
        try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, 1), to: TextFixture.at(a, node, 3), value: link))
        try a.perform(InsertText(node: node, text: "X", at: TextFixture.at(a, node, 3)))
        let text = TextFixture.text(a, node)
        #expect((0..<text.length).map { text.values(at: $0).contains(link) } == [false, true, true, false, false])
        try a.perform(ApplyMark.remove(node: node, from: .start, to: .end, attribute: link))
        #expect(TextFixture.text(a, node).runs.allSatisfy { $0.values.isEmpty })
        // An empty range is the tool's pending format: nothing is written.
        #expect(try a.perform(ApplyMark(node: node, from: .start, to: .start, value: link)) == nil)
        #expect(throws: TextEditError.invalidValue("value")) {
            try a.perform(ApplyMark(node: node, from: .start, to: .end, value: .init()))
        }
    }

    @Test func featureMarksStackByTagAndResetReadsAsNoMark() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "abcd")
        try a.perform(ApplyMark(node: node, from: .start, to: .end, value: TextFixture.feature("liga", .on)))
        try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, 2), to: .end, value: TextFixture.feature("ss03", .on)))
        #expect(TextFixture.text(a, node).values(at: 3) == [TextFixture.feature("liga", .on), TextFixture.feature("ss03", .on)])
        try a.perform(ApplyMark.remove(node: node, from: .start, to: TextFixture.at(a, node, 3), attribute: TextFixture.feature("liga", .on)))
        let text = TextFixture.text(a, node)
        #expect(text.values(at: 0).isEmpty)
        #expect(text.values(at: 2) == [TextFixture.feature("ss03", .on)])
        #expect(text.values(at: 3) == [TextFixture.feature("liga", .on), TextFixture.feature("ss03", .on)])
        #expect(text.values(at: 9).isEmpty)
    }

    @Test func markValueTables() {
        let values: [Wiretuner_Doc_V1_TextMarkValue] = [
            TextFixture.family("A"), TextFixture.mark { $0.fontStyle = "Bold" }, TextFixture.size(9),
            TextFixture.mark { $0.leading = .with { $0.mode = .fixed; $0.value = 14 } }, TextFixture.mark { $0.kerning = 5 },
            TextFixture.mark { $0.rangeKerning = 5 }, TextFixture.mark { $0.baselineShift = 2 }, TextFixture.mark { $0.horizontalScale = 90 },
            TextFixture.mark { $0.fill = .with { $0.inline = .init() } }, TextFixture.mark { $0.stroke.width = 1 },
            TextFixture.mark { $0.effect = .init() }, TextFixture.mark { $0.style = .with { $0.id = OpID(counter: 3, replica: 1).proto } },
            TextFixture.mark { $0.language = "en" }, TextFixture.mark { $0.noBreak = true }, TextFixture.mark { $0.case = .smallCaps },
            TextFixture.mark { $0.inlineGraphic = .init() }, TextFixture.mark { $0.overprint = true }, TextFixture.mark { $0.noHyphen = true },
            TextFixture.mark { $0.axes.axes = [.with { $0.tag = "wght"; $0.value = 700 }] }, TextFixture.feature("liga", .off),
            TextFixture.mark { $0.link = "x" }, TextFixture.mark { $0.field = .init() }, TextFixture.mark { $0.mention = "a" },
        ]
        let labels = values.map(TextMarks.label)
        #expect(Set(labels).count == values.count)
        #expect(TextMarks.label(.init()) == "Format")
        #expect(values.filter { !TextMarks.expands($0) }.count == 7)
        for value in values {
            let cleared = TextMarks.cleared(value)
            #expect(cleared.value != nil)
            #expect(TextMarks.label(cleared) == TextMarks.label(value))
        }
        #expect(TextMarks.cleared(TextFixture.feature("liga", .off)) == TextFixture.mark { $0.feature = .with { $0.tag = "liga" } })
        #expect(TextMarks.cleared(.init()).value == nil)
    }

    // MARK: Block

    @Test func setTextBlockWritesOnlyTheNamedFields() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "ab")
        var block = Wiretuner_Doc_V1_TextBlockProps()
        block.width = 150
        block.inset.left = 4
        try a.perform(SetTextBlock(node: node, block: block, fields: [[3], [1], [5, 1]]))
        let text = TextFixture.text(a, node)
        #expect(text.props.block.width == 150 && !text.props.block.autoWidth && text.props.block.autoHeight)
        #expect(text.props.block.inset.left == 4)
        #expect(throws: TextEditError.notText(WellKnown.layers)) {
            try a.perform(SetTextBlock(node: WellKnown.layers, block: block, fields: [[3]]))
        }
        #expect(throws: TextEditError.invalidValue("fields")) {
            try a.perform(SetTextBlock(node: node, block: block, fields: [[]]))
        }
    }
}
