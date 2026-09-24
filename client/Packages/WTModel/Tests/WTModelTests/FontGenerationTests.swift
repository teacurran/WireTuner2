import CoreGraphics
import CoreText
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// FONT-014 / FONT-015 / FONT-026 (model half): validation, the generate snapshot and the
/// compiled fonts read back through Core Text.
@Suite struct FontGenerationTests {
    /// A Basic Latin typeface with artwork on A (box), O (ring, even-odd), V (stroked open path),
    /// Aacute-like composite on "Agrave" (A + a mark), and kerning.
    static func drawn(_ a: inout Replica) throws -> [String: OpID] {
        try TypefaceFixture.typeface(&a)
        var g = Dictionary(uniqueKeysWithValues: GlyphIndex(a.state).glyphs.map { ($0.name, $0.id) })
        try TypefaceFixture.box(0, -700, 600, 700, on: g["A"]!, in: &a)
        let ring = try a.perform(CreatePath(contours: [
            NewContour(closed: true, points: PathFixture.points([(50, -650), (650, -650), (650, -50), (50, -50)])),
            NewContour(closed: true, points: PathFixture.points([(150, -550), (550, -550), (550, -150), (150, -150)])),
        ], appearance: GlyphPaths.appearance, evenOdd: true))!.createdObjects[0]
        try TypefaceFixture.place(ring, on: g["O"]!, in: &a)
        let stroke = try a.perform(CreatePath(contours: [NewContour(points: PathFixture.points([(0, -700), (300, 0), (600, -700)]))],
                                              appearance: Appearances.standard))!.createdObjects[0]
        try TypefaceFixture.place(stroke, on: g["V"]!, in: &a)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x300), NewGlyph(name: "Agrave", codepoints: [0xC0])]))
        g = Dictionary(uniqueKeysWithValues: GlyphIndex(a.state).glyphs.map { ($0.name, $0.id) })
        try TypefaceFixture.box(100, -900, 100, 100, on: g["gravecomb"]!, in: &a)
        try a.perform(AddComponent(g["A"]!, to: g["Agrave"]!))
        try a.perform(AddComponent(g["gravecomb"]!, to: g["Agrave"]!))
        try a.perform(SetGlyphWidth([g["Agrave"]!], to: 600))
        try a.perform(SetKernPair(g["A"]!, g["V"]!, to: -80))
        try a.perform(CreateKernClass("A", side: .left, members: [g["A"]!, g["Agrave"]!]))
        try a.perform(CreateKernClass("O", side: .right, members: [g["O"]!]))
        let kerning = Kerning(a.state)
        try a.perform(SetClassKern(kerning.classes[0].id, kerning.classes[1].id, to: -30))
        return g
    }

    @Test func snapshotFinishesOutlinesAndSynthesizesStandardGlyphs() throws {
        var a = Replica(0xA)
        let g = try Self.drawn(&a)
        try a.perform(SetGlyphAttributes([g["B"]!], export: false))
        let snapshot = FontGeneration.snapshot(a.state)
        let names = snapshot.source.glyphs.map(\.name)
        #expect(names.first == ".notdef" && !names.contains("B") && names.suffix(2) == ["NULL", "CR"])
        #expect(snapshot.glyphs.first == g[".notdef"] && snapshot.glyphs.last == .some(nil))
        let glyphA = try #require(snapshot.source.glyphs.first { $0.name == "A" })
        // y flipped into the font, counter-clockwise, whole units.
        #expect(glyphA.bounds == Rect(x: 0, y: 0, width: 600, height: 700) && glyphA.contours[0].signedArea() > 0)
        let ring = try #require(snapshot.source.glyphs.first { $0.name == "O" })
        #expect(ring.contours.count == 2 && ring.contours.map { $0.signedArea() > 0 }.sorted { !$0 && $1 } == [false, true])
        let agrave = try #require(snapshot.source.glyphs.first { $0.name == "Agrave" })
        #expect(agrave.bounds == Rect(x: 0, y: 0, width: 600, height: 900))
        let v = try #require(snapshot.source.glyphs.first { $0.name == "V" })
        #expect(!v.contours.isEmpty)
        // Kerning by index: the pair, and the A class (A, Agrave) against O.
        let index = { (name: String) in names.firstIndex(of: name)! }
        #expect(snapshot.source.kerning.value(index("A"), index("V")) == -80)
        #expect(snapshot.source.kerning.value(index("Agrave"), index("O")) == -30)
        // Options: selected glyphs only, no standard glyphs, test suffix, kerning omitted.
        try a.perform(SetGeneratedFeatures(kern: false))
        let options = FontGenerationOptions(addStandardGlyphs: false, keepOverlaps: true, glyphs: [g["A"]!, g["space"]!], testSuffix: true)
        let small = FontGeneration.snapshot(a.state, options: options)
        #expect(small.source.glyphs.map(\.name) == [".notdef", "space", "A"] && small.source.glyphs[0].contours.isEmpty)
        #expect(small.source.names.family == "Marlowe Test" && small.source.names.postscript == "MarloweTest-Regular")
        #expect(small.source.names.full == "Marlowe Test Regular" && small.source.kerning.isEmpty)
        #expect(small.problems.contains { $0.kind == .kerningOmitted })
        // Without a .notdef glyph, the synthesized box.
        try a.perform(RemoveGlyphs([g[".notdef"]!]))
        let synthesized = FontGeneration.snapshot(a.state)
        #expect(synthesized.source.glyphs[0].name == ".notdef" && synthesized.source.glyphs[0].contours.count == 2 && synthesized.glyphs[0] == nil)
        #expect(synthesized.problems.contains { $0.kind == .missingNotdef })
    }

    @Test(arguments: FontCompiler.Format.allCases)
    func generatedFontsMatchTheModel(format: FontCompiler.Format) async throws {
        var a = Replica(0xA)
        _ = try Self.drawn(&a)
        let result = try await FontGeneration.generate(a.state, format: format)
        let provider = try #require(CGDataProvider(data: result.data as CFData))
        let font = CTFontCreateWithGraphicsFont(try #require(CGFont(provider)), 1_000, nil, nil)
        #expect(CTFontCopyFamilyName(font) as String == "Marlowe")
        var units = Array("AOV\u{C0}".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        #expect(CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count))
        let ring = try #require(CTFontCreatePathForGlyph(font, glyphs[1], nil))
        #expect(ring.contains(CGPoint(x: 100, y: 100)) && !ring.contains(CGPoint(x: 350, y: 350)))
        let agrave = try #require(CTFontCreatePathForGlyph(font, glyphs[3], nil)).boundingBoxOfPath
        #expect(agrave == CGRect(x: 0, y: 0, width: 600, height: 900))
        let attributed = NSAttributedString(string: "AVÀO", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let run = (CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attributed)) as! [CTRun])[0]
        var positions = [CGPoint](repeating: .zero, count: 4)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        #expect(positions[1].x - positions[0].x == 420)
        #expect(positions[3].x - positions[2].x == 570)
    }

    @Test func errorsStopGeneration() async throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(OpsCommand("Duplicate names", ops: [
            Ops.create(parent: WellKnown.glyphs, position: [0x80], props: GlyphFields.values { $0.name = "a" }),
            Ops.create(parent: WellKnown.glyphs, position: [0x81], props: GlyphFields.values { $0.name = "a" }),
            Ops.create(parent: WellKnown.glyphs, position: [0x82], props: GlyphFields.values { $0.name = "9" }),
        ]))
        do {
            _ = try await FontGeneration.generate(a.state, format: .otf)
            Issue.record("generated")
        } catch FontGenerationError.invalid(let problems) {
            #expect(problems.contains { $0.kind == .nameCollision } && problems.contains { $0.kind == .invalidName })
            #expect(problems.first?.level == .error && FontValidation.blocksGeneration(problems))
        }
    }

    @Test func validationListsEveryCheck() throws {
        var a = Replica(0xA)
        try a.perform(NewTypeface(family: "", style: "Regular", set: nil))
        try a.perform(SetFontMetrics([.ascender: -300]))
        try a.perform(OpsCommand("Older client", ops: [Ops.set(WellKnown.settings, [FontFields.name(3)], values: FontFields.fontValues {
            $0.names.postscript = "bad name"
        })]))
        try a.perform(OpsCommand("Features", ops: [Ops.textInsert(WellKnown.settings, FontFields.features, "languagesystem DFLT dflt;")]))
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42), NewGlyph(scalar: 0x43), NewGlyph(scalar: 0x44),
                                 NewGlyph(scalar: 0x301), NewGlyph(scalar: 0x45)]))
        let g = Dictionary(uniqueKeysWithValues: GlyphIndex(a.state).glyphs.map { ($0.name, $0.id) })
        // A: off-grid point; B: open path; C: a curve missing its extreme; D: too many points.
        try TypefaceFixture.box(0.5, -700, 300, 700, on: g["A"]!, in: &a)
        let open = try a.perform(CreatePath(contours: [NewContour(points: PathFixture.points([(0, 0), (100, -100)]))], appearance: GlyphPaths.appearance))!
            .createdObjects[0]
        try TypefaceFixture.place(open, on: g["B"]!, in: &a)
        let curve = try a.perform(CreatePath(contours: [NewContour(closed: true, points: [
            VectorPoint(anchor: Point(x: 0, y: 0), outHandle: Vector(dx: 0, dy: -300)),
            VectorPoint(anchor: Point(x: 400, y: 0), inHandle: Vector(dx: 0, dy: -300)),
        ])], appearance: GlyphPaths.appearance))!.createdObjects[0]
        try TypefaceFixture.place(curve, on: g["C"]!, in: &a)
        let many = (0..<1_600).map { index -> (Double, Double) in
            // A star: alternate radii keep every point a corner.
            let angle = Double(index) / 1_600 * 2 * .pi, radius = index % 2 == 0 ? 3_000.0 : 2_900
            return ((cos(angle) * radius).rounded(), (sin(angle) * radius).rounded())
        }
        try TypefaceFixture.draw(many, on: g["D"]!, in: &a)
        // Anchors: an unused base, a mark with no base, a duplicate; a component chain 9 deep.
        try a.perform(AddAnchor("top", at: .zero, to: g["A"]!))
        try a.perform(AddAnchor("_bottom", at: .zero, to: g["acutecomb"]!))
        try a.perform(AddAnchor("_bottom", at: .zero, to: g["acutecomb"]!))
        var chain: [OpID] = [g["E"]!]
        try a.perform(AddGlyphs((0..<9).map { NewGlyph(name: "deep\($0)") }))
        for level in 0..<9 {
            let next = TypefaceFixture.glyph("deep\(level)", in: a)
            try a.perform(AddComponent(chain.last!, to: next))
            chain.append(next)
        }
        try TypefaceFixture.box(0, -10, 10, 10, on: g["E"]!, in: &a)
        let problems = FontValidation.problems(in: a.state)
        let kinds = Set(problems.map(\.kind))
        for kind in [FontProblem.Kind.invalidMetrics, .emptyFamilyOrStyle, .invalidPostScriptName, .componentTooDeep, .missingNotdef, .missingSpace,
                     .featuresNotCompiled, .offGrid, .openContours, .missingExtrema, .emptyGlyph, .tooManyPoints, .unusedBaseAnchor, .markWithoutBase,
                     .duplicateAnchor] {
            #expect(kinds.contains(kind), "\(kind)")
        }
        #expect(problems.first { $0.kind == .offGrid }?.glyph == g["A"])
        #expect(FontValidation.glyphCountProblems(70_000).map(\.kind) == [.tooManyGlyphs] && FontValidation.glyphCountProblems(3).isEmpty)
        // Dangling and looping components are errors; matching anchors mean mark attachment is not compiled.
        var b = Replica(0xB)
        try TypefaceFixture.typeface(&b, set: nil)
        try b.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42), NewGlyph(scalar: 0x43)]))
        let glyphA = TypefaceFixture.glyph("A", in: b), glyphB = TypefaceFixture.glyph("B", in: b), glyphC = TypefaceFixture.glyph("C", in: b)
        try b.perform(AddComponent(glyphC, to: glyphA))
        try b.perform(RemoveGlyphs([glyphC]))
        try b.perform(OpsCommand("Loop", ops: [
            GlyphEditing.componentOp(glyphA, source: glyphB), GlyphEditing.componentOp(glyphB, source: glyphA),
        ]))
        try b.perform(AddAnchor("top", at: .zero, to: glyphA))
        try b.perform(AddAnchor("_top", at: .zero, to: glyphB))
        let errors = Set(FontValidation.problems(in: b.state).map(\.kind))
        #expect(errors.isSuperset(of: [.danglingComponent, .componentLoop, .attachmentNotCompiled]))
    }
}

extension GlyphEditing {
    /// A component insert that skips the loop check (for normalization tests).
    static func componentOp(_ glyph: OpID, source: OpID) -> Wiretuner_Doc_V1_Op {
        Ops.elementInsert(glyph, GlyphFields.components, positions: [[0x90]], values: GlyphFields.values {
            var value = Wiretuner_Doc_V1_Component()
            value.glyph.id = source.proto
            $0.components = [value]
        })
    }
}
