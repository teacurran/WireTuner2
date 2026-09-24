import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// Edge cases of the typeface model: stored values older or foreign clients may write, empty and
/// unusual inputs, and the less common branches of the commands.
@Suite struct TypefaceEdgeTests {
    static func raw(_ replica: inout Replica, _ ops: [Wiretuner_Doc_V1_Op]) throws {
        try replica.perform(OpsCommand("Raw", ops: ops))
    }

    @Test func glyphIndexOddStoredValues() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(named: "f_i"), NewGlyph(scalar: 0x66), NewGlyph(scalar: 0x69), NewGlyph(named: "eacute")]))
        let g = Dictionary(uniqueKeysWithValues: GlyphIndex(a.state).glyphs.map { ($0.name, $0.id) })
        #expect(GlyphIndex(a.state).glyph(named: "eacute")?.codepoints == [0xE9])
        // Ligature parts resolve by name; a base glyph or a missing part gives none.
        #expect(GlyphIndex(a.state)[g["f_i"]!]?.ligatureParts(in: GlyphIndex(a.state)) == [g["f"]!, g["i"]!])
        #expect(GlyphIndex(a.state)[g["A"]!]?.ligatureParts(in: GlyphIndex(a.state)) == nil)
        try a.perform(RenameGlyph(g["i"]!, to: "i.alt"))
        #expect(GlyphIndex(a.state)[g["f_i"]!]?.ligatureParts(in: GlyphIndex(a.state)) == nil)
        // A component with no glyph reference and a non-finite transform.
        try Self.raw(&a, [Ops.elementInsert(g["A"]!, GlyphFields.components, positions: [[0x80]], values: GlyphFields.values {
            var component = Wiretuner_Doc_V1_Component()
            component.transform.a = .nan
            $0.components = [component]
        })])
        let component = try #require(GlyphIndex(a.state)[g["A"]!]?.components.first)
        #expect(component.source == nil && component.status == .dangling && component.transform == .identity)
        // A codepoint another glyph keeps shows as a collision on the loser.
        try Self.raw(&a, [Ops.setAdd(g["eacute"]!, GlyphFields.codepoints, values: GlyphFields.codepointValues([0x41]))])
        let loser = g["A"]! < g["eacute"]! ? g["eacute"]! : g["A"]!
        #expect(GlyphIndex(a.state)[loser]?.hasCollision == true)
        #expect(FontValidation.problems(in: a.state).contains { $0.kind == .codepointCollision })
        // A stored name equal to another glyph's derived duplicate name keeps the lookup stable.
        var b = Replica(0xB)
        try TypefaceFixture.typeface(&b, set: nil)
        let created = try #require(try b.perform(OpsCommand("Twins", ops: [
            Ops.create(parent: WellKnown.glyphs, position: [0x80], props: GlyphFields.values { $0.name = "a" }),
            Ops.create(parent: WellKnown.glyphs, position: [0x81], props: GlyphFields.values { $0.name = "a" }),
        ]))).createdNodes
        let derived = "a.dup\(created[1].counter)_b"
        try b.perform(OpsCommand("Third", ops: [Ops.create(parent: WellKnown.glyphs, position: [0x82], props: GlyphFields.values { $0.name = derived })]))
        #expect(GlyphIndex(b.state).glyph(named: derived)?.id == created[1])
    }

    @Test func kerningOddStoredValues() throws {
        var a = Replica(0xA)
        let g = try KerningTests.glyphs(&a)
        try a.perform(CreateKernClass("L", side: .left, members: [g["A"]!]))
        try a.perform(CreateKernClass("R", side: .right, members: [g["V"]!]))
        try a.perform(CreateKernClass("L2", side: .left, members: [g["T"]!]))
        try a.perform(CreateKernClass("L2", side: .left, members: [g["o"]!]))
        try a.perform(CreateKernClass("R", side: .right, members: [g["O"]!]))
        let classes = Kerning(a.state).classes
        let left = classes[0].id, right = classes[1].id
        #expect(Kerning(a.state).sameNamedClasses.count == 2)
        try Self.raw(&a, [
            // A pair without a left glyph, a member without a glyph, a cell without classes and two
            // duplicate cells.
            Ops.elementInsert(WellKnown.settings, FontFields.pairs, positions: [[0x80]], values: FontFields.fontValues {
                var pair = Wiretuner_Doc_V1_KernPair()
                pair.right = KerningEditing.glyphRef(g["V"]!)
                $0.pairs = [pair]
            }),
            Ops.elementInsert(WellKnown.settings, FontFields.kernClassMembers(left), positions: [[0x90]], values: FontFields.fontValues {
                $0.classes = [Wiretuner_Doc_V1_KernClass.with { $0.members = [Wiretuner_Doc_V1_KernClassMember()] }]
            }),
            Ops.elementInsert(WellKnown.settings, FontFields.classKerns, positions: [[0x80], [0x81], [0x82]], values: FontFields.fontValues {
                var empty = Wiretuner_Doc_V1_ClassKern()
                empty.value = -1
                var first = Wiretuner_Doc_V1_ClassKern()
                first.left = left.elementID
                first.right = right.elementID
                first.value = -10
                var second = first
                second.value = -20
                $0.classKerns = [empty, first, second]
            }),
        ])
        var kerning = Kerning(a.state)
        #expect(kerning.storedPairs.isEmpty && kerning.kernClass(left)?.memberships.count == 1)
        #expect(kerning.storedCells.count == 2 && kerning.duplicateCells.count == 1 && kerning.value(g["A"]!, g["V"]!) == -20)
        // The next set of the cell writes the winner and deletes the duplicate.
        try a.perform(SetClassKern(left, right, to: -30))
        kerning = Kerning(a.state)
        #expect(kerning.storedCells.count == 1 && kerning.value(g["A"]!, g["V"]!) == -30)
        // Exceptions list pairs inside classes only, with 0 for a missing cell.
        try a.perform(SetKernPair(g["A"]!, g["O"]!, to: -5))
        try a.perform(SetKernPair(g["C"]!, g["O"]!, to: -5))
        #expect(Kerning(a.state).exceptions.map(\.classValue) == [0])
        // Merging left classes moves cells whose left side is the merged class.
        try a.perform(SetClassKern(classes[3].id, right, to: -7))
        try a.perform(MergeKernClasses(keeping: classes[2].id, merging: classes[3].id))
        #expect(Kerning(a.state).value(g["o"]!, g["V"]!) == -7 && Kerning(a.state).value(g["T"]!, g["V"]!) == -7)
    }

    @Test func fontInfoOddStoredValues() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try Self.raw(&a, [Ops.set(WellKnown.settings, [FontFields.metric(4), FontFields.guides(9), FontFields.guides(11)], values: FontFields.fontValues {
            $0.metrics.xHeight = .nan
            $0.guides.baselineColor = Wiretuner_Doc_V1_Color()
            $0.guides.bearingColor = Wiretuner_Doc_V1_Color()
        })])
        let font = FontInfo(a.state)
        #expect(font.metrics.xHeight == 0 && font.guides.baselineColor != nil && font.guides.bearingColor != nil)
        #expect(FontInfo(Wiretuner_Doc_V1_FontProps()).metrics.ascender == 800)
        // A second extra line goes after the first.
        try a.perform(SetMetricGuides([.addLine(name: "a", y: 1)]))
        try a.perform(SetMetricGuides([.addLine(name: "b", y: 2)]))
        #expect(FontInfo(a.state).guides.extraLines.map(\.name) == ["a", "b"])
    }

    @Test func scaleWithWindowsDescentAndClassKerning() throws {
        var a = Replica(0xA)
        let (glyphA, glyphB, _) = try FontInfoTests.scalable(&a)
        try a.perform(SetFontMetrics(winDescent: .some(300)))
        try a.perform(CreateKernClass("L", side: .left, members: [glyphA]))
        try a.perform(CreateKernClass("R", side: .right, members: [glyphB]))
        let classes = Kerning(a.state).classes
        try a.perform(SetClassKern(classes[0].id, classes[1].id, to: -25))
        try a.perform(SetUnitsPerEm(2_000, scale: true))
        #expect(FontInfo(a.state).metrics.winDescent == 600 && Kerning(a.state).effectiveCells[0].value == -50)
    }

    @Test func generationEdges() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42), NewGlyph(scalar: 0x43)]))
        let g = Dictionary(uniqueKeysWithValues: GlyphIndex(a.state).glyphs.map { ($0.name, $0.id) })
        try a.perform(SetKernPair(g["A"]!, g["B"]!, to: -10))
        try a.perform(CreateKernClass("L", side: .left, members: [g["B"]!]))
        try a.perform(CreateKernClass("R", side: .right, members: [g["C"]!]))
        let classes = Kerning(a.state).classes
        try a.perform(SetClassKern(classes[0].id, classes[1].id, to: -20))
        try a.perform(SetGlyphAttributes([g["B"]!], export: false))
        // B is not exported: its pair, its class and the class's cell drop out; space is synthesized
        // at the default width.
        let snapshot = FontGeneration.snapshot(a.state)
        #expect(snapshot.source.kerning.isEmpty && snapshot.source.kerning.leftClasses.isEmpty && snapshot.source.kerning.rightClasses.count == 1)
        #expect(snapshot.source.glyphs.first { $0.name == "space" }?.advanceWidth == 250)
    }

    @Test func importEdges() throws {
        let box = Contour(polygon: [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 100), Point(x: 0, y: 100)])
        let names = FontSource.Names(family: "F", style: "Regular", postscript: "F-Regular", full: "F")
        func font(fsType: UInt16, panose: [UInt8], kerning: FontSource.Kerning) -> ImportedFont {
            ImportedFont(names: names, metrics: .init(), os2: FontSource.OS2(fsType: fsType, panose: panose), glyphs: [
                .init(name: ".notdef", codepoints: [], advanceWidth: 500, contours: [], components: []),
                .init(name: "A", codepoints: [0x41], advanceWidth: 500, contours: [box], components: []),
                .init(name: "f_i", codepoints: [], advanceWidth: 500, contours: [box], components: []),
                .init(name: "Aring", codepoints: [0xC5], advanceWidth: 500, contours: [], components: [.init(glyph: 1, transform: .identity)]),
            ], kerning: kerning, report: [])
        }
        // One glyph per batch: components resolve against earlier batches; editable embedding;
        // classes without cells.
        var a = Replica(0xA)
        let editable = font(fsType: 8, panose: [], kerning: FontSource.Kerning(leftClasses: [[1]], rightClasses: [[2]]))
        try FontImportTests.perform(FontImport.plan(editable, fileName: "F.otf", into: a.state, newDocument: true, batchSize: 1), on: &a)
        let index = GlyphIndex(a.state)
        #expect(index.glyph(named: "f_i")?.kind == .ligature && index.glyph(named: "Aring")?.components.first?.status == .resolved)
        #expect(FontInfo(a.state).os2.embedding == .editable && Kerning(a.state).classes.count == 2 && Kerning(a.state).storedCells.isEmpty)
        // Preview & print embedding, pairs only; a name taken after planning is skipped.
        var b = Replica(0xB)
        let preview = font(fsType: 4, panose: [1, 2, 3], kerning: FontSource.Kerning(pairs: [.init(left: 1, right: 2, value: -3)]))
        let plan = FontImport.plan(preview, fileName: "F.otf", into: b.state, newDocument: true)
        try b.perform(NewTypeface(family: "x", style: "y", set: nil))
        try b.perform(AddGlyphs([NewGlyph(name: "A")]))
        try FontImportTests.perform(plan, on: &b)
        #expect(FontInfo(b.state).os2.embedding == .previewPrint && GlyphIndex(b.state).glyph(named: "A")?.codepoints == [])
        #expect(GlyphIndex(b.state).glyph(named: "Aring")?.components.first?.source == GlyphIndex(b.state).glyph(named: "A")?.id)
        // An empty font performs as nothing but the settings.
        var c = Replica(0xC)
        let empty = ImportedFont(names: names, metrics: .init(), os2: .init(), glyphs: [], kerning: .init(), report: [])
        try FontImportTests.perform(FontImport.plan(empty, fileName: "E.otf", into: c.state, newDocument: false), on: &c)
        #expect(GlyphIndex(c.state).isEmpty)
    }

    @Test func outlinesOfGroupsLayersAndOtherKinds() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41)]))
        let glyph = TypefaceFixture.glyph("A", in: a)
        let first = try TypefaceFixture.box(0, -100, 100, 100, on: nil, in: &a)
        let second = try TypefaceFixture.box(200, -100, 100, 100, on: nil, in: &a)
        let group = try #require(try a.perform(GroupObjects([first, second]))?.createdObjects.first)
        try TypefaceFixture.place(group, on: glyph, in: &a)
        #expect(GlyphOutlines.metrics(of: glyph, in: a.state)?.bounds == Rect(x: 0, y: -100, width: 300, height: 100))
        // A text block and an empty path on the glyph contribute nothing.
        let layer = LayerOrder(a.state).layers[0].id
        let made = try #require(try a.perform(OpsCommand("Text and empty path", ops: [
            Ops.create(parent: layer, position: [0xF0], props: NodeValues.common(kind: .text) { $0.canvas.id = glyph.proto }),
            Ops.create(parent: layer, position: [0xF1], props: NodeValues.common(kind: .path) { $0.canvas.id = glyph.proto }),
        ])))
        #expect(made.createdNodes.count == 2)
        #expect(GlyphOutlines.metrics(of: glyph, in: a.state)?.bounds == Rect(x: 0, y: -100, width: 300, height: 100))
        // A non-printing layer is left out of the outline.
        try a.perform(CreateLayer(name: "Printing"))
        try a.perform(SetLayerFlag([layer], .printing, false))
        #expect(GlyphOutlines.metrics(of: glyph, in: a.state)?.bounds == nil)
        // Cached outline encoding: an empty contour, and data that does not parse.
        let encoded = GlyphOutlines.encode(FilledPath(contours: [Contour(segments: [], closed: true)]))
        #expect(GlyphOutlines.decode(encoded).contours.count == 1)
        let good = [UInt8](GlyphOutlines.encode(FilledPath(TypefaceFixture.boxContour)))
        for bytes in [[UInt8](), [2], [1, 0, 0], [1, 0xFF, 0xFF, 0xFF, 0xFF], Array(good.prefix(5)), Array(good.prefix(9)), Array(good.prefix(20)),
                      Array(good.prefix(good.count - 2))] {
            #expect(GlyphOutlines.decode(Data(bytes)).isEmpty, "\(bytes.count)")
        }
    }

    @Test func commandEdges() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42)]))
        let glyphA = TypefaceFixture.glyph("A", in: a), glyphB = TypefaceFixture.glyph("B", in: a)
        #expect(RemoveGlyphs([glyphA, glyphB], in: a.state).label == "Remove 2 glyphs")
        // Surrogates in a range are skipped.
        #expect(AddGlyphs.range(0xD7FA...0xD801).glyphs.map(\.codepoints) == [[0xD7FA], [0xD7FB]])
        // Bearings move components too.
        try TypefaceFixture.box(0, -100, 100, 100, on: glyphA, in: &a)
        try a.perform(AddComponent(glyphA, to: glyphB, transform: .translation(x: 50, y: 0)))
        try a.perform(SetGlyphBearings([glyphB], .left(0, keepRSB: false)))
        #expect(GlyphIndex(a.state)[glyphB]?.components[0].transform == .identity)
        // Decompose: a partly unknown list, and a cut loop is skipped.
        let component = try #require(GlyphIndex(a.state)[glyphB]?.components.first?.id)
        #expect(throws: GlyphEditError.unknownElement(glyphA)) { try a.perform(DecomposeComponents(glyphB, components: [component, glyphA])) }
        try Self.raw(&a, [GlyphEditing.componentOp(glyphA, source: glyphB)])
        let loop = try #require(GlyphIndex(a.state)[glyphA]?.components.first { $0.status == .loop } ?? GlyphIndex(a.state)[glyphB]?.components.first { $0.status == .loop })
        let owner = GlyphIndex(a.state)[glyphA]!.components.contains { $0.id == loop.id } ? glyphA : glyphB
        try a.perform(DecomposeComponents(owner, components: [loop.id]))
        #expect(GlyphIndex(a.state)[owner]?.components.contains { $0.id == loop.id } == false)
        // Convert Page to Glyph with a suffixed name encodes nothing; an identity placement writes
        // an empty transform.
        let page = try PageFixture.onePage(&a)
        try a.perform(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([(0, -100), (100, -100), (100, 0), (0, 0)]))],
                                 appearance: GlyphPaths.appearance, transform: .translation(x: 0, y: 792)))
        try a.perform(ConvertPageToGlyph(page, name: "C.alt", scaling: .onePointPerUnit))
        let converted = try #require(GlyphIndex(a.state).glyph(named: "C.alt"))
        #expect(converted.codepoints.isEmpty && GlyphOutlines.metrics(of: converted.id, in: a.state)?.bounds == Rect(x: 0, y: -100, width: 100, height: 100))
        // Converting a typeface without glyphs copies nothing.
        var b = Replica(0xB)
        try TypefaceFixture.typeface(&b, set: nil)
        try b.perform(ConvertDocumentKind(to: .multiPage, options: .init(copyGlyphsToPages: true)))
        #expect(PageList(b.state).isSynthesized)
        // Invalidation ignores objects on a master canvas.
        let masterPage = try PageFixture.onePage(&b)
        try b.perform(NewMasterPage(from: masterPage))
        let onMaster = try TypefaceFixture.box(0, 0, 1, 1, on: nil, in: &b)
        try TypefaceFixture.place(onMaster, on: PageList(b.state).masters[0].id, in: &b)
        let before = b.state
        let moved = try #require(try b.perform(MoveObjects([onMaster], by: Vector(dx: 1, dy: 0))))
        #expect(GlyphInvalidation.glyphs(touchedBy: moved, before: before, after: b.state).isEmpty)
    }
}

extension TypefaceFixture {
    static var boxContour: Contour {
        Contour(polygon: [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 10), Point(x: 0, y: 10)])
    }
}
