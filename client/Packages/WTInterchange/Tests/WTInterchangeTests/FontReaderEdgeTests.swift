import Foundation
import Testing
import WTGeometry
@testable import WTInterchange

/// Hand-built tables for the OpenType reader's less common paths: composite transforms, point
/// matching, flag repeats, long loca, cmap glyph arrays, Macintosh and non-English names, fonts
/// without optional tables, old kern tables, GSUB, GPOS class and coverage formats, and CFF
/// charsets, DICT reals and every charstring operator.
@Suite struct FontReaderEdgeTests {
    // MARK: Builders

    static func head(unitsPerEm: Int = 1_000, longLoca: Bool = false) -> [UInt8] {
        var w = FontWriter()
        w.u32(0x0001_0000); w.u32(0x0001_0000); w.u32(0); w.u32(0x5F0F_3CF5); w.u16(0); w.u16(unitsPerEm)
        for _ in 0..<4 { w.u32(0) }
        for _ in 0..<4 { w.i16(0) }
        w.u16(0); w.u16(8); w.i16(2); w.i16(longLoca ? 1 : 0); w.i16(0)
        return w.bytes
    }

    static func maxp(_ count: Int) -> [UInt8] {
        var w = FontWriter()
        w.u32(0x0000_5000); w.u16(count)
        return w.bytes
    }

    static func hhea(metrics: Int) -> [UInt8] {
        var w = FontWriter()
        w.u32(0x0001_0000); w.i16(800); w.i16(-200); w.i16(0)
        for _ in 0..<12 { w.i16(0) }
        w.u16(metrics)
        return w.bytes
    }

    static func hmtx(_ advances: [Int]) -> [UInt8] {
        var w = FontWriter()
        for advance in advances { w.u16(advance); w.i16(0) }
        return w.bytes
    }

    /// A simple glyph from raw contours of (x, y, onCurve), with every flag repeated once where
    /// two consecutive flags match (exercising the repeat flag).
    static func simple(_ contours: [[(Int, Int, Bool)]]) -> [UInt8] {
        var w = FontWriter()
        w.i16(contours.count); w.i16(0); w.i16(0); w.i16(0); w.i16(0)
        var end = -1
        for contour in contours { end += contour.count; w.u16(end) }
        w.u16(0)
        let points = contours.flatMap { $0 }
        // Every coordinate as a signed word (no short flags), on-curve bit as given.
        var flags: [UInt8] = points.map { $0.2 ? 1 : 0 }
        var packed: [UInt8] = []
        var index = 0
        while index < flags.count {
            var run = 1
            while index + run < flags.count, flags[index + run] == flags[index], run < 255 { run += 1 }
            if run > 1 {
                packed += [flags[index] | 0x08, UInt8(run - 1)]
            } else {
                packed.append(flags[index])
            }
            index += run
        }
        flags = packed
        w.append(flags)
        var last = 0
        for point in points { w.i16(point.0 - last); last = point.0 }
        last = 0
        for point in points { w.i16(point.1 - last); last = point.1 }
        return w.bytes
    }

    /// A TrueType font of `glyphs` (glyf data per glyph) with optional extra tables.
    static func trueType(_ glyphs: [[UInt8]], extra: [String: [UInt8]] = [:], longLoca: Bool = false) -> Data {
        var glyf = FontWriter()
        var loca = FontWriter()
        for glyph in glyphs {
            if longLoca { loca.u32(glyf.count) } else { loca.u16(glyf.count / 2) }
            glyf.append(glyph)
            glyf.pad(to: 4)
        }
        if longLoca { loca.u32(glyf.count) } else { loca.u16(glyf.count / 2) }
        var tables = ["head": head(longLoca: longLoca), "maxp": maxp(glyphs.count), "hhea": hhea(metrics: 1), "hmtx": hmtx([500]),
                      "glyf": glyf.bytes, "loca": loca.bytes]
        tables.merge(extra) { $1 }
        return FontTables.assemble(tables, signature: 0x0001_0000)
    }

    // MARK: TrueType

    @Test func compositesPointsAndLongLoca() throws {
        let triangle = Self.simple([[(0, 0, true), (100, 0, true), (50, 100, true)]])
        // Off-curve start, two consecutive off-curve points, and a one-point contour.
        let curvy = Self.simple([[(0, 50, false), (50, 100, false), (100, 50, true), (50, 0, false)], [(5, 5, true)]])
        var composite = FontWriter()
        composite.i16(-1); for _ in 0..<4 { composite.i16(0) }
        // Words, x/y values, a uniform scale, more.
        composite.u16(0x0001 | 0x0002 | 0x0008 | 0x0020); composite.u16(0); composite.i16(300); composite.i16(-20); composite.i16(8_192)
        // Bytes, x/y values, separate x and y scales, more.
        composite.u16(0x0002 | 0x0040 | 0x0020); composite.u16(0); composite.u8(10); composite.u8(0xF6); composite.i16(16_384); composite.i16(8_192)
        // Point matching with a 2 × 2, last.
        composite.u16(0x0080); composite.u16(0); composite.u8(1); composite.u8(2)
        composite.i16(0); composite.i16(16_384); composite.i16(-16_384); composite.i16(0)
        let empty = Self.simple([])
        let font = try OpenTypeReader.read(Self.trueType([triangle, curvy, composite.bytes, empty, []], extra: ["fpgm": [0]], longLoca: true))
        #expect(font.glyphs.count == 5 && font.glyphs.map(\.advanceWidth) == [500, 500, 500, 500, 500])
        #expect(font.glyphs.map(\.name) == [".notdef", "glyph1", "glyph2", "glyph3", "glyph4"])
        #expect(font.glyphs[1].contours.count == 1 && font.glyphs[1].contours[0].segments.count == 3)
        let components = font.glyphs[2].components
        #expect(components.map(\.transform) == [
            AffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, tx: 300, ty: -20), AffineTransform(a: 1, b: 0, c: 0, d: 0.5, tx: 10, ty: -10),
            AffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0),
        ])
        #expect(font.report.contains("Components placed by point matching were placed at their origin."))
        #expect(font.report.contains("Hinting instructions were not read."))
        #expect(font.glyphs[3].contours.isEmpty && font.glyphs[4].contours.isEmpty)
        #expect(font.names.family.isEmpty && font.names.style == "Regular" && font.metrics.underlinePosition == -100 && font.os2.weightClass == 400)
    }

    @Test func characterMapsNamesAndOldKerning() throws {
        let triangle = Self.simple([[(0, 0, true), (100, 0, true), (50, 100, true)]])
        // cmap: format 4 with a glyph-id array for A–B under (3, 1).
        var format4 = FontWriter()
        format4.u16(4); format4.u16(16 + 2 * 8 + 4); format4.u16(0); format4.u16(4); format4.u16(4); format4.u16(1); format4.u16(0)
        format4.u16(0x42); format4.u16(0xFFFF); format4.u16(0)
        format4.u16(0x41); format4.u16(0xFFFF)
        format4.u16(0); format4.u16(1)
        format4.u16(4); format4.u16(0)       // seg 0 glyph array 4 bytes on (2 words later)
        format4.u16(1); format4.u16(0)       // glyph ids: A → 1, B → 0 (missing)
        var cmap = FontWriter()
        cmap.u16(0); cmap.u16(2)
        cmap.u16(1); cmap.u16(0); cmap.u32(20)   // Macintosh: ignored
        cmap.u16(3); cmap.u16(1); cmap.u32(20)
        cmap.append(format4)
        // name: a Macintosh family, a French then an English Windows style, typographic names.
        var strings = FontWriter()
        var records: [(Int, Int, Int, Int, [UInt8])] = []
        records.append((1, 0, 0, 1, Array("MacFamily".utf8)))
        func utf16(_ text: String) -> [UInt8] { text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }
        records.append((3, 1, 0x40C, 2, utf16("Gras")))
        records.append((3, 1, 0x409, 2, utf16("Bold")))
        records.append((3, 1, 0x40C, 2, utf16("Gras2")))
        records.append((3, 10, 0x409, 17, utf16("Book")))
        records.append((1, 0, 0, 5, Array("Version 3.25".utf8)))
        var name = FontWriter()
        name.u16(0); name.u16(records.count); name.u16(6 + records.count * 12)
        for (platform, encoding, language, id, bytes) in records {
            name.u16(platform); name.u16(encoding); name.u16(language); name.u16(id); name.u16(bytes.count); name.u16(strings.count)
            strings.append(bytes)
        }
        name.append(strings)
        // An old kern table: a vertical subtable (skipped), then a horizontal one.
        var kern = FontWriter()
        kern.u16(0); kern.u16(2)
        kern.u16(0); kern.u16(14); kern.u16(0x0000); kern.u16(0); kern.u16(0); kern.u16(0); kern.u16(0)
        kern.u16(0); kern.u16(20); kern.u16(0x0001); kern.u16(1); kern.u16(6); kern.u16(0); kern.u16(0); kern.u16(0); kern.u16(1); kern.i16(-40)
        // A post table in format 3 (no names) and an OS/2 version 1 (no x-height).
        var post = FontWriter()
        post.u32(0x0003_0000); post.fixed(-10); post.i16(-80); post.i16(40)
        for _ in 0..<5 { post.u32(0) }
        var os2 = FontWriter()
        os2.u16(1); os2.i16(500); os2.u16(700); os2.u16(3); os2.u16(0)
        for _ in 0..<11 { os2.i16(0) }
        os2.append([UInt8](repeating: 2, count: 10))
        for _ in 0..<4 { os2.u32(0) }
        os2.tag("TEST"); os2.u16(0x21); os2.u16(0x41); os2.u16(0x42); os2.i16(750); os2.i16(-250); os2.i16(10); os2.u16(900); os2.u16(300)
        os2.u32(0); os2.u32(0)
        // GSUB features are listed as not read.
        var gsub = FontWriter()
        gsub.u16(1); gsub.u16(0); gsub.u16(10); gsub.u16(12); gsub.u16(0)
        gsub.u16(0)
        gsub.u16(1); gsub.tag("liga"); gsub.u16(8); gsub.u16(0); gsub.u16(0)
        let data = Self.trueType([triangle, triangle],
                                 extra: ["cmap": cmap.bytes, "name": name.bytes, "kern": kern.bytes, "post": post.bytes, "OS/2": os2.bytes, "GSUB": gsub.bytes])
        let font = try OpenTypeReader.read(data)
        #expect(font.glyphs[1].codepoints == [0x41] && font.glyphs[0].codepoints.isEmpty)
        #expect(font.names.family == "MacFamily" && font.names.style == "Book" && font.names.version == "3.250")
        #expect(font.kerning.pairs == [.init(left: 0, right: 1, value: -40)])
        #expect(font.metrics.italicAngle == -10 && font.metrics.underlinePosition == -80 && font.metrics.underlineThickness == 40)
        #expect(font.os2.weightClass == 700 && font.os2.widthClass == 3 && font.os2.vendorID == "TEST" && font.os2.italic && font.os2.bold)
        #expect(font.metrics.xHeight == 500 && font.metrics.winAscent == 900 && font.metrics.typoLineGap == 10)
        #expect(font.report == ["GSUB feature liga was not read."])
        #expect(try OpenTypeReader.readNames(FontReader(name.bytes, context: "name"))[2] == "Bold")
        // A format 12 group that runs backwards is refused; a cmap with no Unicode subtable is empty.
        var bad = FontWriter()
        bad.u16(0); bad.u16(1); bad.u16(3); bad.u16(10); bad.u32(12)
        bad.u16(12); bad.u16(0); bad.u32(28); bad.u32(0); bad.u32(1); bad.u32(0x42); bad.u32(0x41); bad.u32(1)
        #expect(throws: FontReadError.malformed("cmap")) { try OpenTypeReader.readCMap(FontReader(bad.bytes, context: "cmap")) }
        var mac = FontWriter()
        mac.u16(0); mac.u16(1); mac.u16(1); mac.u16(0); mac.u32(12)
        #expect(try OpenTypeReader.readCMap(FontReader(mac.bytes, context: "cmap")).isEmpty)
    }

    // MARK: GPOS

    /// A GPOS with a `size` feature (dropped) and a `kern` feature using a single adjustment
    /// (skipped), pair format 1 (XPlacement and XAdvance, coverage format 2), pair format 2 through
    /// an extension (class definitions in format 1, class 0 of the first glyph kerned) and a pair
    /// format 2 without XAdvance (nothing read).
    @Test func gposFormatsThroughCraftedLookups() throws {
        // Pair format 1: coverage format 2 (glyphs 1–2), value format 1 = XPlacement | XAdvance.
        var pair = FontWriter()
        pair.u16(1); pair.u16(0); pair.u16(0x0005); pair.u16(0); pair.u16(2); pair.u16(0); pair.u16(0)
        let coverageAt = pair.count
        pair.u16(2); pair.u16(1); pair.u16(1); pair.u16(2); pair.u16(0)
        let set1 = pair.count
        pair.u16(1); pair.u16(3); pair.i16(7); pair.i16(-25)
        let set2 = pair.count
        pair.u16(1); pair.u16(3); pair.i16(0); pair.i16(0)
        pair.set16(coverageAt, at: 2); pair.set16(set1, at: 10); pair.set16(set2, at: 12)
        // Pair format 2: classes in format 1, class 0 of the first glyph kerned too.
        var classes = FontWriter()
        classes.u16(2); classes.u16(0); classes.u16(0x0004); classes.u16(0); classes.u16(0); classes.u16(0); classes.u16(2); classes.u16(2)
        classes.i16(-3); classes.i16(-11); classes.i16(0); classes.i16(-13)   // class 0 row, class 1 row
        let cover = classes.count
        classes.u16(1); classes.u16(2); classes.u16(4); classes.u16(5)
        let first = classes.count
        classes.u16(1); classes.u16(4); classes.u16(2); classes.u16(1); classes.u16(0)   // glyph 4 → 1, 5 → 0
        let second = classes.count
        classes.u16(1); classes.u16(6); classes.u16(1); classes.u16(1)                  // glyph 6 → 1
        classes.set16(cover, at: 2); classes.set16(first, at: 8); classes.set16(second, at: 10)
        // A format 2 subtable without XAdvance contributes nothing; a single adjustment is skipped.
        var noAdvance = FontWriter()
        noAdvance.u16(2); noAdvance.u16(18); noAdvance.u16(0x0001); noAdvance.u16(0); noAdvance.u16(24); noAdvance.u16(24); noAdvance.u16(1); noAdvance.u16(1)
        noAdvance.i16(0)
        noAdvance.u16(1); noAdvance.u16(1); noAdvance.u16(4)                     // coverage at 18
        noAdvance.u16(1); noAdvance.u16(4); noAdvance.u16(1); noAdvance.u16(0)   // ClassDef at 24
        var w = FontWriter()
        w.u16(1); w.u16(0); w.u16(10); w.u16(12); w.u16(42)
        w.u16(0)                                                                 // ScriptList at 10
        w.u16(2); w.tag("kern"); w.u16(14); w.tag("size"); w.u16(26)            // FeatureList at 12
        w.u16(0); w.u16(4); w.u16(0); w.u16(1); w.u16(2); w.u16(3)
        w.u16(0); w.u16(0)
        let list = w.count
        #expect(list == 42)
        w.u16(4); w.u16(10); w.u16(18); w.u16(26); w.u16(34)
        let lookups = [(1, 42), (2, 34), (9, 26), (2, 18)]
        for (index, (type, _)) in lookups.enumerated() { _ = index; w.u16(type); w.u16(0); w.u16(1); w.u16(0) }
        let singleAt = w.count
        w.u16(1); w.u16(6); w.u16(0x0004); w.i16(5); w.u16(1); w.u16(0)
        let pairAt = w.count
        w.append(pair)
        let extensionAt = w.count
        w.u16(1); w.u16(2); w.u32(8)
        w.append(classes)
        let noAdvanceAt = w.count
        w.append(noAdvance)
        // Fix up each lookup's subtable offset (relative to the lookup).
        for (index, target) in [singleAt, pairAt, extensionAt, noAdvanceAt].enumerated() {
            let lookupAt = list + 10 + index * 8
            w.set16(target - lookupAt, at: lookupAt + 6)
        }
        let read = try GPOSReader(FontReader(w.bytes, context: "GPOS"))
        #expect(read.dropped == ["size"])
        #expect(read.kerning.pairs == [.init(left: 1, right: 3, value: -25)])
        #expect(read.kerning.leftClasses == [[5], [4]] && read.kerning.rightClasses == [[6]])
        #expect(read.kerning.classValues == [.init(left: 0, right: 0, value: -11), .init(left: 1, right: 0, value: -13)])
        #expect(throws: FontReadError.malformed("Coverage")) { try GPOSReader.coverage(FontReader([0, 3], context: "c"), at: 0) }
        #expect(throws: FontReadError.malformed("ClassDef")) { try GPOSReader.classDef(FontReader([0, 3], context: "c"), at: 0) }
    }

    // MARK: CFF

    static func dictInt(_ value: Int) -> [UInt8] { CFFWriter.dictInteger(value, fixedWidth: true) }

    /// A CFF table with custom charstrings, subroutines and charset.
    static func cff(charstrings: [[UInt8]], locals: [[UInt8]] = [], globals: [[UInt8]] = [], charset: [UInt8]? = nil, predefinedCharset: Int? = nil,
                    extraTop: [UInt8] = []) -> [UInt8] {
        let header: [UInt8] = [1, 0, 4, 4]
        let name = CFFWriter.index([Array("Test".utf8)])
        let strings = CFFWriter.index([Array("custom".utf8)])
        let global = CFFWriter.index(globals)
        func top(_ charsetOffset: Int, _ charstringsOffset: Int, _ privateSize: Int, _ privateOffset: Int) -> [UInt8] {
            extraTop + dictInt(charsetOffset) + [15] + dictInt(charstringsOffset) + [17] + dictInt(privateSize) + dictInt(privateOffset) + [18]
        }
        let topSize = CFFWriter.index([top(0, 0, 0, 0)]).count
        let charsetOffset = predefinedCharset ?? (header.count + name.count + topSize + strings.count + global.count)
        let charsetBytes = charset ?? []
        let charstringsOffset = header.count + name.count + topSize + strings.count + global.count + charsetBytes.count
        let charstringIndex = CFFWriter.index(charstrings)
        let localIndex = CFFWriter.index(locals)
        // Three five-byte operands and their operators: the local subroutines follow at 18.
        let privateDict = dictInt(0) + [20] + dictInt(0) + [21] + (locals.isEmpty ? [] : dictInt(18) + [19])
        let privateOffset = charstringsOffset + charstringIndex.count
        let topIndex = CFFWriter.index([top(charsetOffset, charstringsOffset, privateDict.count, privateOffset)])
        return header + name + topIndex + strings + global + charsetBytes + charstringIndex + privateDict + (locals.isEmpty ? [] : localIndex)
    }

    func n(_ values: Double...) -> [UInt8] { values.flatMap(CFFWriter.number) }

    @Test func charstringOperatorsDrawTheirSegments() throws {
        let path: [UInt8] =
            n(10, 20) + [21]                                   // rmoveto
            + n(10) + [6] + n(10, 5) + [7]                     // hlineto, vlineto (alternating)
            + n(5, 10, 10, 5, 5) + [27]                        // hhcurveto with dy1
            + n(5, 10, 10, 5, 5) + [26]                        // vvcurveto with dx1
            + n(10, 10, 10, 10, 10, 10, 10, 10, 3) + [31]      // hvcurveto, last with df
            + n(10, 10, 10, 10, 10, 10, 10, 10, 3) + [30]      // vhcurveto, last with df
            + n(1, 1, 1, 1, 1, 1, 2, 2) + [24]                 // rcurveline
            + n(2, 2, 1, 1, 1, 1, 1, 1) + [25]                 // rlinecurve
            + n(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 50) + [12, 35]   // flex
            + n(1, 1, 1, 1, 1, 1, 1) + [12, 34]                // hflex
            + n(1, 1, 1, 1, 1, 1, 1, 1, 1) + [12, 36]          // hflex1
            + n(5, 1, 5, 1, 5, 1, 5, 1, 5, 1, 1) + [12, 37]    // flex1, horizontal
            + n(1, 5, 1, 5, 1, 5, 1, 5, 1, 5, 1) + [12, 37]    // flex1, vertical
            + n(1) + [12, 18]                                  // an arithmetic operator: stack cleared
            + [255, 0, 1, 0x80, 0] + [22]                      // hmoveto with a fixed operand
            + n(5) + [4]                                       // vmoveto
            + n(3, 4) + [5]
            + [14]
        let hints: [UInt8] = n(100, 10, 20, 10, 20) + [1] + n(5, 10, 20, 10) + [18] + n(1, 2) + [19, 0xFF] + n(3, 4) + [23] + [20, 0xFF] + n(5, 6) + [3]
            + n(0, 0) + [21] + n(10, 0) + [5] + n(0, 10) + [5] + n(900) + [14]
        let widthOnly: [UInt8] = n(500) + [14]
        let seac: [UInt8] = n(500, 0, 0, 65, 97) + [14]
        let subroutined: [UInt8] = n(-107) + [10] + n(-107) + [29] + [14]
        let local: [UInt8] = n(0, 0) + [21] + n(10, 0) + [5] + [11]
        let global: [UInt8] = n(0, 10) + [5] + [11]
        let charset: [UInt8] = [2, 0, 1, 0, 3]                 // format 2: SIDs 1 ... 4 (space ... numbersign)
        let table = Self.cff(charstrings: [widthOnly, path, hints, seac, subroutined], locals: [local], globals: [global], charset: charset)
        let read = try CFFReader(FontReader(table, context: "CFF "), glyphCount: 6)
        #expect(read.names == [".notdef", "space", "exclam", "quotedbl", "numbersign"])
        #expect(read.contours.count == 6 && read.contours[0].isEmpty && read.contours[5].isEmpty)
        // The hmoveto starts a contour the vmoveto leaves empty: two contours.
        #expect(read.contours[1].count == 2 && read.contours[1][0].segments.count > 20)
        #expect(read.contours[2].count == 1 && read.contours[2][0].segments.count == 2)
        #expect(read.contours[4].first?.segments.count == 2)
        // Charset format 1 and the predefined charsets.
        let format1 = try CFFReader(FontReader(Self.cff(charstrings: [widthOnly, widthOnly, widthOnly], charset: [1, 1, 135, 1]), context: "CFF "),
                                    glyphCount: 3)
        #expect(format1.names == [".notdef", "custom", "glyph392"])
        let format0 = try CFFReader(FontReader(Self.cff(charstrings: [widthOnly, widthOnly], charset: [0, 0, 5]), context: "CFF "), glyphCount: 2)
        #expect(format0.names == [".notdef", "dollar"])
        let isoAdobe = try CFFReader(FontReader(Self.cff(charstrings: [widthOnly, widthOnly], predefinedCharset: 0), context: "CFF "), glyphCount: 2)
        #expect(isoAdobe.names == [".notdef", "space"])
        let expert = try CFFReader(FontReader(Self.cff(charstrings: [widthOnly], predefinedCharset: 1), context: "CFF "), glyphCount: 1)
        #expect(expert.names == nil)
        #expect(throws: FontReadError.malformed("CFF charset")) {
            try CFFReader(FontReader(Self.cff(charstrings: [widthOnly, widthOnly], charset: [7]), context: "CFF "), glyphCount: 2)
        }
        #expect(CharstringInterpreter.bias(2_000) == 1_131 && CharstringInterpreter.bias(40_000) == 32_768)
    }

    @Test func cffRefusalsAndDicts() throws {
        let widthOnly: [UInt8] = n(500) + [14]
        #expect(throws: FontReadError.unsupported("CID-keyed CFF")) {
            try CFFReader(FontReader(Self.cff(charstrings: [widthOnly], extraTop: Self.dictInt(1) + Self.dictInt(2) + Self.dictInt(0) + [12, 30]), context: "CFF "), glyphCount: 1)
        }
        // DICT operands: reals with exponents, 16- and 32-bit integers, two-byte integers.
        let dict = try CFFReader.dict([30, 0x1B, 0x2F, 17, 30, 0x2C, 0x1F, 18, 28, 0x01, 0x00, 247, 0, 251, 0, 29, 0, 1, 0, 0, 12, 7])
        #expect(dict[17] == [1e2] && dict[18] == [2e-1] && dict[1_207] == [256, 108, -108, 65_536])
        #expect(throws: FontReadError.malformed("CFF DICT")) { try CFFReader.dict([255]) }
        #expect(throws: FontReadError.truncated("CFF DICT")) { try CFFReader.dict([12]) }
        #expect(throws: FontReadError.truncated("CFF DICT")) { try CFFReader.dict([28, 1]) }
        #expect(throws: FontReadError.truncated("CFF DICT")) { try CFFReader.dict([247]) }
        #expect(try CFFReader.dict([30, 0xDF]) == [:])
        // INDEX offsets: an invalid offset size and offsets that run backwards.
        #expect(throws: FontReadError.malformed("CFF INDEX")) { try CFFReader.index(FontReader([0, 1, 5, 0, 0], context: "i"), at: 0) }
        #expect(throws: FontReadError.malformed("CFF INDEX")) { try CFFReader.index(FontReader([0, 1, 1, 3, 1], context: "i"), at: 0) }
        #expect(try CFFReader.index(FontReader([0, 2, 2, 0, 1, 0, 2, 0, 3, 7, 8], context: "i"), at: 0).items == [9..<10, 10..<11])
        // A Top DICT INDEX that is empty, and no CharStrings.
        let noTop: [UInt8] = [1, 0, 4, 4] + CFFWriter.index([Array("T".utf8)]) + [0, 0]
        #expect(throws: FontReadError.malformed("CFF Top DICT")) { try CFFReader(FontReader(noTop, context: "CFF "), glyphCount: 1) }
        let noCharStrings: [UInt8] = [1, 0, 4, 4] + CFFWriter.index([Array("T".utf8)]) + CFFWriter.index([[139, 0]]) + [0, 0] + [0, 0]
        #expect(throws: FontReadError.malformed("CFF CharStrings")) { try CFFReader(FontReader(noCharStrings, context: "CFF "), glyphCount: 1) }
        // Charstring errors: stack underflow, missing subroutines, runaway recursion.
        let interpreter = { (bytes: [UInt8], locals: [[UInt8]]) -> Result<[Contour], Error> in
            var all = bytes
            var ranges: [Range<Int>] = []
            for local in locals {
                ranges.append(all.count..<(all.count + local.count))
                all += local
            }
            let engine = CharstringInterpreter(data: FontReader(all, context: "cs"), globals: [], locals: ranges)
            return Result { try engine.contours(0..<bytes.count) }
        }
        for bytes in [[21], [22], [4], [10], n(5) + [10], [12, 35], [12, 34], [12, 36], [12, 37]] as [[UInt8]] {
            #expect(throws: (any Error).self) { try interpreter(bytes, []).get() }
        }
        let recursive: [UInt8] = n(-107) + [10]
        #expect(throws: FontReadError.malformed("charstring subroutine depth")) { try interpreter(recursive, [recursive]).get() }
        #expect(try interpreter([0x01] + [14], []).get().isEmpty)
    }
}
