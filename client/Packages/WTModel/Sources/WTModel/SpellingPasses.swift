import WTCRDT
import WTProto

// The parts of spelling that are WireTuner's own (editing-text.adoc, "Checking spelling"; TYPE-014):
// the words of a text, the duplicate-word and capitalization passes and the ignore filters.  The
// dictionary lookup itself is the system's spelling service, in the app.

/// One word of a text: its live range and spelling.
public struct SpellingWord: Hashable, Sendable {
    public let range: Range<Int>
    public let word: String

    public init(range: Range<Int>, word: String) {
        self.range = range
        self.word = word
    }
}

/// What the ignore filters leave out.
public struct SpellingFilters: Hashable, Sendable {
    public var ignoreNumbers: Bool
    public var ignoreAddresses: Bool
    public var ignoreUppercase: Bool

    public init(ignoreNumbers: Bool = true, ignoreAddresses: Bool = true, ignoreUppercase: Bool = false) {
        self.ignoreNumbers = ignoreNumbers
        self.ignoreAddresses = ignoreAddresses
        self.ignoreUppercase = ignoreUppercase
    }

    /// Whether `word` (or the address token around it, `token`) is skipped.
    public func ignores(_ word: String, token: String) -> Bool {
        if ignoreNumbers, word.unicodeScalars.contains(where: { $0.properties.numericType != nil }) { return true }
        if ignoreAddresses, SpellingPasses.isAddress(token) { return true }
        if ignoreUppercase {
            let letters = word.unicodeScalars.filter(\.properties.isAlphabetic)
            if letters.count > 1, letters.allSatisfy(\.properties.isUppercase) { return true }
        }
        return false
    }
}

/// The passes.
public enum SpellingPasses {
    /// The words of `scalars` (runs of letters, digits, combining marks and apostrophes; a
    /// trailing apostrophe is not part of the word).
    public static func words(_ scalars: [Unicode.Scalar]) -> [SpellingWord] {
        var result: [SpellingWord] = []
        var offset = 0
        while offset < scalars.count {
            guard CaseConverting.isWordScalar(scalars[offset]), scalars[offset] != "'", scalars[offset] != "\u{2019}" else {
                offset += 1
                continue
            }
            var end = offset
            while end < scalars.count, CaseConverting.isWordScalar(scalars[end]) { end += 1 }
            var upper = end
            while upper > offset, scalars[upper - 1] == "'" || scalars[upper - 1] == "\u{2019}" { upper -= 1 }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[offset..<upper])
            result.append(SpellingWord(range: offset..<upper, word: String(view)))
            offset = end
        }
        return result
    }

    /// The whitespace-delimited token around `range` (to judge addresses: "www.example.com").
    public static func token(around range: Range<Int>, in scalars: [Unicode.Scalar]) -> String {
        var lower = range.lowerBound
        while lower > 0, !scalars[lower - 1].properties.isWhitespace { lower -= 1 }
        var upper = range.upperBound
        while upper < scalars.count, !scalars[upper].properties.isWhitespace { upper += 1 }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[lower..<upper])
        return String(view)
    }

    /// Whether `token` is an internet or file address: a URL, an e-mail address or a path.
    public static func isAddress(_ token: String) -> Bool {
        let lower = token.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") || lower.hasPrefix("mailto:") { return true }
        if lower.hasPrefix("/") || lower.hasPrefix("~/") || lower.hasPrefix("./") { return true }
        if let at = lower.firstIndex(of: "@"), lower[lower.index(after: at)...].contains("."), at != lower.startIndex { return true }
        return false
    }

    /// The second word of each repeated pair ("the the"): equal without regard to case and
    /// separated by white space only.
    public static func duplicates(_ words: [SpellingWord], in scalars: [Unicode.Scalar]) -> [SpellingWord] {
        zip(words, words.dropFirst()).compactMap { first, second in
            guard first.word.lowercased() == second.word.lowercased(),
                  scalars[first.range.upperBound..<second.range.lowerBound].allSatisfy({ $0.properties.isWhitespace && $0 != "\n" }) else { return nil }
            return second
        }
    }

    /// The words that start a sentence without a capital.
    public static func capitalization(_ words: [SpellingWord], in scalars: [Unicode.Scalar]) -> [SpellingWord] {
        guard !scalars.isEmpty else { return [] }
        let initials = CaseConverting.sentenceInitials(scalars, range: 0..<scalars.count)
        return words.filter { word in
            initials.contains(word.range.lowerBound) && scalars[word.range.lowerBound].properties.isLowercase
        }
    }

    /// The paragraph language spelling follows: the paragraph's hyphenation language when set.
    public static func language(of paragraph: TextParagraph) -> String? {
        let language = paragraph.props.hyphenation.language
        return language.isEmpty ? nil : language
    }
}
