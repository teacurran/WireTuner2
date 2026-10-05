// FONT-018: the sfnt tables every generated font carries (OpenType 1.9: `head`, `hhea`, `hmtx`,
// `maxp`, `OS/2`, `name`, `cmap`, `post`) and the sfnt assembly, written from a `FontSource` in
// Swift.  The glyph outline tables are `TrueTypeGlyphs` (glyf/loca) and `CFFWriter` (CFF ); the
// kerning goes through the generated feature text (`FeatureGenerator`, `FeatureTables`).

import Foundation
import WTGeometry

/// Integer bounds of written glyph data.
struct GlyphBox: Hashable, Sendable {
    var xMin: Int
    var yMin: Int
    var xMax: Int
    var yMax: Int

    static let zero = GlyphBox(xMin: 0, yMin: 0, xMax: 0, yMax: 0)

    /// The box of `points`, nil for none.
    init?(_ points: [(Int, Int)]) {
        guard let first = points.first else { return nil }
        var box = GlyphBox(xMin: first.0, yMin: first.1, xMax: first.0, yMax: first.1)
        for (x, y) in points.dropFirst() {
            box.xMin = min(box.xMin, x); box.yMin = min(box.yMin, y)
            box.xMax = max(box.xMax, x); box.yMax = max(box.yMax, y)
        }
        self = box
    }

    init(xMin: Int, yMin: Int, xMax: Int, yMax: Int) {
        self.xMin = xMin
        self.yMin = yMin
        self.xMax = xMax
        self.yMax = yMax
    }
}

/// Per-glyph facts the metric tables need, measured from the outlines as written.
struct GlyphMetricsRecord: Hashable, Sendable {
    var advance: Int
    /// The written outline's bounds, nil for an empty glyph.
    var bounds: GlyphBox?

    var leftSideBearing: Int { bounds?.xMin ?? 0 }
}

enum FontTables {
    /// The font's overall bounds from the glyphs' (zeros for a font with no outlines).
    static func fontBounds(_ records: [GlyphMetricsRecord]) -> GlyphBox {
        let boxes = records.compactMap(\.bounds)
        guard !boxes.isEmpty else { return .zero }
        return GlyphBox(xMin: boxes.map(\.xMin).min()!, yMin: boxes.map(\.yMin).min()!, xMax: boxes.map(\.xMax).max()!, yMax: boxes.map(\.yMax).max()!)
    }

    /// The OS/2 Windows ascent and descent: the typed values, else measured from the outlines
    /// (at least the ascender and descender).
    static func winMetrics(_ source: FontSource, bounds: GlyphBox) -> (ascent: Int, descent: Int) {
        let ascent = source.metrics.winAscent.map { Int($0.rounded()) } ?? max(bounds.yMax, Int(source.metrics.ascender.rounded()))
        let descent = source.metrics.winDescent.map { Int($0.rounded()) } ?? max(-bounds.yMin, Int((-source.metrics.descender).rounded()))
        return (min(max(ascent, 0), 65_535), min(max(descent, 0), 65_535))
    }

    // MARK: head

    /// `head`, 54 bytes; `checkSumAdjustment` is left 0 for the assembler.  `longLoca` selects
    /// the loca format (TrueType only).
    static func head(_ source: FontSource, records: [GlyphMetricsRecord], longLoca: Bool, created: Date?) -> [UInt8] {
        var w = FontWriter()
        let bounds = fontBounds(records)
        w.u16(1); w.u16(0)                          // version 1.0
        w.fixed(source.names.revision)              // fontRevision
        w.u32(0)                                    // checkSumAdjustment
        w.u32(0x5F0F_3CF5)                          // magicNumber
        w.u16(0x000B)                               // flags: baseline y = 0, lsb x = 0, integer ppem
        w.u16(source.metrics.unitsPerEm)
        let seconds = created.map { Int64($0.timeIntervalSince1970) + 2_082_844_800 } ?? 0
        for _ in 0..<2 {                            // created, modified (LONGDATETIME)
            w.u32(Int(seconds >> 32))
            w.u32(Int(seconds & 0xFFFF_FFFF))
        }
        w.i16(bounds.xMin); w.i16(bounds.yMin); w.i16(bounds.xMax); w.i16(bounds.yMax)
        w.u16((source.os2.bold ? 1 : 0) | (source.os2.italic ? 2 : 0))   // macStyle
        w.u16(8)                                    // lowestRecPPEM
        w.i16(2)                                    // fontDirectionHint
        w.i16(longLoca ? 1 : 0)                     // indexToLocFormat
        w.i16(0)                                    // glyphDataFormat
        return w.bytes
    }

    // MARK: hhea, hmtx

    static func hhea(_ source: FontSource, records: [GlyphMetricsRecord]) -> [UInt8] {
        var w = FontWriter()
        w.u16(1); w.u16(0)
        w.i16(Int(source.metrics.ascender.rounded()))
        w.i16(Int(source.metrics.descender.rounded()))
        w.i16(Int(source.metrics.lineGap.rounded()))
        w.u16(records.map(\.advance).max() ?? 0)                                                   // advanceWidthMax
        let drawn = records.filter { $0.bounds != nil }
        w.i16(drawn.map(\.leftSideBearing).min() ?? 0)                                             // minLeftSideBearing
        w.i16(drawn.map { $0.advance - $0.bounds!.xMax }.min() ?? 0)                               // minRightSideBearing
        w.i16(drawn.map { $0.bounds!.xMax }.max() ?? 0)                                            // xMaxExtent
        // The caret slope for the italic angle (rise, run).
        let angle = source.metrics.italicAngle * .pi / 180
        if angle == 0 {
            w.i16(1); w.i16(0)
        } else {
            w.i16(Int((cos(angle) * 10_000).rounded())); w.i16(Int((-sin(angle) * 10_000).rounded()))
        }
        w.i16(0)                                                                                   // caretOffset
        for _ in 0..<4 { w.i16(0) }                                                                // reserved
        w.i16(0)                                                                                   // metricDataFormat
        w.u16(records.count)                                                                       // numberOfHMetrics
        return w.bytes
    }

    static func hmtx(_ records: [GlyphMetricsRecord]) -> [UInt8] {
        var w = FontWriter()
        for record in records {
            w.u16(record.advance)
            w.i16(record.leftSideBearing)
        }
        return w.bytes
    }

    // MARK: maxp

    /// `maxp` 0.5 for CFF outlines.
    static func maxpCFF(glyphs: Int) -> [UInt8] {
        var w = FontWriter()
        w.u32(0x0000_5000)
        w.u16(glyphs)
        return w.bytes
    }

    /// `maxp` 1.0 for TrueType outlines (no glyph instructions, no composites; the stack the
    /// `prep` program uses).
    static func maxpTrueType(glyphs: Int, maxPoints: Int, maxContours: Int) -> [UInt8] {
        var w = FontWriter()
        w.u32(0x0001_0000)
        w.u16(glyphs)
        w.u16(maxPoints); w.u16(maxContours)
        w.u16(0); w.u16(0)          // maxCompositePoints, maxCompositeContours
        w.u16(2)                    // maxZones
        for _ in 0..<4 { w.u16(0) } // twilight points, storage, function defs, instruction defs
        w.u16(1)                    // maxStackElements (the prep program pushes one value at a time)
        for _ in 0..<3 { w.u16(0) } // instruction size, component elements, depth
        return w.bytes
    }

    /// The TrueType `prep` program of an unhinted font: smart dropout control at every size
    /// (`PUSHW[] 511 SCANCTRL[] PUSHB[] 4 SCANTYPE[]`, as `gftools fix-nonhinting` writes it).
    static let dropoutControl: [UInt8] = [0xB8, 0x01, 0xFF, 0x85, 0xB0, 0x04, 0x8D]

    /// `gasp` version 1: one range to the largest size, grid-fitting and smoothing on.
    static let gasp: [UInt8] = [0x00, 0x01, 0x00, 0x01, 0xFF, 0xFF, 0x00, 0x0F]

    // MARK: OS/2

    /// OS/2 version 4.
    static func os2(_ source: FontSource, records: [GlyphMetricsRecord], hasKerning: Bool) -> [UInt8] {
        var w = FontWriter()
        let bounds = fontBounds(records)
        let upm = Double(source.metrics.unitsPerEm)
        func scaled(_ fraction: Double) -> Int { Int((upm * fraction).rounded()) }
        let spacing = records.map(\.advance).filter { $0 > 0 }
        w.u16(4)
        w.i16(spacing.isEmpty ? 0 : Int((Double(spacing.reduce(0, +)) / Double(spacing.count)).rounded()))  // xAvgCharWidth
        w.u16(source.os2.weightClass)
        w.u16(source.os2.widthClass)
        w.u16(Int(source.os2.fsType))
        w.i16(scaled(0.65)); w.i16(scaled(0.6)); w.i16(0); w.i16(scaled(0.075))      // subscript size, offset
        w.i16(scaled(0.65)); w.i16(scaled(0.6)); w.i16(0); w.i16(scaled(0.35))       // superscript size, offset
        w.i16(Int(source.metrics.underlineThickness.rounded()))                     // yStrikeoutSize
        w.i16(Int((source.metrics.xHeight / 2).rounded()))                          // yStrikeoutPosition
        w.i16(0)                                                                    // sFamilyClass
        w.append(Array((source.os2.panose + [UInt8](repeating: 0, count: 10)).prefix(10)))
        let codepoints = Set(source.glyphs.flatMap(\.codepoints))
        for word in unicodeRanges(codepoints) { w.u32(Int(word)) }
        w.tag(String(source.os2.vendorID.prefix(4)))
        var selection = 0
        if source.os2.italic { selection |= 0x0001 }
        if source.os2.bold { selection |= 0x0020 }
        if !source.os2.italic && !source.os2.bold { selection |= 0x0040 }
        selection |= 0x0080                                                         // USE_TYPO_METRICS
        w.u16(selection)
        w.u16(Int(min(codepoints.min() ?? 0, 0xFFFF)))                              // usFirstCharIndex
        w.u16(Int(min(codepoints.max() ?? 0, 0xFFFF)))                              // usLastCharIndex
        w.i16(Int(source.metrics.typoAscender.rounded()))
        w.i16(Int(source.metrics.typoDescender.rounded()))
        w.i16(Int(source.metrics.typoLineGap.rounded()))
        let win = winMetrics(source, bounds: bounds)
        w.u16(win.ascent)
        w.u16(win.descent)
        let latin1 = codepoints.contains { (0xA0...0xFF).contains($0) } || codepoints.contains { (0x20...0x7E).contains($0) }
        w.u32(latin1 ? 1 : 0)                                                       // ulCodePageRange1: Latin 1
        w.u32(0)
        w.i16(Int(source.metrics.xHeight.rounded()))
        w.i16(Int(source.metrics.capHeight.rounded()))
        w.u16(0)                                                                    // usDefaultChar
        w.u16(codepoints.contains(0x20) ? 0x20 : 0)                                 // usBreakChar
        w.u16(hasKerning ? 2 : 1)                                                   // usMaxContext
        return w.bytes
    }

    /// OS/2 `ulUnicodeRange1...4` for the blocks the codepoints touch (the common Latin, Greek,
    /// Cyrillic and punctuation blocks; others are left unset, which is permitted).
    static func unicodeRanges(_ codepoints: Set<UInt32>) -> [UInt32] {
        let blocks: [(ClosedRange<UInt32>, Int)] = [
            (0x0000...0x007F, 0), (0x0080...0x00FF, 1), (0x0100...0x017F, 2), (0x0180...0x024F, 3), (0x0250...0x02AF, 4),
            (0x02B0...0x02FF, 5), (0x0300...0x036F, 6), (0x0370...0x03FF, 7), (0x0400...0x04FF, 9), (0x1E00...0x1EFF, 29),
            (0x2000...0x206F, 31), (0x20A0...0x20CF, 33), (0x2100...0x214F, 35), (0x2190...0x21FF, 37), (0x2200...0x22FF, 38),
            (0xFB00...0xFB4F, 62),
        ]
        var words = [UInt32](repeating: 0, count: 4)
        for (range, bit) in blocks where codepoints.contains(where: range.contains) {
            words[bit / 32] |= 1 << UInt32(bit % 32)
        }
        if codepoints.contains(where: { $0 > 0xFFFF }) { words[1] |= 1 << 25 }   // bit 57: non-plane 0
        return words
    }

    // MARK: name

    /// The styles the four-style (RIBBI) family model names directly.
    static let ribbi = ["Regular", "Italic", "Bold", "Bold Italic"]

    /// `name` format 0: Windows Unicode (3, 1, 0x409) records, UTF-16BE, sorted by name id.
    static func name(_ source: FontSource) -> [UInt8] {
        let names = source.names
        var records: [(Int, String)] = []
        let isRibbi = ribbi.contains(names.style)
        let legacyStyle = source.os2.bold ? (source.os2.italic ? "Bold Italic" : "Bold") : (source.os2.italic ? "Italic" : "Regular")
        records.append((0, names.copyright))
        records.append((1, isRibbi ? names.family : "\(names.family) \(names.style)"))
        records.append((2, isRibbi ? names.style : legacyStyle))
        records.append((3, "\(names.version);\(source.os2.vendorID);\(names.postscript)"))
        records.append((4, names.full))
        records.append((5, "Version \(names.version)"))
        records.append((6, names.postscript))
        records.append((7, names.trademark))
        records.append((8, names.manufacturer))
        records.append((9, names.designer))
        records.append((10, names.description))
        records.append((11, names.manufacturerURL))
        records.append((12, names.designerURL))
        records.append((13, names.license))
        records.append((14, names.licenseURL))
        if !isRibbi {
            records.append((16, names.family))
            records.append((17, names.style))
        }
        records.append((19, names.sampleText))
        let kept = records.filter { !$0.1.isEmpty }
        var strings = FontWriter()
        var w = FontWriter()
        w.u16(0)
        w.u16(kept.count)
        w.u16(6 + kept.count * 12)
        for (id, text) in kept {
            let utf16 = Array(text.utf16.prefix(32_767))
            w.u16(3); w.u16(1); w.u16(0x409); w.u16(id)
            w.u16(utf16.count * 2)
            w.u16(strings.count)
            for unit in utf16 { strings.u16(Int(unit)) }
        }
        w.append(strings)
        return w.bytes
    }

    // MARK: cmap

    /// `cmap` with a format 4 subtable (BMP) under (0, 3) and (3, 1), and a format 12 subtable
    /// under (0, 4) and (3, 10) when a codepoint lies above the BMP.  `map` is codepoint → glyph.
    static func cmap(_ map: [UInt32: Int]) -> [UInt8] {
        let format4 = cmapFormat4(map.filter { $0.key <= 0xFFFF })
        let supplementary = map.keys.contains { $0 > 0xFFFF }
        let format12 = supplementary ? cmapFormat12(map) : []
        let encodings: [(Int, Int, Bool)] = supplementary ? [(0, 3, false), (0, 4, true), (3, 1, false), (3, 10, true)] : [(0, 3, false), (3, 1, false)]
        var w = FontWriter()
        w.u16(0)
        w.u16(encodings.count)
        let start = 4 + encodings.count * 8
        for (platform, encoding, wide) in encodings {
            w.u16(platform); w.u16(encoding)
            w.u32(wide ? start + format4.count : start)
        }
        w.append(format4)
        w.append(format12)
        return w.bytes
    }

    /// Format 4: one segment per run of consecutive codepoints whose glyph ids are consecutive
    /// too (a constant `idDelta`), plus the final 0xFFFF segment.
    static func cmapFormat4(_ map: [UInt32: Int]) -> [UInt8] {
        var segments: [(start: Int, end: Int, delta: Int)] = []
        for codepoint in map.keys.sorted() {
            let code = Int(codepoint), glyph = map[codepoint]!
            if let last = segments.last, last.end == code - 1, last.delta == glyph - code {
                segments[segments.count - 1].end = code
            } else {
                segments.append((code, code, glyph - code))
            }
        }
        if segments.last?.end == 0xFFFF {
            // 0xFFFF is the terminator; a glyph for U+FFFF cannot be in format 4.
            segments[segments.count - 1].end = 0xFFFE
            if segments[segments.count - 1].start > 0xFFFE { segments.removeLast() }
        }
        segments.append((0xFFFF, 0xFFFF, 1))
        let count = segments.count
        var entrySelector = 0
        while 1 << (entrySelector + 1) <= count { entrySelector += 1 }
        let searchRange = 2 << entrySelector
        var w = FontWriter()
        w.u16(4)
        w.u16(16 + count * 8)
        w.u16(0)
        w.u16(count * 2)
        w.u16(searchRange)
        w.u16(entrySelector)
        w.u16(count * 2 - searchRange)
        for segment in segments { w.u16(segment.end) }
        w.u16(0)
        for segment in segments { w.u16(segment.start) }
        for segment in segments { w.u16(segment.delta & 0xFFFF) }
        for _ in segments { w.u16(0) }
        return w.bytes
    }

    /// Format 12: sequential groups of consecutive codepoints and glyph ids.
    static func cmapFormat12(_ map: [UInt32: Int]) -> [UInt8] {
        var groups: [(start: Int, end: Int, glyph: Int)] = []
        for codepoint in map.keys.sorted() {
            let code = Int(codepoint), glyph = map[codepoint]!
            if let last = groups.last, last.end == code - 1, last.glyph + (code - last.start) == glyph {
                groups[groups.count - 1].end = code
            } else {
                groups.append((code, code, glyph))
            }
        }
        var w = FontWriter()
        w.u16(12); w.u16(0)
        w.u32(16 + groups.count * 12)
        w.u32(0)
        w.u32(groups.count)
        for group in groups {
            w.u32(group.start); w.u32(group.end); w.u32(group.glyph)
        }
        return w.bytes
    }

    // MARK: post

    /// `post` 3.0 (no glyph names: CFF carries them) or 2.0 with every name in the table (the
    /// standard Macintosh order is not used; every name index is a custom one).
    static func post(_ source: FontSource, names: Bool) -> [UInt8] {
        var w = FontWriter()
        w.u32(names ? 0x0002_0000 : 0x0003_0000)
        w.fixed(source.metrics.italicAngle)
        w.i16(Int(source.metrics.underlinePosition.rounded()))
        w.i16(Int(source.metrics.underlineThickness.rounded()))
        w.u32(0)                    // isFixedPitch
        for _ in 0..<4 { w.u32(0) } // memory usage hints
        guard names else { return w.bytes }
        w.u16(source.glyphs.count)
        for index in source.glyphs.indices { w.u16(258 + index) }
        for glyph in source.glyphs {
            let bytes = Array(glyph.name.utf8.prefix(255))
            w.u8(bytes.count)
            w.append(bytes)
        }
        return w.bytes
    }

    // MARK: Assembly

    /// An sfnt of `tables` with `signature` (0x00010000 for TrueType outlines, 'OTTO' for CFF):
    /// the directory sorted by tag, tables 4-byte aligned, checksums and
    /// `head.checkSumAdjustment`.
    static func assemble(_ tables: [String: [UInt8]], signature: Int) -> Data {
        var tables = tables
        if var head = tables["head"], head.count >= 12 {
            // The adjustment is computed over the file with the field zero.
            head.replaceSubrange(8..<12, with: [0, 0, 0, 0])
            tables["head"] = head
        }
        let tags = tables.keys.sorted()
        var entrySelector = 0
        while 1 << (entrySelector + 1) <= tags.count { entrySelector += 1 }
        let searchRange = (1 << entrySelector) * 16
        var w = FontWriter()
        w.u32(signature)
        w.u16(tags.count)
        w.u16(searchRange)
        w.u16(entrySelector)
        w.u16(tags.count * 16 - searchRange)
        var offset = 12 + tags.count * 16
        var headOffset: Int?
        for tag in tags {
            let table = tables[tag]!
            w.tag(tag)
            w.u32(Int(FontProgram.checksum(table)))
            w.u32(offset)
            w.u32(table.count)
            if tag == "head" { headOffset = offset }
            offset += (table.count + 3) / 4 * 4
        }
        for tag in tags {
            w.append(tables[tag]!)
            w.pad(to: 4)
        }
        if let headOffset {
            let adjustment = 0xB1B0_AFBA &- FontProgram.checksum(w.bytes)
            w.set32(Int(adjustment), at: headOffset + 8)
        }
        return Data(w.bytes)
    }
}
