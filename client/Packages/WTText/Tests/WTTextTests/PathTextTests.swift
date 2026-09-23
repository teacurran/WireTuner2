import Testing
import WTGeometry
import WTRender
@testable import WTText

/// Text on a path and inside one (text-on-path).
@Suite struct PathTextTests {
    /// An arch: a half ellipse from left to right over the top (y down).
    static let arch = Contour(segments: [
        CubicBezier(Point(x: 10, y: 110), Point(x: 10, y: 20), Point(x: 190, y: 20), Point(x: 190, y: 110)),
    ], closed: false)

    /// A circle of radius 60 about (100, 100), starting at the left, clockwise on screen.
    static let circle: Contour = {
        let k = 0.5523 * 60
        let c = Point(x: 100, y: 100)
        return Contour(segments: [
            CubicBezier(Point(x: c.x - 60, y: c.y), Point(x: c.x - 60, y: c.y - k), Point(x: c.x - k, y: c.y - 60), Point(x: c.x, y: c.y - 60)),
            CubicBezier(Point(x: c.x, y: c.y - 60), Point(x: c.x + k, y: c.y - 60), Point(x: c.x + 60, y: c.y - k), Point(x: c.x + 60, y: c.y)),
            CubicBezier(Point(x: c.x + 60, y: c.y), Point(x: c.x + 60, y: c.y + k), Point(x: c.x + k, y: c.y + 60), Point(x: c.x, y: c.y + 60)),
            CubicBezier(Point(x: c.x, y: c.y + 60), Point(x: c.x - k, y: c.y + 60), Point(x: c.x - 60, y: c.y + k), Point(x: c.x - 60, y: c.y)),
        ], closed: true)
    }()

    static func distance(from point: Point, to contour: Contour) -> Double {
        contour.nearestPoint(to: point)?.distance ?? .infinity
    }

    /// The point where a glyph's baseline midpoint lands (glyph space (advance / 2, 0)).
    static func baselineMid(_ glyph: LaidOutGlyph) -> Point {
        glyph.transform.apply(Point(x: glyph.advance / 2, y: 0))
    }

    @Test func glyphsSitOnThePathAndTurnWithIt() {
        let path = PathText(contour: PathTextTests.arch, orientation: .rotate)
        let layout = Fixture.layout("Along the arch", in: [.path(path)])
        #expect(!layout.overflows)
        let glyphs = layout.glyphs()
        #expect(glyphs.count == 14)
        for glyph in glyphs {
            #expect(PathTextTests.distance(from: PathTextTests.baselineMid(glyph), to: PathTextTests.arch) < 0.05)
            // Rotation only: an orthonormal frame.
            #expect(approx(glyph.transform.a * glyph.transform.a + glyph.transform.b * glyph.transform.b, 1, 1e-6))
            #expect(approx(glyph.transform.determinant, 1, 1e-6))
        }
        // The first glyph starts at the path start, climbing; later ones turn clockwise.
        #expect(glyphs[0].origin.distance(to: Point(x: 10, y: 110)) < 0.5)
        #expect(glyphs[0].transform.b < -0.9, "tangent points up at the start")
        #expect(layout.sizes[0] == Size(width: PathTextTests.arch.bounds.width, height: PathTextTests.arch.bounds.height))
        Goldens.check(layout, name: "pathRotate", size: Size(width: 200, height: 120))
    }

    @Test func orientations() {
        func first(_ orientation: PathText.Orientation) -> LaidOutGlyph {
            Fixture.layout("Wave", in: [.path(PathText(contour: PathTextTests.arch, orientation: orientation, offsetStart: 40))]).glyphs()[0]
        }
        let vertical = first(.vertical).transform
        #expect(vertical.a == 1 && vertical.b == 0 && vertical.c == 0 && vertical.d == 1, "upright glyphs")
        let skewH = first(.skewHorizontal).transform
        #expect(skewH.a == 1 && skewH.b == 0 && skewH.c != 0, "horizontal baseline, leaning verticals")
        let skewV = first(.skewVertical).transform
        #expect(skewV.c == 0 && skewV.d == 1 && skewV.b != 0, "turned baseline, vertical verticals")
        for orientation in [PathText.Orientation.vertical, .skewHorizontal, .skewVertical] {
            let layout = Fixture.layout("Wave", in: [.path(PathText(contour: PathTextTests.arch, orientation: orientation, offsetStart: 40))])
            Goldens.check(layout, name: "path-\(orientation)", size: Size(width: 200, height: 120))
        }
    }

    @Test func alignmentToThePathAndAlongIt() {
        let text = "Hg"
        func glyph(_ top: PathText.Alignment) -> LaidOutGlyph {
            Fixture.layout(text, in: [.path(PathText(contour: Contour(polygon: [Point(x: 0, y: 50), Point(x: 200, y: 50)], closed: false), top: top))]).glyphs()[0]
        }
        #expect(approx(glyph(.baseline).origin.y, 50))
        #expect(approx(glyph(.ascent).origin.y, 50 + 9.24, 0.01), "the ascent touches the path: text hangs below")
        #expect(approx(glyph(.descent).origin.y, 50 - 2.76, 0.01), "the descent touches the path")
        let hidden = Fixture.layout(text, in: [.path(PathText(contour: Contour(polygon: [Point(x: 0, y: 50), Point(x: 200, y: 50)], closed: false), top: .none))])
        #expect(hidden.glyphs().isEmpty && hidden.overflows, "nothing drawn, the overflow dot shown (text-on-path)")

        let line = Contour(polygon: [Point(x: 0, y: 50), Point(x: 200, y: 50)], closed: false)
        let width = Fixture.layout(text, in: [.path(PathText(contour: line))]).glyphs().map { $0.origin.x + $0.advance }.max()!
        let centered = Fixture.layout(text, style: ParagraphStyle(alignment: .center), in: [.path(PathText(contour: line, offsetStart: 20, offsetEnd: 40))])
        #expect(approx(centered.glyphs()[0].origin.x, 20 + (140 - width) / 2, 0.01))
        let right = Fixture.layout(text, style: ParagraphStyle(alignment: .right), in: [.path(PathText(contour: line, offsetEnd: 30))])
        #expect(approx(right.glyphs()[0].origin.x, 170 - width, 0.01))
        let left = Fixture.layout(text, in: [.path(PathText(contour: line, offsetStart: 25))])
        #expect(approx(left.glyphs()[0].origin.x, 25, 0.01))
    }

    @Test func closedPathsCarryATopAndABottomRun() {
        let path = PathText(contour: PathTextTests.circle, top: .baseline, bottom: .ascent)
        let text = "TOP LINE\nbottom line\nrest"
        let layout = Fixture.layout(text, style: ParagraphStyle(alignment: .center), in: [.path(path), Fixture.block()])
        let glyphs = layout.glyphs(inContainer: 0)
        let top = glyphs.filter { $0.offset < 8 }
        let bottom = glyphs.filter { $0.offset > 8 && $0.offset < 20 }
        #expect(top.count == 8 && bottom.count == 11)
        #expect(top.allSatisfy { $0.origin.y < 70 }, "over the top")
        #expect(bottom.allSatisfy { $0.origin.y > 130 }, "under the bottom")
        // Both read left to right.
        #expect(top.map(\.origin.x) == top.map(\.origin.x).sorted())
        #expect(bottom.map(\.origin.x) == bottom.map(\.origin.x).sorted())
        // Centred on the top and bottom of the circle.
        let topMid = (top.first!.origin.x + top.last!.origin.x + top.last!.advance) / 2
        #expect(approx(topMid, 100, 3))
        // The third paragraph flows on to the linked block.
        #expect(layout.lineCount(inContainer: 1) == 1)
        Goldens.check(layout, name: "pathCircle", size: Size(width: 200, height: 200))
    }

    @Test func openPathsStopAtATabAndOverflowWhatDoesNotFit() {
        let short = Contour(polygon: [Point(x: 0, y: 20), Point(x: 60, y: 20)], closed: false)
        let tabbed = Fixture.layout("Tab\tafter", in: [.path(PathText(contour: short)), Fixture.block()])
        #expect(tabbed.glyphs(inContainer: 0).count == 3)
        #expect(tabbed.lineRanges[1].lowerBound == 4, "the text after the tab flows on")
        let long = Fixture.layout("This does not fit on the path", in: [.path(PathText(contour: short)), Fixture.block()])
        let placed = long.glyphs(inContainer: 0)
        #expect(placed.allSatisfy { $0.origin.x + $0.advance <= 60.01 })
        #expect(long.lineRanges[1].lowerBound == placed.map(\.offset).max()! + 1)
        let alone = Fixture.layout("This does not fit on the path", in: [.path(PathText(contour: short))])
        #expect(alone.overflows)
        // A tab ending the paragraph finishes it; an empty path places nothing.
        let trailing = Fixture.layout("ab\t\ncd", in: [.path(PathText(contour: short)), Fixture.block()])
        #expect(trailing.lineRanges.last!.lowerBound == 4)
        let empty = Fixture.layout("x", in: [.path(PathText(contour: Contour(segments: [], closed: false)))])
        #expect(empty.lineCount == 0 && empty.overflows)
        // A closed path whose top run overflows leaves the bottom empty.
        let tiny = Fixture.layout("A long top run\nbottom", in: [.path(PathText(contour: Contour(polygon: [Point(x: 0, y: 0), Point(x: 20, y: 0), Point(x: 20, y: 20)], closed: true)))])
        #expect(tiny.lineCount == 1 && tiny.overflows)
        // Cell breaks end the run like a paragraph end.
        let broken = Fixture.layout("ab\u{000C}cd", in: [.path(PathText(contour: short)), Fixture.block()])
        #expect(broken.lineRanges[1].lowerBound == 3)
    }

    @Test func tightCurvesRespaceLeftAlignedText() {
        // A small arc traversed so the glyphs sit inside it: their tops converge.
        let inside = Contour(segments: [
            CubicBezier(Point(x: 20, y: 20), Point(x: 20, y: 80), Point(x: 100, y: 80), Point(x: 100, y: 20)),
        ], closed: false)
        let path = PathText(contour: inside, top: .baseline)
        let layout = Fixture.layout("MMMMMM", attributes: TextAttributes(size: 18), in: [.path(path)])
        let glyphs = layout.glyphs()
        let naive = Fixture.layout("MMMMMM", style: ParagraphStyle(alignment: .center), attributes: TextAttributes(size: 18), in: [.path(PathText(contour: Contour(polygon: [Point(x: 0, y: 0), Point(x: 1000, y: 0)], closed: false)))]).glyphs()
        let spacing = glyphs.count > 1 ? glyphs[1].origin.distance(to: glyphs[0].origin) : 0
        #expect(spacing > naive[1].origin.x - naive[0].origin.x + 1, "pushed further apart than their advances")
        func box(_ glyph: LaidOutGlyph) -> [Point] {
            [Point(x: 0, y: -13), Point(x: glyph.advance, y: -13), Point(x: glyph.advance, y: 4), Point(x: 0, y: 4)].map(glyph.transform.apply)
        }
        for (lhs, rhs) in zip(glyphs, glyphs.dropFirst()) {
            #expect(!boxesOverlap(box(lhs), box(rhs)))
        }
    }

    @Test func textFlowsInsideAClosedPath() {
        let path = PathText(contour: PathTextTests.circle, mode: .inside, inset: Inset(left: 4, right: 4, top: 4, bottom: 4))
        let layout = Fixture.layout(Fixture.lorem, in: [.path(path)])
        #expect(layout.lineCount > 5)
        for glyph in layout.glyphs() {
            let corner = glyph.transform.apply(Point(x: glyph.advance, y: 0))
            #expect(glyph.origin.distance(to: Point(x: 100, y: 100)) < 60.5)
            #expect(corner.distance(to: Point(x: 100, y: 100)) < 60.5)
        }
        // Narrow near the top, wide in the middle.
        let extents = Fixture.lineExtents(layout, text: Fixture.lorem)
        let widths = extents.map { $0.end - $0.start }
        #expect(widths[0] < widths[widths.count / 2])
        Goldens.check(layout, name: "pathInside", size: Size(width: 200, height: 200))
        // An open path is closed for layout; a paragraph break continues; a cell break moves to
        // the next linked container, and in a lone container is a line break.
        #expect(Fixture.layout("x", in: [.path(PathText(contour: PathTextTests.arch, mode: .inside))]).lineCount == 1)
        let breaks = Fixture.layout("one\ntwo\u{000C}three", in: [.path(path), Fixture.block()])
        #expect(breaks.lineCount(inContainer: 0) == 2 && breaks.lineCount(inContainer: 1) == 1 && !breaks.overflows)
        let lone = Fixture.layout("one\ntwo\u{000C}three", in: [.path(path)])
        #expect(lone.lineCount == 3 && !lone.overflows)
        let spaced = TextContent(runs: [TextRun("a\nb", attributes: Fixture.body)], paragraphs: [ParagraphStyle(spaceBelow: 10), ParagraphStyle()])
        let spacedLayout = TextLayoutEngine().layout(spaced, in: [.path(path)])
        #expect(approx(spacedLayout.lineOrigins[1].y - spacedLayout.lineOrigins[0].y, 24.4, 0.01))
        // Too small for any line.
        let tiny = Contour(polygon: [Point(x: 0, y: 0), Point(x: 4, y: 0), Point(x: 4, y: 4)], closed: true)
        #expect(Fixture.layout("x", in: [.path(PathText(contour: tiny, mode: .inside))]).overflows)
    }

    @Test func pathCaretsFollowTheCurveAndHitTestsMapBack() {
        let layout = Fixture.layout("Along the arch", in: [.path(PathText(contour: PathTextTests.arch))])
        let glyphs = layout.glyphs()
        for offset in 0...14 {
            let caret = layout.caret(atOffset: offset)!
            #expect(PathTextTests.distance(from: caret.baseline, to: PathTextTests.arch) < 0.05)
            #expect(caret.top.distance(to: caret.baseline) > 8)
            if offset < 14 {
                #expect(caret.baseline.distance(to: glyphs[offset].origin) < 0.5, "the caret on the arc, the glyph origin on its chord")
            }
            #expect(layout.offset(at: caret.baseline, inContainer: 0) == offset)
        }
        let vertical = Fixture.layout("ab", in: [.path(PathText(contour: PathTextTests.arch, orientation: .vertical))])
        let caret = vertical.caret(atOffset: 1)!
        #expect(approx(caret.top.x, caret.baseline.x) && caret.top.y < caret.baseline.y)
        #expect(layout.displayItems(forContainer: 0).count == 1)
        #expect(layout.lineOrigins[0].distance(to: Point(x: 10, y: 110)) < 0.5)
    }

    @Test func arcLengthHandlesDegenerateSegments() {
        let contour = Contour(segments: [
            CubicBezier(Point(x: 0, y: 0), Point(x: 0, y: 0), Point(x: 0, y: 0), Point(x: 0, y: 0)),
            CubicBezier(Point(x: 0, y: 0), Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 0)),
        ], closed: false)
        let arc = ArcLength(contour)
        #expect(approx(arc.total, 10, 1e-3))
        let start = arc.frame(at: 0)
        #expect(start.tangent.length > 0.99)
        let middle = arc.frame(at: 5)
        #expect(approx(middle.point.x, 5, 1e-3) && approx(middle.tangent.dx, 1, 1e-6))
        let point = ArcLength(Contour(segments: [CubicBezier(Point(x: 3, y: 3), Point(x: 3, y: 3), Point(x: 3, y: 3), Point(x: 3, y: 3))], closed: false))
        #expect(point.frame(at: 1).tangent == Vector(dx: 1, dy: 0))
    }
}
