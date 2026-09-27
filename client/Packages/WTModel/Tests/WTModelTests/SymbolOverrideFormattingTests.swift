import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// LIB-027: formatting, paragraph settings and placeholders inside an instance's text override.
@Suite struct SymbolOverrideFormattingTests {
    typealias Fixture = SymbolOverrideTests.Fixture

    static func text(_ f: Fixture, _ instance: OpID? = nil, in state: EngineState) throws -> TextNode {
        try #require(Symbols.textNode(f.text, in: instance ?? f.instance, state: state))
    }

    @Test func aMarkOnTheFirstEditCopiesTheTextThenFormatsIt() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let change = try #require(try a.perform(OverrideText(f.instance, master: f.text, edits: [.mark(1..<3, TextFixture.size(30))], label: "Size")))
        #expect(change.label == "Size")
        let text = try Self.text(f, in: a.state)
        #expect(text.string == "Label" && text.runs.contains { $0.range == 1..<3 && $0.values.contains { $0.size == 30 } })
        #expect(TextNode(f.text, in: a.state)?.runs.allSatisfy { !$0.values.contains { $0.size == 30 } } == true, "the master is untouched")
        // Later: a cleared value removes the attribute; an empty range writes nothing.
        try a.perform(OverrideText(f.instance, master: f.text, edits: [.mark(0..<5, TextMarks.cleared(TextFixture.size(30)))]))
        #expect(try Self.text(f, in: a.state).runs.allSatisfy { !$0.values.contains { $0.size == 30 } })
        #expect(try a.perform(OverrideText(f.instance, master: f.text, edits: [.mark(2..<2, TextFixture.size(8))])) == nil)
        #expect(throws: TextEditError.invalidValue("value")) {
            try a.perform(OverrideText(f.instance, master: f.text, edits: [.mark(0..<1, Wiretuner_Doc_V1_TextMarkValue())]))
        }
        #expect(throws: TextEditError.invalidValue("range")) { try a.perform(OverrideText(f.instance, master: f.text, edits: [.mark(0..<9, TextFixture.size(8))])) }
        #expect(OverrideText(f.instance, master: f.text, edits: [.mark(0..<1, TextFixture.size(8))]).coalescing == .none)
    }

    @Test func severalEditsAreOneChangeEachInTheOffsetsTheOneBeforeLeft() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("!", at: 5)))
        let change = try #require(try a.perform(OverrideText(f.instance, master: f.text, edits: [
            .insertMarked("Big ", at: 0, marks: [TextFixture.size(20)]), .replace(4..<5, with: "l"), .mark(0..<3, TextFixture.family("Georgia")),
            .delete(9..<10),
        ])))
        #expect(change.label == "Override text")
        let text = try Self.text(f, in: a.state)
        #expect(text.string == "Big label")
        #expect(text.runs.contains { $0.range.contains(0) && $0.values.contains { $0.size == 20 } && $0.values.contains { $0.fontFamily == "Georgia" } })
        a.undo()
        #expect(try Self.text(f, in: a.state).string == "Label!", "one undo step")
        #expect(throws: TextEditError.invalidValue("offset")) {
            try a.perform(OverrideText(f.instance, master: f.text, edits: [.insertMarked("x", at: 99, marks: [])]))
        }
    }

    @Test func paragraphSettingsGoOnTheOverridesNewlinesAndItsTailParagraph() throws {
        var a = Replica(0xA)
        let rect = try a.perform(SymbolFixture.rect(x: 0))!.createdObjects[0]
        let block = try TextFixture.block(&a, "One\nTwo", at: Point(x: 0, y: 30), paragraph: .with { $0.spaceAbove = 6 })
        let converted = try #require(try a.perform(ConvertToSymbol([rect, block])))
        let instance = converted.createdNodes[1]
        func text() throws -> TextNode { try #require(Symbols.textNode(block, in: instance, state: a.state)) }
        #expect(try text().paragraphs.map(\.props.spaceAbove) == [6, 6], "the master's paragraphs")
        // Centring the last paragraph copies the master's tail settings with it.
        let center = Wiretuner_Doc_V1_ParagraphProps.with { $0.alignment = .center }
        try a.perform(OverrideText(instance, master: block, edits: [.paragraph(5..<5, center, fields: [[1]])], label: "Alignment"))
        var paragraphs = try text().paragraphs
        #expect(paragraphs[1].props.alignment == .center && paragraphs[1].props.spaceAbove == 6)
        #expect(paragraphs[0].props.alignment == .unspecified)
        #expect(TextNode(block, in: a.state)?.paragraphs[1].props.alignment == .unspecified, "the master is untouched")
        let element = try #require(Symbols.liveOverrides(of: instance, in: a.state).values.first)
        #expect(element.hasTailParagraph && element.tailParagraph.spaceAbove == 6)
        // The first paragraph's settings go on its newline; a later tail write writes only its field.
        let right = Wiretuner_Doc_V1_ParagraphProps.with { $0.alignment = .right; $0.leftIndent = 12 }
        try a.perform(OverrideText(instance, master: block, edits: [.paragraph(0..<2, right, fields: [[1], [4]])]))
        paragraphs = try text().paragraphs
        #expect(paragraphs[0].props.alignment == .right && paragraphs[0].props.leftIndent == 12)
        let tail = try #require(try a.perform(OverrideText(instance, master: block, edits: [.paragraph(6..<6, right, fields: [[4]])])))
        paragraphs = try text().paragraphs
        #expect(tail.ops.count == 1 && paragraphs[1].props.alignment == .center && paragraphs[1].props.leftIndent == 12)
        // A range over both paragraphs writes both.
        let both = try #require(try a.perform(OverrideText(instance, master: block, edits: [.paragraph(1..<6, center, fields: [[1]])])))
        paragraphs = try text().paragraphs
        #expect(both.ops.count == 2 && paragraphs.map(\.props.alignment) == [.center, .center])
        // A caret at the very end is in the last paragraph.
        try a.perform(OverrideText(instance, master: block, edits: [.paragraph(7..<7, right, fields: [[1]])]))
        #expect(try text().paragraphs.map(\.props.alignment) == [.center, .right])
        #expect(throws: TextEditError.invalidValue("fields")) {
            try a.perform(OverrideText(instance, master: block, edits: [.paragraph(0..<1, center, fields: [[9]])]))
        }
        #expect(throws: TextEditError.invalidValue("fields")) { try a.perform(OverrideText(instance, master: block, edits: [.paragraph(0..<1, center, fields: [])])) }
        // Release bakes the override's paragraph settings with its text.
        let released = try #require(try a.perform(ReleaseInstances([instance])))
        let copy = try #require(released.createdObjects.first.flatMap { group in a.state.liveChildren(group).first { a.state.nodeKind($0) == .text } })
        let baked = try #require(TextNode(copy, in: a.state))
        #expect(baked.string == "One\nTwo" && baked.paragraphs.map(\.props.alignment) == [.center, .right] && baked.paragraphs[1].props.leftIndent == 12)
        a.undo()
        // Every settable field reaches the copied tail.
        let all = Wiretuner_Doc_V1_ParagraphProps.with {
            $0.raggedWidth = 10; $0.flushZone = 11; $0.rightIndent = 2; $0.firstLineIndent = 3; $0.spaceBelow = 4; $0.hyphenation.enabled = true
            $0.rule.mode = .centered; $0.hangPunctuation = true; $0.keepLines = 2; $0.keepWithNext = true; $0.wordSpacing.opt = 90
            $0.letterSpacing.opt = 5; $0.style.id = OpID(counter: 3, replica: 3).proto
        }
        let laid = OverrideText.Editor.laid(all, fields: [[1], [2], [3], [4], [5], [6], [7], [8], [10, 1], [11, 1], [12], [13], [14], [15, 2], [16, 2], [17]],
                                            over: .init())
        #expect(laid.raggedWidth == 10 && laid.flushZone == 11 && laid.rightIndent == 2 && laid.firstLineIndent == 3 && laid.spaceBelow == 4)
        #expect(laid.hyphenation.enabled && laid.rule.mode == .centered && laid.hangPunctuation && laid.keepLines == 2 && laid.keepWithNext)
        #expect(laid.wordSpacing.opt == 90 && laid.letterSpacing.opt == 5 && laid.hasStyle)
    }

    @Test func concurrentTailSettingsMergeFieldByField() throws {
        var pair = Pair()
        let f = try Fixture(on: &pair.a)
        try pair.a.perform(OverrideText(f.instance, master: f.text, edit: .insert("!", at: 5)))
        pair.sync()
        try pair.a.perform(OverrideText(f.instance, master: f.text, edits: [.paragraph(0..<0, .with { $0.alignment = .center }, fields: [[1]])]))
        try pair.b.perform(OverrideText(f.instance, master: f.text, edits: [.paragraph(0..<0, .with { $0.spaceAbove = 9 }, fields: [[7]])]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let props = try #require(Symbols.textNode(f.text, in: f.instance, state: pair.a.state)?.paragraphs.last?.props)
        #expect(props.alignment == .center && props.spaceAbove == 9)
    }

    @Test func placeholdersInsideAnInstance() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let field = try DataFixture.fields(&a, ["Name"])[0]
        let edit = try #require(DataPlaceholders.overrideInsert(field: field, at: 0, marks: [TextFixture.size(14), DataPlaceholders.mark(nil)], in: a.state))
        try a.perform(OverrideText(f.instance, master: f.text, edits: [edit], label: "Insert field"))
        var text = try Self.text(f, in: a.state)
        #expect(text.string == "{{Name}}Label")
        #expect(DataPlaceholders.unitRange(1..<1, in: text) == 0..<8, "one unit")
        #expect(DataPlaceholders.overrideInsert(field: f.rect, at: 0, marks: [], in: a.state) == nil, "not a field")
        // Typing the closing braces converts the name.
        try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("{{Name}}", at: 13)))
        text = try Self.text(f, in: a.state)
        let edits = try #require(DataPlaceholders.overrideConversion(in: text, before: 21, state: a.state))
        try a.perform(OverrideText(f.instance, master: f.text, edits: edits, label: "Insert field"))
        text = try Self.text(f, in: a.state)
        #expect(text.string == "{{Name}}Label{{Name}}" && DataPlaceholders.unitRange(15..<15, in: text) == 13..<21)
        #expect(DataPlaceholders.overrideConversion(in: text, before: 5, state: a.state) == nil)
        // A name no field has keeps its name, under the unknown field's mark.
        try a.perform(OverrideText(f.instance, master: f.text, edit: .insert("{{Other}}", at: 21)))
        text = try Self.text(f, in: a.state)
        let unknown = try #require(DataPlaceholders.overrideConversion(in: text, before: 30, state: a.state))
        #expect(unknown.count == 2 && unknown[1] == .insertMarked("{{Other}}", at: 21, marks: [DataPlaceholders.mark(nil)]))
    }
}
