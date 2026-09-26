// FONT-019: `FeatureChecker` (opentype-features.adoc, "Client"): the user's feature text checked
// against the font -- syntax errors and unsupported constructs with line and column, unknown glyph
// and class names (with the nearest glyph name for the editor's tooltip), duplicate definitions,
// features that are also generated (combined, yours first), the reserved `kern1.`/`kern2.` class
// prefix -- and the list of feature tags for the Metrics window's Features pop-up.  It runs the
// compiler's resolution pass, so text that checks clean compiles.  Also the glyph-name occurrences
// that *Rename in feature file* rewrites.

/// Checks feature text.
public enum FeatureChecker {
    /// What a check found.
    public struct Report: Hashable, Sendable {
        /// Every problem, in text order.
        public var issues: [FeatureIssue]
        /// The feature tags the text defines, in order.
        public var featureTags: [String]

        /// Whether nothing blocks generation.
        public var isClean: Bool { !issues.contains { $0.severity == .error } }

        public var errors: [FeatureIssue] { issues.filter { $0.severity == .error } }
    }

    /// Checks the user's `text` for a font with `glyphs` (names in glyph-id order); `generated`
    /// names the features the generator will add (a user feature with one of those tags is
    /// combined with it, reported as a warning).
    public static func check(_ text: String, glyphs: [String], generated: Set<String> = []) -> Report {
        let compiled = FeatureCompiler.compile(text, glyphs: glyphs)
        var issues = compiled.issues
        let parsed = FeatureParser.parse(text)
        var seen: [String: FeatureLocation] = [:]
        for statement in parsed.statements {
            guard case .feature(let tag, _, let location) = statement else { continue }
            if seen[tag] != nil {
                issues.append(FeatureIssue(.warning, .duplicate, "The feature \(tag) is defined again; its rules are added to the earlier block's.",
                                           at: location, name: tag))
            } else if generated.contains(tag) {
                issues.append(FeatureIssue(.warning, .generated, "The feature \(tag) is also generated; your rules come first, then the generated ones.",
                                           at: location, name: tag))
            }
            seen[tag] = seen[tag] ?? location
        }
        issues = issues.enumerated().sorted { ($0.element.location, $0.offset) < ($1.element.location, $1.offset) }.map(\.element)
        return Report(issues: issues, featureTags: compiled.featureTags)
    }

    /// The glyph name in `names` nearest to `name` by edit distance (at most a third of its
    /// length, and at most 3), nil when none is that close.
    public static func nearestName(to name: String, in names: [String]) -> String? {
        let target = Array(name.unicodeScalars)
        let limit = min(3, max(1, target.count / 3))
        var best: (name: String, distance: Int)?
        for candidate in names {
            let other = Array(candidate.unicodeScalars)
            guard abs(other.count - target.count) <= limit else { continue }
            let distance = editDistance(target, other, limit: limit)
            if distance <= limit, distance < (best?.distance ?? .max) { best = (candidate, distance) }
        }
        return best?.name
    }

    /// Levenshtein distance, cut off above `limit`.
    static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], limit: Int) -> Int {
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if row.min()! > limit { return limit + 1 }
            previous = row
        }
        return previous[b.count]
    }

    /// Where the glyph name `name` is written in `text` as a glyph of a rule, class or mark class
    /// (not a keyword, tag, lookup or class name, nor part of a longer name): scalar offset
    /// ranges, in order.  Text that does not parse is searched in the statements that do.
    public static func occurrences(of name: String, in text: String) -> [Range<Int>] {
        let parsed = FeatureParser.parse(text)
        var locations: Set<FeatureLocation> = []
        func visit(_ glyphs: FeatureGlyphs) {
            for item in glyphs.items {
                switch item {
                case .glyph(let found, let location) where found == name: locations.insert(location)
                case .range(let first, let last, let location):
                    // The endpoints of a spaced range: the first at the item, the last after it.
                    if first == name { locations.insert(location) }
                    if last == name, let token = parsed.tokens.first(where: { $0.location > location && $0.kind == .name(last, escaped: false) }) {
                        locations.insert(token.location)
                    }
                default: break
                }
            }
        }
        func visit(_ statements: [FeatureStatement]) {
            for statement in statements {
                switch statement {
                case .classDefinition(_, let glyphs, _), .markClass(let glyphs, _, _, _): visit(glyphs)
                case .feature(_, let body, _), .lookup(_, let body, _): visit(body)
                case .glyphClassDefinition(let sets, _): sets.compactMap { $0 }.forEach(visit)
                case .substitute(let rule):
                    rule.elements.forEach { visit($0.glyphs) }
                    rule.replacement.forEach(visit)
                    rule.alternates.map(visit)
                case .position(let rule):
                    rule.elements.forEach { visit($0.glyphs) }
                    switch rule.kind {
                    case .markToBase(let glyphs, _), .markToMark(let glyphs, _): visit(glyphs)
                    case .sequence: break
                    }
                default: break
                }
            }
        }
        visit(parsed.statements)
        return parsed.tokens.compactMap { token in
            guard locations.contains(token.location), case .name(_, let escaped) = token.kind else { return nil }
            // `\name` keeps its backslash: the name follows it.
            return escaped ? (token.offset + 1)..<(token.offset + token.length) : token.offset..<(token.offset + token.length)
        }
    }
}
