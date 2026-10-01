// FreeHand text to imported text (import-formats.adoc, "FreeHand"; IO-041).  FreeHand 8 and
// later keep a text block as a TextObject (a frame, or a path for text on a path) whose string
// is a list of paragraphs, each a TextBlok of UTF-16 characters with runs of character
// properties; FreeHand 3 to 7 keep DisplayText records of MacRoman characters.  A frame becomes
// area text of the frame's size and a path text on that path; the character properties become
// runs with family, style, size and colour.  The runs' origins are a simple layout (one line per
// paragraph, 1.2 times the size apart) for the import preview only: WireTuner lays the text out
// again in the block, so wrapping follows the frame.

import CoreText
import Foundation
import WTGeometry
import WTRender

extension FreeHandConverter {
    /// Character property keys (FHConstants.h).
    static let alignmentKey = String(0x15e3)
    static let horizontalScaleKey = String(0x16d4)
    static let kerningKey = String(0x16ec)
    static let baselineShiftKey = String(0x169c)

    /// One styled piece of a paragraph.
    struct TextPiece {
        var text: String
        var family: String
        var style: String
        var size: Double
        var fill: ImportedPaint
    }

    // MARK: TextObject (FreeHand 8 and later)

    mutating func textObject(_ object: FreeHandRecords.TextObject, _ transform: AffineTransform) -> ImportedText? {
        let paragraphs = self.paragraphs(object)
        guard paragraphs.contains(where: { !$0.pieces.isEmpty }) else { return nil }
        let placement = freeHandTransform(object.xform).concatenating(transform)
        if object.path != 0, let path = records.paths[object.path] ?? compositeAsPath(object.path) {
            // Text on a path: the block's space is points, y down, at FreeHand's origin; the path
            // is drawn in it.  The object's own transform is not applied to the path: in the
            // files read so far it scales the text, not the path, which stays where FreeHand
            // draws it (libfreehand places the text by the path alone too).
            let contours = FreeHandConverter.contours(path, freeHandTransform(path.xform).concatenating(FreeHandConverter.symbolSpace))
            guard !contours.isEmpty else { return nil }
            let start = contours[0].start
            var text = layout(paragraphs, origin: start, width: nil)
            text.transform = FreeHandConverter.fromSymbolSpace.concatenating(transform)
            text.path = ImportedPath(contours: contours)
            return text
        }
        // Area text: the frame's top-left corner (startX, startY -- y up, the frame reaching
        // down) is the block's origin, y down.
        let local = AffineTransform(a: 1.0 / 72, b: 0, c: 0, d: -1.0 / 72, tx: object.startX, ty: object.startY)
        let columns = max(object.colNum, 1)
        let rows = max(object.rowNum, 1)
        if columns > 1 || rows > 1 { notes.textColumns += 1 }
        let width = object.width > 0 ? (object.width * Double(columns) + object.colSep * Double(columns - 1)) * 72 : nil
        let height = object.height > 0 ? (object.height * Double(rows) + object.rowSep * Double(rows - 1)) * 72 : nil
        var text = layout(paragraphs, origin: .zero, width: width)
        text.transform = local.concatenating(placement)
        if let width, let height { text.frame = Size(width: width, height: height) }
        return text
    }

    /// The first path of composite `id`, for text on a composite path.
    func compositeAsPath(_ id: Int) -> FreeHandRecords.Path? {
        records.compositePaths[id].flatMap { compositeParts($0).first }
    }

    /// The object's paragraphs in its [beginPos, endPos) range of the string (a linked frame
    /// shows part of it), each with its alignment.
    func paragraphs(_ object: FreeHandRecords.TextObject) -> [(pieces: [TextPiece], alignment: ImportedTextAlignment)] {
        var result: [(pieces: [TextPiece], alignment: ImportedTextAlignment)] = []
        var position = 0
        let begin = object.beginPos
        let end = object.endPos > 0 ? object.endPos : Int.max
        for id in records.tStrings[object.tString] ?? [] {
            guard position < end, let paragraph = records.paragraphs[id] else {
                position += 1
                continue
            }
            let characters = records.textBloks[paragraph.textBlok] ?? []
            var pieces: [TextPiece] = []
            let runs = paragraph.charStyles.filter { $0.count == 2 }
            for (index, run) in runs.enumerated() {
                let first = max(run[0], 0)
                let last = min(index + 1 < runs.count ? runs[index + 1][0] : characters.count, characters.count)
                guard first < last else { continue }
                let lower = max(first, begin - position)
                let upper = min(last, end - position)
                guard lower < upper else { continue }
                let text = FreeHandConverter.clean(Array(characters[lower..<upper]))
                guard !text.isEmpty else { continue }
                pieces.append(piece(text, charProperties: run[1]))
            }
            position += characters.count + 1
            if position <= begin { continue }
            let ints = records.paragraphProperties[paragraph.paraStyle]?.ints ?? [:]
            result.append((pieces, FreeHandConverter.alignment(ints[FreeHandConverter.alignmentKey] ?? 0)))
        }
        return result
    }

    /// FreeHand's alignment code.
    static func alignment(_ code: Int) -> ImportedTextAlignment {
        switch code {
        case 1: return .right
        case 2: return .center
        case 3: return .justify
        default: return .left
        }
    }

    /// UTF-16 characters without FreeHand's control codes (end of column, optional hyphen and
    /// the rest below a space); tabs stay.
    static func clean(_ units: [UInt16]) -> String {
        let kept = units.filter { $0 >= 0x20 || $0 == 0x09 }
        return String(decoding: kept, as: UTF16.self)
    }

    /// A piece in character properties `id`: the AGD font's name, style and size win over the
    /// properties' own (libfreehand's order).
    func piece(_ text: String, charProperties id: Int) -> TextPiece {
        let properties = records.charProperties[id]
        var family = properties.flatMap { records.strings[$0.fontName] } ?? ""
        var size = properties?.fontSize ?? 12
        var bold = false
        var italic = false
        if let font = properties.flatMap({ records.fonts[$0.font] }) {
            if let name = records.strings[font.name], !name.isEmpty { family = name }
            if font.size > 0 { size = font.size }
            bold = font.style & 1 != 0
            italic = font.style & 2 != 0
        }
        let fill = properties.flatMap { records.basicFills[$0.textColor] }.flatMap(colorPaint) ?? .solid(.black)
        return TextPiece(text: text, family: family.isEmpty ? "Helvetica" : family, style: FreeHandConverter.styleName(bold: bold, italic: italic),
                         size: size > 0 ? size : 12, fill: fill)
    }

    /// "Bold", "Italic", "Bold Italic" or "" for Regular.
    static func styleName(bold: Bool, italic: Bool) -> String {
        switch (bold, italic) {
        case (true, true): return "Bold Italic"
        case (true, false): return "Bold"
        case (false, true): return "Italic"
        case (false, false): return ""
        }
    }

    /// The paragraphs (at least one) as runs, one baseline per paragraph from `origin`; with a
    /// `width`, lines are aligned inside it for the preview.
    func layout(_ paragraphs: [(pieces: [TextPiece], alignment: ImportedTextAlignment)], origin: Point, width: Double?) -> ImportedText {
        var runs: [ImportedTextRun] = []
        var baseline = origin.y
        for (index, paragraph) in paragraphs.enumerated() {
            let size = paragraph.pieces.map(\.size).max() ?? runs.last?.fontSize ?? 12
            baseline += index == 0 ? size : size * 1.2
            if paragraph.pieces.isEmpty {
                // An empty paragraph still ends a line.
                runs.append(ImportedTextRun(text: "", fontName: runs.last?.fontName ?? "Helvetica", fontSize: size, origin: Point(x: origin.x, y: baseline)))
                continue
            }
            let fonts = paragraph.pieces.map { FreeHandConverter.postScriptName(family: $0.family, style: $0.style) }
            let widths = zip(paragraph.pieces, fonts).map { FreeHandConverter.advance($0.text, font: $1, size: $0.size) }
            let lineWidth = widths.reduce(0, +)
            var x = origin.x
            if let width {
                switch paragraph.alignment {
                case .right: x += max(width - lineWidth, 0)
                case .center: x += max(width - lineWidth, 0) / 2
                case .left, .justify: break
                }
            }
            for ((piece, font), advance) in zip(zip(paragraph.pieces, fonts), widths) {
                runs.append(ImportedTextRun(text: piece.text, fontName: font, fontSize: piece.size, fill: piece.fill, origin: Point(x: x, y: baseline),
                                            family: piece.family, style: piece.style))
                x += advance
            }
        }
        return ImportedText(runs: runs, alignment: paragraphs[0].alignment)
    }

    /// The PostScript name of the installed font of `family` and `style`, else the family.
    static func postScriptName(family: String, style: String) -> String {
        let attributes: [CFString: Any] = style.isEmpty
            ? [kCTFontFamilyNameAttribute: family]
            : [kCTFontFamilyNameAttribute: family, kCTFontStyleNameAttribute: style]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        let matched = CTFontCopyFamilyName(font) as String
        return matched == family ? CTFontCopyPostScriptName(font) as String : family
    }

    /// The width of `text` in `font` at `size`.
    static func advance(_ text: String, font: String, size: Double) -> Double {
        let characters = Array(text.utf16)
        let ctFont = CTFontCreateWithName(font as CFString, size, nil)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, characters.count)
        return CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, nil, glyphs.count)
    }

    // MARK: DisplayText (FreeHand 3 to 7)

    mutating func displayText(_ text: FreeHandRecords.DisplayText, _ transform: AffineTransform) -> ImportedText? {
        let bytes = [UInt8](text.characters.data)
        guard !bytes.isEmpty else { return nil }
        let properties = text.charProps.sorted { $0.offset < $1.offset }
        var paragraphs: [(pieces: [TextPiece], alignment: ImportedTextAlignment)] = [([], FreeHandConverter.displayAlignment(text.justify))]
        var index = 0
        while index < bytes.count {
            // The run of characters up to the next property change or line end.
            let active = properties.last { $0.offset <= index }
            let nextChange = properties.first { $0.offset > index }?.offset ?? bytes.count
            var end = index
            while end < nextChange, bytes[end] != 0x0d, bytes[end] != 0x0a { end += 1 }
            if end > index {
                let string = FreeHandConverter.macRoman(Array(bytes[index..<end]))
                if !string.isEmpty {
                    paragraphs[paragraphs.count - 1].pieces.append(displayPiece(string, active))
                }
            }
            if end < bytes.count, bytes[end] == 0x0d || bytes[end] == 0x0a {
                paragraphs.append(([], paragraphs[0].alignment))
                end += 1
            }
            index = max(end, index + 1)
        }
        if paragraphs.last?.pieces.isEmpty == true, paragraphs.count > 1 { paragraphs.removeLast() }
        guard paragraphs.contains(where: { !$0.pieces.isEmpty }) else { return nil }
        let local = AffineTransform(a: 1.0 / 72, b: 0, c: 0, d: -1.0 / 72, tx: text.startX, ty: text.startY)
        let width = text.width > 0 ? text.width * 72 : nil
        var result = layout(paragraphs, origin: .zero, width: width)
        result.transform = local.concatenating(freeHandTransform(text.xform)).concatenating(transform)
        if let width, text.height > 0 { result.frame = Size(width: width, height: text.height * 72) }
        return result
    }

    /// FreeHand 3 to 7's justification code.
    static func displayAlignment(_ code: Int) -> ImportedTextAlignment {
        switch code {
        case 1: return .center
        case 2: return .right
        case 3: return .justify
        default: return .left
        }
    }

    func displayPiece(_ text: String, _ properties: FreeHandRecords.DisplayCharProps?) -> TextPiece {
        let family = properties.flatMap { records.strings[$0.fontName] }.flatMap { $0.isEmpty ? nil : $0 } ?? "Helvetica"
        let style = properties.map { FreeHandConverter.styleName(bold: $0.fontStyle & 1 != 0, italic: $0.fontStyle & 2 != 0) } ?? ""
        let fill = properties.flatMap { colorPaint($0.fontColor) } ?? .solid(.black)
        let size = properties.map(\.fontSize).flatMap { $0 > 0 ? $0 : nil } ?? 12
        return TextPiece(text: text, family: family, style: style, size: size, fill: fill)
    }

    /// MacRoman bytes as a string, control codes other than tab dropped.
    static func macRoman(_ bytes: [UInt8]) -> String {
        let kept = bytes.filter { $0 >= 0x20 || $0 == 0x09 }
        // Every byte has a MacRoman character, so the decoding cannot fail.
        return String(data: Data(kept), encoding: .macOSRoman)!
    }
}
