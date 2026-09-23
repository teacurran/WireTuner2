import WTGeometry
import Testing
@testable import WTRender

@Suite struct AppearanceTests {
    @Test func paintNoneAndColor() {
        #expect(Paint.none.color == nil)
        #expect(Paint.none.isNone)
        #expect(Paint.solid(red).color == red)
        #expect(!Paint.solid(red).isNone)
    }

    @Test func strokeStyleHairlineAndDashNormalization() {
        #expect(StrokeStyle(width: 0).isHairline)
        #expect(StrokeStyle(width: -1).isHairline)
        #expect(!StrokeStyle(width: 0.5).isHairline)
        #expect(StrokeStyle().effectiveDash.isEmpty)
        #expect(StrokeStyle(dash: [0, 0]).effectiveDash.isEmpty, "all-zero lengths read as solid")
        #expect(StrokeStyle(dash: [-1, 2]).effectiveDash.isEmpty)
        #expect(StrokeStyle(dash: [.nan, 2]).effectiveDash.isEmpty)
        #expect(StrokeStyle(dash: [.infinity]).effectiveDash.isEmpty)
        #expect(StrokeStyle(dash: [4, 2]).effectiveDash == [4, 2])
        #expect(StrokeStyle(dash: [3]).effectiveDash == [3], "an odd count is kept; Core Graphics repeats the cycle")
        #expect(StrokeStyle(dash: [0, 10]).effectiveDash == [0, 10], "dots: zero-length dashes with round caps")
    }

    @Test func arrowheadPresets() {
        #expect(Arrowhead.builtIns.count == 5)
        #expect(Set(Arrowhead.builtIns.map(\.name)).count == 5)
        #expect(approx(Arrowhead.triangle.extent, 2.5))
        #expect(approx(Arrowhead.open.extent, (4 + 1.75 * 1.75).squareRoot() + 0.5), "a stroked head reaches half a unit further")
        #expect(!Arrowhead.open.filled)
        #expect(Arrowhead.triangle.pathTrim == 1.5)
        #expect(Arrowhead(name: "x", shape: DisplayPath(), pathTrim: -3).pathTrim == 0)
        #expect(Arrowhead(name: "x", shape: DisplayPath()).extent == 0)
    }

    @Test func strokePaintOutsetIncludesArrowheads() {
        let plain = StrokePaint(paint: .solid(red), style: StrokeStyle(width: 2, miterLimit: 1))
        #expect(!plain.hasArrowheads)
        #expect(approx(plain.outset, 2.0.squareRoot()))
        let headed = StrokePaint(paint: .solid(red), style: StrokeStyle(width: 2, miterLimit: 1), endArrowhead: .triangle)
        #expect(headed.hasArrowheads)
        #expect(approx(headed.outset, 5), "2.5 units × width 2")
        let hairline = StrokePaint(paint: .solid(red), style: StrokeStyle(width: 0), startArrowhead: .triangle)
        #expect(!hairline.hasArrowheads, "heads scale with width, so a hairline has none")
        #expect(hairline.outset == 0)
        #expect(!hairline.overprint)
    }

    @Test func appearanceReadOuts() {
        let appearance = Appearance([
            .fill(FillPaint(paint: .none)),
            .stroke(StrokePaint(paint: .solid(red), style: StrokeStyle(width: 3))),
            .fill(FillPaint(paint: .solid(blue), rule: .evenOdd, overprint: true)),
            .stroke(StrokePaint(paint: .none, style: StrokeStyle(width: 9))),
            .stroke(StrokePaint(paint: .solid(green), style: StrokeStyle(width: 5))),
        ])
        #expect(appearance.fills.count == 2)
        #expect(appearance.strokes.count == 3)
        #expect(appearance.paintsInterior)
        #expect(appearance.widestStroke?.style.width == 5, "a None stroke never sets the tolerance")
        #expect(approx(appearance.outset, 9 * 10 / 2), "bounds stay conservative: every stroke's outset counts")
        #expect(appearance.fills[1].overprint && appearance.fills[1].rule == .evenOdd)

        #expect(!Appearance([.fill(FillPaint(paint: .none))]).paintsInterior)
        #expect(Appearance().widestStroke == nil)
        #expect(Appearance().outset == 0)

        let standard = Appearance.fillAndStroke(fill: red, stroke: .black, width: 2)
        #expect(standard.items.count == 2)
        guard case .fill = standard.items[0], case .stroke(let stroke) = standard.items[1] else {
            Issue.record("a new object gets one fill with one stroke above it")
            return
        }
        #expect(stroke.style.width == 2)
    }

    @Test func pathItemBoundsAndTransform() {
        let rect = Rect(x: 0, y: 0, width: 10, height: 10)
        let fillOnly = DisplayItem.path(PathItem(path: DisplayPath(rect: rect), appearance: Appearance([.fill(FillPaint(paint: .solid(red)))]), transform: .translation(x: 5, y: 0)))
        #expect(fillOnly.bounds == Rect(x: 5, y: 0, width: 10, height: 10))
        #expect(fillOnly.transform == .translation(x: 5, y: 0))
        let stroked = DisplayItem.path(PathItem(path: DisplayPath(rect: rect), appearance: .fillAndStroke(fill: red, stroke: .black, width: 2)))
        #expect(stroked.bounds == rect.expanded(by: 10), "width 2 × miter limit 10 / 2")
        let empty = DisplayItem.path(PathItem(path: DisplayPath(), appearance: Appearance()))
        #expect(empty.bounds == nil)
    }

    @Test func groupHighlightColor() {
        #expect(GroupItem(children: []).highlightColor == nil)
        #expect(GroupItem(children: [], highlightColor: red).highlightColor == red)
    }
}

@Suite struct PathGeometryTests {
    @Test func contoursOfRectsEllipsesAndSubpaths() {
        let rect = DisplayPath(rect: Rect(x: 0, y: 0, width: 10, height: 5)).contours
        #expect(rect.count == 1)
        #expect(rect[0].isClosed)
        #expect(rect[0].segments.count == 3, "the fourth side is the implicit closing segment")
        #expect(rect[0].closingSegment != nil)

        let ellipse = DisplayPath(ellipseIn: Rect(x: 0, y: 0, width: 10, height: 10)).contours
        #expect(ellipse.count == 1 && ellipse[0].segments.count == 4)

        var path = DisplayPath()
        path.move(to: Point(x: 0, y: 0))
        path.addLine(to: Point(x: 10, y: 0))
        path.addQuadCurve(control: Point(x: 10, y: 10), to: Point(x: 0, y: 10))
        path.close()
        path.addLine(to: Point(x: -5, y: 0))  // continues from the closed subpath's start
        path.addCubicCurve(control1: Point(x: -5, y: 5), control2: Point(x: -10, y: 5), to: Point(x: -10, y: 0))
        path.move(to: Point(x: 50, y: 50))
        path.close()  // a subpath with no segments is dropped
        path.move(to: Point(x: 60, y: 60))
        let contours = path.contours
        #expect(contours.count == 2)
        #expect(contours[0].isClosed && contours[0].segments.count == 2)
        #expect(!contours[1].isClosed)
        #expect(contours[1].startPoint == Point(x: 0, y: 0))
        #expect(contours[1].endPoint == Point(x: -10, y: 0))
    }

    @Test func drawingWithoutACurrentPointActsAsAMove() {
        let line = DisplayPath(elements: [.line(to: Point(x: 1, y: 1)), .line(to: Point(x: 2, y: 1))]).contours
        #expect(line.count == 1 && line[0].startPoint == Point(x: 1, y: 1))
        let quad = DisplayPath(elements: [.quadCurve(control: .zero, end: Point(x: 1, y: 1)), .line(to: Point(x: 3, y: 1))]).contours
        #expect(quad.count == 1 && quad[0].startPoint == Point(x: 1, y: 1))
        let cubic = DisplayPath(elements: [.cubicCurve(control1: .zero, control2: .zero, end: Point(x: 2, y: 2)), .line(to: Point(x: 3, y: 1))]).contours
        #expect(cubic.count == 1 && cubic[0].startPoint == Point(x: 2, y: 2))
        #expect(DisplayPath().contours.isEmpty)
    }

    @Test func contoursRoundTrip() {
        let original = star(center: Point(x: 10, y: 10), radius: 8).contours
        let rebuilt = DisplayPath(contours: original)
        #expect(rebuilt.contours == original)
        #expect(DisplayPath(contours: [Contour(segments: [], closed: true)]).isEmpty)
        let open = DisplayPath(contours: [Contour(polygon: [.zero, Point(x: 1, y: 0)], closed: false)])
        #expect(open.elements.last != .close)
    }

    @Test func anchorsAndControls() {
        var path = DisplayPath()
        path.move(to: Point(x: 0, y: 0))
        path.addLine(to: Point(x: 1, y: 0))
        path.addQuadCurve(control: Point(x: 2, y: 1), to: Point(x: 3, y: 0))
        path.addCubicCurve(control1: Point(x: 4, y: 1), control2: Point(x: 5, y: 1), to: Point(x: 6, y: 0))
        path.close()
        let anchors = path.points(includeControls: false)
        #expect(anchors.map(\.element) == [0, 1, 2, 3])
        #expect(anchors.allSatisfy { $0.control == 0 })
        let all = path.points(includeControls: true)
        #expect(all.map { [$0.element, $0.control] } == [[0, 0], [1, 0], [2, 1], [2, 0], [3, 1], [3, 2], [3, 0]])
        #expect(all[4].point == Point(x: 4, y: 1))
    }

    private func headed(_ path: DisplayPath, width: Double = 2, start: Arrowhead? = .triangle, end: Arrowhead? = .triangle) -> StrokeGeometry {
        StrokeGeometry(path: path, stroke: StrokePaint(paint: .solid(.black), style: StrokeStyle(width: width), startArrowhead: start, endArrowhead: end))
    }

    @Test func arrowheadsTrimAndPlaceOnOpenEnds() {
        let line = DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 100, y: 0)], closed: false)
        let geometry = headed(line)
        #expect(geometry.heads.count == 2)
        let body = geometry.body.contours
        #expect(body.count == 1)
        #expect(approx(body[0].startPoint!, Point(x: 3, y: 0), tolerance: 1e-6), "trimmed by 1.5 units × width 2")
        #expect(approx(body[0].endPoint!, Point(x: 97, y: 0), tolerance: 1e-6))
        // The start head points back past the start; the end head along the path.
        let startHead = geometry.heads[0].transform
        #expect(approx(startHead.apply(.zero), .zero))
        #expect(approx(startHead.apply(Point(x: 1, y: 0)), Point(x: -2, y: 0), tolerance: 1e-12))
        let endHead = geometry.heads[1].transform
        #expect(approx(endHead.apply(.zero), Point(x: 100, y: 0)))
        #expect(approx(endHead.apply(Point(x: 1, y: 0)), Point(x: 102, y: 0), tolerance: 1e-12))
        #expect(approx(endHead.apply(Point(x: 0, y: 1)), Point(x: 100, y: 2), tolerance: 1e-12))

        let untrimmed = headed(line, start: .circle, end: nil)
        #expect(untrimmed.heads.count == 1)
        #expect(untrimmed.body.contours[0].startPoint == Point(x: 0, y: 0), "a head with no trim leaves the path")
    }

    @Test func arrowheadsFollowTheTangentOnCurves() {
        var curve = DisplayPath()
        curve.move(to: .zero)
        curve.addCubicCurve(control1: Point(x: 0, y: 10), control2: Point(x: 10, y: 10), to: Point(x: 10, y: 0))
        let geometry = headed(curve, width: 1, start: .circle, end: .circle)
        // Leaves the start going +y, so the start head points -y; arrives going -y.
        let start = geometry.heads[0].transform.apply(Point(x: 1, y: 0))
        #expect(approx(start, Point(x: 0, y: -1), tolerance: 1e-9))
        let end = geometry.heads[1].transform.apply(Point(x: 1, y: 0))
        #expect(approx(end, Point(x: 10, y: -1), tolerance: 1e-9))
    }

    @Test func closedEndsAndDegenerateContoursCarryNoHeads() {
        let closed = DisplayPath(rect: Rect(x: 0, y: 0, width: 10, height: 10))
        let onClosed = headed(closed)
        #expect(onClosed.heads.isEmpty)
        #expect(onClosed.body == closed)

        let dot = DisplayPath(polygon: [Point(x: 5, y: 5), Point(x: 5, y: 5)], closed: false)
        #expect(headed(dot).heads.isEmpty, "no extent, no tangent")

        // Start on an open contour, end on a closed one: only the start head.
        var mixed = DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 50, y: 0)], closed: false)
        mixed.elements += DisplayPath(rect: Rect(x: 60, y: 0, width: 10, height: 10)).elements
        let partial = headed(mixed)
        #expect(partial.heads.count == 1)
        #expect(partial.body.contours.count == 2)

        let hairline = StrokeGeometry(path: DisplayPath(polygon: [.zero, Point(x: 9, y: 0)], closed: false), stroke: StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 0), endArrowhead: .triangle))
        #expect(hairline.heads.isEmpty)
    }

    @Test func trimmingMorePathThanThereIsLeavesNoBody() {
        let short = DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 2, y: 0), Point(x: 4, y: 0)], closed: false)
        let geometry = headed(short, width: 4)
        #expect(geometry.heads.count == 2, "heads still draw")
        #expect(geometry.body.isEmpty)

        let contour = Contour(polygon: [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 20, y: 0)], closed: false)
        let trimmed = StrokeGeometry.trimmingStart(of: contour, by: 15)
        #expect(trimmed.segments.count == 1)
        #expect(approx(trimmed.startPoint!, Point(x: 15, y: 0), tolerance: 1e-6))
        #expect(StrokeGeometry.trimmingStart(of: contour, by: 0) == contour)
        let fromEnd = StrokeGeometry.trimmingEnd(of: contour, by: 5)
        #expect(approx(fromEnd.endPoint!, Point(x: 15, y: 0), tolerance: 1e-6))
        #expect(StrokeGeometry.startPlacement(of: Contour(segments: [], closed: false)) == nil)
        #expect(StrokeGeometry.endPlacement(of: Contour(segments: [], closed: false)) == nil)
    }
}
