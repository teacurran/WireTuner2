// The PDF exporter: every page flattened for PDF 1.4+ and written into one file.

import Foundation

public struct PDFExporter: Exporter {
    public init() {}

    public var format: ExportFormat { .pdf }
    public var optionsType: any ExportOptions.Type { PDFOptions.self }
    public var capabilities: ExportCapabilities { ExportFormat.pdf.capabilities }

    /// The flattener PDF output goes through with `options`.
    public static func flattener(options: PDFOptions, scene: ExportScene) -> Flattener {
        Flattener(target: .pdf, rasterResolution: options.rasterPPI > 0 ? options.rasterPPI : scene.rasterResolution, outlineText: options.fonts == .outlines)
    }

    /// `scene` as PDF data and the summary notes.
    public func data(scene: ExportScene, options: PDFOptions) throws -> (data: Data, notes: [String]) {
        try options.validate()
        guard !scene.pages.isEmpty else {
            throw ExportError.nothingToExport
        }
        let flattener = PDFExporter.flattener(options: options, scene: scene)
        var pages: [FlatPage] = []
        var notes: [String] = []
        for page in scene.pages {
            let flat = flattener.flatten(page, scene: scene)
            pages.append(flat.page)
            notes += flat.report.notes
        }
        let written = PDFWriter(options: options).write(pages, scene: scene)
        return (written.data, notes + written.notes)
    }

    public func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination) throws -> ExportSummary {
        let options = try typed(options, as: PDFOptions.self)
        let written = try data(scene: scene, options: options)
        let url = destination.url.deletingPathExtension().appendingPathExtension(ExportFormat.pdf.fileExtension)
        do {
            try written.data.write(to: url)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return ExportSummary(files: [url], notes: written.notes)
    }
}
