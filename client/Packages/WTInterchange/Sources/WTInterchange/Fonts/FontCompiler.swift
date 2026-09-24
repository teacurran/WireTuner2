// FONT-018: the font compiler (font-export.adoc, "Font compiler decision", as built: see the
// deviation recorded there).  A `FontSource` becomes an OpenType font in memory, in Swift, with no
// third-party code: OTF (CFF outlines, cubic as drawn) or TTF (quadratic outlines within half a
// unit), the metric, naming, character-map and PostScript tables, and the kerning model compiled
// straight into GPOS.  The user's feature file is not compiled by this compiler (there is no
// feature-file compiler in it); a non-empty one is reported as a warning so generation still
// succeeds.  Compilation is synchronous and fast; the async entry point runs it off the caller's
// actor, checks for cancellation between glyphs and tables, and returns the bytes with the
// diagnostics.

import Foundation
import WTGeometry

/// Compiles typeface snapshots to font files.
public struct FontCompiler: Sendable {
    /// The outline flavour.
    public enum Format: Hashable, Sendable, CaseIterable {
        /// OpenType with PostScript (CFF) outlines.
        case otf
        /// OpenType with TrueType (glyf) outlines.
        case ttf

        /// The file extension.
        public var fileExtension: String {
            self == .otf ? "otf" : "ttf"
        }
    }

    public struct Options: Hashable, Sendable {
        public var format: Format
        /// The `head` creation and modification date; nil writes zero so identical sources give
        /// identical bytes on every client.
        public var date: Date?

        public init(format: Format = .otf, date: Date? = nil) {
            self.format = format
            self.date = date
        }
    }

    /// A message about the compile, mapped to a glyph or a feature-file line when it has one.
    public struct Diagnostic: Hashable, Sendable {
        public enum Severity: Hashable, Sendable {
            case error, warning
        }

        public var severity: Severity
        public var message: String
        /// The glyph concerned, by name.
        public var glyph: String?
        /// The feature-file line and column (1-based), when the message is about the text.
        public var line: Int?
        public var column: Int?

        public init(_ severity: Severity, _ message: String, glyph: String? = nil, line: Int? = nil, column: Int? = nil) {
            self.severity = severity
            self.message = message
            self.glyph = glyph
            self.line = line
            self.column = column
        }
    }

    /// A compiled font.
    public struct Result: Hashable, Sendable {
        public var data: Data
        public var diagnostics: [Diagnostic]
    }

    /// Why nothing was compiled.
    public enum Failure: Error, Hashable, Sendable {
        /// The source has errors; nothing was written.
        case invalidSource([Diagnostic])
        /// The task was cancelled.
        case cancelled
    }

    /// Format limits (font-export.adoc, "Validation").
    public static let maximumGlyphs = 65_535

    public init() {}

    /// Compiles `source` off the caller's actor.
    public func compile(_ source: FontSource, options: Options = Options()) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            try Self.compile(source, options: options, isCancelled: { Task.isCancelled })
        }.value
    }

    /// The quick compile the Metrics window and the Features pop-up preview through: the same
    /// compile, in memory, as OTF (FONT-020 loads the bytes with Core Text).
    public func quickCompile(_ source: FontSource) async throws -> Result {
        try await compile(source, options: Options(format: .otf))
    }

    /// The problems that stop a compile (and the warnings that do not).
    public static func check(_ source: FontSource) -> [Diagnostic] {
        var result: [Diagnostic] = []
        if source.glyphs.isEmpty || source.glyphs[0].name != ".notdef" {
            result.append(Diagnostic(.error, "The first glyph must be .notdef."))
        }
        if source.glyphs.count > maximumGlyphs {
            result.append(Diagnostic(.error, "More than \(maximumGlyphs) glyphs."))
        }
        if !(16...16_384).contains(source.metrics.unitsPerEm) {
            result.append(Diagnostic(.error, "Units per em must be between 16 and 16384."))
        }
        if source.metrics.ascender <= source.metrics.descender {
            result.append(Diagnostic(.error, "The ascender must be above the descender."))
        }
        if source.names.family.isEmpty || source.names.style.isEmpty {
            result.append(Diagnostic(.error, "The family and style names must not be empty."))
        }
        let postscript = source.names.postscript
        if postscript.isEmpty || postscript.utf8.count > 63 || !postscript.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F && !"[](){}<>/%".unicodeScalars.contains($0) }) {
            result.append(Diagnostic(.error, "Invalid PostScript name."))
        }
        var names: Set<String> = []
        var codepoints: Set<UInt32> = []
        for glyph in source.glyphs {
            if !names.insert(glyph.name).inserted { result.append(Diagnostic(.error, "Two glyphs are named \(glyph.name).", glyph: glyph.name)) }
            for codepoint in glyph.codepoints where !codepoints.insert(codepoint).inserted {
                result.append(Diagnostic(.error, String(format: "Two glyphs encode U+%04X.", codepoint), glyph: glyph.name))
            }
        }
        if !source.features.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(Diagnostic(.warning, "The feature file is not compiled by the built-in compiler; kerning is generated from the kerning model.",
                                     line: 1, column: 1))
        }
        return result
    }

    /// Compiles `source` now.
    public static func compile(_ source: FontSource, options: Options = Options(), isCancelled: () -> Bool = { false }) throws -> Result {
        let diagnostics = check(source)
        guard !diagnostics.contains(where: { $0.severity == .error }) else { throw Failure.invalidSource(diagnostics) }
        guard !isCancelled() else { throw Failure.cancelled }
        var tables: [String: [UInt8]] = [:]
        let records: [GlyphMetricsRecord]
        let longLoca: Bool
        switch options.format {
        case .otf:
            let cff = CFFWriter(source)
            tables["CFF "] = cff.table
            records = cff.records
            longLoca = false
            tables["maxp"] = FontTables.maxpCFF(glyphs: source.glyphs.count)
        case .ttf:
            let glyphs = TrueTypeGlyphs(source)
            tables["glyf"] = glyphs.glyf
            tables["loca"] = glyphs.loca
            records = glyphs.records
            longLoca = glyphs.longLoca
            tables["maxp"] = FontTables.maxpTrueType(glyphs: source.glyphs.count, maxPoints: glyphs.maxPoints, maxContours: glyphs.maxContours)
        }
        guard !isCancelled() else { throw Failure.cancelled }
        var map: [UInt32: Int] = [:]
        for (index, glyph) in source.glyphs.enumerated() {
            for codepoint in glyph.codepoints { map[codepoint] = index }
        }
        let gpos = GPOSKerning.table(source.kerning, glyphCount: source.glyphs.count)
        tables["head"] = FontTables.head(source, records: records, longLoca: longLoca, created: options.date)
        tables["hhea"] = FontTables.hhea(source, records: records)
        tables["hmtx"] = FontTables.hmtx(records)
        tables["OS/2"] = FontTables.os2(source, records: records, hasKerning: gpos != nil)
        tables["name"] = FontTables.name(source)
        tables["cmap"] = FontTables.cmap(map)
        tables["post"] = FontTables.post(source, names: options.format == .ttf)
        if let gpos { tables["GPOS"] = gpos }
        let data = FontTables.assemble(tables, signature: options.format == .otf ? 0x4F54_544F : 0x0001_0000)
        return Result(data: data, diagnostics: diagnostics)
    }
}
