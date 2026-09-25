import WTCRDT
import WTProto

// Finding and replacing text (editing-text.adoc, "Finding and replacing text", "Replace All";
// TYPE-013) and the spelling correction's rewrite (TYPE-014): a document-wide search over the
// text nodes in stacking order -- a chain's head owns its text, so a chain is searched as one
// story -- on the merged plain string, with a map back to character ids, and one command that
// deletes each match and inserts its replacement before it.

/// What the Find and Replace Text window searches for.
public struct TextSearch: Hashable, Sendable {
    /// A search string can be up to 255 characters.
    public static let limit = 255

    public var find: String
    public var wholeWord: Bool
    public var matchCase: Bool

    public init(_ find: String, wholeWord: Bool = false, matchCase: Bool = false) {
        self.find = String(find.unicodeScalars.prefix(Self.limit))
        self.wholeWord = wholeWord
        self.matchCase = matchCase
    }
}

/// One match: its node, its live range when found and the ids of its first and last characters
/// (what the replace resolves, so a match survives edits elsewhere in the text).
public struct TextMatch: Hashable, Sendable {
    public let node: OpID
    public let range: Range<Int>
    public let first: OpID
    public let last: OpID

    public init(node: OpID, range: Range<Int>, first: OpID, last: OpID) {
        self.node = node
        self.range = range
        self.first = first
        self.last = last
    }
}

/// The search.
public enum TextFinder {
    /// The text nodes searched, in stacking order: every live text node on a visible, unlocked
    /// ordinary layer (group members included), or with `within` those among (or inside) it.
    public static func nodes(in state: EngineState, within: [OpID]? = nil) -> [OpID] {
        let scope: AttributeQuery.Scope = within.map { .selection($0) } ?? .document
        return AttributeQuery.candidates(scope, in: state).filter { state.nodeKind($0) == .text }
    }

    /// The scalar compared: itself with Match case, else its lowercase form when that is one scalar.
    static func folded(_ scalar: Unicode.Scalar, matchCase: Bool) -> Unicode.Scalar {
        guard !matchCase else { return scalar }
        let lower = scalar.properties.lowercaseMapping.unicodeScalars
        return lower.count == 1 ? lower.first! : scalar
    }

    /// The matches of `search` in `text`, optionally inside the live range `within`; matches do not
    /// overlap.
    public static func matches(_ search: TextSearch, in text: TextNode, within: Range<Int>? = nil) -> [TextMatch] {
        let pattern = search.find.unicodeScalars.map { folded($0, matchCase: search.matchCase) }
        guard !pattern.isEmpty else { return [] }
        let scalars = text.string.unicodeScalars.map { folded($0, matchCase: search.matchCase) }
        let bounds = (within ?? 0..<scalars.count).clamped(to: 0..<scalars.count)
        var result: [TextMatch] = []
        var offset = bounds.lowerBound
        let first = pattern[0]
        while offset + pattern.count <= bounds.upperBound {
            if scalars[offset] == first, scalars[offset..<offset + pattern.count].elementsEqual(pattern),
               !search.wholeWord || isWholeWord(offset..<offset + pattern.count, in: scalars) {
                let range = offset..<offset + pattern.count
                result.append(TextMatch(node: text.id, range: range, first: text.chars[range.lowerBound], last: text.chars[range.upperBound - 1]))
                offset += pattern.count
            } else {
                offset += 1
            }
        }
        return result
    }

    /// Whether `range` is bounded by non-word scalars (or the ends of the text).
    static func isWholeWord(_ range: Range<Int>, in scalars: [Unicode.Scalar]) -> Bool {
        let before = range.lowerBound > 0 ? CaseConverting.isWordScalar(scalars[range.lowerBound - 1]) : false
        let after = range.upperBound < scalars.count ? CaseConverting.isWordScalar(scalars[range.upperBound]) : false
        return !before && !after
    }

    /// Every match in `nodes` (in their order), each node's matches in text order.
    public static func matches(_ search: TextSearch, in state: EngineState, nodes: [OpID]) -> [TextMatch] {
        nodes.flatMap { node in state.textNode(node).map { matches(search, in: $0) } ?? [] }
    }
}

/// Replaces matches (editing-text, "Replace All"): per match one `TextDelete` of its characters
/// and one `TextInsert` of the replacement between the character before the match and the
/// match's first character, so the replacement sorts before the tombstoned match and letters
/// typed concurrently inside or after it come out after the replacement.  The replacement
/// carries the formatting the match's first character had.  An empty replacement only deletes.
/// A match whose characters are all gone is skipped.  One change.
public struct ReplaceText: Command {
    public var matches: [TextMatch]
    public var replacement: String
    public var label: String

    public init(_ matches: [TextMatch], with replacement: String, label: String) {
        self.matches = matches
        self.replacement = replacement
        self.label = label
    }

    /// "Replace all 'colour' with 'color' (3)".
    public static func replaceAllLabel(_ find: String, _ replacement: String, count: Int) -> String {
        "Replace all '\(find)' with '\(replacement)' (\(count))"
    }

    /// The label of a spelling correction.
    public static let correctSpelling = "Correct spelling"

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var texts: [OpID: TextNode] = [:]
        for match in matches {
            if texts[match.node] == nil { texts[match.node] = try TextEditing.text(match.node, in: state) }
            let text = texts[match.node]!
            guard let range = Self.resolve(match, in: text) else { continue }
            let old = Array(text.chars[range])
            for op in TextEditing.deletes(match.node, old) { builder.append(op) }
            guard !replacement.isEmpty else { continue }
            let formatting = CaseConverting.formatting(text, run: range)
            let marks = formatting.keys.map { key, sample in formatting.values[range.lowerBound]?[key] ?? TextMarks.cleared(sample) }
            let left = range.lowerBound > 0 ? text.chars[range.lowerBound - 1] : .zero
            TextEditing.insert(replacement, node: match.node, origins: (left, old[0]), split: text.paragraphs[text.paragraphIndex(at: range.lowerBound)],
                               marks: marks, state: state, builder: &builder)
        }
    }

    /// The live range a match covers now: from its first live character to its last.
    static func resolve(_ match: TextMatch, in text: TextNode) -> Range<Int>? {
        let sequence = text.sequence
        let lower = sequence.offset(of: match.first)
        let upper = sequence.offset(of: match.last).map { sequence.isDeleted(match.last) ? $0 : $0 + 1 }
        guard let lower, let upper, lower < upper, upper <= text.length else { return nil }
        return lower..<upper
    }
}
