import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Two-replica merge tests of the typeface model (FONT-002, -005, -008, -012, -013, -016): every
/// case converges to one state hash and reads as the spec's merge semantics say.
@Suite struct TypefaceMergeTests {
    /// A pair whose replicas share a typeface with `glyphs` (by scalar).
    static func shared(_ scalars: [UInt32] = [0x41, 0x42]) throws -> Pair {
        var pair = Pair()
        try TypefaceFixture.typeface(&pair.a, set: nil)
        try pair.a.perform(AddGlyphs(scalars.map(NewGlyph.init(scalar:))))
        pair.sync()
        return pair
    }

    static func converged(_ pair: Pair) -> Bool {
        pair.a.state.stateHash == pair.b.state.stateHash
    }

    // MARK: FONT-002

    @Test func kindVersusKindLaterWinsAndTheLoserIsKept() throws {
        var pair = Pair()
        let a = try #require(try pair.a.perform(ConvertDocumentKind(to: .typeface)))
        let b = try #require(try pair.b.perform(ConvertDocumentKind(to: .singlePage)))
        pair.sync()
        #expect(Self.converged(pair))
        let later = PageFixture.later(a, b)
        #expect(DocumentKind(pair.a.state) == (later ? .typeface : .singlePage))
        // Both writes are listed: the losing one is retained on the register.
        #expect(pair.a.state.store.losingWrites(WellKnown.settings, FontFields.documentKind).count == 1)
    }

    @Test func convertPageToGlyphVersusPointEditLandsInTheGlyph() throws {
        var pair = Pair()
        try TypefaceFixture.typeface(&pair.a, set: nil)
        let page = try PageFixture.onePage(&pair.a)
        let object = try TypefaceFixture.box(50, 592, 100, 100, on: nil, in: &pair.a)
        pair.sync()
        try pair.a.perform(ConvertPageToGlyph(page, name: "A", scaling: .onePointPerUnit))
        let path = pair.b.path(object)
        let contour = path.contours[0]
        try pair.b.perform(MovePoints(node: object, contour: contour.id, point: contour.points[0].id, to: Point(x: 40, y: 592)))
        pair.sync()
        #expect(Self.converged(pair))
        let glyph = TypefaceFixture.glyph("A", in: pair.a)
        #expect(GlyphArtwork.objectIDs(on: glyph, in: pair.a.state) == [object])
        #expect(Objects.bounds(of: object, in: pair.a.state) == Rect(x: 40, y: -200, width: 110, height: 100))
    }

    @Test func glyphDeleteVersusDrawReadsOnThePasteboardAndRestoreReattaches() throws {
        var pair = try Self.shared()
        let glyph = TypefaceFixture.glyph("A", in: pair.a)
        try pair.a.perform(RemoveGlyphs([glyph]))
        let drawn = try TypefaceFixture.box(0, -700, 100, 700, on: glyph, in: &pair.b)
        pair.sync()
        #expect(Self.converged(pair))
        #expect(pair.a.state.isLive(drawn) && CanvasMembership.placement(of: drawn, in: pair.a.state) == .pasteboard)
        try pair.a.perform(RestoreGlyph(glyph))
        pair.sync()
        #expect(CanvasMembership.placement(of: drawn, in: pair.b.state) == .canvas(glyph))
        #expect(GlyphArtwork.objectIDs(on: glyph, in: pair.b.state) == [drawn])
    }

    // MARK: FONT-008

    @Test func renameCollisionTheSmallerIDKeepsTheName() throws {
        var pair = try Self.shared()
        let glyphA = TypefaceFixture.glyph("A", in: pair.a)
        let glyphB = TypefaceFixture.glyph("B", in: pair.a)
        try pair.a.perform(RenameGlyph(glyphA, to: "Alpha"))
        try pair.b.perform(RenameGlyph(glyphB, to: "Alpha"))
        pair.sync()
        #expect(Self.converged(pair))
        let index = GlyphIndex(pair.a.state)
        let (keeper, other) = glyphA < glyphB ? (glyphA, glyphB) : (glyphB, glyphA)
        #expect(index[keeper]?.name == "Alpha" && index[other]?.nameStatus == .duplicate)
        #expect(index[other]?.name == "Alpha.dup\(other.counter)_\(String(other.replica, radix: 16))" && index[other]?.hasCollision == true)
        #expect(index.nameCollisions["Alpha"] == [keeper, other] && index.glyph(named: "Alpha")?.id == keeper)
    }

    @Test func codepointCollisionTheSmallerIDKeepsIt() throws {
        var pair = try Self.shared()
        let glyphA = TypefaceFixture.glyph("A", in: pair.a)
        let glyphB = TypefaceFixture.glyph("B", in: pair.a)
        try pair.a.perform(SetGlyphCodepoints(glyphA, add: [0x391]))
        try pair.b.perform(SetGlyphCodepoints(glyphB, add: [0x391]))
        pair.sync()
        #expect(Self.converged(pair))
        let index = GlyphIndex(pair.a.state)
        let (keeper, other) = glyphA < glyphB ? (glyphA, glyphB) : (glyphB, glyphA)
        #expect(index.glyph(for: 0x391)?.id == keeper && index[other]?.lostCodepoints == [0x391])
        #expect(index.codepointCollisions[0x391] == [keeper, other])
        // *Move to this glyph* resolves it in one change.
        try pair.a.perform(MoveGlyphCodepoint(0x391, to: other))
        #expect(GlyphIndex(pair.a.state).glyph(for: 0x391)?.id == other && GlyphIndex(pair.a.state).codepointCollisions.isEmpty)
    }

    @Test func concurrentAddAndRemoveOfACodepointKeepsIt() throws {
        var pair = try Self.shared()
        let glyphA = TypefaceFixture.glyph("A", in: pair.a)
        try pair.a.perform(SetGlyphCodepoints(glyphA, remove: [0x41]))
        try pair.b.perform(SetGlyphCodepoints(glyphA, add: [0x61]))
        try pair.b.perform(OpsCommand("Re-add", ops: [Ops.setAdd(glyphA, GlyphFields.codepoints, values: GlyphFields.codepointValues([0x41]))]))
        pair.sync()
        #expect(Self.converged(pair))
        #expect(TypefaceFixture.codepoints(glyphA, in: pair.a) == [0x41, 0x61])
    }

    @Test func addFromRangeOnTwoReplicasDetectsRemovableDuplicates() throws {
        var pair = try Self.shared([])
        try pair.a.perform(AddGlyphs.range(0xE8...0xE9))
        try pair.b.perform(AddGlyphs.range(0xE9...0xEA))
        pair.sync()
        #expect(Self.converged(pair))
        let index = GlyphIndex(pair.a.state)
        let duplicates = index.glyphs.filter { $0.nameStatus == .duplicate }
        #expect(index.count == 4 && duplicates.count == 1 && duplicates[0].codepoints.isEmpty && duplicates[0].lostCodepoints == [0xE9])
        #expect(GlyphArtwork.objectIDs(on: duplicates[0].id, in: pair.a.state).isEmpty)
        // The empty duplicate is removable in one step; the keeper keeps the name and codepoint.
        try pair.a.perform(RemoveGlyphs([duplicates[0].id]))
        #expect(GlyphIndex(pair.a.state).glyph(named: "eacute")?.codepoints == [0xE9] && GlyphIndex(pair.a.state).count == 3)
    }

    @Test func removeVersusUseAsComponentReadsAPlaceholder() throws {
        var pair = try Self.shared()
        let glyphA = TypefaceFixture.glyph("A", in: pair.a)
        let glyphB = TypefaceFixture.glyph("B", in: pair.a)
        try TypefaceFixture.box(0, -700, 300, 700, on: glyphA, in: &pair.a)
        pair.sync()
        try pair.a.perform(RemoveGlyphs([glyphA]))
        try pair.b.perform(AddComponent(glyphA, to: glyphB))
        pair.sync()
        #expect(Self.converged(pair))
        let component = try #require(GlyphIndex(pair.a.state)[glyphB]?.components.first)
        #expect(component.status == .dangling)
        // The placeholder draws the outline cached when the component was added.
        #expect(GlyphOutlines.metrics(of: glyphB, in: pair.a.state)?.bounds == Rect(x: 0, y: -700, width: 300, height: 700))
    }

    // MARK: FONT-005

    @Test func scaleVersusConcurrentPointEditKeepsTheEditScaled() throws {
        var pair = try Self.shared()
        let glyph = TypefaceFixture.glyph("A", in: pair.a)
        let box = try TypefaceFixture.box(0, -500, 100, 500, on: glyph, in: &pair.a)
        pair.sync()
        try pair.a.perform(SetUnitsPerEm(2_000, scale: true))
        let contour = pair.b.path(box).contours[0]
        try pair.b.perform(MovePoints(node: box, contour: contour.id, point: contour.points[0].id, to: Point(x: -10, y: -500)))
        pair.sync()
        #expect(Self.converged(pair))
        #expect(Objects.bounds(of: box, in: pair.a.state) == Rect(x: -20, y: -1_000, width: 220, height: 1_000))
    }

    @Test func scaleVersusConcurrentCreationLeavesItUnscaled() throws {
        var pair = try Self.shared()
        let glyph = TypefaceFixture.glyph("A", in: pair.a)
        try pair.a.perform(SetUnitsPerEm(2_000, scale: true))
        let drawn = try TypefaceFixture.box(0, -500, 100, 500, on: glyph, in: &pair.b)
        pair.sync()
        #expect(Self.converged(pair))
        #expect(FontInfo(pair.a.state).metrics.upm == 2_000 && Objects.bounds(of: drawn, in: pair.a.state) == Rect(x: 0, y: -500, width: 100, height: 500))
    }

    @Test func twoConcurrentScalesApplyTheLaterFactorEverywhere() throws {
        var pair = try Self.shared()
        let glyph = TypefaceFixture.glyph("A", in: pair.a)
        let box = try TypefaceFixture.box(0, -500, 100, 500, on: glyph, in: &pair.a)
        pair.sync()
        let a = try #require(try pair.a.perform(SetUnitsPerEm(2_048, scale: true)))
        let b = try #require(try pair.b.perform(SetUnitsPerEm(1_200, scale: true)))
        pair.sync()
        #expect(Self.converged(pair))
        let factor = PageFixture.later(a, b) ? 2.048 : 1.2
        let font = FontInfo(pair.a.state)
        #expect(Double(font.metrics.upm) == 1_000 * factor && abs(font.metrics.ascender - 800 * factor) < 1e-9)
        let bounds = try #require(Objects.bounds(of: box, in: pair.a.state))
        #expect(abs(bounds.width - 100 * factor) < 1e-9 && GlyphIndex(pair.a.state)[glyph]?.advanceWidth == (500 * factor).rounded())
    }

    @Test func xHeightVersusCapHeightBothApply() throws {
        var pair = try Self.shared()
        try pair.a.perform(SetFontMetrics([.xHeight: 480]))
        try pair.b.perform(SetFontMetrics([.capHeight: 690]))
        pair.sync()
        #expect(Self.converged(pair))
        #expect(FontInfo(pair.a.state).metrics.xHeight == 480 && FontInfo(pair.a.state).metrics.capHeight == 690)
    }

    // MARK: FONT-012

    @Test func componentMoveVersusMoveLaterWins() throws {
        var pair = try Self.shared()
        let glyphA = TypefaceFixture.glyph("A", in: pair.a)
        let glyphB = TypefaceFixture.glyph("B", in: pair.a)
        try pair.a.perform(AddComponent(glyphA, to: glyphB))
        pair.sync()
        let component = try #require(GlyphIndex(pair.a.state)[glyphB]?.components.first?.id)
        let a = try #require(try pair.a.perform(SetComponentTransform(component, of: glyphB, to: .translation(x: 10, y: 0))))
        let b = try #require(try pair.b.perform(SetComponentTransform(component, of: glyphB, to: .translation(x: 20, y: 0))))
        pair.sync()
        #expect(Self.converged(pair))
        #expect(GlyphIndex(pair.a.state)[glyphB]?.components[0].transform == .translation(x: PageFixture.later(a, b) ? 10 : 20, y: 0))
    }

    @Test func decomposeVersusMoveRestoreReinsertsTheComponent() throws {
        var pair = try Self.shared()
        let glyphA = TypefaceFixture.glyph("A", in: pair.a)
        let glyphB = TypefaceFixture.glyph("B", in: pair.a)
        try TypefaceFixture.box(0, -700, 300, 700, on: glyphA, in: &pair.a)
        try pair.a.perform(AddComponent(glyphA, to: glyphB))
        pair.sync()
        let component = try #require(GlyphIndex(pair.a.state)[glyphB]?.components.first?.id)
        try pair.a.perform(DecomposeComponents(glyphB))
        try pair.b.perform(SetComponentTransform(component, of: glyphB, to: .translation(x: 50, y: 0)))
        pair.sync()
        #expect(Self.converged(pair))
        #expect(GlyphIndex(pair.a.state)[glyphB]?.components.isEmpty == true && GlyphArtwork.objectIDs(on: glyphB, in: pair.a.state).count == 1)
        // *Restore*: the element comes back beside the decomposed paths, with the moved transform.
        try pair.b.perform(OpsCommand("Restore", ops: [Ops.elementDelete(glyphB, [GlyphFields.component(component)], deleted: false)]))
        #expect(GlyphIndex(pair.b.state)[glyphB]?.components.first?.transform == .translation(x: 50, y: 0))
    }

    @Test func concurrentLoopIsCutAtTheSmallestElementOnBothReplicas() throws {
        var pair = try Self.shared()
        let glyphA = TypefaceFixture.glyph("A", in: pair.a)
        let glyphB = TypefaceFixture.glyph("B", in: pair.a)
        try TypefaceFixture.box(0, -100, 100, 100, on: glyphA, in: &pair.a)
        try TypefaceFixture.box(200, -100, 100, 100, on: glyphB, in: &pair.a)
        pair.sync()
        try pair.a.perform(AddComponent(glyphB, to: glyphA))
        try pair.b.perform(AddComponent(glyphA, to: glyphB))
        pair.sync()
        #expect(Self.converged(pair))
        let index = GlyphIndex(pair.a.state)
        let elements = [index[glyphA]!.components[0], index[glyphB]!.components[0]]
        let cut = elements.min { $0.id < $1.id }!
        #expect(elements.filter { $0.status == .loop } == [cut] && elements.filter { $0.status == .resolved }.count == 1)
        #expect(GlyphIndex(pair.b.state) == index)
        #expect(GlyphOutlines.outlines(in: pair.a.state) == GlyphOutlines.outlines(in: pair.b.state))
    }

    // MARK: FONT-013

    @Test func anchorMoveVersusMoveAndSameNameAdds() throws {
        var pair = try Self.shared()
        let glyph = TypefaceFixture.glyph("A", in: pair.a)
        try pair.a.perform(AddAnchor("top", at: .zero, to: glyph))
        pair.sync()
        let anchor = try #require(GlyphIndex(pair.a.state)[glyph]?.anchors.first?.id)
        let a = try #require(try pair.a.perform(EditAnchor(anchor, of: glyph, .move(Point(x: 1, y: 1)))))
        let b = try #require(try pair.b.perform(EditAnchor(anchor, of: glyph, .move(Point(x: 2, y: 2)))))
        try pair.a.perform(AddAnchor("bottom", at: .zero, to: glyph))
        try pair.b.perform(AddAnchor("bottom", at: .zero, to: glyph))
        pair.sync()
        #expect(Self.converged(pair))
        let anchors = try #require(GlyphIndex(pair.a.state)[glyph]?.anchors)
        #expect(anchors[0].position == (PageFixture.later(a, b) ? Point(x: 1, y: 1) : Point(x: 2, y: 2)))
        let bottoms = anchors.filter { $0.storedName == "bottom" }.sorted { $0.id < $1.id }
        #expect(bottoms.map(\.name) == ["bottom", "bottom.dup1"])
    }

    @Test func anchorRemoveVersusMoveRestores() throws {
        var pair = try Self.shared()
        let glyph = TypefaceFixture.glyph("A", in: pair.a)
        try pair.a.perform(AddAnchor("top", at: .zero, to: glyph))
        pair.sync()
        let anchor = try #require(GlyphIndex(pair.a.state)[glyph]?.anchors.first?.id)
        try pair.a.perform(EditAnchor(anchor, of: glyph, .remove))
        try pair.b.perform(EditAnchor(anchor, of: glyph, .move(Point(x: 9, y: 9))))
        pair.sync()
        #expect(Self.converged(pair) && GlyphIndex(pair.a.state)[glyph]?.anchors.isEmpty == true)
        try pair.b.perform(OpsCommand("Restore", ops: [Ops.elementDelete(glyph, [GlyphFields.anchor(anchor)], deleted: false)]))
        #expect(GlyphIndex(pair.b.state)[glyph]?.anchors.first?.position == Point(x: 9, y: 9))
    }

    // MARK: FONT-016

    @Test func samePairSetTwiceAndCreatedTwice() throws {
        var pair = try Self.shared()
        let glyphA = TypefaceFixture.glyph("A", in: pair.a)
        let glyphB = TypefaceFixture.glyph("B", in: pair.a)
        // Created on both replicas: two elements; the greater element id is read.
        try pair.a.perform(SetKernPair(glyphA, glyphB, to: -10))
        try pair.b.perform(SetKernPair(glyphA, glyphB, to: -20))
        pair.sync()
        #expect(Self.converged(pair))
        var kerning = Kerning(pair.a.state)
        let winner = kerning.storedPairs.max { $0.id < $1.id }!
        #expect(kerning.storedPairs.count == 2 && kerning.value(glyphA, glyphB) == winner.value && kerning.duplicatePairs.count == 1)
        // Set twice on one element: later wins.
        try pair.a.perform(SetKernPair(glyphA, glyphB, to: -30))
        pair.sync()
        let a = try #require(try pair.a.perform(SetKernPair(glyphA, glyphB, to: -40)))
        let b = try #require(try pair.b.perform(SetKernPair(glyphA, glyphB, to: -50)))
        pair.sync()
        #expect(Self.converged(pair))
        kerning = Kerning(pair.a.state)
        #expect(kerning.storedPairs.count == 1 && kerning.value(glyphA, glyphB) == (PageFixture.later(a, b) ? -40 : -50))
    }

    @Test func pairSetVersusRemoveRestores() throws {
        var pair = try Self.shared()
        let glyphA = TypefaceFixture.glyph("A", in: pair.a)
        let glyphB = TypefaceFixture.glyph("B", in: pair.a)
        try pair.a.perform(SetKernPair(glyphA, glyphB, to: -10))
        pair.sync()
        let element = Kerning(pair.a.state).storedPairs[0].id
        try pair.a.perform(RemoveKernPairs([(glyphA, glyphB)]))
        try pair.b.perform(SetKernPair(glyphA, glyphB, to: -60))
        pair.sync()
        #expect(Self.converged(pair) && Kerning(pair.a.state).isEmpty)
        try pair.b.perform(OpsCommand("Restore", ops: [Ops.elementDelete(WellKnown.settings, [FontFields.pair(element)], deleted: false)]))
        #expect(Kerning(pair.b.state).value(glyphA, glyphB) == -60)
    }

    @Test func sameClassCreatedTwiceFollowsTheMembershipRuleAndMerges() throws {
        var pair = try Self.shared([0x4F, 0x43, 0x51])
        let o = TypefaceFixture.glyph("O", in: pair.a)
        let c = TypefaceFixture.glyph("C", in: pair.a)
        let q = TypefaceFixture.glyph("Q", in: pair.a)
        try pair.a.perform(CreateKernClass("O", side: .left, members: [o, c]))
        try pair.b.perform(CreateKernClass("O", side: .left, members: [c, q]))
        pair.sync()
        #expect(Self.converged(pair))
        var kerning = Kerning(pair.a.state)
        #expect(kerning.classes.count == 2 && kerning.classes.map(\.name).sorted() == ["O", "O_2"])
        // C is in both: the greater membership element id places it.
        let holders = kerning.classes.filter { $0.memberships.contains { $0.glyph == c } }
        let expected = holders.max { lhs, rhs in
            lhs.memberships.first { $0.glyph == c }!.element < rhs.memberships.first { $0.glyph == c }!.element
        }!
        #expect(kerning.kernClass(of: c, side: .left)?.id == expected.id)
        let groups = kerning.sameNamedClasses
        #expect(groups.count == 1)
        try pair.a.perform(MergeKernClasses(keeping: groups[0][0].id, merging: groups[0][1].id))
        pair.sync()
        #expect(Self.converged(pair))
        kerning = Kerning(pair.b.state)
        #expect(kerning.classes.count == 1 && Set(kerning.classes[0].members) == [o, c, q])
    }

    @Test func autoKernVersusAutoKernHasOneUniformWinner() throws {
        var pair = try Self.shared([0x41, 0x56, 0x54, 0x6F])
        let g = Dictionary(uniqueKeysWithValues: GlyphIndex(pair.a.state).glyphs.map { ($0.name, $0.id) })
        try pair.a.perform(ApplyAutoKern([(g["A"]!, g["V"]!, -80), (g["T"]!, g["o"]!, -60)]))
        pair.sync()
        let a = try #require(try pair.a.perform(ApplyAutoKern([(g["A"]!, g["V"]!, -70), (g["T"]!, g["o"]!, -50)])))
        let b = try #require(try pair.b.perform(ApplyAutoKern([(g["A"]!, g["V"]!, -90), (g["T"]!, g["o"]!, -40)])))
        pair.sync()
        #expect(Self.converged(pair))
        let kerning = Kerning(pair.a.state)
        let values = [kerning.value(g["A"]!, g["V"]!), kerning.value(g["T"]!, g["o"]!)]
        #expect(values == (PageFixture.later(a, b) ? [-70, -50] : [-90, -40]))
    }
}
