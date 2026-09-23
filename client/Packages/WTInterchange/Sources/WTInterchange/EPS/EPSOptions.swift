// EPS export options (export-vector.adoc, "EPS options"; `EpsOptions` in
// interchange/v1/export_options.proto).

import Foundation

public struct EPSOptions: ExportOptions, Hashable {
    public enum Level: Int, CaseIterable, Hashable, Sendable {
        /// Gradients as stepped bands, for old RIPs.
        case level2 = 2
        /// Smooth shadings (`shfill`) for gradients.
        case level3 = 3
    }

    public enum Preview: Hashable, Sendable {
        case none
        /// A TIFF preview at 72 ppi in the DOS EPS binary header.
        case tiff72
        /// A TIFF preview at 144 ppi.
        case tiff144

        var ppi: Double? {
            switch self {
            case .none: return nil
            case .tiff72: return 72
            case .tiff144: return 144
            }
        }
    }

    public enum Fonts: Hashable, Sendable {
        /// The glyphs used, as Type 42 subsets.
        case embedSubset
        /// Every glyph of each font.
        case embedFull
        case outlines
        /// Font names only (`%%IncludeResource`); the printer supplies the fonts.
        case reference
    }

    public enum Colors: Hashable, Sendable {
        case keep
        case convertToCMYK
        case convertToRGB
    }

    public var level: Level
    public var preview: Preview
    public var fonts: Fonts
    public var colors: Colors
    public var preserveOverprint: Bool
    /// The embedded document package (IO-028).  Not written yet: reported.
    public var embedPackage: Bool
    /// Document Info as DSC header comments.
    public var includeDocumentInfo: Bool
    /// Pixels per inch for regions EPS cannot express; 0 uses the document's raster resolution.
    public var rasterPPI: Double
    /// Bands per gradient at Level 2 (the print settings' gradient steps).
    public var gradientSteps: Int

    public init(
        level: Level = .level3,
        preview: Preview = .none,
        fonts: Fonts = .embedSubset,
        colors: Colors = .keep,
        preserveOverprint: Bool = true,
        embedPackage: Bool = false,
        includeDocumentInfo: Bool = true,
        rasterPPI: Double = 0,
        gradientSteps: Int = 256
    ) {
        self.level = level
        self.preview = preview
        self.fonts = fonts
        self.colors = colors
        self.preserveOverprint = preserveOverprint
        self.embedPackage = embedPackage
        self.includeDocumentInfo = includeDocumentInfo
        self.rasterPPI = rasterPPI
        self.gradientSteps = gradientSteps
    }

    public static var defaults: EPSOptions { EPSOptions() }

    func validate() throws {
        guard rasterPPI >= 0 else {
            throw ExportError.invalidOption("The raster resolution cannot be negative.")
        }
        guard (2...4096).contains(gradientSteps) else {
            throw ExportError.invalidOption("Gradient steps must be 2 to 4,096.")
        }
    }
}
