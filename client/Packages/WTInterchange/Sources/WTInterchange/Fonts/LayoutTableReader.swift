// FONT-025 (rest): the binary side of reading a font's layout back (font-export.adoc, "Opening an
// existing font", "OTF/TTF import"; OpenType 1.9, "OpenType Layout Common Table Formats", "GSUB",
// "GPOS", "GDEF").  `LayoutTable` reads a `GSUB` or `GPOS` table into its language systems, its
// features (lookups per language system) and its lookups (Extension lookups unwrapped), and decodes
// every subtable the feature file can express into rules: single, multiple, alternate and ligature
// substitution; contextual and chaining contextual rules of formats 1, 2 and 3 for both tables;
// single and pair positioning (glyph pairs and class pairs); mark-to-base and mark-to-mark
// attachment.  Reverse chaining substitution, cursive and mark-to-ligature attachment are decoded
// as `unsupported` with what they are.  `LayoutGDEF` reads `GDEF`'s glyph classes, its mark
// attachment classes and its mark glyph sets.  `FeatureDecompiler` turns all this into anchors,
// kinds and feature text.

/// A decoded contextual rule: glyph sets per position (backtrack in text order, nearest glyph
/// last) and the lookups applied at input positions.
struct LayoutContextRule: Hashable, Sendable {
    var backtrack: [[Int]]
    var input: [[Int]]
    var lookahead: [[Int]]
    var records: [LayoutRecord]
}

/// A lookup applied at an input position of a contextual rule.
struct LayoutRecord: Hashable, Sendable {
    var sequence: Int
    var lookup: Int
}

/// Mark attachment (GPOS 4 or 6): the mark classes (marks with their anchors) and the attaching
/// glyphs with an anchor per class (nil where the font has none).
struct LayoutAttachment: Hashable, Sendable {
    struct Mark: Hashable, Sendable {
        var glyph: Int
        var anchor: FeatureAnchor
    }

    struct Base: Hashable, Sendable {
        var glyph: Int
        var anchors: [FeatureAnchor?]
    }

    var classes: [[Mark]]
    var bases: [Base]
}

/// The rules of one subtable.
enum LayoutRules: Hashable, Sendable {
    struct Single: Hashable, Sendable {
        var glyph: Int
        var replacement: Int
    }

    struct Sequence: Hashable, Sendable {
        var glyph: Int
        var glyphs: [Int]
    }

    struct Ligature: Hashable, Sendable {
        var components: [Int]
        var glyph: Int
    }

    struct Value: Hashable, Sendable {
        var glyph: Int
        var value: FeatureValue
    }

    struct Pair: Hashable, Sendable {
        var first: Int
        var second: Int
        var value: FeatureValue
    }

    struct ClassPair: Hashable, Sendable {
        var first: [Int]
        var second: [Int]
        var value: FeatureValue
    }

    case single([Single])
    case multiple([Sequence])
    case alternate([Sequence])
    case ligature([Ligature])
    case context([LayoutContextRule])
    case singlePosition([Value])
    case pairs([Pair])
    case classPairs([ClassPair])
    case attachment(LayoutAttachment)
    /// A subtable the feature file cannot express, and what it is.
    case unsupported(String)
}

/// A GSUB or GPOS table.
struct LayoutTable {
    struct Lookup: Hashable, Sendable {
        /// The lookup type, Extension lookups unwrapped.
        var type: Int
        var flag: Int
        /// Each subtable's offset in the table (past any Extension wrapper).
        var subtables: [Int]
        /// The GDEF mark glyph set of a lookup flagged UseMarkFilteringSet.
        var markFilteringSet: Int?
    }

    struct Feature: Hashable, Sendable {
        var tag: String
        /// Lookup indices per language system, in the font's order.
        var systems: [FeatureLanguageSystem: [Int]]
    }

    let kind: FeatureTableKind
    let reader: FontReader
    /// Every language system of the ScriptList, sorted.
    var systems: [FeatureLanguageSystem] = []
    /// One entry per feature tag, in FeatureList order.
    var features: [Feature] = []
    var lookups: [Lookup] = []
    /// Tags of features a language system marks required (written as ordinary features).
    var required: [String] = []
    /// The glyph count of the font (class 0 of a context class definition is every other glyph).
    let glyphCount: Int

    init(_ table: FontReader, kind: FeatureTableKind, glyphCount: Int) throws {
        self.kind = kind
        reader = table
        self.glyphCount = glyphCount
        let scriptList = try table.u16(4), featureList = try table.u16(6), lookupList = try table.u16(8)
        var records: [(tag: String, lookups: [Int])] = []
        if featureList != 0 {
            for index in 0..<(try table.u16(featureList)) {
                let record = featureList + 2 + index * 6
                let feature = featureList + (try table.u16(record + 4))
                let lookups = try (0..<(try table.u16(feature + 2))).map { try table.u16(feature + 4 + $0 * 2) }
                records.append((Self.trimmed(try table.tag(record)), lookups))
            }
        }
        var bySystem: [FeatureLanguageSystem: [Int]] = [:]
        var required: Set<String> = []
        func langSys(_ at: Int, _ system: FeatureLanguageSystem) throws {
            let requiredIndex = try table.u16(at + 2)
            var indices = try (0..<(try table.u16(at + 4))).map { try table.u16(at + 6 + $0 * 2) }
            if requiredIndex != 0xFFFF, requiredIndex < records.count {
                required.insert(records[requiredIndex].tag)
                indices.insert(requiredIndex, at: 0)
            }
            bySystem[system] = indices.filter { $0 < records.count }
        }
        if scriptList != 0 {
            for index in 0..<(try table.u16(scriptList)) {
                let record = scriptList + 2 + index * 6
                let tag = Self.trimmed(try table.tag(record))
                let script = scriptList + (try table.u16(record + 4))
                let defaultLangSys = try table.u16(script)
                if defaultLangSys != 0 { try langSys(script + defaultLangSys, FeatureLanguageSystem(script: tag, language: "dflt")) }
                for language in 0..<(try table.u16(script + 2)) {
                    let languageRecord = script + 4 + language * 6
                    try langSys(script + (try table.u16(languageRecord + 4)), FeatureLanguageSystem(script: tag, language: Self.trimmed(try table.tag(languageRecord))))
                }
            }
        }
        systems = bySystem.keys.sorted()
        self.required = required.sorted()
        var features: [Feature] = []
        for (index, record) in records.enumerated() {
            if !features.contains(where: { $0.tag == record.tag }) { features.append(Feature(tag: record.tag, systems: [:])) }
            let position = features.firstIndex { $0.tag == record.tag }!
            for system in systems where bySystem[system]!.contains(index) {
                var list = features[position].systems[system] ?? []
                for lookup in record.lookups where !list.contains(lookup) { list.append(lookup) }
                features[position].systems[system] = list
            }
        }
        // A feature no language system uses is never applied.
        self.features = features.filter { !$0.systems.isEmpty }
        if lookupList != 0 {
            let extensionType = kind == .gsub ? 7 : 9
            for index in 0..<(try table.u16(lookupList)) {
                let lookup = lookupList + (try table.u16(lookupList + 2 + index * 2))
                var type = try table.u16(lookup)
                let flag = try table.u16(lookup + 2)
                let count = try table.u16(lookup + 4)
                var subtables = try (0..<count).map { lookup + (try table.u16(lookup + 6 + $0 * 2)) }
                let markFilteringSet = flag & 0x10 != 0 ? try table.u16(lookup + 6 + count * 2) : nil
                if type == extensionType {
                    var types: [Int] = []
                    subtables = try subtables.map { subtable in
                        types.append(try table.u16(subtable + 2))
                        return subtable + (try table.u32(subtable + 4))
                    }
                    type = types.first ?? 0
                }
                lookups.append(Lookup(type: type, flag: flag, subtables: subtables, markFilteringSet: markFilteringSet))
            }
        }
    }

    /// A tag without its padding spaces (`TRK ` is written `TRK`).
    static func trimmed(_ tag: String) -> String {
        String(tag.reversed().drop { $0 == " " }.reversed())
    }

    // MARK: Shared structures

    /// A value record of `format` at `offset`: the four adjustments (device tables skipped), and
    /// the record's size.
    func value(_ format: Int, at offset: Int) throws -> (value: FeatureValue, size: Int) {
        var value = FeatureValue()
        var position = offset
        func next() throws -> Int {
            defer { position += 2 }
            return try reader.i16(position)
        }
        if format & 1 != 0 { value.xPlacement = try next() }
        if format & 2 != 0 { value.yPlacement = try next() }
        if format & 4 != 0 { value.xAdvance = try next() }
        if format & 8 != 0 { value.yAdvance = try next() }
        return (value, (format & 0xFF).nonzeroBitCount * 2)
    }

    func coverage(_ offset: Int) throws -> [Int] {
        try GPOSReader.coverage(reader, at: offset)
    }

    func classDef(_ offset: Int) throws -> [Int: Int] {
        try GPOSReader.classDef(reader, at: offset)
    }

    /// The glyphs of class `value` in `classes` (class 0: every glyph not in another class).
    func members(_ value: Int, of classes: [Int: Int]) -> [Int] {
        value == 0 ? (0..<glyphCount).filter { classes[$0] == nil } : classes.filter { $0.value == value }.map(\.key).sorted()
    }

    func anchor(_ offset: Int) throws -> FeatureAnchor {
        FeatureAnchor(x: try reader.i16(offset + 2), y: try reader.i16(offset + 4))
    }

    func glyphs(_ offset: Int, count: Int) throws -> [Int] {
        try (0..<count).map { try reader.u16(offset + $0 * 2) }
    }

    func records(_ offset: Int, count: Int) throws -> [LayoutRecord] {
        try (0..<count).map { LayoutRecord(sequence: try reader.u16(offset + $0 * 4), lookup: try reader.u16(offset + $0 * 4 + 2)) }
    }

    // MARK: Subtables

    /// The rules of every subtable of `lookup`, in order.
    func rules(_ lookup: Lookup) throws -> [LayoutRules] {
        try lookup.subtables.map { try rules(type: lookup.type, at: $0) }
    }

    func rules(type: Int, at subtable: Int) throws -> LayoutRules {
        let format = try reader.u16(subtable)
        switch (kind, type) {
        case (.gsub, 1): return try single(subtable, format: format)
        case (.gsub, 2), (.gsub, 3): return try sequences(subtable, format: format, alternate: type == 3)
        case (.gsub, 4): return try ligature(subtable, format: format)
        case (.gsub, 5), (.gpos, 7): return try context(subtable, format: format, chaining: false)
        case (.gsub, 6), (.gpos, 8): return try context(subtable, format: format, chaining: true)
        case (.gsub, 8): return .unsupported("reverse chaining substitution")
        case (.gpos, 1): return try singlePosition(subtable, format: format)
        case (.gpos, 2): return try pair(subtable, format: format)
        case (.gpos, 3): return .unsupported("cursive attachment")
        case (.gpos, 4), (.gpos, 6): return try attachment(subtable, format: format)
        case (.gpos, 5): return .unsupported("mark-to-ligature attachment")
        default: return .unsupported("lookup type \(type)")
        }
    }

    private func unknown(_ type: String, _ format: Int) -> LayoutRules {
        .unsupported("\(type) format \(format)")
    }

    private func single(_ subtable: Int, format: Int) throws -> LayoutRules {
        let covered = try coverage(subtable + (try reader.u16(subtable + 2)))
        switch format {
        case 1:
            let delta = try reader.i16(subtable + 4)
            return .single(covered.map { .init(glyph: $0, replacement: ($0 + delta) & 0xFFFF) })
        case 2:
            let replacements = try glyphs(subtable + 6, count: try reader.u16(subtable + 4))
            return .single(zip(covered, replacements).map { .init(glyph: $0, replacement: $1) })
        default:
            return unknown("single substitution", format)
        }
    }

    private func sequences(_ subtable: Int, format: Int, alternate: Bool) throws -> LayoutRules {
        guard format == 1 else { return unknown(alternate ? "alternate substitution" : "multiple substitution", format) }
        let covered = try coverage(subtable + (try reader.u16(subtable + 2)))
        let count = min(covered.count, try reader.u16(subtable + 4))
        let result = try (0..<count).map { index -> LayoutRules.Sequence in
            let set = subtable + (try reader.u16(subtable + 6 + index * 2))
            return .init(glyph: covered[index], glyphs: try glyphs(set + 2, count: try reader.u16(set)))
        }
        return alternate ? .alternate(result) : .multiple(result)
    }

    private func ligature(_ subtable: Int, format: Int) throws -> LayoutRules {
        guard format == 1 else { return unknown("ligature substitution", format) }
        let covered = try coverage(subtable + (try reader.u16(subtable + 2)))
        var result: [LayoutRules.Ligature] = []
        for index in 0..<min(covered.count, try reader.u16(subtable + 4)) {
            let set = subtable + (try reader.u16(subtable + 6 + index * 2))
            for member in 0..<(try reader.u16(set)) {
                let ligature = set + (try reader.u16(set + 2 + member * 2))
                let components = try reader.u16(ligature + 2)
                result.append(.init(components: [covered[index]] + (try glyphs(ligature + 4, count: max(components - 1, 0))), glyph: try reader.u16(ligature)))
            }
        }
        return .ligature(result)
    }

    private func context(_ subtable: Int, format: Int, chaining: Bool) throws -> LayoutRules {
        switch format {
        case 1: return try glyphContext(subtable, chaining: chaining)
        case 2: return try classContext(subtable, chaining: chaining)
        case 3: return try coverageContext(subtable, chaining: chaining)
        default: return unknown(chaining ? "chaining contextual rule" : "contextual rule", format)
        }
    }

    /// Format 1: rule sets per covered glyph, glyph sequences.
    private func glyphContext(_ subtable: Int, chaining: Bool) throws -> LayoutRules {
        let covered = try coverage(subtable + (try reader.u16(subtable + 2)))
        var result: [LayoutContextRule] = []
        for index in 0..<min(covered.count, try reader.u16(subtable + 4)) {
            let setOffset = try reader.u16(subtable + 6 + index * 2)
            guard setOffset != 0 else { continue }
            let set = subtable + setOffset
            for member in 0..<(try reader.u16(set)) {
                let rule = set + (try reader.u16(set + 2 + member * 2))
                result.append(try contextRule(rule, chaining: chaining, first: [covered[index]]))
            }
        }
        return .context(result)
    }

    /// Format 2: rule sets per class of the first glyph, class sequences.
    private func classContext(_ subtable: Int, chaining: Bool) throws -> LayoutRules {
        let covered = try coverage(subtable + (try reader.u16(subtable + 2)))
        func classes(_ field: Int) throws -> [Int: Int] {
            let offset = try reader.u16(subtable + field)
            return offset == 0 ? [:] : try classDef(subtable + offset)
        }
        let backtrack = chaining ? try classes(4) : [:]
        let input = try classes(chaining ? 6 : 4)
        let lookahead = chaining ? try classes(8) : [:]
        let countAt = subtable + (chaining ? 10 : 6)
        var result: [LayoutContextRule] = []
        for value in 0..<(try reader.u16(countAt)) {
            let setOffset = try reader.u16(countAt + 2 + value * 2)
            let first = covered.filter { (input[$0] ?? 0) == value }
            guard setOffset != 0, !first.isEmpty else { continue }
            let set = subtable + setOffset
            for member in 0..<(try reader.u16(set)) {
                let rule = set + (try reader.u16(set + 2 + member * 2))
                result.append(try contextRule(rule, chaining: chaining, first: first, backtrack: { members($0, of: backtrack) },
                                              input: { members($0, of: input) }, lookahead: { members($0, of: lookahead) }))
            }
        }
        return .context(result)
    }

    /// A format 1 or 2 rule at `rule`: glyph ids or class values turned into sets per part.
    private func contextRule(_ rule: Int, chaining: Bool, first: [Int], backtrack backtrackSet: (Int) -> [Int] = { [$0] },
                             input inputSet: (Int) -> [Int] = { [$0] }, lookahead lookaheadSet: (Int) -> [Int] = { [$0] }) throws -> LayoutContextRule {
        var position = rule
        func sequence(_ count: Int, _ set: (Int) -> [Int]) throws -> [[Int]] {
            defer { position += count * 2 }
            return try glyphs(position, count: count).map(set)
        }
        var backtrack: [[Int]] = []
        if chaining {
            let count = try reader.u16(position)
            position += 2
            backtrack = Array(try sequence(count, backtrackSet).reversed())
        }
        let inputCount = try reader.u16(position)
        var recordCount = 0
        if !chaining {
            recordCount = try reader.u16(position + 2)
            position += 4
        } else {
            position += 2
        }
        let input = [first] + (try sequence(max(inputCount - 1, 0), inputSet))
        var lookahead: [[Int]] = []
        if chaining {
            let count = try reader.u16(position)
            position += 2
            lookahead = try sequence(count, lookaheadSet)
            recordCount = try reader.u16(position)
            position += 2
        }
        return LayoutContextRule(backtrack: backtrack, input: input, lookahead: lookahead, records: try records(position, count: recordCount))
    }

    /// Format 3: a coverage per position.
    private func coverageContext(_ subtable: Int, chaining: Bool) throws -> LayoutRules {
        var position = subtable + 2
        func coverages(_ count: Int) throws -> [[Int]] {
            defer { position += count * 2 }
            return try (0..<count).map { try coverage(subtable + (try reader.u16(position + $0 * 2))) }
        }
        if !chaining {
            let inputCount = try reader.u16(position), recordCount = try reader.u16(position + 2)
            position += 4
            let input = try coverages(inputCount)
            return .context([LayoutContextRule(backtrack: [], input: input, lookahead: [], records: try records(position, count: recordCount))])
        }
        let backtrackCount = try reader.u16(position)
        position += 2
        let backtrack = Array(try coverages(backtrackCount).reversed())
        let inputCount = try reader.u16(position)
        position += 2
        let input = try coverages(inputCount)
        let lookaheadCount = try reader.u16(position)
        position += 2
        let lookahead = try coverages(lookaheadCount)
        let recordCount = try reader.u16(position)
        return .context([LayoutContextRule(backtrack: backtrack, input: input, lookahead: lookahead, records: try records(position + 2, count: recordCount))])
    }

    private func singlePosition(_ subtable: Int, format: Int) throws -> LayoutRules {
        let covered = try coverage(subtable + (try reader.u16(subtable + 2)))
        let valueFormat = try reader.u16(subtable + 4)
        switch format {
        case 1:
            let value = try self.value(valueFormat, at: subtable + 6).value
            return .singlePosition(covered.map { .init(glyph: $0, value: value) })
        case 2:
            var result: [LayoutRules.Value] = []
            var at = subtable + 8
            for glyph in covered.prefix(try reader.u16(subtable + 6)) {
                let read = try value(valueFormat, at: at)
                result.append(.init(glyph: glyph, value: read.value))
                at += read.size
            }
            return .singlePosition(result)
        default:
            return unknown("single positioning", format)
        }
    }

    private func pair(_ subtable: Int, format: Int) throws -> LayoutRules {
        let covered = try coverage(subtable + (try reader.u16(subtable + 2)))
        let format1 = try reader.u16(subtable + 4), format2 = try reader.u16(subtable + 6)
        let size1 = (format1 & 0xFF).nonzeroBitCount * 2, size2 = (format2 & 0xFF).nonzeroBitCount * 2
        switch format {
        case 1:
            var result: [LayoutRules.Pair] = []
            for (index, first) in covered.prefix(try reader.u16(subtable + 8)).enumerated() {
                let set = subtable + (try reader.u16(subtable + 10 + index * 2))
                for record in 0..<(try reader.u16(set)) {
                    let at = set + 2 + record * (2 + size1 + size2)
                    let value = try self.value(format1, at: at + 2).value
                    if value != FeatureValue() { result.append(.init(first: first, second: try reader.u16(at), value: value)) }
                }
            }
            return .pairs(result)
        case 2:
            let first = try classDef(subtable + (try reader.u16(subtable + 8)))
            let second = try classDef(subtable + (try reader.u16(subtable + 10)))
            let class1Count = try reader.u16(subtable + 12), class2Count = try reader.u16(subtable + 14)
            var result: [LayoutRules.ClassPair] = []
            for class1 in 0..<class1Count {
                let lefts = covered.filter { (first[$0] ?? 0) == class1 }
                guard !lefts.isEmpty else { continue }
                // Class 0 of the second glyph is every glyph the font does not class: not written.
                for class2 in 1..<max(class2Count, 1) {
                    let rights = second.filter { $0.value == class2 }.map(\.key).sorted()
                    let value = try self.value(format1, at: subtable + 16 + (class1 * class2Count + class2) * (size1 + size2)).value
                    if !rights.isEmpty, value != FeatureValue() { result.append(.init(first: lefts, second: rights, value: value)) }
                }
            }
            return .classPairs(result)
        default:
            return unknown("pair positioning", format)
        }
    }

    private func attachment(_ subtable: Int, format: Int) throws -> LayoutRules {
        guard format == 1 else { return unknown("mark attachment", format) }
        let marks = try coverage(subtable + (try reader.u16(subtable + 2)))
        let bases = try coverage(subtable + (try reader.u16(subtable + 4)))
        let classCount = try reader.u16(subtable + 6)
        let markArray = subtable + (try reader.u16(subtable + 8))
        let baseArray = subtable + (try reader.u16(subtable + 10))
        var classes = [[LayoutAttachment.Mark]](repeating: [], count: classCount)
        for (index, mark) in marks.prefix(try reader.u16(markArray)).enumerated() {
            let markClass = try reader.u16(markArray + 2 + index * 4)
            guard markClass < classCount else { continue }
            classes[markClass].append(.init(glyph: mark, anchor: try anchor(markArray + (try reader.u16(markArray + 4 + index * 4)))))
        }
        var result: [LayoutAttachment.Base] = []
        for (index, base) in bases.prefix(try reader.u16(baseArray)).enumerated() {
            let anchors = try (0..<classCount).map { markClass -> FeatureAnchor? in
                let offset = try reader.u16(baseArray + 2 + (index * classCount + markClass) * 2)
                return offset == 0 ? nil : try anchor(baseArray + offset)
            }
            result.append(.init(glyph: base, anchors: anchors))
        }
        return .attachment(LayoutAttachment(classes: classes, bases: result))
    }
}

/// `GDEF`: the glyph classes (1 base, 2 ligature, 3 mark, 4 component), the mark attachment
/// classes and the mark glyph sets; what else it holds is named for the report.
struct LayoutGDEF {
    var glyphClasses: [Int: Int] = [:]
    var markAttachmentClasses: [Int: Int] = [:]
    var markGlyphSets: [[Int]] = []
    var unread: [String] = []

    init() {}

    init(_ table: FontReader) throws {
        let minor = try table.u16(2)
        glyphClasses = try Self.classDef(table, try table.u16(4))
        if try table.u16(6) != 0 { unread.append("attachment points") }
        if try table.u16(8) != 0 { unread.append("ligature caret positions") }
        markAttachmentClasses = try Self.classDef(table, try table.u16(10))
        if minor >= 2, let sets = try? table.u16(12), sets != 0 {
            markGlyphSets = try (0..<(try table.u16(sets + 2))).map { index in
                try GPOSReader.coverage(table, at: sets + (try table.u32(sets + 4 + index * 4)))
            }
        }
        if minor >= 3, let store = try? table.u32(14), store != 0 { unread.append("variation data") }
    }

    static func classDef(_ table: FontReader, _ offset: Int) throws -> [Int: Int] {
        offset == 0 ? [:] : try GPOSReader.classDef(table, at: offset)
    }
}
