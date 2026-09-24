import WTCRDT
import WTProto
import WTRender

// FONT-005: the typed view over `settings.font` with its defaults and read-time normalizations
// (font-info.adoc, "Data model", "Read-time normalizations").  Every `FontProps` scalar is an
// ATOMIC register; a field never written reads as its default, a written value as written.

/// The font-level settings of a typeface document as read.
public struct FontInfo: Hashable, Sendable {
    /// The naming table entries, with the generated names filled in.
    public struct Names: Hashable, Sendable {
        public var family: String
        public var style: String
        /// The effective PostScript name: the stored one when it is valid, else generated from
        /// family and style.
        public var postscript: String
        /// The stored PostScript name ("" = generated).
        public var storedPostscript: String
        /// The effective full name: stored, else "Family Style".
        public var full: String
        public var version: String
        public var copyright: String
        public var trademark: String
        public var designer: String
        public var designerURL: String
        public var manufacturer: String
        public var manufacturerURL: String
        public var description: String
        public var sampleText: String
        public var license: String
        public var licenseURL: String
    }

    /// The vertical metrics, font units, y up.
    public struct Metrics: Hashable, Sendable {
        public var upm: Int
        public var ascender: Double
        public var descender: Double
        public var xHeight: Double
        public var capHeight: Double
        public var italicAngle: Double
        public var underlinePosition: Double
        public var underlineThickness: Double
        public var lineGap: Double
        /// OS/2 usWinAscent as typed; nil = computed from the outlines at generate time.
        public var winAscent: Double?
        public var winDescent: Double?
        public var typoSeparate: Bool
        /// The effective typo metrics: the typed ones when `typoSeparate`, else ascender,
        /// descender and line gap.
        public var typoAscender: Double
        public var typoDescender: Double
        public var typoLineGap: Double

        /// Whether the metrics can generate: ascender above descender, UPM in range.
        public var isValid: Bool {
            ascender > descender && FontInfo.upmRange.contains(upm)
        }
    }

    /// OS/2 embedding permission.
    public enum Embedding: Hashable, Sendable, CaseIterable {
        case installable, editable, previewPrint, restricted

        init(_ stored: Wiretuner_Doc_V1_Embedding) {
            switch stored {
            case .editable: self = .editable
            case .previewPrint: self = .previewPrint
            case .restricted: self = .restricted
            default: self = .installable
            }
        }

        public var stored: Wiretuner_Doc_V1_Embedding {
            switch self {
            case .installable: .installable
            case .editable: .editable
            case .previewPrint: .previewPrint
            case .restricted: .restricted
            }
        }

        /// The OS/2 `fsType` permission bits.
        public var fsType: UInt16 {
            switch self {
            case .installable: 0
            case .editable: 8
            case .previewPrint: 4
            case .restricted: 2
            }
        }
    }

    /// OS/2 fields.
    public struct OS2: Hashable, Sendable {
        public var weightClass: Int
        public var widthClass: Int
        public var vendorID: String
        public var bold: Bool
        public var italic: Bool
        public var embedding: Embedding
        public var noSubsetting: Bool
        public var bitmapEmbeddingOnly: Bool
        /// Ten bytes.
        public var panose: [UInt8]

        /// `fsType` with the subsetting bits.
        public var fsType: UInt16 {
            embedding.fsType | (noSubsetting ? 0x0100 : 0) | (bitmapEmbeddingOnly ? 0x0200 : 0)
        }
    }

    /// A named extra metric line.
    public struct ExtraLine: Hashable, Sendable, Identifiable {
        public var id: OpID
        public var name: String
        /// Font units, y up.
        public var y: Double
    }

    /// Which metric guides show.
    public struct Guides: Hashable, Sendable {
        public var showBaseline: Bool
        public var showXHeight: Bool
        public var showCapHeight: Bool
        public var showAscender: Bool
        public var showDescender: Bool
        public var showSideBearings: Bool
        public var showEmBox: Bool
        public var showLabels: Bool
        public var baselineColor: Color?
        public var metricColor: Color?
        public var bearingColor: Color?
        public var extraLines: [ExtraLine]
    }

    public static let upmRange = 16...16_384
    public static let defaultUPM = 1_000
    public static let defaultVersion = "1.000"
    public static let defaultVendor = "WTNR"

    /// The metric defaults New Typeface and Convert to typeface write, keyed by `FontMetrics`
    /// field number (upm 1, ascender 2, descender 3, x-height 4, cap height 5, italic angle 6,
    /// underline position 7, thickness 8, line gap 9).
    public static let metricDefaults: [UInt32: Double] = [1: 1_000, 2: 800, 3: -200, 4: 500, 5: 700, 6: 0, 7: -100, 8: 50, 9: 0]

    public var names: Names
    public var metrics: Metrics
    public var os2: OS2
    public var guides: Guides
    public var omitGeneratedKern: Bool
    public var omitGeneratedMark: Bool
    public var omitGeneratedLiga: Bool
    /// The feature file as plain text, NUL and other C0 controls but tab and newline stripped.
    public var features: String

    public init(_ state: EngineState) {
        let font = state.props(WellKnown.settings).settings.font
        func written(_ path: RegisterPath) -> Bool {
            state.store.register(WellKnown.settings, path)?.value != nil
        }
        func metric(_ number: UInt32, _ value: Double) -> Double {
            guard written(FontFields.metric(number)) else { return Self.metricDefaults[number, default: 0] }
            return value.isFinite ? value : 0
        }
        let text = state.store.text(WellKnown.settings, FontFields.features)?.string ?? ""
        self.init(font, metric: metric, features: text)
    }

    /// The view of `font` as a typed message: fields at their proto3 defaults read as written
    /// unless `metric` says otherwise (the state initializer passes the written test).
    public init(_ font: Wiretuner_Doc_V1_FontProps, metric: ((UInt32, Double) -> Double)? = nil, features: String = "") {
        let metric = metric ?? { number, value in value == 0 ? Self.metricDefaults[number, default: 0] : value }
        let stored = font.names
        let family = stored.family
        let style = stored.style
        names = Names(
            family: family, style: style,
            postscript: Self.isValidPostScriptName(stored.postscript) ? stored.postscript : Self.generatedPostScriptName(family: family, style: style),
            storedPostscript: stored.postscript,
            full: stored.full.isEmpty ? Self.generatedFullName(family: family, style: style) : stored.full,
            version: Self.isValidVersion(stored.version) ? stored.version : Self.defaultVersion,
            copyright: stored.copyright, trademark: stored.trademark, designer: stored.designer, designerURL: stored.designerURL,
            manufacturer: stored.manufacturer, manufacturerURL: stored.manufacturerURL, description: stored.description_p,
            sampleText: stored.sampleText, license: stored.license, licenseURL: stored.licenseURL
        )
        let m = font.metrics
        let ascender = metric(2, m.ascender)
        let descender = metric(3, m.descender)
        let lineGap = metric(9, m.lineGap)
        func optional(_ value: Wiretuner_Doc_V1_OptionalMetric?) -> Double? {
            guard let value, !value.computed, value.value.isFinite else { return nil }
            return value.value
        }
        metrics = Metrics(
            upm: m.upm == 0 ? Self.defaultUPM : Int(m.upm), ascender: ascender, descender: descender, xHeight: metric(4, m.xHeight),
            capHeight: metric(5, m.capHeight), italicAngle: min(max(metric(6, m.italicAngle), -90), 90),
            underlinePosition: metric(7, m.underlinePosition), underlineThickness: max(metric(8, m.underlineThickness), 0), lineGap: lineGap,
            winAscent: optional(m.hasWinAscent ? m.winAscent : nil), winDescent: optional(m.hasWinDescent ? m.winDescent : nil),
            typoSeparate: m.typoSeparate,
            typoAscender: m.typoSeparate ? Self.finite(m.typoAscender) : ascender,
            typoDescender: m.typoSeparate ? Self.finite(m.typoDescender) : descender,
            typoLineGap: m.typoSeparate ? Self.finite(m.typoLineGap) : lineGap
        )
        let o = font.os2
        os2 = OS2(
            weightClass: o.weightClass == 0 ? 400 : Int(min(o.weightClass, 1_000)), widthClass: o.widthClass == 0 ? 5 : Int(min(o.widthClass, 9)),
            vendorID: Self.isValidVendor(o.vendorID) ? o.vendorID : Self.defaultVendor, bold: o.styleBold, italic: o.styleItalic,
            embedding: Embedding(o.embedding), noSubsetting: o.noSubsetting, bitmapEmbeddingOnly: o.bitmapEmbeddingOnly,
            panose: o.panose.count == 10 ? [UInt8](o.panose) : [UInt8](repeating: 0, count: 10)
        )
        let g = font.guides
        guides = Guides(
            showBaseline: !g.hideBaseline, showXHeight: !g.hideXHeight, showCapHeight: !g.hideCapHeight, showAscender: !g.hideAscender,
            showDescender: !g.hideDescender, showSideBearings: !g.hideSideBearings, showEmBox: !g.hideEmBox, showLabels: !g.hideLabels,
            baselineColor: g.hasBaselineColor ? Appearances.color(g.baselineColor) : nil,
            metricColor: g.hasMetricColor ? Appearances.color(g.metricColor) : nil,
            bearingColor: g.hasBearingColor ? Appearances.color(g.bearingColor) : nil,
            extraLines: g.extraLines.map { line in
                ExtraLine(id: OpID(sequenceElement: line.id), name: line.name.isEmpty ? "Line" : line.name, y: Self.finite(line.y))
            }
        )
        omitGeneratedKern = font.omitGeneratedKern
        omitGeneratedMark = font.omitGeneratedMark
        omitGeneratedLiga = font.omitGeneratedLiga
        self.features = Self.plain(features)
    }

    static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    /// `text` without NUL and other C0 controls except tab and newline.
    static func plain(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" || $0 == "\n" }))
    }

    // MARK: Names

    /// The PostScript name pattern: ASCII letters, digits, `.`, `_`, `-`; 1 to 63 characters.
    public static func isValidPostScriptName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 63 && name.unicodeScalars.allSatisfy(isPostScriptCharacter)
    }

    static func isPostScriptCharacter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
            || scalar == "." || scalar == "_" || scalar == "-"
    }

    /// "Family-Style" with spaces and other disallowed characters dropped, 63 characters at most;
    /// "Untitled" for an empty family.
    public static func generatedPostScriptName(family: String, style: String) -> String {
        func clean(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter { isPostScriptCharacter($0) && $0 != "-" }))
        }
        let base = clean(family).isEmpty ? "Untitled" : clean(family)
        let suffix = clean(style)
        return String((suffix.isEmpty ? base : "\(base)-\(suffix)").prefix(63))
    }

    /// "Family Style" (just the family when there is no style).
    public static func generatedFullName(family: String, style: String) -> String {
        let base = family.isEmpty ? "Untitled" : family
        return style.isEmpty ? base : "\(base) \(style)"
    }

    /// `1.000`: digits, a point, three digits.
    public static func isValidVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return version.count <= 16 && parts.count == 2 && !parts[0].isEmpty && parts[1].count == 3
            && parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// Four printable ASCII characters.
    public static func isValidVendor(_ vendor: String) -> Bool {
        vendor.unicodeScalars.count == 4 && vendor.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
    }
}
