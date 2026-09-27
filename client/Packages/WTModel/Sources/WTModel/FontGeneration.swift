import Foundation
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

// FONT-026 (model half) / FONT-015: the generate pipeline's model steps (font-export.adoc,
// "Pipeline"): an immutable snapshot of the typeface read from the state, validation, every
// exported glyph flattened (components resolved, strokes expanded, overlaps unioned unless kept),
// flipped into the font's y-up convention, turned counter-clockwise, given points at its extremes
// and rounded to whole units; the standard glyphs synthesized when asked; the kerning resolved to
// glyph indices with the classes' names; since FONT-019 each glyph's kind and anchors and the
// Features pane's generate switches, so the automatic features compile from the document; then
// `WTInterchange.FontCompiler` writes the bytes.  Generation never changes the
// document.

/// The Generate Fonts sheet's options that reach the model.
public struct FontGenerationOptions: Hashable, Sendable {
    /// *Add .notdef, space, NULL and CR* when missing (on by default).
    public var addStandardGlyphs: Bool
    /// *Keep overlaps*: contours as drawn, not unioned.
    public var keepOverlaps: Bool
    /// *Selected glyphs only*: the glyphs to include (nil: all exported glyphs).
    public var glyphs: Set<OpID>?
    /// *Add "Test" to the family name* (Install for Testing): "Marlowe Test", "MarloweTest-Regular".
    public var testSuffix: Bool

    public init(addStandardGlyphs: Bool = true, keepOverlaps: Bool = false, glyphs: Set<OpID>? = nil, testSuffix: Bool = false) {
        self.addStandardGlyphs = addStandardGlyphs
        self.keepOverlaps = keepOverlaps
        self.glyphs = glyphs
        self.testSuffix = testSuffix
    }
}

/// Why generation stopped.
public enum FontGenerationError: Error, Hashable, Sendable {
    /// Validation found errors; the list holds every problem.
    case invalid([FontProblem])
}

/// Building the compiler's input from a typeface document.
public enum FontGeneration {
    /// The glyphs of the font in glyph-id order with the document glyph each came from (nil for
    /// a synthesized standard glyph).
    public struct Snapshot: Hashable, Sendable {
        public var source: FontSource
        public var glyphs: [OpID?]
        public var problems: [FontProblem]
    }

    /// The compiler input of the document's font, with the validation list.
    public static func snapshot(_ state: EngineState, options: FontGenerationOptions = FontGenerationOptions()) -> Snapshot {
        snapshot(state, options: options, flatten: true)
    }

    /// What the feature generator reads of the document's font -- glyph names, kinds, anchors,
    /// kerning, the generate switches -- without flattening any outline (the Features editor's
    /// *Generated* pane, FONT-022).  Glyphs have no contours and there is no validation list.
    public static func featureSource(_ state: EngineState) -> FontSource {
        snapshot(state, options: FontGenerationOptions(), flatten: false).source
    }

    static func snapshot(_ state: EngineState, options: FontGenerationOptions, flatten: Bool) -> Snapshot {
        let index = GlyphIndex(state)
        let font = FontInfo(state)
        let flattened = flatten
            ? GlyphFlattener.outlines(GlyphOutlines.sources(in: state, index: index), options: .init(keepOverlaps: options.keepOverlaps)) : [:]
        let outlines = Dictionary(uniqueKeysWithValues: flattened.map { (OpID($0.key), $0.value) })
        let problems = flatten ? FontValidation.problems(in: state, index: index, outlines: outlines) : []
        let upm = Double(font.metrics.upm)
        var glyphs: [FontSource.Glyph] = []
        var origins: [OpID?] = []
        let exported = index.glyphs.filter { !$0.skipExport && (options.glyphs?.contains($0.id) ?? true) }
        func add(_ glyph: FontSource.Glyph, from origin: OpID?) {
            glyphs.append(glyph)
            origins.append(origin)
        }
        // .notdef is glyph 0: the document's, or a synthesized box.
        if let notdef = exported.first(where: { $0.name == ".notdef" }) {
            add(sourceGlyph(notdef, outline: outlines[notdef.id]), from: notdef.id)
        } else if options.addStandardGlyphs {
            add(notdefGlyph(font), from: nil)
        } else {
            add(FontSource.Glyph(name: ".notdef", advanceWidth: 0), from: nil)
        }
        for glyph in exported where glyph.name != ".notdef" {
            add(sourceGlyph(glyph, outline: outlines[glyph.id]), from: glyph.id)
        }
        if options.addStandardGlyphs {
            let spaceWidth = glyphs.first { $0.codepoints.contains(0x20) }?.advanceWidth ?? (250 * upm / 1_000).rounded()
            let names = Set(glyphs.map(\.name))
            let codepoints = Set(glyphs.flatMap(\.codepoints))
            for (name, codepoint, width) in [("space", UInt32(0x20), spaceWidth), ("NULL", 0x00, 0), ("CR", 0x0D, spaceWidth)]
            where !names.contains(name) && !codepoints.contains(codepoint) {
                add(FontSource.Glyph(name: name, codepoints: [codepoint], advanceWidth: width), from: nil)
            }
        }
        var names = FontSource.Names(family: font.names.family, style: font.names.style, postscript: font.names.postscript, full: font.names.full,
                                     version: font.names.version)
        if options.testSuffix {
            names.family += " Test"
            names.full = FontInfo.generatedFullName(family: names.family, style: names.style)
            names.postscript = FontInfo.generatedPostScriptName(family: names.family, style: names.style)
        }
        names.copyright = font.names.copyright
        names.trademark = font.names.trademark
        names.designer = font.names.designer
        names.designerURL = font.names.designerURL
        names.manufacturer = font.names.manufacturer
        names.manufacturerURL = font.names.manufacturerURL
        names.description = font.names.description
        names.sampleText = font.names.sampleText
        names.license = font.names.license
        names.licenseURL = font.names.licenseURL
        let m = font.metrics
        let metrics = FontSource.Metrics(
            unitsPerEm: m.upm, ascender: m.ascender, descender: m.descender, xHeight: m.xHeight, capHeight: m.capHeight, italicAngle: m.italicAngle,
            underlinePosition: m.underlinePosition, underlineThickness: m.underlineThickness, lineGap: m.lineGap, winAscent: m.winAscent,
            winDescent: m.winDescent, typoAscender: m.typoAscender, typoDescender: m.typoDescender, typoLineGap: m.typoLineGap
        )
        let os2 = FontSource.OS2(weightClass: font.os2.weightClass, widthClass: font.os2.widthClass, vendorID: font.os2.vendorID, bold: font.os2.bold,
                                 italic: font.os2.italic, fsType: font.os2.fsType, panose: font.os2.panose)
        let kerning = font.omitGeneratedKern ? FontSource.Kerning() : self.kerning(Kerning(state, index: index), glyphs: origins)
        let source = FontSource(names: names, metrics: metrics, os2: os2, glyphs: glyphs, kerning: kerning, features: font.features,
                                generateMark: !font.omitGeneratedMark, generateLiga: !font.omitGeneratedLiga)
        return Snapshot(source: source, glyphs: origins, problems: problems)
    }

    /// A document glyph as the compiler takes it: its outline finished for the font, its kind,
    /// and its anchors in font units (FONT-019).
    static func sourceGlyph(_ glyph: Glyph, outline: GlyphOutline?) -> FontSource.Glyph {
        FontSource.Glyph(name: glyph.name, codepoints: glyph.codepoints, advanceWidth: glyph.advanceWidth.rounded(),
                         contours: finished(outline?.path.contours ?? []), kind: kind(glyph.kind), anchors: anchors(glyph.anchors))
    }

    /// The compiler's glyph kind for the document's.
    static func kind(_ kind: GlyphKind) -> FontSource.GlyphKind {
        switch kind {
        case .base: .base
        case .mark: .mark
        case .ligature: .ligature
        case .component: .component
        }
    }

    /// Anchors as the feature generator reads them: y flipped into the font and rounded, named
    /// by the underscore convention for their role (an explicit Mark role on `top` reads `_top`,
    /// an explicit Base role on `_top` reads `top`); duplicates (`top.dup2`) are left out.
    static func anchors(_ anchors: [GlyphAnchorValue]) -> [FontSource.Anchor] {
        anchors.filter { !$0.isDuplicate }.map { anchor in
            let name = anchor.role == .mark ? "_" + anchor.attachmentName : anchor.attachmentName
            return FontSource.Anchor(name: name, x: anchor.position.x.rounded(), y: (anchor.position.y == 0 ? 0 : -anchor.position.y).rounded())
        }
    }

    /// Glyph-canvas contours (y down) as font contours: y flipped, counter-clockwise outer
    /// contours, extrema added, rounded.
    public static func finished(_ contours: [Contour]) -> [Contour] {
        let flipped = GlyphContours.flipped(contours.filter { !$0.isEmpty })
        return GlyphContours.rounded(GlyphContours.addingExtrema(GlyphContours.correctingDirections(flipped, outer: .counterClockwise)))
    }

    /// The synthesized `.notdef`: a box from the baseline to the cap height with a counter.
    static func notdefGlyph(_ font: FontInfo) -> FontSource.Glyph {
        let upm = Double(font.metrics.upm)
        let width = (500 * upm / 1_000).rounded()
        let inset = (50 * upm / 1_000).rounded()
        let stroke = (50 * upm / 1_000).rounded()
        let top = max(font.metrics.capHeight.rounded(), stroke * 3)
        let outer = Contour(polygon: [Point(x: inset, y: 0), Point(x: width - inset, y: 0), Point(x: width - inset, y: top), Point(x: inset, y: top)])
        let inner = Contour(polygon: [Point(x: inset + stroke, y: stroke), Point(x: inset + stroke, y: top - stroke), Point(x: width - inset - stroke, y: top - stroke),
                                      Point(x: width - inset - stroke, y: stroke)])
        return FontSource.Glyph(name: ".notdef", advanceWidth: width, contours: [outer, inner])
    }

    /// The kerning resolved to glyph indices: effective pairs whose glyphs are both in the font;
    /// classes with their members in the font (empty classes dropped); effective cells between
    /// kept classes.  Values are rounded to whole units.
    static func kerning(_ kerning: Kerning, glyphs: [OpID?]) -> FontSource.Kerning {
        var position: [OpID: Int] = [:]
        for (index, origin) in glyphs.enumerated() {
            if let origin { position[origin] = index }
        }
        let pairs = kerning.effectivePairs.compactMap { pair -> FontSource.Kerning.Pair? in
            guard let left = position[pair.left], let right = position[pair.right] else { return nil }
            return FontSource.Kerning.Pair(left: left, right: right, value: Int(pair.value.rounded()))
        }
        var leftClasses: [[Int]] = [], rightClasses: [[Int]] = []
        var leftNames: [String] = [], rightNames: [String] = []
        var leftIndex: [OpID: Int] = [:], rightIndex: [OpID: Int] = [:]
        for kernClass in kerning.classes {
            let members = kernClass.members.compactMap { position[$0] }
            guard !members.isEmpty else { continue }
            if kernClass.side == .left {
                leftIndex[kernClass.id] = leftClasses.count
                leftClasses.append(members)
                leftNames.append(kernClass.name)
            } else {
                rightIndex[kernClass.id] = rightClasses.count
                rightClasses.append(members)
                rightNames.append(kernClass.name)
            }
        }
        let cells = kerning.effectiveCells.compactMap { cell -> FontSource.Kerning.ClassValue? in
            guard let left = leftIndex[cell.left], let right = rightIndex[cell.right] else { return nil }
            return FontSource.Kerning.ClassValue(left: left, right: right, value: Int(cell.value.rounded()))
        }
        return FontSource.Kerning(pairs: pairs, leftClasses: leftClasses, rightClasses: rightClasses, classValues: cells, leftClassNames: leftNames,
                                  rightClassNames: rightNames)
    }

    /// Validates and compiles the document's font (menu:File[Generate Fonts…]).  Errors stop here.
    public static func generate(_ state: EngineState, format: FontCompiler.Format, options: FontGenerationOptions = FontGenerationOptions(),
                                date: Date? = nil) async throws -> FontCompiler.Result {
        let snapshot = snapshot(state, options: options)
        guard !FontValidation.blocksGeneration(snapshot.problems) else { throw FontGenerationError.invalid(snapshot.problems) }
        return try await FontCompiler().compile(snapshot.source, options: .init(format: format, date: date))
    }
}
