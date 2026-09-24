import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FONT-008 / FONT-012 / FONT-013: the glyph commands, components, anchors and the glyph index's
/// read-time normalizations (glyph-grid.adoc, glyph-editing.adoc).
@Suite struct GlyphCommandTests {
    @Test func startingSetsAndNewTypeface() throws {
        var a = Replica(0xA)
        let change = try #require(try a.perform(NewTypeface(family: "Marlowe", style: "Regular", upm: 2_048, set: .latin1)))
        #expect(change.label == "New typeface" && a.core.undoStack.undo.isEmpty)
        let index = GlyphIndex(a.state)
        // 96 Basic Latin, 7 combining marks, 96 Latin-1 Supplement.
        #expect(index.count == 199)
        #expect(index.glyph(named: "A")?.advanceWidth == 1_024 && index.glyph(named: "acutecomb")?.kind == .mark)
        #expect(index.glyph(named: "acutecomb")?.advanceWidth == 0)
        let eacute = try #require(index.glyph(named: "eacute"))
        #expect(eacute.codepoints == [0xE9])
        #expect(eacute.components.map(\.source) == [index.glyph(named: "e")?.id, index.glyph(named: "acutecomb")?.id].map { $0 })
        #expect(eacute.components.allSatisfy { $0.status == .resolved && $0.transform == .identity })
        // Letters with no decomposition have no components.
        #expect(index.glyph(named: "AE")?.components.isEmpty == true)
        #expect(FontInfo(a.state).metrics.ascender == 1_638.4 && FontInfo(a.state).names.family == "Marlowe")
        #expect(throws: GlyphEditError.invalidValue("units per em")) { try a.perform(NewTypeface(family: "x", style: "y", upm: 8)) }
        // Adding a set again skips everything already there.
        #expect(try a.perform(GlyphSet.basicLatin.command()) == nil)
        #expect(GlyphSet.allCases.count == 2)
    }

    @Test func addGlyphsRefusesTakenAndInvalid() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        let change = try #require(try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(named: "f_i"), NewGlyph(named: "a.sc")])))
        #expect(change.label == "Add 3 glyphs")
        let index = GlyphIndex(a.state)
        #expect(index.glyphs.map(\.name) == ["A", "f_i", "a.sc"])
        #expect(index.glyph(named: "f_i")?.kind == .ligature && index.glyph(named: "f_i")?.codepoints == [])
        #expect(index.glyph(named: "a.sc")?.kind == .base && index.glyph(named: "a.sc")?.codepoints == [])
        #expect(throws: GlyphEditError.nameTaken("A")) { try a.perform(AddGlyphs([NewGlyph(name: "A")])) }
        #expect(throws: GlyphEditError.codepointTaken(0x41)) { try a.perform(AddGlyphs([NewGlyph(name: "A.two", codepoints: [0x41])])) }
        #expect(throws: GlyphEditError.invalidName("1")) { try a.perform(AddGlyphs([NewGlyph(name: "1")])) }
        #expect(throws: GlyphEditError.invalidCodepoint(0xD800)) { try a.perform(AddGlyphs([NewGlyph(name: "x", codepoints: [0xD800])])) }
        #expect(throws: GlyphEditError.invalidValue("advance width")) { try a.perform(AddGlyphs([NewGlyph(name: "x", advanceWidth: -1)])) }
        #expect(throws: GlyphEditError.nameTaken("y")) { try a.perform(AddGlyphs([NewGlyph(name: "y"), NewGlyph(name: "y")])) }
        #expect(try a.perform(AddGlyphs([NewGlyph(name: "A")], skipExisting: true)) == nil)
        #expect(AddGlyphs([NewGlyph(name: "q")]).label == "Add glyph")
        // A range adds each missing assigned codepoint after the given glyph.
        let first = index.glyphs[0].id
        try a.perform(AddGlyphs.range(0x40...0x43, after: first))
        #expect(GlyphIndex(a.state).glyphs.map(\.name) == ["A", "at", "B", "C", "f_i", "a.sc"])
        try a.perform(AddGlyphs.range(0x0378...0x0379))
        #expect(GlyphIndex(a.state).count == 6)
        // Components of existing glyphs, placed by anchor arithmetic.
        let base = TypefaceFixture.glyph("A", in: a)
        try a.perform(AddAnchor("top", at: Point(x: 250, y: -700), to: base))
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x301)]))
        let mark = TypefaceFixture.glyph("acutecomb", in: a)
        try a.perform(AddAnchor("_top", at: Point(x: 50, y: -500), to: mark))
        try a.perform(AddGlyphs([NewGlyph(name: "Aacute", codepoints: [0xC1], components: [.init(source: .glyph(base)), .init(source: .glyph(mark)),
                                                                     .init(source: .glyph(OpID(counter: 9_999, replica: 1)))])]))
        let aacute = try #require(GlyphIndex(a.state).glyph(named: "Aacute"))
        #expect(aacute.components.count == 2 && aacute.components[1].transform == .translation(x: 200, y: -200))
    }

    @Test func renameAndCodepoints() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42)]))
        let glyphA = TypefaceFixture.glyph("A", in: a)
        let glyphB = TypefaceFixture.glyph("B", in: a)
        #expect(try a.perform(RenameGlyph(glyphA, to: "A.alt"))?.label == "Rename glyph")
        #expect(try a.perform(RenameGlyph(glyphA, to: "A.alt")) == nil)
        #expect(throws: GlyphEditError.nameTaken("B")) { try a.perform(RenameGlyph(glyphA, to: "B")) }
        #expect(throws: GlyphEditError.invalidName("a b")) { try a.perform(RenameGlyph(glyphA, to: "a b")) }
        #expect(throws: GlyphEditError.notAGlyph(WellKnown.settings)) { try a.perform(RenameGlyph(WellKnown.settings, to: "Z")) }
        #expect(try a.perform(SetGlyphCodepoints(glyphA, add: [0x391], remove: [0x41]))?.label == "Set Unicode")
        #expect(TypefaceFixture.codepoints(glyphA, in: a) == [0x391])
        #expect(throws: GlyphEditError.codepointTaken(0x42)) { try a.perform(SetGlyphCodepoints(glyphA, add: [0x42])) }
        #expect(throws: GlyphEditError.invalidCodepoint(0x110000)) { try a.perform(SetGlyphCodepoints(glyphA, add: [0x110000])) }
        #expect(try a.perform(SetGlyphCodepoints(glyphA, add: [0x391], remove: [0x999])) == nil)
        #expect(try a.perform(MoveGlyphCodepoint(0x42, to: glyphA))?.label == "Move Unicode")
        #expect(TypefaceFixture.codepoints(glyphA, in: a) == [0x42, 0x391] && TypefaceFixture.codepoints(glyphB, in: a).isEmpty)
        #expect(try a.perform(MoveGlyphCodepoint(0x42, to: glyphA)) == nil)
        #expect(throws: GlyphEditError.invalidCodepoint(0xDC00)) { try a.perform(MoveGlyphCodepoint(0xDC00, to: glyphA)) }
    }

    @Test func removeRestoreAndReorder() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42), NewGlyph(scalar: 0x43)]))
        let glyphA = TypefaceFixture.glyph("A", in: a)
        let glyphC = TypefaceFixture.glyph("C", in: a)
        let drawn = try TypefaceFixture.box(0, -700, 100, 700, on: glyphA, in: &a)
        let command = RemoveGlyphs([glyphA], in: a.state)
        #expect(command.label == "Remove glyph A" && RemoveGlyphs([glyphA]).label == "Remove glyph")
        #expect(RemoveGlyphs([glyphA, glyphC]).label == "Remove 2 glyphs")
        try a.perform(command)
        #expect(GlyphIndex(a.state).glyph(named: "A") == nil && !a.state.isLive(drawn))
        a.undo()
        #expect(GlyphIndex(a.state).glyph(named: "A") != nil && a.state.isLive(drawn))
        #expect(throws: GlyphEditError.notAGlyph(drawn)) { try a.perform(RemoveGlyphs([drawn])) }
        #expect(try a.perform(ReorderGlyph(glyphC, to: 1))?.label == "Move glyph")
        #expect(GlyphIndex(a.state).glyphs.map(\.name) == ["C", "A", "B"])
        #expect(try a.perform(ReorderGlyph(glyphC, to: 0)) == nil)
        try a.perform(ReorderGlyph(glyphC, to: 99))
        #expect(GlyphIndex(a.state).glyphs.map(\.name) == ["A", "B", "C"] && GlyphIndex(a.state)[glyphC]?.order == 3)
        try a.perform(ReorderGlyph(glyphC, to: 2))
        #expect(GlyphIndex(a.state).glyphs.map(\.name) == ["A", "C", "B"])
        // Adding after a glyph lands between it and the next live one.
        try a.perform(AddGlyphs([NewGlyph(name: "x")], after: glyphA))
        #expect(GlyphIndex(a.state).glyphs.map(\.name) == ["A", "x", "C", "B"])
    }

    @Test func widthsBearingsAndTransforms() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42)]))
        let glyph = TypefaceFixture.glyph("A", in: a)
        let empty = TypefaceFixture.glyph("B", in: a)
        let drawn = try TypefaceFixture.box(50, -700, 300, 700, on: glyph, in: &a)
        try a.perform(AddAnchor("top", at: Point(x: 200, y: -700), to: glyph))
        #expect(GlyphOutlines.metrics(of: glyph, in: a.state) == GlyphMetrics(advanceWidth: 500, bounds: Rect(x: 50, y: -700, width: 300, height: 700)))
        #expect(GlyphOutlines.metrics(of: glyph, in: a.state)?.rightSideBearing == 150)
        #expect(GlyphOutlines.metrics(of: drawn, in: a.state) == nil)
        #expect(GlyphMetrics(advanceWidth: 300, bounds: nil).rightSideBearing == 300)
        #expect(try a.perform(SetGlyphWidth([glyph, empty], to: 600))?.label == "Set width of 2 glyphs")
        #expect(SetGlyphWidth([glyph], to: 1).label == "Set width")
        #expect(try a.perform(SetGlyphWidth([glyph], to: 600)) == nil)
        #expect(throws: GlyphEditError.invalidValue("advance width")) { try a.perform(SetGlyphWidth([glyph], to: .nan)) }
        // LSB 100 keeping the RSB: the artwork moves 50 and the width grows 50.
        #expect(try a.perform(SetGlyphBearings([glyph], .left(100, keepRSB: true)))?.label == "Set left side bearing")
        var metrics = try #require(GlyphOutlines.metrics(of: glyph, in: a.state))
        #expect(metrics.leftSideBearing == 100 && metrics.advanceWidth == 650 && metrics.rightSideBearing == 250)
        #expect(GlyphIndex(a.state)[glyph]?.anchors[0].position == Point(x: 250, y: -700))
        try a.perform(SetGlyphBearings([glyph], .right(50)))
        metrics = try #require(GlyphOutlines.metrics(of: glyph, in: a.state))
        #expect(metrics.advanceWidth == 450 && metrics.rightSideBearing == 50)
        #expect(try a.perform(SetGlyphBearings([glyph, empty], .center))?.label == "Center in width of 2 glyphs")
        metrics = try #require(GlyphOutlines.metrics(of: glyph, in: a.state))
        #expect(metrics.leftSideBearing == 75 && metrics.rightSideBearing == 75)
        try a.perform(SetGlyphBearings([glyph], .left(10, keepRSB: false)))
        #expect(GlyphOutlines.metrics(of: glyph, in: a.state)?.advanceWidth == 450)
        #expect(SetGlyphBearings([glyph], .right(1)).label == "Set right side bearing")
        #expect(throws: GlyphEditError.invalidValue("left side bearing")) { try a.perform(SetGlyphBearings([glyph], .left(.infinity, keepRSB: false))) }
        #expect(throws: GlyphEditError.invalidValue("right side bearing")) { try a.perform(SetGlyphBearings([glyph], .right(.nan))) }
        // Transform: a 2× scale about the origin with the width.
        #expect(try a.perform(TransformGlyphs([glyph], by: .scale(2), scaleWidth: true))?.label == "Transform glyph")
        metrics = try #require(GlyphOutlines.metrics(of: glyph, in: a.state))
        #expect(metrics.bounds == Rect(x: 20, y: -1_400, width: 600, height: 1_400) && metrics.advanceWidth == 900)
        #expect(TransformGlyphs([glyph, empty], by: .identity).label == "Transform 2 glyphs")
        #expect(throws: ObjectEditError.degenerateTransform) { try a.perform(TransformGlyphs([glyph], by: .scale(0))) }
        #expect(throws: GlyphEditError.invalidValue("advance width")) { try a.perform(TransformGlyphs([glyph], by: .scale(100), scaleWidth: true)) }
    }

    @Test func attributes() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41)]))
        let glyph = TypefaceFixture.glyph("A", in: a)
        #expect(try a.perform(SetGlyphAttributes([glyph], kind: .component))?.label == "Set glyph kind")
        #expect(try a.perform(SetGlyphAttributes([glyph], markColor: 3))?.label == "Set mark color")
        #expect(try a.perform(SetGlyphAttributes([glyph], export: false))?.label == "Set export")
        #expect(try a.perform(SetGlyphAttributes([glyph], note: "check"))?.label == "Set note")
        let read = try #require(GlyphIndex(a.state)[glyph])
        #expect(read.kind == .component && read.markColor == 3 && read.skipExport && read.note == "check")
        #expect(try a.perform(SetGlyphAttributes([glyph], kind: .component, markColor: 3, export: false, note: "check")) == nil)
        #expect(throws: GlyphEditError.invalidValue("mark color")) { try a.perform(SetGlyphAttributes([glyph], markColor: 13)) }
        #expect(GlyphKind.allCases.map { GlyphKind(stored: $0.stored) } == GlyphKind.allCases)
    }

    @Test func componentsAddMoveRemoveAndDecompose() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42), NewGlyph(scalar: 0x301)]))
        let glyphA = TypefaceFixture.glyph("A", in: a)
        let glyphB = TypefaceFixture.glyph("B", in: a)
        let mark = TypefaceFixture.glyph("acutecomb", in: a)
        try TypefaceFixture.box(0, -100, 100, 100, on: mark, in: &a)
        try TypefaceFixture.box(0, -700, 400, 700, on: glyphA, in: &a)
        #expect(try a.perform(AddComponent(glyphA, to: glyphB))?.label == "Add component")
        #expect(throws: GlyphEditError.componentLoop) { try a.perform(AddComponent(glyphB, to: glyphA)) }
        #expect(throws: GlyphEditError.componentLoop) { try a.perform(AddComponent(glyphA, to: glyphA)) }
        try a.perform(AddAnchor("top", at: Point(x: 200, y: -700), to: glyphB))
        try a.perform(AddAnchor("_top", at: Point(x: 50, y: 0), to: mark))
        try a.perform(AddComponent(mark, to: glyphB))
        var read = try #require(GlyphIndex(a.state)[glyphB])
        #expect(read.components.count == 2 && read.components[1].transform == .translation(x: 150, y: -700))
        #expect(!GlyphOutlines.decode(read.components[0].cached).isEmpty)
        #expect(GlyphOutlines.metrics(of: glyphB, in: a.state)?.bounds == Rect(x: 0, y: -800, width: 400, height: 800))
        #expect(GlyphIndex(a.state).users(of: glyphA).map(\.id) == [glyphB])
        #expect(throws: GlyphEditError.invalidValue("transform")) {
            try a.perform(AddComponent(mark, to: glyphB, transform: AffineTransform(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0)))
        }
        let component = read.components[1].id
        #expect(try a.perform(SetComponentTransform(component, of: glyphB, to: .translation(x: 10, y: 0)))?.label == "Move component")
        try a.perform(SetComponentTransform(component, of: glyphB, to: .identity))
        #expect(GlyphIndex(a.state)[glyphB]?.components[1].transform == .identity)
        #expect(throws: GlyphEditError.unknownElement(glyphA)) { try a.perform(SetComponentTransform(glyphA, of: glyphB, to: .identity)) }
        #expect(throws: GlyphEditError.invalidValue("transform")) {
            try a.perform(SetComponentTransform(component, of: glyphB, to: AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: .infinity, ty: 0)))
        }
        // Decompose: the element goes and one path per contour lands on the glyph's canvas.
        #expect(try a.perform(DecomposeComponents(glyphB, components: [component]))?.label == "Decompose")
        read = try #require(GlyphIndex(a.state)[glyphB])
        #expect(read.components.count == 1 && GlyphArtwork.objectIDs(on: glyphB, in: a.state).count == 1)
        #expect(throws: GlyphEditError.unknownElement(component)) { try a.perform(DecomposeComponents(glyphB, components: [component])) }
        try a.perform(DecomposeComponents(glyphB))
        #expect(GlyphIndex(a.state)[glyphB]?.components.isEmpty == true && GlyphArtwork.objectIDs(on: glyphB, in: a.state).count == 2)
        #expect(try a.perform(DecomposeComponents(glyphB)) == nil)
        #expect(GlyphOutlines.metrics(of: glyphB, in: a.state)?.bounds == Rect(x: 0, y: -700, width: 400, height: 700))
        // Remove.
        try a.perform(AddComponent(glyphA, to: glyphB))
        let added = try #require(GlyphIndex(a.state)[glyphB]?.components[0].id)
        #expect(try a.perform(RemoveComponents([added], of: glyphB))?.label == "Remove component")
        #expect(RemoveComponents([added, added], of: glyphB).label == "Remove 2 components")
        #expect(throws: GlyphEditError.unknownElement(added)) { try a.perform(RemoveComponents([added], of: glyphB)) }
        #expect(try a.perform(RemoveComponents([], of: glyphB)) == nil)
    }

    @Test func decomposeDanglingFromTheCachedOutline() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42)]))
        let glyphA = TypefaceFixture.glyph("A", in: a)
        let glyphB = TypefaceFixture.glyph("B", in: a)
        try TypefaceFixture.box(0, -700, 400, 700, on: glyphA, in: &a)
        try a.perform(AddComponent(glyphA, to: glyphB, transform: .translation(x: 10, y: 0)))
        try a.perform(RemoveGlyphs([glyphA]))
        let component = try #require(GlyphIndex(a.state)[glyphB]?.components[0])
        #expect(component.status == .dangling)
        // The placeholder still draws the cached outline.
        #expect(GlyphOutlines.metrics(of: glyphB, in: a.state)?.bounds == Rect(x: 10, y: -700, width: 400, height: 700))
        try a.perform(DecomposeComponents(glyphB))
        #expect(GlyphOutlines.metrics(of: glyphB, in: a.state)?.bounds == Rect(x: 10, y: -700, width: 400, height: 700))
    }

    @Test func anchorsAddEditAndNormalize() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41)]))
        let glyph = TypefaceFixture.glyph("A", in: a)
        #expect(try a.perform(AddAnchor("top", at: Point(x: 1, y: 2), to: glyph))?.label == "Add anchor")
        try a.perform(AddAnchor("_bottom", at: Point(x: 3, y: 4), to: glyph))
        try a.perform(AddAnchor("ogonek", at: .zero, to: glyph, role: .mark))
        var anchors = try #require(GlyphIndex(a.state)[glyph]?.anchors)
        #expect(anchors.map(\.role) == [.base, .mark, .mark] && anchors.map(\.attachmentName) == ["top", "bottom", "ogonek"])
        #expect(throws: GlyphEditError.invalidName("a b")) { try a.perform(AddAnchor("a b", at: .zero, to: glyph)) }
        #expect(throws: GlyphEditError.invalidValue("position")) { try a.perform(AddAnchor("x", at: Point(x: .nan, y: 0), to: glyph)) }
        let top = anchors[0].id
        #expect(try a.perform(EditAnchor(top, of: glyph, .move(Point(x: 5, y: 6))))?.label == "Move anchor")
        #expect(try a.perform(EditAnchor(top, of: glyph, .rename("_top")))?.label == "Rename anchor")
        #expect(try a.perform(EditAnchor(top, of: glyph, .role(.base)))?.label == "Set anchor role")
        anchors = try #require(GlyphIndex(a.state)[glyph]?.anchors)
        #expect(anchors[0].name == "_top" && anchors[0].role == .base && anchors[0].position == Point(x: 5, y: 6))
        #expect(GlyphIndex(a.state)[glyph]?.anchor(named: "_top")?.id == top)
        #expect(throws: GlyphEditError.invalidValue("position")) { try a.perform(EditAnchor(top, of: glyph, .move(Point(x: 0, y: .infinity)))) }
        #expect(throws: GlyphEditError.invalidName("")) { try a.perform(EditAnchor(top, of: glyph, .rename(""))) }
        #expect(throws: GlyphEditError.unknownElement(glyph)) { try a.perform(EditAnchor(glyph, of: glyph, .remove)) }
        #expect(try a.perform(EditAnchor(top, of: glyph, .remove))?.label == "Remove anchor")
        #expect(GlyphIndex(a.state)[glyph]?.anchors.count == 2)
        // Same-named anchors: the smaller element id keeps the name.
        try a.perform(AddAnchor("_bottom", at: .zero, to: glyph))
        try a.perform(AddAnchor("_bottom", at: .zero, to: glyph))
        anchors = try #require(GlyphIndex(a.state)[glyph]?.anchors)
        #expect(anchors.map(\.name) == ["_bottom", "ogonek", "_bottom.dup1", "_bottom.dup2"])
        #expect(anchors.map(\.isDuplicate) == [false, false, true, true])
    }

    @Test func indexNormalizesStoredValues() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        let key: (UInt8) -> [UInt8] = { [0x80, $0] }
        func create(_ build: (inout Wiretuner_Doc_V1_GlyphProps) -> Void, at position: UInt8) -> Wiretuner_Doc_V1_Op {
            Ops.create(parent: WellKnown.glyphs, position: key(position), props: GlyphFields.values(build))
        }
        let change = try #require(try a.perform(OpsCommand("Older client", ops: [
            create({ $0.name = "" }, at: 1),
            create({ $0.name = "b"; $0.advanceWidth = .infinity; $0.kind = .unspecified; $0.markColor = 40 }, at: 2),
            create({ $0.name = "c" }, at: 3),
        ])))
        let ids = change.createdNodes
        let index = GlyphIndex(a.state)
        #expect(index.glyphs[0].name == "glyph\(ids[0].counter)_a" && index.glyphs[0].nameStatus == .invalid)
        #expect(index.glyphs[1].advanceWidth == 0 && index.glyphs[1].kind == .base && index.glyphs[1].markColor == 12)
        // A component with an anchor at a non-finite position, a stored member above U+10FFFF.
        try a.perform(OpsCommand("Odd", ops: [
            Ops.elementInsert(ids[2], GlyphFields.anchors, positions: [[0x80]], values: GlyphFields.values {
                var anchor = Wiretuner_Doc_V1_GlyphAnchor()
                anchor.name = "top"
                anchor.position.x = .nan
                $0.anchors = [anchor]
            }),
            Ops.setAdd(ids[2], GlyphFields.codepoints, values: GlyphFields.codepointValues([0x41])),
        ]))
        #expect(GlyphIndex(a.state)[ids[2]]?.anchors[0].position == .zero)
        #expect(GlyphIndex(a.state).names.contains("c") && GlyphIndex(a.state).holder(of: 0x41)?.id == ids[2])
        #expect(GlyphIndex.codepoints(of: ids[1], in: a.state).isEmpty)
    }
}
