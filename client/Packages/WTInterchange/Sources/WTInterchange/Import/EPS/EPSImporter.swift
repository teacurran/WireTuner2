// The EPS importer (import-formats.adoc, "EPS"; IMG-011): an EPS file is placed, not converted.
// The whole file is kept verbatim as the placed file's blob for PostScript output; its natural
// size is the DSC bounding box; its preview (the embedded PDF, the DOS header's TIFF or the EPSI
// bitmap) is re-encoded as a PNG blob for the renderer, and a file without one is drawn as a gray
// box with its name.  A PostScript Illustrator EPS goes through the legacy Illustrator reader
// first (import-formats.adoc, "Adobe Illustrator"), which places it when it leaves the operator
// set.  DCS files are placed like any EPS through their composite preview.

import CoreGraphics
import Foundation
import WTGeometry

public struct EPSImporter: Importer {
    public init() {}

    public var formats: [ImportFormat] { [.eps] }

    /// The UTI of the placed file's blob.
    public static let uti = "com.adobe.encapsulated-postscript"

    /// The natural size when a file has no usable bounding box and no preview: US Letter.
    static let fallbackSize = (width: 612.0, height: 792.0)

    public func probe(_ data: Data, name: String, format: ImportFormat) throws -> ImportDescriptor {
        let file = try EPSFile(data, name: name)
        if let converted = EPSImporter.illustrator(file, name: name) {
            return ImportDescriptor(format: format, naturalSize: converted.bounds)
        }
        let preview = file.preview()
        return ImportDescriptor(format: format, naturalSize: EPSImporter.bounds(file, preview: preview?.image).rect, preview: preview?.image, placed: true)
    }

    public func convert(_ data: Data, name: String, format: ImportFormat, options: ImportOptionValues, context: ImportContext) throws -> ImportedScene {
        let file = try EPSFile(data, name: name)
        if let converted = EPSImporter.illustrator(file, name: name) {
            return converted
        }
        return EPSImporter.place(data, file: file, name: name)
    }

    /// A PostScript Illustrator EPS read as vector artwork, or nil when the file is not one or
    /// the reader falls back to placement (the file is then placed here, with its preview).
    static func illustrator(_ file: EPSFile, name: String) -> ImportedScene? {
        guard file.creator?.contains("Adobe Illustrator") == true, file.postscript.range(of: Data("%PDF-".utf8)) == nil else {
            return nil
        }
        let scene = AILegacyReader(data: file.postscript, name: name, text: .editable).read()
        return scene.kind == .vector ? scene : nil
    }

    /// Why a placed EPS cannot become editable objects (menu:Object[Convert to Editable]).
    public static let notEditable = "it carries only PostScript, which WireTuner does not interpret, so it stays a placed file."


    /// A placed EPS file's artwork as editable objects (IMG-060, import-formats.adoc "Converting a
    /// placed EPS"): the PDF-compatible stream a recent Illustrator embeds, converted by the PDF
    /// importer (its first page, editable text, no notes or links, no page clip), else a
    /// PostScript Illustrator file the legacy reader can read.  Anything else -- plain PostScript
    /// -- is refused with `ImportError.unreadable` and `notEditable` as the reason.
    public static func editable(_ data: Data, name: String, context: ImportContext = ImportContext()) throws -> ImportedScene {
        let file = try EPSFile(data, name: name)
        if let pdf = file.embeddedPDF, let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider), document.numberOfPages > 0 {
            let options = PDFImportOptions(pages: ImportPageRange(parsing: "1")!, text: .editable, importNotes: false, importLinks: false, keepPageClip: false)
            return try PDFImporter().convert(document, name: name, options: options, context: context)
        }
        if file.creator?.contains("Adobe Illustrator") == true {
            let scene = AILegacyReader(data: file.postscript, name: name, text: .editable).read()
            if scene.kind == .vector { return scene }
        }
        throw ImportError.unreadable(name: name, reason: notEditable)
    }

    /// `data` placed as an EPS: the file blob, its bounding box and preview, and notes on what
    /// the placement cannot show.
    static func place(_ data: Data, file: EPSFile, name: String, notes: [String] = []) -> ImportedScene {
        var notes = notes
        let preview = file.preview()
        let (bounds, boxNote) = EPSImporter.bounds(file, preview: preview?.image)
        if let boxNote {
            notes.append("“\(name)” has no bounding box; it is placed at \(boxNote).")
        }
        if preview == nil {
            if file.hasMetafile {
                notes.append("“\(name)” has a Windows Metafile preview, which WireTuner does not read; it shows as a gray box.")
            } else {
                notes.append("“\(name)” has no preview; it shows as a gray box of its bounding-box size.")
            }
        }
        if file.isDCS {
            notes.append("“\(name)” is a DCS file: it is placed with its composite preview and its plates are not separated.")
        }
        let placed = ImportedPlacedFile(kind: .eps, blob: ImportedBlob(data: data, uti: EPSImporter.uti), bounds: bounds, name: name, preview: preview.map { ImageImporter.pixels(of: $0.image) })
        return ImportedScene(kind: .placed, name: name, bounds: bounds, nodes: [.placed(placed)], notes: notes)
    }

    /// The natural rect `(0, 0, width, height)` in points: the bounding box's size, else the
    /// preview's pixels at 72 ppi, else US Letter; with the fallback described when one is used.
    static func bounds(_ file: EPSFile, preview: CGImage?) -> (rect: Rect, fallback: String?) {
        if let box = file.boundingBox {
            return (Rect(x: 0, y: 0, width: box.width, height: box.height), nil)
        }
        if let preview {
            return (Rect(x: 0, y: 0, width: Double(preview.width), height: Double(preview.height)), "its preview’s size")
        }
        return (Rect(x: 0, y: 0, width: fallbackSize.width, height: fallbackSize.height), "612 × 792 pt")
    }
}
