import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// FONT-028: the round-trip suite (font-export.adoc, "Build tasks").  A corpus of three families
/// -- built as documents here, so the corpus needs no binary files or licenses -- each with
/// kerning classes, marks and a ligature, goes OTF → document → OTF, TTF → document → TTF and
/// UFO → document → UFO, comparing every glyph's outline (within a per-format tolerance), advance
/// widths, the character map, every kerning value, anchors, kinds and the feature text, plus the
/// WOFF2 wrap decoding to the same font.  A failure names the family, the glyph and the value
/// that differs; what a format cannot carry is asserted as an expected loss.
@Suite struct FontRoundTripTests {
    struct Family: CustomStringConvertible, Sendable {
        let name: String
        let build: @Sendable (inout Replica) throws -> Void
        var description: String { name }
    }

    static let corpus: [Family] = [
        Family(name: "Marlowe", build: marlowe),
        Family(name: "Quill", build: quill),
        Family(name: "Tern", build: tern),
    ]

    // MARK: Corpus

    /// Basic Latin boxes, a ring, a stroked V, an Agrave of components, a pair and two classes,
    /// top anchors, an f_i ligature and a stylistic set in the feature file.
    static func marlowe(_ a: inout Replica) throws {
        var g = try FontGenerationTests.drawn(&a)
        try a.perform(AddGlyphs([NewGlyph(name: "f_i", kind: .ligature)]))
        g = names(a)
        for (name, width) in [("f", 300.0), ("i", 150), ("f_i", 450), ("B", 500)] {
            try TypefaceFixture.box(40, -700, width, 700, on: g[name]!, in: &a)
        }
        try a.perform(SetGlyphWidth([g["f_i"]!], to: 520))
        try a.perform(AddAnchor("top", at: Point(x: 300, y: -700), to: g["A"]!))
        try a.perform(AddAnchor("top", at: Point(x: 350, y: -700), to: g["O"]!))
        try a.perform(AddAnchor("_top", at: Point(x: 150, y: -700), to: g["gravecomb"]!))
        try a.perform(OpsCommand("Features", ops: [Ops.textInsert(WellKnown.settings, FontFields.features, "feature ss01 { sub A by B; } ss01;\n")]))
    }

    /// 2048 units per em, curved outlines (a bowl and an arch), classes on both sides with an
    /// exception, a mark with both a base and a mark anchor (mkmk) and a ligature.
    static func quill(_ a: inout Replica) throws {
        try a.perform(NewTypeface(family: "Quill", style: "Bold", upm: 2_048, set: nil))
        try a.perform(AddGlyphs([0x6F, 0x63, 0x6E, 0x68, 0x301, 0x302, 0x20].map(NewGlyph.init(scalar:)) + [NewGlyph(name: "c_h", kind: .ligature)]))
        let g = names(a)
        func curve(_ glyph: String, _ points: [VectorPoint]) throws {
            let path = try a.perform(CreatePath(contours: [NewContour(closed: true, points: points)], appearance: GlyphPaths.appearance))!.createdObjects[0]
            try TypefaceFixture.place(path, on: g[glyph]!, in: &a)
        }
        let bowl = [
            VectorPoint(anchor: Point(x: 500, y: 0), inHandle: Vector(dx: -276, dy: 0), outHandle: Vector(dx: 276, dy: 0)),
            VectorPoint(anchor: Point(x: 1_000, y: -500), inHandle: Vector(dx: 0, dy: 276), outHandle: Vector(dx: 0, dy: -276)),
            VectorPoint(anchor: Point(x: 500, y: -1_000), inHandle: Vector(dx: 276, dy: 0), outHandle: Vector(dx: -276, dy: 0)),
            VectorPoint(anchor: Point(x: 0, y: -500), inHandle: Vector(dx: 0, dy: -276), outHandle: Vector(dx: 0, dy: 276)),
        ]
        try curve("o", bowl)
        try curve("c", bowl.map { VectorPoint(anchor: $0.anchor + Vector(dx: 20, dy: 0), inHandle: $0.inHandle, outHandle: $0.outHandle) })
        try curve("n", [
            VectorPoint(anchor: Point(x: 0, y: 0)), VectorPoint(anchor: Point(x: 0, y: -1_000)),
            VectorPoint(anchor: Point(x: 900, y: -700), inHandle: Vector(dx: 0, dy: -300)), VectorPoint(anchor: Point(x: 900, y: 0)),
        ])
        try TypefaceFixture.box(0, -1_400, 200, 1_400, on: g["h"]!, in: &a)
        try TypefaceFixture.box(0, -1_400, 1_600, 1_400, on: g["c_h"]!, in: &a)
        try TypefaceFixture.box(-100, -1_500, 200, 150, on: g[GlyphNaming.name(for: 0x301)]!, in: &a)
        try TypefaceFixture.box(-150, -1_500, 300, 120, on: g[GlyphNaming.name(for: 0x302)]!, in: &a)
        try a.perform(SetGlyphWidth([g["o"]!, g["c"]!, g["n"]!], to: 1_100))
        try a.perform(SetGlyphWidth([g["c_h"]!], to: 1_700))
        try a.perform(AddAnchor("top", at: Point(x: 500, y: -1_100), to: g["o"]!))
        try a.perform(AddAnchor("top", at: Point(x: 450, y: -1_100), to: g["n"]!))
        try a.perform(AddAnchor("_top", at: Point(x: 0, y: -1_100), to: g[GlyphNaming.name(for: 0x301)]!))
        try a.perform(AddAnchor("_top", at: Point(x: 0, y: -1_100), to: g[GlyphNaming.name(for: 0x302)]!))
        try a.perform(AddAnchor("top", at: Point(x: 0, y: -1_700), to: g[GlyphNaming.name(for: 0x302)]!))
        try a.perform(CreateKernClass("round", side: .left, members: [g["o"]!, g["c"]!]))
        try a.perform(CreateKernClass("stem", side: .right, members: [g["n"]!, g["h"]!]))
        try a.perform(CreateKernClass("round", side: .right, members: [g["o"]!, g["c"]!]))
        let kerning = Kerning(a.state)
        let left = kerning.classes.first { $0.side == .left }!.id
        for right in kerning.classes.filter({ $0.side == .right }) {
            try a.perform(SetClassKern(left, right.id, to: right.name == "stem" ? -40 : -25))
        }
        try a.perform(SetKernPair(g["c"]!, g["h"]!, to: 10))
    }

    /// Latin-1 (accented letters as components of a base and a mark, placed by transforms), an
    /// italic angle, a scaled component and kerning with pairs only.
    static func tern(_ a: inout Replica) throws {
        try a.perform(NewTypeface(family: "Tern", style: "Italic", upm: 1_000, set: .latin1))
        try a.perform(SetFontMetrics([.italicAngle: -12]))
        try a.perform(SetFontOS2(italic: true))
        try a.perform(AddGlyphs([NewGlyph(name: "A.small")]))
        let g = names(a)
        for name in ["A", "E", "O", "e", "a"] { try TypefaceFixture.box(30, -680, 480, 680, on: g[name]!, in: &a) }
        for name in [0x300, 0x301, 0x308].map(GlyphNaming.name(for:)) { try TypefaceFixture.box(-60, -800, 120, 80, on: g[name]!, in: &a) }
        try a.perform(AddComponent(g["A"]!, to: g["A.small"]!, transform: AffineTransform(a: 0.75, b: 0, c: 0, d: 0.75, tx: 20, ty: 0)))
        try a.perform(AddAnchor("top", at: Point(x: 270, y: -700), to: g["A"]!))
        try a.perform(AddAnchor("_top", at: Point(x: 0, y: -700), to: g[GlyphNaming.name(for: 0x301)]!))
        try a.perform(SetKernPair(g["A"]!, g["O"]!, to: -35))
        try a.perform(SetKernPair(g["O"]!, g["A"]!, to: -30))
        try a.perform(CreateKernClass("E", side: .left, members: [g["E"]!, g["Egrave"]!, g["Eacute"]!]))
        try a.perform(CreateKernClass("A", side: .right, members: [g["A"]!, g["Agrave"]!, g["Aacute"]!]))
        let kerning = Kerning(a.state)
        try a.perform(SetClassKern(kerning.classes[0].id, kerning.classes[1].id, to: -15))
    }

    static func names(_ replica: Replica) -> [String: OpID] {
        Dictionary(uniqueKeysWithValues: GlyphIndex(replica.state).glyphs.map { ($0.name, $0.id) })
    }

    static func document(_ family: Family) throws -> Replica {
        var replica = Replica(0xA)
        try family.build(&replica)
        return replica
    }

    // MARK: Comparison

    /// The largest distance from a point of one outline to the other (both ways), sampled at
    /// every segment's ends and quarters.
    static func distance(_ a: [Contour], _ b: [Contour]) -> Double {
        // A closed contour's closing segment counts too.
        func closed(_ contours: [Contour]) -> [Contour] {
            contours.map { contour in
                guard contour.isClosed, let closing = contour.closingSegment else { return contour }
                return Contour(segments: contour.segments + [closing], closed: true)
            }
        }
        func oneWay(_ from: [Contour], _ to: [Contour]) -> Double {
            var worst = 0.0
            for contour in from {
                for segment in contour.segments {
                    for t in [0, 0.25, 0.5, 0.75] {
                        let point = segment.evaluate(t)
                        let nearest = to.compactMap { $0.nearestPoint(to: point)?.distance }.min() ?? .infinity
                        worst = max(worst, nearest)
                    }
                }
            }
            return worst
        }
        return max(oneWay(closed(a), closed(b)), oneWay(closed(b), closed(a)))
    }

    /// Every difference between two read fonts, each naming the glyph and the values.
    static func differences(_ a: ImportedFont, _ b: ImportedFont, tolerance: Double) -> [String] {
        var result: [String] = []
        if a.glyphs.map(\.name) != b.glyphs.map(\.name) { result.append("glyph order: \(a.glyphs.map(\.name)) vs \(b.glyphs.map(\.name))") }
        if a.names != b.names { result.append("names: \(a.names) vs \(b.names)") }
        if a.metrics != b.metrics { result.append("metrics: \(a.metrics) vs \(b.metrics)") }
        let other = Dictionary(b.glyphs.enumerated().map { ($1.name, $0) }) { first, _ in first }
        for glyph in a.glyphs {
            guard let index = other[glyph.name] else {
                result.append("\(glyph.name): missing")
                continue
            }
            let twin = b.glyphs[index]
            if glyph.advanceWidth != twin.advanceWidth { result.append("\(glyph.name): advance \(glyph.advanceWidth) vs \(twin.advanceWidth)") }
            if glyph.codepoints.sorted() != twin.codepoints.sorted() { result.append("\(glyph.name): cmap \(glyph.codepoints) vs \(twin.codepoints)") }
            let d = distance(glyph.contours, twin.contours)
            if d > tolerance { result.append("\(glyph.name): outline differs by \(d) units") }
        }
        // Every pair of glyphs, by name.
        for left in a.glyphs.indices {
            guard let l = other[a.glyphs[left].name] else { continue }
            for right in a.glyphs.indices {
                guard let r = other[a.glyphs[right].name] else { continue }
                let x = a.kerning.value(left, right), y = b.kerning.value(l, r)
                if x != y { result.append("kerning \(a.glyphs[left].name) \(a.glyphs[right].name): \(x) vs \(y)") }
            }
        }
        return result
    }

    static func perform(_ plan: FontImport.Plan, on replica: inout Replica) throws {
        let recording = DocumentCore.Recording(group: 9, limit: 100, now: Replica.now)
        for command in plan.commands { _ = try replica.core.perform(command, recording: recording) }
    }

    // MARK: OpenType

    @Test(arguments: corpus, FontCompiler.Format.allCases)
    func openTypeDocumentOpenType(family: Family, format: FontCompiler.Format) async throws {
        let a = try Self.document(family)
        let bytes = try await FontGeneration.generate(a.state, format: format, date: Date(timeIntervalSince1970: 0)).data
        let first = try OpenTypeReader.read(bytes)
        var b = Replica(0xB)
        try Self.perform(FontImport.plan(first, fileName: "\(family).\(format.fileExtension)", into: b.state, newDocument: true), on: &b)
        let again = try await FontGeneration.generate(b.state, format: format, date: Date(timeIntervalSince1970: 0)).data
        let second = try OpenTypeReader.read(again)
        // TrueType re-converts cubics to quadratics each way (half a unit each) and rounds.
        let tolerance = format == .ttf ? 1.5 : 0.5
        let differences = Self.differences(first, second, tolerance: tolerance)
        #expect(differences.isEmpty, "\(family) \(format): \(differences.joined(separator: "; "))")
        // Expected losses: the layout features other than kern are not read back from a font, so
        // anchors -- and with them mark and mkmk -- and the feature text do not survive; the
        // ligature glyph is recognised by its name and liga is generated again.
        let before = FontGeneration.snapshot(a.state).source, after = FontGeneration.snapshot(b.state).source
        #expect(after.glyphs.allSatisfy(\.anchors.isEmpty) && after.features.isEmpty)
        #expect(before.glyphs.contains { !$0.anchors.isEmpty })
        let ligatures = { (source: FontSource) in Set(source.glyphs.filter { $0.kind == .ligature }.map(\.name)) }
        #expect(ligatures(after) == ligatures(before), "\(family): ligatures \(ligatures(before)) vs \(ligatures(after))")
        #expect(FeatureGenerator.generatedTags(after).contains("liga") == FeatureGenerator.generatedTags(before).contains("liga"))
        // The report says what was not read.
        #expect(first.report.allSatisfy { !$0.isEmpty })
    }

    @Test(arguments: corpus)
    func woff2DecodesToTheSameFont(family: Family) async throws {
        let a = try Self.document(family)
        let otf = try await FontGeneration.generate(a.state, format: .otf, date: Date(timeIntervalSince1970: 0)).data
        let decoded = try WOFF2Reader.sfnt(try WOFF2Writer.woff2(otf))
        let differences = Self.differences(try OpenTypeReader.read(otf), try OpenTypeReader.read(decoded), tolerance: 0)
        #expect(differences.isEmpty, "\(family): \(differences.joined(separator: "; "))")
    }

    // MARK: UFO

    @Test(arguments: corpus)
    func ufoDocumentUFO(family: Family) throws {
        let a = try Self.document(family)
        let first = UFOExport.package(a.state).package
        let url = FileManager.default.temporaryDirectory.appending(component: "roundtrip-\(UUID().uuidString).ufo")
        defer { try? FileManager.default.removeItem(at: url) }
        try UFOWriter.write(first, to: url)
        let read = try UFOReader.read(at: url)
        var b = Replica(0xB)
        try Self.perform(UFOImport.plan(read, fileName: "\(family).ufo", into: b.state, newDocument: true), on: &b)
        let second = UFOExport.package(b.state).package
        // Glyph by glyph, then byte for byte.
        #expect(first.glyphs.map(\.name) == second.glyphs.map(\.name))
        for (x, y) in zip(first.glyphs, second.glyphs) {
            #expect(Self.distance(x.contours, y.contours) == 0, "\(family) \(x.name): outline")
            #expect(x.components == y.components, "\(family) \(x.name): components \(x.components) vs \(y.components)")
            #expect(x.anchors == y.anchors, "\(family) \(x.name): anchors \(x.anchors) vs \(y.anchors)")
            #expect(x.kind == y.kind && x.advanceWidth == y.advanceWidth && x.codepoints == y.codepoints, "\(family) \(x.name)")
        }
        #expect(first.kerning == second.kerning, "\(family): kerning")
        #expect(first.features == second.features && first.names == second.names && first.metrics == second.metrics && first.os2 == second.os2)
        let once = try UFOWriter.files(first), twice = try UFOWriter.files(second)
        for (path, data) in once { #expect(twice[path] == data, "\(family): \(path) differs") }
        #expect(once.keys.sorted() == twice.keys.sorted())
        // The document's kinds survive (the synthesized standard glyphs become glyphs of their own).
        let kinds = { (replica: Replica) in Set(GlyphIndex(replica.state).glyphs.filter { !$0.skipExport }.map { "\($0.name):\($0.kind)" }) }
        #expect(kinds(a).isSubset(of: kinds(b)), "\(family): \(kinds(a).subtracting(kinds(b)))")
    }
}
