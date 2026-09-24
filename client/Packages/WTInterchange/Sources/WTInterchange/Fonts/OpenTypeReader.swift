// FONT-025: opening an existing OTF or TTF as typeface data (font-export.adoc, "Opening an
// existing font", "OTF/TTF import"): a table parser in Swift for `head`, `hhea`, `hmtx`, `maxp`,
// `OS/2`, `name`, `cmap` (formats 4 and 12), `post` (2.0 names), `glyf`/`loca` (simple and
// composite glyphs; quadratic curves converted to cubics exactly), `CFF ` (Type 2 charstrings
// with local and global subroutines; CID-keyed fonts refused), and kerning from the `GPOS` `kern`
// feature (pair positioning formats 1 and 2, through extension lookups) or an old-format `kern`
// table.  Hinting is not read; mark attachment, ligatures and other layout features are listed in
// the report as dropped (the decompiler into feature text is not built; recorded on the page).
// Fonts whose embedding permission is Restricted are refused.

import Foundation
import WTGeometry

/// A font as read, in font units (y up), ready for WTModel's import.
public struct ImportedFont: Hashable, Sendable {
    /// A component of a composite TrueType glyph.
    public struct Component: Hashable, Sendable {
        /// The glyph index used.
        public var glyph: Int
        /// Source glyph space → this glyph (font units, y up).
        public var transform: AffineTransform

        public init(glyph: Int, transform: AffineTransform) {
            self.glyph = glyph
            self.transform = transform
        }
    }

    public struct Glyph: Hashable, Sendable {
        public var name: String
        public var codepoints: [UInt32]
        public var advanceWidth: Double
        /// Cubic contours, y up, closed.
        public var contours: [Contour]
        public var components: [Component]

        public init(name: String, codepoints: [UInt32], advanceWidth: Double, contours: [Contour], components: [Component]) {
            self.name = name
            self.codepoints = codepoints
            self.advanceWidth = advanceWidth
            self.contours = contours
            self.components = components
        }
    }

    public var names: FontSource.Names
    public var metrics: FontSource.Metrics
    public var os2: FontSource.OS2
    public var glyphs: [Glyph]
    public var kerning: FontSource.Kerning
    /// What was not read (hinting, layout features other than kern, point-matched components).
    public var report: [String]

    public init(names: FontSource.Names, metrics: FontSource.Metrics, os2: FontSource.OS2, glyphs: [Glyph], kerning: FontSource.Kerning, report: [String]) {
        self.names = names
        self.metrics = metrics
        self.os2 = os2
        self.glyphs = glyphs
        self.kerning = kerning
        self.report = report
    }
}

/// Reads OpenType fonts.
public enum OpenTypeReader {
    /// Reads `data` (an OTF or TTF; collections and WOFF are refused).
    public static func read(_ data: Data) throws -> ImportedFont {
        let file = FontReader(data, context: "sfnt")
        let signature = try file.u32(0)
        guard signature == 0x0001_0000 || signature == 0x4F54_544F || signature == 0x7472_7565 else {
            throw FontReadError.unsupported(signature == 0x7474_6366 ? "font collections" : "not an OpenType font")
        }
        var tables: [String: FontReader] = [:]
        for index in 0..<(try file.u16(4)) {
            let entry = 12 + index * 16
            let tag = try file.tag(entry)
            tables[tag] = try file.sub(try file.u32(entry + 8), try file.u32(entry + 12), context: tag)
        }
        func table(_ tag: String) throws -> FontReader {
            guard let found = tables[tag] else { throw FontReadError.missingTable(tag) }
            return found
        }
        var report: [String] = []
        let head = try table("head")
        let unitsPerEm = try head.u16(18)
        let maxp = try table("maxp")
        let count = try maxp.u16(4)
        let hhea = try table("hhea")
        let advances = try readAdvances(try table("hmtx"), metrics: try hhea.u16(34), count: count)
        let os2 = tables["OS/2"]
        let fsType = try os2.map { try $0.u16(8) } ?? 0
        if fsType & 0x000F == 0x0002 { throw FontReadError.unsupported("embedding permission Restricted") }
        // Outlines.
        var contours = [[Contour]](repeating: [], count: count)
        var components = [[ImportedFont.Component]](repeating: [], count: count)
        var cffNames: [String]?
        if let cff = tables["CFF "] {
            let read = try CFFReader(cff, glyphCount: count)
            contours = read.contours
            cffNames = read.names
        } else {
            let glyphs = try TrueTypeReader(glyf: try table("glyf"), loca: try table("loca"), longOffsets: try head.i16(50) != 0, count: count)
            contours = glyphs.contours
            components = glyphs.components
            if glyphs.pointMatched { report.append("Components placed by point matching were placed at their origin.") }
            if tables["fpgm"] != nil || tables["prep"] != nil { report.append("Hinting instructions were not read.") }
        }
        // Names: post 2.0, else CFF's charset, else from the character map.
        let map = try tables["cmap"].map(readCMap) ?? [:]
        var glyphNames = try tables["post"].flatMap { try readPostNames($0, count: count) } ?? cffNames ?? []
        if glyphNames.count != count {
            glyphNames = (0..<count).map { $0 == 0 ? ".notdef" : "glyph\($0)" }
        }
        var codepoints = [[UInt32]](repeating: [], count: count)
        for (codepoint, glyph) in map where glyph < count {
            codepoints[glyph].append(codepoint)
        }
        let glyphs = (0..<count).map { index in
            ImportedFont.Glyph(name: glyphNames[index], codepoints: codepoints[index].sorted(), advanceWidth: Double(advances[index]),
                               contours: contours[index], components: components[index])
        }
        // Kerning, and the layout features that are not read.
        var kerning = FontSource.Kerning()
        if let gpos = tables["GPOS"] {
            let read = try GPOSReader(gpos)
            kerning = read.kerning
            report += read.dropped.map { "GPOS feature \($0) was not read." }
        } else if let kern = tables["kern"] {
            kerning = try readKernTable(kern)
        }
        if let gsub = tables["GSUB"] {
            report += try GPOSReader.featureTags(gsub).map { "GSUB feature \($0) was not read." }
        }
        let names = try tables["name"].map(readNames) ?? [:]
        func name(_ id: Int) -> String { names[id] ?? "" }
        let family = names[16] ?? name(1)
        let style = names[17] ?? (names[2] ?? "Regular")
        var fontNames = FontSource.Names(family: family, style: style, postscript: name(6), full: name(4), version: version(name(5)))
        fontNames.copyright = name(0)
        fontNames.trademark = name(7)
        fontNames.manufacturer = name(8)
        fontNames.designer = name(9)
        fontNames.description = name(10)
        fontNames.manufacturerURL = name(11)
        fontNames.designerURL = name(12)
        fontNames.license = name(13)
        fontNames.licenseURL = name(14)
        fontNames.sampleText = name(19)
        let post = tables["post"]
        var metrics = FontSource.Metrics(unitsPerEm: unitsPerEm, ascender: Double(try hhea.i16(4)), descender: Double(try hhea.i16(6)),
                                         lineGap: Double(try hhea.i16(8)))
        metrics.italicAngle = try post.map { try $0.fixed(4) } ?? 0
        metrics.underlinePosition = Double(try post.map { try $0.i16(8) } ?? -100)
        metrics.underlineThickness = Double(try post.map { try $0.i16(10) } ?? 50)
        var style2 = FontSource.OS2(fsType: UInt16(fsType))
        if let os2 {
            style2.weightClass = try os2.u16(4)
            style2.widthClass = try os2.u16(6)
            style2.panose = try os2.slice(32, 10)
            style2.vendorID = String(decoding: try os2.slice(58, 4), as: UTF8.self)
            let selection = try os2.u16(62)
            style2.italic = selection & 0x01 != 0
            style2.bold = selection & 0x20 != 0
            metrics.typoAscender = Double(try os2.i16(68))
            metrics.typoDescender = Double(try os2.i16(70))
            metrics.typoLineGap = Double(try os2.i16(72))
            metrics.winAscent = Double(try os2.u16(74))
            metrics.winDescent = Double(try os2.u16(76))
            if try os2.u16(0) >= 2, os2.count >= 90 {
                metrics.xHeight = Double(try os2.i16(86))
                metrics.capHeight = Double(try os2.i16(88))
            }
        }
        return ImportedFont(names: fontNames, metrics: metrics, os2: style2, glyphs: glyphs, kerning: kerning, report: report)
    }

    /// "Version 1.002; ..." → "1.002" (the stored version pattern), else "1.000".
    static func version(_ text: String) -> String {
        let digits = text.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
        let parts = digits.split(separator: ".")
        guard parts.count >= 2, let major = Int(parts[0]) else { return "1.000" }
        let minor = String(parts[1].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        return "\(major).\(minor)"
    }

    static func readAdvances(_ hmtx: FontReader, metrics: Int, count: Int) throws -> [Int] {
        var result: [Int] = []
        var last = 0
        for index in 0..<count {
            if index < metrics { last = try hmtx.u16(index * 4) }
            result.append(last)
        }
        return result
    }

    /// Name records: Windows Unicode preferred (English first), then Macintosh Roman.
    static func readNames(_ name: FontReader) throws -> [Int: String] {
        let count = try name.u16(2)
        let storage = try name.u16(4)
        var windows: [Int: (String, Bool)] = [:]
        var mac: [Int: String] = [:]
        for index in 0..<count {
            let record = 6 + index * 12
            let platform = try name.u16(record), encoding = try name.u16(record + 2), language = try name.u16(record + 4)
            let id = try name.u16(record + 6)
            let bytes = try name.slice(storage + (try name.u16(record + 10)), try name.u16(record + 8))
            if platform == 3, encoding == 1 || encoding == 10 {
                let units = stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
                let english = language == 0x409
                if windows[id] == nil || (english && windows[id]?.1 == false) { windows[id] = (String(decoding: units, as: UTF16.self), english) }
            } else if platform == 1, encoding == 0, mac[id] == nil {
                mac[id] = String(bytes.map { Character(Unicode.Scalar($0)) })
            }
        }
        return mac.merging(windows.mapValues(\.0)) { _, windows in windows }
    }

    /// `post` 2.0 glyph names; nil for other formats.
    static func readPostNames(_ post: FontReader, count: Int) throws -> [String]? {
        guard try post.u32(0) == 0x0002_0000 else { return nil }
        let numberOfGlyphs = try post.u16(32)
        let indices = try (0..<numberOfGlyphs).map { try post.u16(34 + $0 * 2) }
        var custom: [String] = []
        var position = 34 + numberOfGlyphs * 2
        while position < post.count {
            let length = try post.u8(position)
            custom.append(String(decoding: try post.slice(position + 1, length), as: UTF8.self))
            position += 1 + length
        }
        let names = indices.map { index in
            index < 258 ? macintoshGlyphNames[index] : (index - 258 < custom.count ? custom[index - 258] : "")
        }
        return names.count == count ? names : nil
    }

    /// The character map: format 12 when present, else format 4 (Unicode subtables).
    static func readCMap(_ cmap: FontReader) throws -> [UInt32: Int] {
        var best: (offset: Int, format: Int)?
        for index in 0..<(try cmap.u16(2)) {
            let record = 4 + index * 8
            let platform = try cmap.u16(record), encoding = try cmap.u16(record + 2)
            guard platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10)) else { continue }
            let offset = try cmap.u32(record + 4)
            let format = try cmap.u16(offset)
            if format == 12 || (format == 4 && best?.format != 12) { best = (offset, format) }
        }
        guard let best else { return [:] }
        var map: [UInt32: Int] = [:]
        if best.format == 12 {
            let groups = try cmap.u32(best.offset + 12)
            for group in 0..<groups {
                let at = best.offset + 16 + group * 12
                let start = try cmap.u32(at), end = try cmap.u32(at + 4), glyph = try cmap.u32(at + 8)
                guard end >= start, end - start < 0x11_0000 else { throw FontReadError.malformed("cmap") }
                for code in start...end { map[UInt32(code)] = glyph + (code - start) }
            }
            return map
        }
        let base = best.offset
        let segments = try cmap.u16(base + 6) / 2
        let ends = base + 14, starts = ends + segments * 2 + 2, deltas = starts + segments * 2, ranges = deltas + segments * 2
        for segment in 0..<segments {
            let end = try cmap.u16(ends + segment * 2), start = try cmap.u16(starts + segment * 2)
            let delta = try cmap.u16(deltas + segment * 2), rangeOffset = try cmap.u16(ranges + segment * 2)
            guard start <= end, end != 0xFFFF || start != 0xFFFF else { continue }
            for code in start...end {
                var glyph: Int
                if rangeOffset == 0 {
                    glyph = (code + delta) & 0xFFFF
                } else {
                    let at = ranges + segment * 2 + rangeOffset + (code - start) * 2
                    glyph = try cmap.u16(at)
                    if glyph != 0 { glyph = (glyph + delta) & 0xFFFF }
                }
                if glyph != 0 { map[UInt32(code)] = glyph }
            }
        }
        return map
    }

    /// An old-format `kern` table (version 0, format 0 subtables): pairs.
    static func readKernTable(_ kern: FontReader) throws -> FontSource.Kerning {
        guard try kern.u16(0) == 0 else { return FontSource.Kerning() }
        var pairs: [FontSource.Kerning.Pair] = []
        var offset = 4
        for _ in 0..<(try kern.u16(2)) {
            let length = try kern.u16(offset + 2)
            let coverage = try kern.u16(offset + 4)
            if coverage >> 8 == 0, coverage & 0x01 != 0 {
                let count = try kern.u16(offset + 6)
                for index in 0..<count {
                    let at = offset + 14 + index * 6
                    pairs.append(.init(left: try kern.u16(at), right: try kern.u16(at + 2), value: try kern.i16(at + 4)))
                }
            }
            offset += max(length, 6)
        }
        return FontSource.Kerning(pairs: pairs)
    }
}

/// `glyf`/`loca` outlines.
struct TrueTypeReader {
    var contours: [[Contour]]
    var components: [[ImportedFont.Component]]
    var pointMatched = false

    init(glyf: FontReader, loca: FontReader, longOffsets: Bool, count: Int) throws {
        contours = []
        components = []
        for index in 0..<count {
            let start = longOffsets ? try loca.u32(index * 4) : try loca.u16(index * 2) * 2
            let end = longOffsets ? try loca.u32(index * 4 + 4) : try loca.u16(index * 2 + 2) * 2
            guard end > start else {
                contours.append([])
                components.append([])
                continue
            }
            let glyph = try glyf.sub(start, end - start, context: "glyf")
            let contourCount = try glyph.i16(0)
            if contourCount >= 0 {
                contours.append(try Self.simple(glyph, contours: contourCount))
                components.append([])
            } else {
                contours.append([])
                components.append(try composite(glyph))
            }
        }
    }

    /// A simple glyph's contours, quadratic segments elevated to cubics.
    static func simple(_ glyph: FontReader, contours count: Int) throws -> [Contour] {
        guard count > 0 else { return [] }
        let ends = try (0..<count).map { try glyph.u16(10 + $0 * 2) }
        let points = (ends.last ?? -1) + 1
        var position = 10 + count * 2
        position += 2 + (try glyph.u16(position))
        var flags: [Int] = []
        while flags.count < points {
            let flag = try glyph.u8(position)
            position += 1
            flags.append(flag)
            if flag & 0x08 != 0 {
                let repeats = try glyph.u8(position)
                position += 1
                flags += Array(repeating: flag, count: repeats)
            }
        }
        func coordinates(short: Int, same: Int) throws -> [Double] {
            var value = 0
            var result: [Double] = []
            for flag in flags.prefix(points) {
                if flag & short != 0 {
                    let delta = try glyph.u8(position)
                    position += 1
                    value += flag & same != 0 ? delta : -delta
                } else if flag & same == 0 {
                    value += try glyph.i16(position)
                    position += 2
                }
                result.append(Double(value))
            }
            return result
        }
        let xs = try coordinates(short: 0x02, same: 0x10)
        let ys = try coordinates(short: 0x04, same: 0x20)
        var result: [Contour] = []
        var first = 0
        for end in ends {
            guard end >= first else { continue }
            let range = first...end
            let contour = cubic(range.map { (Point(x: xs[$0], y: ys[$0]), flags[$0] & 0x01 != 0) })
            // A one-point contour (a metrics anchor) draws nothing.
            if !contour.isEmpty { result.append(contour) }
            first = end + 1
        }
        return result
    }

    /// A quadratic TrueType contour (points with on-curve flags) as an exact cubic contour.
    static func cubic(_ points: [(point: Point, on: Bool)]) -> Contour {
        guard !points.isEmpty else { return Contour(segments: [], closed: true) }
        // Start from an on-curve point (the midpoint of the first two when there is none).
        var expanded: [(point: Point, on: Bool)] = []
        for (index, current) in points.enumerated() {
            let next = points[(index + 1) % points.count]
            expanded.append(current)
            if !current.on && !next.on { expanded.append((Point.lerp(current.point, next.point, 0.5), true)) }
        }
        guard let startIndex = expanded.firstIndex(where: \.on) else { return Contour(segments: [], closed: true) }
        let ordered = Array(expanded[startIndex...] + expanded[..<startIndex])
        var segments: [CubicBezier] = []
        var index = 0
        while index < ordered.count {
            let from = ordered[index].point
            let next = ordered[(index + 1) % ordered.count]
            if next.on {
                segments.append(CubicBezier(line: Line(from, next.point)))
                index += 1
            } else {
                let to = ordered[(index + 2) % ordered.count].point
                segments.append(CubicBezier(quadratic: QuadraticBezier(from, next.point, to)))
                index += 2
            }
        }
        return Contour(segments: segments.filter { !($0.p0 == $0.p3 && $0.isLinear()) }, closed: true)
    }

    /// A composite glyph's components (x/y offsets; point matching is placed at the origin).
    mutating func composite(_ glyph: FontReader) throws -> [ImportedFont.Component] {
        var result: [ImportedFont.Component] = []
        var position = 10
        while true {
            let flags = try glyph.u16(position)
            let index = try glyph.u16(position + 2)
            position += 4
            var dx = 0.0, dy = 0.0
            if flags & 0x0001 != 0 {
                dx = Double(try glyph.i16(position)); dy = Double(try glyph.i16(position + 2))
                position += 4
            } else {
                dx = Double(Int8(bitPattern: UInt8(try glyph.u8(position)))); dy = Double(Int8(bitPattern: UInt8(try glyph.u8(position + 1))))
                position += 2
            }
            if flags & 0x0002 == 0 {
                pointMatched = true
                dx = 0
                dy = 0
            }
            func f2dot14(_ at: Int) throws -> Double { Double(try glyph.i16(at)) / 16_384 }
            var a = 1.0, b = 0.0, c = 0.0, d = 1.0
            if flags & 0x0008 != 0 {
                a = try f2dot14(position); d = a
                position += 2
            } else if flags & 0x0040 != 0 {
                a = try f2dot14(position); d = try f2dot14(position + 2)
                position += 4
            } else if flags & 0x0080 != 0 {
                a = try f2dot14(position); b = try f2dot14(position + 2); c = try f2dot14(position + 4); d = try f2dot14(position + 6)
                position += 8
            }
            result.append(ImportedFont.Component(glyph: index, transform: AffineTransform(a: a, b: b, c: c, d: d, tx: dx, ty: dy)))
            if flags & 0x0020 == 0 { return result }
        }
    }
}
