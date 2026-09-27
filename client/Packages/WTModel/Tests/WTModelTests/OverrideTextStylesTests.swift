import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// LIB-027's rest: paragraph and character styles applied to an instance's text override.
@Suite struct OverrideTextStylesTests {
    typealias Fixture = SymbolOverrideTests.Fixture

    @Test func aParagraphStyleGoesOnTheOverrideAndClearsWhatItGoverns() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let style = try TextStyleTests.style(&a, .paragraph, name: "Heading") { $0.paragraph.alignment = .center; $0.character.size = 24 }
        // A size mark on the override first: the style's governed size clears it.
        try a.perform(OverrideText(f.instance, master: f.text, edits: [.mark(0..<5, TextFixture.size(9)), .paragraph(0..<0, .with { $0.alignment = .right }, fields: [[1]])]))
        let text = try #require(Symbols.textNode(f.text, in: f.instance, state: a.state))
        let edits = try OverrideTextStyles.paragraphStyle(style, range: 1..<1, in: text, state: a.state)
        try a.perform(OverrideText(f.instance, master: f.text, edits: edits, label: "Apply style"))
        let styled = try #require(Symbols.textNode(f.text, in: f.instance, state: a.state))
        let styles = a.state.textStyles
        #expect(styles.paragraphStyle(styled.paragraphs[0].props).style == style)
        #expect(styled.paragraphs[0].props.alignment == .unspecified, "the governed alignment is cleared")
        #expect(styled.runs.allSatisfy { TextStyleTests.size($0.values) != 9 }, "the governed size mark is cleared")
        #expect(TextNode(f.text, in: a.state).map { styles.paragraphStyle($0.paragraphs[0].props).style } != style, "the master is untouched")
        #expect(throws: TextStyleError.self) { try OverrideTextStyles.paragraphStyle(f.instance, range: 0..<0, in: text, state: a.state) }
    }

    @Test func aCharacterStyleMarksTheRangeAndNoneClearsIt() throws {
        var a = Replica(0xA)
        let f = try Fixture(on: &a)
        let style = try TextStyleTests.style(&a, .character, name: "Loud") { $0.character.fontFamily = "Georgia" }
        #expect(try OverrideTextStyles.characterStyle(style, range: 2..<2, state: a.state).isEmpty)
        try a.perform(OverrideText(f.instance, master: f.text, edits: [.mark(0..<5, TextFixture.family("Menlo"))]))
        try a.perform(OverrideText(f.instance, master: f.text, edits: try OverrideTextStyles.characterStyle(style, range: 0..<3, state: a.state)))
        var text = try #require(Symbols.textNode(f.text, in: f.instance, state: a.state))
        let styles = a.state.textStyles
        func characterStyle(_ offset: Int) -> OpID? {
            for value in text.values(at: offset) { if case .style(let ref)? = value.value { return styles.reference(ref, kind: .character)?.style } }
            return nil
        }
        #expect(characterStyle(0) == style && characterStyle(4) == nil)
        #expect(TextStyleTests.family(text.values(at: 0)) != "Menlo" && TextStyleTests.family(text.values(at: 4)) == "Menlo")
        try a.perform(OverrideText(f.instance, master: f.text, edits: try OverrideTextStyles.characterStyle(nil, range: 0..<3, state: a.state)))
        text = try #require(Symbols.textNode(f.text, in: f.instance, state: a.state))
        #expect(characterStyle(0) == nil)
        #expect(throws: TextStyleError.self) { try OverrideTextStyles.characterStyle(f.instance, range: 0..<1, state: a.state) }
    }
}
