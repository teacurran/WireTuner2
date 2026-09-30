import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The Glyph menu over a selection (FONT-008, FONT-010, FONT-012 rests): the metric sheet, thirds,
/// Build Accented Glyphs, Snap Components to Anchors, the outline clean-ups, Round to Units, the
/// Select queries, the placed components a canvas draws, and the single-page page rule (FONT-003).
@Suite struct GlyphMenuCommandTests {
    /// A typeface with `A` (a 100...500 box, width 600), `B` (empty, width 500) and `acutecomb`.
    static func fixture() throws -> (Replica, a: OpID, b: OpID, mark: OpID) {
        var r = Replica(0xA)
        try TypefaceFixture.typeface(&r, set: nil)
        try r.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42), NewGlyph(scalar: 0x301)]))
        let a = TypefaceFixture.glyph("A", in: r), b = TypefaceFixture.glyph("B", in: r), mark = TypefaceFixture.glyph("acutecomb", in: r)
        try TypefaceFixture.box(100, -700, 400, 700, on: a, in: &r)
        try r.perform(SetGlyphWidth([a], to: 600))
        return (r, a, b, mark)
    }

    static func metrics(_ glyph: OpID, _ r: Replica) -> GlyphMetrics { GlyphOutlines.metrics(of: glyph, in: r.state)! }

    /// The contours of `node` as drawn, glyph space.
    static func drawn(_ node: OpID, _ r: Replica) -> [Contour] {
        let shapes = GlyphOutlines.shapes(of: node, parentTransform: .identity, state: r.state)
        return GlyphFlattener.outline(of: GlyphSource(shapes: shapes), sources: [:], options: GlyphFlattener.Options(keepOverlaps: true)).path.contours
    }

    @Test func metricSheetSetsAddsAndScales() throws {
        var (r, a, b, _) = try Self.fixture()
        let width = AdjustGlyphMetrics([a, b], .width, .add(20))
        #expect(width.label == "Set width of 2 glyphs")
        try r.perform(width)
        #expect(Self.metrics(a, r).advanceWidth == 620 && Self.metrics(b, r).advanceWidth == 520)
        try r.perform(AdjustGlyphMetrics([a], .width, .scale(0.5)))
        #expect(Self.metrics(a, r).advanceWidth == 310)
        try r.perform(AdjustGlyphMetrics([a], .width, .set(600)))
        // Left: the artwork moves; the empty glyph has no bearings and is left alone.
        let left = AdjustGlyphMetrics([a, b], .left, .scale(2))
        #expect(left.label == "Set left side bearing of 2 glyphs")
        try r.perform(left)
        #expect(Self.metrics(a, r).leftSideBearing == 200 && Self.metrics(a, r).advanceWidth == 600 && Self.metrics(b, r).advanceWidth == 520)
        // Right: the width follows.
        #expect(AdjustGlyphMetrics([a], .right, .set(0)).label == "Set right side bearing")
        try r.perform(AdjustGlyphMetrics([a], .right, .set(50)))
        #expect(Self.metrics(a, r).rightSideBearing == 50 && Self.metrics(a, r).advanceWidth == 650)
        // Nothing to write, and refusals.
        #expect(try r.perform(AdjustGlyphMetrics([a], .width, .add(0))) == nil)
        #expect(throws: GlyphEditError.invalidValue("advance width")) { try r.perform(AdjustGlyphMetrics([a], .width, .set(.nan))) }
        #expect(throws: GlyphEditError.invalidValue("side bearing")) { try r.perform(AdjustGlyphMetrics([a], .left, .add(.infinity))) }
        #expect(throws: GlyphEditError.invalidValue("advance width")) { try r.perform(AdjustGlyphMetrics([a], .right, .set(-10_000))) }
        #expect(throws: GlyphEditError.notAGlyph(OpID(counter: 999, replica: 1))) {
            try r.perform(AdjustGlyphMetrics([OpID(counter: 999, replica: 1)], .width, .set(10)))
        }
        // One undo step restores every glyph.
        _ = r.undo()
        #expect(Self.metrics(a, r).advanceWidth == 600)
    }

    @Test func thirdsPutsTwiceTheLeftOnTheRight() throws {
        var (r, a, _, _) = try Self.fixture()
        let command = SetGlyphBearings([a], .thirds)
        #expect(command.label == "Thirds in width" && SetGlyphBearings([a, a], .thirds).label == "Thirds in width of 2 glyphs")
        try r.perform(command)
        let metrics = Self.metrics(a, r)
        #expect(abs(metrics.leftSideBearing - 200.0 / 3) < 1e-9 && abs(metrics.rightSideBearing - 2 * metrics.leftSideBearing) < 1e-9)
    }

    /// `e` with a `top` anchor, `acutecomb` with `_top` and a `top` of its own (for stacking),
    /// `uni0302` with `_top`, and `eacute` drawn by hand.
    static func accents() throws -> (Replica, e: OpID, acute: OpID, circumflex: OpID, eacute: OpID) {
        var r = Replica(0xA)
        try TypefaceFixture.typeface(&r, set: nil)
        try r.perform(AddGlyphs([NewGlyph(scalar: 0x65), NewGlyph(scalar: 0x301), NewGlyph(scalar: 0x302), NewGlyph(scalar: 0xE9),
                                 NewGlyph(scalar: 0x1EBF), NewGlyph(scalar: 0x41)]))
        let e = TypefaceFixture.glyph("e", in: r), acute = TypefaceFixture.glyph("acutecomb", in: r)
        let circumflex = TypefaceFixture.glyph("uni0302", in: r), eacute = TypefaceFixture.glyph("eacute", in: r)
        try TypefaceFixture.box(50, -500, 400, 500, on: e, in: &r)
        try TypefaceFixture.box(0, -100, 100, 100, on: acute, in: &r)
        try TypefaceFixture.box(0, -80, 120, 80, on: circumflex, in: &r)
        try TypefaceFixture.box(0, -10, 10, 10, on: eacute, in: &r)
        try r.perform(SetGlyphWidth([e], to: 520))
        try r.perform(AddAnchor("top", at: Point(x: 250, y: -500), to: e))
        try r.perform(AddAnchor("_top", at: Point(x: 50, y: 0), to: acute))
        try r.perform(AddAnchor("top", at: Point(x: 50, y: -100), to: circumflex))
        try r.perform(AddAnchor("_top", at: Point(x: 60, y: 0), to: circumflex))
        return (r, e, acute, circumflex, eacute)
    }

    @Test func buildAccentedGlyphsReplacesTheArtworkWithAnchoredComponents() throws {
        var (r, e, acute, circumflex, eacute) = try Self.accents()
        let ecircumflexacute = GlyphIndex(r.state).glyph(for: 0x1EBF)!.id
        let letterA = TypefaceFixture.glyph("A", in: r)
        let index = GlyphIndex(r.state)
        #expect(BuildAccentedGlyphs.parts(of: index[letterA]!, in: index) == nil)
        #expect(BuildAccentedGlyphs.parts(of: index[eacute]!, in: index)?.map(\.id) == [e, acute])
        let command = BuildAccentedGlyphs([eacute, ecircumflexacute, letterA])
        #expect(command.label == "Build 3 accented glyphs" && BuildAccentedGlyphs([eacute]).label == "Build accented glyph")
        try r.perform(command)
        let built = try #require(GlyphIndex(r.state)[eacute])
        #expect(built.components.map(\.source) == [e, acute] && built.advanceWidth == 520)
        #expect(built.components[1].transform == .translation(x: 200, y: -500))
        #expect(GlyphArtwork.objectIDs(on: eacute, in: r.state).isEmpty)
        // A mark stacked on a mark: the acute attaches to the circumflex's own `top`.
        let stacked = try #require(GlyphIndex(r.state)[ecircumflexacute])
        #expect(stacked.components.map(\.source) == [e, circumflex, acute])
        #expect(stacked.components[1].transform == .translation(x: 190, y: -500))
        #expect(stacked.components[2].transform == .translation(x: 190, y: -600))
        // Building again replaces the components rather than adding more.
        try r.perform(BuildAccentedGlyphs([eacute]))
        #expect(GlyphIndex(r.state)[eacute]?.components.count == 2)
        _ = circumflex
    }

    @Test func snapComponentsMovesMarksOntoTheirAnchors() throws {
        var (r, e, acute, _, eacute) = try Self.accents()
        try r.perform(AddComponent(e, to: eacute, transform: .identity))
        try r.perform(AddComponent(acute, to: eacute, transform: AffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 0, ty: 0)))
        let command = SnapComponentsToAnchors([eacute])
        #expect(command.label == "Snap components to anchors")
        try r.perform(command)
        let snapped = try #require(GlyphIndex(r.state)[eacute]?.components[1].transform)
        // The mark keeps its scale; its `_top` (50, 0) lands on e's `top` (250, -500).
        #expect(snapped.a == 2 && snapped.apply(Point(x: 50, y: 0)) == Point(x: 250, y: -500))
        #expect(try r.perform(SnapComponentsToAnchors([eacute])) == nil)
        // The glyph's own base anchor places even its first component.
        try r.perform(AddAnchor("top", at: Point(x: 300, y: -600), to: eacute))
        try r.perform(SnapComponentsToAnchors([eacute]))
        #expect(GlyphIndex(r.state)[eacute]?.components[1].transform.apply(Point(x: 50, y: 0)) == Point(x: 300, y: -600))
    }

    @Test func rewritesMergeTurnAndAddExtrema() throws {
        var r = Replica(0xA)
        try TypefaceFixture.typeface(&r, set: nil)
        try r.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42), NewGlyph(scalar: 0x43)]))
        let a = TypefaceFixture.glyph("A", in: r), b = TypefaceFixture.glyph("B", in: r), c = TypefaceFixture.glyph("C", in: r)
        try TypefaceFixture.box(0, -500, 300, 500, on: a, in: &r)
        try TypefaceFixture.box(200, -500, 300, 500, on: a, in: &r)
        #expect(RewriteGlyphOutlines.Operation.allCases.map(\.title) == ["Remove Overlaps", "Correct Directions", "Add Extrema"])
        let merge = RewriteGlyphOutlines([a, b], .removeOverlaps)
        #expect(merge.label == "Remove Overlaps")
        try r.perform(merge)
        let merged = GlyphArtwork.objectIDs(on: a, in: r.state)
        #expect(merged.count == 1 && Self.metrics(a, r).bounds == Rect(x: 0, y: -500, width: 500, height: 500))
        // A ring drawn as two same-direction boxes fills its counter until directions are corrected.
        try TypefaceFixture.box(0, -500, 500, 500, on: b, in: &r)
        try TypefaceFixture.box(100, -400, 300, 300, on: b, in: &r)
        let ring = try r.perform(RewriteGlyphOutlines([b], .correctDirections))
        #expect(ring != nil)
        let objects = GlyphArtwork.objectIDs(on: b, in: r.state)
        #expect(objects.count == 1)
        let ringContours = Self.drawn(objects[0], r)
        #expect(ringContours.count == 2 && ringContours[0].signedArea().sign != ringContours[1].signedArea().sign)
        #expect(Self.metrics(b, r).bounds == Rect(x: 0, y: -500, width: 500, height: 500))
        #expect(try r.perform(RewriteGlyphOutlines([b], .correctDirections)) == nil)
        // A circle drawn from four quarter arcs has its extrema; a rotated square's corners are its extrema.
        let ellipse = try r.perform(CreateShape(.ellipse, size: Size(width: 300, height: 200), transform: .translation(x: 10, y: -300)))!.createdObjects[0]
        try TypefaceFixture.place(ellipse, on: c, in: &r)
        try r.perform(TransformGlyphs([c], by: .rotation(radians: 0.3)))
        try r.perform(RewriteGlyphOutlines([c], .addExtrema))
        #expect(!GlyphContours.isMissingExtrema(Self.drawn(GlyphArtwork.objectIDs(on: c, in: r.state)[0], r)))
        #expect(try r.perform(RewriteGlyphOutlines([c], .addExtrema)) == nil)
        // Round to Units over many glyphs is one change.
        try TypefaceFixture.box(0.4, -10.6, 20, 20, on: a, in: &r)
        #expect(try r.perform(RoundGlyphsToUnits([a, b]))?.label == "Round to Units")
        #expect(throws: GlyphEditError.notAGlyph(OpID(counter: 999, replica: 1))) {
            try r.perform(RewriteGlyphOutlines([OpID(counter: 999, replica: 1)], .addExtrema))
        }
    }

    @Test func rewritesLeaveBackgroundLayersAndEmptyGlyphsAlone() throws {
        var r = Replica(0xA)
        try TypefaceFixture.typeface(&r, set: nil)
        try r.perform(AddGlyphs([NewGlyph(scalar: 0x41)]))
        let a = TypefaceFixture.glyph("A", in: r)
        #expect(try r.perform(RewriteGlyphOutlines([a], .removeOverlaps)) == nil)
        let open = try r.perform(CreatePath(contours: [NewContour(closed: false, points: PathFixture.points([(0, 0), (10, 10), (0, 10)]))], appearance: GlyphPaths.appearance))!.createdObjects[0]
        try TypefaceFixture.place(open, on: a, in: &r)
        // An open unstroked path draws nothing in the font, so there is nothing to rewrite: it stays.
        #expect(try r.perform(RewriteGlyphOutlines([a], .removeOverlaps)) == nil)
        #expect(GlyphArtwork.objectIDs(on: a, in: r.state) == [open])
        // A glyph whose only artwork is on a background layer is left alone.
        try r.perform(CreateLayer(name: "Top"))
        let box = try TypefaceFixture.box(0, -100, 100, 100, on: a, in: &r)
        let layer = try #require(r.state.store.placement(box)?.parent)
        try r.perform(SetLayerFlag([layer], .printing, false))
        #expect(try r.perform(RewriteGlyphOutlines([a], .removeOverlaps)) == nil)
        #expect(GlyphArtwork.objectIDs(on: a, in: r.state).count == 2)
    }

    @Test func selectQueries() throws {
        var (r, a, b, mark) = try Self.fixture()
        try r.perform(AddComponent(a, to: b))
        try r.perform(SetGlyphAttributes([a, mark], markColor: 3))
        try r.perform(AddGlyphs([NewGlyph(name: "a.alt")]))
        let alt = TypefaceFixture.glyph("a.alt", in: r)
        #expect(GlyphSelectionQuery.allCases.map(\.title).count == 7)
        #expect(GlyphSelectionQuery.allCases.filter(\.needsSelection) == [.usingSelectedAsComponent, .sameMarkColor])
        #expect(GlyphSelectionQuery.withOutlines.glyphs(selected: [], in: r.state) == [a, b])
        #expect(GlyphSelectionQuery.empty.glyphs(selected: [], in: r.state) == [mark, alt])
        #expect(GlyphSelectionQuery.encoded.glyphs(selected: [], in: r.state) == [a, b, mark])
        #expect(GlyphSelectionQuery.unencoded.glyphs(selected: [], in: r.state) == [alt])
        #expect(GlyphSelectionQuery.usingSelectedAsComponent.glyphs(selected: [a], in: r.state) == [b])
        #expect(GlyphSelectionQuery.sameMarkColor.glyphs(selected: [mark], in: r.state) == [a, mark])
        // A zero-width base glyph is a problem Find Problems lists.
        try r.perform(SetGlyphWidth([alt], to: 0))
        #expect(GlyphSelectionQuery.withProblems.glyphs(selected: [], in: r.state).contains(alt))
    }

    @Test func placedComponentsForTheCanvas() throws {
        var (r, a, b, mark) = try Self.fixture()
        #expect(GlyphOutlines.placedComponents(of: b, in: r.state).isEmpty)
        #expect(GlyphOutlines.placedComponents(of: OpID(counter: 999, replica: 1), in: r.state).isEmpty)
        try r.perform(AddComponent(a, to: b, transform: .translation(x: 10, y: 0)))
        try r.perform(AddComponent(mark, to: b))
        var placed = GlyphOutlines.placedComponents(of: b, in: r.state)
        #expect(placed.map(\.name) == ["A", "acutecomb"] && placed.map(\.isPlaceholder) == [false, false])
        #expect(placed[0].bounds == Rect(x: 110, y: -700, width: 400, height: 700))
        // An empty source still has a box to click.
        #expect(placed[1].outline.isEmpty && placed[1].bounds == Rect(x: 0, y: -100, width: 100, height: 100))
        #expect(GlyphOutlines.reachableOutline(of: b, in: r.state).bounds == Rect(x: 110, y: -700, width: 400, height: 700))
        #expect(GlyphOutlines.sources(reachableFrom: [b], in: r.state).count == 3)
        // Removed: the cached outline, named by its last name.
        try r.perform(RemoveGlyphs([a]))
        placed = GlyphOutlines.placedComponents(of: b, in: r.state)
        #expect(placed[0].status == .dangling && placed[0].isPlaceholder && placed[0].name == "A")
        #expect(placed[0].bounds == Rect(x: 110, y: -700, width: 400, height: 700))
        #expect(GlyphFields.lastName(of: OpID(counter: 999, replica: 1), in: r.state) == "")
    }

    @Test func placedComponentsCutFromALoop() throws {
        var pair = Pair()
        try TypefaceFixture.typeface(&pair.a, set: nil)
        try pair.a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42)]))
        pair.sync()
        let glyphA = TypefaceFixture.glyph("A", in: pair.a), glyphB = TypefaceFixture.glyph("B", in: pair.a)
        try pair.a.perform(AddComponent(glyphB, to: glyphA))
        try pair.b.perform(AddComponent(glyphA, to: glyphB))
        pair.sync()
        let state = pair.a.state
        let cut = (GlyphOutlines.placedComponents(of: glyphA, in: state) + GlyphOutlines.placedComponents(of: glyphB, in: state))
            .filter { $0.status == .loop }
        #expect(cut.count == 1 && cut[0].name == "loop" && cut[0].outline.isEmpty && cut[0].isPlaceholder)
    }

    @Test func aSinglePageDocumentGetsNoSecondPage() throws {
        var r = Replica(0xA)
        try r.perform(ConvertDocumentKind(to: .singlePage))
        #expect(throws: PageSetupError.singlePageDocument) { try r.perform(AddPages()) }
        let page = try PageFixture.onePage(&r)
        #expect(throws: PageSetupError.singlePageDocument) { try r.perform(DuplicatePage(page)) }
        try r.perform(ConvertDocumentKind(to: .multiPage))
        #expect(try r.perform(AddPages())?.label == "Add page")
    }

    @Test func markAttachmentPreviewPlacesMarksOnBasesAndASampleUnderAMark() throws {
        var (r, e, acute, circumflex, eacute) = try Self.accents()
        var index = GlyphIndex(r.state)
        // On e: both marks whose `_top` matches e's `top`.
        let onE = MarkAttachment.placements(on: e, in: index)
        #expect(onE == [MarkAttachment.Placement(glyph: acute, offset: Vector(dx: 200, dy: -500)),
                        MarkAttachment.Placement(glyph: circumflex, offset: Vector(dx: 190, dy: -500))])
        // A dragged anchor moves the preview.
        var moved = index[e]!.anchors
        moved[0].position = Point(x: 260, y: -520)
        #expect(MarkAttachment.placements(on: e, anchors: moved, in: index)[0].offset == Vector(dx: 210, dy: -520))
        // On the acute: the first base with a matching anchor (no `a` or `A` has one yet).
        #expect(MarkAttachment.placements(on: acute, in: index) == [MarkAttachment.Placement(glyph: e, offset: Vector(dx: -200, dy: 500))])
        // `A` is preferred once it has a top anchor.
        let letterA = TypefaceFixture.glyph("A", in: r)
        try r.perform(AddAnchor("top", at: Point(x: 300, y: -700), to: letterA))
        index = GlyphIndex(r.state)
        #expect(MarkAttachment.placements(on: acute, in: index).map(\.glyph) == [letterA])
        // Nothing for a glyph with no anchors, a stray id, or a mark with nothing to sit on.
        #expect(MarkAttachment.placements(on: eacute, in: index).isEmpty)
        #expect(MarkAttachment.placements(on: OpID(counter: 999, replica: 1), in: index).isEmpty)
        try r.perform(AddAnchor("_ogonek", at: Point(x: 0, y: 0), to: eacute))
        #expect(MarkAttachment.placements(on: eacute, in: GlyphIndex(r.state)).isEmpty)
    }
}
