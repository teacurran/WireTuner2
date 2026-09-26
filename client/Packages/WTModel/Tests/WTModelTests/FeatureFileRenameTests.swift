import Foundation
import Testing
import WTCRDT
@testable import WTModel
import WTProto

/// FONT-019's *Rename in feature file*: glyph occurrences rewritten character by character in the
/// shared feature text (opentype-features.adoc, "Merge semantics").
@Suite struct FeatureFileRenameTests {
    static func write(_ text: String, into replica: inout Replica) throws {
        try replica.perform(OpsCommand("Features", ops: [Ops.textInsert(WellKnown.settings, FontFields.features, text)]))
    }

    static func features(_ replica: Replica) -> String {
        replica.state.store.text(WellKnown.settings, FontFields.features)?.string ?? ""
    }

    @Test func everyGlyphOccurrenceIsRenamedInOneChange() throws {
        var a = Replica(0xA)
        try Self.write("@c = [a b];\nfeature ss01 { sub a by b; sub \\a by a.sc; } ss01; # a\n", into: &a)
        #expect(RenameInFeatureFile.count(of: "a", in: a.state) == 3)
        let change = try #require(try a.perform(RenameInFeatureFile("a", to: "sub")))
        #expect(change.label == "Rename in Feature File")
        #expect(Self.features(a) == "@c = [\\sub b];\nfeature ss01 { sub \\sub by b; sub \\sub by a.sc; } ss01; # a\n")
        #expect(RenameInFeatureFile.count(of: "a", in: a.state) == 0 && RenameInFeatureFile.count(of: "sub", in: a.state) == 3)
        a.undo()
        #expect(Self.features(a).hasPrefix("@c = [a b];"))
        // Nothing to do: no change.
        #expect(try a.perform(RenameInFeatureFile("zz", to: "yy")) == nil)
        #expect(try a.perform(RenameInFeatureFile("a", to: "a")) == nil)
        #expect(try a.perform(RenameInFeatureFile("a", to: "")) == nil)
        #expect(RenameInFeatureFile.count(of: "a", in: EngineState()) == 0)
        var empty = Replica(0xB)
        #expect(try empty.perform(RenameInFeatureFile("a", to: "b")) == nil)
    }

    @Test func aRenameMergesWithAConcurrentEditElsewhere() throws {
        var pair = Pair()
        try Self.write("feature ss01 { sub a by b; } ss01;", into: &pair.a)
        pair.sync()
        try pair.a.perform(RenameInFeatureFile("a", to: "alpha"))
        // B types a new rule at the end meanwhile.
        let text = try #require(pair.b.state.store.text(WellKnown.settings, FontFields.features))
        try pair.b.perform(OpsCommand("Type", ops: [Ops.textInsert(WellKnown.settings, FontFields.features, "\nfeature ss02 { sub a by c; } ss02;",
                                                                  left: text.liveChars.last!)]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(Self.features(pair.a) == "feature ss01 { sub alpha by b; } ss01;\nfeature ss02 { sub a by c; } ss02;")
    }
}
