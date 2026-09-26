// FONT-019 (and FONT-018's kerning, which now reaches GPOS through generated feature text): the
// binary `GSUB`, `GPOS` and `GDEF` tables of compiled lookups.  Every lookup is an Extension lookup
// (GSUB type 7, GPOS type 9) whose subtables sit after the lookup list behind 32-bit offsets, and
// large subtables are split by first glyph, so no 16-bit offset can overflow however big the font.
// Coverage tables are format 1, class definitions format 2, anchors format 1.

enum FeatureTables {
    /// The largest subtable body aimed for, bytes (keeps internal 16-bit offsets in range).
    static let subtableBudget = 48_000

    // MARK: Shared structures

    /// Coverage format 1 of sorted, distinct glyph ids.
    static func coverage(_ glyphs: [Int]) -> [UInt8] {
        let sorted = Array(Set(glyphs)).sorted()
        var w = FontWriter()
        w.u16(1)
        w.u16(sorted.count)
        for glyph in sorted { w.u16(glyph) }
        return w.bytes
    }

    /// ClassDef format 2: ranges of consecutive glyph ids with one class.
    static func classDef(_ classes: [Int: Int]) -> [UInt8] {
        var ranges: [(start: Int, end: Int, value: Int)] = []
        for glyph in classes.keys.sorted() {
            let value = classes[glyph]!
            if let last = ranges.last, last.end == glyph - 1, last.value == value {
                ranges[ranges.count - 1].end = glyph
            } else {
                ranges.append((glyph, glyph, value))
            }
        }
        var w = FontWriter()
        w.u16(2)
        w.u16(ranges.count)
        for range in ranges {
            w.u16(range.start); w.u16(range.end); w.u16(range.value)
        }
        return w.bytes
    }

    static func anchor(_ anchor: FeatureAnchor) -> [UInt8] {
        var w = FontWriter()
        w.u16(1); w.i16(anchor.x); w.i16(anchor.y)
        return w.bytes
    }

    /// The fields of `value` that `format` names, in ValueRecord order.
    static func value(_ value: FeatureValue, format: Int, into w: inout FontWriter) {
        if format & 1 != 0 { w.i16(value.xPlacement) }
        if format & 2 != 0 { w.i16(value.yPlacement) }
        if format & 4 != 0 { w.i16(value.xAdvance) }
        if format & 8 != 0 { w.i16(value.yAdvance) }
    }

    /// The format covering every value, never 0 (a zero x advance keeps the record valid).
    static func valueFormat(_ values: some Sequence<FeatureValue>) -> Int {
        let format = values.reduce(0) { $0 | $1.format }
        return format == 0 ? 4 : format
    }

    static func valueSize(_ format: Int) -> Int {
        format.nonzeroBitCount * 2
    }

    /// Items chunked so each chunk's estimated cost stays within the budget.
    static func chunks<T>(_ items: [T], cost: (T) -> Int, fixed: Int = 16) -> [[T]] {
        var result: [[T]] = []
        var size = 0
        for item in items {
            let itemCost = cost(item)
            if result.isEmpty || size + itemCost > subtableBudget - fixed {
                result.append([])
                size = 0
            }
            result[result.count - 1].append(item)
            size += itemCost
        }
        return result
    }

    /// A subtable whose header is followed by a coverage and per-glyph child tables at offsets
    /// in the header (GSUB 2, 3, 4 and GPOS 2 format 1 share this shape).
    static func perGlyphSubtable(format: Int, header extra: [Int], glyphs: [Int], children: [[UInt8]]) -> [UInt8] {
        var w = FontWriter()
        let headerSize = 4 + extra.count * 2 + 2 + glyphs.count * 2
        let cover = coverage(glyphs)
        w.u16(format)
        w.u16(headerSize)
        for field in extra { w.u16(field) }
        w.u16(glyphs.count)
        var offset = headerSize + cover.count
        for child in children {
            w.u16(offset)
            offset += child.count
        }
        w.append(cover)
        for child in children { w.append(child) }
        return w.bytes
    }

    // MARK: Subtables

    /// The subtables of `lookup` (without the Extension wrappers).
    static func subtables(_ lookup: FeatureLookup) -> [[UInt8]] {
        switch lookup.body {
        case .single(let map): single(map)
        case .multiple(let map), .alternate(let map): sequences(map)
        case .ligature(let rules): ligature(rules)
        case .chain(let rules): rules.map(chain)
        case .singlePosition(let map): singlePosition(map)
        case .pairPosition(let glyphs, let segments): pairGlyphs(glyphs) + segments.filter { !$0.isEmpty }.flatMap(pairClasses)
        case .markToBase(let attachment), .markToMark(let attachment): markAttachment(attachment)
        }
    }

    /// GSUB 1 format 2.
    static func single(_ map: [Int: Int]) -> [[UInt8]] {
        chunks(map.keys.sorted(), cost: { _ in 4 }).map { glyphs in
            var w = FontWriter()
            w.u16(2)
            w.u16(6 + glyphs.count * 2)
            w.u16(glyphs.count)
            for glyph in glyphs { w.u16(map[glyph]!) }
            w.append(coverage(glyphs))
            return w.bytes
        }
    }

    /// GSUB 2 or 3 format 1: a glyph sequence (or alternate set) per covered glyph.
    static func sequences(_ map: [Int: [Int]]) -> [[UInt8]] {
        chunks(map.keys.sorted(), cost: { 6 + map[$0]!.count * 2 }).map { glyphs in
            let children = glyphs.map { glyph -> [UInt8] in
                var w = FontWriter()
                w.u16(map[glyph]!.count)
                for member in map[glyph]! { w.u16(member) }
                return w.bytes
            }
            return perGlyphSubtable(format: 1, header: [], glyphs: glyphs, children: children)
        }
    }

    /// GSUB 4 format 1: ligature sets by first component, longer ligatures first.
    static func ligature(_ rules: [(components: [Int], glyph: Int)]) -> [[UInt8]] {
        var byFirst: [Int: [(components: [Int], glyph: Int)]] = [:]
        var seen: Set<[Int]> = []
        for rule in rules where seen.insert(rule.components).inserted {
            byFirst[rule.components[0], default: []].append(rule)
        }
        return chunks(byFirst.keys.sorted(), cost: { first in byFirst[first]!.reduce(6) { $0 + 8 + $1.components.count * 2 } }).map { firsts in
            let children = firsts.map { first -> [UInt8] in
                // Stable: longer first, then as written.
                let set = byFirst[first]!.enumerated().sorted { ($1.element.components.count, $0.offset) < ($0.element.components.count, $1.offset) }.map(\.element)
                var w = FontWriter()
                w.u16(set.count)
                var offset = 2 + set.count * 2
                for rule in set {
                    w.u16(offset)
                    offset += 4 + (rule.components.count - 1) * 2
                }
                for rule in set {
                    w.u16(rule.glyph)
                    w.u16(rule.components.count)
                    for component in rule.components.dropFirst() { w.u16(component) }
                }
                return w.bytes
            }
            return perGlyphSubtable(format: 1, header: [], glyphs: firsts, children: children)
        }
    }

    /// GSUB 6 / GPOS 8 format 3: coverage per position, backtrack closest first.
    static func chain(_ rule: FeatureLookup.ChainRule) -> [UInt8] {
        let backtrack = Array(rule.backtrack.reversed())
        let headerSize = 2 + 2 + backtrack.count * 2 + 2 + rule.input.count * 2 + 2 + rule.lookahead.count * 2 + 2 + rule.records.count * 4
        var w = FontWriter()
        var coverages: [[UInt8]] = []
        var offset = headerSize
        func offsets(_ sets: [[Int]]) {
            w.u16(sets.count)
            for set in sets {
                let cover = coverage(set)
                w.u16(offset)
                offset += cover.count
                coverages.append(cover)
            }
        }
        w.u16(3)
        offsets(backtrack)
        offsets(rule.input)
        offsets(rule.lookahead)
        w.u16(rule.records.count)
        for record in rule.records {
            w.u16(record.sequence)
            w.u16(record.lookup)
        }
        for cover in coverages { w.append(cover) }
        return w.bytes
    }

    /// GPOS 1 format 2: a value per covered glyph.
    static func singlePosition(_ map: [Int: FeatureValue]) -> [[UInt8]] {
        let format = valueFormat(map.values)
        return chunks(map.keys.sorted(), cost: { _ in 2 + valueSize(format) }).map { glyphs in
            var w = FontWriter()
            w.u16(2)
            w.u16(8 + glyphs.count * valueSize(format))
            w.u16(format)
            w.u16(glyphs.count)
            for glyph in glyphs { value(map[glyph]!, format: format, into: &w) }
            w.append(coverage(glyphs))
            return w.bytes
        }
    }

    /// GPOS 2 format 1: pair sets by first glyph.
    static func pairGlyphs(_ pairs: [Int: [Int: FeatureValue]]) -> [[UInt8]] {
        guard !pairs.isEmpty else { return [] }
        let format = valueFormat(pairs.values.flatMap(\.values))
        let record = 2 + valueSize(format)
        return chunks(pairs.keys.sorted(), cost: { 4 + pairs[$0]!.count * record }).map { lefts in
            let children = lefts.map { left -> [UInt8] in
                var w = FontWriter()
                let set = pairs[left]!.sorted { $0.key < $1.key }
                w.u16(set.count)
                for (right, pairValue) in set {
                    w.u16(right)
                    value(pairValue, format: format, into: &w)
                }
                return w.bytes
            }
            return perGlyphSubtable(format: 1, header: [format, 0], glyphs: lefts, children: children)
        }
    }

    /// GPOS 2 format 2: the class pairs of one segment, split where a class overlaps another or
    /// the matrix outgrows the budget.
    static func pairClasses(_ rules: [FeatureLookup.ClassPair]) -> [[UInt8]] {
        let format = valueFormat(rules.map(\.value))
        var groups: [[FeatureLookup.ClassPair]] = []
        var firsts: [[Int]] = [], seconds: [[Int]] = []
        var firstGlyphs: Set<Int> = [], secondGlyphs: Set<Int> = []
        func fits(_ set: [Int], in sets: [[Int]], glyphs: Set<Int>) -> Bool {
            sets.contains(set) || glyphs.isDisjoint(with: set)
        }
        for rule in rules {
            let newFirst = !firsts.contains(rule.first), newSecond = !seconds.contains(rule.second)
            let size = (firsts.count + (newFirst ? 1 : 0) + 1) * (seconds.count + (newSecond ? 1 : 0) + 1) * valueSize(format)
            if groups.isEmpty || !fits(rule.first, in: firsts, glyphs: firstGlyphs) || !fits(rule.second, in: seconds, glyphs: secondGlyphs)
                || size > subtableBudget {
                groups.append([])
                firsts = []; seconds = []
                firstGlyphs = []; secondGlyphs = []
            }
            if !firsts.contains(rule.first) {
                firsts.append(rule.first)
                firstGlyphs.formUnion(rule.first)
            }
            if !seconds.contains(rule.second) {
                seconds.append(rule.second)
                secondGlyphs.formUnion(rule.second)
            }
            groups[groups.count - 1].append(rule)
        }
        return groups.map { group in
            var firsts: [[Int]] = [], seconds: [[Int]] = []
            var values: [Int: [Int: FeatureValue]] = [:]
            for rule in group {
                if !firsts.contains(rule.first) { firsts.append(rule.first) }
                if !seconds.contains(rule.second) { seconds.append(rule.second) }
                let l = firsts.firstIndex(of: rule.first)! + 1, r = seconds.firstIndex(of: rule.second)! + 1
                if values[l]?[r] == nil { values[l, default: [:]][r] = rule.value }
            }
            var classOf1: [Int: Int] = [:], classOf2: [Int: Int] = [:]
            for (index, set) in firsts.enumerated() { for glyph in set { classOf1[glyph] = index + 1 } }
            for (index, set) in seconds.enumerated() { for glyph in set { classOf2[glyph] = index + 1 } }
            let cover = coverage(Array(classOf1.keys)), first = classDef(classOf1), second = classDef(classOf2)
            let class1Count = firsts.count + 1, class2Count = seconds.count + 1
            let matrix = class1Count * class2Count * valueSize(format)
            var w = FontWriter()
            w.u16(2)
            w.u16(16 + matrix)
            w.u16(format); w.u16(0)
            w.u16(16 + matrix + cover.count)
            w.u16(16 + matrix + cover.count + first.count)
            w.u16(class1Count); w.u16(class2Count)
            for l in 0..<class1Count {
                for r in 0..<class2Count { value(values[l]?[r] ?? FeatureValue(), format: format, into: &w) }
            }
            w.append(cover); w.append(first); w.append(second)
            return w.bytes
        }
    }

    /// GPOS 4 or 6 format 1: marks with their classes and anchors, attaching glyphs with an
    /// anchor per class (NULL where they have none).
    static func markAttachment(_ attachment: FeatureLookup.Attachment) -> [[UInt8]] {
        let classCount = attachment.classes.count
        let marks = attachment.marks.keys.sorted()
        var markArray = FontWriter()
        markArray.u16(marks.count)
        var anchors: [[UInt8]] = []
        var anchorOffset = 2 + marks.count * 4
        for mark in marks {
            let entry = attachment.marks[mark]!
            markArray.u16(entry.mark)
            markArray.u16(anchorOffset)
            let bytes = anchor(entry.anchor)
            anchors.append(bytes)
            anchorOffset += bytes.count
        }
        for bytes in anchors { markArray.append(bytes) }
        let bases = attachment.bases.keys.sorted()
        return chunks(bases, cost: { 2 * classCount + 6 * (attachment.bases[$0]!.count) }, fixed: 16 + markArray.count + marks.count * 2).map { chunk in
            var baseArray = FontWriter()
            baseArray.u16(chunk.count)
            var anchorBytes: [[UInt8]] = []
            var offset = 2 + chunk.count * classCount * 2
            for base in chunk {
                for classIndex in 0..<classCount {
                    if let found = attachment.bases[base]![classIndex] {
                        baseArray.u16(offset)
                        let bytes = anchor(found)
                        anchorBytes.append(bytes)
                        offset += bytes.count
                    } else {
                        baseArray.u16(0)
                    }
                }
            }
            for bytes in anchorBytes { baseArray.append(bytes) }
            let markCover = coverage(marks), baseCover = coverage(chunk)
            var w = FontWriter()
            w.u16(1)
            w.u16(12)
            w.u16(12 + markCover.count)
            w.u16(classCount)
            w.u16(12 + markCover.count + baseCover.count)
            w.u16(12 + markCover.count + baseCover.count + markArray.count)
            w.append(markCover); w.append(baseCover); w.append(markArray); w.append(baseArray)
            return w.bytes
        }
    }

    // MARK: Tables

    /// The `GSUB` or `GPOS` table of `lookups`, nil when no feature uses the table and it has no
    /// lookups.
    static func layoutTable(_ table: FeatureTableKind, lookups: [FeatureLookup],
                            features: [(tag: String, lookups: [FeatureLanguageSystem: [FeatureTableKind: [Int]]])],
                            systems: [FeatureLanguageSystem]) -> [UInt8]? {
        guard !lookups.isEmpty else { return nil }
        // Feature records: one per tag and distinct lookup list, in tag order.
        var records: [(tag: String, lookups: [Int])] = []
        var recordOf: [FeatureLanguageSystem: [Int]] = [:]
        for feature in features.enumerated().sorted(by: { ($0.element.tag, $0.offset) < ($1.element.tag, $1.offset) }).map(\.element) {
            for system in feature.lookups.keys.sorted() {
                let list = Array(Set(feature.lookups[system]?[table] ?? [])).sorted()
                guard !list.isEmpty else { continue }
                let index = records.firstIndex { $0.tag == feature.tag && $0.lookups == list } ?? {
                    records.append((feature.tag, list))
                    return records.count - 1
                }()
                recordOf[system, default: []].append(index)
            }
        }
        // ScriptList: every declared system plus any a feature names, scripts and languages sorted.
        var byScript: [String: [String: [Int]]] = [:]
        for system in Set(systems).union(recordOf.keys) {
            byScript[system.script, default: [:]][system.language] = (recordOf[system] ?? []).sorted()
        }
        var scriptList = FontWriter()
        let scripts = byScript.keys.sorted()
        scriptList.u16(scripts.count)
        var scriptBodies: [[UInt8]] = []
        var scriptOffset = 2 + scripts.count * 6
        for script in scripts {
            let languages = byScript[script]!
            let others = languages.keys.filter { $0 != "dflt" }.sorted()
            var body = FontWriter()
            let hasDefault = languages["dflt"] != nil
            let headerSize = 4 + others.count * 6
            var langSys: [[UInt8]] = []
            func langSysTable(_ indices: [Int]) -> [UInt8] {
                var w = FontWriter()
                w.u16(0); w.u16(0xFFFF); w.u16(indices.count)
                for index in indices { w.u16(index) }
                return w.bytes
            }
            var offset = headerSize
            if hasDefault {
                body.u16(offset)
                let bytes = langSysTable(languages["dflt"]!)
                langSys.append(bytes)
                offset += bytes.count
            } else {
                body.u16(0)
            }
            body.u16(others.count)
            for language in others {
                body.tag(language)
                body.u16(offset)
                let bytes = langSysTable(languages[language]!)
                langSys.append(bytes)
                offset += bytes.count
            }
            for bytes in langSys { body.append(bytes) }
            scriptList.tag(script)
            scriptList.u16(scriptOffset)
            scriptOffset += body.count
            scriptBodies.append(body.bytes)
        }
        for body in scriptBodies { scriptList.append(body) }
        // FeatureList.
        var featureList = FontWriter()
        featureList.u16(records.count)
        var featureOffset = 2 + records.count * 6
        for record in records {
            featureList.tag(record.tag)
            featureList.u16(featureOffset)
            featureOffset += 4 + record.lookups.count * 2
        }
        for record in records {
            featureList.u16(0)
            featureList.u16(record.lookups.count)
            for index in record.lookups { featureList.u16(index) }
        }
        // LookupList: Extension lookups; the real subtables follow the whole list.
        let extensionType = table == .gsub ? 7 : 9
        let bodies = lookups.map(subtables)
        var lookupList = FontWriter()
        lookupList.u16(lookups.count)
        var lookupOffset = 2 + lookups.count * 2
        for body in bodies {
            lookupList.u16(lookupOffset)
            lookupOffset += 6 + body.count * 10
        }
        let headerSize = 10
        let lookupListStart = headerSize + scriptList.count + featureList.count
        var subtableStart = lookupListStart + lookupOffset
        for (lookup, body) in zip(lookups, bodies) {
            let lookupStart = lookupListStart + lookupList.count
            lookupList.u16(extensionType)
            lookupList.u16(lookup.flag)
            lookupList.u16(body.count)
            for index in body.indices { lookupList.u16(6 + body.count * 2 + index * 8) }
            for (index, subtable) in body.enumerated() {
                let extensionStart = lookupStart + 6 + body.count * 2 + index * 8
                lookupList.u16(1)
                lookupList.u16(lookup.type)
                lookupList.u32(subtableStart - extensionStart)
                subtableStart += subtable.count
            }
        }
        var w = FontWriter()
        w.u16(1); w.u16(0)
        w.u16(headerSize)
        w.u16(headerSize + scriptList.count)
        w.u16(lookupListStart)
        w.append(scriptList)
        w.append(featureList)
        w.append(lookupList)
        for body in bodies { for subtable in body { w.append(subtable) } }
        return w.bytes
    }

    /// `GDEF` version 1.0 with the glyph class definition only.
    static func gdef(_ classes: [Int: Int]) -> [UInt8] {
        var w = FontWriter()
        w.u16(1); w.u16(0)
        w.u16(12)
        w.u16(0); w.u16(0); w.u16(0)
        w.append(classDef(classes))
        return w.bytes
    }
}
