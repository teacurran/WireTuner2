import AppKit
import WTCRDT
import WTModel

/// The system's spelling service as the checker uses it (so tests can give their own
/// dictionary).  Learned words live in the macOS user dictionary and never reach the document.
@MainActor
protocol SpellingService: AnyObject {
    /// Whether `word` is spelled right in `language` (nil: automatic).
    func isCorrect(_ word: String, language: String?) -> Bool
    func guesses(for word: String, language: String?) -> [String]
    func learn(_ word: String)
    func unlearn(_ word: String)
    func hasLearned(_ word: String) -> Bool
}

/// `NSSpellChecker` over one document tag, so btn:[Ignore] lasts for the document.
@MainActor
final class SystemSpellingService: SpellingService {
    let tag = NSSpellChecker.uniqueSpellDocumentTag()
    private var ignored: Set<String> = []

    func isCorrect(_ word: String, language: String?) -> Bool {
        if ignored.contains(word) { return true }
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: tag, wordCount: nil)
        return range.location == NSNotFound
    }

    func guesses(for word: String, language: String?) -> [String] {
        NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: word.utf16.count), in: word, language: language,
                                      inSpellDocumentWithTag: tag) ?? []
    }

    func learn(_ word: String) { NSSpellChecker.shared.learnWord(word) }
    func unlearn(_ word: String) { NSSpellChecker.shared.unlearnWord(word) }
    func hasLearned(_ word: String) -> Bool { NSSpellChecker.shared.hasLearnedWord(word) }

    func ignore(_ word: String) {
        ignored.insert(word)
        NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: tag)
    }
}

/// The Spelling preferences as the checker reads them.
struct SpellingOptions: Equatable {
    var findDuplicates = true
    var findCapitalization = true
    var filters = SpellingFilters()
    /// *Add words to dictionary*: learn in lowercase.
    var learnsLowercase = false
    /// *Spelling language*; nil: automatic.  A paragraph's own language wins.
    var language: String?

    init() {}

    @MainActor init(preferences: PreferenceStore) {
        findDuplicates = preferences[PreferenceCatalog.Spelling.findDuplicates]
        findCapitalization = preferences[PreferenceCatalog.Spelling.findCapitalization]
        filters = SpellingFilters(ignoreNumbers: preferences[PreferenceCatalog.Spelling.ignoreNumbers],
                                  ignoreAddresses: preferences[PreferenceCatalog.Spelling.ignoreAddresses],
                                  ignoreUppercase: preferences[PreferenceCatalog.Spelling.ignoreUppercase])
        learnsLowercase = preferences[PreferenceCatalog.Spelling.learnedWordCase] == "lowercase"
        let language = preferences[PreferenceCatalog.Spelling.dictionary]
        self.language = language.isEmpty ? nil : language
    }
}

/// One questionable word.
struct SpellingIssue: Equatable {
    enum Kind: Equatable {
        case misspelled, duplicate, capitalization
    }

    let node: OpID
    let range: Range<Int>
    let word: String
    let kind: Kind
    /// The paragraph's language (or the preference's).
    let language: String?

    /// What the window's message says.
    var message: String {
        switch kind {
        case .misspelled: "Not in dictionary: \(word)"
        case .duplicate: "Duplicate word: \(word)"
        case .capitalization: "Capitalize the start of the sentence: \(word)"
        }
    }

    /// The proposed correction for the rule passes.
    var suggestion: String? {
        switch kind {
        case .misspelled: nil
        case .duplicate: ""
        case .capitalization: word.prefix(1).uppercased() + word.dropFirst()
        }
    }
}

/// The checker: every issue of a text node, paragraph by paragraph (each in its language), with
/// the passes and filters of the options.
@MainActor
struct SpellingChecker {
    let service: any SpellingService
    let options: SpellingOptions

    func issues(in text: TextNode, within: Range<Int>? = nil) -> [SpellingIssue] {
        let scalars = Array(text.string.unicodeScalars)
        let bounds = within ?? 0..<scalars.count
        var result: [SpellingIssue] = []
        let words = SpellingPasses.words(scalars)
        let duplicates = options.findDuplicates ? Set(SpellingPasses.duplicates(words, in: scalars).map(\.range)) : []
        let capitals = options.findCapitalization ? Set(SpellingPasses.capitalization(words, in: scalars).map(\.range)) : []
        let paragraphs = text.paragraphs
        for word in words where bounds.contains(word.range.lowerBound) {
            let paragraph = paragraphs[text.paragraphIndex(at: word.range.lowerBound)]
            let language = SpellingPasses.language(of: paragraph) ?? options.language
            let token = SpellingPasses.token(around: word.range, in: scalars)
            if duplicates.contains(word.range) {
                // The repeat and the space before it go together.
                var lower = word.range.lowerBound
                while lower > 0, scalars[lower - 1].properties.isWhitespace { lower -= 1 }
                result.append(SpellingIssue(node: text.id, range: lower..<word.range.upperBound, word: word.word, kind: .duplicate, language: language))
            } else if options.filters.ignores(word.word, token: token) {
                continue
            } else if !service.isCorrect(word.word, language: language) {
                result.append(SpellingIssue(node: text.id, range: word.range, word: word.word, kind: .misspelled, language: language))
            } else if capitals.contains(word.range) {
                result.append(SpellingIssue(node: text.id, range: word.range, word: word.word, kind: .capitalization, language: language))
            }
        }
        return result
    }

    /// What btn:[Learn] adds for `word`.
    func learnedForm(_ word: String) -> String {
        options.learnsLowercase ? word.lowercased() : word
    }
}
