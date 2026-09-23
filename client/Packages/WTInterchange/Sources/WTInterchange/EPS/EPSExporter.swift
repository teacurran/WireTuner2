// The EPS exporter (IO-018): each page flattened for an opaque target -- transparency composited,
// effects expanded or rendered, gradients kept for Level 3 shadings or Level 2 bands -- and written
// as one EPS file, with an optional TIFF preview rendered by the bitmap rasterizer.

import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct EPSExporter: Exporter {
    public var cmyk: any CMYKConverter

    public init(cmyk: any CMYKConverter = ProfileCMYKConverter()) {
        self.cmyk = cmyk
    }

    public var format: ExportFormat { .eps }
    public var optionsType: any ExportOptions.Type { EPSOptions.self }
    public var capabilities: ExportCapabilities { ExportFormat.eps.capabilities }

    /// The flattener EPS output goes through with `options`.
    public static func flattener(options: EPSOptions, scene: ExportScene) -> Flattener {
        Flattener(target: .opaque, rasterResolution: options.rasterPPI > 0 ? options.rasterPPI : scene.rasterResolution, outlineText: options.fonts == .outlines)
    }

    /// Page `index` of `scene` as EPS data and the summary notes.
    public func data(scene: ExportScene, page index: Int, options: EPSOptions, title: String? = nil) throws -> (data: Data, notes: [String]) {
        try options.validate()
        guard scene.pages.indices.contains(index) else {
            throw ExportError.nothingToExport
        }
        let page = scene.pages[index]
        let flat = EPSExporter.flattener(options: options, scene: scene).flatten(page, scene: scene)
        let preview = options.preview.ppi.map { EPSExporter.preview(page, ppi: $0) }
        let written = EPSWriter(options: options, cmyk: cmyk).write(flat.page, scene: scene, title: title ?? page.name ?? scene.name, preview: preview)
        return (written.data, flat.report.notes + written.notes)
    }

    /// The page rendered at `ppi` over white as an uncompressed TIFF (the preview old layout
    /// programs read).
    static func preview(_ page: ExportPage, ppi: Double) -> Data {
        let rasterizer = BitmapRasterizer(common: BitmapCommonOptions(ppi: ppi, antiAliasing: 4, background: .white, rgbSpace: .sRGB))
        let bitmap = rasterizer.render(page, scale: 1, bitsPerComponent: 8, alpha: false).bitmap
        // An 8-bit RGB image always encodes as TIFF.
        return ImageEncoding.encode(bitmap.image, type: .tiff, properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]])!
    }

    public func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination) throws -> ExportSummary {
        let options = try typed(options, as: EPSOptions.self)
        try options.validate()
        guard !scene.pages.isEmpty else {
            throw ExportError.nothingToExport
        }
        let urls = try destination.urls(count: scene.pages.count, format: .eps) { index in
            FileNamePattern.Values(name: scene.name, page: index + 1, pageName: scene.pages[index].name)
        }
        var summary = ExportSummary()
        for (index, url) in urls.enumerated() {
            let written = try data(scene: scene, page: index, options: options, title: url.lastPathComponent)
            do {
                try written.data.write(to: url)
            } catch {
                throw ExportError.writeFailed(error.localizedDescription)
            }
            summary.files.append(url)
            summary.notes += written.notes
        }
        return summary
    }
}
