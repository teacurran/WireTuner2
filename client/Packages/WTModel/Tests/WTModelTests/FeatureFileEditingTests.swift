import Foundation
import Testing
import WTCRDT
import WTInterchange
@testable import WTModel
import WTProto

/// FONT-022's model half: the Features editor's text, its edits and their undo grouping, the
/// checker's context, and the glyph rename that also renames in the feature file
/// (opentype-features.adoc, "The Features editor", "Merge semantics").
@Suite struct FeatureFileEditingTests {
    static func features(_ replica: Replica) -> String { FeatureFileText(replica.state).string }

    /// Types `string` at `offset`, one keystroke per scalar.
    static func type(_ string: String, at offset: Int, into replica: inout Replica) throws {
        var at = offset
        for scalar in string.unicodeScalars {
            let text = FeatureFileText(replica.state)
            try replica.perform(text.edit(replacing: at..<at, with: String(scalar), typing: true))
            at += 1
        }
    }

    @Test func editsReplaceTheCharactersTheyCover() throws {
        var a = Replica(0xA)
        #expect(FeatureFileText(a.state).string.isEmpty && FeatureFileText(a.state).char(at: 0) == .zero)
        try a.perform(FeatureFileText(a.state).edit(replacing: 0..<0, with: "feature liga {\r\n} liga;"))
        #expect(Self.features(a) == "feature liga {\n} liga;")
        // Insert inside, replace a word, delete at the end.
        try a.perform(FeatureFileText(a.state).edit(replacing: 15..<15, with: "  sub f i by f_i;\n"))
        #expect(Self.features(a) == "feature liga {\n  sub f i by f_i;\n} liga;")
        let text = FeatureFileText(a.state)
        let range = 8..<12
        try a.perform(text.edit(replacing: range, with: "dlig"))
        #expect(Self.features(a) == "feature dlig {\n  sub f i by f_i;\n} liga;")
        try a.perform(FeatureFileText(a.state).edit(replacing: 35..<39, with: "dlig"))
        #expect(Self.features(a).hasSuffix("} dlig;"))
        // A range past the end clamps; an empty edit writes nothing.
        let count = FeatureFileText(a.state).count
        try a.perform(FeatureFileText(a.state).edit(replacing: count..<(count + 5), with: "\u{1}\n"))
        #expect(Self.features(a).hasSuffix("dlig;\n"))
        #expect(try a.perform(FeatureFileText(a.state).edit(replacing: 3..<3, with: "")) == nil)
        #expect(try a.perform(FeatureFileText(a.state).edit(replacing: 3..<3, with: "\u{7}")) == nil)
        #expect(EditFeatureFile(delete: [], before: .zero, insert: "x").label == "Edit Feature File")
    }

    @Test func controlCharactersAreNotShown() throws {
        var a = Replica(0xA)
        try a.perform(OpsCommand("Raw", ops: [Ops.textInsert(WellKnown.settings, FontFields.features, "a\u{1}b\tc")]))
        let text = FeatureFileText(a.state)
        #expect(text.string == "ab\tc" && text.count == 4)
        // An edit between the shown characters goes next to the hidden one's neighbour.
        try a.perform(text.edit(replacing: 1..<1, with: "X"))
        #expect(Self.features(a) == "aXb\tc")
        // Where a caret on a hidden, deleted or unknown character reads.
        let raw = try #require(a.state.store.text(WellKnown.settings, FontFields.features))
        let hidden = try #require(raw.liveChars.first { raw.codepoint($0) == 1 })
        let after = FeatureFileText(a.state)
        #expect(after.offset(of: hidden, in: a.state) == 1)
        #expect(after.offset(of: .zero, in: a.state) == after.count && after.offset(of: after.chars[3], in: a.state) == 3)
        try a.perform(after.edit(replacing: 3..<4, with: ""))
        #expect(FeatureFileText(a.state).offset(of: after.chars[3], in: a.state) == 3)
        #expect(FeatureFileText(a.state).offset(of: OpID(counter: 999, replica: 9), in: a.state) == nil)
        #expect(FeatureFileText(EngineState()).offset(of: OpID(counter: 1, replica: 1), in: EngineState()) == nil)
    }

    @Test func typingUndoesAWordAtATime() throws {
        var a = Replica(0xA)
        try Self.type("sub f", at: 0, into: &a)
        #expect(Self.features(a) == "sub f")
        #expect(a.core.undoStack.undo.count == 2)
        // A backspace joins the word being typed; a paste is its own step.
        try a.perform(FeatureFileText(a.state).edit(replacing: 4..<5, with: "", typing: true))
        try a.perform(FeatureFileText(a.state).edit(replacing: 4..<4, with: "f i", typing: false))
        #expect(Self.features(a) == "sub f i" && a.core.undoStack.undo.count == 3)
        a.undo()
        #expect(Self.features(a) == "sub ")
        // The second word's step held both the f and its deletion.
        a.undo()
        #expect(Self.features(a) == "sub ")
        a.undo()
        #expect(Self.features(a).isEmpty)
        #expect(EditFeatureFile(delete: [], before: .zero, insert: "ab", typing: true).coalescing == .none)
        #expect(EditFeatureFile(delete: [], before: .zero, insert: ";", typing: true).coalescing
            == .typing(node: WellKnown.settings, field: FontFields.features, endsWord: true))
        #expect(EditFeatureFile(delete: [], before: .zero, insert: "x", typing: false).coalescing == .none)
    }

    @Test func anEditLandsWhereTheUserPutItDespiteAConcurrentOne() throws {
        var pair = Pair()
        try pair.a.perform(FeatureFileText(pair.a.state).edit(replacing: 0..<0, with: "feature liga {\n} liga;\nfeature ss01 {\n} ss01;"))
        pair.sync()
        // A types in the first block, B in the second, each from the text they saw.
        try Self.type("sub f i by f_i;", at: 15, into: &pair.a)
        let seen = FeatureFileText(pair.b.state)
        try pair.b.perform(seen.edit(replacing: 38..<38, with: "sub a by a.alt;"))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(Self.features(pair.a) == "feature liga {\nsub f i by f_i;} liga;\nfeature ss01 {\nsub a by a.alt;} ss01;")
        // An edit made against text that has since changed still goes before its character.
        let stale = FeatureFileText(pair.a.state)
        try pair.b.perform(FeatureFileText(pair.b.state).edit(replacing: 0..<0, with: "# top\n"))
        pair.sync()
        try pair.a.perform(stale.edit(replacing: 0..<7, with: "table"))
        #expect(Self.features(pair.a).hasPrefix("# top\ntable liga {"))
        // Deleting a character a collaborator deleted first writes nothing for it.
        let both = FeatureFileText(pair.a.state)
        try pair.b.perform(FeatureFileText(pair.b.state).edit(replacing: 0..<6, with: ""))
        pair.sync()
        #expect(try pair.a.perform(both.edit(replacing: 0..<6, with: "")) == nil)
        #expect(Self.features(pair.a).hasPrefix("table liga {"))
    }

    @Test func theContextKnowsTheGlyphsAndTheGeneratedFeatures() throws {
        var a = Replica(0xA)
        try a.perform(NewTypeface(family: "M", style: "R", set: .basicLatin))
        try a.perform(AddGlyphs([NewGlyph(name: "f_i", kind: .ligature)]))
        let context = FeatureFileContext(a.state)
        #expect(context.glyphs.contains("f_i") && context.glyphs.contains(".notdef") && context.glyphs.contains("A"))
        #expect(context.generatedTags == ["liga"] && context.generated.contains("sub f i by f_i;"))
        #expect(context.check("feature liga { sub f f by f_i; } liga;").isClean)
        #expect(context.check("feature liga { sub f f by f_i; } liga;").issues.first?.kind == .generated)
        #expect(!context.check("feature liga { sub q q by fq; } liga;").isClean)
        // The generator's source has no outlines and matches the full snapshot's names.
        let source = FontGeneration.featureSource(a.state)
        #expect(source.glyphs.allSatisfy { $0.contours.isEmpty })
        let full = FontGeneration.snapshot(a.state, options: FontGenerationOptions())
        #expect(source.glyphs.map(\.name) == full.source.glyphs.map(\.name))
        // With liga off nothing is generated.
        try a.perform(SetGeneratedFeatures(liga: false))
        #expect(FeatureFileContext(a.state).generatedTags.isEmpty)
    }

    @Test func aRenameCanRenameInTheFeatureFileInTheSameChange() throws {
        var a = Replica(0xA)
        try a.perform(NewTypeface(family: "M", style: "R", set: .basicLatin))
        try a.perform(FeatureFileText(a.state).edit(replacing: 0..<0, with: "feature ss01 { sub a by b; } ss01;"))
        let glyph = try #require(GlyphIndex(a.state).glyph(named: "a")).id
        let change = try #require(try a.perform(RenameGlyph(glyph, to: "alpha", inFeatureFile: true)))
        #expect(change.label == "Rename glyph" && Self.features(a) == "feature ss01 { sub alpha by b; } ss01;")
        a.undo()
        #expect(Self.features(a) == "feature ss01 { sub a by b; } ss01;" && GlyphIndex(a.state).glyph(named: "a") != nil)
        // Without the switch only the glyph is renamed.
        try a.perform(RenameGlyph(glyph, to: "alpha"))
        #expect(Self.features(a) == "feature ss01 { sub a by b; } ss01;" && GlyphIndex(a.state).glyph(named: "alpha") != nil)
    }
}
