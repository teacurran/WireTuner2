import Foundation
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

// FONT-014 / FONT-026 (model half): the glyph checks and the font-level validation list that the
// Find Problems panel and the Generate Fonts sheet show (glyph-editing.adoc, "Find Problems";
// font-export.adoc, "Validation").  Errors stop generation; warnings are listed.  Each problem
// names the glyph it is about, so a row can select it.

/// One validation result.
public struct FontProblem: Hashable, Sendable {
    public enum Level: Hashable, Sendable {
        case error, warning
    }

    public enum Kind: Hashable, Sendable {
        // Errors.
        case nameCollision
        case codepointCollision
        case invalidName
        case danglingComponent
        case componentLoop
        case componentTooDeep
        case invalidMetrics
        case emptyFamilyOrStyle
        case invalidPostScriptName
        case tooManyGlyphs
        // Warnings.
        case openContours
        case offGrid
        case missingExtrema
        case emptyGlyph
        case unusedBaseAnchor
        case markWithoutBase
        case duplicateAnchor
        case kerningOmitted
        case tooManyPoints
        case missingNotdef
        case missingSpace
        case featuresNotCompiled
        case attachmentNotCompiled
    }

    public var level: Level
    public var kind: Kind
    /// The glyph concerned, when there is one.
    public var glyph: OpID?
    public var message: String

    public init(_ level: Level, _ kind: Kind, glyph: OpID? = nil, _ message: String) {
        self.level = level
        self.kind = kind
        self.glyph = glyph
        self.message = message
    }
}

/// The checks.
public enum FontValidation {
    /// More points than this after flattening is a warning (font-export.adoc).
    public static let pointLimit = 1_500

    /// Every problem of the document's font, errors first, in grid order within each level.
    public static func problems(in state: EngineState, index: GlyphIndex? = nil, outlines: [OpID: GlyphOutline]? = nil) -> [FontProblem] {
        let index = index ?? GlyphIndex(state)
        let font = FontInfo(state)
        let outlines = outlines ?? Dictionary(uniqueKeysWithValues: GlyphFlattener.outlines(GlyphOutlines.sources(in: state, index: index)).map {
            (OpID($0.key), $0.value)
        })
        var result: [FontProblem] = []
        // Font level.
        if !font.metrics.isValid {
            result.append(FontProblem(.error, .invalidMetrics, "The ascender must be above the descender and the units per em between 16 and 16384."))
        }
        if font.names.family.isEmpty || font.names.style.isEmpty {
            result.append(FontProblem(.error, .emptyFamilyOrStyle, "The family and style names must not be empty."))
        }
        if !font.names.storedPostscript.isEmpty, !FontInfo.isValidPostScriptName(font.names.storedPostscript) {
            result.append(FontProblem(.error, .invalidPostScriptName, "The PostScript name \"\(font.names.storedPostscript)\" is not valid."))
        }
        result += glyphCountProblems(index.count)
        if index.glyph(named: ".notdef") == nil {
            result.append(FontProblem(.warning, .missingNotdef, "There is no .notdef glyph."))
        }
        if index.glyph(for: 0x20) == nil {
            result.append(FontProblem(.warning, .missingSpace, "There is no space glyph."))
        }
        if !Kerning(state, index: index).isEmpty, font.omitGeneratedKern {
            result.append(FontProblem(.warning, .kerningOmitted, "The font has kerning but Generate kern is off."))
        }
        if !font.features.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(FontProblem(.warning, .featuresNotCompiled, "The feature file is not compiled by the built-in compiler."))
        }
        // Glyph level.
        let marks = Set(index.glyphs.flatMap { $0.anchors.filter { $0.role == .mark && !$0.isDuplicate }.map(\.attachmentName) })
        let bases = Set(index.glyphs.flatMap { $0.anchors.filter { $0.role == .base && !$0.isDuplicate }.map(\.attachmentName) })
        if !marks.intersection(bases).isEmpty {
            result.append(FontProblem(.warning, .attachmentNotCompiled, "Mark attachment is not compiled by the built-in compiler."))
        }
        for glyph in index.glyphs {
            result += problems(of: glyph, outline: outlines[glyph.id, default: .empty], marks: marks, bases: bases)
        }
        return result.filter { $0.level == .error } + result.filter { $0.level == .warning }
    }

    /// The checks of one glyph (Find Problems for the current glyph).
    public static func problems(of glyph: Glyph, outline: GlyphOutline, marks: Set<String> = [], bases: Set<String> = []) -> [FontProblem] {
        var result: [FontProblem] = []
        let id = glyph.id
        switch glyph.nameStatus {
        case .duplicate: result.append(FontProblem(.error, .nameCollision, glyph: id, "Two glyphs are named \(glyph.storedName)."))
        case .invalid: result.append(FontProblem(.error, .invalidName, glyph: id, "The glyph name \"\(glyph.storedName)\" is not valid."))
        case .stored: break
        }
        for codepoint in glyph.lostCodepoints {
            result.append(FontProblem(.error, .codepointCollision, glyph: id, "Another glyph encodes U+\(String(format: "%04X", codepoint))."))
        }
        if glyph.components.contains(where: { $0.status == .dangling }) {
            result.append(FontProblem(.error, .danglingComponent, glyph: id, "\(glyph.name) uses a glyph that was removed."))
        }
        if glyph.components.contains(where: { $0.status == .loop }) {
            result.append(FontProblem(.error, .componentLoop, glyph: id, "\(glyph.name) uses itself through its components."))
        }
        if outline.report.depthExceeded {
            result.append(FontProblem(.error, .componentTooDeep, glyph: id, "\(glyph.name) nests components more than 8 deep."))
        }
        if outline.report.droppedOpenContours > 0 {
            result.append(FontProblem(.warning, .openContours, glyph: id, "\(glyph.name) has open paths without a stroke."))
        }
        let contours = GlyphContours.flipped(outline.path.contours)
        if GlyphContours.isOffGrid(contours) {
            result.append(FontProblem(.warning, .offGrid, glyph: id, "\(glyph.name) has points off the unit grid."))
        }
        if GlyphContours.isMissingExtrema(contours) {
            result.append(FontProblem(.warning, .missingExtrema, glyph: id, "\(glyph.name) is missing points at its extremes."))
        }
        let spaceLike = glyph.codepoints.contains { Unicode.Scalar($0)?.properties.isWhitespace == true } || glyph.name == "space"
            || glyph.name == ".notdef"
        if outline.path.isEmpty, !spaceLike, !glyph.skipExport {
            result.append(FontProblem(.warning, .emptyGlyph, glyph: id, "\(glyph.name) has no outline."))
        }
        if GlyphContours.pointCount(contours) > pointLimit {
            result.append(FontProblem(.warning, .tooManyPoints, glyph: id, "\(glyph.name) has more than \(pointLimit) points."))
        }
        for anchor in glyph.anchors {
            if anchor.isDuplicate {
                result.append(FontProblem(.warning, .duplicateAnchor, glyph: id, "\(glyph.name) has two anchors named \(anchor.storedName)."))
            } else if anchor.role == .base, !marks.contains(anchor.attachmentName) {
                result.append(FontProblem(.warning, .unusedBaseAnchor, glyph: id, "No mark attaches to \(glyph.name)'s \(anchor.name) anchor."))
            } else if anchor.role == .mark, !bases.contains(anchor.attachmentName) {
                result.append(FontProblem(.warning, .markWithoutBase, glyph: id, "No base has an anchor for \(glyph.name)'s \(anchor.name)."))
            }
        }
        return result
    }

    /// The format limit on the glyph count.
    static func glyphCountProblems(_ count: Int) -> [FontProblem] {
        count > FontCompiler.maximumGlyphs ? [FontProblem(.error, .tooManyGlyphs, "More than \(FontCompiler.maximumGlyphs) glyphs.")] : []
    }

    /// Whether any problem stops generation.
    public static func blocksGeneration(_ problems: [FontProblem]) -> Bool {
        problems.contains { $0.level == .error }
    }
}
