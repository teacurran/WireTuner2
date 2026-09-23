// The Illustrator importer (import-formats.adoc, "Adobe Illustrator"; IMG-010): files saved with
// *Create PDF Compatible File* (every Illustrator since 9 by default) are read as PDFs -- their
// layers arrive as optional content and become layer groups, live blends as the groups of blended
// shapes Illustrator writes, gradient meshes as 50% black -- and PostScript-based files (versions
// 1.1 through 8, Illustrator EPS) through the legacy operator reader, which places a file it
// cannot read as EPS rather than refusing it.

import CoreGraphics
import Foundation
import WTGeometry

public struct IllustratorImporter: Importer {
    public init() {}

    public var formats: [ImportFormat] { [.illustrator] }

    public func optionsSchema(for format: ImportFormat) -> ImportOptionsSchema { PDFImportOptions.schema }

    /// The PDF importer for PDF-compatible files: gradient meshes at 50% black.
    static let pdf = PDFImporter(meshBlack: 0.5)

    /// Whether `data` carries a PDF (the PDF-compatible format) rather than only PostScript.
    static func isPDFCompatible(_ data: Data) -> Bool {
        data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    public func probe(_ data: Data, name: String, format: ImportFormat) throws -> ImportDescriptor {
        if IllustratorImporter.isPDFCompatible(data) {
            return try IllustratorImporter.pdf.probe(data, name: name, format: format)
        }
        let scene = try legacy(data, name: name, text: .editable)
        return ImportDescriptor(format: format, naturalSize: scene.bounds, placed: scene.kind == .placed)
    }

    public func convert(_ data: Data, name: String, format: ImportFormat, options: ImportOptionValues, context: ImportContext) throws -> ImportedScene {
        let typed = try PDFImportOptions(options, name: name)
        if IllustratorImporter.isPDFCompatible(data) {
            let document = try PDFImporter.document(data, name: name)
            return try IllustratorImporter.pdf.convert(document, name: name, options: typed, context: context)
        }
        return try legacy(data, name: name, text: typed.text)
    }

    /// A PostScript Illustrator file through the legacy reader; anything else is refused.
    func legacy(_ data: Data, name: String, text: ImportTextHandling) throws -> ImportedScene {
        guard String(decoding: data.prefix(64), as: UTF8.self).hasPrefix("%!PS-Adobe") else {
            throw ImportError.unreadable(name: name, reason: "it is neither a PDF-compatible nor a PostScript Illustrator file.")
        }
        return AILegacyReader(data: data, name: name, text: text).read()
    }
}
