import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTRender

/// FONT-026 (rest): btn:[Fix All Warnings] -- the warnings generation corrects anyway, fixed in the
/// document in one undo step.
@Suite struct FontWarningFixesTests {
    @Test func fixAllWarningsCleansTheArtworkInOneStep() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a)
        let g = Dictionary(uniqueKeysWithValues: GlyphIndex(a.state).glyphs.map { ($0.name, $0.id) })
        // Off the grid: a box at half units; missing extrema: an ellipse drawn with its points on
        // the diagonals; two overlapping boxes merge.
        try TypefaceFixture.box(10.5, -700.5, 300, 700, on: g["A"]!, in: &a)
        let k = 0.5522847498 * 200
        let diagonal = try a.perform(CreatePath(contours: [NewContour(closed: true, points: [
            VectorPoint(anchor: Point(x: 341, y: -341), inHandle: Vector(dx: -k, dy: k), outHandle: Vector(dx: k, dy: -k)),
            VectorPoint(anchor: Point(x: 341, y: -59), inHandle: Vector(dx: k, dy: k), outHandle: Vector(dx: -k, dy: -k)),
            VectorPoint(anchor: Point(x: 59, y: -59), inHandle: Vector(dx: k, dy: -k), outHandle: Vector(dx: -k, dy: k)),
            VectorPoint(anchor: Point(x: 59, y: -341), inHandle: Vector(dx: -k, dy: -k), outHandle: Vector(dx: k, dy: k)),
        ])], appearance: GlyphPaths.appearance))!.createdObjects[0]
        try TypefaceFixture.place(diagonal, on: g["O"]!, in: &a)
        try TypefaceFixture.box(0, -700, 300, 700, on: g["B"]!, in: &a)
        try TypefaceFixture.box(200.25, -700, 300, 700, on: g["B"]!, in: &a)
        let problems = FontGeneration.snapshot(a.state).problems
        let warned = FixGlyphWarnings.glyphs(in: problems)
        #expect(Set(warned) == [g["A"]!, g["O"]!, g["B"]!], "\(problems.map(\.message))")
        let before = a.state
        try a.perform(FixGlyphWarnings(warned))
        let after = FontGeneration.snapshot(a.state).problems
        #expect(FixGlyphWarnings.glyphs(in: after).isEmpty, "\(after.map(\.message))")
        // One path per glyph, the overlap merged into one contour.
        #expect(GlyphArtwork.objectIDs(on: g["B"]!, in: a.state).count == 1)
        let merged = try #require(GlyphOutlines.metrics(of: g["B"]!, in: a.state)?.bounds)
        #expect(merged == Rect(x: 0, y: -700, width: 500, height: 700))
        // One undo step brings the drawing back.
        a.undo()
        #expect(FixGlyphWarnings.glyphs(in: FontGeneration.snapshot(a.state).problems) == FixGlyphWarnings.glyphs(in: FontGeneration.snapshot(before).problems))
        #expect(GlyphArtwork.objectIDs(on: g["B"]!, in: a.state).count == 2)
        // Nothing to fix: no change.
        #expect(FixGlyphWarnings.glyphs(in: [FontProblem(.error, .offGrid, glyph: g["A"]!, "x"), FontProblem(.warning, .emptyGlyph, glyph: g["A"]!, "y")]).isEmpty)
        #expect(FixGlyphWarnings([g["C"]!]).label == "Fix All Warnings")
        try a.perform(FixGlyphWarnings([g["C"]!]))
    }
}
