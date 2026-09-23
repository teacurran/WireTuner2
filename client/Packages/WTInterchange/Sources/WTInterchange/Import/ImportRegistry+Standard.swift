// The importers this package ships (import-formats.adoc, "Format summary").  EPS placement is
// IMG-011's and text import the TXT epic's; until they register, those files are refused as
// unsupported.

extension ImportRegistry {
    /// Every importer: vector formats converted, bitmaps through ImageIO.
    public static let standard = ImportRegistry(importers: [
        PDFImporter(),
        IllustratorImporter(),
        SVGImporter(),
        DXFImporter(),
        ImageImporter(),
    ])
}
