// FONT-018: the neutral input of the font compiler (font-export.adoc, "Pipeline"): a typeface
// snapshot as WTModel hands it over after validation and flattening -- names, metrics, OS/2
// fields, glyphs in glyph-id order with their finished outlines (font units, y up, cubic,
// counter-clockwise outer contours, extrema added, rounded to whole units), advance widths and
// codepoints, the kerning resolved to glyph indices, and the user's feature text.  WTModel builds
// it (`FontGeneration`); nothing here reads the document.

import WTGeometry

/// Everything the compiler needs to write one font.
public struct FontSource: Hashable, Sendable {
    /// The naming table entries; the generated names are already filled in.
    public struct Names: Hashable, Sendable {
        public var family: String
        public var style: String
        public var postscript: String
        public var full: String
        /// "1.000".
        public var version: String
        public var copyright: String = ""
        public var trademark: String = ""
        public var designer: String = ""
        public var designerURL: String = ""
        public var manufacturer: String = ""
        public var manufacturerURL: String = ""
        public var description: String = ""
        public var sampleText: String = ""
        public var license: String = ""
        public var licenseURL: String = ""

        public init(family: String, style: String, postscript: String, full: String, version: String = "1.000") {
            self.family = family
            self.style = style
            self.postscript = postscript
            self.full = full
            self.version = version
        }

        /// The version as a number (the `head` revision): 1.000 → 1.0.
        public var revision: Double {
            Double(version) ?? 1
        }
    }

    /// Vertical metrics in font units, y up.
    public struct Metrics: Hashable, Sendable {
        public var unitsPerEm: Int
        public var ascender: Double
        public var descender: Double
        public var xHeight: Double
        public var capHeight: Double
        /// Degrees, negative leaning right.
        public var italicAngle: Double
        public var underlinePosition: Double
        public var underlineThickness: Double
        public var lineGap: Double
        /// OS/2 usWinAscent; nil measures the outlines.
        public var winAscent: Double?
        /// OS/2 usWinDescent (positive below the baseline); nil measures the outlines.
        public var winDescent: Double?
        public var typoAscender: Double
        public var typoDescender: Double
        public var typoLineGap: Double

        public init(unitsPerEm: Int = 1_000, ascender: Double = 800, descender: Double = -200, xHeight: Double = 500, capHeight: Double = 700,
                    italicAngle: Double = 0, underlinePosition: Double = -100, underlineThickness: Double = 50, lineGap: Double = 0,
                    winAscent: Double? = nil, winDescent: Double? = nil, typoAscender: Double? = nil, typoDescender: Double? = nil,
                    typoLineGap: Double? = nil) {
            self.unitsPerEm = unitsPerEm
            self.ascender = ascender
            self.descender = descender
            self.xHeight = xHeight
            self.capHeight = capHeight
            self.italicAngle = italicAngle
            self.underlinePosition = underlinePosition
            self.underlineThickness = underlineThickness
            self.lineGap = lineGap
            self.winAscent = winAscent
            self.winDescent = winDescent
            self.typoAscender = typoAscender ?? ascender
            self.typoDescender = typoDescender ?? descender
            self.typoLineGap = typoLineGap ?? lineGap
        }
    }

    /// OS/2 fields.
    public struct OS2: Hashable, Sendable {
        public var weightClass: Int
        public var widthClass: Int
        /// Four printable ASCII characters.
        public var vendorID: String
        public var bold: Bool
        public var italic: Bool
        public var fsType: UInt16
        /// Ten bytes.
        public var panose: [UInt8]

        public init(weightClass: Int = 400, widthClass: Int = 5, vendorID: String = "WTNR", bold: Bool = false, italic: Bool = false,
                    fsType: UInt16 = 0, panose: [UInt8] = [UInt8](repeating: 0, count: 10)) {
            self.weightClass = weightClass
            self.widthClass = widthClass
            self.vendorID = vendorID
            self.bold = bold
            self.italic = italic
            self.fsType = fsType
            self.panose = panose
        }
    }

    /// One glyph.
    public struct Glyph: Hashable, Sendable {
        /// The PostScript glyph name.
        public var name: String
        public var codepoints: [UInt32]
        /// Font units.
        public var advanceWidth: Double
        /// Finished outlines: font units, y up, closed, counter-clockwise outer contours.
        public var contours: [Contour]

        public init(name: String, codepoints: [UInt32] = [], advanceWidth: Double, contours: [Contour] = []) {
            self.name = name
            self.codepoints = codepoints
            self.advanceWidth = advanceWidth
            self.contours = contours
        }

        /// The outline's bounds, nil when empty.
        public var bounds: Rect? {
            contours.isEmpty ? nil : contours.dropFirst().reduce(contours[0].controlBounds) { $0.union($1.controlBounds) }
        }
    }

    /// Kerning resolved to glyph indices (into `glyphs`).
    public struct Kerning: Hashable, Sendable {
        public struct Pair: Hashable, Sendable {
            public var left: Int
            public var right: Int
            /// Font units; negative tightens.
            public var value: Int

            public init(left: Int, right: Int, value: Int) {
                self.left = left
                self.right = right
                self.value = value
            }
        }

        public struct ClassValue: Hashable, Sendable {
            /// Index into `leftClasses`.
            public var left: Int
            /// Index into `rightClasses`.
            public var right: Int
            public var value: Int

            public init(left: Int, right: Int, value: Int) {
                self.left = left
                self.right = right
                self.value = value
            }
        }

        /// Exceptions: they win over the class values.
        public var pairs: [Pair]
        /// Glyph indices per class; a glyph is in at most one class per side.
        public var leftClasses: [[Int]]
        public var rightClasses: [[Int]]
        public var classValues: [ClassValue]

        public init(pairs: [Pair] = [], leftClasses: [[Int]] = [], rightClasses: [[Int]] = [], classValues: [ClassValue] = []) {
            self.pairs = pairs
            self.leftClasses = leftClasses
            self.rightClasses = rightClasses
            self.classValues = classValues
        }

        public var isEmpty: Bool {
            pairs.isEmpty && classValues.isEmpty
        }

        /// The kerning between glyphs `left` and `right` by the model's lookup rule: the pair,
        /// else the class value, else 0.
        public func value(_ left: Int, _ right: Int) -> Int {
            if let pair = pairs.first(where: { $0.left == left && $0.right == right }) { return pair.value }
            guard let l = leftClasses.firstIndex(where: { $0.contains(left) }), let r = rightClasses.firstIndex(where: { $0.contains(right) })
            else { return 0 }
            return classValues.first { $0.left == l && $0.right == r }?.value ?? 0
        }
    }

    public var names: Names
    public var metrics: Metrics
    public var os2: OS2
    /// Glyph 0 is `.notdef`.
    public var glyphs: [Glyph]
    public var kerning: Kerning
    /// The user's feature file (the built-in compiler does not compile it; see `FontCompiler`).
    public var features: String

    public init(names: Names, metrics: Metrics = Metrics(), os2: OS2 = OS2(), glyphs: [Glyph], kerning: Kerning = Kerning(), features: String = "") {
        self.names = names
        self.metrics = metrics
        self.os2 = os2
        self.glyphs = glyphs
        self.kerning = kerning
        self.features = features
    }
}
