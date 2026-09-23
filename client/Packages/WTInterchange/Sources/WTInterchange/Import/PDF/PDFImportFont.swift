// PDF fonts for import (IMG-009): character codes to Unicode (`ToUnicode`, else the font's
// encoding and glyph names), glyph widths to advance the text matrix, and glyph outlines for
// *Convert to paths* and for text that has no Unicode -- from the embedded font program, from
// Type 3 glyph procedures (drawn by the content interpreter), or from the installed font of the
// same name.

import CoreGraphics
import CoreText
import Foundation
import WTGeometry

final class PDFImportFont {
    /// `/BaseFont` without a subset tag (`ABCDEF+Helvetica` → `Helvetica`).
    let name: String
    let subtype: String
    /// Type 0: two-byte codes.
    let twoByte: Bool
    let toUnicode: [UInt32: String]
    /// Simple fonts: glyph names by code from `/Differences`.
    let differences: [UInt32: String]
    /// Simple fonts: the base encoding (`WinAnsiEncoding`, `MacRomanEncoding`, `StandardEncoding`)
    /// or nil for a symbolic font with a built-in encoding.
    let baseEncoding: String?
    let firstChar: Int
    let widths: [Double]
    let missingWidth: Double
    let cidWidths: [UInt32: Double]
    let defaultWidth: Double
    /// Glyph space → text space (0.001 except Type 3).
    let fontMatrix: AffineTransform
    /// Type 3: the glyph procedures by glyph name, and the resources they draw with.
    let charProcs: PDFImportDict?
    let type3Resources: PDFImportDict?
    /// The embedded font program.
    let program: CGFont?
    /// Type 0 with a `/CIDToGIDMap` stream: glyph ids by CID.
    let cidToGID: [UInt16]?

    init(_ dict: PDFImportDict) {
        subtype = dict.name("Subtype") ?? "Type1"
        let base = dict.name("BaseFont") ?? dict.name("Name") ?? ""
        name = PDFImportFont.stripSubset(base)
        twoByte = subtype == "Type0"
        toUnicode = dict.stream("ToUnicode").map { PDFImportFont.parseCMap($0.data) } ?? [:]
        var descriptor = dict.dict("FontDescriptor")
        var widthsDict = dict
        if twoByte, let descendant = dict.array("DescendantFonts")?[0]?.dict {
            descriptor = descendant.dict("FontDescriptor")
            widthsDict = descendant
        }
        let flags = Int(descriptor?.number("Flags") ?? 32)
        let symbolic = flags & 4 != 0
        var differences: [UInt32: String] = [:]
        var baseEncoding: String? = symbolic ? nil : (subtype == "TrueType" ? "WinAnsiEncoding" : "StandardEncoding")
        switch dict["Encoding"] {
        case .name(let encoding)?:
            baseEncoding = encoding
        case .dict(let encoding)?:
            if let name = encoding.name("BaseEncoding") {
                baseEncoding = name
            }
            var code: UInt32 = 0
            for value in encoding.array("Differences")?.values ?? [] {
                if let number = value.number {
                    code = UInt32(max(number, 0))
                } else if let glyph = value.name {
                    differences[code] = glyph
                    code += 1
                }
            }
        default:
            break
        }
        self.differences = differences
        self.baseEncoding = baseEncoding
        firstChar = Int(dict.number("FirstChar") ?? 0)
        widths = dict.numbers("Widths") ?? []
        missingWidth = descriptor?.number("MissingWidth") ?? 0
        defaultWidth = widthsDict.number("DW") ?? 1000
        cidWidths = twoByte ? PDFImportFont.parseCIDWidths(widthsDict.array("W")) : [:]
        if subtype == "Type3", let matrix = dict.numbers("FontMatrix"), matrix.count == 6 {
            fontMatrix = AffineTransform(a: matrix[0], b: matrix[1], c: matrix[2], d: matrix[3], tx: matrix[4], ty: matrix[5])
        } else {
            fontMatrix = .scale(0.001)
        }
        charProcs = dict.dict("CharProcs")
        type3Resources = dict.dict("Resources")
        let file = descriptor?.stream("FontFile2") ?? descriptor?.stream("FontFile3") ?? descriptor?.stream("FontFile")
        program = file.flatMap { CGDataProvider(data: $0.data as CFData) }.flatMap { CGFont($0) }
        if case .stream(let map)? = widthsDict["CIDToGIDMap"] {
            let bytes = [UInt8](map.data)
            cidToGID = stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        } else {
            cidToGID = nil
        }
    }

    static func stripSubset(_ name: String) -> String {
        let parts = name.split(separator: "+", maxSplits: 1)
        if parts.count == 2, parts[0].count == 6, parts[0].allSatisfy({ $0.isUppercase && $0.isASCII }) {
            return String(parts[1])
        }
        return name
    }

    var isType3: Bool { subtype == "Type3" }

    /// The character codes of a shown string.
    func codes(_ data: Data) -> [UInt32] {
        let bytes = [UInt8](data)
        guard twoByte else {
            return bytes.map(UInt32.init)
        }
        return stride(from: 0, to: bytes.count - 1, by: 2).map { UInt32(bytes[$0]) << 8 | UInt32(bytes[$0 + 1]) }
    }

    /// The text a code stands for, nil when the font does not say.
    func unicode(_ code: UInt32) -> String? {
        if let text = toUnicode[code] {
            return text
        }
        guard !twoByte else {
            return nil
        }
        if let glyph = differences[code] {
            return PDFImportFont.unicode(glyphName: glyph)
        }
        guard let encoding = baseEncoding, code < 256 else {
            return nil
        }
        return PDFImportFont.decode(UInt8(code), encoding: encoding)
    }

    /// The glyph name of a simple font's code, for Type 3 procedures and name lookups.
    func glyphName(_ code: UInt32) -> String? {
        if let name = differences[code] {
            return name
        }
        return unicode(code).flatMap(PDFImportFont.glyphName(unicode:))
    }

    /// The code's advance in text space units (at font size 1).
    func width(_ code: UInt32) -> Double {
        if twoByte {
            return (cidWidths[code] ?? defaultWidth) / 1000
        }
        let index = Int(code) - firstChar
        let glyphWidth = index >= 0 && index < widths.count ? widths[index] : (widths.isEmpty ? installedWidth(code) : missingWidth)
        return isType3 ? fontMatrix.apply(Vector(dx: glyphWidth, dy: 0)).dx : glyphWidth / 1000
    }

    /// A simple font without `/Widths` (the standard 14): the installed font's advance.
    func installedWidth(_ code: UInt32) -> Double {
        guard let text = unicode(code), let (font, glyph) = PDFImportFont.installedGlyph(name, text) else {
            return missingWidth
        }
        var g = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &advance, 1)
        return Double(advance.width) * 1000
    }

    // MARK: Outlines

    /// The glyph outline of `code` in text space at font size 1 (not for Type 3, whose
    /// procedures the interpreter draws), nil when neither the embedded program nor an
    /// installed font has it.
    func outline(_ code: UInt32) -> CGPath? {
        if let program {
            let font = CTFontCreateWithGraphicsFont(program, 1, nil, nil)
            if let glyph = programGlyph(code, font: font, program: program) {
                return CTFontCreatePathForGlyph(font, glyph, nil)
            }
        }
        guard let text = unicode(code), let (font, glyph) = PDFImportFont.installedGlyph(name, text) else {
            return nil
        }
        return CTFontCreatePathForGlyph(font, glyph, nil)
    }

    /// The embedded program's glyph for `code`.
    func programGlyph(_ code: UInt32, font: CTFont, program: CGFont) -> CGGlyph? {
        if twoByte {
            if let map = cidToGID {
                return Int(code) < map.count ? map[Int(code)] : nil
            }
            return CGGlyph(truncatingIfNeeded: code)
        }
        if let glyphName = differences[code] {
            let glyph = program.getGlyphWithGlyphName(name: glyphName as CFString)
            if glyph != 0 {
                return glyph
            }
        }
        // A symbolic TrueType font maps its codes into the (3, 0) cmap at 0xF000.
        var candidates: [UniChar] = [UniChar(0xF000 + code), UniChar(code)]
        if let text = unicode(code), let first = text.utf16.first {
            candidates.insert(first, at: 0)
        }
        for candidate in candidates {
            var character = candidate
            var glyph: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 {
                return glyph
            }
        }
        return nil
    }

    /// The installed font `name` (or its substitute) and its glyph for `text`.
    static func installedGlyph(_ name: String, _ text: String) -> (CTFont, CGGlyph)? {
        let font = CTFontCreateWithName((name.isEmpty ? "Helvetica" : name) as CFString, 1, nil)
        let characters = Array(text.utf16)
        guard !characters.isEmpty else {
            return nil
        }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count), glyphs[0] != 0 else {
            return nil
        }
        return (font, glyphs[0])
    }

    /// Whether a font of this PostScript name is installed (not substituted).
    static func isInstalled(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        return (CTFontCopyPostScriptName(font) as String) == name
    }

    // MARK: Tables

    /// A `ToUnicode` CMap's `bfchar` and `bfrange` mappings.
    static func parseCMap(_ data: Data) -> [UInt32: String] {
        var parser = PDFImportParser(data)
        var result: [UInt32: String] = [:]
        func code(_ bytes: Data) -> UInt32 { bytes.reduce(0) { $0 << 8 | UInt32($1) } }
        func text(_ bytes: Data) -> String {
            let b = [UInt8](bytes)
            return String(decoding: stride(from: 0, to: b.count - 1, by: 2).map { UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]) }, as: UTF16.self)
        }
        parser.forEachOperator { op, operands in
                switch op {
                case "endbfchar":
                    var index = 0
                    while index + 1 < operands.count {
                        if let source = operands[index].string, let target = operands[index + 1].string {
                            result[code(source)] = text(target)
                        }
                        index += 2
                    }
                case "endbfrange":
                    var index = 0
                    while index + 2 < operands.count {
                        if let low = operands[index].string, let high = operands[index + 1].string {
                            let from = code(low)
                            let to = code(high)
                            if case .array(let targets) = operands[index + 2] {
                                for (offset, target) in targets.enumerated() where from + UInt32(offset) <= to {
                                    if let target = target.string {
                                        result[from + UInt32(offset)] = text(target)
                                    }
                                }
                            } else if let start = operands[index + 2].string, from <= to, to - from < 65_536 {
                                var units = [UInt8](start)
                                for value in from...to {
                                    result[value] = text(Data(units))
                                    // Increment the last byte of the destination.
                                    if let last = units.indices.last {
                                        units[last] = units[last] &+ 1
                                    }
                                }
                            }
                        }
                        index += 3
                    }
                default:
                    break
                }
        }
        return result
    }

    /// A CID font's `/W` array: `c [w1 w2 …]` and `c_first c_last w` entries.
    static func parseCIDWidths(_ array: PDFImportArray?) -> [UInt32: Double] {
        guard let values = array?.values else {
            return [:]
        }
        var result: [UInt32: Double] = [:]
        var index = 0
        while index + 1 < values.count {
            guard let first = values[index].number else {
                index += 1
                continue
            }
            if let list = values[index + 1].array {
                for (offset, width) in list.numbers.enumerated() {
                    result[UInt32(first) + UInt32(offset)] = width
                }
                index += 2
            } else if index + 2 < values.count, let last = values[index + 1].number, let width = values[index + 2].number {
                if last >= first, last - first < 65_536 {
                    for cid in UInt32(first)...UInt32(last) {
                        result[cid] = width
                    }
                }
                index += 3
            } else {
                index += 1
            }
        }
        return result
    }

    /// A byte in a standard encoding.
    static func decode(_ byte: UInt8, encoding: String) -> String? {
        switch encoding {
        case "MacRomanEncoding":
            return String(bytes: [byte], encoding: .macOSRoman)
        case "StandardEncoding":
            if byte == 0x27 { return "\u{2019}" }
            if byte == 0x60 { return "\u{2018}" }
            return byte >= 0x20 && byte < 0x7F ? String(UnicodeScalar(byte)) : nil
        default:
            // WinAnsiEncoding, and PDFDocEncoding-like unknowns.
            return String(bytes: [byte], encoding: .windowsCP1252)
        }
    }

    /// The Unicode text of a glyph name (Adobe Glyph List conventions for the common names,
    /// `uniXXXX` and `uXXXX`).
    static func unicode(glyphName: String) -> String? {
        let base = String(glyphName.split(separator: ".").first ?? "")
        if let text = glyphNames[base] {
            return text
        }
        if base.count == 1 {
            return base
        }
        if base.hasPrefix("uni"), base.count >= 7, let value = UInt32(base.dropFirst(3).prefix(4), radix: 16), let scalar = UnicodeScalar(value) {
            return String(scalar)
        }
        if base.hasPrefix("u"), (5...7).contains(base.count), let value = UInt32(base.dropFirst(), radix: 16), let scalar = UnicodeScalar(value) {
            return String(scalar)
        }
        return nil
    }

    /// The glyph name of a single character, for name lookups in Type 3 and simple fonts.
    static func glyphName(unicode text: String) -> String? {
        if let name = glyphNames.first(where: { $0.value == text })?.key {
            return name
        }
        guard let scalar = text.unicodeScalars.first else {
            return nil
        }
        if text.unicodeScalars.count == 1, scalar.isASCII, CharacterSet.letters.contains(scalar) {
            return text
        }
        return String(format: "uni%04X", scalar.value)
    }

    static let glyphNames: [String: String] = [
        "space": " ", "exclam": "!", "quotedbl": "\"", "numbersign": "#", "dollar": "$", "percent": "%",
        "ampersand": "&", "quotesingle": "'", "parenleft": "(", "parenright": ")", "asterisk": "*",
        "plus": "+", "comma": ",", "hyphen": "-", "period": ".", "slash": "/", "zero": "0", "one": "1",
        "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "colon": ":", "semicolon": ";", "less": "<", "equal": "=", "greater": ">",
        "question": "?", "at": "@", "bracketleft": "[", "backslash": "\\", "bracketright": "]",
        "asciicircum": "^", "underscore": "_", "grave": "`", "braceleft": "{", "bar": "|",
        "braceright": "}", "asciitilde": "~", "quoteright": "\u{2019}", "quoteleft": "\u{2018}",
        "quotedblleft": "\u{201C}", "quotedblright": "\u{201D}", "bullet": "\u{2022}", "endash": "\u{2013}",
        "emdash": "\u{2014}", "ellipsis": "\u{2026}", "fi": "\u{FB01}", "fl": "\u{FB02}", "copyright": "\u{00A9}",
        "registered": "\u{00AE}", "trademark": "\u{2122}", "degree": "\u{00B0}", "Euro": "\u{20AC}",
        "sterling": "\u{00A3}", "yen": "\u{00A5}", "cent": "\u{00A2}", "section": "\u{00A7}",
        "paragraph": "\u{00B6}", "dagger": "\u{2020}", "daggerdbl": "\u{2021}", "periodcentered": "\u{00B7}",
        "minus": "\u{2212}", "multiply": "\u{00D7}", "divide": "\u{00F7}", "eacute": "\u{00E9}",
        "egrave": "\u{00E8}", "agrave": "\u{00E0}", "aacute": "\u{00E1}", "ccedilla": "\u{00E7}",
        "udieresis": "\u{00FC}", "odieresis": "\u{00F6}", "adieresis": "\u{00E4}", "Adieresis": "\u{00C4}",
        "Odieresis": "\u{00D6}", "Udieresis": "\u{00DC}", "germandbls": "\u{00DF}", "nbspace": "\u{00A0}",
        "exclamdown": "\u{00A1}", "questiondown": "\u{00BF}", "guillemotleft": "\u{00AB}",
        "guillemotright": "\u{00BB}", "Eacute": "\u{00C9}", "ntilde": "\u{00F1}", "Ntilde": "\u{00D1}",
    ]
}

/// Core Graphics paths as imported contours.
enum PDFImportPaths {
    /// The contours of `path` with `transform` applied.
    static func contours(of path: CGPath, transform: AffineTransform = .identity) -> [ImportedContour] {
        var builder = ImportPathBuilder()
        func point(_ p: CGPoint) -> Point { transform.apply(Point(x: Double(p.x), y: Double(p.y))) }
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: builder.move(to: point(points[0]))
            case .addLineToPoint: builder.line(to: point(points[0]))
            case .addQuadCurveToPoint: builder.quad(point(points[0]), point(points[1]))
            case .addCurveToPoint: builder.cubic(point(points[0]), point(points[1]), point(points[2]))
            default: builder.close()
            }
        }
        return builder.build()
    }
}
