import CoreGraphics
import CoreText
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange

/// FONT-019: the feature-file grammar, `FeatureChecker`, `FeatureGenerator` and the compiler that
/// turns feature text into GSUB, GPOS and GDEF (opentype-features.adoc), checked through the issues
/// they report and through Core Text's layout of compiled fonts.
@Suite struct FeatureFileTests {
    /// A box glyph named `name` for `scalar`.
    static func box(_ name: String, _ scalar: UInt32?, width: Double = 500, kind: FontSource.GlyphKind = .base,
                    anchors: [FontSource.Anchor] = []) -> FontSource.Glyph {
        FontSource.Glyph(name: name, codepoints: scalar.map { [$0] } ?? [], advanceWidth: width,
                         contours: [FontFixture.polygon([(50, 0), (width - 50, 0), (width - 50, 600), (50, 600)])], kind: kind, anchors: anchors)
    }

    /// A font with a–z, A–Z, figures, small caps and tabular figures, ligatures, a swash and two
    /// marks: every name the page's primer and the rules below use.
    static func font(features: String = "", kerning: FontSource.Kerning = .init(), generateMark: Bool = true, generateLiga: Bool = true) -> FontSource {
        var glyphs: [FontSource.Glyph] = [box(".notdef", nil), box("space", 0x20, width: 250)]
        for scalar in UInt32(0x61)...0x7A { glyphs.append(box(String(UnicodeScalar(scalar)!), scalar, anchors: [.init(name: "top", x: 250, y: 600)])) }
        for scalar in UInt32(0x41)...0x5A { glyphs.append(box(String(UnicodeScalar(scalar)!), scalar, width: 600, anchors: [.init(name: "top", x: 300, y: 700)])) }
        let figures = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        for (offset, name) in figures.enumerated() { glyphs.append(box(name, 0x30 + UInt32(offset))) }
        for name in figures { glyphs.append(box(name + ".tf", nil, width: 600)) }
        for scalar in UInt32(0x61)...0x7A { glyphs.append(box(String(UnicodeScalar(scalar)!) + ".sc", nil)) }
        glyphs += [box("A.swash", nil, width: 700), box("c_t", nil, width: 900, kind: .ligature), box("f_i", nil, width: 800, kind: .ligature),
                   box("f_f_i", nil, width: 1_100, kind: .ligature),
                   box("acutecomb", 0x301, width: 0, kind: .mark, anchors: [.init(name: "_top", x: 0, y: 500), .init(name: "top", x: 0, y: 800)]),
                   box("gravecomb", 0x300, width: 0, kind: .mark, anchors: [.init(name: "_top", x: 0, y: 500)]),
                   box("sub", nil)]
        var names = FontSource.Names(family: "Feature", style: "Regular", postscript: "Feature-Regular", full: "Feature Regular")
        names.license = "OFL"
        return FontSource(names: names, metrics: FontSource.Metrics(unitsPerEm: 1_000, ascender: 800, descender: -200), glyphs: glyphs,
                          kerning: kerning, features: features, generateMark: generateMark, generateLiga: generateLiga)
    }

    static var names: [String] { font().glyphs.map(\.name) }

    static func index(_ name: String) -> Int { names.firstIndex(of: name)! }

    static let primer = """
        # Glyph classes: names beginning with @
        @figures = [zero one two three four five six seven eight nine];
        @figures.tf = [zero.tf one.tf two.tf three.tf four.tf five.tf six.tf seven.tf eight.tf nine.tf];

        # A class substitution: tabular figures
        feature tnum {
            sub @figures by @figures.tf;
        } tnum;

        # Small capitals from a suffix
        feature smcp {
            sub [a b c d e f g h i j k l m n o p q r s t u v w x y z]
             by [a.sc b.sc c.sc d.sc e.sc f.sc g.sc h.sc i.sc j.sc k.sc l.sc m.sc
                 n.sc o.sc p.sc q.sc r.sc s.sc t.sc u.sc v.sc w.sc x.sc y.sc z.sc];
        } smcp;

        # A discretionary ligature the automatic liga feature would not make
        feature dlig {
            sub c t by c_t;
        } dlig;

        # A contextual rule: a swash cap only at the start of a word (before a lowercase letter)
        feature swsh {
            sub A' [a b c d e f g h i j k l m n o p q r s t u v w x y z] by A.swash;
        } swsh;
        """

    static func core(_ source: FontSource) throws -> CTFont {
        try #require(FontFixture.coreText(try FontCompiler.compile(source).data))
    }

    /// The glyph names Core Text lays out for `text`, with `features` (tags) turned on.
    static func shaped(_ font: CTFont, _ text: String, features: [String] = []) -> [String] {
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if !features.isEmpty {
            let settings = features.map { [kCTFontOpenTypeFeatureTag: $0, kCTFontOpenTypeFeatureValue: 1] as [CFString: Any] }
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: settings] as CFDictionary)
            attributes[NSAttributedString.Key(kCTFontAttributeName as String)] = CTFontCreateCopyWithAttributes(font, 0, nil, descriptor)
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let graphics = CTFontCopyGraphicsFont(font, nil)
        return (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run -> [String] in
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            return glyphs.map { graphics.name(for: $0) as String? ?? "?" }
        }
    }

    /// The positions Core Text gives each glyph of `text`.
    static func positions(_ font: CTFont, _ text: String) -> [CGPoint] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        return (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run -> [CGPoint] in
            var points = [CGPoint](repeating: .zero, count: CTRunGetGlyphCount(run))
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &points)
            return points
        }
    }

    // MARK: The page's examples and the generated features, through Core Text

    @Test func thePagesPrimerChecksCleanAndCompilesToWorkingSubstitutions() throws {
        let report = FeatureChecker.check(Self.primer, glyphs: Self.names)
        #expect(report.isClean && report.issues.isEmpty && report.errors.isEmpty)
        #expect(report.featureTags == ["tnum", "smcp", "dlig", "swsh"])
        let font = try Self.core(Self.font(features: Self.primer))
        #expect(Self.shaped(font, "12", features: ["tnum"]) == ["one.tf", "two.tf"])
        #expect(Self.shaped(font, "ab", features: ["smcp"]) == ["a.sc", "b.sc"])
        #expect(Self.shaped(font, "ct", features: ["dlig"]) == ["c_t"])
        #expect(Self.shaped(font, "Ab A", features: ["swsh"]) == ["A.swash", "b", "space", "A"])
        // Without the features nothing changes; liga is on by default and generated from names.
        #expect(Self.shaped(font, "12ab") == ["one", "two", "a", "b"])
        #expect(Self.shaped(font, "ffi fi") == ["f_f_i", "space", "f_i"])
    }

    @Test func generatedKerningMatchesTheModelForAThousandRandomPairs() throws {
        let base = Self.index("a")
        let letters = Array(base..<(base + 52))
        var random = SystemRandomNumberGenerator()
        var generator = SeededRandom(seed: 19)
        var pairs: [FontSource.Kerning.Pair] = []
        for _ in 0..<300 {
            pairs.append(.init(left: letters.randomElement(using: &generator)!, right: letters.randomElement(using: &generator)!,
                               value: Int.random(in: -120...60, using: &generator)))
        }
        // Classes partition the letters: five left classes, four right classes, all cells set.
        let left = (0..<5).map { index in letters.filter { ($0 - base) % 5 == index } }
        let right = (0..<4).map { index in letters.filter { ($0 - base) % 4 == index } }
        var cells: [FontSource.Kerning.ClassValue] = []
        for l in 0..<5 { for r in 0..<4 { cells.append(.init(left: l, right: r, value: -(l * 4 + r) * 3)) } }
        let kerning = FontSource.Kerning(pairs: pairs, leftClasses: left, rightClasses: right, classValues: cells,
                                         leftClassNames: ["O", "O", "", "H", "n"], rightClassNames: ["O"])
        let source = Self.font(kerning: kerning, generateMark: false, generateLiga: false)
        let generated = FeatureGenerator.generated(source)
        #expect(generated.contains("@kern1.O = [") && generated.contains("@kern1.O_2 = [") && generated.contains("@kern2.O = ["))
        #expect(generated == FeatureGenerator.generated(source))
        let font = try Self.core(source)
        let names = source.glyphs.map(\.name)
        for _ in 0..<1_000 {
            let l = letters.randomElement(using: &random)!, r = letters.randomElement(using: &random)!
            let text = String(UnicodeScalar(source.glyphs[l].codepoints[0])!) + String(UnicodeScalar(source.glyphs[r].codepoints[0])!)
            let x = Self.positions(font, text)
            #expect(Int((x[1].x - x[0].x).rounded()) - Int(source.glyphs[l].advanceWidth) == kerning.value(l, r), "\(names[l]) \(names[r])")
        }
    }

    @Test func generatedMarksPositionAccentsOnBasesAndOnEachOther() throws {
        let source = Self.font()
        let generated = FeatureGenerator.generated(source)
        #expect(generated.contains("markClass acutecomb <anchor 0 500> @MC_top;"))
        #expect(generated.contains("pos base a <anchor 250 600> mark @MC_top;"))
        #expect(generated.contains("pos mark acutecomb <anchor 0 800> mark @MC_top;"))
        #expect(generated.contains("table GDEF {") && generated.contains("sub f i by f_i;") && generated.contains("sub f f i by f_f_i;"))
        #expect(FeatureGenerator.generatedTags(source) == ["mark", "mkmk", "liga"])
        let font = try Self.core(source)
        let a = Self.positions(font, "a\u{301}")
        #expect(abs(a[1].x - 250) < 0.5 && abs(a[1].y - 100) < 0.5)
        let stacked = Self.positions(font, "a\u{301}\u{300}")
        #expect(abs(stacked[2].y - 400) < 0.5)
        // Switched off: nothing generated but the GDEF classes.
        let off = Self.font(generateMark: false, generateLiga: false)
        #expect(FeatureGenerator.generatedTags(off).isEmpty && FeatureGenerator.generated(off).hasPrefix("table GDEF"))
        let plain = FontSource(names: off.names, glyphs: [Self.box(".notdef", nil)])
        #expect(FeatureGenerator.generated(plain).isEmpty && FeatureGenerator.file(user: "", generated: "").text == "languagesystem DFLT dflt;\n")
    }

    @Test func generatedNamesAreEscapedAndUniqueAndTheFileMapsLinesBack() {
        #expect(FeatureGenerator.glyph("sub") == "\\sub" && FeatureGenerator.glyph("a.sc") == "a.sc" && FeatureGenerator.glyph("1x") == "\\1x")
        #expect(FeatureGenerator.glyph("") == "\\")
        #expect(FeatureGenerator.identifier("a b-c") == "a_b_c" && FeatureGenerator.identifier("") == "class")
        #expect(FeatureGenerator.unique(["O", "O", "O", "P"]) == ["O", "O_2", "O_3", "P"])
        let file = FeatureGenerator.file(user: "feature ss01 { sub a by b; } ss01;", generated: "feature kern { pos a b -5; } kern;\n")
        #expect(file.userFirstLine == 2 && file.generatedFirstLine == 3)
        #expect(file.userLocation(FeatureLocation(line: 2, column: 4)) == FeatureLocation(line: 1, column: 4))
        #expect(file.userLocation(FeatureLocation(line: 1, column: 1)) == nil && file.userLocation(FeatureLocation(line: 4, column: 1)) == nil)
        let own = FeatureGenerator.file(user: "languagesystem latn dflt;\n", generated: "")
        #expect(own.userFirstLine == 1 && own.generatedFirstLine == nil && own.userLocation(FeatureLocation(line: 9, column: 1)) != nil)
        // A kerning class whose members are all out of range is left out; so are its cells.
        var source = Self.font(kerning: FontSource.Kerning(pairs: [.init(left: 9_999, right: 2, value: -5)], leftClasses: [[9_999], [2]],
                                                           rightClasses: [[3]], classValues: [.init(left: 0, right: 0, value: -1),
                                                                                              .init(left: 1, right: 0, value: -2),
                                                                                              .init(left: 1, right: 0, value: -3),
                                                                                              .init(left: 7, right: 0, value: -3)]))
        source.generateMark = false
        let kern = FeatureGenerator.kern(source)
        #expect(kern.contains("pos @kern1.a @kern2.b -2;") && !kern.contains("-3") && !kern.contains("-5"))
        // A ligature whose parts are missing is not generated.
        source.glyphs.append(Self.box("q_zz", nil, kind: .ligature))
        source.glyphs.append(Self.box("x_y.alt", nil, kind: .ligature))
        #expect(!FeatureGenerator.liga(source).contains("q_zz") && !FeatureGenerator.liga(source).contains("x_y.alt"))
    }

    // MARK: Everything the grammar supports compiles

    @Test func everySupportedStatementCompiles() throws {
        let text = """
            languagesystem DFLT dflt;
            languagesystem latn dflt;
            languagesystem latn TRK;
            @vowels = [a e i o u];
            @range = [a-e];
            @spaced = [A - E];
            @digits = [zero one];
            @nested = [@vowels z];
            markClass [acutecomb] <anchor 0 500> @TOP;
            markClass gravecomb <anchor 0 500> @TOP;
            lookup STANDALONE {
                sub a by b;
            } STANDALONE;
            lookup MOVE useExtension {
                pos a 10;
            } MOVE;
            table GDEF {
                GlyphClassDef [a b], [f_i], [acutecomb gravecomb], ;
            } GDEF;
            feature ss01 useExtension {
                sub @range by [A B C D E];
                sub \\sub by z;
                sub x by y z;
                sub y from [a b c];
                sub f f by f_f_i;
                sub [c d] t by c_t;
                subtable;
                lookup STANDALONE;
                lookup INNER {
                    lookupflag IgnoreMarks;
                    sub q by r;
                } INNER;
                script latn;
                language TRK exclude_dflt;
                sub w by v;
                language DEU include_dflt;
                sub v by w;
            } ss01;
            feature calt {
                lookupflag RightToLeft IgnoreBaseGlyphs IgnoreLigatures;
                sub a' b by c;
                sub a' b' by c_t;
                sub e' by f g;
                sub g' h from [i j];
                sub k' lookup STANDALONE l;
                ignore sub m' n;
                lookupflag 0;
            } calt;
            feature kern {
                pos a 20;
                pos b <10 0 20 0>;
                pos c <NULL>;
                pos a b -10;
                pos [c d] [e f] <0 0 -20 0>;
                subtable;
                pos @vowels @digits -5;
                enum pos [g h] i -7;
                pos j' 30 k;
                pos l' lookup MOVE m;
                ignore pos n' o;
                pos base [a b] <anchor 250 600> mark @TOP;
                pos mark acutecomb <anchor 0 800> mark @TOP <anchor NULL> mark @TOP;
            } kern;
            feature mkmk {
                pos mark gravecomb <anchor 0 900> mark @TOP;
            } mkmk;
            """
        let compiled = FeatureCompiler.compile(text, glyphs: Self.names)
        #expect(compiled.isClean, "\(compiled.issues)")
        #expect(compiled.gsub != nil && compiled.gpos != nil && compiled.gdef != nil)
        #expect(compiled.featureTags == ["ss01", "calt", "kern", "mkmk"])
        let font = try Self.core(Self.font(features: text))
        // STANDALONE (a → b) is the first lookup, so a becomes b, then B; y takes its first alternate.
        #expect(Self.shaped(font, "a", features: ["ss01"]) == ["B"])
        #expect(Self.shaped(font, "x", features: ["ss01"]) == ["a", "z"])
    }

    @Test func inferredGlyphClassesAndLargeLookupsCompile() throws {
        // No GDEF block: mark classes and `pos base` glyphs give the classes.
        let inferred = FeatureCompiler.compile("markClass acutecomb <anchor 0 500> @T;\nfeature mark { pos base a <anchor 250 600> mark @T; } mark;",
                                               glyphs: Self.names)
        #expect(inferred.isClean && inferred.gdef != nil)
        #expect(FeatureCompiler.compile("feature liga { sub f i by f_i; } liga;", glyphs: Self.names).gdef == nil)
        #expect(FeatureCompiler.compile("table GDEF { GlyphClassDef , , , ; } GDEF;", glyphs: Self.names).gdef == nil)
        // Thousands of glyphs in single, multiple, ligature, alternate and pair lookups split into subtables.
        let many = (0..<3_000).map { "g\($0)" }
        var rules = "feature ss02 {\n"
        for index in stride(from: 0, to: 3_000, by: 2) { rules += "    sub g\(index) by g\(index + 1);\n" }
        rules += "} ss02;\nfeature ss03 {\n"
        for index in stride(from: 0, to: 3_000, by: 3) { rules += "    sub g\(index) by g\(index + 1) g\(index + 2) g\(index + 1);\n" }
        rules += "} ss03;\nfeature ss04 {\n"
        for index in stride(from: 0, to: 2_997, by: 3) { rules += "    sub g\(index) g\(index + 1) g\(index + 2) by g\(index);\n" }
        rules += "} ss04;\nfeature ss05 {\n"
        for index in stride(from: 0, to: 3_000, by: 5) { rules += "    sub g\(index) from [g1 g2 g3 g4 g5 g6 g7 g8];\n" }
        rules += "} ss05;\nfeature kern {\n"
        for index in stride(from: 0, to: 2_400, by: 2) { rules += "    pos g\(index) [g1 g3 g5 g7 g9 g11 g13] <5 5 -20 0>;\n" }
        rules += "    pos [g0 g1 g2] [g3 g4] -9;\n    pos [g0 g1] [g5] -8;\n    pos [g2 g9] [g4] -7;\n} kern;\n"
        rules += "feature ss06 {\n"
        for index in stride(from: 0, to: 3_000, by: 1) { rules += "    pos g\(index) <0 \(index % 90) 0 0>;\n" }
        rules += "} ss06;\n"
        let compiled = FeatureCompiler.compile(rules, glyphs: many)
        #expect(compiled.isClean, "\(compiled.issues.prefix(3))")
        #expect((compiled.gsub?.count ?? 0) > 20_000 && (compiled.gpos?.count ?? 0) > 20_000)
    }

    // MARK: Problems, with line and column

    /// Thirty malformed texts and the first error each reports.
    static let malformed: [(text: String, line: Int, column: Int, kind: FeatureIssue.Kind)] = [
        ("feature liga { sub f i by f_i; }", 1, 33, .syntax),
        ("feature liga { sub f i by f_i } liga;", 1, 31, .syntax),
        ("feature liga {\n  sub f i f_i;\n} liga;", 2, 14, .syntax),
        ("feature ss01 { sub a by b; } ss02;", 1, 30, .syntax),
        ("featur ss01 { sub a by b; } ss01;", 1, 1, .syntax),
        ("feature toolong { sub a by b; } toolong;", 1, 1, .syntax),
        ("sub a by b;", 1, 1, .syntax),
        ("feature ss01 { languagesystem DFLT dflt; } ss01;", 1, 16, .syntax),
        ("feature ss01 { sub a by nothere; } ss01;", 1, 25, .unknownGlyph),
        ("feature ss01 { sub @missing by b; } ss01;", 1, 20, .unknownName),
        ("@c = [a b];\n@c = [d];", 2, 1, .duplicate),
        ("feature ss01 { sub [a b c] by [d e]; } ss01;", 1, 16, .invalidRule),
        ("feature ss01 { sub a b by c d; } ss01;", 1, 16, .unsupported),
        ("feature ss01 { sub a by NULL; } ss01;", 1, 25, .unsupported),
        ("feature ss01 { rsub a by b; } ss01;", 1, 16, .unsupported),
        ("table head { FontRevision 1.1; } head;", 1, 1, .unsupported),
        ("feature ss01 { pos cursive a <anchor 0 0> <anchor 0 0>; } ss01;", 1, 16, .unsupported),
        ("feature ss01 { lookupflag MarkAttachmentType @m; } ss01;", 1, 27, .unsupported),
        ("feature ss01 { lookup NOPE; } ss01;", 1, 16, .unknownName),
        ("feature ss01 { sub a' b' c by d; sub e' f g' by h; } ss01;", 1, 34, .syntax),
        ("feature ss01 { language DEU; } ss01;\nlanguagesystem DFLT dflt;\nlanguagesystem latn dflt;", 2, 1, .syntax),
        ("feature ss01 { pos a b c 10; } ss01;", 1, 16, .unsupported),
        ("feature ss01 { pos a; } ss01;", 1, 16, .syntax),
        ("feature ss01 { pos base a <anchor 1 1> mark @NONE; } ss01;", 1, 16, .unknownName),
        ("markClass a <anchor NULL> @M;", 1, 1, .syntax),
        ("@c = [];", 1, 6, .syntax),
        ("@c = [a b", 1, 10, .syntax),
        ("feature ss01 { sub [a-zz] by b; } ss01;", 1, 21, .unknownGlyph),
        ("lookup L { sub a by b; pos a 1; } L;", 1, 24, .invalidRule),
        ("feature ss01 { ignore sub a b; } ss01;", 1, 16, .syntax),
    ]

    @Test func thirtyMalformedTextsReportTheirLineAndColumn() {
        #expect(Self.malformed.count == 30)
        for fixture in Self.malformed {
            let report = FeatureChecker.check(fixture.text, glyphs: Self.names)
            let first = report.errors.first
            #expect(!report.isClean, "\(fixture.text)")
            #expect(first?.location == FeatureLocation(line: fixture.line, column: fixture.column) && first?.kind == fixture.kind,
                    "\(fixture.text): \(report.errors.map { "\($0.location.line):\($0.location.column) \($0.kind) \($0.message)" })")
        }
    }

    @Test func moreProblemsAreReportedAndRecoveredFrom() {
        func errors(_ text: String) -> [String] { FeatureCompiler.compile(text, glyphs: Self.names).issues.map(\.message) }
        func has(_ text: String, _ fragment: String) -> Bool { errors(text).contains { $0.contains(fragment) } }
        #expect(has("feature ss01 { sub aa by b; } ss01;", "did you mean a?"))
        #expect(has("feature ss01 { sub a from [b c]; sub a b from [c d]; } ss01;", "replaces one glyph"))
        #expect(has("feature ss01 { sub a' from [b c]; sub [a b]' c' from [d]; } ss01;", "replaces one glyph"))
        #expect(has("feature ss01 { sub a by [b c] d; } ss01;", "sequence of single glyphs"))
        #expect(has("feature ss01 { sub a' by [b c] d; } ss01;", "sequence of single glyphs"))
        #expect(has("feature ss01 { sub a b by [c d]; } ss01;", "one glyph"))
        #expect(has("feature ss01 { sub a' b' by [c d]; } ss01;", "one glyph"))
        #expect(has("feature ss01 { sub a' b' by c d; } ss01;", "Many-to-many"))
        #expect(has("feature ss01 { sub [a-z] [a-z] [a-z] by b; } ss01;", "expands to 17576"))
        #expect(has("feature ss01 { sub [a b]' by [c d e]; } ss01;", "differ in size"))
        #expect(has("feature ss01 { sub a' lookup L by b; } ss01;", "not defined"))
        #expect(has("lookup P { pos a 1; } P;\nfeature ss01 { sub a' lookup P b; } ss01;", "positioning lookup"))
        #expect(has("lookup S { sub a by b; } S;\nfeature ss01 { pos a' lookup S b; } ss01;", "substitution lookup"))
        #expect(has("lookup S { sub a by b; } S;\nfeature ss01 { sub a' lookup S by c; } ss01;", "either lookups or an inline replacement"))
        #expect(has("lookup S { sub a by b; } S;\nfeature ss01 { sub a lookup S b; } ss01;", "follows a marked glyph"))
        #expect(has("lookup S { sub a by b; } S;\nfeature ss01 { sub a b' c lookup S; } ss01;", "follow marked glyphs"))
        #expect(has("lookup P { pos a 1; } P;\nfeature ss01 { pos a' lookup P 5 b; } ss01;", "value or lookups"))
        #expect(has("lookup L { sub a by b; } L;\nlookup L { sub c by d; } L;", "defined twice"))
        #expect(has("lookup L { lookupflag 0; } L;", "has no rules"))
        #expect(has("lookup L { sub a by b; lookupflag IgnoreMarks; } L;", "must come before"))
        #expect(has("lookup L { script latn; sub a by b; } L;", "Only rules"))
        #expect(has("markClass acutecomb <anchor 0 1> @M;\nfeature mark { pos base a <anchor 1 1> mark @M; } mark;\nmarkClass gravecomb <anchor 0 1> @M;",
                    "extended after it is used"))
        #expect(has("markClass acutecomb <anchor 0 1> @M;\nmarkClass acutecomb <anchor 0 2> @N;\nfeature mark { pos base a <anchor 1 1> mark @M <anchor 2 2> mark @N; } mark;",
                    "two mark classes"))
        #expect(has("@M = [a];\nmarkClass acutecomb <anchor 0 1> @M;", "already a glyph class"))
        #expect(has("@kern1.x = [a];", "reserved"))
        #expect(has("languagesystem DFLT dflt;\nlanguagesystem DFLT dflt;", "declared twice"))
        #expect(has("table GDEF { GlyphClassDef [a],,,; } GDEF;\ntable GDEF { GlyphClassDef [b],,,; } GDEF;", "given twice"))
        #expect(has("feature ss01 { sub a by b; sub a by c; } ss01;", "already substituted"))
        #expect(has("feature ss01 { sub [A-a] by b; } ss01;", "not in the font"))
        #expect(has("feature ss01 { sub [a - zz] by b; } ss01;", "not a glyph range"))
        #expect(has("@c = [aa-ab];", "not in the font"))
        #expect(has("feature ss01 { sub [a-c.sc] by b; } ss01;", "not in the font"))
        // The parser's own messages, recovering at the next statement.
        #expect(has("lookup L;", "belongs inside a feature"))
        #expect(has("}", "Unexpected '}'"))
        #expect(has("feature ss01 { sub a by b;", "Missing '}'"))
        #expect(has("table GDEF { LigatureCaretByPos f_i 100; } GDEF;", "Only GlyphClassDef"))
        #expect(has("table GDEF { GlyphClassDef [a],,,; } GDEX;", "Expected 'GDEF'"))
        #expect(has("feature ss01 { language DEU required; } ss01;", "not supported in a language"))
        #expect(has("feature ss01 { lookupflag 99; } ss01;", "Only the RightToLeft"))
        #expect(has("feature ss01 { ignore x; } ss01;", "Expected 'sub' or 'pos'"))
        #expect(has("feature ss01 { enum sub a by b; } ss01;", "Expected 'pos'"))
        #expect(has("enum pos a b 1;", "not allowed outside"))
        #expect(has("frobnicate;", "Unknown statement"))
        #expect(has("feature ss01 { sub by b; } ss01;", "Expected glyphs after 'sub'"))
        #expect(has("feature ss01 { sub a by; } ss01;", "Expected replacement glyphs"))
        #expect(has("feature ss01 { pos by; } ss01;", "Expected glyphs after 'pos'"))
        #expect(has("feature ss01 { ignore pos a b; } ss01;", "needs a marked glyph"))
        #expect(has("feature ss01 { pos base a <anchor 1 1> x; } ss01;", "Expected 'mark'"))
        #expect(has("feature ss01 { pos base a; } ss01;", "Expected '<anchor x y> mark @class'"))
        #expect(has("feature ss01 { pos base a <x 1 1> mark @M; } ss01;", "Expected 'anchor'"))
        #expect(has("feature ss01 { pos base a <anchor 1 1 contourpoint 2> mark @M; } ss01;", "Only '<anchor x y>'"))
        #expect(has("feature ss01 { pos a <1 2 3>; } ss01;", "Expected a number"))
        #expect(has("feature ss01 { pos a <1 2 3 4 5>; } ss01;", "Only four-number"))
        #expect(has("feature ss01 { pos a <NULL x>; } ss01;", "Expected '>'"))
        #expect(has("feature ss01 { sub [a 5] by b; } ss01;", "in the brackets"))
        #expect(has("@c = 5;", "Expected a glyph or class"))
        #expect(has("@c =", "at the end of the file"))
        #expect(has("markClass a <anchor 1 1> x;", "Expected a class name"))
        #expect(has("feature ss01 { lookupflag x; } ss01;", "is not supported"))
        #expect(has("feature \"x\" { } x;", "Expected a feature tag before a string"))
        #expect(has("feature ss01 { sub a by b; } \n", "Expected 'ss01' after '}' at the end of the file"))
        #expect(has("languagesystem latn 5;", "before '5'"))
        #expect(has("languagesystem latn @x;", "before '@x'"))
        #expect(has("languagesystem latn {;", "before '{'"))
        #expect(has("feature ss01 { lookup L { sub a by b; } } ss01;", "Expected 'L' after '}'"))
        #expect(has("feature ss01 { lookup L { sub a by b; } L; lookup L2 { sub c by d; } L2 } ss01;", "Expected ';'"))
    }

    @Test func languageSystemsScriptsAndLanguagesGroupLookups() {
        let text = """
            languagesystem DFLT dflt;
            languagesystem latn dflt;
            feature ss01 {
                sub a by b;
                script latn;
                language DEU;
                sub c by d;
                language TRK exclude_dflt;
                sub e by f;
                language TRK;
                sub g by h;
            } ss01;
            feature ss01 {
                sub i by j;
            } ss01;
            feature ss02 {
                language FRA;
                sub k by l;
            } ss02;
            """
        let compiled = FeatureCompiler.compile(text, glyphs: Self.names)
        #expect(compiled.issues.first?.message.contains("needs a script statement") == true)
        let single = "languagesystem latn dflt;\nfeature ss02 { language FRA; sub k by l; } ss02;"
        #expect(FeatureCompiler.compile(single, glyphs: Self.names).isClean)
        let report = FeatureChecker.check(text, glyphs: Self.names, generated: ["ss02"])
        #expect(report.issues.contains { $0.kind == .duplicate && $0.location.line == 13 })
        let generated = FeatureChecker.check("feature liga { sub c t by c_t; } liga;", glyphs: Self.names, generated: ["liga"])
        #expect(generated.issues.map(\.kind) == [.generated] && generated.isClean)
        #expect(FeatureLanguageSystem(script: "latn", language: "dflt") < FeatureLanguageSystem(script: "latn", language: "AAA"))
    }

    @Test func theCompilerReportsFeatureErrorsAtTheirLinesAndBlocksGeneration() throws {
        var source = Self.font(features: "feature ss01 {\n    sub a by nothere;\n} ss01;")
        let diagnostics = FontCompiler.check(source)
        #expect(diagnostics.contains { $0.severity == .error && $0.line == 2 && $0.column == 14 && $0.glyph == "nothere" })
        #expect(throws: FontCompiler.Failure.self) { try FontCompiler.compile(source) }
        source.features = "feature liga { sub c t by c_t; } liga;"
        #expect(try FontCompiler.compile(source).diagnostics.isEmpty)
        // A generator bug (here: a glyph with a name the grammar cannot read, reached only through
        // the generated text) is reported on no line.
        source.features = ""
        source.glyphs.append(Self.box("x;y", nil, kind: .ligature))
        source.glyphs.append(Self.box("x_y", nil, kind: .ligature))
        source.glyphs.append(Self.box("dot", nil, kind: .mark, anchors: [.init(name: "_top", x: 0, y: 0)]))
        source.glyphs[Self.index("a")].anchors.append(.init(name: "top", x: 1, y: 1))
        #expect(throws: FontCompiler.Failure.self) { try FontCompiler.compile(source) }
        let direct = FontCompiler.diagnostic(FeatureIssue(.warning, .duplicate, "twice", at: FeatureLocation(line: 3, column: 4)))
        #expect(direct.severity == .warning && direct.line == 3 && direct.glyph == nil)
    }

    // MARK: Checker details and Rename in feature file

    @Test func nearestNamesAndEditDistance() {
        #expect(FeatureChecker.nearestName(to: "Aacute", in: ["Aacute.sc", "aacute", "A"]) == "aacute")
        #expect(FeatureChecker.nearestName(to: "zzzzzz", in: ["a", "b"]) == nil)
        #expect(FeatureChecker.nearestName(to: "ab", in: ["abcdefgh"]) == nil)
        #expect(FeatureChecker.editDistance(Array("".unicodeScalars), Array("abc".unicodeScalars), limit: 5) == 3)
        #expect(FeatureChecker.editDistance(Array("abc".unicodeScalars), Array("".unicodeScalars), limit: 5) == 3)
        #expect(FeatureChecker.editDistance(Array("abcdef".unicodeScalars), Array("uvwxyz".unicodeScalars), limit: 2) == 3)
    }

    @Test func renameFindsOnlyGlyphOccurrences() {
        let text = """
            @a = [a b a.sc];   # a in a comment
            markClass a <anchor 0 0> @m;
            feature aalt { sub a by \\a; sub [a - c] by b; sub b from [a]; sub x - a by b; } aalt;
            lookup a { pos a' 5 b; pos base a <anchor 1 1> mark @m; } a;
            table GDEF { GlyphClassDef [a], , , ; } GDEF;
            feature ss01 { sub a b' by c; ignore sub a' b; } ss01;
            """
        let ranges = FeatureChecker.occurrences(of: "a", in: text)
        let scalars = Array(text.unicodeScalars)
        #expect(ranges.allSatisfy { String(String.UnicodeScalarView(scalars[$0])) == "a" })
        #expect(ranges.count == 11)
        #expect(FeatureChecker.occurrences(of: "c", in: text).count == 2)
        #expect(FeatureChecker.occurrences(of: "sub", in: "feature ss01 { sub \\sub by a; } ss01;").count == 1)
    }

    @Test func theLexerReadsNumbersNamesStringsAndComments() {
        let tokens = FeatureLexer.tokens("a1 -12 12 1a \\sub @x \"two\nlines\" # c\n{ -x 3-4")
        let kinds = tokens.map(\.kind)
        #expect(kinds[0] == .name("a1", escaped: false) && kinds[1] == .number(-12) && kinds[2] == .number(12))
        #expect(kinds[3] == .name("1a", escaped: false) && kinds[4] == .name("sub", escaped: true) && kinds[5] == .className("x"))
        #expect(kinds[6] == .string("two\nlines") && tokens[7].location == FeatureLocation(line: 3, column: 1))
        #expect(kinds[8] == .symbol("-") && kinds[9] == .name("x", escaped: false))
        #expect(kinds.dropFirst(10).first == .number(3))
        #expect(FeatureLexer.tokens("\"open").first?.kind == .string("open"))
        #expect(FeatureLexer.tokens("@").first?.kind == .symbol("@"))
        #expect(FeatureLocation(line: 1, column: 2) < FeatureLocation(line: 2, column: 1))
    }
}

/// A small deterministic generator (SplitMix64).
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
