import WTCRDT
import WTInterchange

// FONT-022 (model half): the feature file as the Features editor edits it (opentype-features.adoc,
// "The Features editor", "Data model").  `FeatureFileText` is the text the editor shows -- the
// `FontProps.features` characters with the C0 controls a foreign client may have written left out,
// as `FontInfo` reads them -- with each character's id, so a range the user selects becomes the
// characters it covers.  `EditFeatureFile` is one edit: the characters to delete and the text to
// insert before a character (or at the end), resolved when the change is built, so an edit made
// while a collaborator's change lands still goes where the user put it.  Typing groups into
// word-sized undo steps (`UndoCoalescing.typing`).  `FeatureFileContext` is what the checker and
// the *Generated* pane read of the font.

/// The feature file's visible characters and their ids.
public struct FeatureFileText: Hashable, Sendable {
    /// The text, C0 controls other than tab and newline left out.
    public let string: String
    /// The id of each of `string`'s scalars.
    public let chars: [OpID]

    public init(_ state: EngineState) {
        guard let sequence = state.store.text(WellKnown.settings, FontFields.features) else {
            self.init(string: "", chars: [])
            return
        }
        var scalars = String.UnicodeScalarView()
        var chars: [OpID] = []
        for char in sequence.liveChars {
            let scalar = sequence.codepoint(char).flatMap(Unicode.Scalar.init) ?? "\u{FFFD}"
            guard scalar.value >= 0x20 || scalar == "\t" || scalar == "\n" else { continue }
            scalars.append(scalar)
            chars.append(char)
        }
        self.init(string: String(scalars), chars: chars)
    }

    public init(string: String, chars: [OpID]) {
        self.string = string
        self.chars = chars
    }

    /// The number of scalars.
    public var count: Int { chars.count }

    /// The character at `offset`, zero at (or past) the end: what an insertion at `offset` goes
    /// before.
    public func char(at offset: Int) -> OpID {
        offset >= 0 && offset < chars.count ? chars[offset] : .zero
    }

    /// The edit replacing the scalars `range` with `replacement` (a keystroke with `typing`).
    public func edit(replacing range: Range<Int>, with replacement: String, typing: Bool = false) -> EditFeatureFile {
        let clamped = range.clamped(to: 0..<chars.count)
        return EditFeatureFile(delete: Array(chars[clamped]), before: char(at: clamped.upperBound), insert: replacement, typing: typing)
    }

    /// Where a collaborator's caret on character `char` (zero: the end) reads in this text: the
    /// offset of the character, or where it was when it has been deleted; nil for a character the
    /// text never had.
    public func offset(of char: OpID, in state: EngineState) -> Int? {
        if char == .zero { return count }
        if let visible = chars.firstIndex(of: char) { return visible }
        guard let sequence = state.store.text(WellKnown.settings, FontFields.features), let live = sequence.offset(of: char) else { return nil }
        // Live characters before it that this text shows.
        let shown = Set(chars)
        return sequence.liveChars.prefix(live).filter(shown.contains).count
    }
}

/// One edit of the feature file: delete `delete`, insert `insert` before `before` (zero: at the
/// end).  "Edit Feature File"; a keystroke (`typing`) joins the typing undo step until a word ends.
public struct EditFeatureFile: Command {
    public var delete: [OpID]
    public var before: OpID
    public var insert: String
    public var typing: Bool

    public init(delete: [OpID], before: OpID, insert: String, typing: Bool = false) {
        self.delete = delete
        self.before = before
        self.insert = insert
        self.typing = typing
    }

    public var label: String { "Edit Feature File" }

    public var coalescing: UndoCoalescing {
        guard typing, insert.unicodeScalars.count <= 1, delete.count <= 1, insert.isEmpty != delete.isEmpty else { return .none }
        let ends = insert.unicodeScalars.first.map(Self.endsWord) ?? false
        return .typing(node: WellKnown.settings, field: FontFields.features, endsWord: ends)
    }

    /// Whether typing `scalar` ends a word: whitespace or punctuation.
    static func endsWord(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation: true
        default: scalar.properties.isWhitespace
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let field = FontFields.features
        let sequence = state.store.text(WellKnown.settings, field) ?? TextSequence()
        let removing = Set(delete)
        for char in delete where sequence.contains(char) && !sequence.isDeleted(char) {
            builder.append(Ops.textDelete(WellKnown.settings, field, first: char, count: 1))
        }
        let text = FeatureFileText.plainText(insert)
        guard !text.isEmpty else { return }
        let live = sequence.liveChars
        let at = before == .zero ? live.count : sequence.offset(of: before) ?? live.count
        let left = live.prefix(at).last { !removing.contains($0) } ?? .zero
        let right = before != .zero && sequence.contains(before) ? before : .zero
        builder.append(Ops.textInsert(WellKnown.settings, field, text, left: left, right: right))
    }
}

extension FeatureFileText {
    /// `text` as the feature file holds it: newlines for returns, no other C0 controls but tab.
    static func plainText(_ text: String) -> String {
        FontInfo.plain(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    }
}

/// What the Features editor reads of the font besides its text: the glyph names the checker
/// knows (every exported glyph, plus the standard glyphs generation may add), the generated
/// feature text and its tags.
public struct FeatureFileContext: Hashable, Sendable {
    public let glyphs: [String]
    public let generated: String
    public let generatedTags: Set<String>

    public init(_ state: EngineState) {
        let source = FontGeneration.featureSource(state)
        glyphs = FontValidation.featureGlyphNames(GlyphIndex(state))
        generated = FeatureGenerator.generated(source)
        generatedTags = FeatureGenerator.generatedTags(source)
    }

    /// Checks `text` as generation will.
    public func check(_ text: String) -> FeatureChecker.Report {
        FeatureChecker.check(text, glyphs: glyphs, generated: generatedTags)
    }
}
