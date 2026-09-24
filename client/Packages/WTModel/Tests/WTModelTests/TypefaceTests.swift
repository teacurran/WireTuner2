import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Typeface fixtures shared by the FONT test suites.
enum TypefaceFixture {
    /// A typeface document ("Marlowe Regular", 1000 UPM) with `set`.
    @discardableResult
    static func typeface(_ replica: inout Replica, set: GlyphSet? = .basicLatin, upm: Int = 1_000) throws -> GlyphIndex {
        try replica.perform(NewTypeface(family: "Marlowe", style: "Regular", upm: upm, set: set))
        return GlyphIndex(replica.state)
    }

    /// The glyph named `name`.
    static func glyph(_ name: String, in replica: Replica) -> OpID {
        GlyphIndex(replica.state).glyph(named: name)!.id
    }

    /// A black-filled closed polygon drawn on `glyph`'s canvas (glyph space).
    @discardableResult
    static func draw(_ points: [(Double, Double)], on glyph: OpID?, in replica: inout Replica) throws -> OpID {
        let node = try replica.perform(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points(points))],
                                                  appearance: GlyphPaths.appearance))!.createdObjects[0]
        if let glyph { try place(node, on: glyph, in: &replica) }
        return node
    }

    /// A rectangle `x`...`x + width` by `y`...`y + height` (glyph space, y down) on `glyph`.
    @discardableResult
    static func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double, on glyph: OpID?, in replica: inout Replica) throws -> OpID {
        try draw([(x, y), (x + width, y), (x + width, y + height), (x, y + height)], on: glyph, in: &replica)
    }

    /// Writes `canvas` = `glyph` on `node`.
    static func place(_ node: OpID, on glyph: OpID, in replica: inout Replica) throws {
        let kind = replica.state.nodeKind(node)!
        try replica.perform(OpsCommand("Place", ops: [Ops.set(node, [CommonFields.canvas(kind)], values: NodeValues.common(kind: kind) {
            $0.canvas.id = glyph.proto
        })]))
    }

    static func codepoints(_ glyph: OpID, in replica: Replica) -> [UInt32] {
        GlyphIndex(replica.state)[glyph]?.codepoints ?? []
    }
}

/// FONT-002: the document kind, glyph-canvas space, canvas membership, the conversions and the
/// page ↔ glyph commands (typeface-documents.adoc).
@Suite struct TypefaceTests {
    @Test func kindReadsMultiPageUntilWrittenAndLaysOutByPages() throws {
        var a = Replica(0xA)
        #expect(DocumentKind(a.state) == .multiPage && DocumentKind.layout(a.state) == .multiPage)
        #expect(DocumentKind.allCases.map(\.title) == ["Single-page illustration", "Multi-page illustration", "Typeface"])
        #expect(DocumentKind.allCases.map { DocumentKind(stored: $0.stored) } == DocumentKind.allCases)
        #expect(DocumentKind(stored: .unspecified) == .multiPage)
        let change = try #require(try a.perform(ConvertDocumentKind(to: .singlePage)))
        #expect(change.label == "Convert to single-page illustration")
        #expect(DocumentKind(a.state) == .singlePage)
        // Writing the kind that is already read as the stored value is still one write when unset.
        var b = Replica(0xB)
        #expect(try b.perform(ConvertDocumentKind(to: .multiPage))?.label == "Convert to multi-page illustration")
        #expect(try b.perform(ConvertDocumentKind(to: .multiPage)) == nil)
        // A single-page document with a second page (a concurrent add) lays out as multi-page.
        let page = try PageFixture.onePage(&a)
        try a.perform(OpsCommand("Add page", ops: [Ops.create(parent: WellKnown.pages, position: [0xF0], props: PageFields.values {
            $0.geometry = PageGeometry.letter.stored
        })]))
        #expect(DocumentKind(a.state) == .singlePage && DocumentKind.layout(a.state) == .multiPage)
        #expect(throws: DocumentKindError.tooManyPages(2)) { try a.perform(ConvertDocumentKind(to: .singlePage)) }
        _ = page
    }

    @Test func canvasSpacePresentsFontY() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil, upm: 2_048)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41)]))
        let glyph = TypefaceFixture.glyph("A", in: a)
        let space = CanvasSpace.of(glyph, in: a.state)
        #expect(space == .glyph(upm: 2_048))
        #expect(space.displayY(-700) == 700 && space.storedY(700) == -700 && space.displayY(0) == 0)
        #expect(space.displayPoint(Point(x: 3, y: -4)) == Point(x: 3, y: 4))
        #expect(space.unitLabel == "Font units" && !space.unitsEditable && space.defaultGridSize == 10)
        let board = CanvasSpace.of(nil, in: a.state)
        #expect(board == .pasteboard(.points) && board.displayY(5) == 5 && board.unitLabel == "Points" && board.unitsEditable)
        #expect(board.defaultGridSize == GridSettings.defaultSize)
        #expect(CanvasSpace.of(WellKnown.pages, in: a.state) == board)
    }

    @Test func canvasMembershipFollowsGlyphsKindAndMasters() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41)]))
        let glyph = TypefaceFixture.glyph("A", in: a)
        let drawn = try TypefaceFixture.box(0, -700, 500, 700, on: glyph, in: &a)
        let loose = try TypefaceFixture.box(0, 0, 10, 10, on: nil, in: &a)
        #expect(CanvasMembership.placement(of: drawn, in: a.state) == .canvas(glyph))
        #expect(CanvasMembership.placement(of: loose, in: a.state) == .pasteboard)
        #expect(CanvasMembership.placement(of: WellKnown.settings, in: a.state) == .pasteboard)
        #expect(CanvasMembership.belongs(drawn, to: glyph, in: a.state) && !CanvasMembership.belongs(drawn, to: nil, in: a.state))
        #expect(CanvasMembership.belongs(loose, to: nil, in: a.state))
        let common = NodeValues.common(a.state.props(drawn))!
        #expect(CanvasMembership.draws(common, on: glyph, in: a.state) && !CanvasMembership.draws(common, on: nil, in: a.state))
        #expect(CanvasMembership.draws(Wiretuner_Doc_V1_CommonProps(), on: glyph, in: a.state))
        // A deleted glyph's objects read on the Sketches pasteboard; restoring re-attaches them.
        try a.perform(OpsCommand("Delete glyph", ops: [Ops.setDeleted(glyph)]))
        #expect(CanvasMembership.placement(of: drawn, in: a.state) == .pasteboard)
        #expect(CanvasMembership.draws(common, on: nil, in: a.state))
        try a.perform(RestoreGlyph(glyph))
        #expect(CanvasMembership.placement(of: drawn, in: a.state) == .canvas(glyph))
        // In an illustration document glyph content is hidden with its glyph.
        try a.perform(ConvertDocumentKind(to: .multiPage))
        #expect(CanvasMembership.placement(of: drawn, in: a.state) == .hidden)
        #expect(!CanvasMembership.belongs(drawn, to: nil, in: a.state) && !CanvasMembership.draws(common, on: nil, in: a.state))
        // Masters: live → their canvas; deleted → nowhere; a canvas naming nothing → pasteboard.
        let page = try PageFixture.onePage(&a)
        try a.perform(NewMasterPage(from: page))
        let master = PageList(a.state).masters[0].id
        try TypefaceFixture.place(loose, on: master, in: &a)
        #expect(CanvasMembership.placement(of: loose, in: a.state) == .canvas(master))
        try a.perform(DeleteMasterPage(master))
        #expect(CanvasMembership.placement(of: loose, in: a.state) == .hidden)
        try TypefaceFixture.place(loose, on: OpID(counter: 999, replica: 9), in: &a)
        #expect(CanvasMembership.placement(of: loose, in: a.state) == .pasteboard)
        #expect(throws: GlyphEditError.notAGlyph(loose)) { try a.perform(RestoreGlyph(loose)) }
    }

    @Test func convertToTypefaceWritesDefaultsOnceAndAddsBasicLatin() throws {
        var a = Replica(0xA)
        try a.perform(SetFontMetrics([.xHeight: 480]))
        let change = try #require(try a.perform(ConvertDocumentKind(to: .typeface, options: .init(addBasicLatin: true))))
        #expect(change.label == "Convert to typeface")
        #expect(DocumentKind(a.state) == .typeface)
        let font = FontInfo(a.state)
        #expect(font.metrics.upm == 1_000 && font.metrics.ascender == 800 && font.metrics.descender == -200 && font.metrics.xHeight == 480)
        #expect(font.names.version == "1.000" && font.os2.weightClass == 400 && font.os2.vendorID == "WTNR")
        let index = GlyphIndex(a.state)
        #expect(index.count == 96 && index.glyphs[0].name == ".notdef" && index.glyph(for: 0x41)?.name == "A")
        #expect(index.glyph(named: "space")?.advanceWidth == 500)
        // Converting back and forth keeps the glyphs; the defaults are not written twice.
        try a.perform(ConvertDocumentKind(to: .multiPage))
        #expect(GlyphIndex(a.state).count == 96)
        let again = try #require(try a.perform(ConvertDocumentKind(to: .typeface)))
        #expect(again.ops.count == 1)
        a.undo()
        #expect(DocumentKind(a.state) == .multiPage)
    }

    @Test func convertToIllustrationCopiesGlyphsToPages() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42)]))
        let glyphA = TypefaceFixture.glyph("A", in: a)
        let drawn = try TypefaceFixture.box(10, -700, 400, 700, on: glyphA, in: &a)
        try a.perform(ConvertDocumentKind(to: .multiPage, options: .init(copyGlyphsToPages: true)))
        let pages = PageList(a.state).pages
        #expect(pages.map(\.name) == ["A", "B"])
        #expect(pages.map(\.geometry.width) == [1_000, 1_000] && pages[0].origin == .zero && pages[1].origin.x == 1_072)
        let copies = PageObjects.objects(on: pages[0], in: a.state, pages: PageList(a.state))
        #expect(copies.count == 1 && copies[0].id != drawn)
        // One unit per point, the ascender line at the page's top.
        #expect(copies[0].bounds == Rect(x: 10, y: 100, width: 400, height: 700))
        // The glyph itself is kept (hidden) and its artwork untouched.
        #expect(GlyphIndex(a.state).count == 2 && CanvasMembership.placement(of: drawn, in: a.state) == .hidden)
        a.undo()
        #expect(PageList(a.state).isSynthesized && DocumentKind(a.state) == .typeface)
        // Copy Glyph to Page appends after the existing pages.
        try PageFixture.onePage(&a)
        let copy = try #require(try a.perform(CopyGlyphToPage(glyphA)))
        #expect(copy.label == "Copy glyph to page")
        #expect(PageList(a.state).pages.map(\.origin.x) == [0, 684])
        #expect(throws: GlyphEditError.notAGlyph(drawn)) { try a.perform(CopyGlyphToPage(drawn)) }
    }

    @Test func convertPageToGlyphMovesAndUndoRestoresTransforms() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        let page = try PageFixture.onePage(&a)
        // A 612 × 792 page; a box 100 pt above the bottom edge.
        let object = try TypefaceFixture.box(50, 592, 100, 100, on: nil, in: &a)
        let change = try #require(try a.perform(ConvertPageToGlyph(page, name: "A", scaling: .onePointPerUnit)))
        #expect(change.label == "Convert page to glyph")
        let glyph = TypefaceFixture.glyph("A", in: a)
        #expect(GlyphIndex(a.state)[glyph]?.codepoints == [0x41] && GlyphIndex(a.state)[glyph]?.advanceWidth == 612)
        #expect(GlyphArtwork.objectIDs(on: glyph, in: a.state) == [object])
        // The page's bottom-left corner is the glyph origin: the box sits 100 units above the baseline.
        #expect(Objects.bounds(of: object, in: a.state) == Rect(x: 50, y: -200, width: 100, height: 100))
        a.undo()
        #expect(GlyphIndex(a.state).isEmpty && CanvasMembership.placement(of: object, in: a.state) == .pasteboard)
        #expect(Objects.bounds(of: object, in: a.state) == Rect(x: 50, y: 592, width: 100, height: 100))
    }

    @Test func convertPageToGlyphScalesThePageHeightToTheEmAndCopies() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        let page = try PageFixture.onePage(&a)
        try a.perform(SetPageGeometry([page], to: PageGeometry(width: 500, height: 500)))
        let object = try TypefaceFixture.box(0, 400, 100, 100, on: nil, in: &a)
        try a.perform(ConvertPageToGlyph(page, name: "B.alt", codepoints: [], scaling: .pageHeightIsEm, move: false))
        let glyph = TypefaceFixture.glyph("B.alt", in: a)
        #expect(GlyphIndex(a.state)[glyph]?.codepoints == [] && GlyphIndex(a.state)[glyph]?.advanceWidth == 1_000)
        let copies = GlyphArtwork.objectIDs(on: glyph, in: a.state)
        #expect(copies.count == 1 && copies[0] != object)
        // Scale 2; the page's bottom edge is the descender line (200 units below the baseline).
        #expect(Objects.bounds(of: copies[0], in: a.state) == Rect(x: 0, y: 0, width: 200, height: 200))
        #expect(CanvasMembership.placement(of: object, in: a.state) == .pasteboard)
        // Refusals: invalid or taken name, taken codepoint, not a page.
        #expect(throws: GlyphEditError.invalidName("9x")) { try a.perform(ConvertPageToGlyph(page, name: "9x")) }
        #expect(throws: GlyphEditError.nameTaken("B.alt")) { try a.perform(ConvertPageToGlyph(page, name: "B.alt")) }
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x43)]))
        #expect(throws: GlyphEditError.codepointTaken(0x43)) { try a.perform(ConvertPageToGlyph(page, name: "C.two", codepoints: [0x43])) }
        #expect(throws: PageSetupError.notAPage(glyph)) { try a.perform(ConvertPageToGlyph(glyph, name: "D")) }
    }

    @Test func invalidationReachesUsersAndMovedArtwork() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42), NewGlyph(scalar: 0x43), NewGlyph(scalar: 0x44)]))
        let g = Dictionary(uniqueKeysWithValues: GlyphIndex(a.state).glyphs.map { ($0.name, $0.id) })
        try a.perform(AddComponent(g["A"]!, to: g["B"]!))
        try a.perform(AddComponent(g["B"]!, to: g["C"]!))
        let group = try a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10)))!.createdObjects[0]
        try TypefaceFixture.place(group, on: g["A"]!, in: &a)
        // Editing A's artwork reaches A, B (uses A) and C (uses B), not D.
        var before = a.state
        let move = try #require(try a.perform(MoveObjects([group], by: Vector(dx: 5, dy: 0))))
        #expect(GlyphInvalidation.glyphs(touchedBy: move, before: before, after: a.state) == [g["A"]!, g["B"]!, g["C"]!])
        // Moving the object to D's canvas reaches both glyphs' users.
        before = a.state
        try TypefaceFixture.place(group, on: g["D"]!, in: &a)
        let place = a.sent.last!
        #expect(GlyphInvalidation.glyphs(touchedBy: place, before: before, after: a.state) == [g["A"]!, g["B"]!, g["C"]!, g["D"]!])
        // A glyph write, and a pasteboard object that touches none.
        before = a.state
        let width = try #require(try a.perform(SetGlyphWidth([g["D"]!], to: 1)))
        #expect(GlyphInvalidation.glyphs(touchedBy: width, before: before, after: a.state) == [g["D"]!])
        before = a.state
        let loose = try #require(try a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 1, height: 1))))
        #expect(GlyphInvalidation.glyphs(touchedBy: loose, before: before, after: a.state).isEmpty)
    }

    @Test func glyphArtworkQueriesByGlyph() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42)]))
        let glyphA = TypefaceFixture.glyph("A", in: a)
        let glyphB = TypefaceFixture.glyph("B", in: a)
        let first = try TypefaceFixture.box(0, 0, 10, 10, on: glyphA, in: &a)
        let second = try TypefaceFixture.box(0, 0, 10, 10, on: glyphB, in: &a)
        let third = try TypefaceFixture.box(0, 0, 10, 10, on: glyphA, in: &a)
        try TypefaceFixture.box(0, 0, 10, 10, on: nil, in: &a)
        let page = try PageFixture.onePage(&a)
        try a.perform(NewMasterPage(from: page))
        try TypefaceFixture.place(try TypefaceFixture.box(0, 0, 1, 1, on: nil, in: &a), on: PageList(a.state).masters[0].id, in: &a)
        let all = GlyphArtwork.objectsByGlyph(in: a.state)
        #expect(all.count == 2 && all[glyphA]?.flatMap(\.objects) == [first, third] && all[glyphB]?.flatMap(\.objects) == [second])
        #expect(GlyphArtwork.objectIDs(on: glyphA, in: a.state) == [first, third])
    }
}
