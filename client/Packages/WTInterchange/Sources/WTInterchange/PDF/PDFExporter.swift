// The PDF exporter: every page flattened for PDF 1.4+ (or, for PDF/X-1a, for an opaque target) and
// written into one file.  A PDF/X standard first forces the options it requires; what that changed
// is the fix report at the head of the summary notes.

import Foundation

public struct PDFExporter: Exporter {
    /// Converts colours and images for CMYK output and PDF/X (the registry's Default CMYK unless
    /// the dialog passes the document's Working CMYK or a destination profile).
    public var cmyk: any CMYKConverter

    public init(cmyk: any CMYKConverter = ProfileCMYKConverter()) {
        self.cmyk = cmyk
    }

    public var format: ExportFormat { .pdf }
    public var optionsType: any ExportOptions.Type { PDFOptions.self }
    public var capabilities: ExportCapabilities { ExportFormat.pdf.capabilities }

    /// The flattener PDF output goes through with `options`: PDF/X-1a allows no transparency.
    public static func flattener(options: PDFOptions, scene: ExportScene) -> Flattener {
        Flattener(target: options.standard == .pdfX1a2001 ? .opaque : .pdf, rasterResolution: options.rasterPPI > 0 ? options.rasterPPI : scene.rasterResolution, outlineText: options.fonts == .outlines)
    }

    /// `scene` as PDF data and the summary notes.
    public func data(scene: ExportScene, options requested: PDFOptions) throws -> (data: Data, notes: [String]) {
        try requested.validate()
        guard !scene.pages.isEmpty else {
            throw ExportError.nothingToExport
        }
        let (options, fixes) = requested.conforming()
        let flattener = PDFExporter.flattener(options: options, scene: scene)
        var pages: [FlatPage] = []
        var notes = fixes
        for page in scene.pages {
            let flat = flattener.flatten(page, scene: scene)
            pages.append(flat.page)
            notes += flat.report.notes
        }
        let written = PDFWriter(options: options, cmyk: cmyk).write(pages, scene: scene)
        return (written.data, notes + written.notes)
    }

    public func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination) throws -> ExportSummary {
        let options = try typed(options, as: PDFOptions.self)
        return try destination.writeSingle(data(scene: scene, options: options), extension: ExportFormat.pdf.fileExtension)
    }
}

/// Adobe Illustrator options (export-vector.adoc, "Adobe Illustrator options"): the PDF options
/// with everything but these fixed.
public struct IllustratorOptions: ExportOptions, Hashable {
    public var colors: PDFOptions.Colors
    /// The embedded document package (IO-028).  Not written yet: reported.
    public var embedPackage: Bool
    public var includeDocumentInfo: Bool

    public init(colors: PDFOptions.Colors = .keep, embedPackage: Bool = false, includeDocumentInfo: Bool = true) {
        self.colors = colors
        self.embedPackage = embedPackage
        self.includeDocumentInfo = includeDocumentInfo
    }

    public static var defaults: IllustratorOptions { IllustratorOptions() }

    /// The fixed profile: PDF 1.7, complete fonts (text stays editable), layers as optional
    /// content, links kept.
    public var pdfOptions: PDFOptions {
        PDFOptions(version: .v1_7, layers: true, embedPackage: embedPackage, includeDocumentInfo: includeDocumentInfo, fonts: .embedFull, colors: colors)
    }
}

/// The Illustrator exporter (IO-029): a PDF in the fixed profile, saved as `.ai`.  Illustrator
/// opens it as a PDF with layers, paths and text; no Illustrator private data is written.
public struct IllustratorExporter: Exporter {
    public var cmyk: any CMYKConverter

    public init(cmyk: any CMYKConverter = ProfileCMYKConverter()) {
        self.cmyk = cmyk
    }

    public var format: ExportFormat { .illustrator }
    public var optionsType: any ExportOptions.Type { IllustratorOptions.self }
    public var capabilities: ExportCapabilities { ExportFormat.illustrator.capabilities }

    public func data(scene: ExportScene, options: IllustratorOptions) throws -> (data: Data, notes: [String]) {
        try PDFExporter(cmyk: cmyk).data(scene: scene, options: options.pdfOptions)
    }

    public func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination) throws -> ExportSummary {
        let options = try typed(options, as: IllustratorOptions.self)
        return try destination.writeSingle(data(scene: scene, options: options), extension: ExportFormat.illustrator.fileExtension)
    }
}
