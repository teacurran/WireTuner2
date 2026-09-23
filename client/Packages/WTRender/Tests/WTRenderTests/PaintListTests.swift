import WTGeometry
import CoreGraphics
import Testing
@testable import WTRender
// GEO-003 added stroke types of the same names to WTGeometry; the display list's are WTRender's.
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// The CPU half of the Metal renderer: flattening and lowering, no GPU needed.
@Suite struct PathFlattenerTests {
    let flattener = PathFlattener(tolerance: .standard)

    @Test func subpathsFollowCoreGraphicsRules() {
        var path = DisplayPath()
        path.addLine(to: Point(x: 0, y: 0))  // no current point: acts as a move
        path.addLine(to: Point(x: 10, y: 0))
        path.addLine(to: Point(x: 10, y: 10))
        path.close()
        path.addLine(to: Point(x: 0, y: 20))  // after a close: starts again at (0, 0)
        path.addLine(to: Point(x: -10, y: 10))
        path.move(to: Point(x: 50, y: 50))  // a lone move encloses nothing
        let flat = flattener.flatten(path, transform: .identity)
        #expect(flat.contours.count == 2)
        #expect(flat.points[flat.contours[1]].first == SIMD2(0, 0))
        #expect(flat.fanTriangleCount == 2)
        #expect(flat.bounds == Rect(x: -10, y: 0, width: 20, height: 20))
        #expect(FlatPath().bounds == nil && FlatPath().isEmpty)
    }

    @Test func curvesWithoutACurrentPointStartASubpath() {
        var path = DisplayPath()
        path.addQuadCurve(control: Point(x: 5, y: 5), to: Point(x: 0, y: 0))
        path.addCubicCurve(control1: Point(x: 0, y: 40), control2: Point(x: 40, y: 40), to: Point(x: 40, y: 0))
        path.addQuadCurve(control: Point(x: 20, y: -20), to: Point(x: 0, y: 0))
        let cubicOnly = DisplayPath(elements: [.cubicCurve(control1: .zero, control2: Point(x: 1, y: 1), end: Point(x: 3, y: 3))])
        let flat = flattener.flatten(path, transform: .scale(2))
        #expect(flat.contours.count == 1)
        #expect(flat.points.count > 10, "curves flatten to many segments")
        #expect(flat.bounds.map { $0.maxX == 80 } == true, "flattened in device pixels")
        #expect(flattener.flatten(cubicOnly, transform: .identity).isEmpty)
    }

    @Test func segmentCountsFollowWangsFormulaAndClamp() {
        let flat = SIMD2<Double>(0, 0)
        #expect(flattener.segmentCount(flat, flat, flat) == 1)
        #expect(flattener.segmentCount(SIMD2(0, 0), SIMD2(50, 100), SIMD2(100, 0)) == 15)
        #expect(flattener.segmentCount(SIMD2(0, 0), SIMD2(0, 1e12), SIMD2(0, 0), SIMD2(1, 1)) == 4096)
        #expect(flattener.segmentCount(SIMD2(0, 0), SIMD2(.nan, 0), SIMD2(0, 0)) == 1)
    }

    @Test func clippingKeepsWindingInsideTheRect() {
        let flat = flattener.flatten(DisplayPath(rect: Rect(x: -100, y: -100, width: 300, height: 150)), transform: .identity)
        let clipped = flat.clipped(to: Rect(x: 0, y: 0, width: 100, height: 100))
        #expect(clipped.bounds == Rect(x: 0, y: 0, width: 100, height: 50))
        #expect(flat.clipped(to: Rect(x: 500, y: 500, width: 10, height: 10)).isEmpty)
    }

    @Test func coreGraphicsPathsConvertElementForElement() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 10, y: 0))
        path.addQuadCurve(to: CGPoint(x: 10, y: 10), control: CGPoint(x: 15, y: 5))
        path.addCurve(to: CGPoint(x: 0, y: 10), control1: CGPoint(x: 8, y: 12), control2: CGPoint(x: 2, y: 12))
        path.closeSubpath()
        let converted = DisplayPath(path)
        #expect(converted.elements == [
            .move(to: Point(x: 0, y: 0)),
            .line(to: Point(x: 10, y: 0)),
            .quadCurve(control: Point(x: 15, y: 5), end: Point(x: 10, y: 10)),
            .cubicCurve(control1: Point(x: 8, y: 12), control2: Point(x: 2, y: 12), end: Point(x: 0, y: 10)),
            .close,
        ])
        #expect(flattener.flatten(path, transform: .identity).contours.count == 1)
    }
}

@Suite struct PaintListBuilderTests {
    private func builder(_ mode: ViewMode = .preview, overprint: Bool = false, swaps: Bool = false) -> PaintListBuilder {
        PaintListBuilder(viewMode: mode, overprintPreview: overprint, tolerance: .standard, surface: Rect(x: 0, y: 0, width: 128, height: 96), swapsFillRules: swaps)
    }

    private func lower(_ items: [DisplayItem], _ builder: PaintListBuilder) -> [PaintOperation] {
        builder.operations(for: DisplayList(canvas: "lower", items: items), pasteboardTransform: .identity, cull: Rect(x: -1000, y: -1000, width: 3000, height: 3000))
    }

    private func fills(_ operations: [PaintOperation]) -> [PaintFill] {
        operations.flatMap { operation -> [PaintFill] in
            switch operation {
            case .fill(let fill): return [fill]
            case .group(let group): return fills(group.operations)
            }
        }
    }

    private let square = DisplayPath(rect: Rect(x: 10, y: 10, width: 40, height: 40))

    @Test func translucentGroupsLayerInPreviewAndFadeMembersInFastModes() throws {
        let group = DisplayItem.group(GroupItem(children: [.fill(FillItem(path: square, paint: .solid(.black)))], opacity: 0.5))
        let preview = lower([group], builder())
        guard case .group(let layer) = try #require(preview.first) else {
            Issue.record("expected a layer")
            return
        }
        #expect(layer.opacity == 0.5 && layer.clip == nil)
        #expect(fills(layer.operations).first?.color == SIMD4(0, 0, 0, 1), "full alpha inside the layer")

        let fast = lower([group], builder(.fastPreview))
        #expect(fills(fast).first?.color == SIMD4(0, 0, 0, 0.5), "members at the group's alpha, no layer")
        if case .group = try #require(fast.first) { Issue.record("fast modes draw no layer") }

        let keyline = fills(lower([group], builder(.keyline)))
        #expect(keyline.allSatisfy { $0.color.w == 1 }, "keyline ignores opacity")
    }

    @Test func clipsBecomeGroupsAndAnEmptyClipHidesEverything() throws {
        let clipped = DisplayItem.group(GroupItem(children: [.fill(FillItem(path: square, paint: .solid(.black)))], clip: DisplayPath(rect: Rect(x: 0, y: 0, width: 20, height: 20)), clipRule: .evenOdd))
        guard case .group(let group) = try #require(lower([clipped], builder()).first) else {
            Issue.record("expected a clip group")
            return
        }
        #expect(group.clipRule == .evenOdd && group.opacity == 1 && group.clip?.isEmpty == false)

        let hidden = DisplayItem.group(GroupItem(children: [.fill(FillItem(path: square, paint: .solid(.black)))], clip: DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 20, y: 20)])))
        guard case .group(let empty) = try #require(lower([hidden], builder()).first) else {
            Issue.record("expected a clip group")
            return
        }
        #expect(empty.clip?.isEmpty == true)
        var geometry = PaintGeometry()
        #expect(geometry.plan([.group(empty)], width: 128, height: 96).isEmpty, "an empty clip plans nothing")
        #expect(geometry.plan([.group(PaintGroup(operations: [], clip: nil, clipRule: .nonZero, opacity: 0.5))], width: 128, height: 96).isEmpty)
    }

    @Test func overprintMultipliesOnlyWithPreviewOn() {
        let item = DisplayItem.path(PathItem(path: square, appearance: Appearance([
            .fill(FillPaint(paint: .solid(.black), overprint: true)),
            .stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 2), overprint: true)),
        ])))
        #expect(fills(lower([item], builder(overprint: true))).map(\.blend) == [.multiply, .multiply])
        #expect(fills(lower([item], builder())).map(\.blend) == [.normal, .normal])
    }

    @Test func fillRulesSwapOnlyWhenAskedAndOnlyDeclaredOnes() {
        let items: [DisplayItem] = [
            .fill(FillItem(path: square, rule: .evenOdd, paint: .solid(.black))),
            .path(PathItem(path: DisplayPath(polygon: [Point(x: 5, y: 5), Point(x: 60, y: 5)], closed: false), appearance: Appearance([
                .stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 2), endArrowhead: .triangle)),
            ]))),
        ]
        #expect(fills(lower(items, builder())).map(\.rule) == [.evenOdd, .nonZero, .nonZero])
        #expect(fills(lower(items, builder(swaps: true))).map(\.rule) == [.nonZero, .nonZero, .nonZero], "stroke outlines and heads keep non-zero")
    }

    @Test func placeholdersFollowTheMode() {
        let items: [DisplayItem] = [
            .image(ImageItem(assetID: "a", rect: Rect(x: 0, y: 0, width: 30, height: 20))),
            .text(TextRunItem(text: "t", origin: Point(x: 40, y: 60), bounds: Rect(x: 40, y: 50, width: 30, height: 12))),
        ]
        #expect(fills(lower(items, builder())).count == 4, "grey block + diagonals, tint + baseline")
        #expect(fills(lower(items, builder(.fastPreview))).count == 2, "crossed box, greeked bar")
        #expect(fills(lower(items, builder(.keyline))).count == 2, "crossed box, bounds and baseline")
        #expect(fills(lower(items, builder(.fastKeyline))).count == 2)
    }

    @Test func noneAndOffSurfacePaintsLowerToNothing() {
        let items: [DisplayItem] = [
            .fill(FillItem(path: square, paint: .none)),
            .stroke(StrokeItem(path: square, paint: .none)),
            .fill(FillItem(path: DisplayPath(rect: Rect(x: 500, y: 500, width: 10, height: 10)), paint: .solid(.black))),
            .stroke(StrokeItem(path: square, style: StrokeStyle(width: 0), paint: .solid(.black))),
        ]
        let lowered = fills(lower(items, builder()))
        #expect(lowered.count == 1, "only the hairline paints")
        #expect(lower([.stroke(StrokeItem(path: square, paint: .solid(.black)))], builder(.keyline)).count == 1)
    }

    @Test func hairlinesAreOneDevicePixel() {
        #expect(PaintListBuilder.hairlineWidth(for: .scale(4)) == 0.25)
        #expect(PaintListBuilder.hairlineWidth(for: .scale(x: 0, y: 1)) == 1, "a degenerate transform falls back to one unit")
    }
}
