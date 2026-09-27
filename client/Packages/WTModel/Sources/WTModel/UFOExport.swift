import Foundation
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

// FONT-023 (model half): a typeface document as a UFO 3 package (font-export.adoc, "UFO packages"):
// the generate snapshot's glyphs (exported glyphs in grid order, `.notdef` first, the standard glyphs
// synthesized when asked), names, metrics, OS/2 values, kinds, anchors and kerning with the classes'
// names, plus what a UFO carries beyond a compiled font -- components kept as components, each
// glyph's note and mark color, the feature file (the user's text, then the generated features), and
// the lib keys an opened UFO carried (`FontProps.ufo_lib_passthrough`) written back.  Artwork is
// written *flattened* (each glyph's own paths merged and finished as for a font, each contour
// started at its lowest-leftmost on-curve point; components that
// point at glyphs in the package stay components) or *as drawn* (each path's contours as they
// stand, strokes expanded into outlines, overlaps intact; the glyph's objects also go into its lib
// as a pasteboard payload, which `UFOImport` pastes back so strokes and effects survive a round trip
// through WireTuner).  Export never changes the document.

/// The Export UFO sheet's choices.
public struct UFOExportOptions: Hashable, Sendable {
    public enum Artwork: Hashable, Sendable, CaseIterable {
        /// The generated outlines: components kept, everything else merged.
        case flattened
        /// Each path as a contour, strokes as contours, overlaps intact, the artwork in the lib.
        case asDrawn
    }

    public var artwork: Artwork
    /// *Add .notdef, space, NULL and CR* when missing.
    public var addStandardGlyphs: Bool
    /// The generated `kern`, `mark`, `mkmk`, `liga` and `GDEF` appended to `features.fea`.
    public var generatedFeatures: Bool
    /// The glyphs to include (nil: every exported glyph).
    public var glyphs: Set<OpID>?

    public init(artwork: Artwork = .flattened, addStandardGlyphs: Bool = true, generatedFeatures: Bool = true, glyphs: Set<OpID>? = nil) {
        self.artwork = artwork
        self.addStandardGlyphs = addStandardGlyphs
        self.generatedFeatures = generatedFeatures
        self.glyphs = glyphs
    }
}

/// Building and writing a UFO export.
public enum UFOExport {
    /// The package and what the export could not carry as drawn.
    public struct Export: Hashable, Sendable {
        public var package: UFOPackage
        public var report: [String]
    }

    /// The package for the document's font.
    public static func package(_ state: EngineState, options: UFOExportOptions = UFOExportOptions()) -> Export {
        let snapshot = FontGeneration.snapshot(state, options: FontGenerationOptions(addStandardGlyphs: options.addStandardGlyphs, glyphs: options.glyphs))
        let index = GlyphIndex(state)
        let sources = GlyphOutlines.sources(in: state, index: index)
        let objects = options.artwork == .asDrawn ? GlyphArtwork.objectsByGlyph(in: state) : [:]
        let included = Set(snapshot.glyphs.compactMap { $0 })
        var stroked: [String] = []
        var glyphs: [UFOPackage.Glyph] = []
        for (offset, generated) in snapshot.source.glyphs.enumerated() {
            var glyph = UFOPackage.Glyph(name: generated.name, codepoints: generated.codepoints, advanceWidth: generated.advanceWidth,
                                         contours: generated.contours, anchors: generated.anchors, kind: generated.kind)
            guard let id = snapshot.glyphs[offset], let read = index[id], let source = sources[NodeID(id)] else {
                glyphs.append(glyph)
                continue
            }
            glyph.note = read.note
            glyph.markColor = read.markColor
            // Components whose glyph is in the package stay components; the rest are drawn in.
            var kept: [UFOPackage.Component] = []
            var drawnIn: [GlyphComponentPlacement] = []
            for (component, placement) in zip(read.components, source.components) {
                if component.status == .resolved, let target = component.source, included.contains(target), let base = index[target] {
                    kept.append(UFOPackage.Component(base: base.name, transform: FontImport.canvasTransform(component.transform)))
                } else {
                    drawnIn.append(placement)
                }
            }
            glyph.components = kept
            switch options.artwork {
            case .flattened:
                let own = GlyphFlattener.outline(of: GlyphSource(shapes: source.shapes, components: drawnIn), sources: sources)
                glyph.contours = FontGeneration.finished(own.path.contours).map(startingAtLowerLeft)
            case .asDrawn:
                let drawn = asDrawn(source.shapes, components: drawnIn, sources: sources)
                glyph.contours = drawn.contours
                if drawn.stroked { stroked.append(read.name) }
                let artwork = objects[id]?.flatMap(\.objects) ?? []
                if !artwork.isEmpty { glyph.artwork = Data(ClipboardPayload(copying: artwork, from: state).encoded()) }
            }
            glyphs.append(glyph)
        }
        let font = FontInfo(state)
        // A UFO keeps no class order (groups are a dictionary): classes go by name, so the
        // generated kern feature reads the same after the package is opened again.
        let kerning = sortedClasses(snapshot.source.kerning)
        var source = snapshot.source
        source.kerning = kerning
        let generated = options.generatedFeatures ? FeatureGenerator.generated(source) : ""
        let features = generated.isEmpty ? font.features : FeatureGenerator.file(user: font.features, generated: generated).text
        let passthrough = state.props(WellKnown.settings).settings.font.ufoLibPassthrough
        let package = UFOPackage(names: snapshot.source.names, metrics: snapshot.source.metrics, os2: snapshot.source.os2, glyphs: glyphs,
                                 kerning: kerning, features: features, lib: passthrough.isEmpty ? nil : passthrough)
        var report: [String] = []
        if !stroked.isEmpty {
            report.append("Strokes were written as outlines in \(stroked.count == 1 ? stroked[0] : "\(stroked.count) glyphs"); WireTuner keeps them "
                + "as strokes when it opens the UFO.")
        }
        return Export(package: package, report: report)
    }

    /// Writes the document's font as a UFO package at `url` (menu:File[Export UFO…]) and returns
    /// the report.
    @discardableResult
    public static func write(_ state: EngineState, to url: URL, options: UFOExportOptions = UFOExportOptions()) throws -> [String] {
        let export = package(state, options: options)
        try UFOWriter.write(export.package, to: url)
        return export.report
    }

    /// `kerning` with each side's classes in name order (unnamed classes by their first glyph
    /// index, after the named ones), the class values renumbered.
    static func sortedClasses(_ kerning: FontSource.Kerning) -> FontSource.Kerning {
        func order(_ classes: [[Int]], _ names: [String]) -> [Int] {
            classes.indices.sorted { a, b in
                let x = a < names.count ? names[a] : "", y = b < names.count ? names[b] : ""
                if x.isEmpty != y.isEmpty { return !x.isEmpty }
                return x != y ? x < y : a < b
            }
        }
        let left = order(kerning.leftClasses, kerning.leftClassNames), right = order(kerning.rightClasses, kerning.rightClassNames)
        var leftPosition: [Int: Int] = [:], rightPosition: [Int: Int] = [:]
        for (position, index) in left.enumerated() { leftPosition[index] = position }
        for (position, index) in right.enumerated() { rightPosition[index] = position }
        func name(_ names: [String], _ index: Int) -> String { index < names.count ? names[index] : "" }
        return FontSource.Kerning(
            pairs: kerning.pairs, leftClasses: left.map { kerning.leftClasses[$0] }, rightClasses: right.map { kerning.rightClasses[$0] },
            classValues: kerning.classValues.compactMap { cell in
                guard let l = leftPosition[cell.left], let r = rightPosition[cell.right] else { return nil }
                return FontSource.Kerning.ClassValue(left: l, right: r, value: cell.value)
            }.sorted { ($0.left, $0.right) < ($1.left, $1.right) },
            leftClassNames: left.map { name(kerning.leftClassNames, $0) }, rightClassNames: right.map { name(kerning.rightClassNames, $0) })
    }

    /// A closed contour started at its lowest on-curve point (the leftmost of those), the usual
    /// font-editor convention; flattening does not keep start points, so an export of an imported
    /// UFO starts every contour where the source did only after this normalization.
    static func startingAtLowerLeft(_ contour: Contour) -> Contour {
        guard contour.isClosed, !contour.segments.isEmpty else { return contour }
        var segments = contour.segments
        if let closing = contour.closingSegment { segments.append(closing) }
        let start = segments.indices.min { a, b in
            let p = segments[a].p0, q = segments[b].p0
            return p.y != q.y ? p.y < q.y : p.x < q.x
        }!
        return Contour(segments: Array(segments[start...] + segments[..<start]), closed: true)
    }

    /// The as-drawn contours in font space: filled paths' contours as they stand, each stroke's
    /// outline, components that are not kept flattened in; whether a stroke was expanded.
    static func asDrawn(_ shapes: [GlyphShape], components: [GlyphComponentPlacement],
                        sources: [NodeID: GlyphSource]) -> (contours: [Contour], stroked: Bool) {
        var contours: [Contour] = []
        var stroked = false
        for shape in shapes {
            if shape.filled { contours += shape.contours.filter { !$0.isEmpty }.map { $0.applying(shape.transform) } }
            guard !shape.strokes.isEmpty else { continue }
            let strokes = GlyphShape(contours: shape.contours, transform: shape.transform, fillRule: shape.fillRule, filled: false, strokes: shape.strokes)
            let outline = GlyphFlattener.outline(of: GlyphSource(shapes: [strokes]), sources: sources, options: .init(keepOverlaps: true))
            contours += outline.path.contours
            stroked = stroked || !outline.path.contours.isEmpty
        }
        if !components.isEmpty {
            contours += GlyphFlattener.outline(of: GlyphSource(components: components), sources: sources, options: .init(keepOverlaps: true)).path.contours
        }
        return (GlyphContours.flipped(contours), stroked)
    }
}
