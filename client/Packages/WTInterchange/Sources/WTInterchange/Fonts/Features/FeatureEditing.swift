// FONT-022: what the Features editor needs from the feature-file grammar (opentype-features.adoc,
// "The Features editor"): the spans its syntax colouring paints, brace matching, the glyph and
// class names Control-Space completes after a `sub` or `pos`, where a checker issue stands in the
// text (a line and column to a scalar offset, the underline under an unknown name) and the two
// classes *Insert Class from Suffix…* writes.  Everything counts Unicode scalars, as
// `FeatureLocation` columns do; the editor converts to its view's units.

/// One coloured stretch of feature text.
public struct FeatureSpan: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A word the grammar reads as a keyword (`feature`, `sub`, `by`, `lookupflag`, …).
        case keyword
        /// A feature, lookup, script or language tag (`liga`, `DFLT`), or a block's closing tag.
        case tag
        /// A glyph name (`f_i`, `\sub`).
        case glyph
        /// `@name`.
        case className
        case number
        case string
        /// `#` to the end of the line.
        case comment
    }

    public var kind: Kind
    /// Scalar offsets.
    public var range: Range<Int>

    public init(_ kind: Kind, _ range: Range<Int>) {
        self.kind = kind
        self.range = range
    }
}

/// The editor's reading of feature text.
public enum FeatureEditing {
    /// Words after which the next name is a tag.
    static let tagIntroducers: Set<String> = ["feature", "lookup", "script", "language", "table"]
    /// Words that open a rule whose names Control-Space completes.
    static let ruleKeywords: Set<String> = ["sub", "substitute", "pos", "position", "ignore", "rsub", "reversesub", "enum", "enumerate"]

    /// The coloured spans of `text`, in order; whitespace and punctuation are left out.
    public static func spans(_ text: String) -> [FeatureSpan] {
        let tokens = FeatureLexer.tokens(text)
        var spans: [FeatureSpan] = []
        var tagsExpected = 0
        for (position, token) in tokens.enumerated() {
            let range = token.offset..<(token.offset + token.length)
            switch token.kind {
            case .name(let name, let escaped):
                if tagsExpected > 0, !escaped {
                    spans.append(FeatureSpan(.tag, range))
                    tagsExpected -= 1
                } else if !escaped, FeatureGenerator.keywords.contains(name) {
                    spans.append(FeatureSpan(.keyword, range))
                    tagsExpected = tagIntroducers.contains(name) ? 1 : name == "languagesystem" ? 2 : 0
                } else if position > 0, tokens[position - 1].kind == .symbol("}") {
                    spans.append(FeatureSpan(.tag, range))
                } else {
                    spans.append(FeatureSpan(.glyph, range))
                }
            case .className: spans.append(FeatureSpan(.className, range))
            case .number: spans.append(FeatureSpan(.number, range))
            case .string: spans.append(FeatureSpan(.string, range))
            case .symbol: tagsExpected = 0
            }
        }
        return (spans + comments(text, tokens: tokens)).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The comments: a `#` outside every token, to the end of its line.
    static func comments(_ text: String, tokens: [FeatureToken]) -> [FeatureSpan] {
        let scalars = Array(text.unicodeScalars)
        var result: [FeatureSpan] = []
        var next = 0
        var index = 0
        while index < scalars.count {
            while next < tokens.count, tokens[next].offset + tokens[next].length <= index { next += 1 }
            if next < tokens.count, tokens[next].offset <= index {
                index = tokens[next].offset + tokens[next].length
                continue
            }
            if scalars[index] == "#" {
                var end = index
                while end < scalars.count, scalars[end] != "\n" { end += 1 }
                result.append(FeatureSpan(.comment, index..<end))
                index = end
            } else {
                index += 1
            }
        }
        return result
    }

    /// The offset of the bracket matching the one just before `caret` (a closer) or at `caret`
    /// (an opener): `{}`, `[]`, `()`.  Brackets in comments and strings do not count.  Nil when
    /// there is no bracket there or it is unmatched.
    public static func matchingBracket(in text: String, caret: Int) -> Int? {
        let pairs: [Character: Character] = ["{": "}", "[": "]", "(": ")"]
        let closers = Dictionary(uniqueKeysWithValues: pairs.map { ($0.value, $0.key) })
        let brackets = FeatureLexer.tokens(text).compactMap { token -> (Character, Int)? in
            guard case .symbol(let symbol) = token.kind, pairs[symbol] != nil || closers[symbol] != nil else { return nil }
            return (symbol, token.offset)
        }
        if let at = brackets.firstIndex(where: { $0.1 == caret - 1 && closers[$0.0] != nil }) {
            let (closer, _) = brackets[at]
            var depth = 0
            for (symbol, offset) in brackets[..<at].reversed() {
                if symbol == closer { depth += 1 } else if symbol == closers[closer] {
                    if depth == 0 { return offset }
                    depth -= 1
                }
            }
            return nil
        }
        if let at = brackets.firstIndex(where: { $0.1 == caret && pairs[$0.0] != nil }) {
            let (opener, _) = brackets[at]
            var depth = 0
            for (symbol, offset) in brackets[(at + 1)...] {
                if symbol == opener { depth += 1 } else if symbol == pairs[opener] {
                    if depth == 0 { return offset }
                    depth -= 1
                }
            }
        }
        return nil
    }

    // MARK: Completion

    /// What Control-Space completes at `caret`: the partial name before it (with its `@` for a
    /// class) and where it starts; nil unless the caret is in a rule opened by `sub`, `pos`,
    /// `ignore`, `rsub` or `enum`.
    public static func completionPrefix(in text: String, caret: Int) -> (prefix: String, start: Int)? {
        let scalars = Array(text.unicodeScalars)
        guard caret >= 0, caret <= scalars.count else { return nil }
        var start = caret
        while start > 0, FeatureLexer.nameBody.contains(scalars[start - 1]) { start -= 1 }
        if start > 0, scalars[start - 1] == "@" || scalars[start - 1] == "\\" { start -= 1 }
        // The statement so far: back to the last `;`, `{` or `}` outside comments and strings.
        let before = FeatureLexer.tokens(String(String.UnicodeScalarView(scalars[..<start])))
        let statement = before.reversed().prefix { token in
            if case .symbol(let symbol) = token.kind { return !";{}".contains(symbol) }
            return true
        }
        guard let opener = statement.last, case .name(let word, escaped: false) = opener.kind, ruleKeywords.contains(word) else { return nil }
        return (String(String.UnicodeScalarView(scalars[start..<caret])), start)
    }

    /// The names that complete `prefix`: classes (every `@name` the text defines, in order) for a
    /// prefix starting `@`, else the glyph names, in their order, that start with it (written
    /// `\name` where the grammar would read a keyword).  At most `limit`.
    public static func completions(for prefix: String, glyphs: [String], text: String, limit: Int = 200) -> [String] {
        if prefix.hasPrefix("@") {
            return Array(definedClasses(text).map { "@" + $0 }.filter { $0.hasPrefix(prefix) }.prefix(limit))
        }
        let bare = prefix.hasPrefix("\\") ? String(prefix.dropFirst()) : prefix
        return Array(glyphs.filter { $0.hasPrefix(bare) }.map(FeatureGenerator.glyph).prefix(limit))
    }

    /// The class names `text` defines (`@name = …`), in order, each once.
    public static func definedClasses(_ text: String) -> [String] {
        let tokens = FeatureLexer.tokens(text)
        var names: [String] = []
        for (position, token) in tokens.enumerated() {
            guard case .className(let name) = token.kind, position + 1 < tokens.count, tokens[position + 1].kind == .symbol("="),
                  !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    // MARK: Issues in the text

    /// The scalar offset of `location` in `text` (a column past the end of its line clamps to the
    /// line's end); nil for a line the text does not have.
    public static func offset(of location: FeatureLocation, in text: String) -> Int? {
        guard let line = lineRange(location.line, in: text) else { return nil }
        return min(line.lowerBound + max(location.column - 1, 0), line.upperBound)
    }

    /// The scalar range of line `line` (1-based), its newline excluded.
    public static func lineRange(_ line: Int, in text: String) -> Range<Int>? {
        guard line >= 1 else { return nil }
        var current = 1
        var start = 0
        var index = 0
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if current == line { return start..<index }
                current += 1
                start = index + 1
            }
            index += 1
        }
        return current == line ? start..<index : nil
    }

    /// The stretch the editor underlines for `issue`: an unknown glyph or class name, from its
    /// location over the name (its `@` or `\` included); nil for other issues.
    public static func underline(_ issue: FeatureIssue, in text: String) -> Range<Int>? {
        guard let name = issue.name, issue.kind == .unknownGlyph || issue.kind == .unknownName && name.hasPrefix("@"),
              let start = offset(of: issue.location, in: text) else { return nil }
        let scalars = Array(text.unicodeScalars)
        let sigil = issue.kind == .unknownGlyph && start < scalars.count && scalars[start] == "\\" ? 1 : 0
        return start..<min(start + sigil + name.unicodeScalars.count, scalars.count)
    }

    // MARK: Insert Class from Suffix

    /// menu:Edit[Insert Class from Suffix…]: for every glyph in `glyphs` that has a `<name><suffix>`
    /// variant, `@<s>_from = [a b …];` and `@<s>_to = [a.sc b.sc …];` (`<s>` the suffix without
    /// its dot), one line each; nil when no glyph has the variant.
    public static func classesFromSuffix(_ suffix: String, glyphs: [String]) -> String? {
        let trimmed = suffix.trimmingCharacters(in: .whitespaces)
        let dotted = trimmed.hasPrefix(".") ? trimmed : "." + trimmed
        guard dotted.count > 1 else { return nil }
        let names = Set(glyphs)
        let bases = glyphs.filter { !$0.hasSuffix(dotted) && names.contains($0 + dotted) }
        guard !bases.isEmpty else { return nil }
        let stem = FeatureGenerator.identifier(String(dotted.dropFirst()))
        let from = bases.map(FeatureGenerator.glyph).joined(separator: " ")
        let to = bases.map { FeatureGenerator.glyph($0 + dotted) }.joined(separator: " ")
        return "@\(stem)_from = [\(from)];\n@\(stem)_to = [\(to)];\n"
    }
}
