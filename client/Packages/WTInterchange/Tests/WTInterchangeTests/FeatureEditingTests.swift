import Testing
@testable import WTInterchange

/// FONT-022: the Features editor's reading of feature text -- colouring spans, bracket matching,
/// completion, issue positions and *Insert Class from Suffix…* (opentype-features.adoc).
@Suite struct FeatureEditingTests {
    static let sample = """
        languagesystem DFLT dflt; # default
        @figures = [zero one];
        feature liga {
            sub f i by f_i; # "quoted # not a comment"
            sub \\sub by 12;
        } liga;
        table GDEF { GlyphClassDef , , , ; } GDEF;
        name "a # b";
        """

    func text(_ range: Range<Int>, in text: String = sample) -> String {
        String(String.UnicodeScalarView(Array(text.unicodeScalars)[range]))
    }

    @Test func spansColourEveryKind() {
        let spans = FeatureEditing.spans(Self.sample)
        func kinds(_ kind: FeatureSpan.Kind) -> [String] { spans.filter { $0.kind == kind }.map { text($0.range) } }
        #expect(kinds(.keyword) == ["languagesystem", "feature", "sub", "by", "sub", "by", "table", "GlyphClassDef"])
        #expect(kinds(.tag) == ["DFLT", "dflt", "liga", "liga", "GDEF", "GDEF"])
        #expect(kinds(.glyph) == ["zero", "one", "f", "i", "f_i", "\\sub", "name"])
        #expect(kinds(.className) == ["@figures"])
        #expect(kinds(.number) == ["12"])
        #expect(kinds(.string) == ["\"a # b\""])
        #expect(kinds(.comment) == ["# default", "# \"quoted # not a comment\""])
        #expect(spans.map(\.range.lowerBound) == spans.map(\.range.lowerBound).sorted())
        #expect(FeatureEditing.spans("").isEmpty)
    }

    @Test func bracketsMatchOutsideComments() {
        let text = "feature a { sub [x y] by z; # }\n} a;"
        let scalars = Array(text.unicodeScalars)
        let open = scalars.firstIndex(of: "{")!
        let close = scalars.lastIndex(of: "}")!
        let square = scalars.firstIndex(of: "[")!
        let squareClose = scalars.firstIndex(of: "]")!
        #expect(FeatureEditing.matchingBracket(in: text, caret: close + 1) == open)
        #expect(FeatureEditing.matchingBracket(in: text, caret: open) == close)
        #expect(FeatureEditing.matchingBracket(in: text, caret: squareClose + 1) == square)
        #expect(FeatureEditing.matchingBracket(in: text, caret: square) == squareClose)
        #expect(FeatureEditing.matchingBracket(in: text, caret: 3) == nil)
        // Nested, and unmatched either way.
        #expect(FeatureEditing.matchingBracket(in: "{{}}", caret: 4) == 0 && FeatureEditing.matchingBracket(in: "{{}}", caret: 0) == 3)
        #expect(FeatureEditing.matchingBracket(in: "x}", caret: 2) == nil && FeatureEditing.matchingBracket(in: "{x", caret: 0) == nil)
        #expect(FeatureEditing.matchingBracket(in: "(a)", caret: 3) == 0)
    }

    @Test func completionOnlyInRules() throws {
        let text = "@caps = [A B];\nfeature liga {\n    sub f_ i by @ca"
        let count = text.unicodeScalars.count
        let classPrefix = try #require(FeatureEditing.completionPrefix(in: text, caret: count))
        #expect(classPrefix.prefix == "@ca" && classPrefix.start == count - 3)
        let glyph = try #require(FeatureEditing.completionPrefix(in: text, caret: count - 9))
        #expect(glyph.prefix == "f_")
        // Outside a rule, or after the rule ended, nothing completes; a bad caret neither.
        #expect(FeatureEditing.completionPrefix(in: "feature li", caret: 10) == nil)
        #expect(FeatureEditing.completionPrefix(in: "sub a by b; x", caret: 13) == nil)
        #expect(FeatureEditing.completionPrefix(in: "x", caret: 5) == nil && FeatureEditing.completionPrefix(in: "", caret: 0) == nil)
        #expect(FeatureEditing.completionPrefix(in: "pos \\su", caret: 7)?.prefix == "\\su")
        let glyphs = ["f", "f_i", "f_f_i", "sub", "g"]
        #expect(FeatureEditing.completions(for: "f_", glyphs: glyphs, text: text) == ["f_i", "f_f_i"])
        #expect(FeatureEditing.completions(for: "su", glyphs: glyphs, text: text) == ["\\sub"])
        #expect(FeatureEditing.completions(for: "\\su", glyphs: glyphs, text: text) == ["\\sub"])
        #expect(FeatureEditing.completions(for: "@", glyphs: glyphs, text: text + ";\n@lower = [a];\n@caps = [C];") == ["@caps", "@lower"])
        #expect(FeatureEditing.completions(for: "", glyphs: glyphs, text: "", limit: 2) == ["f", "f_i"])
    }

    @Test func issuesFindTheirPlace() throws {
        let text = "feature liga {\n  sub f i by fi;\n  sub \\qq by f;\n  sub i by @nope;\n} liga;"
        #expect(FeatureEditing.lineRange(2, in: text).map { self.text($0, in: text) } == "  sub f i by fi;")
        #expect(FeatureEditing.lineRange(5, in: text).map { self.text($0, in: text) } == "} liga;")
        #expect(FeatureEditing.lineRange(6, in: text) == nil && FeatureEditing.lineRange(0, in: text) == nil)
        #expect(FeatureEditing.offset(of: FeatureLocation(line: 2, column: 3), in: text) == 17)
        #expect(FeatureEditing.offset(of: FeatureLocation(line: 1, column: 99), in: text) == 14)
        #expect(FeatureEditing.offset(of: FeatureLocation(line: 9, column: 1), in: text) == nil)
        let report = FeatureChecker.check(text, glyphs: ["f", "i", "f_i"])
        let underlined = report.issues.compactMap { FeatureEditing.underline($0, in: text) }.map { self.text($0, in: text) }
        #expect(underlined == ["fi", "\\qq", "@nope"])
        // Other issues are not underlined.
        let syntax = FeatureIssue(.error, .syntax, "x", at: FeatureLocation(line: 1, column: 1))
        #expect(FeatureEditing.underline(syntax, in: text) == nil)
        let lookup = FeatureIssue(.error, .unknownName, "x", at: FeatureLocation(line: 1, column: 1), name: "missing")
        #expect(FeatureEditing.underline(lookup, in: text) == nil)
    }

    @Test func classesFromASuffix() {
        let glyphs = ["a", "b", "c", "a.sc", "c.sc", "sub", "sub.sc", "a.sc.sc"]
        #expect(FeatureEditing.classesFromSuffix(".sc", glyphs: glyphs) == "@sc_from = [a c \\sub];\n@sc_to = [a.sc c.sc sub.sc];\n")
        #expect(FeatureEditing.classesFromSuffix(" sc ", glyphs: glyphs) == FeatureEditing.classesFromSuffix(".sc", glyphs: glyphs))
        #expect(FeatureEditing.classesFromSuffix(".alt", glyphs: glyphs) == nil)
        #expect(FeatureEditing.classesFromSuffix(".", glyphs: glyphs) == nil && FeatureEditing.classesFromSuffix("", glyphs: glyphs) == nil)
        // What it writes checks clean.
        let inserted = FeatureEditing.classesFromSuffix(".sc", glyphs: glyphs)! + "feature smcp { sub @sc_from by @sc_to; } smcp;"
        #expect(FeatureChecker.check(inserted, glyphs: glyphs).isClean)
    }
}
