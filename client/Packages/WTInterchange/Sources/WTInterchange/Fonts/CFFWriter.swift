// FONT-018: PostScript outlines as a CFF table (Adobe Technical Notes #5176 "The Compact Font Format
// Specification" and #5177 "The Type 2 Charstring Format"): one font, a Top DICT with the names,
// FontBBox, FontMatrix (for an em other than 1000 units), charset and CharStrings, an empty global
// subroutine INDEX, a Private DICT with the width defaults, and one unhinted, unsubroutinized
// Type 2 charstring per glyph -- the width, then `rmoveto` / `rlineto` / `rrcurveto` per contour
// exactly as drawn (cubic), and `endchar`.

import Foundation
import WTGeometry

struct CFFWriter {
    let table: [UInt8]
    let records: [GlyphMetricsRecord]

    init(_ source: FontSource) {
        var records: [GlyphMetricsRecord] = []
        var charstrings: [[UInt8]] = []
        for glyph in source.glyphs {
            let advance = min(max(Int(glyph.advanceWidth.rounded()), 0), 65_535)
            let points = glyph.contours.flatMap { contour in contour.segments.flatMap { [$0.p0, $0.p1, $0.p2, $0.p3] } }
            let bounds = points.isEmpty ? nil : GlyphBox(
                xMin: Int(points.map(\.x).min()!.rounded(.down)), yMin: Int(points.map(\.y).min()!.rounded(.down)),
                xMax: Int(points.map(\.x).max()!.rounded(.up)), yMax: Int(points.map(\.y).max()!.rounded(.up)))
            records.append(GlyphMetricsRecord(advance: advance, bounds: bounds))
            charstrings.append(Self.charstring(glyph.contours, width: advance))
        }
        self.records = records
        table = Self.assemble(source, charstrings: charstrings, bounds: FontTables.fontBounds(records))
    }

    // MARK: Charstrings

    /// A Type 2 number: one to three bytes for integers in -1131 ... 1131, `28` + int16 for
    /// other integers in range, `255` + 16.16 fixed otherwise.
    static func number(_ value: Double) -> [UInt8] {
        if value == value.rounded(), abs(value) <= 32_767 {
            let v = Int(value)
            switch v {
            case -107...107: return [UInt8(v + 139)]
            case 108...1_131: return [UInt8((v - 108) / 256 + 247), UInt8((v - 108) % 256)]
            case -1_131 ... -108: return [UInt8((-v - 108) / 256 + 251), UInt8((-v - 108) % 256)]
            default: return [28, UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
            }
        }
        let fixed = Int32(clamping: Int((value * 65_536).rounded()))
        return [255] + withUnsafeBytes(of: fixed.bigEndian) { Array($0) }
    }

    /// The charstring of `contours` (y up) with the advance `width` (nominal width 0, default
    /// width 0: a zero width is left out).
    static func charstring(_ contours: [Contour], width: Int) -> [UInt8] {
        var out: [UInt8] = []
        var pending: [Double] = width != 0 ? [Double(width)] : []
        var current = WTGeometry.Point(x: 0, y: 0)
        func emit(_ operands: [Double], _ op: UInt8) {
            for value in pending + operands { out += number(value) }
            out.append(op)
            pending = []
        }
        for contour in contours where !contour.isEmpty {
            let start = contour.segments[0].p0
            emit([start.x - current.x, start.y - current.y], 21)           // rmoveto
            current = start
            for (index, segment) in contour.segments.enumerated() {
                let closesLine = index == contour.segments.count - 1 && segment.p3 == start && segment.isLinear()
                if closesLine { break }                                     // the path closes itself
                if segment.isLinear() {
                    emit([segment.p3.x - current.x, segment.p3.y - current.y], 5)   // rlineto
                } else {
                    emit([segment.p1.x - current.x, segment.p1.y - current.y, segment.p2.x - segment.p1.x, segment.p2.y - segment.p1.y,
                          segment.p3.x - segment.p2.x, segment.p3.y - segment.p2.y], 8)  // rrcurveto
                }
                current = segment.p3
            }
        }
        emit([], 14)                                                        // endchar
        return out
    }

    // MARK: DICTs and INDEXes

    /// A DICT integer; `fixedWidth` always uses the five-byte form (offsets filled in later).
    static func dictInteger(_ value: Int, fixedWidth: Bool = false) -> [UInt8] {
        if !fixedWidth {
            switch value {
            case -107...107: return [UInt8(value + 139)]
            case 108...1_131: return [UInt8((value - 108) / 256 + 247), UInt8((value - 108) % 256)]
            case -1_131 ... -108: return [UInt8((-value - 108) / 256 + 251), UInt8((-value - 108) % 256)]
            case -32_768...32_767: return [28, UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
            default: break
            }
        }
        let v = Int32(clamping: value)
        return [29] + withUnsafeBytes(of: v.bigEndian) { Array($0) }
    }

    /// A DICT real: `30`, then decimal nibbles (`a` point, `b` E, `c` E-, `e` minus), `f` ends.
    static func dictReal(_ value: Double) -> [UInt8] {
        let text = String(format: "%.10g", value)
        var nibbles: [UInt8] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "0"..."9": nibbles.append(UInt8(character.asciiValue! - 48))
            case ".": nibbles.append(0xA)
            case "-": nibbles.append(0xE)
            case "e", "E":
                if index + 1 < characters.count, characters[index + 1] == "-" {
                    nibbles.append(0xC)
                    index += 1
                } else {
                    nibbles.append(0xB)
                    if index + 1 < characters.count, characters[index + 1] == "+" { index += 1 }
                }
            default: break
            }
            index += 1
        }
        nibbles.append(0xF)
        if nibbles.count % 2 == 1 { nibbles.append(0xF) }
        return [30] + stride(from: 0, to: nibbles.count, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] }
    }

    /// An INDEX of `items` with four-byte offsets (an empty INDEX is its count alone).
    static func index(_ items: [[UInt8]]) -> [UInt8] {
        var w = FontWriter()
        w.u16(items.count)
        guard !items.isEmpty else { return w.bytes }
        w.u8(4)
        var offset = 1
        w.u32(offset)
        for item in items {
            offset += item.count
            w.u32(offset)
        }
        for item in items { w.append(item) }
        return w.bytes
    }

    /// The whole table.
    static func assemble(_ source: FontSource, charstrings: [[UInt8]], bounds: GlyphBox) -> [UInt8] {
        var strings: [String] = []
        var customSIDs: [String: Int] = [:]
        let standard = Dictionary(standardStrings.enumerated().map { ($1, $0) }) { first, _ in first }
        func sid(_ string: String) -> Int {
            if let known = standard[string] { return known }
            if let known = customSIDs[string] { return known }
            let value = standardStrings.count + strings.count
            strings.append(string)
            customSIDs[string] = value
            return value
        }
        func top(charset: Int, charstringsOffset: Int, privateSize: Int, privateOffset: Int) -> [UInt8] {
            var d: [UInt8] = []
            d += dictInteger(sid(source.names.version)) + [0]
            if !source.names.copyright.isEmpty { d += dictInteger(sid(String(source.names.copyright.prefix(4_000)))) + [12, 0] }
            if !source.names.trademark.isEmpty { d += dictInteger(sid(String(source.names.trademark.prefix(4_000)))) + [1] }
            d += dictInteger(sid(source.names.full)) + [2]
            d += dictInteger(sid(source.names.family)) + [3]
            d += dictInteger(sid(source.os2.bold ? "Bold" : "Regular")) + [4]
            if source.metrics.italicAngle != 0 { d += dictReal(source.metrics.italicAngle) + [12, 2] }
            d += dictInteger(Int(source.metrics.underlinePosition.rounded())) + [12, 3]
            d += dictInteger(Int(source.metrics.underlineThickness.rounded())) + [12, 4]
            if source.metrics.unitsPerEm != 1_000 {
                let scale = 1 / Double(source.metrics.unitsPerEm)
                d += dictReal(scale) + dictInteger(0) + dictInteger(0) + dictReal(scale) + dictInteger(0) + dictInteger(0) + [12, 7]
            }
            d += dictInteger(bounds.xMin) + dictInteger(bounds.yMin) + dictInteger(bounds.xMax) + dictInteger(bounds.yMax) + [5]
            d += dictInteger(charset, fixedWidth: true) + [15]
            d += dictInteger(charstringsOffset, fixedWidth: true) + [17]
            d += dictInteger(privateSize, fixedWidth: true) + dictInteger(privateOffset, fixedWidth: true) + [18]
            return d
        }
        // Glyph names first so their SIDs come before the Top DICT's strings are measured.
        var charset = FontWriter()
        charset.u8(0)
        for glyph in source.glyphs.dropFirst() { charset.u16(sid(glyph.name)) }
        let privateDict = dictInteger(0) + [20] + dictInteger(0) + [21]
        let header: [UInt8] = [1, 0, 4, 4]
        let name = index([Array(source.names.postscript.utf8)])
        let measured = index([top(charset: 0, charstringsOffset: 0, privateSize: 0, privateOffset: 0)])
        let stringIndex = index(strings.map { Array($0.utf8) })
        let globalSubrs = index([])
        let charsetOffset = header.count + name.count + measured.count + stringIndex.count + globalSubrs.count
        let charstringsOffset = charsetOffset + charset.count
        let charstringIndex = index(charstrings)
        let privateOffset = charstringsOffset + charstringIndex.count
        let topIndex = index([top(charset: charsetOffset, charstringsOffset: charstringsOffset, privateSize: privateDict.count,
                                  privateOffset: privateOffset)])
        return header + name + topIndex + stringIndex + globalSubrs + charset.bytes + charstringIndex + privateDict
    }
}
