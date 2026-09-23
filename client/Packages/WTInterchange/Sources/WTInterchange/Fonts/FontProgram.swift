// Font data for embedding (export-pdf.adoc "Fonts", export-vector.adoc SVG *Keep as text, embed
// fonts*): the facts a writer needs about a Core Text font, its embedding permission, and a
// TrueType subset built from Core Text's table data.  The subset keeps glyph ids (unused glyphs
// become empty), so a PDF can address glyphs as CIDs through an identity map and an SVG web font
// keeps the font's own `cmap`.  Fonts without TrueType outlines (CFF) have no subset here; the PDF
// writer embeds their glyphs as Type 3 procedures instead (a deviation recorded on export-pdf.adoc)
// and SVG outlines them.  Variable TrueType fonts are instanced by `VariableFontInstancer` for PDF
// (TYPE-048); SVG and EPS outline them.

import CoreGraphics
import CoreText
import Foundation
import WTRender

/// What a writer needs to know about one font.
struct FontFacts {
    let font: CTFont
    let postScriptName: String
    let familyName: String
    let italic: Bool
    let bold: Bool
    /// CSS `font-weight`, 100 ... 900.
    let cssWeight: Int
    /// Whether the license allows embedding (OS/2 `fsType` neither restricted nor bitmap-only).
    let embeddable: Bool
    let unitsPerEm: Double

    init(_ font: CTFont) {
        self.font = font
        postScriptName = CTFontCopyPostScriptName(font) as String
        familyName = CTFontCopyFamilyName(font) as String
        let traits = CTFontGetSymbolicTraits(font)
        italic = traits.contains(.traitItalic)
        bold = traits.contains(.traitBold)
        // Core Text reports a weight trait for every font.
        let weight = ((CTFontCopyTraits(font) as NSDictionary)[kCTFontWeightTrait] as! NSNumber).doubleValue
        cssWeight = FontFacts.cssWeight(forTrait: weight)
        unitsPerEm = Double(CTFontGetUnitsPerEm(font))
        embeddable = FontFacts.embeddingPermitted(FontProgram.table("OS/2", of: font))
    }

    /// Core Text's weight trait (-1 ... 1) as a CSS weight.
    static func cssWeight(forTrait weight: Double) -> Int {
        let steps: [(Double, Int)] = [(-0.7, 100), (-0.5, 200), (-0.3, 300), (0.1, 400), (0.25, 500), (0.35, 600), (0.5, 700), (0.6, 800)]
        return steps.first { weight < $0.0 }?.1 ?? 900
    }

    /// OS/2 `fsType`: bit 1 is Restricted License embedding, bit 9 Bitmap embedding only.
    static func embeddingPermitted(_ os2: Data?) -> Bool {
        guard let os2, os2.count >= 10 else {
            return true
        }
        let fsType = UInt16(os2[os2.startIndex + 8]) << 8 | UInt16(os2[os2.startIndex + 9])
        return fsType & 0x0002 == 0 && fsType & 0x0200 == 0
    }
}

enum FontProgram {
    /// A table of `font` by tag, as Core Text reads it.
    static func table(_ tag: String, of font: CTFont) -> Data? {
        let code = tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return CTFontCopyTable(font, CTFontTableTag(code), []) as Data?
    }

    /// The tables a subset keeps when the font has them.
    static let keptTables = ["OS/2", "cmap", "cvt ", "fpgm", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post", "prep"]

    /// A TrueType font program holding `glyphs` (and `.notdef` and every composite component),
    /// every other glyph empty; nil when the font has no TrueType outlines.
    static func trueTypeSubset(of font: CTFont, glyphs: Set<CGGlyph>) -> Data? {
        guard let glyf = table("glyf", of: font), let loca = table("loca", of: font),
              let head = table("head", of: font), let maxp = table("maxp", of: font),
              head.count >= 54, maxp.count >= 6
        else {
            return nil
        }
        let bytes = [UInt8](glyf)
        let longOffsets = int16(head, 50) != 0
        let count = Int(uint16(maxp, 4))
        let offsets = (0...count).map { index -> Int in
            longOffsets ? Int(uint32(loca, index * 4)) : Int(uint16(loca, index * 2)) * 2
        }
        guard offsets.last.map({ $0 <= bytes.count }) == true else {
            return nil
        }
        func data(of glyph: Int) -> ArraySlice<UInt8> {
            let start = offsets[glyph], end = offsets[glyph + 1]
            return end > start ? bytes[start..<end] : []
        }
        var kept = Set<Int>()
        var pending = [0] + glyphs.map(Int.init).filter { $0 < count }
        while let glyph = pending.popLast() {
            guard kept.insert(glyph).inserted else { continue }
            pending += components(of: data(of: glyph)).filter { $0 < count && !kept.contains($0) }
        }
        var subsetGlyf = [UInt8]()
        var subsetLoca = [UInt8]()
        for glyph in 0..<count {
            append(UInt32(subsetGlyf.count), to: &subsetLoca)
            if kept.contains(glyph) {
                subsetGlyf += data(of: glyph)
                while subsetGlyf.count % 4 != 0 {
                    subsetGlyf.append(0)
                }
            }
        }
        append(UInt32(subsetGlyf.count), to: &subsetLoca)
        var subsetHead = [UInt8](head)
        subsetHead[8..<12] = [0, 0, 0, 0]  // checkSumAdjustment, set below
        subsetHead[50] = 0
        subsetHead[51] = 1  // indexToLocFormat: long
        var tables: [String: Data] = ["glyf": Data(subsetGlyf), "loca": Data(subsetLoca), "head": Data(subsetHead)]
        for tag in keptTables where tables[tag] == nil {
            if let table = table(tag, of: font) {
                tables[tag] = table
            }
        }
        return sfnt(tables)
    }

    /// The component glyph ids of a composite glyph (none for a simple one).
    static func components(of glyph: ArraySlice<UInt8>) -> [Int] {
        let bytes = Array(glyph)
        guard bytes.count >= 10, Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])) < 0 else {
            return []
        }
        var result: [Int] = []
        var position = 10
        while position + 4 <= bytes.count {
            let flags = UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1])
            result.append(Int(UInt16(bytes[position + 2]) << 8 | UInt16(bytes[position + 3])))
            position += 4 + (flags & 0x0001 != 0 ? 4 : 2)
            if flags & 0x0008 != 0 {
                position += 2
            } else if flags & 0x0040 != 0 {
                position += 4
            } else if flags & 0x0080 != 0 {
                position += 8
            }
            if flags & 0x0020 == 0 {
                break
            }
        }
        return result
    }

    /// An sfnt (TrueType) file of `tables`: table directory sorted by tag, 4-byte aligned tables,
    /// checksums and `head.checkSumAdjustment`.
    static func sfnt(_ tables: [String: Data]) -> Data {
        let tags = tables.keys.sorted()
        var entrySelector = 0
        while 1 << (entrySelector + 1) <= tags.count {
            entrySelector += 1
        }
        let searchRange = (1 << entrySelector) * 16
        var header = [UInt8]()
        append(UInt32(0x0001_0000), to: &header)
        append(UInt16(tags.count), to: &header)
        append(UInt16(searchRange), to: &header)
        append(UInt16(entrySelector), to: &header)
        append(UInt16(tags.count * 16 - searchRange), to: &header)
        var body = [UInt8]()
        var directory = [UInt8]()
        var headOffset = 0
        let start = 12 + tags.count * 16
        for tag in tags {
            var table = [UInt8](tables[tag]!)
            let length = table.count
            while table.count % 4 != 0 {
                table.append(0)
            }
            if tag == "head" {
                headOffset = start + body.count
            }
            directory += Array(tag.utf8)
            append(checksum(table), to: &directory)
            append(UInt32(start + body.count), to: &directory)
            append(UInt32(length), to: &directory)
            body += table
        }
        var file = header + directory + body
        let adjustment = 0xB1B0_AFBA &- checksum(file)
        file[(headOffset + 8)..<(headOffset + 12)] = [UInt8(adjustment >> 24), UInt8((adjustment >> 16) & 0xFF), UInt8((adjustment >> 8) & 0xFF), UInt8(adjustment & 0xFF)]
        return Data(file)
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        var index = 0
        while index < bytes.count {
            var word: UInt32 = 0
            for offset in 0..<4 {
                word = word << 8 | UInt32(index + offset < bytes.count ? bytes[index + offset] : 0)
            }
            sum = sum &+ word
            index += 4
        }
        return sum
    }

    static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) << 8 | UInt16(data[base + 1])
    }

    static func int16(_ data: Data, _ offset: Int) -> Int16 {
        Int16(bitPattern: uint16(data, offset))
    }

    static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(uint16(data, offset)) << 16 | UInt32(uint16(data, offset + 2))
    }

    static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes += [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes += [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}

extension GlyphFont {
    /// Whether the glyphs of this font can be embedded as a TrueType subset: the font has
    /// TrueType outlines, is not a variable-font instance and allows embedding.
    var subsettable: Bool {
        variations.isEmpty && FontProgram.table("glyf", of: ctFont) != nil && FontFacts(ctFont).embeddable
    }
}
