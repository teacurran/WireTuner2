import WTGeometry
import CoreGraphics
import Testing
@testable import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// Renders `items` with Core Graphics over white at `scale`.
func renderSurface(_ items: [DisplayItem], size: Size = Size(width: 128, height: 96), scale: Double = 1, mode: ViewMode = .preview, overprint: Bool = false) -> BitmapSurface {
    let renderer = CoreGraphicsRenderer(background: .white, viewMode: mode, overprintPreview: overprint)
    let image = renderer.renderBitmap(DisplayList(canvas: "test", items: items), viewport: Viewport(size: size), scale: scale)!
    return BitmapSurface(drawing: image)!
}

/// Whether two surfaces hold the same pixels.
func samePixels(_ a: BitmapSurface, _ b: BitmapSurface) -> Bool {
    guard a.width == b.width, a.height == b.height else { return false }
    for y in 0..<a.height {
        for x in 0..<a.width where a.pixel(x: x, y: y) != b.pixel(x: x, y: y) {
            return false
        }
    }
    return true
}

/// ATTR-004: the interleaved stack painted bottom first, hidden elements skipped at build time,
/// and hit testing on the new stack kinds.
@Suite struct AttributeStackTests {
    static let square = DisplayPath(rect: Rect(x: 20, y: 20, width: 60, height: 40))

    func tester(_ items: [DisplayItem]) -> HitTester {
        HitTester(displayList: DisplayList(canvas: "hit", items: items), viewport: Viewport(size: Size(width: 200, height: 150)), options: HitOptions(pickPoints: false))
    }

    func path(_ elements: [AppearanceItem], path: DisplayPath = square) -> DisplayItem {
        .path(PathItem(path: path, appearance: Appearance(elements)))
    }

    @Test func hiddenElementsAreSkippedWhenTheStackIsBuilt() {
        let fill = AppearanceItem.fill(FillPaint(paint: .solid(red)))
        let stroke = AppearanceItem.stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 4)))
        let appearance = Appearance(stack: [StackElement(fill), StackElement(stroke, hidden: true), StackElement(fill)])
        #expect(appearance.items == [fill, fill])
        #expect(StackElement(stroke).hidden == false)
    }

    @Test func paintKindsReportNoneAndLens() {
        #expect(Paint.gradient(Gradient(stops: [])).isNone, "a gradient without stops paints nothing")
        #expect(!Paint.gradient(Gradient(from: red, to: blue)).isNone)
        #expect(Paint.tiled(TiledFill(tile: [])).isNone, "an empty tile renders as None")
        #expect(!Paint.tiled(TiledFill(tile: AttributeCorpus.tile)).isNone)
        #expect(!Paint.lens(LensFill(type: .invert)).isNone && Paint.lens(LensFill(type: .invert)).isLens)
        #expect(!Paint.custom(CustomFill(pattern: .hatch)).isNone && !Paint.custom(CustomFill(pattern: .hatch)).isLens)
        #expect(!Paint.pattern(PatternPaint(bitmap: .checker, color: red)).isNone)
        #expect(!Paint.textured(TexturedFill(texture: .oak, color: red)).isNone)
        #expect(Paint.gradient(Gradient(from: red, to: blue)).color == nil)
        #expect(Appearance([.fill(FillPaint(paint: .lens(LensFill(type: .darken))))]).hasLens)
        #expect(!Appearance([.fill(FillPaint(paint: .solid(red)))]).hasLens)
    }

    @Test func theWidestStrokeIgnoresBrushAndCalligraphicStrokes() {
        let brush = StrokePaint(paint: .solid(red), style: StrokeStyle(width: 30), kind: .brush(BrushStroke(brush: Brush(symbols: [AttributeCorpus.brushSymbol]))))
        let nib = StrokePaint(paint: .solid(red), style: StrokeStyle(width: 40), kind: .calligraphic(CalligraphicNib(width: 5, height: 2)))
        let custom = StrokePaint(paint: .solid(red), style: StrokeStyle(width: 6), kind: .custom(CustomStroke(pattern: .dot)))
        let appearance = Appearance([.stroke(brush), .stroke(nib), .stroke(custom)])
        #expect(appearance.widestStroke?.style.width == 6)
        // A brush that is gone draws (and hits) as its cached Basic stroke.
        let gone = StrokePaint(paint: .solid(red), style: StrokeStyle(width: 9), kind: .brush(BrushStroke(brush: nil)))
        #expect(gone.hasWidthOutline && gone.effectiveKind == .basic)
        #expect(!StrokePaint(paint: .solid(red), style: StrokeStyle(width: 9), startArrowhead: .triangle, kind: .custom(CustomStroke(pattern: .dot))).hasArrowheads, "only Basic strokes carry heads")
    }

    @Test func outsetsOfTheStrokeKinds() {
        #expect(StrokePaint(paint: .solid(red), style: StrokeStyle(width: 4, miterLimit: 1), kind: .custom(CustomStroke(pattern: .dot))).outset == StrokeStyle(width: 4, miterLimit: 1).outset)
        let nib = StrokePaint(paint: .solid(red), kind: .calligraphic(CalligraphicNib(width: 10, height: 4)))
        #expect(approx(nib.outset, 5, tolerance: 0.2))
        #expect(StrokePaint(paint: .solid(red), kind: .brush(BrushStroke(brush: Brush(symbols: [AttributeCorpus.brushSymbol])))).outset == 0)
    }

    @Test func aNoneFilledPathHitsOnlyOnItsStroke() {
        let hits = tester([path([.fill(FillPaint(paint: .none)), .stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 4)))])])
        #expect(hits.hitTest(viewPoint: Point(x: 50, y: 40)).isEmpty, "the interior of a None fill does not hit")
        #expect(hits.hitTest(viewPoint: Point(x: 20, y: 40)).first?.kind == .stroke(PathLocation(contour: 0, segment: 3, t: 0.5)))
    }

    @Test func aHiddenStrokeDoesNotHit() {
        let hidden = Appearance(stack: [StackElement(.stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 12))), hidden: true)])
        let hits = tester([.path(PathItem(path: Self.square, appearance: hidden))])
        #expect(hits.hitTest(viewPoint: Point(x: 16, y: 40)).isEmpty, "5 pt off the path: only the hidden 12 pt stroke would reach")
    }

    @Test func lensAndTransparentCustomFillsHitAnywhereInside() {
        for paint in [Paint.lens(LensFill(type: .magnify)), .custom(CustomFill(pattern: .circles)), .gradient(Gradient(from: red, to: blue)), .tiled(TiledFill(tile: AttributeCorpus.tile))] {
            let hits = tester([path([.fill(FillPaint(paint: paint))])])
            #expect(hits.hitTest(viewPoint: Point(x: 50, y: 40)).first?.kind == .fill)
        }
        let empty = tester([path([.fill(FillPaint(paint: .tiled(TiledFill(tile: []))))])])
        #expect(empty.hitTest(viewPoint: Point(x: 50, y: 40)).isEmpty)
    }

    @Test func calligraphicAndBrushStrokesHitOnTheirOwnGeometry() {
        let line = DisplayPath(polygon: [Point(x: 20, y: 50), Point(x: 180, y: 50)], closed: false)
        let nib = tester([path([.stroke(StrokePaint(paint: .solid(.black), kind: .calligraphic(CalligraphicNib(width: 4, height: 30, angle: 0))))], path: line)])
        #expect(nib.hitTest(viewPoint: Point(x: 100, y: 62)).first?.kind == .stroke(nil), "inside the swept nib, 12 pt off the path")
        #expect(nib.hitTest(viewPoint: Point(x: 100, y: 70)).isEmpty)

        let brush = BrushStroke(brush: Brush(symbols: [BrushSymbol(items: [.path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: -8, width: 16, height: 16)), appearance: Appearance([.fill(FillPaint(paint: .solid(red)))])))])]), seed: 1)
        let copies = tester([path([.stroke(StrokePaint(paint: .solid(.black), kind: .brush(brush)))], path: line)])
        #expect(copies.hitTest(viewPoint: Point(x: 100, y: 56)).first?.kind == .stroke(nil), "inside a copy's frame")
        #expect(copies.hitTest(viewPoint: Point(x: 100, y: 70)).isEmpty)
        let none = tester([path([.stroke(StrokePaint(paint: .none, kind: .calligraphic(CalligraphicNib(width: 4, height: 30))))], path: line)])
        #expect(none.hitTest(viewPoint: Point(x: 100, y: 62)).isEmpty, "a None calligraphic stroke paints nothing")
    }

    @Test func customStrokesHitWithinTheirWidth() {
        let line = DisplayPath(polygon: [Point(x: 20, y: 50), Point(x: 180, y: 50)], closed: false)
        let hits = tester([path([.stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 20), kind: .custom(CustomStroke(pattern: .rectangle))))], path: line)])
        #expect(hits.hitTest(viewPoint: Point(x: 100, y: 58)).first.map { if case .stroke = $0.kind { return true } else { return false } } == true)
    }

    @Test func brushBoundsCoverTheCopies() {
        let line = DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 100, y: 0)], closed: false)
        let brush = BrushStroke(brush: Brush(symbols: [AttributeCorpus.brushSymbol], offset: .fixed(200)), widthPercent: 200)
        let item = DisplayItem.path(PathItem(path: line, appearance: Appearance([.stroke(StrokePaint(paint: .solid(.black), kind: .brush(brush)))])))
        let bounds = try! #require(item.bounds)
        #expect(bounds.maxY > 20, "copies sit 200% of the symbol's height off the path at 200% size")
    }

    @Test func transformedItemsCarryTheTransformThroughGroups() {
        let move = AffineTransform.translation(x: 10, y: 5)
        let items: [DisplayItem] = [
            .fill(FillItem(path: Self.square, paint: .solid(red))),
            .stroke(StrokeItem(path: Self.square, paint: .solid(red))),
            .image(ImageItem(assetID: "a", rect: Rect(x: 0, y: 0, width: 4, height: 4))),
            .text(TextRunItem(text: "t", origin: .zero, bounds: Rect(x: 0, y: 0, width: 4, height: 4))),
            .group(GroupItem(children: [.fill(FillItem(path: Self.square, paint: .solid(red)))], clip: Self.square)),
        ]
        for item in items {
            let moved = item.transformed(by: move)
            #expect(moved.transform == item.transform.concatenating(move))
            #expect(approx(moved.geometricBounds!, item.geometricBounds!.applying(move)))
        }
        guard case .group(let group) = items[4].transformed(by: move) else {
            Issue.record("a group stays a group")
            return
        }
        #expect(group.children[0].transform == move)
        let clippedAway = DisplayItem.group(GroupItem(children: [.fill(FillItem(path: Self.square, paint: .solid(red)))], clip: DisplayPath(rect: Rect(x: 500, y: 500, width: 1, height: 1))))
        #expect(clippedAway.geometricBounds == nil)
        #expect(DisplayItem.group(GroupItem(children: [])).geometricBounds == nil)
        #expect(DisplayItem.group(GroupItem(children: [.fill(FillItem(path: DisplayPath(), paint: .solid(red)))], clip: DisplayPath())).geometricBounds == nil)
    }

    @Test func theItemsBeforeAnIndexPathKeepTheirGroups() {
        let a = DisplayItem.fill(FillItem(path: Self.square, paint: .solid(red)))
        let b = DisplayItem.fill(FillItem(path: Self.square, paint: .solid(blue)))
        let group = DisplayItem.group(GroupItem(children: [a, b], opacity: 0.5))
        let list = DisplayList(canvas: "x", items: [a, group, b])
        #expect(list.items(before: [0]).isEmpty)
        #expect(list.items(before: [2]) == [a, group])
        #expect(list.items(before: [1, 1]) == [a, .group(GroupItem(children: [a], opacity: 0.5))])
        #expect(list.items(before: [1, 0]) == [a], "an enclosing group with nothing before the item is dropped")
        #expect(list.items(before: [7]) == list.items, "a position past the end keeps everything")
    }

    @Test func listsIndexTheirLenses() {
        let lens = DisplayItem.path(PathItem(path: Self.square, appearance: Appearance([.fill(FillPaint(paint: .lens(LensFill(type: .invert))))])))
        let plain = DisplayItem.fill(FillItem(path: Self.square, paint: .solid(red)))
        let list = DisplayList(canvas: "x", items: [plain, lens, .group(GroupItem(children: [plain, lens])), .fill(FillItem(path: Self.square, paint: .lens(LensFill(type: .darken)))), .image(ImageItem(assetID: "a", rect: Rect(x: 0, y: 0, width: 1, height: 1)))])
        #expect(list.lensIndices == [1, 2, 3])
    }

    @Test func stackOrderPaintsBottomFirstInBothRenderers() throws {
        // A fill above a wide stroke hides the stroke's inner half.
        let fillAbove = renderSurface([path([.stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 10))), .fill(FillPaint(paint: .solid(red)))])])
        let strokeAbove = renderSurface([path([.fill(FillPaint(paint: .solid(red))), .stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 10)))])])
        #expect(fillAbove.pixel(x: 22, y: 40) == RGBA8(red: 230, green: 26, blue: 26, alpha: 255))
        #expect(strokeAbove.pixel(x: 22, y: 40) == RGBA8(red: 0, green: 0, blue: 0, alpha: 255))
        #expect(fillAbove.pixel(x: 17, y: 40) == strokeAbove.pixel(x: 17, y: 40), "the outer half is stroke either way")
    }
}
