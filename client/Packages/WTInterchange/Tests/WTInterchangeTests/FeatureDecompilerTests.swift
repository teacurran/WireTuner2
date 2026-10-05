import Foundation
import Testing
import WTGeometry
@testable import WTInterchange

/// FONT-025 (rest): a font's layout read back -- anchors from `mark`/`mkmk`, ligature glyphs from
/// `liga`, kinds from GDEF, and every other feature as feature text that compiles to the same
/// tables.  Fonts compiled by WireTuner are read back and compiled again; hand-built tables cover
/// the formats the compiler never writes.
@Suite struct FeatureDecompilerTests {
    /// The raw tables of an sfnt.
    static func tables(_ data: Data) throws -> [String: [UInt8]] {
        let file = FontReader(data, context: "sfnt")
        var result: [String: [UInt8]] = [:]
        for index in 0..<(try file.u16(4)) {
            let entry = 12 + index * 16
            result[try file.tag(entry)] = try file.slice(try file.u32(entry + 8), try file.u32(entry + 12))
        }
        return result
    }

    static let featureText = """
    languagesystem DFLT dflt;
    languagesystem latn dflt;
    languagesystem latn TRK;
    @upper = [A V O];
    lookup alternates {
        sub A from [A.alt A.sc];
    } alternates;
    feature salt {
        lookup alternates;
    } salt;
    feature ss01 {
        sub A by A.alt;
        sub [V O] by [V.alt O.alt];
    } ss01;
    feature ccmp {
        lookupflag IgnoreMarks;
        sub Adieresis by A dieresiscomb;
    } ccmp;
    feature dlig {
        sub f i by fi;
    } dlig;
    feature liga {
        sub f f by ff;
    } liga;
    feature locl {
        script latn;
        language TRK exclude_dflt;
        sub i by idotless;
    } locl;
    feature calt {
        sub f' i by f.short;
        ignore sub A A' V;
        sub @upper A' lookup alternates V;
    } calt;
    feature cpsp {
        pos @upper <5 0 10 0>;
    } cpsp;
    feature dist {
        pos A V -40;
        enum pos A [O o] -20;
        pos [V O] [A V] -15;
        subtable;
        pos [A] [O] -5;
    } dist;
    feature abvm {
        markClass [dieresiscomb] <anchor 0 600> @ABOVE;
        pos base [o] <anchor 250 500> mark @ABOVE;
    } abvm;
    feature blwm {
        markClass dotbelowcomb <anchor 0 -10> @BELOW;
        pos mark dieresiscomb <anchor 0 -20> mark @BELOW;
    } blwm;
    lookup shift {
        pos V <0 0 7 0>;
    } shift;
    feature kern {
        pos A' lookup shift V;
    } kern;
    """

    /// The fixture plus ligatures, alternates, marks with anchors and a stylistic feature file.
    static func source() -> FontSource {
        var source = FontFixture.source()
        let box = [FontFixture.polygon([(0, 0), (100, 0), (100, 100), (0, 100)])]
        let names = ["A.alt", "A.sc", "V.alt", "O.alt", "f", "i", "fi", "f_i", "ff", "idotless", "f.short", "Adieresis", "dieresiscomb",
                     "gravecomb", "dotbelowcomb", "f_f_i"]
        source.glyphs += names.map { FontSource.Glyph(name: $0, advanceWidth: 300, contours: box) }
        func set(_ name: String, kind: FontSource.GlyphKind? = nil, anchors: [FontSource.Anchor] = []) {
            let index = source.glyphs.firstIndex { $0.name == name }!
            if let kind { source.glyphs[index].kind = kind }
            source.glyphs[index].anchors += anchors
        }
        set("fi", kind: .ligature)
        set("f_i", kind: .ligature)
        set("ff", kind: .ligature)
        set("f_f_i", kind: .ligature)
        set("dieresiscomb", kind: .mark, anchors: [.init(name: "_top", x: 0, y: 600), .init(name: "top", x: 0, y: 800)])
        set("gravecomb", kind: .mark, anchors: [.init(name: "_top", x: 10, y: 600), .init(name: "_bottom", x: 0, y: 0)])
        set("dotbelowcomb", kind: .mark, anchors: [.init(name: "_bottom", x: 0, y: -10)])
        set("Adieresis", kind: .component)
        set("A", anchors: [.init(name: "top", x: 300, y: 700), .init(name: "bottom", x: 300, y: 0)])
        set("O", anchors: [.init(name: "top", x: 350, y: 720)])
        source.features = featureText
        return source
    }

    /// `source` with what `font` read back in place of its anchors, kinds, kerning and features.
    static func rebuilt(_ source: FontSource, from font: ImportedFont) -> FontSource {
        var copy = source
        for index in copy.glyphs.indices {
            copy.glyphs[index].anchors = font.anchors[index]
            copy.glyphs[index].kind = font.kinds[index] ?? .base
        }
        copy.kerning = font.kerning
        copy.features = font.features
        return copy
    }

    @Test(arguments: FontCompiler.Format.allCases)
    func compiledLayoutReadsBackAndCompilesToTheSameTables(format: FontCompiler.Format) throws {
        let source = Self.source()
        let data = try FontCompiler.compile(source, options: .init(format: format)).data
        let font = try OpenTypeReader.read(data)
        #expect(font.report.isEmpty, "\(font.report)")
        #expect(font.hasLayout)
        // Anchors: the generated mark and mkmk come back under their names.
        for (read, original) in zip(font.glyphs.indices, source.glyphs) {
            #expect(Set(font.anchors[read]) == Set(original.anchors), "\(original.name): \(font.anchors[read]) vs \(original.anchors)")
        }
        // Kinds from GDEF (.notdef is in no class).
        #expect(font.kinds[0] == nil)
        for (index, glyph) in source.glyphs.enumerated().dropFirst() {
            #expect(font.kinds[index] == glyph.kind, "\(glyph.name)")
        }
        // Ligatures named by their parts are left to the generator; ff stays as text.
        #expect(!font.features.contains("f_i") && font.features.contains("sub f f by ff;") && font.features.contains("sub f i by fi;"))
        #expect(font.features.contains("language TRK exclude_dflt;") && font.features.contains("lookupflag IgnoreMarks;"))
        #expect(FeatureChecker.check(font.features, glyphs: source.glyphs.map(\.name)).issues.filter { $0.kind != .generated }.isEmpty)
        // Compiled again from what was read, the layout tables are the same bytes.
        let again = try FontCompiler.compile(Self.rebuilt(source, from: font), options: .init(format: format)).data
        let before = try Self.tables(data), after = try Self.tables(again)
        for tag in ["GSUB", "GPOS", "GDEF"] {
            #expect(before[tag] != nil && before[tag] == after[tag], "\(format) \(tag)")
        }
        // And read again, the text is the same.
        #expect(try OpenTypeReader.read(again).features == font.features)
    }

    // MARK: Hand-built tables

    /// A GSUB or GPOS of plain (non-Extension) lookups.
    struct Layout {
        struct Script {
            var tag: String
            /// Feature indices of the default language system (nil: none), its required feature,
            /// and the other languages.
            var features: [Int]?
            var required: Int?
            var languages: [(tag: String, features: [Int])] = []
        }

        struct Lookup {
            var type: Int
            var flag = 0
            var subtables: [[UInt8]]
            var filter: Int?
        }

        var scripts: [Script]
        var features: [(tag: String, lookups: [Int])]
        var lookups: [Lookup]

        var bytes: [UInt8] {
            func langSys(_ features: [Int], required: Int?) -> [UInt8] {
                var w = FontWriter()
                w.u16(0); w.u16(required ?? 0xFFFF); w.u16(features.count)
                for index in features { w.u16(index) }
                return w.bytes
            }
            var scriptList = FontWriter()
            scriptList.u16(scripts.count)
            var bodies: [[UInt8]] = []
            var offset = 2 + scripts.count * 6
            for script in scripts {
                var body = FontWriter()
                var tables: [[UInt8]] = []
                var at = 4 + script.languages.count * 6
                if let features = script.features {
                    body.u16(at)
                    tables.append(langSys(features, required: script.required))
                    at += tables.last!.count
                } else {
                    body.u16(0)
                }
                body.u16(script.languages.count)
                for language in script.languages {
                    body.tag(language.tag); body.u16(at)
                    tables.append(langSys(language.features, required: nil))
                    at += tables.last!.count
                }
                for table in tables { body.append(table) }
                scriptList.tag(script.tag); scriptList.u16(offset)
                offset += body.count
                bodies.append(body.bytes)
            }
            for body in bodies { scriptList.append(body) }
            var featureList = FontWriter()
            featureList.u16(features.count)
            var at = 2 + features.count * 6
            for feature in features {
                featureList.tag(feature.tag); featureList.u16(at)
                at += 4 + feature.lookups.count * 2
            }
            for feature in features {
                featureList.u16(0); featureList.u16(feature.lookups.count)
                for index in feature.lookups { featureList.u16(index) }
            }
            var lookupList = FontWriter()
            lookupList.u16(lookups.count)
            var tables: [[UInt8]] = []
            var lookupAt = 2 + lookups.count * 2
            for lookup in lookups {
                var w = FontWriter()
                let header = 6 + lookup.subtables.count * 2 + (lookup.filter == nil ? 0 : 2)
                w.u16(lookup.type); w.u16(lookup.flag | (lookup.filter == nil ? 0 : 0x10)); w.u16(lookup.subtables.count)
                var subtableAt = header
                for subtable in lookup.subtables {
                    w.u16(subtableAt)
                    subtableAt += subtable.count
                }
                if let filter = lookup.filter { w.u16(filter) }
                for subtable in lookup.subtables { w.append(subtable) }
                lookupList.u16(lookupAt)
                lookupAt += w.count
                tables.append(w.bytes)
            }
            for table in tables { lookupList.append(table) }
            var w = FontWriter()
            w.u32(0x0001_0000)
            w.u16(10); w.u16(10 + scriptList.count); w.u16(10 + scriptList.count + featureList.count)
            w.append(scriptList); w.append(featureList); w.append(lookupList)
            return w.bytes
        }
    }

    /// Coverage format 1 (`ranges`: format 2 of consecutive runs).
    static func coverage(_ glyphs: [Int], ranges: Bool = false) -> [UInt8] {
        var w = FontWriter()
        if ranges {
            var runs: [(Int, Int, Int)] = []
            for (index, glyph) in glyphs.enumerated() {
                if let last = runs.last, last.1 == glyph - 1 { runs[runs.count - 1].1 = glyph } else { runs.append((glyph, glyph, index)) }
            }
            w.u16(2); w.u16(runs.count)
            for run in runs { w.u16(run.0); w.u16(run.1); w.u16(run.2) }
        } else {
            w.u16(1); w.u16(glyphs.count)
            for glyph in glyphs { w.u16(glyph) }
        }
        return w.bytes
    }

    /// ClassDef format 1 from glyph `start`.
    static func classDef(start: Int, _ classes: [Int]) -> [UInt8] {
        var w = FontWriter()
        w.u16(1); w.u16(start); w.u16(classes.count)
        for value in classes { w.u16(value) }
        return w.bytes
    }

    /// A table: header fields (nil: the offset of the next part), then the parts.
    static func table(_ fields: [Int?], _ parts: [[UInt8]]) -> [UInt8] {
        var w = FontWriter()
        var at = fields.count * 2
        var part = 0
        for field in fields {
            if let field {
                w.u16(field)
            } else {
                w.u16(at)
                at += parts[part].count
                part += 1
            }
        }
        for bytes in parts { w.append(bytes) }
        return w.bytes
    }

    /// A rule set of rules (each a list of u16 fields) with offsets.
    static func ruleSet(_ rules: [[Int]]) -> [UInt8] {
        let bodies = rules.map { rule -> [UInt8] in
            var w = FontWriter()
            for field in rule { w.u16(field) }
            return w.bytes
        }
        return table([rules.count] + rules.map { _ in nil }, bodies)
    }

    static let names = [".notdef", "a", "b", "c", "d", "e", "a.alt", "b.alt", "acutecomb", "gravecomb", "dotbelow", "f", "ring"]

    @Test func substitutionFormatsTheCompilerNeverWrites() throws {
        // 0: single format 1 (delta, coverage ranges); 1: context format 1 (glyphs);
        // 2: context format 2 (classes); 3: context format 3; 4: chain format 1;
        // 5: chain format 2 (class 0 of the lookahead is every unclassed glyph);
        // 6: reverse chaining (not read); 7: single format 3 (unknown); 8: a truncated subtable;
        // 9: a multiple substitution deleting a glyph.
        let single = Self.table([1, nil, 5], [Self.coverage([1, 2], ranges: true)])
        let context1 = Self.table([1, nil, 1, nil], [Self.coverage([1]), Self.ruleSet([[2, 1, 2, 0, 0]])])
        let context2 = Self.table([2, nil, nil, 2, 0, nil], [Self.coverage([1, 2]), Self.classDef(start: 1, [1, 1, 2]), Self.ruleSet([[2, 1, 2, 0, 0]])])
        let context3 = Self.table([3, 2, 1, nil, nil, 0, 0], [Self.coverage([1]), Self.coverage([3, 4])])
        let chain1 = Self.table([1, nil, 1, nil], [Self.coverage([2]), Self.ruleSet([[1, 3, 2, 1, 1, 4, 1, 0, 0]])])
        let chain2 = Self.table([2, nil, nil, nil, nil, 2, 0, nil],
                                [Self.coverage([1, 2]), Self.classDef(start: 3, [1]), Self.classDef(start: 1, [1, 1]), Self.classDef(start: 4, [1]),
                                 Self.ruleSet([[1, 1, 1, 1, 0, 1, 0, 0]])])
        let reverse = Self.table([1, nil, 0, 0, 1, 6], [Self.coverage([1])])
        let unknown = Self.table([3, nil], [Self.coverage([1])])
        let deletion = Self.table([1, nil, 1, nil], [Self.coverage([5]), [0, 0]])
        let gsub = Layout(
            scripts: [.init(tag: "DFLT", features: [0, 1], required: 2), .init(tag: "latn", features: [0], languages: [(tag: "TRK ", features: [1])])],
            features: [("calt", [1, 2, 3, 4, 5, 6, 7]), ("locl", [0, 8]), ("rlig", [9]), ("ccmp", [])],
            lookups: [
                .init(type: 1, subtables: [single]), .init(type: 5, subtables: [context1]), .init(type: 5, subtables: [context2]),
                .init(type: 5, subtables: [context3]), .init(type: 6, subtables: [chain1]), .init(type: 6, subtables: [chain2]),
                .init(type: 8, subtables: [reverse]), .init(type: 1, subtables: [unknown]), .init(type: 4, subtables: [[0, 1, 0, 9]]),
                .init(type: 2, subtables: [deletion]),
            ])
        let read = FeatureDecompiler(gsub: FontReader(gsub.bytes, context: "GSUB"), gpos: nil, gdef: nil, names: Self.names, unitsPerEm: 1_000)
        let text = read.features
        #expect(text.contains("sub a by a.alt;") && text.contains("sub b by b.alt;"))
        #expect(text.contains("sub a' lookup locl_1 b';"))
        #expect(text.contains("sub [a b]' lookup locl_1 c';"))
        #expect(text.contains("sub a' lookup locl_1 [c d]';"))
        #expect(text.contains("sub c b' lookup locl_1 a' d;"))
        let lookahead = Self.names.indices.filter { $0 != 4 }.map { Self.names[$0] }.map(FeatureGenerator.glyph).joined(separator: " ")
        #expect(text.contains("sub c [a b]' lookup locl_1 [\(lookahead)];"), "\(text)")
        // Feature lists differ per language system: written per script and language.
        #expect(text.contains("feature calt {\n    script DFLT;\n    lookup "), "\(text)")
        #expect(text.contains("    script latn;\n    language TRK exclude_dflt;\n    lookup "))
        #expect(FeatureChecker.check(text, glyphs: Self.names).isClean)
        #expect(read.report.contains("GSUB calt: reverse chaining substitution was not read."))
        #expect(read.report.contains("GSUB calt: single substitution format 3 was not read."))
        #expect(read.report.contains("GSUB locl: an unreadable lookup was not read.") && read.report.count == 5, "\(read.report)")
        #expect(read.report.contains("GSUB rlig: a deletion (sub … by NULL) was not read."))
        #expect(read.report.contains("GSUB rlig is a required feature in the font; it is written as an ordinary feature."))
        #expect(!text.contains("ccmp"))
    }

    /// A value record with only the fields given (format 4: x advance).
    static func u16s(_ values: [Int]) -> [UInt8] {
        var w = FontWriter()
        for value in values { w.i16(value) }
        return w.bytes
    }

    @Test func positioningAttachmentAndGDEF() throws {
        // 0: single format 1 with flags the feature file lacks; 1: cursive; 2: mark-to-ligature;
        // 3: mark-to-base under mark (three classes: top, a second class above, bottom);
        // 4: context format 3; 5: pair format 1 under kern (kerning's); 6: pair format 3.
        let single = Self.table([1, nil, 4, -10 & 0xFFFF], [Self.coverage([1, 2])])
        let anchor = { (x: Int, y: Int) in Self.u16s([1, x, y]) }
        // Mark array: acutecomb class 0, gravecomb class 1, dotbelow class 2.
        var markArray = FontWriter()
        markArray.u16(3)
        let markAnchors = [anchor(0, 700), anchor(0, 300), anchor(0, -20)]
        var at = 2 + 3 * 4
        for (index, bytes) in markAnchors.enumerated() {
            markArray.u16(index); markArray.u16(at)
            at += bytes.count
        }
        for bytes in markAnchors { markArray.append(bytes) }
        // Base array: a has all three, b only the top (NULL elsewhere).
        var baseArray = FontWriter()
        baseArray.u16(2)
        let baseAnchors = [anchor(250, 700), anchor(250, 300), anchor(250, -50), anchor(300, 700)]
        at = 2 + 6 * 2
        for slot in [0, 1, 2, 3, nil, nil] {
            if let slot {
                baseArray.u16(at)
                at += baseAnchors[slot].count
            } else {
                baseArray.u16(0)
            }
        }
        for bytes in baseAnchors { baseArray.append(bytes) }
        let markToBase = Self.table([1, nil, nil, 3, nil, nil], [Self.coverage([8, 9, 10]), Self.coverage([1, 2]), markArray.bytes, baseArray.bytes])
        let context = Self.table([3, 1, 1, nil, 0, 0], [Self.coverage([3])])
        let pair = Self.table([1, nil, 4, 0, 1, nil], [Self.coverage([1]), Self.u16s([1, 2, -30])])
        let pair3 = Self.table([3, nil], [Self.coverage([1])])
        let gpos = Layout(
            scripts: [.init(tag: "DFLT", features: [0, 1, 2, 3, 4, 5])],
            features: [("cpsp", [0, 4]), ("curs", [1]), ("mark", [2, 3]), ("kern", [5]), ("dist", [6]), ("+", [0])],
            lookups: [
                .init(type: 1, flag: 0x0108, subtables: [single], filter: 0), .init(type: 3, subtables: [[0, 1]]), .init(type: 5, subtables: [[0, 1]]),
                .init(type: 4, subtables: [markToBase]), .init(type: 7, subtables: [context]), .init(type: 2, subtables: [pair]),
                .init(type: 2, subtables: [pair3]),
            ])
        // GDEF 1.2: glyph classes, attachment points and carets (not read), mark attachment
        // classes and one mark glyph set.
        let glyphClasses = Self.classDef(start: 1, [1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 1, 3])
        let markAttachment = Self.classDef(start: 8, [1, 1, 2])
        let sets: [UInt8] = [0, 1, 0, 1, 0, 0, 0, 8] + Self.coverage([8])
        let gdef = Self.table([1, 2, nil, nil, nil, nil, nil], [glyphClasses, [0, 0], [0, 0], markAttachment, sets])
        let read = FeatureDecompiler(gsub: nil, gpos: FontReader(gpos.bytes, context: "GPOS"),
                                     gdef: FontReader(gdef, context: "GDEF"), names: Self.names, unitsPerEm: 1_000)
        let text = read.features
        #expect(text.contains("pos a -10;\n    pos b -10;"), "\(text)")
        #expect(text.contains("    # lookupflag MarkAttachmentType @MarkAttachmentClass1; (dropped: not supported)\n"))
        #expect(text.contains("    # lookupflag UseMarkFilteringSet @MarkGlyphSet0; (dropped: not supported)\n    lookupflag IgnoreMarks;\n"))
        #expect(text.contains("pos c' lookup cpsp_1;"))
        #expect(text.contains("@MarkAttachmentClass1 = [acutecomb gravecomb];\n@MarkAttachmentClass2 = [dotbelow];\n"))
        #expect(text.contains("@MarkGlyphSet0 = [acutecomb];"))
        #expect(!text.contains("feature kern") && !text.contains("feature mark") && !text.contains("feature +"))
        #expect(FeatureChecker.check(text, glyphs: Self.names).isClean)
        // Anchors named by where the classes attach.
        #expect(read.anchors[1] == [.init(name: "top", x: 250, y: 700), .init(name: "anchor2", x: 250, y: 300), .init(name: "bottom", x: 250, y: -50)])
        #expect(read.anchors[2] == [.init(name: "top", x: 300, y: 700)])
        #expect(read.anchors[8] == [.init(name: "_top", x: 0, y: 700)] && read.anchors[10] == [.init(name: "_bottom", x: 0, y: -20)])
        // Kinds from GDEF.
        #expect(read.kinds[1] == .base && read.kinds[8] == .mark && read.kinds[12] == .mark && read.kinds[0] == nil)
        for line in ["GPOS curs: cursive attachment was not read.", "GPOS mark: mark-to-ligature attachment was not read.",
                     "GPOS dist: pair positioning format 3 was not read.", "GDEF attachment points were not read.", "GDEF ligature caret positions were not read.",
                     "GPOS cpsp: lookupflag MarkAttachmentType was dropped (not in the feature file).",
                     "GPOS cpsp: lookupflag UseMarkFilteringSet was dropped (not in the feature file)."] {
            #expect(read.report.contains(line), "\(line) in \(read.report)")
        }
        #expect(read.report.contains { $0.hasPrefix("GPOS + could not be written as feature text and was left out") }, "\(read.report) \(text)")
    }

    @Test func whatDoesNotCheckIsLeftOut() throws {
        // A glyph name the grammar cannot read: its lookup is left out, the rest stays.
        let names = Self.names + ["a@b"]
        let single = Self.table([2, nil, 1, 13], [Self.coverage([1])])
        let other = Self.table([2, nil, 1, 6], [Self.coverage([1])])
        let gsub = Layout(scripts: [.init(tag: "DFLT", features: [0, 1])], features: [("ss01", [0]), ("ss02", [1])],
                          lookups: [.init(type: 1, subtables: [single]), .init(type: 1, subtables: [other])])
        let read = FeatureDecompiler(gsub: FontReader(gsub.bytes, context: "GSUB"), gpos: nil, gdef: nil, names: names, unitsPerEm: 1_000)
        #expect(!read.features.contains("ss01") && read.features.contains("sub a by a.alt;"))
        #expect(read.report.count == 1 && read.report[0].hasPrefix("GSUB ss01: a lookup could not be written as feature text and was left out ("), "\(read.report)")
        // A language system the grammar cannot read: nothing is written.
        let broken = Layout(scripts: [.init(tag: "----", features: [0])], features: [("ss02", [0])], lookups: [.init(type: 1, subtables: [other])])
        let none = FeatureDecompiler(gsub: FontReader(broken.bytes, context: "GSUB"), gpos: nil, gdef: nil, names: Self.names, unitsPerEm: 1_000)
        #expect(none.features.isEmpty && none.report == ["The font's other layout features could not be written as feature text and were not read."])
        // Tables that cannot be read are reported; the font still opens.
        let malformed = FeatureDecompiler(gsub: FontReader([0, 1, 0], context: "GSUB"), gpos: nil, gdef: FontReader([0, 1], context: "GDEF"),
                                          names: Self.names, unitsPerEm: 1_000)
        #expect(malformed.features.isEmpty && malformed.report.count == 2 && malformed.report[0].hasPrefix("The GSUB table could not be read"))
        #expect(malformed.report[1].hasPrefix("The GDEF table could not be read"))
        // A lookup over 256 KB of text is left out (here: a class-based context whose class 0
        // enumerates a big font's glyphs).
        let big = (0..<3_000).map { "glyph\($0)" }
        let wide = Self.table([2, nil, nil, 2, 0, nil], [Self.coverage([1, 2]), Self.classDef(start: 1, [1, 1]),
                                                          Self.ruleSet((0..<12).map { _ in [3, 1, 0, 0, 0, 0] })])
        let huge = Layout(scripts: [.init(tag: "DFLT", features: [0])], features: [("calt", [0, 1])],
                          lookups: [.init(type: 5, subtables: [wide]), .init(type: 1, subtables: [Self.table([1, nil, 1], [Self.coverage([1])])])])
        let limited = FeatureDecompiler(gsub: FontReader(huge.bytes, context: "GSUB"), gpos: nil, gdef: nil, names: big, unitsPerEm: 1_000)
        #expect(!limited.features.contains("calt_2 {") && limited.features.contains("sub glyph1 by glyph2;"), "\(limited.features.prefix(600))")
    }

    @Test func ligaturesAndMarksWithoutGDEF() throws {
        let names = Self.names + ["a_b", "ab"]
        // liga (flagged IgnoreMarks): a b → a_b is the generator's, a c → ab stays, a b → a glyph
        // past the font is left out.
        var ligatures = FontWriter()
        ligatures.u16(3); ligatures.u16(8); ligatures.u16(14); ligatures.u16(20)
        ligatures.u16(13); ligatures.u16(2); ligatures.u16(2)
        ligatures.u16(14); ligatures.u16(2); ligatures.u16(3)
        ligatures.u16(200); ligatures.u16(2); ligatures.u16(2)
        let liga = Self.table([1, nil, 1, nil], [Self.coverage([1]), ligatures.bytes])
        // calt: a rule applying a lookup that is not written, and one with an empty position.
        let unwritten = Self.table([3, 0, 1, nil, 0, 1, 0, 5], [Self.coverage([3])])
        let emptyInput = Self.table([3, 0, 1, nil, 0, 0], [Self.coverage([])])
        let gsub = Layout(scripts: [.init(tag: "DFLT", features: [0, 1])], features: [("liga", [0]), ("calt", [1, 2])],
                          lookups: [.init(type: 4, flag: 8, subtables: [liga]), .init(type: 6, subtables: [unwritten]), .init(type: 6, subtables: [emptyInput]),
                                    .init(type: 1, subtables: []), .init(type: 1, subtables: []), .init(type: 8, subtables: [[0, 1]])])
        // mark: a class with no base (named by its marks' own anchors); mkmk with a mark-to-base
        // lookup, written as text.
        func attachment(marks: [Int], bases: [Int], anchorY: Int) -> [UInt8] {
            var markArray = FontWriter()
            markArray.u16(marks.count)
            for (index, _) in marks.enumerated() { markArray.u16(0); markArray.u16(2 + marks.count * 4 + index * 6) }
            for _ in marks { markArray.append(Self.u16s([1, 0, anchorY])) }
            var baseArray = FontWriter()
            baseArray.u16(bases.count)
            for (index, _) in bases.enumerated() { baseArray.u16(2 + bases.count * 2 + index * 6) }
            for _ in bases { baseArray.append(Self.u16s([1, 100, anchorY + 100])) }
            return Self.table([1, nil, nil, 1, nil, nil], [Self.coverage(marks), Self.coverage(bases), markArray.bytes, baseArray.bytes])
        }
        let gpos = Layout(scripts: [.init(tag: "DFLT", features: [0, 1])], features: [("mark", [0]), ("mkmk", [1])],
                          lookups: [.init(type: 4, subtables: [attachment(marks: [8], bases: [], anchorY: 500)]),
                                    .init(type: 4, subtables: [attachment(marks: [9], bases: [1], anchorY: 40)])])
        let read = FeatureDecompiler(gsub: FontReader(gsub.bytes, context: "GSUB"), gpos: FontReader(gpos.bytes, context: "GPOS"), gdef: nil,
                                     names: names, unitsPerEm: 1_000)
        let text = read.features
        #expect(text.contains("sub a c by ab;") && !text.contains("a_b") && !text.contains("calt"), "\(text)")
        #expect(text.contains("feature mkmk {") && text.contains("pos base a <anchor 100 140> mark @mkmk_"))
        #expect(read.kinds[13] == .ligature && read.kinds[8] == .mark && read.kinds[1] == nil)
        #expect(read.anchors[8] == [.init(name: "_top", x: 0, y: 500)])
        #expect(read.report.contains("GSUB liga: the ligatures named by their parts are generated again, without their lookup flags."))
        #expect(read.report.contains("GSUB lookup 5: reverse chaining substitution was not read."), "\(read.report)")
        #expect(FeatureChecker.check(text, glyphs: names).isClean)
    }

    @Test func cancellingTheCallerStopsTheCompile() async throws {
        let task = Task { try await FontCompiler().compile(FontFixture.source()) }
        task.cancel()
        do {
            _ = try await task.value
        } catch {
            #expect(error as? FontCompiler.Failure == .cancelled)
        }
    }

    @Test func rareFormatsAndMalformedLists() throws {
        let names = Self.names + ["a@b", "a_b"]
        // GSUB: 0 alternate format 2, 1 context format 4, 2 context format 2 with a rule set for
        // class 0 and an empty one, 3 chain format 2 without a backtrack class definition, 4 a
        // liga lookup the generator writes whole, also used by dlig, 5 liga's ligature format 2;
        // a feature tag the grammar cannot read; a feature naming a lookup that is not there.
        let alternate2 = Self.table([2, nil], [Self.coverage([1])])
        let context4 = Self.table([4, 0], [])
        let context2 = Self.table([2, nil, nil, 3, nil, 0, nil], [Self.coverage([1, 4]), Self.classDef(start: 1, [1]),
                                                                   Self.ruleSet([[2, 1, 1, 0, 6]]), Self.ruleSet([[1, 1, 0, 6]])])
        let chain2 = Self.table([2, nil, 0, nil, 0, 2, 0, nil], [Self.coverage([1]), Self.classDef(start: 1, [1]), Self.ruleSet([[0, 1, 0, 1, 0, 6]])])
        let generated = Self.table([1, nil, 1, nil], [Self.coverage([1]), Self.table([1, nil], [Self.u16s([14, 2, 2])])])
        let gsub = Layout(scripts: [.init(tag: "DFLT", features: [0, 1, 2, 3, 4])],
                          features: [("salt", [0, 1, 2, 3]), ("liga", [4, 5]), ("dlig", [4]), ("x y", [6]), ("ccmp", [40])],
                          lookups: [.init(type: 3, subtables: [alternate2]), .init(type: 5, subtables: [context4]), .init(type: 5, subtables: [context2]),
                                    .init(type: 6, subtables: [chain2]), .init(type: 4, subtables: [generated]), .init(type: 4, subtables: [[0, 2]]),
                                    .init(type: 1, subtables: [Self.table([1, nil, 1], [Self.coverage([1])])])])
        // GPOS: 0 single format 1 with every value field, 1 an unknown lookup type, 2 mark
        // attachment format 2, 3 a mark class past the class count; a language tag that cannot
        // be read.
        let all = Self.table([1, nil, 0x0F, 1, 2, 3, 4], [Self.coverage([2])])
        var markArray = FontWriter()
        markArray.u16(1); markArray.u16(5); markArray.u16(6); markArray.append(Self.u16s([1, 0, 0]))
        var baseArray = FontWriter()
        baseArray.u16(0)
        let pastClasses = Self.table([1, nil, nil, 1, nil, nil], [Self.coverage([8]), Self.coverage([]), markArray.bytes, baseArray.bytes])
        let gpos = Layout(scripts: [.init(tag: "DFLT", features: [0, 1], languages: [(tag: "T K", features: [0])])],
                          features: [("cpsp", [0, 1, 2]), ("mark", [3])],
                          lookups: [.init(type: 1, subtables: [all]), .init(type: 10, subtables: [[0, 1]]), .init(type: 4, subtables: [[0, 2]]),
                                    .init(type: 4, subtables: [pastClasses])])
        // GDEF 1.3 with variation data, and a mark attachment class the grammar cannot read.
        let gdef = Self.table([1, 3, 0, 0, 0, nil, 0, 0, 1], [Self.classDef(start: 13, [1])])
        let read = FeatureDecompiler(gsub: FontReader(gsub.bytes, context: "GSUB"), gpos: FontReader(gpos.bytes, context: "GPOS"),
                                     gdef: FontReader(gdef, context: "GDEF"), names: names, unitsPerEm: 1_000)
        let text = read.features
        #expect(text.contains("sub a' lookup gsub_") && text.contains("sub d' lookup gsub_"), "\(text)")
        #expect(text.contains("sub d' lookup gsub_1 a';") && !text.contains("feature liga") && text.contains("feature dlig"), "\(text)")
        #expect(text.contains("pos b <1 2 3 4>;") && !text.contains("x y") && !text.contains("@MarkAttachmentClass"))
        #expect(FeatureChecker.check(text, glyphs: names).isClean)
        for line in ["GSUB salt: alternate substitution format 2 was not read.", "GSUB salt: contextual rule format 4 was not read.",
                     "GSUB liga: ligature substitution format 2 was not read.", "GPOS cpsp: lookup type 10 was not read.",
                     "GPOS cpsp: mark attachment format 2 was not read.", "GDEF variation data were not read."] {
            #expect(read.report.contains(line), "\(line) in \(read.report)")
        }
        #expect(read.report.contains { $0.hasPrefix("GDEF's mark classes could not be written as feature text and was left out") })
        #expect(read.anchors.allSatisfy { $0.isEmpty })
    }
}
