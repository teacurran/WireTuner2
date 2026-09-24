// FONT-018 / FONT-019 (compiled directly, not through feature text): the kerning model as a `GPOS`
// `kern` feature under the DFLT and latn scripts.  One lookup holds pair-kern (PairPos format 1)
// subtables first and class-kern (PairPos format 2) subtables after them, so an exception wins
// over its classes exactly as the model's lookup rule says: within one lookup the first subtable
// that matches a glyph pair applies.  Every subtable is wrapped in an Extension subtable (32-bit
// offsets) and large ones are split by first glyph or first class, so no 16-bit offset overflows.

enum GPOSKerning {
    /// The largest subtable body aimed for, bytes (keeps internal 16-bit offsets in range).
    static let subtableBudget = 48_000

    /// The table, or nil when there is no kerning.
    static func table(_ kerning: FontSource.Kerning, glyphCount: Int) -> [UInt8]? {
        let subtables = pairSubtables(kerning, glyphCount: glyphCount) + classSubtables(kerning, glyphCount: glyphCount)
        guard !subtables.isEmpty else { return nil }
        var w = FontWriter()
        // Header: version 1.0 and the three list offsets.
        w.u16(1); w.u16(0)
        w.u16(10)                   // ScriptList
        let featureListOffset = 10 + scriptList.count
        w.u16(featureListOffset)
        let lookupListOffset = featureListOffset + featureList.count
        w.u16(lookupListOffset)
        w.append(scriptList)
        w.append(featureList)
        // LookupList: one lookup of type 9 (extension) with the subtables.
        w.u16(1)
        w.u16(4)                    // offset to the lookup from the LookupList
        let lookupStart = w.count
        w.u16(9)                    // lookupType: extension
        w.u16(0)                    // lookupFlag
        w.u16(subtables.count)
        let lookupHeader = 6 + subtables.count * 2
        for index in subtables.indices { w.u16(lookupHeader + index * 8) }
        // Extension subtables, then the PairPos bodies with 32-bit offsets.
        var body = lookupStart + lookupHeader + subtables.count * 8
        for (index, subtable) in subtables.enumerated() {
            let extensionStart = lookupStart + lookupHeader + index * 8
            w.u16(1)                // posFormat
            w.u16(2)                // extensionLookupType: pair adjustment
            w.u32(body - extensionStart)
            body += subtable.count
        }
        for subtable in subtables { w.append(subtable) }
        return w.bytes
    }

    /// ScriptList: DFLT and latn, each with a default LangSys enabling feature 0.
    static var scriptList: [UInt8] {
        var w = FontWriter()
        w.u16(2)
        w.tag("DFLT"); w.u16(14)
        w.tag("latn"); w.u16(26)
        for _ in 0..<2 {
            w.u16(4); w.u16(0)                      // Script: default LangSys at 4, no others
            w.u16(0); w.u16(0xFFFF); w.u16(1); w.u16(0)   // LangSys: no required feature, feature 0
        }
        return w.bytes
    }

    /// FeatureList: `kern` using lookup 0.
    static var featureList: [UInt8] {
        var w = FontWriter()
        w.u16(1)
        w.tag("kern"); w.u16(8)
        w.u16(0); w.u16(1); w.u16(0)
        return w.bytes
    }

    /// Coverage format 1 of sorted glyph ids.
    static func coverage(_ glyphs: [Int]) -> [UInt8] {
        var w = FontWriter()
        w.u16(1)
        w.u16(glyphs.count)
        for glyph in glyphs { w.u16(glyph) }
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

    /// PairPos format 1 subtables of the exceptions, split by first glyph within the budget.
    static func pairSubtables(_ kerning: FontSource.Kerning, glyphCount: Int) -> [[UInt8]] {
        var byLeft: [Int: [Int: Int]] = [:]
        for pair in kerning.pairs where pair.left < glyphCount && pair.right < glyphCount {
            byLeft[pair.left, default: [:]][pair.right] = pair.value
        }
        var chunks: [[Int]] = []
        var size = 0
        for left in byLeft.keys.sorted() {
            let cost = 6 + byLeft[left]!.count * 4
            if chunks.isEmpty || size + cost > subtableBudget {
                chunks.append([])
                size = 0
            }
            chunks[chunks.count - 1].append(left)
            size += cost
        }
        return chunks.map { lefts in
            var w = FontWriter()
            let header = 10 + lefts.count * 2
            let cover = coverage(lefts)
            w.u16(1)                                // posFormat
            w.u16(header)                           // coverage after the header
            w.u16(0x0004); w.u16(0)                 // value formats: XAdvance on the first glyph
            w.u16(lefts.count)
            var offset = header + cover.count
            var sets: [[UInt8]] = []
            for left in lefts {
                var set = FontWriter()
                let pairs = byLeft[left]!.sorted { $0.key < $1.key }
                set.u16(pairs.count)
                for (right, value) in pairs {
                    set.u16(right)
                    set.i16(value)
                }
                w.u16(offset)
                offset += set.count
                sets.append(set.bytes)
            }
            w.append(cover)
            for set in sets { w.append(set) }
            return w.bytes
        }
    }

    /// PairPos format 2 subtables of the class values, split by first class within the budget.
    static func classSubtables(_ kerning: FontSource.Kerning, glyphCount: Int) -> [[UInt8]] {
        guard !kerning.classValues.isEmpty else { return [] }
        let rightClasses = kerning.rightClasses.map { $0.filter { $0 < glyphCount } }
        var rightClassOf: [Int: Int] = [:]
        for (index, members) in rightClasses.enumerated() {
            for glyph in members { rightClassOf[glyph] = index + 1 }
        }
        let class2Count = rightClasses.count + 1
        var values: [Int: [Int: Int]] = [:]
        for cell in kerning.classValues where kerning.leftClasses.indices.contains(cell.left) && rightClasses.indices.contains(cell.right) {
            values[cell.left, default: [:]][cell.right + 1] = cell.value
        }
        let rowCost = class2Count * 2
        let perChunk = max(1, subtableBudget / rowCost - 1)
        let lefts = values.keys.sorted().filter { !kerning.leftClasses[$0].filter { $0 < glyphCount }.isEmpty }
        return stride(from: 0, to: lefts.count, by: perChunk).map { start in
            let chunk = Array(lefts[start..<min(start + perChunk, lefts.count)])
            var classOf: [Int: Int] = [:]
            for (index, left) in chunk.enumerated() {
                for glyph in kerning.leftClasses[left] where glyph < glyphCount { classOf[glyph] = index + 1 }
            }
            let cover = coverage(classOf.keys.sorted())
            let firstClasses = classDef(classOf)
            let secondClasses = classDef(rightClassOf)
            let class1Count = chunk.count + 1
            let header = 16
            let matrix = class1Count * class2Count * 2
            var w = FontWriter()
            w.u16(2)
            w.u16(header + matrix)                                        // coverage
            w.u16(0x0004); w.u16(0)
            w.u16(header + matrix + cover.count)                          // ClassDef1
            w.u16(header + matrix + cover.count + firstClasses.count)     // ClassDef2
            w.u16(class1Count)
            w.u16(class2Count)
            for _ in 0..<class2Count { w.i16(0) }                         // class 0: glyphs in no class
            for left in chunk {
                for right in 0..<class2Count { w.i16(values[left]?[right] ?? 0) }
            }
            w.append(cover)
            w.append(firstClasses)
            w.append(secondClasses)
            return w.bytes
        }
    }
}
