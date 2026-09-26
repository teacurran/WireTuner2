// FONT-018 / FONT-019: the font compiler (font-export.adoc, "Font compiler decision", as built: see
// the deviation recorded there).  A `FontSource` becomes an OpenType font in memory, in Swift, with
// no third-party code: OTF (CFF outlines, cubic as drawn) or TTF (quadratic outlines within half a
// unit), the metric, naming, character-map and PostScript tables, and the layout tables compiled
// from feature text: the user's feature file followed by `FeatureGenerator`'s kern, mark, mkmk,
// liga and GDEF text, through `FeatureCompiler` into GSUB, GPOS and GDEF.  Errors in the user's
// text stop the compile with their line and column (generation is blocked until the file checks
// clean, never silently).  Compilation is synchronous and fast; the async entry point runs it off
// the caller's actor, checks for cancellation between glyphs and tables, and returns the bytes
// with the diagnostics.

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
            let report = FeatureChecker.check(source.features, glyphs: source.glyphs.map(\.name), generated: FeatureGenerator.generatedTags(source))
            result += report.issues.filter { $0.kind != .generated }.map(diagnostic)
        }
        return result
    }

    /// A feature-text issue as a compile diagnostic at its line and column.
    static func diagnostic(_ issue: FeatureIssue) -> Diagnostic {
        Diagnostic(issue.severity == .error ? .error : .warning, issue.message, glyph: issue.kind == .unknownGlyph ? issue.name : nil,
                   line: issue.location.line, column: issue.location.column)
    }

    /// The layout tables of `source`: its feature text and the generated features compiled
    /// together.  The user's text has already checked clean, so a problem here is a generator bug
    /// (reported as an error on no line).
    static func layoutTables(_ source: FontSource) throws -> [String: [UInt8]] {
        let file = FeatureGenerator.file(user: source.features, generated: FeatureGenerator.generated(source))
        guard !file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        let compiled = FeatureCompiler.compile(file.text, glyphs: source.glyphs.map(\.name))
        let errors = compiled.issues.filter { $0.severity == .error }
        guard errors.isEmpty else {
            throw Failure.invalidSource(errors.map { issue in
                file.userLocation(issue.location).map { diagnostic(FeatureIssue(issue.severity, issue.kind, issue.message, at: $0, name: issue.name)) }
                    ?? Diagnostic(.error, "Generated features: \(issue.message)")
            })
        }
        var tables: [String: [UInt8]] = [:]
        if let gsub = compiled.gsub { tables["GSUB"] = gsub }
        if let gpos = compiled.gpos { tables["GPOS"] = gpos }
        if let gdef = compiled.gdef { tables["GDEF"] = gdef }
        return tables
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
        let layout = try layoutTables(source)
        guard !isCancelled() else { throw Failure.cancelled }
        tables["head"] = FontTables.head(source, records: records, longLoca: longLoca, created: options.date)
        tables["hhea"] = FontTables.hhea(source, records: records)
        tables["hmtx"] = FontTables.hmtx(records)
        tables["OS/2"] = FontTables.os2(source, records: records, hasKerning: layout["GPOS"] != nil)
        tables["name"] = FontTables.name(source)
        tables["cmap"] = FontTables.cmap(map)
        tables["post"] = FontTables.post(source, names: options.format == .ttf)
        tables.merge(layout) { $1 }
        let data = FontTables.assemble(tables, signature: options.format == .otf ? 0x4F54_544F : 0x0001_0000)
        return Result(data: data, diagnostics: diagnostics)
    }
}
