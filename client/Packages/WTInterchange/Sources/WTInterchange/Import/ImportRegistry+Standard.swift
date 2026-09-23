// The importers this package ships (import-formats.adoc, "Format summary").  Text import is the
// TXT epic's; until it registers, text files are refused as unsupported.

extension ImportRegistry {
    /// Every importer: vector formats converted, EPS placed, bitmaps through ImageIO.
    public static let standard = ImportRegistry(importers: [
        PDFImporter(),
        IllustratorImporter(),
        SVGImporter(),
        DXFImporter(),
        EPSImporter(),
        ImageImporter(),
    ])
}
