// Fonts in EPS output (export-vector.adoc, "EPS options", *Fonts*).
//
// * *Embed*: TrueType (`glyf`) fonts that allow embedding become Type 42 fonts whose `sfnts` hold a
//   TrueType subset (glyph ids kept, unused glyphs emptied -- the program the PDF writer embeds),
//   split at table and glyph boundaries into strings under 64 KiB.  Codes are assigned in
//   first-use order, 256 per font resource; each resource's `Encoding` maps its codes to glyph
//   names `g<id>` and its `CharStrings` map the names to glyph ids.
// * *Reference only*: the font is named (`%%IncludeResource`) and re-encoded to ISO Latin-1, and a
//   run is shown by its characters -- possible only when its glyphs map one to one onto characters
//   in Latin-1; other runs are outlined.
// * Everything else is outlined by the page writer and reported: fonts whose licence forbids
//   embedding, CFF-flavoured fonts and variable-font instances (no Type 42 program; CFF would need
//   a Level 3 `FontSetInit` resource, not written).

import CoreGraphics
import CoreText
import Foundation
import WTRender

final class PSFontRegistry {
    enum Kind {
        case type42
        case reference
    }

    final class Font {
        let key: String
        let kind: Kind
        let unit: CTFont
        let facts: FontFacts
        var glyphs: [CGGlyph] = []
        var codes: [CGGlyph: Int] = [:]
        /// Resource (PostScript font) names, one per 256 codes for Type 42.
        var names: [String] = []

        init(key: String, kind: Kind, unit: CTFont) {
            self.key = key
            self.kind = kind
            self.unit = unit
            facts = FontFacts(unit)
        }
    }

    let mode: EPSOptions.Fonts
    private(set) var fonts: [String: Font] = [:]
    private(set) var order: [String] = []
    /// Why fonts were outlined, by PostScript name.
    private(set) var outlined: [String: String] = [:]

    init(mode: EPSOptions.Fonts) {
        self.mode = mode
    }

    /// How `run` is shown: nil when it must be drawn as outlines (the reason is recorded).
    func font(for run: GlyphRun, text: String) -> Font? {
        let glyphFont = run.font
        let name = glyphFont.postScriptName
        guard mode != .outlines else {
            return nil
        }
        let key = name + glyphFont.variations.sorted { $0.key < $1.key }.map { "|\($0.key)=\($0.value)" }.joined()
        let unit = GlyphFont(postScriptName: name, size: 1000, variations: glyphFont.variations).ctFont
        if mode == .reference {
            guard glyphFont.variations.isEmpty, PSFontRegistry.latin1Codes(glyphs: run.glyphs.count, text: text) != nil else {
                outlined[name] = "its text is outside ISO Latin-1 or does not map one glyph per character, so it is outlined"
                return nil
            }
            return existing(key) ?? register(key, kind: .reference, unit: unit)
        }
        if let font = fonts[key] {
            return font
        }
        guard FontFacts(unit).embeddable else {
            outlined[name] = "does not allow embedding; its text is outlined"
            return nil
        }
        guard glyphFont.variations.isEmpty, FontProgram.table("glyf", of: unit) != nil else {
            outlined[name] = "has no TrueType outlines for a Type 42 font (CFF or a variable instance); its text is outlined"
            return nil
        }
        return register(key, kind: .type42, unit: unit)
    }

    private func existing(_ key: String) -> Font? {
        fonts[key]
    }

    private func register(_ key: String, kind: Kind, unit: CTFont) -> Font {
        let font = Font(key: key, kind: kind, unit: unit)
        if kind == .reference {
            font.names = [font.facts.postScriptName + "-WTLatin1"]
        }
        fonts[key] = font
        order.append(key)
        return font
    }

    /// The Latin-1 code of each glyph's character, or nil when a run cannot be shown by
    /// characters: glyph and character counts differ, or a character lies outside Latin-1.
    static func latin1Codes(glyphs: Int, text: String) -> [UInt8]? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == glyphs, scalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0xFF && $0.value != 0x7F }) else {
            return nil
        }
        return scalars.map { UInt8($0.value) }
    }

    /// The resource name and code showing glyph `index` of a run in `font`.
    func use(_ glyph: CGGlyph, of font: Font, latin1: UInt8?) -> (name: String, code: UInt8) {
        if font.kind == .reference {
            // Reference fonts are only chosen for runs whose characters all have codes.
            return (font.names[0], latin1!)
        }
        if font.codes[glyph] == nil {
            font.codes[glyph] = font.glyphs.count
            font.glyphs.append(glyph)
        }
        let code = font.codes[glyph]!
        let resource = code / 256
        while font.names.count <= resource {
            let suffix = font.names.isEmpty ? "" : "-\(font.names.count)"
            font.names.append("WT+" + font.facts.postScriptName + suffix)
        }
        return (font.names[resource], UInt8(code % 256))
    }

    /// The advance of `glyph` in thousandths of the size.
    static func advance(of glyph: CGGlyph, in font: CTFont) -> Double {
        var glyphs = [glyph]
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
        return Double(advance.width)
    }

    // MARK: Setup

    /// The DSC resource names of the fonts supplied in the file and needed from the printer.
    var suppliedResources: [String] {
        order.compactMap { fonts[$0] }.filter { $0.kind == .type42 }.flatMap(\.names)
    }

    var neededResources: [String] {
        order.compactMap { fonts[$0] }.filter { $0.kind == .reference }.map(\.facts.postScriptName)
    }

    /// The setup section's font definitions.
    func setup() -> String {
        var out = ""
        for (index, key) in order.enumerated() {
            let font = fonts[key]!
            switch font.kind {
            case .reference:
                let name = font.facts.postScriptName
                out += "%%IncludeResource: font \(name)\n"
                out += "/\(name) findfont dup length dict begin {1 index /FID ne {def} {pop pop} ifelse} forall "
                out += "/Encoding ISOLatin1Encoding def currentdict end /\(font.names[0]) exch definefont pop\n"
            case .type42:
                out += type42(font, index: index)
            }
        }
        return out
    }

    func type42(_ font: Font, index: Int) -> String {
        let glyphs = mode == .embedFull ? Set((0..<CGGlyph(CTFontGetGlyphCount(font.unit))).map { $0 }) : Set(font.glyphs)
        // A font with a glyf table always subsets.
        let program = FontProgram.trueTypeSubset(of: font.unit, glyphs: glyphs)!
        let sfnts = "WTsfnts\(index + 1)"
        var out = "/\(sfnts) [\n"
        for chunk in PSFontRegistry.sfntsChunks(program) {
            out += "<" + HexLines.encode(chunk) + "00>\n"
        }
        out += "] def\n"
        let box = CTFontGetBoundingBox(font.unit)
        let bbox = [box.minX, box.minY, box.maxX, box.maxY].map { Numbers.format(Double($0) / 1000, places: 4) }.joined(separator: " ")
        for (resource, name) in font.names.enumerated() {
            let codes = Array(font.glyphs[(resource * 256)..<min(font.glyphs.count, resource * 256 + 256)])
            out += "%%BeginResource: font \(name)\n"
            out += "11 dict begin\n/FontType 42 def\n/FontName /\(name) def\n/PaintType 0 def\n/FontMatrix [1 0 0 1 0 0] def\n"
            out += "/FontBBox [\(bbox)] def\n"
            out += "/Encoding 256 array 0 1 255 {1 index exch /.notdef put} for\n"
            for (code, glyph) in codes.enumerated() {
                out += "dup \(code) /g\(glyph) put\n"
            }
            out += "readonly def\n/CharStrings \(codes.count + 1) dict dup begin\n/.notdef 0 def\n"
            for glyph in codes {
                out += "/g\(glyph) \(glyph) def\n"
            }
            out += "end readonly def\n/sfnts \(sfnts) def\nFontName currentdict end definefont pop\n%%EndResource\n"
        }
        return out
    }

    /// A TrueType file cut into `sfnts` strings: each under 65,535 bytes, starting at a table
    /// boundary or, inside `glyf`, at a glyph boundary (the Type 42 rules).  Every string is
    /// written with one padding byte, which the interpreter ignores for odd-length strings.
    static func sfntsChunks(_ program: Data, limit: Int = 65_534) -> [Data] {
        let bytes = [UInt8](program)
        let count = Int(FontProgram.uint16(program, 4))
        var tables: [(tag: String, offset: Int, length: Int)] = []
        for index in 0..<count {
            let entry = 12 + index * 16
            let tag = String(decoding: bytes[entry..<(entry + 4)], as: UTF8.self)
            let offset = Int(FontProgram.uint32(program, entry + 8))
            let length = Int(FontProgram.uint32(program, entry + 12))
            tables.append((tag, offset, (length + 3) & ~3))
        }
        tables.sort { $0.offset < $1.offset }
        // Glyph boundaries inside glyf, from the (long) loca table.
        var glyphBreaks: [Int] = []
        if let glyf = tables.first(where: { $0.tag == "glyf" }), let loca = tables.first(where: { $0.tag == "loca" }) {
            glyphBreaks = stride(from: loca.offset, to: loca.offset + loca.length, by: 4).map { glyf.offset + Int(FontProgram.uint32(program, $0)) }
        }
        var chunks: [Data] = []
        var start = 0
        var end = tables.first?.offset ?? bytes.count
        func cut(at position: Int) {
            if position - start > limit, end > start {
                chunks.append(Data(bytes[start..<end]))
                start = end
            }
            end = position
        }
        for table in tables {
            if table.length > limit {
                for position in glyphBreaks where position > end && position <= table.offset + table.length {
                    cut(at: position)
                }
            }
            cut(at: table.offset + table.length)
        }
        if end > start {
            chunks.append(Data(bytes[start..<end]))
        }
        return chunks
    }
}
