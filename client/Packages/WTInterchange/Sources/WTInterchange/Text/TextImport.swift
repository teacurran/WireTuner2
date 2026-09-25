// Text file import (type/importing-text.adoc; TYPE-008): Rich Text (RTF, RTFD), plain text and
// Markdown read into the neutral story the RTF export writes from (`ExportParagraph`, `ExportTextRun`,
// `ExportTextAttributes`, `ExportParagraphStyle`), so the one mapping between those and the
// document's marks and paragraph registers (WTModel's `TextAttributeMapping`) serves both ways.
//
// RTF and RTFD go through `NSAttributedString`'s document readers.  Those drop what the export writes
// beyond them -- paragraph and character style names (`\s`, `\cs` and the style sheet), small and
// all capitals (`\scaps`, `\caps`), horizontal scale, tab leaders, right indents, keep-with-next and "don't hyphenate" -- so a light
// scan of the RTF recovers them and lays them over the attributed string character for character.
// Plain text is decoded as UTF-8 unless it carries a byte-order mark or is not valid UTF-8, when
// Foundation's detector guesses among the legacy encodings (Windows-1252 first, then Mac Roman,
// Shift-JIS, Latin-1); the guess is reported for the import summary.  Markdown is plain text.

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import CoreGraphics
import Foundation
import WTRender

/// The formats the text importer reads.
public enum TextFileFormat: String, Hashable, Sendable, CaseIterable {
    case rtf
    case rtfd
    case plain
    case markdown

    /// The format of a file with extension `pathExtension` (case ignored); nil for another kind.
    public init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "rtf": self = .rtf
        case "rtfd": self = .rtfd
        case "txt", "text": self = .plain
        case "md", "markdown": self = .markdown
        default: return nil
        }
    }

    /// Plain text and Markdown carry no formatting.
    public var isPlain: Bool { self == .plain || self == .markdown }
}

/// The Import dialog's options for text.
public struct TextImportOptions: Hashable, Sendable {
    /// The *Encoding* pop-up: nil detects; a value decodes plain text with it.
    public var encoding: String.Encoding?

    public init(encoding: String.Encoding? = nil) {
        self.encoding = encoding
    }
}

/// Why a text file could not be read.
public enum TextImportError: Error, Hashable, Sendable {
    /// The bytes are not a readable document of the format.
    case unreadable(TextFileFormat)
    /// The bytes do not decode in the chosen encoding.
    case undecodable(String.Encoding)
}

/// A text file as read: its paragraphs, what is used for the import summary, and the pictures an
/// RTFD holds (their runs are U+FFFC with `graphic` set).
public struct ImportedTextFile: @unchecked Sendable {
    public var paragraphs: [ExportParagraph]
    /// Plain text and Markdown: the runs carry no formatting and take the document's defaults.
    public var plain: Bool
    /// The encoding plain text was decoded with; nil for rich text.
    public var encoding: String.Encoding?
    /// The notes of the import summary (the new block's Object panel notes).
    public var notes: [String]
    /// Each inline picture's encoded bytes and UTI, by the offset of its U+FFFC in the whole text.
    public var pictures: [Int: (data: Data, uti: String)]

    public init(paragraphs: [ExportParagraph], plain: Bool, encoding: String.Encoding? = nil, notes: [String] = [],
                pictures: [Int: (data: Data, uti: String)] = [:]) {
        self.paragraphs = paragraphs
        self.plain = plain
        self.encoding = encoding
        self.notes = notes
        self.pictures = pictures
    }

    /// The whole text, paragraphs joined by U+000A.
    public var string: String {
        paragraphs.map(\.text).joined(separator: "\n")
    }
}

/// Reading text files.
public enum TextImporter {
    /// Reads the file at `url` (an RTFD is a package directory).
    public static func read(url: URL, options: TextImportOptions = TextImportOptions()) throws -> ImportedTextFile {
        guard let format = TextFileFormat(pathExtension: url.pathExtension) else { throw TextImportError.unreadable(.plain) }
        if format == .rtfd {
            let wrapper = try FileWrapper(url: url, options: .immediate)
            guard let attributed = PlatformText.rtfd(wrapper, url: url) else { throw TextImportError.unreadable(.rtfd) }
            let rtf = wrapper.fileWrappers?["TXT.rtf"]?.regularFileContents
            return rich(attributed, rtf: rtf, format: .rtfd)
        }
        return try read(try Data(contentsOf: url), format: format, options: options)
    }

    /// Reads `data` as `format` (an RTFD as its flattened serialization).
    public static func read(_ data: Data, format: TextFileFormat, options: TextImportOptions = TextImportOptions()) throws -> ImportedTextFile {
        switch format {
        case .plain, .markdown:
            let decoded = try decode(data, encoding: options.encoding)
            var notes: [String] = []
            if decoded.guessed { notes.append("Encoding: \(String.localizedName(of: decoded.encoding)) (detected)") }
            return ImportedTextFile(paragraphs: paragraphs(plain: decoded.string), plain: true, encoding: decoded.encoding, notes: notes)
        case .rtf, .rtfd:
            let type: NSAttributedString.DocumentType = format == .rtf ? .rtf : .rtfd
            guard let attributed = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil) else {
                throw TextImportError.unreadable(format)
            }
            return rich(attributed, rtf: format == .rtf ? data : nil, format: format)
        }
    }

    // MARK: Plain text

    /// Decodes plain text: a byte-order mark's encoding, else UTF-8 when valid, else the detector's
    /// guess (`guessed`); `encoding` forces one.
    public static func decode(_ data: Data, encoding: String.Encoding? = nil) throws -> (string: String, encoding: String.Encoding, guessed: Bool) {
        if let encoding {
            guard let string = String(data: data, encoding: encoding) else { throw TextImportError.undecodable(encoding) }
            return (strippingBOM(string), encoding, false)
        }
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), let string = String(data: data.dropFirst(3), encoding: .utf8) {
            return (string, .utf8, false)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]), let string = String(data: data, encoding: .utf16) {
            return (strippingBOM(string), .utf16, false)
        }
        if let string = String(data: data, encoding: .utf8) {
            return (string, .utf8, false)
        }
        var converted: NSString?
        var lossy: ObjCBool = false
        let suggestions: [String.Encoding] = [.windowsCP1252, .macOSRoman, .shiftJIS, .isoLatin1]
        let raw = NSString.stringEncoding(for: data, encodingOptions: [.suggestedEncodingsKey: suggestions.map(\.rawValue), .allowLossyKey: false],
                                          convertedString: &converted, usedLossyConversion: &lossy)
        guard raw != 0, let converted else {
            // Every byte means something in Latin-1.
            return (String(decoding: data.map { UInt16($0) }, as: UTF16.self), .isoLatin1, true)
        }
        return (converted as String, String.Encoding(rawValue: raw), true)
    }

    static func strippingBOM(_ string: String) -> String {
        string.hasPrefix("\u{FEFF}") ? String(string.dropFirst()) : string
    }

    /// Plain paragraphs: CR LF and lone CR read as line feeds.
    static func paragraphs(plain string: String) -> [ExportParagraph] {
        let normalized = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n").map { ExportParagraph($0.isEmpty ? [] : [ExportTextRun($0)]) }
    }

    // MARK: Rich text

    /// The story of an attributed string, with what `rtf`'s scan recovers laid over it.
    static func rich(_ attributed: NSAttributedString, rtf: Data?, format: TextFileFormat) -> ImportedTextFile {
        let string = attributed.string as NSString
        var scan = rtf.flatMap { RTFScan($0) }
        var notes: [String] = []
        if let current = scan, current.length != string.length {
            notes.append("Style names, small caps and tab leaders could not be matched to the text")
            scan = nil
        }
        // Paragraph ranges without their U+000A; a final paragraph mark ends the last paragraph.
        var ranges: [NSRange] = []
        var start = 0
        for index in 0..<string.length where string.character(at: index) == 0x0A {
            ranges.append(NSRange(location: start, length: index - start))
            start = index + 1
        }
        if start < string.length || ranges.isEmpty { ranges.append(NSRange(location: start, length: string.length - start)) }
        var paragraphs: [ExportParagraph] = []
        var pictures: [Int: (data: Data, uti: String)] = [:]
        var scalarStart = 0
        for (index, range) in ranges.enumerated() {
            var style = ExportParagraphStyle()
            let probe = min(range.location, max(string.length - 1, 0))
            if string.length > 0, let paragraph = attributed.attribute(.paragraphStyle, at: probe, effectiveRange: nil) as? NSParagraphStyle {
                style = paragraphStyle(paragraph)
            }
            var runs: [ExportTextRun] = []
            attributed.enumerateAttributes(in: range) { attrs, runRange, _ in
                let text = string.substring(with: runRange)
                var attributes = characterAttributes(attrs)
                if let scan {
                    attributes.smallCaps = scan.smallCaps(at: runRange.location)
                    attributes.allCaps = scan.allCaps(at: runRange.location)
                    attributes.styleName = scan.characterStyle(at: runRange.location)
                    attributes.horizontalScale = scan.horizontalScale(at: runRange.location) ?? attributes.horizontalScale
                }
                if let attachment = attrs[.attachment] as? NSTextAttachment, text == "\u{FFFC}", let picture = picture(attachment) {
                    let offset = scalarStart + string.substring(with: NSRange(location: range.location, length: runRange.location - range.location)).unicodeScalars.count
                    pictures[offset] = (picture.data, picture.uti)
                    if let image = picture.image {
                        runs.append(ExportTextRun(graphic: image, size: picture.size, attributes: attributes))
                        return
                    }
                }
                runs.append(contentsOf: split(text, at: runRange.location, attributes: attributes, scan: scan))
            }
            scan?.apply(to: &style, paragraph: index)
            paragraphs.append(ExportParagraph(runs, style: style))
            scalarStart += string.substring(with: range).unicodeScalars.count + 1
        }
        if !pictures.isEmpty { notes.append("\(pictures.count) picture\(pictures.count == 1 ? "" : "s") placed as inline graphics") }
        return ImportedTextFile(paragraphs: paragraphs, plain: false, notes: notes, pictures: pictures)
    }

    /// `text` (starting at UTF-16 offset `location`) cut where the scan's small caps, all caps or
    /// character style change.
    static func split(_ text: String, at location: Int, attributes: ExportTextAttributes, scan: RTFScan?) -> [ExportTextRun] {
        guard let scan else { return [ExportTextRun(text, attributes: attributes)] }
        var runs: [ExportTextRun] = []
        var current = ""
        var currentAttributes = attributes
        var utf16 = location
        for character in text {
            var next = attributes
            next.smallCaps = scan.smallCaps(at: utf16)
            next.allCaps = scan.allCaps(at: utf16)
            next.styleName = scan.characterStyle(at: utf16)
            next.horizontalScale = scan.horizontalScale(at: utf16) ?? attributes.horizontalScale
            if next != currentAttributes, !current.isEmpty {
                runs.append(ExportTextRun(current, attributes: currentAttributes))
                current = ""
            }
            currentAttributes = next
            current.append(character)
            utf16 += character.utf16.count
        }
        if !current.isEmpty { runs.append(ExportTextRun(current, attributes: currentAttributes)) }
        return runs
    }

    /// The character attributes of one attributed run.
    static func characterAttributes(_ attrs: [NSAttributedString.Key: Any]) -> ExportTextAttributes {
        var result = ExportTextAttributes()
        if let font = PlatformText.font(attrs) {
            result.fontFamily = font.family
            result.size = font.size
            result.bold = font.bold
            result.italic = font.italic
            result.fontFace = font.face
        }
        if let color = PlatformText.sRGBForeground(attrs) {
            result.color = Color(red: color.red, green: color.green, blue: color.blue)
        }
        result.underline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
        result.strikethrough = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
        let superscript = (attrs[PlatformText.superscriptKey] as? Int) ?? 0
        result.script = superscript > 0 ? .superscript : superscript < 0 ? .subscript : .none
        result.baselineShift = (attrs[.baselineOffset] as? Double) ?? Double((attrs[.baselineOffset] as? CGFloat) ?? 0)
        if let kern = attrs[.kern] as? Double, result.size > 0 {
            result.tracking = (kern / result.size * 1000).rounded()
        }
        if let expansion = attrs[.expansion] as? Double {
            result.horizontalScale = (exp(expansion) * 100).rounded() / 100
        }
        return result
    }

    /// The paragraph attributes of an `NSParagraphStyle`.
    static func paragraphStyle(_ style: NSParagraphStyle) -> ExportParagraphStyle {
        var result = ExportParagraphStyle()
        switch style.alignment {
        case .center: result.alignment = .center
        case .right: result.alignment = .right
        case .justified: result.alignment = .justified
        default: result.alignment = .left
        }
        result.leftIndent = Double(style.headIndent)
        result.firstLineIndent = Double(style.firstLineHeadIndent - style.headIndent)
        result.rightIndent = style.tailIndent < 0 ? Double(-style.tailIndent) : 0
        result.spaceBefore = Double(style.paragraphSpacingBefore)
        result.spaceAfter = Double(style.paragraphSpacing)
        if style.lineHeightMultiple > 0 {
            result.lineSpacing = .multiple((Double(style.lineHeightMultiple) * 100).rounded() / 100)
        } else if style.maximumLineHeight > 0, style.minimumLineHeight == style.maximumLineHeight {
            result.lineSpacing = .exactly(Double(style.maximumLineHeight))
        }
        result.tabStops = style.tabStops.map { tab in
            let alignment: ExportTabStop.Alignment
            if tab.options[.columnTerminators] != nil {
                alignment = .decimal
            } else {
                switch tab.alignment {
                case .center: alignment = .center
                case .right: alignment = .right
                default: alignment = .left
                }
            }
            return ExportTabStop(position: Double(tab.location), alignment: alignment)
        }
        return result
    }

    /// An attachment's picture: its image for the story, its bytes and UTI for the document's blob,
    /// and its size in points.
    static func picture(_ attachment: NSTextAttachment) -> (image: CGImage?, data: Data, uti: String, size: CGSize)? {
        let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents
        guard let (cgImage, imageSize) = PlatformText.image(attachment, data: data) else { return nil }
        let size = attachment.bounds.size == .zero ? imageSize : attachment.bounds.size
        if let data, let source = CGImageSourceCreateWithData(data as CFData, nil), let uti = CGImageSourceGetType(source) {
            return (cgImage, data, uti as String, size)
        }
        guard let cgImage, let png = ImageEncoding.encode(cgImage, type: .png) else { return nil }
        return (cgImage, png, "public.png", size)
    }
}

/// What a scan of RTF source recovers that `NSAttributedString` drops: the paragraph style of each
/// paragraph, its tab leaders, keep-with-next and "don't hyphenate", and the small caps, all caps
/// and character style of each character (UTF-16 offsets, as the attributed string counts).
struct RTFScan {
    struct Format: Equatable {
        var smallCaps = false
        var allCaps = false
        var characterStyle: Int?
        /// `\charscalex`, percent: the attributed string has no horizontal scale.
        var scale: Int?
    }

    struct ParagraphFormat {
        var style: Int?
        var leaders: [Int: ExportTabStop.Leader] = [:]
        var keepWithNext = false
        var noHyphens = false
        /// `\ri`, points: the attributed string has no right indent without a page width.
        var rightIndent: Double = 0
    }

    private(set) var paragraphStyles: [Int: String] = [:]
    private(set) var characterStyles: [Int: String] = [:]
    private(set) var formats: [Format] = []
    private(set) var paragraphs: [ParagraphFormat] = []
    var length: Int { formats.count }

    /// Destinations whose text is not part of the document.
    static let skipped: Set<String> = ["fonttbl", "colortbl", "info", "pict", "header", "footer", "headerl", "headerr", "footerl", "footerr",
                                       "listtable", "listoverridetable", "rsidtbl", "generator", "themedata", "filetbl", "revtbl", "xmlnstbl",
                                       "latentstyles", "datastore", "fldinst", "object", "nonshppict", "footnote", "stylesheet"]
    /// Control words that stand for one character.
    static let symbols: [String: Int] = ["tab": 1, "line": 1, "par": 1, "emdash": 1, "endash": 1, "bullet": 1, "lquote": 1, "rquote": 1,
                                        "ldblquote": 1, "rdblquote": 1, "emspace": 1, "enspace": 1, "qmspace": 1, "page": 1, "sect": 1]

    init?(_ data: Data) {
        guard let source = String(data: data, encoding: .isoLatin1) else { return nil }
        let chars = Array(source.utf8)
        var stack: [(format: Format, skip: Bool, style: Bool, uc: Int)] = []
        var format = Format()
        var skip = false
        var inStylesheet = false
        var uc = 1
        var paragraph = ParagraphFormat()
        var pendingLeader: ExportTabStop.Leader = .none
        var styleEntry: (number: Int, character: Bool)?
        var styleName = ""
        var pendingSkip = 0
        var index = 0
        func emit(_ count: Int = 1) {
            if pendingSkip > 0 {
                pendingSkip -= 1
                return
            }
            guard !skip else { return }
            for _ in 0..<count { formats.append(format) }
        }
        while index < chars.count {
            let c = chars[index]
            switch c {
            case UInt8(ascii: "{"):
                stack.append((format, skip, inStylesheet, uc))
                index += 1
                if inStylesheet { styleEntry = nil; styleName = "" }
            case UInt8(ascii: "}"):
                if inStylesheet, let entry = styleEntry {
                    let name = styleName.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                    if entry.character { characterStyles[entry.number] = name } else { paragraphStyles[entry.number] = name }
                    styleEntry = nil
                }
                if let top = stack.popLast() {
                    format = top.format
                    skip = top.skip
                    inStylesheet = top.style
                    uc = top.uc
                }
                index += 1
            case UInt8(ascii: "\\"):
                index += 1
                guard index < chars.count else { break }
                let next = chars[index]
                if next == UInt8(ascii: "'") {
                    index += 3
                    if inStylesheet { styleName.append("?") } else { emit() }
                } else if !(next >= 97 && next <= 122) && !(next >= 65 && next <= 90) {
                    index += 1
                    switch next {
                    case UInt8(ascii: "*"):
                        skip = !inStylesheet
                    case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                        // A backslash before a line end is a paragraph mark.
                        emit()
                        if !skip { paragraphs.append(paragraph) }
                    case UInt8(ascii: "-"):
                        // An optional hyphen: the attributed string drops it.
                        break
                    default:
                        // `\\`, `\{`, `\}`, `\~`, `\_`, `\:` ... each read as one character.
                        if inStylesheet { styleName.append(Character(Unicode.Scalar(next))) } else { emit() }
                    }
                } else {
                    var word = ""
                    while index < chars.count, (chars[index] >= 97 && chars[index] <= 122) || (chars[index] >= 65 && chars[index] <= 90) {
                        word.append(Character(Unicode.Scalar(chars[index])))
                        index += 1
                    }
                    var number: Int?
                    var sign = 1
                    if index < chars.count, chars[index] == UInt8(ascii: "-") {
                        sign = -1
                        index += 1
                    }
                    var digits = ""
                    while index < chars.count, chars[index] >= 48, chars[index] <= 57 {
                        digits.append(Character(Unicode.Scalar(chars[index])))
                        index += 1
                    }
                    if !digits.isEmpty { number = sign * (Int(digits) ?? 0) }
                    if index < chars.count, chars[index] == UInt8(ascii: " ") { index += 1 }
                    if word == "stylesheet" {
                        inStylesheet = true
                        continue
                    }
                    if inStylesheet {
                        if word == "s", let number { styleEntry = (number, false) }
                        if word == "cs", let number { styleEntry = (number, true) }
                        continue
                    }
                    if Self.skipped.contains(word) {
                        skip = true
                        continue
                    }
                    switch word {
                    case "u":
                        emit()
                        pendingSkip = uc
                    case "uc": uc = number ?? 1
                    case "scaps": format.smallCaps = (number ?? 1) != 0
                    case "caps": format.allCaps = (number ?? 1) != 0
                    case "cs": format.characterStyle = number
                    case "charscalex": format.scale = number == 100 ? nil : number
                    case "plain": format = Format()
                    case "pard": paragraph = ParagraphFormat()
                    case "s": paragraph.style = number
                    case "keepn": paragraph.keepWithNext = true
                    case "ri": paragraph.rightIndent = Double(number ?? 0) / 20
                    case "hyphpar": paragraph.noHyphens = (number ?? 1) == 0
                    case "tldot": pendingLeader = .dots
                    case "tlhyph": pendingLeader = .hyphens
                    case "tlul", "tlth": pendingLeader = .underline
                    case "tx", "tb":
                        if pendingLeader != .none, let number { paragraph.leaders[number] = pendingLeader }
                        pendingLeader = .none
                    default:
                        if let count = Self.symbols[word] {
                            emit(count)
                            if word == "par" || word == "sect" || word == "page", !skip { paragraphs.append(paragraph) }
                        }
                    }
                }
            case UInt8(ascii: "\r"), UInt8(ascii: "\n"):
                index += 1
            default:
                if inStylesheet {
                    styleName.append(Character(Unicode.Scalar(c)))
                } else {
                    // UTF-8 continuation bytes of a raw non-ASCII character count once.
                    if c & 0xC0 != 0x80 { emit() }
                }
                index += 1
            }
        }
        if formats.count > paragraphs.count || paragraphs.isEmpty { paragraphs.append(paragraph) }
    }

    func smallCaps(at offset: Int) -> Bool { formats.indices.contains(offset) && formats[offset].smallCaps }

    /// The horizontal scale at `offset` (1 = 100%), nil where none was given.
    func horizontalScale(at offset: Int) -> Double? {
        guard formats.indices.contains(offset), let scale = formats[offset].scale, scale > 0 else { return nil }
        return Double(scale) / 100
    }
    func allCaps(at offset: Int) -> Bool { formats.indices.contains(offset) && formats[offset].allCaps }

    func characterStyle(at offset: Int) -> String? {
        guard formats.indices.contains(offset), let number = formats[offset].characterStyle else { return nil }
        return characterStyles[number]
    }

    /// Lays paragraph `index`'s recovered settings onto `style`.
    func apply(to style: inout ExportParagraphStyle, paragraph index: Int) {
        guard paragraphs.indices.contains(index) else { return }
        let format = paragraphs[index]
        if let number = format.style, number != 0 { style.styleName = paragraphStyles[number] }
        style.keepWithNext = format.keepWithNext
        style.hyphenate = !format.noHyphens
        if format.rightIndent != 0 { style.rightIndent = format.rightIndent }
        for (position, leader) in format.leaders {
            if let tab = style.tabStops.firstIndex(where: { abs($0.position * 20 - Double(position)) < 1 }) {
                style.tabStops[tab].leader = leader
            }
        }
    }
}
