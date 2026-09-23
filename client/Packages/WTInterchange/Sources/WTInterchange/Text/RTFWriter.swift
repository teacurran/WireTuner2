// RTF and plain-text writers (export-text.adoc, "Client"; IO-030).
//
// RTF is written directly rather than through `NSAttributedString`'s RTF writer: that writer emits
// no style sheet (the specification's workaround post-processes one in), drops attachments outside
// RTFD, and writes no tables from `NSTextTable` in plain RTF -- the three things it would have to
// be patched for.  The own writer emits the font and colour tables, a style sheet of the stories'
// paragraph (`\s`) and character (`\cs`) styles, paragraphs with alignment, indents, spacing, line
// spacing, tab stops with alignment and leaders, keep-with-next and hyphenation, runs with font,
// size, bold, italic, colour, underline, strikethrough, super- and subscript, baseline shift,
// horizontal scale, tracking, small caps, all caps and language, tables as `\trowd … \row`, page
// breaks between pages, and inline graphics as `\pict\pngblip`.

import CoreGraphics
import Foundation
import WTRender

/// RTF options (`RtfOptions`).
public struct RTFOptions: ExportOptions, Hashable {
    /// Inline graphics as PNG pictures; off writes a bullet for each.
    public var embedInlineGraphics: Bool

    public init(embedInlineGraphics: Bool = true) {
        self.embedInlineGraphics = embedInlineGraphics
    }

    public static var defaults: RTFOptions { RTFOptions() }
}

/// Plain-text options (`TextOptions`).
public struct PlainTextOptions: ExportOptions, Hashable {
    public enum Encoding: Hashable, Sendable {
        case utf8
        case utf8BOM
        /// UTF-16 little-endian with a byte-order mark.
        case utf16
    }

    public var encoding: Encoding
    /// Windows line endings (CR LF); false writes LF.
    public var crlf: Bool

    public init(encoding: Encoding = .utf8, crlf: Bool = false) {
        self.encoding = encoding
        self.crlf = crlf
    }

    public static var defaults: PlainTextOptions { PlainTextOptions() }
}

enum PlainTextWriter {
    /// The stories as text: paragraphs on their own lines, table cells separated by tabs and rows
    /// by line breaks, stories separated by a blank line, inline graphics as U+2022.
    static func string(_ stories: [(page: Int, story: ExportStory)]) -> String {
        stories.map { item in
            item.story.elements.map { element -> String in
                switch element {
                case .paragraph(let paragraph):
                    return text(paragraph)
                case .table(let table):
                    return table.rows.map { row in
                        row.map { cell in cell.map(text).joined(separator: " ") }.joined(separator: "\t")
                    }.joined(separator: "\n")
                }
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func text(_ paragraph: ExportParagraph) -> String {
        paragraph.text.replacingOccurrences(of: "\u{FFFC}", with: "\u{2022}").replacingOccurrences(of: "\u{2028}", with: "\n")
    }

    static func data(_ stories: [(page: Int, story: ExportStory)], options: PlainTextOptions) -> Data {
        var text = string(stories)
        if options.crlf {
            text = text.replacingOccurrences(of: "\n", with: "\r\n")
        }
        switch options.encoding {
        case .utf8:
            return Data(text.utf8)
        case .utf8BOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .utf16:
            var data = Data([0xFF, 0xFE])
            for unit in text.utf16 {
                data.appendLittleEndian(unit)
            }
            return data
        }
    }
}

final class RTFWriter {
    let options: RTFOptions
    private var fonts: [String] = []
    private var colors: [Color] = []
    private var paragraphStyles: [String] = []
    private var characterStyles: [String] = []
    /// Inline graphics written.
    private(set) var pictures = 0

    init(options: RTFOptions) {
        self.options = options
    }

    // MARK: Tables

    func fontIndex(_ family: String) -> Int {
        if let index = fonts.firstIndex(of: family) {
            return index
        }
        fonts.append(family)
        return fonts.count - 1
    }

    func colorIndex(_ color: Color) -> Int {
        let clipped = ColorMath.sRGBFallback(Color(space: color.space, components: color.components))
        if let index = colors.firstIndex(of: clipped) {
            return index + 1
        }
        colors.append(clipped)
        return colors.count
    }

    /// Paragraph styles are numbered from 1 (`\s0` is Normal); character styles follow them.
    func paragraphStyleIndex(_ name: String) -> Int {
        if let index = paragraphStyles.firstIndex(of: name) {
            return index + 1
        }
        paragraphStyles.append(name)
        return paragraphStyles.count
    }

    func characterStyleIndex(_ name: String) -> Int {
        if let index = characterStyles.firstIndex(of: name) {
            return index + 100
        }
        characterStyles.append(name)
        return characterStyles.count + 99
    }

    // MARK: Document

    func document(_ stories: [(page: Int, story: ExportStory)]) -> String {
        var body = ""
        var previousPage: Int?
        for (index, item) in stories.enumerated() {
            if index > 0 {
                body += previousPage != item.page ? "\\page\n" : "\\pard\\plain\\par\n"
            }
            previousPage = item.page
            for element in item.story.elements {
                switch element {
                case .paragraph(let paragraph):
                    body += self.paragraph(paragraph, inTable: false) + "\\par\n"
                case .table(let table):
                    body += self.table(table)
                }
            }
        }
        var head = "{\\rtf1\\ansi\\ansicpg1252\\deff0\\uc1\n{\\fonttbl"
        for (index, family) in (fonts.isEmpty ? ["Helvetica"] : fonts).enumerated() {
            head += "{\\f\(index)\\fnil\\fcharset0 \(RTFWriter.escape(family));}"
        }
        head += "}\n{\\colortbl;"
        for color in colors {
            head += "\\red\(ColorMath.byte(color.red))\\green\(ColorMath.byte(color.green))\\blue\(ColorMath.byte(color.blue));"
        }
        // Apple's readers take the table as generic RGB unless told: the expanded table says sRGB.
        head += "}\n{\\*\\expandedcolortbl;"
        for color in colors {
            head += "\\cssrgb" + [color.red, color.green, color.blue].map { "\\c\(Int(($0 * 100_000).rounded()))" }.joined() + ";"
        }
        head += "}\n{\\stylesheet{\\s0\\snext0 Normal;}"
        for (index, name) in paragraphStyles.enumerated() {
            head += "{\\s\(index + 1)\\sbasedon0\\snext\(index + 1) \(RTFWriter.escape(name));}"
        }
        for (index, name) in characterStyles.enumerated() {
            head += "{\\*\\cs\(index + 100)\\additive \(RTFWriter.escape(name));}"
        }
        head += "}\n"
        return head + body + "}\n"
    }

    // MARK: Paragraphs

    func paragraphFormat(_ style: ExportParagraphStyle, inTable: Bool) -> String {
        var out = "\\pard\\plain"
        if inTable {
            out += "\\intbl"
        }
        if let name = style.styleName {
            out += "\\s\(paragraphStyleIndex(name))"
        }
        switch style.alignment {
        case .left: out += "\\ql"
        case .center: out += "\\qc"
        case .right: out += "\\qr"
        case .justified: out += "\\qj"
        }
        out += "\\li\(RTFWriter.twips(style.leftIndent))\\ri\(RTFWriter.twips(style.rightIndent))\\fi\(RTFWriter.twips(style.firstLineIndent))"
        out += "\\sb\(RTFWriter.twips(style.spaceBefore))\\sa\(RTFWriter.twips(style.spaceAfter))"
        switch style.lineSpacing {
        case .auto:
            break
        case .multiple(let factor):
            out += "\\sl\(Int((240 * factor).rounded()))\\slmult1"
        case .exactly(let points):
            out += "\\sl-\(RTFWriter.twips(points))\\slmult0"
        }
        for stop in style.tabStops {
            switch stop.alignment {
            case .left: break
            case .center: out += "\\tqc"
            case .right: out += "\\tqr"
            case .decimal: out += "\\tqdec"
            }
            switch stop.leader {
            case .none: break
            case .dots: out += "\\tldot"
            case .hyphens: out += "\\tlhyph"
            case .underline: out += "\\tlul"
            }
            out += "\\tx\(RTFWriter.twips(stop.position))"
        }
        if style.keepWithNext {
            out += "\\keepn"
        }
        if !style.hyphenate {
            out += "\\hyphpar0"
        }
        return out + " "
    }

    func paragraph(_ paragraph: ExportParagraph, inTable: Bool) -> String {
        var out = paragraphFormat(paragraph.style, inTable: inTable)
        for run in paragraph.runs {
            out += self.run(run)
        }
        return out
    }

    func run(_ run: ExportTextRun) -> String {
        let a = run.attributes
        var format = "\\f\(fontIndex(a.fontFamily))\\fs\(Int((a.size * 2).rounded()))"
        if let name = a.styleName {
            format += "\\cs\(characterStyleIndex(name))"
        }
        if a.bold { format += "\\b" }
        if a.italic { format += "\\i" }
        if a.underline { format += "\\ul" }
        if a.strikethrough { format += "\\strike" }
        switch a.script {
        case .none: break
        case .superscript: format += "\\super"
        case .subscript: format += "\\sub"
        }
        if a.baselineShift > 0 {
            format += "\\up\(Int((a.baselineShift * 2).rounded()))"
        } else if a.baselineShift < 0 {
            format += "\\dn\(Int((-a.baselineShift * 2).rounded()))"
        }
        if a.horizontalScale != 1 {
            format += "\\charscalex\(Int((a.horizontalScale * 100).rounded()))"
        }
        if a.tracking != 0 {
            // Thousandths of an em at this size, in twips.
            format += "\\expndtw\(Int((a.tracking / 1000 * a.size * 20).rounded()))"
        }
        if a.smallCaps { format += "\\scaps" }
        if a.allCaps { format += "\\caps" }
        if let language = a.language {
            let code = NSLocale.windowsLocaleCode(fromLocaleIdentifier: language.replacingOccurrences(of: "-", with: "_"))
            if code > 0 {
                format += "\\lang\(code)"
            }
        }
        format += "\\cf\(colorIndex(a.color))"
        guard let graphic = run.graphic else {
            return "{\(format) \(RTFWriter.escape(run.text))}"
        }
        guard options.embedInlineGraphics, let png = ImageEncoding.encode(graphic, type: .png) else {
            return "{\(format) \\u8226?}"
        }
        pictures += 1
        let size = run.graphicSize
        return "{\(format) {\\pict\\pngblip\\picw\(graphic.width)\\pich\(graphic.height)\\picwgoal\(RTFWriter.twips(Double(size.width)))\\pichgoal\(RTFWriter.twips(Double(size.height)))\n\(HexLines.encode(png, bytesPerLine: 64).lowercased())\n}}"
    }

    func table(_ table: ExportTable) -> String {
        var out = ""
        for row in table.rows {
            out += "\\trowd\\trgaph108"
            var right = 0.0
            for width in table.columnWidths {
                right += width
                out += "\\cellx\(RTFWriter.twips(right))"
            }
            out += "\n"
            for cell in row {
                let paragraphs = cell.isEmpty ? [ExportParagraph([])] : cell
                for (index, paragraph) in paragraphs.enumerated() {
                    out += self.paragraph(paragraph, inTable: true)
                    out += index == paragraphs.count - 1 ? "\\cell\n" : "\\par\n"
                }
            }
            out += "\\row\n"
        }
        return out + "\\pard\\plain\n"
    }

    // MARK: Encoding

    static func twips(_ points: Double) -> Int {
        Int((points * 20).rounded())
    }

    /// Text escaped for RTF: `\`, `{`, `}` escaped, tabs as `\tab`, line separators as `\line`,
    /// non-ASCII as `\uN?` (UTF-16, signed).
    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\", "{", "}":
                out += "\\" + String(scalar)
            case "\t":
                out += "\\tab "
            case "\u{2028}", "\n":
                out += "\\line "
            default:
                if scalar.value >= 0x20 && scalar.value < 0x80 {
                    out.unicodeScalars.append(scalar)
                } else if scalar.value >= 0x80 {
                    for unit in String(scalar).utf16 {
                        out += "\\u\(Int(Int16(bitPattern: unit)))?"
                    }
                }
            }
        }
        return out
    }
}

/// Text export for the pasteboard (export-text.adoc, "Copying and dragging text"): the flavours
/// Copy and drag write, built lazily by the app from these bytes.
public enum TextPasteboard {
    /// `public.rtf` and `public.utf8-plain-text` for `blocks`, in export order.
    public static func flavors(_ blocks: [ExportTextBlock], rtf: RTFOptions = RTFOptions()) -> [(type: String, data: Data)] {
        let stories = TextStories.ordered(blocks)
        return [
            ("public.rtf", Data(RTFWriter(options: rtf).document(stories).utf8)),
            ("public.utf8-plain-text", PlainTextWriter.data(stories, options: PlainTextOptions())),
        ]
    }
}
