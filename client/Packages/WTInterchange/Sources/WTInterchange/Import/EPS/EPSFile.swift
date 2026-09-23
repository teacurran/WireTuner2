// An Encapsulated PostScript file taken apart (import-formats.adoc, "EPS" and "Client"; IMG-011):
// the DOS EPS binary header's sections, the DSC header comments the placement needs and the
// screen preview the file carries -- the TIFF section of a DOS header, an EPSI hex bitmap, or a
// PDF embedded in the PostScript (Illustrator's PDF-compatible stream).  Nothing here interprets
// PostScript; the file is placed, not converted.

import CoreGraphics
import Foundation
import ImageIO
import WTGeometry

/// The parts and DSC facts of an EPS file.
public struct EPSFile: Sendable {
    /// Where a preview came from.
    public enum PreviewSource: String, Hashable, Sendable {
        /// The TIFF section of a DOS EPS binary header.
        case tiff
        /// An EPSI `%%BeginPreview` hex bitmap.
        case epsi
        /// A PDF embedded in the PostScript, rendered with Core Graphics.
        case pdf
    }

    /// The PostScript language section (the whole file without a binary header).
    public let postscript: Data
    /// The TIFF section of a DOS binary header, when it has one.
    public let tiff: Data?
    /// Whether the binary header has a Windows Metafile section (not read).
    public let hasMetafile: Bool
    /// `%%HiResBoundingBox`, else `%%BoundingBox`, in PostScript points (y up); nil when absent,
    /// unparseable or of zero area.
    public private(set) var boundingBox: Rect?
    /// `%%Title` and `%%Creator`, PostScript string escapes decoded.
    public private(set) var title: String?
    public private(set) var creator: String?
    /// `%%DocumentProcessColors` (Cyan, Magenta…) and `%%DocumentCustomColors` (spot inks).
    public private(set) var processColors: [String] = []
    public private(set) var customColors: [String] = []
    /// A Desktop Color Separations file (DCS 1.0 plate comments or DCS 2.0 `%%PlateFile`).
    public private(set) var isDCS = false
    /// The EPSI preview's `width height depth` and hex digits, when there is one.
    var epsi: (width: Int, height: Int, depth: Int, hex: [UInt8])?

    /// `data` taken apart; throws when it is neither a DOS EPS binary file with sound offsets
    /// nor PostScript.
    public init(_ data: Data, name: String) throws {
        let bytes = [UInt8](data.prefix(30))
        if bytes.starts(with: [0xC5, 0xD0, 0xD3, 0xC6]) {
            guard bytes.count == 30 else {
                throw ImportError.unreadable(name: name, reason: "its EPS binary header is truncated.")
            }
            func word(_ offset: Int) -> Int {
                (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
            }
            func section(_ offset: Int) -> Data? {
                let start = word(offset)
                let length = word(offset + 4)
                guard length > 0, start >= 30, start + length <= data.count else {
                    return nil
                }
                let base = data.startIndex
                return data.subdata(in: (base + start)..<(base + start + length))
            }
            guard let postscript = section(4) else {
                throw ImportError.unreadable(name: name, reason: "its EPS binary header points outside the file.")
            }
            self.init(postscript: postscript, tiff: section(20), hasMetafile: word(16) > 0)
        } else {
            self.init(postscript: data)
        }
        guard postscript.starts(with: Data("%!".utf8)) else {
            throw ImportError.unreadable(name: name, reason: "it is not an Encapsulated PostScript file.")
        }
    }

    /// PostScript text (without a binary header) and the binary header's other sections.
    init(postscript: Data, tiff: Data? = nil, hasMetafile: Bool = false) {
        self.postscript = postscript
        self.tiff = tiff
        self.hasMetafile = hasMetafile
        readComments()
    }

    // MARK: DSC

    /// The header comments (to `%%EndComments`, the first line that is not a comment or the
    /// first `%%Begin` section), the EPSI preview right after them, and `(atend)` values from
    /// the trailer.
    private mutating func readComments() {
        var lines = EPSLines(postscript)
        var values: [String: String] = [:]
        var key: String?
        while let line = lines.next() {
            if line.hasPrefix("%%+") {
                if let key {
                    values[key]? += " " + line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            // The header ends at `%%EndComments`, a line that is not a comment, or the first
            // `%%Begin` section (a preview, the prolog) when `%%EndComments` is missing.
            if line.hasPrefix("%%EndComments") || !line.hasPrefix("%") || line.hasPrefix("%%Begin") {
                break
            }
            key = nil
            guard line.hasPrefix("%%"), let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = String(line[line.index(line.startIndex, offsetBy: 2)..<colon])
            // The header's first value wins (DSC); a later one belongs to something else.
            if values[name] == nil {
                values[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                key = name
            }
        }
        readPreview(&lines)
        // `(atend)` values are in the trailer, the last `%%Trailer` of the file.
        if values.values.contains("(atend)"), let trailer = postscript.range(of: Data("%%Trailer".utf8), options: .backwards) {
            var tail = EPSLines(postscript[trailer.upperBound...])
            while let line = tail.next() {
                guard line.hasPrefix("%%"), let colon = line.firstIndex(of: ":") else {
                    continue
                }
                let name = String(line[line.index(line.startIndex, offsetBy: 2)..<colon])
                if values[name] == "(atend)" {
                    values[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        boundingBox = EPSFile.box(values["HiResBoundingBox"]) ?? EPSFile.box(values["BoundingBox"])
        title = values["Title"].map(EPSFile.text)
        creator = values["Creator"].map(EPSFile.text)
        processColors = values["DocumentProcessColors"].map(EPSFile.names) ?? []
        customColors = values["DocumentCustomColors"].map(EPSFile.names) ?? []
        isDCS = values["PlateFile"] != nil || ["CyanPlate", "MagentaPlate", "YellowPlate", "BlackPlate"].contains { values[$0] != nil }
    }

    /// The EPSI preview, which must follow the header (blank lines aside).
    private mutating func readPreview(_ lines: inout EPSLines) {
        var line = lines.current
        while let blank = line, blank.trimmingCharacters(in: .whitespaces).isEmpty || blank.hasPrefix("%%EndComments") {
            line = lines.next()
        }
        guard let line, line.hasPrefix("%%BeginPreview:") else {
            return
        }
        let numbers = line.dropFirst("%%BeginPreview:".count).split(separator: " ").compactMap { Int($0) }
        guard numbers.count >= 3 else {
            return
        }
        var hex: [UInt8] = []
        while let row = lines.next(), !row.hasPrefix("%%EndPreview") {
            hex += row.utf8.compactMap(PDFImportLexer.hexValue)
        }
        epsi = (numbers[0], numbers[1], numbers[2], hex)
    }

    /// `llx lly urx ury` as a rect, nil unless four numbers with an area.
    static func box(_ value: String?) -> Rect? {
        guard let values = value?.split(separator: " ").compactMap({ Double($0) }), values.count == 4 else {
            return nil
        }
        let rect = Rect(minX: min(values[0], values[2]), minY: min(values[1], values[3]), maxX: max(values[0], values[2]), maxY: max(values[1], values[3]))
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    /// A DSC text value: a PostScript string `( … )` with its escapes decoded (UTF-8 when the
    /// bytes are, else Latin-1), or the bare text.
    static func text(_ value: String) -> String {
        guard value.hasPrefix("("), value.hasSuffix(")"), value.count >= 2 else {
            return value
        }
        return decode(Array(value.utf8.dropFirst().dropLast()))
    }

    /// The bytes of a PostScript string body, escapes resolved.
    static func decode(_ body: [UInt8]) -> String {
        var bytes: [UInt8] = []
        var index = 0
        while index < body.count {
            let byte = body[index]
            index += 1
            guard byte == UInt8(ascii: "\\"), index < body.count else {
                bytes.append(byte)
                continue
            }
            let next = body[index]
            index += 1
            switch next {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(next - UInt8(ascii: "0"))
                var digits = 1
                while digits < 3, index < body.count, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(body[index]) {
                    value = value * 8 + Int(body[index] - UInt8(ascii: "0"))
                    index += 1
                    digits += 1
                }
                bytes.append(UInt8(value & 0xFF))
            default: bytes.append(next)
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)!
    }

    /// A colour list: parenthesised names (spaces allowed) and bare words.
    static func names(_ value: String) -> [String] {
        var result: [String] = []
        var rest = Substring(value)
        while let first = rest.first(where: { !$0.isWhitespace }) {
            rest = rest.drop { $0.isWhitespace }
            if first == "(", let close = rest.firstIndex(of: ")") {
                let token = String(rest[...close])
                if token != "(atend)" {
                    result.append(text(token))
                }
                rest = rest[rest.index(after: close)...]
            } else {
                let word = rest.prefix { !$0.isWhitespace }
                result.append(String(word))
                rest = rest.dropFirst(word.count)
            }
        }
        return result
    }

    // MARK: Preview

    /// The preview the file carries, as an sRGB or gray image: the embedded PDF (exact, so
    /// preferred), else the TIFF section, else the EPSI bitmap.  Nil when there is none or none
    /// can be decoded.
    public func preview() -> (image: CGImage, source: PreviewSource)? {
        if let image = pdfPreview() {
            return (image, .pdf)
        }
        if let image = tiffPreview() {
            return (image, .tiff)
        }
        if let image = epsiPreview() {
            return (image, .epsi)
        }
        return nil
    }

    /// The largest side, in pixels, of a preview rendered from an embedded PDF.
    static let maximumPreviewSide = 4096

    /// The first page of a PDF embedded in the PostScript, at 144 ppi (at most
    /// `maximumPreviewSide` pixels a side), transparent where nothing is drawn.
    func pdfPreview() -> CGImage? {
        guard let start = postscript.range(of: Data("%PDF-".utf8)),
              let end = postscript.range(of: Data("%%EOF".utf8), options: .backwards, in: start.upperBound..<postscript.endIndex),
              let provider = CGDataProvider(data: postscript.subdata(in: start.lowerBound..<end.upperBound) as CFData),
              let document = CGPDFDocument(provider), let page = document.page(at: 1) else {
            return nil
        }
        let box = page.getBoxRect(.cropBox)
        let scale = min(2, Double(EPSFile.maximumPreviewSide) / max(box.width, box.height))
        let width = max(1, Int((box.width * scale).rounded()))
        let height = max(1, Int((box.height * scale).rounded()))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// The TIFF section decoded by ImageIO and drawn opaque into sRGB (a CMYK or palette TIFF
    /// becomes RGB, which the PNG preview blob can hold).
    func tiffPreview() -> CGImage? {
        guard let tiff, let source = CGImageSourceCreateWithData(tiff as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// The EPSI bitmap as 8-bit gray: rows top first, samples of `depth` bits with 0 white and
    /// the largest value black (EPSF 3.0, "Guidelines for EPSI Files"), each row padded to a
    /// byte.  Nil when the dimensions are unusable or the data is short.
    func epsiPreview() -> CGImage? {
        guard let epsi, epsi.width > 0, epsi.height > 0, [1, 2, 4, 8].contains(epsi.depth), epsi.width * epsi.height <= 100_000_000 else {
            return nil
        }
        let rowBytes = (epsi.width * epsi.depth + 7) / 8
        guard epsi.hex.count / 2 >= rowBytes * epsi.height else {
            return nil
        }
        let maximum = (1 << epsi.depth) - 1
        let perByte = 8 / epsi.depth
        var gray = [UInt8](repeating: 0, count: epsi.width * epsi.height)
        for y in 0..<epsi.height {
            for x in 0..<epsi.width {
                let offset = (y * rowBytes + x / perByte) * 2
                let byte = epsi.hex[offset] << 4 | epsi.hex[offset + 1]
                let shift = 8 - epsi.depth * (x % perByte + 1)
                let sample = Int(byte >> UInt8(shift)) & maximum
                gray[y * epsi.width + x] = UInt8(255 - sample * 255 / maximum)
            }
        }
        let provider = CGDataProvider(data: Data(gray) as CFData)!
        return CGImage(width: epsi.width, height: epsi.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: epsi.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The lines of PostScript text (CR, LF or CRLF), read one at a time as Latin-1 so any byte
/// survives.
struct EPSLines {
    private let data: Data
    private var index: Data.Index
    /// The line `next()` returned last.
    private(set) var current: String?

    init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    mutating func next() -> String? {
        guard index < data.endIndex else {
            current = nil
            return nil
        }
        let end = data[index...].firstIndex { $0 == 0x0A || $0 == 0x0D } ?? data.endIndex
        let line = String(data: data[index..<end], encoding: .isoLatin1)!
        index = end
        if index < data.endIndex {
            let terminator = data[index]
            index += 1
            if terminator == 0x0D, index < data.endIndex, data[index] == 0x0A {
                index += 1
            }
        }
        current = line
        return line
    }
}
