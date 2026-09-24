// The SVG exporter: flattens each page for SVG and writes one file per page, with linked images
// in a folder named after the file.

import Foundation

public struct SVGExporter: Exporter {
    public init() {}

    public var format: ExportFormat { .svg }
    public var optionsType: any ExportOptions.Type { SVGOptions.self }
    public var capabilities: ExportCapabilities { ExportFormat.svg.capabilities }

    /// The flattener SVG output goes through with `options`.
    public static func flattener(options: SVGOptions, scene: ExportScene) -> Flattener {
        Flattener(target: .svg, rasterResolution: options.rasterPPI > 0 ? options.rasterPPI : scene.rasterResolution, outlineText: options.text == .outlines)
    }

    /// Every page of `scene` as an SVG document.
    /// `pageHrefs` maps document page numbers to what page links point at (`SVGWriter.pageHrefs`).
    public func documents(scene: ExportScene, options: SVGOptions, pageHrefs: [Int: String] = [:],
                          resourceFolder: (Int) -> String = { _ in "images" }) -> [SVGDocument] {
        let flattener = SVGExporter.flattener(options: options, scene: scene)
        return scene.pages.enumerated().map { index, page in
            let flat = flattener.flatten(page, scene: scene)
            var document = SVGWriter(options: options, pageHrefs: pageHrefs).write(flat.page, scene: scene, resourceFolder: resourceFolder(index))
            document.notes = flat.report.notes + document.notes
            return document
        }
    }

    public func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination) throws -> ExportSummary {
        let options = try typed(options, as: SVGOptions.self)
        try options.validate()
        guard !scene.pages.isEmpty else {
            throw ExportError.nothingToExport
        }
        let urls = try destination.urls(count: scene.pages.count, format: .svg) { index in
            FileNamePattern.Values(name: scene.name, page: index + 1, pageName: scene.pages[index].name)
        }
        // A page link goes to the exported file of its page (interactivity.adoc, "SVG").
        var pageHrefs: [Int: String] = [:]
        for (number, url) in zip(WebLinks.pageNumbers(scene), urls) {
            pageHrefs[number] = url.lastPathComponent
        }
        let documents = documents(scene: scene, options: options, pageHrefs: pageHrefs) { urls[$0].deletingPathExtension().lastPathComponent }
        var summary = ExportSummary()
        summary.notes += WebLinks.warnings(scene).filter { $0.kind == .invalidLink || $0.kind == .unusedLink }.map(\.message)
        do {
            for (document, url) in zip(documents, urls) {
                try Data(document.text.utf8).write(to: url)
                for resource in document.resources {
                    let file = url.deletingLastPathComponent().appendingPathComponent(resource.path)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try resource.data.write(to: file)
                    summary.files.append(file)
                }
                summary.files.append(url)
                summary.notes += document.notes
            }
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return summary
    }
}
