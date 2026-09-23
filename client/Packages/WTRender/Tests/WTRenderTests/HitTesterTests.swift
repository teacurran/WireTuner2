import WTGeometry
import Testing
@testable import WTRender

@Suite struct HitTesterTests {
    static let viewSize = Size(width: 400, height: 300)

    func tester(_ items: [DisplayItem], viewport: Viewport = Viewport(size: viewSize), options: HitOptions = HitOptions()) -> HitTester {
        HitTester(displayList: DisplayList(canvas: "hit", items: items), viewport: viewport, options: options)
    }

    func pathItem(_ path: DisplayPath, _ items: [AppearanceItem], transform: AffineTransform = .identity) -> DisplayItem {
        .path(PathItem(path: path, appearance: Appearance(items), transform: transform))
    }

    func filled(_ rect: Rect, rule: FillRule = .nonZero) -> DisplayItem {
        pathItem(DisplayPath(rect: rect), [.fill(FillPaint(paint: .solid(red), rule: rule))])
    }

    func stroked(_ path: DisplayPath, width: Double, cap: LineCap = .butt, paint: Paint = .solid(.black), end: Arrowhead? = nil) -> DisplayItem {
        pathItem(path, [.stroke(StrokePaint(paint: paint, style: StrokeStyle(width: width, cap: cap), endArrowhead: end))])
    }

    func kinds(_ results: [HitResult]) -> [HitKind] {
        results.map(\.kind)
    }

    static let horizontal = DisplayPath(polygon: [Point(x: 100, y: 100), Point(x: 200, y: 100)], closed: false)

    // MARK: Kinds

    @Test func fillsHitInsideAndPathsNearTheirOutline() {
        let hits = tester([filled(Rect(x: 10, y: 10, width: 100, height: 50))])
        #expect(hits.hitTest(viewPoint: Point(x: 50, y: 30)) == [HitResult(itemPath: [0], leafPath: [0], kind: .fill, distance: 0)])
        #expect(hits.hitTest(viewPoint: Point(x: 200, y: 200)).isEmpty)
        let nearEdge = hits.hitTest(viewPoint: Point(x: 50, y: 8))
        #expect(nearEdge.count == 1)
        guard case .segment(let location) = nearEdge[0].kind else {
            Issue.record("an unstroked outline hits as a segment: \(nearEdge)")
            return
        }
        #expect(location.contour == 0 && location.segment == 0 && approx(location.t, 0.4))
        #expect(approx(nearEdge[0].distance, 2))
        #expect(kinds(hits.hitTest(viewPoint: Point(x: 111, y: 61))) == [.point(element: 2)])
    }

    @Test func fillRulesDecideTheInterior() {
        let center = Point(x: 60, y: 60)
        let nonZero = tester([pathItem(star(center: center, radius: 50), [.fill(FillPaint(paint: .solid(red), rule: .nonZero))])])
        #expect(kinds(nonZero.hitTest(viewPoint: center)) == [.fill])
        let evenOdd = tester([pathItem(star(center: center, radius: 50), [.fill(FillPaint(paint: .solid(red), rule: .evenOdd))])])
        #expect(evenOdd.hitTest(viewPoint: center).isEmpty, "the pentagon of an even-odd star is a hole")

        var frame = DisplayPath(rect: Rect(x: 0, y: 0, width: 100, height: 100))
        frame.elements += DisplayPath(rect: Rect(x: 30, y: 30, width: 40, height: 40)).elements
        #expect(tester([pathItem(frame, [.fill(FillPaint(paint: .solid(red), rule: .evenOdd))])]).hitTest(viewPoint: Point(x: 50, y: 50)).isEmpty)
        #expect(kinds(tester([pathItem(frame, [.fill(FillPaint(paint: .solid(red)))])]).hitTest(viewPoint: Point(x: 50, y: 50))) == [.fill])
    }

    @Test func noneFillsDoNotHit() {
        let rect = DisplayPath(rect: Rect(x: 0, y: 0, width: 100, height: 100))
        let middle = Point(x: 50, y: 50)
        #expect(tester([pathItem(rect, [.fill(FillPaint(paint: .none))])]).hitTest(viewPoint: middle).isEmpty)
        #expect(tester([.fill(FillItem(path: rect, paint: .none))]).hitTest(viewPoint: middle).isEmpty)
        #expect(kinds(tester([.fill(FillItem(path: rect, paint: .solid(red)))]).hitTest(viewPoint: middle)) == [.fill])
    }

    @Test func strokesHitWithinHalfWidthPlusTolerance() {
        let hits = tester([stroked(Self.horizontal, width: 10)])
        let result = hits.hitTest(viewPoint: Point(x: 150, y: 107.5))
        #expect(result.count == 1)
        #expect(result[0].kind == .stroke(PathLocation(contour: 0, segment: 0, t: 0.5)))
        #expect(approx(result[0].distance, 7.5))
        #expect(hits.hitTest(viewPoint: Point(x: 150, y: 108.5)).isEmpty)

        let legacy = tester([.stroke(StrokeItem(path: Self.horizontal, style: StrokeStyle(width: 10), paint: .solid(.black)))])
        #expect(legacy.hitTest(viewPoint: Point(x: 150, y: 104)).count == 1)
        let legacyNone = tester([.stroke(StrokeItem(path: Self.horizontal, style: StrokeStyle(width: 10), paint: .none))])
        #expect(legacyNone.hitTest(viewPoint: Point(x: 150, y: 104)).isEmpty)
        guard case .segment = legacyNone.hitTest(viewPoint: Point(x: 150, y: 102)).first?.kind else {
            Issue.record("a None stroke leaves the bare path pickable")
            return
        }
    }

    @Test func noneStrokesFallBackToThePath() {
        let hits = tester([stroked(Self.horizontal, width: 10, paint: .none)])
        #expect(hits.hitTest(viewPoint: Point(x: 150, y: 104)).isEmpty)
        guard case .segment = hits.hitTest(viewPoint: Point(x: 150, y: 102)).first?.kind else {
            Issue.record("expected a segment hit")
            return
        }
    }

    @Test func capsDecideWhatLiesPastAnOpenEnd() {
        let options = HitOptions(pickPoints: false)
        func hit(_ cap: LineCap, _ point: Point) -> Bool {
            !tester([stroked(Self.horizontal, width: 10, cap: cap)], options: options).hitTest(viewPoint: point).isEmpty
        }
        let beyond = Point(x: 207, y: 100)
        #expect(!hit(.butt, beyond), "a butt end paints nothing past the end point")
        #expect(hit(.square, beyond))
        #expect(hit(.round, beyond))
        #expect(hit(.butt, Point(x: 202, y: 100)), "within the pick tolerance of the butt end")
        #expect(hit(.butt, Point(x: 98, y: 100)), "the start end too")
        #expect(!hit(.butt, Point(x: 94, y: 100)))
        let corner = Point(x: 206, y: 106)
        #expect(!hit(.round, corner), "8.5 units from the end is outside the round cap's reach of 8")
        #expect(hit(.square, corner))
        #expect(!hit(.square, Point(x: 206, y: 109)))

        // A zero-length open path has no end direction: the cap test defers to distance.
        let dot = DisplayPath(polygon: [Point(x: 50, y: 50), Point(x: 50, y: 50)], closed: false)
        #expect(!tester([stroked(dot, width: 4)], options: options).hitTest(viewPoint: Point(x: 52, y: 50)).isEmpty)
    }

    @Test func closedStrokesIncludeTheClosingSegment() {
        let hits = tester([stroked(DisplayPath(rect: Rect(x: 10, y: 10, width: 100, height: 50)), width: 4)])
        let result = hits.hitTest(viewPoint: Point(x: 7, y: 35))
        #expect(result.first?.kind == .stroke(PathLocation(contour: 0, segment: 3, t: 0.5)))
        #expect(hits.hitTest(viewPoint: Point(x: 60, y: 35)).isEmpty, "an unfilled interior never hits")
    }

    @Test func curvedStrokes() {
        var curve = DisplayPath()
        curve.move(to: Point(x: 100, y: 100))
        curve.addCubicCurve(control1: Point(x: 100, y: 200), control2: Point(x: 200, y: 200), to: Point(x: 200, y: 100))
        let hits = tester([stroked(curve, width: 2)])
        let top = Point(x: 150, y: 175)  // the curve's apex
        guard case .stroke(let location)? = hits.hitTest(viewPoint: Point(x: top.x, y: top.y + 3)).first?.kind else {
            Issue.record("expected a stroke hit on the curve")
            return
        }
        #expect(location.map { approx($0.t, 0.5, tolerance: 1e-6) } == true)
        #expect(hits.hitTest(viewPoint: Point(x: 150, y: 150)).isEmpty)
    }

    @Test func pointsAndHandles() {
        var curve = DisplayPath()
        curve.move(to: Point(x: 100, y: 100))
        curve.addCubicCurve(control1: Point(x: 100, y: 150), control2: Point(x: 200, y: 150), to: Point(x: 200, y: 100))
        let item = pathItem(curve, [])
        let control = Point(x: 101, y: 151)
        #expect(kinds(tester([item], options: HitOptions(pickHandles: true)).hitTest(viewPoint: control)) == [.handle(element: 1, control: 1)])
        #expect(kinds(tester([item], options: HitOptions(pickHandles: true)).hitTest(viewPoint: Point(x: 199, y: 151))) == [.handle(element: 1, control: 2)])
        #expect(tester([item]).hitTest(viewPoint: control).isEmpty, "handles are off by default")
        #expect(kinds(tester([item]).hitTest(viewPoint: Point(x: 201, y: 101))) == [.point(element: 1)])

        let handlesOnly = tester([item], options: HitOptions(pickPoints: false, pickHandles: true))
        guard case .segment = handlesOnly.hitTest(viewPoint: Point(x: 100, y: 101)).first?.kind else {
            Issue.record("with points off an anchor is just on the path")
            return
        }
        // Two anchors within reach: the closer one wins.
        let close = DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 4, y: 0)], closed: false)
        #expect(kinds(tester([pathItem(close, [])]).hitTest(viewPoint: Point(x: 3, y: 0))) == [.point(element: 1)])
    }

    @Test func arrowheadsHitAsTheStroke() {
        let fine = HitOptions(pickDistanceInViewPixels: 1, pickPoints: false)
        let triangle = tester([stroked(Self.horizontal, width: 4, end: .triangle)], options: fine)
        // Inside the head, 4.5 units off the centreline (beyond half width 2 + tolerance 1).
        #expect(kinds(triangle.hitTest(viewPoint: Point(x: 193, y: 104.5))) == [.stroke(nil)])
        #expect(kinds(triangle.hitTest(viewPoint: Point(x: 193, y: 106.5))) == [.stroke(nil)], "within the tolerance of the head's edge")
        #expect(triangle.hitTest(viewPoint: Point(x: 193, y: 110)).isEmpty)

        let open = tester([stroked(Self.horizontal, width: 4, end: .open)], options: fine)
        #expect(kinds(open.hitTest(viewPoint: Point(x: 196, y: 96.5))) == [.stroke(nil)])

        let invisible = tester([pathItem(Self.horizontal, [
            .stroke(StrokePaint(paint: .none, style: StrokeStyle(width: 4), endArrowhead: .triangle)),
        ])], options: fine)
        #expect(invisible.hitTest(viewPoint: Point(x: 193, y: 104.5)).isEmpty)
    }

    @Test func textAndImageFrames() {
        let text = DisplayItem.text(TextRunItem(text: "t", origin: Point(x: 10, y: 25), bounds: Rect(x: 10, y: 10, width: 60, height: 20)))
        let hits = tester([text])
        #expect(hits.hitTest(viewPoint: Point(x: 30, y: 20)) == [HitResult(itemPath: [0], leafPath: [0], kind: .text, distance: 0)])
        let near = hits.hitTest(viewPoint: Point(x: 30, y: 8))
        #expect(near.first?.kind == .text && approx(near.first!.distance, 2))
        #expect(hits.hitTest(viewPoint: Point(x: 30, y: 0)).isEmpty)

        let image = DisplayItem.image(ImageItem(assetID: "i", rect: Rect(x: 0, y: 0, width: 40, height: 20), transform: AffineTransform.rotation(degrees: 90).concatenating(.translation(x: 100, y: 100))))
        #expect(kinds(tester([image]).hitTest(viewPoint: Point(x: 90, y: 120))) == [.image])
        #expect(tester([image]).hitTest(viewPoint: Point(x: 120, y: 90)).isEmpty)
    }

    // MARK: Ordering, groups, options

    @Test func resultsAreTopMostFirst() {
        let hits = tester([filled(Rect(x: 0, y: 0, width: 100, height: 100)), filled(Rect(x: 50, y: 50, width: 100, height: 100))])
        #expect(hits.hitTest(viewPoint: Point(x: 75, y: 75)).map(\.itemPath) == [[1], [0]])
    }

    @Test func groupsVersusContents() {
        let group = DisplayItem.group(GroupItem(children: [
            filled(Rect(x: 10, y: 10, width: 50, height: 50)),
            filled(Rect(x: 40, y: 40, width: 50, height: 50)),
            pathItem(DisplayPath(), [.fill(FillPaint(paint: .solid(red)))]),
        ]))
        let items = [filled(Rect(x: 0, y: 0, width: 200, height: 200)), group]
        let point = Point(x: 45, y: 45)

        let pointer = tester(items).hitTest(viewPoint: point)
        #expect(pointer == [
            HitResult(itemPath: [1], leafPath: [1, 1], kind: .fill, distance: 0),
            HitResult(itemPath: [0], leafPath: [0], kind: .fill, distance: 0),
        ], "clicking a member selects the group")

        let subselect = tester(items, options: HitOptions(subselect: true)).hitTest(viewPoint: point)
        #expect(subselect.map(\.itemPath) == [[1, 1], [1, 0], [0]], "subselect names each member, top-most first")

        let nested = DisplayItem.group(GroupItem(children: [.group(GroupItem(children: [filled(Rect(x: 0, y: 0, width: 20, height: 20))]))]))
        #expect(tester([nested], options: HitOptions(subselect: true)).hitTest(viewPoint: Point(x: 10, y: 10)).map(\.itemPath) == [[0, 0, 0]])
        #expect(tester([nested]).hitTest(viewPoint: Point(x: 10, y: 10)).map(\.leafPath) == [[0, 0, 0]])
    }

    @Test func clipsBoundWhatAGroupCanHit() {
        let clipped = DisplayItem.group(GroupItem(
            children: [filled(Rect(x: 0, y: 0, width: 100, height: 100))],
            clip: DisplayPath(rect: Rect(x: 0, y: 0, width: 20, height: 20)),
            transform: .translation(x: 10, y: 10)
        ))
        let hits = tester([clipped])
        #expect(hits.hitTest(viewPoint: Point(x: 50, y: 50)).isEmpty, "outside the clip nothing of the group shows")
        #expect(hits.hitTest(viewPoint: Point(x: 20, y: 20)).map(\.itemPath) == [[0]])
    }

    @Test func pickDistanceIsInViewPixels() {
        let hairline = stroked(DisplayPath(polygon: [Point(x: 100, y: 100), Point(x: 300, y: 100)], closed: false), width: 0)
        let off = Point(x: 200, y: 102.4)
        let atOne = Viewport(size: Self.viewSize)
        #expect(!tester([hairline], viewport: atOne).hitTest(viewPoint: atOne.toView(off)).isEmpty)
        let atTwo = Viewport(scrollOrigin: Point(x: 100, y: 0), rotationDegrees: 90, zoom: 2, size: Self.viewSize)
        #expect(tester([hairline], viewport: atTwo).hitTest(viewPoint: atTwo.toView(off)).isEmpty, "3 view px is 1.5 units at 200%")
        let onLine = tester([hairline], viewport: atTwo).hitTest(viewPoint: atTwo.toView(Point(x: 200, y: 101)))
        guard case .stroke = onLine.first?.kind else {
            Issue.record("the pointer maps through the rotated view transform: \(onLine)")
            return
        }
        #expect(HitOptions().pasteboardTolerance(for: atTwo) == 1.5)
        let wide = HitOptions(pickDistanceInViewPixels: 5)
        #expect(!tester([hairline], viewport: atTwo, options: wide).hitTest(viewPoint: atTwo.toView(off)).isEmpty)
    }

    @Test func pickDistanceIsClamped() {
        #expect(HitOptions(pickDistanceInViewPixels: 0).pickDistanceInViewPixels == 1)
        #expect(HitOptions(pickDistanceInViewPixels: 9).pickDistanceInViewPixels == 5)
        #expect(HitOptions(pickDistanceInViewPixels: .nan).pickDistanceInViewPixels == 3)
        var options = HitOptions()
        #expect(options.pickDistanceInViewPixels == HitOptions.defaultPickDistance)
        options.pickDistanceInViewPixels = 10
        #expect(options.pickDistanceInViewPixels == 5)
        #expect(!options.subselect && !options.contactSensitive && options.pickPoints && !options.pickHandles)
    }

    @Test func indexFollowsChanges() {
        let a = filled(Rect(x: 0, y: 0, width: 50, height: 50))
        let b = filled(Rect(x: 200, y: 0, width: 50, height: 50))
        var hits = tester([a, b])
        #expect(hits.index.count == 2)

        let moved = filled(Rect(x: 100, y: 100, width: 50, height: 50))
        hits.update(displayList: DisplayList(canvas: "hit", items: [moved, b]), changedIndices: [0, 7])
        #expect(hits.hitTest(viewPoint: Point(x: 120, y: 120)).map(\.itemPath) == [[0]])
        #expect(hits.hitTest(viewPoint: Point(x: 20, y: 20)).isEmpty)
        #expect(hits.index.bounds(of: 0) == Rect(x: 100, y: 100, width: 50, height: 50))

        let emptied = pathItem(DisplayPath(), [])
        hits.update(displayList: DisplayList(canvas: "hit", items: [moved, emptied]), changedIndices: [1])
        #expect(!hits.index.contains(1))
        #expect(hits.displayList.count == 2)

        hits.update(displayList: DisplayList(canvas: "hit", items: [a, b, moved]), changedIndices: [0])
        #expect(hits.index.count == 3, "a different length rebuilds")
        hits.update(displayList: DisplayList(canvas: "hit", items: [b]))
        #expect(hits.index.count == 1 && hits.hitTest(viewPoint: Point(x: 220, y: 20)).count == 1)
    }

    // MARK: Marquee

    @Test func marqueeEnclosedVersusContact() {
        let square = filled(Rect(x: 10, y: 10, width: 40, height: 40))
        let line = stroked(DisplayPath(polygon: [Point(x: 0, y: 100), Point(x: 300, y: 100)], closed: false), width: 2)
        let hits = tester([square, line])

        let around = hits.hitTest(marquee: Rect(x: 0, y: 0, width: 100, height: 90))
        #expect(around.count == 1)
        #expect(around[0].itemPath == [0] && around[0].selected)
        #expect(around[0].anchors.map(\.element) == [0, 1, 2, 3])

        let across = Rect(x: 30, y: 0, width: 50, height: 200)
        let enclosed = hits.hitTest(marquee: across, contactSensitive: false)
        #expect(enclosed == [MarqueeHit(itemPath: [0], selected: false, anchors: [
            AnchorReference(leafPath: [0], element: 1), AnchorReference(leafPath: [0], element: 2),
        ])], "points inside the marquee are picked in either mode")
        let contact = hits.hitTest(marquee: across, contactSensitive: true)
        #expect(contact.map(\.itemPath) == [[1], [0]])
        #expect(contact.allSatisfy { $0.selected }, "the line is touched though neither end is inside")

        var contactOptions = hits
        contactOptions.options.contactSensitive = true
        #expect(contactOptions.hitTest(marquee: across).map(\.itemPath) == [[1], [0]], "defaults to the options' setting")

        #expect(hits.hitTest(marquee: Rect(x: 20, y: 20, width: 10, height: 10), contactSensitive: true).isEmpty, "inside a fill but touching no edge")
    }

    @Test func marqueeOverGroups() {
        let group = DisplayItem.group(GroupItem(children: [
            filled(Rect(x: 10, y: 10, width: 20, height: 20)),
            filled(Rect(x: 100, y: 10, width: 20, height: 20)),
            pathItem(DisplayPath(), []),
        ]))
        let marquee = Rect(x: 0, y: 0, width: 50, height: 50)
        let enclosed = tester([group]).hitTest(marquee: marquee, contactSensitive: false)
        #expect(enclosed.count == 1 && !enclosed[0].selected && enclosed[0].anchors.count == 4, "a group is enclosed only when every member is")
        #expect(tester([group]).hitTest(marquee: Rect(x: 0, y: 0, width: 200, height: 50)).first?.selected == true)
        #expect(tester([group]).hitTest(marquee: marquee, contactSensitive: true).first?.selected == true)
        let subselect = tester([group], options: HitOptions(subselect: true)).hitTest(marquee: marquee, contactSensitive: false)
        #expect(subselect.map(\.itemPath) == [[0, 0]] && subselect[0].selected)
        #expect(HitTester.leaves(of: group, path: [0]).map(\.path) == [[0, 0], [0, 1]])
    }

    @Test func marqueeOverTextImagesAndARotatedView() {
        let text = DisplayItem.text(TextRunItem(text: "t", origin: Point(x: 10, y: 18), bounds: Rect(x: 10, y: 10, width: 20, height: 10)))
        let image = DisplayItem.image(ImageItem(assetID: "i", rect: Rect(x: 60, y: 10, width: 20, height: 10)))
        let hits = tester([text, image])
        #expect(hits.hitTest(marquee: Rect(x: 0, y: 0, width: 40, height: 40)).map(\.itemPath) == [[0]])
        #expect(hits.hitTest(marquee: Rect(x: 70, y: 0, width: 40, height: 40), contactSensitive: true).map(\.itemPath) == [[1]])

        let rotated = Viewport(size: Self.viewSize).rotated(toDegrees: 90)
        let square = filled(Rect(x: 100, y: 100, width: 20, height: 20))
        let corners = [Point(x: 95, y: 95), Point(x: 125, y: 125)].map { rotated.toView($0) }
        let viewRect = Rect(corners[0], corners[1])
        let result = tester([square], viewport: rotated).hitTest(marquee: viewRect)
        #expect(result.first?.selected == true && result.first?.anchors.count == 4)
    }

    @Test func outlineCrossingHelper() {
        let rect = Rect(x: 0, y: 0, width: 10, height: 10)
        let through = Contour(polygon: [Point(x: -5, y: 5), Point(x: 15, y: 5)], closed: false)
        #expect(HitTester.outline(of: [through], crosses: rect))
        let away = Contour(polygon: [Point(x: -5, y: 20), Point(x: 15, y: 20)], closed: false)
        #expect(!HitTester.outline(of: [away], crosses: rect))
        let nearMiss = Contour(polygon: [Point(x: 8, y: -5), Point(x: 20, y: 7)], closed: false)
        #expect(!HitTester.outline(of: [nearMiss], crosses: rect), "hulls overlap, the segment does not")
    }
}
