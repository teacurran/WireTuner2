import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// The merge tests of TYPE-002 (creating-text.adoc, "Merge semantics"), each through two
/// in-process replicas that exchange their changes in both directions.
@Suite struct TextMergeTests {
    /// Two replicas sharing a text block created on A holding `text`.
    struct Shared {
        var pair = Pair()
        let node: OpID

        init(_ text: String) throws {
            node = try TextFixture.block(&pair.a, text)
            pair.sync()
        }

        /// Syncs and checks both replicas converged; returns the merged text.
        mutating func merged() -> TextNode {
            pair.sync()
            #expect(pair.a.state.stateHash == pair.b.state.stateHash)
            #expect(TextFixture.text(pair.a, node).string == TextFixture.text(pair.b, node).string)
            return TextFixture.text(pair.a, node)
        }
    }

    /// Types `word` one keystroke at a time at the end of `node` on `replica`.
    static func type(_ word: String, _ replica: inout Replica, _ node: OpID, at anchor: Anchor = .end) throws {
        var caret = anchor
        for character in word {
            let change = try replica.perform(InsertText(node: node, text: String(character), at: caret, typing: true))!
            let typed = OpID(counter: change.startCounter, replica: change.replica)
            // The caret follows the typed character.
            caret = Anchor(char: typed, before: false)
        }
    }

    @Test func concurrentTypingAtOneAnchorNeverInterleaves() throws {
        var s = try Shared("ab")
        try Self.type("hello", &s.pair.a, s.node)
        try Self.type("world", &s.pair.b, s.node)
        let merged = s.merged().string
        #expect(merged == "abhelloworld" || merged == "abworldhello")
        // Both orders of delivery reach the same string (Pair delivers each side's changes to the other).
        var t = try Shared("")
        try Self.type("one", &t.pair.b, t.node, at: .start)
        try Self.type("two", &t.pair.a, t.node, at: .start)
        let other = t.merged().string
        #expect(other == "onetwo" || other == "twoone")
    }

    @Test func formattingCoversTextTypedConcurrentlyInsideAndAtTheEnd() throws {
        var s = try Shared("abcd")
        let text = TextFixture.text(s.pair.a, s.node)
        try s.pair.a.perform(ApplyMark(node: s.node, from: .start, to: .end, value: TextFixture.size(18)))
        // B types inside the span and just after its last character.
        try s.pair.b.perform(InsertText(node: s.node, text: "X", at: text.anchor(at: 2)))
        try s.pair.b.perform(InsertText(node: s.node, text: "Z", at: .end))
        let merged = s.merged()
        #expect(merged.string == "abXcdZ")
        #expect(TextFixture.sizes(merged) == [18, 18, 18, 18, 18, 18])
    }

    @Test func formattingAcrossConcurrentInsertsOfTwoAttributesStacks() throws {
        var s = try Shared("abcdef")
        let text = TextFixture.text(s.pair.a, s.node)
        try s.pair.a.perform(ApplyMark(node: s.node, from: text.anchor(at: 0), to: text.anchor(at: 4), value: TextFixture.family("A")))
        try s.pair.b.perform(ApplyMark(node: s.node, from: text.anchor(at: 2), to: .end, value: TextFixture.family("B")))
        try s.pair.b.perform(ApplyMark(node: s.node, from: text.anchor(at: 2), to: .end, value: TextFixture.size(9)))
        let merged = s.merged()
        // In c-d the greater OpId (B's, whose counters are the same and replica greater) wins the family.
        #expect(merged.values(at: 0) == [TextFixture.family("A")])
        #expect(merged.values(at: 2) == [TextFixture.family("B"), TextFixture.size(9)])
    }

    @Test func deleteVersusFormatKeepsTheSurvivorsFormatted() throws {
        var s = try Shared("abcd")
        let text = TextFixture.text(s.pair.a, s.node)
        try s.pair.a.perform(DeleteText(node: s.node, from: text.anchor(at: 1), to: text.anchor(at: 3)))
        try s.pair.b.perform(ApplyMark(node: s.node, from: .start, to: .end, value: TextFixture.family("Menlo")))
        let merged = s.merged()
        #expect(merged.string == "ad")
        #expect(merged.runs.map(\.values) == [[TextFixture.family("Menlo")]])
        // Typing into a word the other side deletes leaves the typed letters standing alone.
        var t = try Shared("word")
        let word = TextFixture.text(t.pair.a, t.node)
        try t.pair.a.perform(DeleteText(node: t.node, from: .start, to: .end))
        try t.pair.b.perform(InsertText(node: t.node, text: "XY", at: word.anchor(at: 2)))
        #expect(t.merged().string == "XY")
    }

    @Test func blockDeletedWhileTypingKeepsTheTypedCharacters() throws {
        var s = try Shared("ab")
        try s.pair.a.perform(DeleteNodes([s.node]))
        try Self.type("cd", &s.pair.b, s.node)
        _ = s.merged()
        #expect(!s.pair.a.state.isLive(s.node))
        try s.pair.a.perform(OpsCommand("Restore", ops: [Ops.setDeleted(s.node, false)]))
        let restored = s.merged()
        #expect(s.pair.b.state.isLive(s.node))
        #expect(restored.string == "abcd")
    }

    @Test func splitVersusAlignmentKeepsTheCopyOnTheFirstHalf() throws {
        var paragraph = Wiretuner_Doc_V1_ParagraphProps()
        paragraph.alignment = .left
        var s = try Shared("")
        let node = try TextFixture.block(&s.pair.a, "ab\ncd", paragraph: paragraph)
        s.pair.sync()
        let text = TextFixture.text(s.pair.a, node)
        try s.pair.a.perform(SplitParagraph(node: node, at: text.anchor(at: 1)))
        var center = Wiretuner_Doc_V1_ParagraphProps()
        center.alignment = .center
        try s.pair.b.perform(SetParagraph(node: node, from: text.anchor(at: 0), to: text.anchor(at: 0), props: center, fields: [[1]]))
        s.pair.sync()
        #expect(s.pair.a.state.stateHash == s.pair.b.state.stateHash)
        let merged = TextFixture.text(s.pair.a, node)
        #expect(merged.string == "a\nb\ncd")
        #expect(merged.paragraphs.map(\.props.alignment) == [.left, .center, .left])
    }

    @Test func undoOfTypingSkipsTheOtherReplicasText() throws {
        var s = try Shared("")
        try Self.type("mine", &s.pair.a, s.node)
        s.pair.sync()
        try Self.type("theirs", &s.pair.b, s.node)
        s.pair.sync()
        s.pair.a.undo()
        #expect(s.merged().string == "theirs")
    }
}
