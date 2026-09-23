// SVG export options (export-vector.adoc, "SVG options"; `SvgOptions` in
// interchange/v1/export_options.proto) and the element ids the writer derives from names.

import Foundation

/// The SVG options sheet.
public struct SVGOptions: ExportOptions, Hashable {
    public enum Text: Hashable, Sendable {
        /// `<text>` with font names.
        case asText
        /// Paths.
        case outlines
        /// `<text>` plus the used glyphs as embedded web fonts, where licenses allow.
        case asTextEmbedFonts
    }

    public enum Ids: Hashable, Sendable {
        /// Object and layer names, made safe and unique.
        case fromNames
        case none
        /// Short unique ids.
        case generated
    }

    public enum Styling: Hashable, Sendable {
        /// `fill="#…"` on each element.
        case presentationAttributes
        /// Repeated styles collected into a `<style>` block.
        case cssClasses
        /// `style="…"` attributes.
        case inlineStyle
    }

    public enum Images: Hashable, Sendable {
        /// Data URLs.
        case embed
        /// Separate files in a folder named after the SVG.
        case link
        /// As `link`, copying placed JPEGs unchanged.
        case linkOriginals
    }

    /// Decimal places for coordinates, 1 ... 6.
    public var precision: Int
    public var text: Text
    public var ids: Ids
    public var styling: Styling
    /// Only a `viewBox`; otherwise `width` and `height` in `sizeUnit` too.  Off by default: a
    /// view box alone is read at 96 user units per inch (CSS pixels), which would shrink the
    /// points-based view box to 75%, so the default file states its size in points.
    public var responsive: Bool
    /// `pt` (the default), `px`, `mm` or `in`.
    public var sizeUnit: String
    public var images: Images
    /// Pixels per inch for regions SVG cannot express; 0 uses the document's raster resolution.
    public var rasterPPI: Double
    public var pageBackground: Bool
    /// Symbols as plain artwork.  The display list carries symbol instances expanded, so every
    /// export is expanded today.
    public var expandSymbols: Bool
    public var minify: Bool
    public var includeDocumentInfo: Bool

    public init(
        precision: Int = 3,
        text: Text = .asText,
        ids: Ids = .fromNames,
        styling: Styling = .presentationAttributes,
        responsive: Bool = false,
        sizeUnit: String = "pt",
        images: Images = .embed,
        rasterPPI: Double = 0,
        pageBackground: Bool = false,
        expandSymbols: Bool = false,
        minify: Bool = false,
        includeDocumentInfo: Bool = true
    ) {
        self.precision = precision
        self.text = text
        self.ids = ids
        self.styling = styling
        self.responsive = responsive
        self.sizeUnit = sizeUnit
        self.images = images
        self.rasterPPI = rasterPPI
        self.pageBackground = pageBackground
        self.expandSymbols = expandSymbols
        self.minify = minify
        self.includeDocumentInfo = includeDocumentInfo
    }

    public static var defaults: SVGOptions { SVGOptions() }

    /// Rejects values outside the sheet's ranges.
    func validate() throws {
        guard (1...6).contains(precision) else {
            throw ExportError.invalidOption("SVG precision must be 1 to 6 decimal places.")
        }
        guard SVGOptions.unitScale[sizeUnit] != nil else {
            throw ExportError.invalidOption("SVG size unit must be px, pt, mm or in.")
        }
        guard rasterPPI >= 0 else {
            throw ExportError.invalidOption("The raster resolution cannot be negative.")
        }
    }

    /// Units per point for the fixed-size units.  The view box is always in points (one SVG user
    /// unit per point); `pt`, `mm` and `in` give the true physical size to any reader.  A pixel
    /// is one point, as in Illustrator and every design tool, so a `px`-sized file keeps its
    /// pixel dimensions on the web and reads at 75% of its point size elsewhere.
    static let unitScale: [String: Double] = ["px": 1, "pt": 1, "mm": 25.4 / 72, "in": 1 / 72]
}

/// Element ids: sanitized names made unique, and generated ids that never collide with them.
struct SVGIdentifiers {
    private var used = Set<String>()
    private var counters: [String: Int] = [:]

    /// `name` as an XML id (`[A-Za-z_][A-Za-z0-9_-]*`): other characters become `_`, a leading
    /// digit or hyphen gets a `_` prefix.  Nil when nothing usable remains.
    static func sanitize(_ name: String) -> String? {
        var result = ""
        for scalar in name.unicodeScalars {
            let ascii = scalar.isASCII ? Character(scalar) : "_"
            result.append(ascii.isLetter || ascii.isNumber || ascii == "_" || ascii == "-" ? ascii : "_")
        }
        guard result.contains(where: { $0 != "_" }) else {
            return nil
        }
        if let first = result.first, first.isNumber || first == "-" {
            result = "_" + result
        }
        return result
    }

    /// A unique id for `name`: `Logo`, then `Logo-2`, `Logo-3`…
    mutating func unique(_ name: String) -> String? {
        guard let base = SVGIdentifiers.sanitize(name) else {
            return nil
        }
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    /// Reserves ids already taken (the names) before generating others.
    mutating func reserve(_ id: String) {
        used.insert(id)
    }

    /// A fresh id with `prefix` (`wt-g1`, `wt-g2`…) that no name id uses.
    mutating func generate(_ prefix: String) -> String {
        var counter = counters[prefix, default: 0] + 1
        while used.contains("\(prefix)\(counter)") {
            counter += 1
        }
        counters[prefix] = counter
        let id = "\(prefix)\(counter)"
        used.insert(id)
        return id
    }
}
