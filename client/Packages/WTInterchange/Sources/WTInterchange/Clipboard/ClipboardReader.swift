// The clipboard readers (copying.adoc, "Clipboard formats"; OBJ-015): of the types a pasteboard
// holds, the formats Paste Special may offer and the one Paste takes (the richest), and each
// non-native format converted to an `ImportedScene` that `WTModel` places like an import: PDF and
// SVG as editable paths through their importers, TIFF and PNG as a bitmap object, RTF and plain
// text as a text block.  The native format is the app's own paste path (`ClipboardPayload`).

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Foundation
import WTGeometry
import WTRender

public enum ClipboardReader {
    /// The name pasted artwork gets (importing.adoc, "Pasting").
    public static let pastedName = "Pasted"

    /// The formats `types` (a pasteboard's types) can be pasted as, richest first: what Paste
    /// Special lists.
    public static func formats(in types: [String]) -> [ClipboardFormat] {
        let present = Set(types)
        return ClipboardFormat.richestFirst.filter { format in format.readTypes.contains(where: present.contains) }
    }

    /// The format Paste takes from `types`: the richest present; nil when none is.
    public static func richest(in types: [String]) -> ClipboardFormat? {
        formats(in: types).first
    }

    /// Reads `format` from a pasteboard whose types are `types`, asking `data` for the bytes of
    /// one type (its preferred type present first), converted to a scene named `name`.  Throws
    /// `ImportError.unsupportedFormat` for the native format (the app pastes it) or a format with
    /// no readable type present, and the importer's errors for unreadable bytes.
    public static func read(_ format: ClipboardFormat, types: [String], name: String = pastedName, context: ImportContext = ImportContext(),
                            data: (String) -> Data?) throws -> ImportedScene {
        var found: (type: String, bytes: Data)?
        for type in format.readTypes where format != .native && found == nil && types.contains(type) {
            found = data(type).map { (type, $0) }
        }
        guard let (type, bytes) = found else {
            throw ImportError.unsupportedFormat(name: name)
        }
        switch format {
        case .pdf:
            return try convert(PDFImporter(), bytes, name: name, format: .pdf, context: context)
        case .svg:
            return try convert(SVGImporter(), bytes, name: name, format: .svg, context: context)
        case .image:
            return try convert(ImageImporter(), bytes, name: name, format: type == ClipboardFormat.pngType ? .png : .tiff, context: context)
        case .rtf:
            return try text(rtf: bytes, name: name)
        default:
            return try text(String(decoding: bytes, as: UTF8.self), name: name)
        }
    }

    /// Paste: the richest non-native format of `types` read; nil when only the native format or
    /// nothing readable is present.
    public static func readRichest(types: [String], name: String = pastedName, context: ImportContext = ImportContext(),
                                   data: (String) -> Data?) throws -> ImportedScene? {
        guard let format = richest(in: types), format != .native else { return nil }
        return try read(format, types: types, name: name, context: context, data: data)
    }

    static func convert(_ importer: any Importer, _ data: Data, name: String, format: ImportFormat, context: ImportContext) throws -> ImportedScene {
        try importer.convert(data, name: name, format: format, options: importer.optionsSchema(for: format).defaults, context: context)
    }

    // MARK: Text

    /// The font plain text is pasted in.
    public static let plainFont = "Helvetica"
    public static let plainSize: Double = 12
    /// Line spacing as a multiple of the line's largest size.
    static let leading = 1.2

    /// Plain text as one text block: one line per paragraph, in Helvetica 12 pt, black.
    public static func text(_ string: String, name: String = pastedName) throws -> ImportedScene {
        let lines = string.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map {
            [(text: String($0), font: plainFont, size: plainSize, color: Color.black)]
        }
        return try scene(lines, name: name)
    }

    /// RTF as one text block keeping each run's font, size and colour.
    public static func text(rtf data: Data, name: String = pastedName) throws -> ImportedScene {
        guard let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
            throw ImportError.unreadable(name: name, reason: "the rich text could not be read")
        }
        var lines: [[(text: String, font: String, size: Double, color: Color)]] = [[]]
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            let (name, size, fill) = style(attributes)
            let pieces = (attributed.string as NSString).substring(with: range).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                if index > 0 { lines.append([]) }
                if !piece.isEmpty { lines[lines.count - 1].append((String(piece), name, size, fill)) }
            }
        }
        return try scene(lines, name: name)
    }

    /// A run's font name, size and colour from its RTF attributes; plain text's where one is
    /// missing.
    static func style(_ attributes: [NSAttributedString.Key: Any]) -> (font: String, size: Double, color: Color) {
        let font = PlatformText.font(attributes)
        let color = PlatformText.sRGBForeground(attributes)
        return (font?.name ?? plainFont, font?.size ?? plainSize, color.map { Color(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) } ?? Color.black)
    }

    /// Lines of styled runs set as one text block, baselines stacked downwards (y down, as every
    /// imported scene); trailing empty lines dropped.
    static func scene(_ lines: [[(text: String, font: String, size: Double, color: Color)]], name: String) throws -> ImportedScene {
        var lines = lines
        while let last = lines.last, last.allSatisfy({ $0.text.isEmpty }) { lines.removeLast() }
        guard !lines.isEmpty else { throw ImportError.empty(name: name) }
        var runs: [ImportedTextRun] = []
        var top = 0.0
        var width = 0.0
        for line in lines {
            let size = line.map { $0.size }.max() ?? plainSize
            let baseline = top + size
            // An empty line keeps its place with an empty run on its baseline.
            for run in line.isEmpty ? [(text: "", font: plainFont, size: plainSize, color: Color.black)] : line {
                runs.append(ImportedTextRun(text: run.text, fontName: run.font, fontSize: run.size, fill: .solid(run.color), origin: Point(x: 0, y: baseline)))
            }
            // An estimate (half an em per character): placement only needs the block's extent.
            let estimate: Double = line.reduce(0.0) { total, run in total + Double(run.text.count) * run.size / 2 }
            width = max(width, estimate)
            top += size * leading
        }
        return ImportedScene(kind: .vector, name: name, bounds: Rect(x: 0, y: 0, width: width, height: top), nodes: [.text(ImportedText(runs: runs, name: name))])
    }
}
