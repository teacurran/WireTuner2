import WTCRDT
import WTInterchange

/// *Rename in feature file* (opentype-features.adoc, "Merge semantics", Feature text vs. glyph
/// rename; FONT-019): every place the feature file writes the glyph `from` as a glyph -- not a
/// keyword, tag, lookup or class name, nor part of a longer name (`FeatureChecker.occurrences`) --
/// becomes `to`, as one `TextDelete` per character and one `TextInsert` per occurrence in the same
/// change, so a concurrent edit elsewhere in the text merges character by character.  `to` is
/// written `\to` where the grammar would read it as a keyword (unless the occurrence already
/// carries the backslash).  The glyph rename command performs it in its change when the user asks.
public struct RenameInFeatureFile: Command {
    public var from: String
    public var to: String

    public init(_ from: String, to: String) {
        self.from = from
        self.to = to
    }

    public var label: String { "Rename in Feature File" }

    /// How many places the feature file of `state` writes the glyph `name` ("used in the feature
    /// file, 3 places").
    public static func count(of name: String, in state: EngineState) -> Int {
        FeatureChecker.occurrences(of: name, in: text(state).string).count
    }

    static func text(_ state: EngineState) -> (string: String, chars: [OpID], codepoints: [UInt32]) {
        guard let sequence = state.store.text(WellKnown.settings, FontFields.features) else { return ("", [], []) }
        let chars = sequence.liveChars
        let codepoints = chars.map { sequence.codepoint($0) ?? 0xFFFD }
        return (sequence.string, chars, codepoints)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard from != to, !to.isEmpty else { return }
        let (string, chars, codepoints) = Self.text(state)
        let field = FontFields.features
        for range in FeatureChecker.occurrences(of: from, in: string) {
            guard range.upperBound <= chars.count else { continue }
            for index in range {
                builder.append(Ops.textDelete(WellKnown.settings, field, first: chars[index], count: 1))
            }
            let escaped = range.lowerBound > 0 && codepoints[range.lowerBound - 1] == 0x5C
            let written = escaped ? to : FeatureGenerator.glyph(to)
            let left = range.lowerBound > 0 ? chars[range.lowerBound - 1] : .zero
            let right = range.upperBound < chars.count ? chars[range.upperBound] : .zero
            builder.append(Ops.textInsert(WellKnown.settings, field, written, left: left, right: right))
        }
    }
}
