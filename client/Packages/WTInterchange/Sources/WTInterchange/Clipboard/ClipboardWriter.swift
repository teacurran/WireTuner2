// The clipboard writers (copying.adoc, "Clipboard formats"; OBJ-015): the selection's export
// scene written as each enabled pasteboard type on demand, so the app can put the types on the
// pasteboard at once and produce the expensive ones only when a reader asks
// (`NSPasteboardItemDataProvider`).  Built on the export writers: PDF through `PDFExporter`, SVG
// through `SVGExporter` with images embedded, TIFF and PNG through `BitmapRasterizer`, RTF and
// plain text through the text exporters.

import Foundation

/// What one Copy offers: the pasteboard types, and each type's bytes when asked.
public struct ClipboardWriter: Sendable {
    /// The selection as exporters see it: one page whose bounds are the selection's.
    public var scene: ExportScene
    public var settings: ClipboardSettings
    /// The native payload's bytes (`ClipboardPayload.encoded()`), nil to leave the native type out.
    public var native: Data?
    /// The PDF copy's CMYK conversion.
    public var cmyk: any CMYKConverter

    public init(scene: ExportScene, settings: ClipboardSettings = ClipboardSettings(), native: Data? = nil,
                cmyk: any CMYKConverter = ProfileCMYKConverter()) {
        self.scene = scene
        self.settings = settings
        self.native = native
        self.cmyk = cmyk
    }

    /// The formats this copy writes: the enabled ones that have something to carry -- native only
    /// with a payload, the vector and image formats only with a page, the text formats only when
    /// the selection holds text.
    public var formats: [ClipboardFormat] {
        let hasText = !TextStories.ordered(scene.text).isEmpty
        return ClipboardFormat.richestFirst.filter { format in
            guard settings.formats.contains(format) else { return false }
            switch format {
            case .native: return native != nil
            case .rtf, .plainText: return hasText
            case .pdf, .svg, .image: return !scene.pages.isEmpty
            }
        }
    }

    /// The pasteboard types to declare, richest first.
    public var types: [String] { formats.flatMap(\.writtenTypes) }

    /// The bytes of pasteboard type `type`; nil when this copy does not offer it.
    public func data(for type: String) throws -> Data? {
        guard types.contains(type), let format = ClipboardFormat(pasteboardType: type) else { return nil }
        switch format {
        case .native:
            return native
        case .pdf:
            return try PDFExporter(cmyk: cmyk).data(scene: scene, options: PDFOptions(colors: settings.colors.pdfColors)).data
        case .svg:
            // Embedded images (a pasteboard has nowhere to put linked ones); SVG colour is sRGB.
            return Data(SVGExporter().documents(scene: scene, options: SVGOptions(images: .embed))[0].text.utf8)
        case .image:
            return try image(type == ClipboardFormat.pngType ? .png : .tiff)
        case .rtf:
            return try RTFExporter().data(scene: scene, options: RTFOptions()).data
        case .plainText:
            return try PlainTextExporter().data(scene: scene, options: PlainTextOptions())
        }
    }

    /// Every offered type's bytes, in order (a pasteboard that is written eagerly, and tests).
    public func allData() throws -> [(type: String, data: Data)] {
        try types.compactMap { type in try data(for: type).map { (type, $0) } }
    }

    /// The page rasterized at *Clipboard image resolution* on a transparent background, encoded
    /// as `format` (PNG or TIFF, 8 bits per channel with alpha).
    func image(_ format: ExportFormat) throws -> Data {
        let common = BitmapCommonOptions(ppi: settings.imageResolution, background: .transparent)
        let options: any BitmapFormatOptions = format == .png ? PNGOptions(common: common) : TIFFOptions(common: common)
        let exporter = BitmapExporter(format: format)
        let layout = try exporter.layout(for: options)
        let rendered = BitmapRasterizer(common: common).render(scene.pages[0], scale: 1, bitsPerComponent: layout.bitsPerComponent, alpha: layout.alpha)
        return try exporter.imageIOEncoding(rendered.bitmap, options: options, url: URL(fileURLWithPath: "Clipboard.\(format.fileExtension)"))
    }
}
