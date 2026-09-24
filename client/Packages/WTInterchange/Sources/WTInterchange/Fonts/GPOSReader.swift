// FONT-025: kerning from `GPOS` (OpenType 1.9, "GPOS — Glyph Positioning Table"): the lookups of
// every `kern` feature, pair adjustment directly or through extension lookups; format 1 subtables
// become pairs, format 2 subtables classes and cells.  Earlier subtables win, as in layout: a pair
// already read is not overwritten, and a glyph already in a class of a side is not put in another.

import Foundation

struct GPOSReader {
    var kerning = FontSource.Kerning()
    /// The feature tags other than `kern`, sorted.
    var dropped: [String] = []

    /// The feature tags of a GPOS or GSUB table, sorted and unique.
    static func featureTags(_ table: FontReader) throws -> [String] {
        let list = try table.u16(6)
        return Array(Set(try (0..<(try table.u16(list))).map { try table.tag(list + 2 + $0 * 6) })).sorted()
    }

    init(_ table: FontReader) throws {
        let featureList = try table.u16(6)
        let lookupList = try table.u16(8)
        var lookups: Set<Int> = []
        for index in 0..<(try table.u16(featureList)) {
            let record = featureList + 2 + index * 6
            let tag = try table.tag(record)
            guard tag == "kern" else { continue }
            let feature = featureList + (try table.u16(record + 4))
            for lookup in 0..<(try table.u16(feature + 2)) { lookups.insert(try table.u16(feature + 4 + lookup * 2)) }
        }
        dropped = try Self.featureTags(table).filter { $0 != "kern" }
        var pairs: [Int: [Int: Int]] = [:]
        var leftAssigned: Set<Int> = [], rightAssigned: [Int: Int] = [:]
        for lookupIndex in lookups.sorted() {
            let lookup = lookupList + (try table.u16(lookupList + 2 + lookupIndex * 2))
            let type = try table.u16(lookup)
            for subtableIndex in 0..<(try table.u16(lookup + 4)) {
                var subtable = lookup + (try table.u16(lookup + 6 + subtableIndex * 2))
                var subtableType = type
                if type == 9 {
                    subtableType = try table.u16(subtable + 2)
                    subtable += try table.u32(subtable + 4)
                }
                guard subtableType == 2 else { continue }
                try read(table, at: subtable, pairs: &pairs, leftAssigned: &leftAssigned, rightAssigned: &rightAssigned)
            }
        }
        kerning.pairs = pairs.keys.sorted().flatMap { left in
            pairs[left]!.keys.sorted().map { FontSource.Kerning.Pair(left: left, right: $0, value: pairs[left]![$0]!) }
        }
    }

    /// The size of a value record of `format`, and the offset of its XAdvance (nil without one).
    static func valueRecord(_ format: Int) -> (size: Int, xAdvance: Int?) {
        let size = (0..<8).filter { format & (1 << $0) != 0 }.count * 2
        let xAdvance = format & 0x0004 != 0 ? (format & 0x0001 != 0 ? 2 : 0) + (format & 0x0002 != 0 ? 2 : 0) : nil
        return (size, xAdvance)
    }

    /// A Coverage table's glyphs in coverage index order.
    static func coverage(_ table: FontReader, at offset: Int) throws -> [Int] {
        switch try table.u16(offset) {
        case 1:
            return try (0..<(try table.u16(offset + 2))).map { try table.u16(offset + 4 + $0 * 2) }
        case 2:
            var glyphs: [Int] = []
            for index in 0..<(try table.u16(offset + 2)) {
                let record = offset + 4 + index * 6
                let start = try table.u16(record), end = try table.u16(record + 2)
                if end >= start { glyphs += Array(start...end) }
            }
            return glyphs
        default:
            throw FontReadError.malformed("Coverage")
        }
    }

    /// A ClassDef table: glyph → class (class 0 left out).
    static func classDef(_ table: FontReader, at offset: Int) throws -> [Int: Int] {
        var classes: [Int: Int] = [:]
        switch try table.u16(offset) {
        case 1:
            let start = try table.u16(offset + 2)
            for index in 0..<(try table.u16(offset + 4)) {
                let value = try table.u16(offset + 6 + index * 2)
                if value != 0 { classes[start + index] = value }
            }
        case 2:
            for index in 0..<(try table.u16(offset + 2)) {
                let record = offset + 4 + index * 6
                let start = try table.u16(record), end = try table.u16(record + 2), value = try table.u16(record + 4)
                if value != 0, end >= start { for glyph in start...end { classes[glyph] = value } }
            }
        default:
            throw FontReadError.malformed("ClassDef")
        }
        return classes
    }

    private mutating func read(_ table: FontReader, at subtable: Int, pairs: inout [Int: [Int: Int]], leftAssigned: inout Set<Int>,
                               rightAssigned: inout [Int: Int]) throws {
        let format = try table.u16(subtable)
        let covered = try Self.coverage(table, at: subtable + (try table.u16(subtable + 2)))
        let first = Self.valueRecord(try table.u16(subtable + 4))
        let second = Self.valueRecord(try table.u16(subtable + 6))
        switch format {
        case 1:
            for (index, left) in covered.enumerated() {
                let set = subtable + (try table.u16(subtable + 10 + index * 2))
                let recordSize = 2 + first.size + second.size
                for record in 0..<(try table.u16(set)) {
                    let at = set + 2 + record * recordSize
                    let right = try table.u16(at)
                    guard let offset = first.xAdvance, pairs[left]?[right] == nil else { continue }
                    let value = try table.i16(at + 2 + offset)
                    if value != 0 { pairs[left, default: [:]][right] = value }
                }
            }
        case 2:
            let firstClasses = try Self.classDef(table, at: subtable + (try table.u16(subtable + 8)))
            let secondClasses = try Self.classDef(table, at: subtable + (try table.u16(subtable + 10)))
            let class1Count = try table.u16(subtable + 12), class2Count = try table.u16(subtable + 14)
            guard let offset = first.xAdvance else { return }
            let recordSize = first.size + second.size
            // Right classes: this subtable's class numbers → the kerning's class indices.
            var rightIndex: [Int: Int] = [:]
            for value in Set(secondClasses.values).sorted() {
                let members = secondClasses.filter { $0.value == value && rightAssigned[$0.key] == nil }.map(\.key).sorted()
                guard !members.isEmpty else { continue }
                rightIndex[value] = kerning.rightClasses.count
                for glyph in members { rightAssigned[glyph] = kerning.rightClasses.count }
                kerning.rightClasses.append(members)
            }
            for class1 in 0..<class1Count {
                let members = covered.filter { (firstClasses[$0] ?? 0) == class1 && !leftAssigned.contains($0) }.sorted()
                var cells: [(Int, Int)] = []
                for class2 in 1..<max(class2Count, 1) {
                    let value = try table.i16(subtable + 16 + (class1 * class2Count + class2) * recordSize + offset)
                    if value != 0, let right = rightIndex[class2] { cells.append((right, value)) }
                }
                guard !members.isEmpty, !cells.isEmpty else { continue }
                leftAssigned.formUnion(members)
                let left = kerning.leftClasses.count
                kerning.leftClasses.append(members)
                kerning.classValues += cells.map { FontSource.Kerning.ClassValue(left: left, right: $0.0, value: $0.1) }
            }
        default:
            throw FontReadError.malformed("PairPos format")
        }
    }
}
