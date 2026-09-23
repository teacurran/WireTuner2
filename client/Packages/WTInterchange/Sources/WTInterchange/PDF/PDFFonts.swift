// Fonts in PDF output (export-pdf.adoc, "Fonts").  Every glyph run is shown with a font resource
// and a `ToUnicode` map, so text stays selectable and searchable:
//
// * TrueType fonts become a Type 0 font over a `CIDFontType2` whose program is a TrueType subset
//   (`FontFile2`) addressed through `Identity-H` with `CIDToGIDMap /Identity`: two-byte codes are
//   the glyph ids.  *Complete* embeds every glyph of the font.
// * Fonts with CFF outlines, and variable-font instances, have no subsetter here: their glyphs
//   are embedded as Type 3 procedures holding the instance's outlines (up to 256 glyphs per font
//   resource), where the specification asks for CFF subsets -- the deviation recorded on
//   export-pdf.adoc.
// * A font whose license forbids embedding, or every font under *Convert text to outlines*, is
//   drawn as paths by the page writer and reported.

import CoreGraphics
import CoreText
import Foundation
import WTGeometry
import WTRender

/// The fonts of one PDF file, shared by its pages.
final class PDFFontRegistry {
    enum Kind {
        case trueType
        case type3
    }

    /// One font program and the glyphs used from it.
    final class Font {
        let key: String
        let kind: Kind
        /// A 1000-point instance of the font without horizontal scale: widths and Type 3 outlines.
        let unit: CTFont
        let facts: FontFacts
        /// The font dictionary's object number per resource (Type 3 splits every 256 glyphs).
        var objects: [Int] = []
        /// Resource names, parallel to `objects`.
        var names: [String] = []
        /// Glyphs in first-use order.
        var glyphs: [CGGlyph] = []
        var codes: [CGGlyph: Int] = [:]
        var unicode: [CGGlyph: String] = [:]

        init(key: String, kind: Kind, unit: CTFont) {
            self.key = key
            self.kind = kind
            self.unit = unit
            facts = FontFacts(unit)
        }
    }

    let objects: PDFObjects
    let embedAll: Bool
    private(set) var fonts: [String: Font] = [:]
    private var order: [String] = []
    private var resourceCounter = 0
    /// Fonts drawn as outlines because their license forbids embedding.
    private(set) var restricted = Set<String>()

    init(objects: PDFObjects, embedAll: Bool) {
        self.objects = objects
        self.embedAll = embedAll
    }

    /// How the glyphs of `font` are written: nil when they must be drawn as paths.
    func font(for glyphFont: GlyphFont) -> Font? {
        let key = glyphFont.postScriptName + glyphFont.variations.sorted { $0.key < $1.key }.map { "|\($0.key)=\($0.value)" }.joined()
        if let font = fonts[key] {
            return font
        }
        if restricted.contains(key) {
            return nil
        }
        let unit = GlyphFont(postScriptName: glyphFont.postScriptName, size: 1000, variations: glyphFont.variations).ctFont
        guard FontFacts(unit).embeddable else {
            restricted.insert(key)
            return nil
        }
        let kind: Kind = glyphFont.variations.isEmpty && FontProgram.table("glyf", of: unit) != nil ? .trueType : .type3
        let font = Font(key: key, kind: kind, unit: unit)
        fonts[key] = font
        order.append(key)
        return font
    }

    /// The resource name and code bytes showing `glyph` of `font`, recording its text.
    func use(_ glyph: CGGlyph, of font: Font, text: String?) -> (name: String, object: Int, code: String) {
        if font.codes[glyph] == nil {
            font.codes[glyph] = font.glyphs.count
            font.glyphs.append(glyph)
        }
        if let text, font.unicode[glyph] == nil, !text.isEmpty {
            font.unicode[glyph] = text
        }
        let code = font.codes[glyph]!
        let resource: Int
        let bytes: String
        switch font.kind {
        case .trueType:
            resource = 0
            bytes = String(format: "%04X", glyph)
        case .type3:
            resource = code / 256
            bytes = String(format: "%02X", code % 256)
        }
        while font.objects.count <= resource {
            resourceCounter += 1
            font.objects.append(objects.reserve())
            font.names.append("F\(resourceCounter)")
        }
        return (font.names[resource], font.objects[resource], bytes)
    }

    /// The glyph-to-text mapping of a run: one character per glyph when the counts match,
    /// otherwise the whole text on the first glyph (the rest map to nothing).
    static func unicodeMapping(glyphs: [CGGlyph], text: String) -> [String?] {
        let scalars = Array(text.unicodeScalars)
        if scalars.count == glyphs.count {
            return scalars.map { String($0) }
        }
        return glyphs.indices.map { $0 == 0 ? text : nil }
    }

    // MARK: Writing

    /// Writes every font's objects.
    func finish() {
        for key in order {
            let font = fonts[key]!
            switch font.kind {
            case .trueType: writeTrueType(font)
            case .type3: writeType3(font)
            }
        }
    }

    /// Six capital letters naming a subset, derived from the glyphs so identical subsets agree.
    static func subsetTag(_ glyphs: [CGGlyph]) -> String {
        var hash: UInt64 = 1469598103934665603
        for glyph in glyphs.sorted() {
            hash = (hash ^ UInt64(glyph)) &* 1099511628211
        }
        return String((0..<6).map { index in Character(UnicodeScalar(65 + UInt8((hash >> (UInt64(index) * 5)) % 26))) })
    }

    /// The advance of `glyph` in glyph space (thousandths of the size).
    func width(of glyph: CGGlyph, in font: Font) -> Double {
        advances(of: [glyph], in: font.unit)[0]
    }

    func advances(of glyphs: [CGGlyph], in font: CTFont) -> [Double] {
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        return advances.map { Double($0.width) }
    }

    /// Fonts are flagged symbolic: their glyphs are addressed by id, not a standard encoding.
    func descriptor(_ font: Font, name: String, fontFile: (String, Int)?) -> Int {
        let unit = font.unit
        let box = CTFontGetBoundingBox(unit)
        var flags = 4
        if font.facts.italic {
            flags |= 64
        }
        var entries: [(String, PDFValue)] = [
            ("Type", .name("FontDescriptor")),
            ("FontName", .name(name)),
            ("Flags", .int(flags)),
            ("FontBBox", .rect(Double(box.minX), Double(box.minY), Double(box.maxX), Double(box.maxY))),
            ("ItalicAngle", .real(Double(CTFontGetSlantAngle(unit)))),
            ("Ascent", .real(Double(CTFontGetAscent(unit)))),
            ("Descent", .real(-Double(CTFontGetDescent(unit)))),
            ("CapHeight", .real(Double(CTFontGetCapHeight(unit)))),
            ("StemV", .int(font.facts.bold ? 120 : 80)),
        ]
        if let fontFile {
            entries.append((fontFile.0, .reference(fontFile.1)))
        }
        return objects.add(.dictionary(entries))
    }

    func writeTrueType(_ font: Font) {
        let all = embedAll ? Set((0..<CGGlyph(CTFontGetGlyphCount(font.unit))).map { $0 }) : Set(font.glyphs)
        // A font with a glyf table always subsets.
        let program = FontProgram.trueTypeSubset(of: font.unit, glyphs: all)!
        let file = objects.addStream([("Length1", .int(program.count))], data: program)
        let name = (embedAll ? "" : PDFFontRegistry.subsetTag(font.glyphs) + "+") + font.facts.postScriptName
        let descriptor = descriptor(font, name: name, fontFile: ("FontFile2", file))
        let sorted = font.glyphs.sorted()
        let widths = advances(of: sorted, in: font.unit)
        var widthArray: [PDFValue] = []
        for (glyph, width) in zip(sorted, widths) {
            widthArray += [.int(Int(glyph)), .array([.real(width)])]
        }
        let cid = objects.add(.dictionary([
            ("Type", .name("Font")),
            ("Subtype", .name("CIDFontType2")),
            ("BaseFont", .name(name)),
            ("CIDSystemInfo", .dictionary([("Registry", .string("Adobe")), ("Ordering", .string("Identity")), ("Supplement", .int(0))])),
            ("FontDescriptor", .reference(descriptor)),
            ("W", .array(widthArray)),
            ("CIDToGIDMap", .name("Identity")),
        ]))
        let toUnicode = objects.addStream([], data: PDFFontRegistry.cmap(font.glyphs.map { (Int($0), font.unicode[$0]) }, codeBytes: 2))
        objects.set(font.objects[0], .dictionary([
            ("Type", .name("Font")),
            ("Subtype", .name("Type0")),
            ("BaseFont", .name(name)),
            ("Encoding", .name("Identity-H")),
            ("DescendantFonts", .array([.reference(cid)])),
            ("ToUnicode", .reference(toUnicode)),
        ]))
    }

    func writeType3(_ font: Font) {
        for (resource, object) in font.objects.enumerated() {
            let glyphs = Array(font.glyphs[(resource * 256)..<min(font.glyphs.count, resource * 256 + 256)])
            let widths = advances(of: glyphs, in: font.unit)
            var procs: [(String, PDFValue)] = []
            var box = Rect.null
            for (glyph, width) in zip(glyphs, widths) {
                var content = PDFContent()
                var flip = CGAffineTransform.identity
                let outline = CTFontCreatePathForGlyph(font.unit, glyph, &flip).map { DisplayPath(cgPathElements: $0) } ?? DisplayPath()
                let bounds = outline.controlBounds ?? Rect.zero
                box = box.union(bounds)
                content.op("\(PDFValue.number(width)) 0 \(PDFValue.number(bounds.minX)) \(PDFValue.number(bounds.minY)) \(PDFValue.number(bounds.maxX)) \(PDFValue.number(bounds.maxY)) d1")
                if !outline.isEmpty {
                    content.path(outline)
                    content.op("f")
                }
                procs.append(("g\(glyph)", .reference(objects.addStream([], data: content.data))))
            }
            let differences: [PDFValue] = [.int(0)] + glyphs.map { .name("g\($0)") }
            let toUnicode = objects.addStream([], data: PDFFontRegistry.cmap(glyphs.enumerated().map { ($0.offset, font.unicode[$0.element]) }, codeBytes: 1))
            objects.set(object, .dictionary([
                ("Type", .name("Font")),
                ("Subtype", .name("Type3")),
                ("Name", .name(font.names[resource])),
                ("FontBBox", .rect(box.minX, box.minY, box.maxX, box.maxY)),
                ("FontMatrix", .numbers([0.001, 0, 0, 0.001, 0, 0])),
                ("CharProcs", .dictionary(procs)),
                ("Encoding", .dictionary([("Type", .name("Encoding")), ("Differences", .array(differences))])),
                ("FirstChar", .int(0)),
                ("LastChar", .int(glyphs.count - 1)),
                ("Widths", .numbers(widths)),
                ("FontDescriptor", .reference(descriptor(font, name: font.facts.postScriptName, fontFile: nil))),
                ("Resources", .dictionary([])),
                ("ToUnicode", .reference(toUnicode)),
            ]))
        }
    }

    /// A `ToUnicode` CMap from codes to text (codes without text are left out).
    static func cmap(_ mappings: [(code: Int, text: String?)], codeBytes: Int) -> Data {
        let format = codeBytes == 2 ? "%04X" : "%02X"
        var lines = [
            "/CIDInit /ProcSet findresource begin", "12 dict begin", "begincmap",
            "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def",
            "/CMapName /Adobe-Identity-UCS def", "/CMapType 2 def",
            "1 begincodespacerange", "<\(String(format: format, 0))> <\(String(format: format, codeBytes == 2 ? 0xFFFF : 0xFF))>", "endcodespacerange",
        ]
        let known = mappings.compactMap { mapping in mapping.text.map { (mapping.code, $0) } }
        for start in stride(from: 0, to: known.count, by: 100) {
            let chunk = known[start..<min(start + 100, known.count)]
            lines.append("\(chunk.count) beginbfchar")
            for (code, text) in chunk {
                let units = text.utf16.map { String(format: "%04X", $0) }.joined()
                lines.append("<\(String(format: format, code))> <\(units)>")
            }
            lines.append("endbfchar")
        }
        lines += ["endcmap", "CMapName currentdict /CMap defineresource pop", "end", "end"]
        return Data(lines.joined(separator: "\n").utf8)
    }
}

extension DisplayPath {
    /// The elements of a Core Graphics path (y up, as Core Text returns glyph outlines).
    init(cgPathElements path: CGPath) {
        var elements: [Element] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            func point(_ index: Int) -> Point {
                Point(x: Double(points[index].x), y: Double(points[index].y))
            }
            switch element.type {
            case .moveToPoint: elements.append(.move(to: point(0)))
            case .addLineToPoint: elements.append(.line(to: point(0)))
            case .addQuadCurveToPoint: elements.append(.quadCurve(control: point(0), end: point(1)))
            case .addCurveToPoint: elements.append(.cubicCurve(control1: point(0), control2: point(1), end: point(2)))
            default: elements.append(.close)
            }
        }
        self.init(elements: elements)
    }
}
