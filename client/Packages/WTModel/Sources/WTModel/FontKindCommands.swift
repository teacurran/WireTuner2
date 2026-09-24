import WTCRDT
import WTGeometry
import WTProto
import WTRender

// FONT-002: the conversion commands (typeface-documents.adoc, "Converting a document to another
// kind", "Conversion commands"): to single-page, to multi-page, to typeface (with the font
// defaults written where never written and optionally the Basic Latin set) and to illustration
// (optionally copying every glyph's artwork onto its own em-square page).  Glyph nodes are never
// deleted or moved by a conversion, so converting back restores them.  Each is one change.

/// Why a conversion could not build its change.
public enum DocumentKindError: Error, Equatable, Sendable {
    /// A single-page document must have exactly one page (the sheet offers the Document panel).
    case tooManyPages(Int)
}

/// menu:File[Convert Document To]: one change writing `document_kind`.
public struct ConvertDocumentKind: Command {
    public struct Options: Hashable, Sendable {
        /// Convert to typeface: add the Basic Latin glyph set.
        public var addBasicLatin: Bool
        /// Convert to illustration: copy every glyph to its own page.
        public var copyGlyphsToPages: Bool

        public init(addBasicLatin: Bool = false, copyGlyphsToPages: Bool = false) {
            self.addBasicLatin = addBasicLatin
            self.copyGlyphsToPages = copyGlyphsToPages
        }
    }

    public var kind: DocumentKind
    public var options: Options

    public init(to kind: DocumentKind, options: Options = Options()) {
        self.kind = kind
        self.options = options
    }

    public var label: String {
        switch kind {
        case .singlePage: "Convert to single-page illustration"
        case .multiPage: "Convert to multi-page illustration"
        case .typeface: "Convert to typeface"
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let current = DocumentKind(state)
        if kind == .singlePage {
            let pages = DocumentKind.livePageCount(state)
            guard pages <= 1 else { throw DocumentKindError.tooManyPages(pages) }
        }
        let written = state.store.register(WellKnown.settings, FontFields.documentKind)?.value != nil
        if kind != current || !written {
            builder.append(Ops.set(WellKnown.settings, [FontFields.documentKind], values: FontFields.values { $0.documentKind = kind.stored }))
        }
        switch kind {
        case .typeface:
            FontDefaults.write(state: state, builder: &builder)
            if options.addBasicLatin {
                try GlyphSet.basicLatin.command().execute(&builder, state: state)
            }
        case .singlePage, .multiPage:
            if current == .typeface, options.copyGlyphsToPages {
                try GlyphPageCopies.copyAll(state: state, builder: &builder)
            }
        }
    }
}

/// The font defaults New Typeface and Convert to typeface write where a field was never written
/// (font-info.adoc: UPM 1000, ascender 800, descender −200, x-height 500, cap height 700, italic
/// angle 0, underline −100 / 50, line gap 0, version 1.000, weight 400, width 5, vendor WTNR,
/// embedding installable).
enum FontDefaults {
    static func write(state: EngineState, builder: inout ChangeBuilder, family: String? = nil, style: String? = nil, upm: Int? = nil) {
        func unwritten(_ path: RegisterPath) -> Bool {
            state.store.register(WellKnown.settings, path)?.value == nil
        }
        var paths: [RegisterPath] = []
        var values = FontFields.fontValues { _ in }
        let scale = Double(upm ?? FontInfo.defaultUPM) / Double(FontInfo.defaultUPM)
        // A zero default is not written: writing 0 clears a register, which reads as the default.
        for number in FontInfo.metricDefaults.keys.sorted() where FontInfo.metricDefaults[number] != 0
            && (unwritten(FontFields.metric(number)) || (number == 1 && upm != nil)) {
            paths.append(FontFields.metric(number))
            if number == 1 {
                values.settings.font.metrics.upm = UInt32(upm ?? FontInfo.defaultUPM)
            } else {
                FontMetricField(rawValue: number)!.set(FontInfo.metricDefaults[number]! * scale, in: &values.settings.font.metrics)
            }
        }
        if unwritten(FontFields.name(5)) {
            paths.append(FontFields.name(5))
            values.settings.font.names.version = FontInfo.defaultVersion
        }
        if let family {
            paths.append(FontFields.name(1))
            values.settings.font.names.family = String(family.prefix(63))
        }
        if let style {
            paths.append(FontFields.name(2))
            values.settings.font.names.style = String(style.prefix(63))
        }
        let os2: [(UInt32, (inout Wiretuner_Doc_V1_Os2Props) -> Void)] = [
            (1, { $0.weightClass = 400 }), (2, { $0.widthClass = 5 }), (3, { $0.vendorID = FontInfo.defaultVendor }), (6, { $0.embedding = .installable }),
        ]
        for (number, set) in os2 where unwritten(FontFields.os2(number)) {
            paths.append(FontFields.os2(number))
            set(&values.settings.font.os2)
        }
        guard !paths.isEmpty else { return }
        builder.append(Ops.set(WellKnown.settings, paths, values: values))
    }
}

/// *New Typeface*: turns a new document into a typeface with the family and style names, the
/// units per em (metrics scaled from the 1000-unit defaults) and a starting set, in one change.
public struct NewTypeface: Command {
    public var family: String
    public var style: String
    public var upm: Int
    public var set: GlyphSet?

    public init(family: String, style: String, upm: Int = FontInfo.defaultUPM, set: GlyphSet? = .basicLatin) {
        self.family = family
        self.style = style
        self.upm = upm
        self.set = set
    }

    public var label: String { "New typeface" }
    public var recordsUndo: Bool { false }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard FontInfo.upmRange.contains(upm) else { throw GlyphEditError.invalidValue("units per em") }
        builder.append(Ops.set(WellKnown.settings, [FontFields.documentKind], values: FontFields.values { $0.documentKind = .typeface }))
        FontDefaults.write(state: state, builder: &builder, family: family, style: style, upm: upm)
        if let set {
            // The set's default advance follows the UPM being written, not the state's.
            var glyphs = set.glyphs
            for index in glyphs.indices where glyphs[index].advanceWidth == nil {
                glyphs[index].advanceWidth = glyphs[index].kind == .mark ? 0 : GlyphEditing.defaultAdvance(upm: upm)
            }
            try AddGlyphs(glyphs, skipExisting: true).execute(&builder, state: state)
        }
    }
}
