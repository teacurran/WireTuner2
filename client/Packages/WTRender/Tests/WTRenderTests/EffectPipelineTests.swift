import WTGeometry
import CoreGraphics
import Foundation
import Testing
@testable import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// FX-006 and FX-048: drawables and attachment, order, caching, invalidation, hit testing and
/// output of effected items; Combine groups.
@Suite struct EffectPipelineTests {
    typealias C = ReferenceCorpus
    static let square = DisplayPath(rect: Rect(x: 10, y: 10, width: 40, height: 40))
    static let fillStroke: [AppearanceItem] = [C.fill(C.orange), C.stroke(.black, width: 2)]

    static func render(_ items: [DisplayItem], size: Size = Size(width: 80, height: 80), renderer: CoreGraphicsRenderer = CoreGraphicsRenderer(background: .white)) -> BitmapSurface {
        let image = renderer.renderBitmap(DisplayList(canvas: "fx", items: items), viewport: Viewport(size: size))!
        return BitmapSurface(drawing: image)!
    }

    static func sameRender(_ lhs: [DisplayItem], _ rhs: [DisplayItem], size: Size = Size(width: 80, height: 80)) -> Bool {
        let a = render(lhs, size: size)
        let b = render(rhs, size: size)
        return PixelComparison(reference: a, candidate: b, edgeTolerance: 0).passes
    }

    static func item(_ path: DisplayPath, _ stack: [AppearanceItem], _ effects: [EffectElement], transform: AffineTransform = .identity) -> PathItem {
        PathItem(path: path, appearance: Appearance(stack, effects: effects), transform: transform)
    }

    static func item(_ stack: [AppearanceItem], _ effects: [EffectElement], transform: AffineTransform = .identity) -> PathItem {
        item(square, stack, effects, transform: transform)
    }

    static func item(_ effects: [EffectElement]) -> PathItem {
        item(square, fillStroke, effects)
    }

    // MARK: The stack

    @Test func stackEffectsFollowTheirElementsPastHiddenOnes() {
        let appearance = Appearance(stack: [
            StackElement(C.fill(C.orange), hidden: true),
            StackElement(C.stroke(.black, width: 2)),
        ], effects: [
            EffectElement(.bend(.init(size: 3)), target: .element(0)),
            EffectElement(.bend(.init(size: 4)), target: .element(1)),
            EffectElement(.bend(.init(size: 5)), hidden: true),
            EffectElement(.bend(.init(size: 6))),
        ])
        #expect(appearance.items.count == 1)
        #expect(appearance.effects == [EffectElement(.bend(.init(size: 4)), target: .element(0)), EffectElement(.bend(.init(size: 6)))])
        // Live effects skip unknown kinds and elements that do not exist.
        let dangling = Appearance([C.fill(C.orange)], effects: [EffectElement(.unsupported), EffectElement(.blur(.init(radius: 2)), target: .element(5)), EffectElement(.blur(.init(radius: 1)), hidden: true)])
        #expect(!dangling.hasEffects)
        #expect(!PathItem(path: Self.square, appearance: dangling).hasEffects)
    }

    @Test func hiddenUnknownAndDanglingEffectsDrawAsNoEffect() {
        let plain = PathItem(path: Self.square, appearance: Appearance(Self.fillStroke))
        let noisy = Self.item([
            EffectElement(.unsupported),
            EffectElement(.bend(.init(size: 9)), target: .element(7)),
            EffectElement(.combine(.init(operation: .intersect))),
            EffectElement(.blur(.init(radius: 0))),
            EffectElement(.sharpen(.init(amount: 0))),
            EffectElement(.shadow(.init(opacity: 0))),
            EffectElement(.bevelEmboss(.init(width: 0))),
            EffectElement(.transparency(.init(style: .feather, radius: 0))),
            EffectElement(.transparency(.init(style: .basic, amount: 0))),
        ])
        #expect(noisy.hasEffects)
        #expect(Self.sameRender([.path(plain)], [.path(noisy)]))
    }

    @Test func attachedEffectsApplyToTheirElementOnly() {
        // A Transform on the stroke moves it; the fill stays.
        let moved = Self.item([EffectElement(.transform(.init(move: Point(x: 10, y: 0))), target: .element(1))])
        let nodes = EffectPipeline.nodes(for: moved)
        #expect(nodes.count == 2)
        guard case .item(.path(let fill)) = nodes[0], case .item(.path(let stroke)) = nodes[1] else {
            Issue.record("expected two plain drawables")
            return
        }
        #expect(fill.path.controlBounds == Self.square.controlBounds)
        #expect(approx(stroke.path.controlBounds!, Rect(x: 20, y: 10, width: 40, height: 40), tolerance: 1e-9))
    }

    @Test func effectsApplyInPositionOrder() {
        let reference = EffectPipeline.ownBounds(Self.square)
        let bend = EffectElement(.bend(.init(size: 6)))
        let move = EffectElement(.transform(.init(scaleX: 50, scaleY: 50, center: Point(x: 20, y: 0))))
        let first = EffectPipeline.nodes(for: Self.item([C.fill(C.orange)], [bend, move]))
        let second = EffectPipeline.nodes(for: Self.item([C.fill(C.orange)], [move, bend]))
        #expect(first != second)
        #expect(reference == Rect(x: 10, y: 10, width: 40, height: 40))
    }

    @Test func chainsSplitAtRasterStages() {
        let reference = Rect(x: 0, y: 0, width: 10, height: 10)
        func framed(_ effect: LiveEffect) -> FramedEffect { FramedEffect(effect: effect, toEffectSpace: .identity, reference: reference) }
        let chain = EffectPipeline.Chain([
            framed(.transform(.init(rotate: 5))),
            framed(.blur(.init(radius: 2))),
            framed(.ragged(.init(size: 1, frequency: 10))),
            framed(.duet(.init())),
            framed(.combine(.init())),
            framed(.transparency(.init(amount: 30))),
        ])
        #expect(chain.vector.map(\.effect) == [.transform(.init(rotate: 5)), .ragged(.init(size: 1, frequency: 10))])
        #expect(chain.stages == [.blur(.init(radius: 2)), .transparency(.init(amount: 30))])
        #expect(chain.copies.map(\.effect) == [.duet(.init())])
    }

    @Test func affineEffectsAfterARasterStageCopyTheResult() {
        let shadowed = Self.item([C.fill(C.orange)], [
            EffectElement(.shadow(.init(offset: 3, opacity: 50, softness: 2))),
            EffectElement(.transform(.init(move: Point(x: 20, y: 0), copies: 2))),
        ], transform: .translation(x: 5, y: 0))
        let nodes = EffectPipeline.nodes(for: shadowed)
        #expect(nodes.count == 2)
        guard case .raster(let a) = nodes[0], case .raster(let b) = nodes[1] else {
            Issue.record("expected two raster copies")
            return
        }
        let shift = EffectNode.union(b.content)!.minX - EffectNode.union(a.content)!.minX
        #expect(approx(shift, 20, tolerance: 1e-9))
        // Placement through a transform that cannot be inverted keeps the local placements.
        let collapsed = FramedEffect(effect: .transform(.init(move: Point(x: 1, y: 0))), toEffectSpace: .scale(0), reference: .zero)
        #expect(EffectPipeline.placements(collapsed, transform: .identity).count == 1)
        #expect(EffectPipeline.placements(FramedEffect(effect: .bend(.init()), toEffectSpace: .identity, reference: .zero), transform: .identity) == [.identity])
    }

    @Test func rasterStagesMergeIntoOneNode() {
        let nodes = EffectPipeline.nodes(for: Self.item([C.fill(C.orange)], [
            EffectElement(.blur(.init(radius: 2))),
            EffectElement(.shadow(.init(offset: 2, opacity: 50))),
            EffectElement(.sharpen(.init(amount: 50))),
            EffectElement(.bevelEmboss(.init(width: 2))),
        ]))
        guard nodes.count == 1, case .raster(let raster) = nodes[0] else {
            Issue.record("expected one raster node")
            return
        }
        #expect(raster.operations.count == 4)
        // A different raster setting starts a new node.
        let split = EffectPipeline.rasterStage(.blur(.init(radius: 1)), content: nodes, settings: RasterSettings(resolution: 300))
        guard case .raster(let outer) = split[0] else { return }
        #expect(outer.content == nodes)
    }

    // MARK: Caching and invalidation

    @Test func chainsAreResolvedOncePerValue() {
        let item = Self.item([EffectElement(.ragged(.init(size: 2, frequency: 17, seed: 123_456)))])
        #expect(!EffectPipeline.isResolved(item))
        let nodes = EffectPipeline.nodes(for: item)
        #expect(EffectPipeline.isResolved(item))
        #expect(EffectPipeline.nodes(for: item) == nodes)
    }

    @Test func aRemoteEditToOneEffectRepaintsOnlyThatObject() {
        func list(size: Double) -> DisplayList {
            var builder = DisplayListBuilder(canvas: "fx")
            for index in 0..<40 {
                let rect = Rect(x: Double(index % 8) * 60, y: Double(index / 8) * 60, width: 30, height: 30)
                let bend = index == 17 ? size : 4
                builder.add(.path(Self.item(DisplayPath(rect: rect), Self.fillStroke, [EffectElement(.bend(.init(size: bend + 0.123_456)))])), node: NodeID(counter: UInt64(index + 1), replica: 1))
            }
            return builder.build()
        }
        let before = list(size: 4)
        // Only the edited object's chain is new; every other one is served from the cache.
        let pending = list(size: 12).items.enumerated().filter { index, item in
            guard case .path(let path) = item else { return false }
            return index != 17 && !EffectPipeline.isResolved(path)
        }
        #expect(pending.isEmpty)
        let after = list(size: 12)
        var summary = ChangeSummary(origin: .remote)
        summary.touch(NodeID(counter: 18, replica: 1), fields: [FieldPath(fields: 7)])
        let region = InvalidationMapper().dirtyRegion(for: summary, before: [before], after: [after])
        let rects = region.rects(for: "fx")
        #expect(rects.count == 1)
        let edited = after.bounds(of: NodeID(counter: 18, replica: 1))!.union(before.bounds(of: NodeID(counter: 18, replica: 1))!)
        #expect(rects.allSatisfy { edited.contains($0) })
        // The effected bounds are larger than the object's own.
        #expect(!Rect(x: 60, y: 120, width: 30, height: 30).contains(after.itemBounds[17]!))
    }

    @Test func effectedBoundsFeedTheSpatialIndex() {
        let expanded = Self.item([C.fill(C.cyan)], [EffectElement(.expandPath(.init(direction: .outside, width: 20)))])
        let item = DisplayItem.path(expanded)
        #expect(item.bounds!.contains(Rect(x: -9, y: -9, width: 78, height: 78)))
        #expect(item.ownBounds == Rect(x: 10, y: 10, width: 40, height: 40))
        #expect(item.effectBounds == item.bounds)
        #expect(DisplayItem.path(PathItem(path: Self.square, appearance: Appearance(Self.fillStroke))).effectBounds == nil)
        #expect(DisplayItem.group(GroupItem(children: [item])).effectBounds == nil)
    }

    // MARK: Hit testing

    @Test func hitsInsideAnExpandBandSelectThePathAndPointsUseTheRawPath() {
        var line = DisplayPath()
        line.move(to: Point(x: 10, y: 40))
        line.addLine(to: Point(x: 70, y: 40))
        let band = PathItem(path: line, appearance: Appearance([C.fill(C.cyan)], effects: [EffectElement(.expandPath(.init(width: 20)))]))
        let list = DisplayList(canvas: "fx", items: [.path(band)])
        let tester = HitTester(displayList: list, viewport: Viewport(size: Size(width: 80, height: 80)))
        // 8 pt off the line, inside the band: a fill hit on the path.
        let inBand = tester.hitTest(viewPoint: Point(x: 40, y: 48))
        #expect(inBand.first?.itemPath == [0])
        #expect(inBand.first?.kind == .fill)
        // On the raw path's end point: a point hit.
        #expect(tester.hitTest(viewPoint: Point(x: 70, y: 40)).first?.kind == .point(element: 1))
        // Near the raw line, a segment hit.
        #expect(tester.hitTest(viewPoint: Point(x: 40, y: 41)).first.map { if case .segment = $0.kind { return true } else { return false } } == true)
        // Outside the band: nothing.
        #expect(tester.hitTest(viewPoint: Point(x: 40, y: 60)).isEmpty)
    }

    @Test func strokesHitOnTheirEffectedOutline() {
        let moved = Self.item([C.stroke(.black, width: 4)], [EffectElement(.transform(.init(move: Point(x: 20, y: 0))))])
        let tester = HitTester(displayList: DisplayList(canvas: "fx", items: [.path(moved)]), viewport: Viewport(size: Size(width: 100, height: 80)), options: HitOptions(pickPoints: false))
        #expect(tester.hitTest(viewPoint: Point(x: 70, y: 30)).first?.kind == .stroke(nil))
        // A fully transparent object is still selectable by its outline.
        let invisible = Self.item([C.fill(C.orange)], [EffectElement(.transparency(.init(amount: 100)))])
        let clear = HitTester(displayList: DisplayList(canvas: "fx", items: [.path(invisible)]), viewport: Viewport(size: Size(width: 80, height: 80)))
        #expect(clear.hitTest(viewPoint: Point(x: 30, y: 30)).first?.kind == .fill)
    }

    // MARK: Output

    @Test func pdfOutputReceivesTheEffectedGeometry() throws {
        let expanded = Self.item([C.fill(C.cyan)], [EffectElement(.expandPath(.init(direction: .outside, width: 8)))])
        let list = DisplayList(canvas: "fx", items: [.path(expanded)])
        let viewport = Viewport(size: Size(width: 80, height: 80))
        let pdf = try #require(CoreGraphicsRenderer(background: .white).renderPDF(list, viewport: viewport))
        let raster = try #require(PDFRasterizer.rasterize(pdf, scale: 1))
        // Inside the band, outside the raw square: painted; inside the square: the band's hole.
        #expect(raster.pixel(x: 6, y: 30) != RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
        #expect(raster.pixel(x: 30, y: 30) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
    }

    @Test func keylineDrawsTheObjectsOwnOutline() {
        let keyline = CoreGraphicsRenderer(background: .white, viewMode: .keyline)
        let effected = Self.item([EffectElement(.bend(.init(size: 10))), EffectElement(.shadow(.init(offset: 4, opacity: 80)))])
        let plain = PathItem(path: Self.square, appearance: Appearance(Self.fillStroke))
        let a = Self.render([.path(effected)], renderer: keyline)
        let b = Self.render([.path(plain)], renderer: keyline)
        #expect(PixelComparison(reference: a, candidate: b, edgeTolerance: 0).passes)
    }

    // MARK: Groups

    @Test func groupEffectsApplyToTheWholeGroup() {
        let members: [DisplayItem] = [
            C.path(DisplayPath(rect: Rect(x: 10, y: 10, width: 20, height: 20)), [C.fill(C.orange)]),
            .fill(FillItem(path: DisplayPath(rect: Rect(x: 34, y: 10, width: 20, height: 20)), paint: .solid(C.cyan))),
            .stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 10, y: 34, width: 20, height: 20)), style: StrokeStyle(width: 2), paint: .solid(.black))),
            .text(TextRunItem(text: "x", origin: Point(x: 40, y: 50), bounds: Rect(x: 34, y: 40, width: 10, height: 10))),
            .image(ImageItem(assetID: "i", rect: Rect(x: 50, y: 40, width: 10, height: 10))),
            .group(GroupItem(children: [C.path(DisplayPath(rect: Rect(x: 60, y: 60, width: 10, height: 10)), [C.fill(.black)])])),
        ]
        let bent = GroupItem(children: members, appearance: Appearance(effects: [
            EffectElement(.bend(.init(size: 5))),
            EffectElement(.transparency(.init(amount: 50))),
            EffectElement(.transform(.init(move: Point(x: 2, y: 0)))),
        ]))
        let derived = EffectPipeline.derived(bent)
        #expect(derived.entries.count == members.count)
        #expect(derived.entries.map(\.origin) == Array(0..<members.count))
        guard case .layer(let opacity, let content) = derived.nodes[0] else {
            Issue.record("expected the group's transparency layer")
            return
        }
        #expect(opacity == 0.5)
        #expect(content.count == members.count)
        #expect(derived.keylineItems == members)
        // Glyph runs become paths that inherit the effect.
        let glyphs = DisplayItem.text(TextRunItem(text: "a", glyphRun: GlyphRun(font: GlyphFont(postScriptName: "Helvetica", size: 20), glyphs: []), origin: .zero)).inheriting([])
        if case .path = glyphs {} else { Issue.record("glyph runs inherit as paths") }
    }

    @Test func combineRendersLikeTheBooleanResult() {
        let a = DisplayPath(ellipseIn: Rect(x: 8, y: 8, width: 40, height: 40))
        let b = DisplayPath(rect: Rect(x: 28, y: 20, width: 40, height: 30))
        for (operation, boolean) in [(LiveEffect.Combine.Operation.union, BooleanOperation.union), (.subtract, .subtraction), (.intersect, .intersection), (.exclude, .exclusiveOr)] {
            let group = DisplayItem.group(GroupItem(children: [C.path(a, [C.fill(.white)]), C.path(b, [C.fill(.white)])], appearance: Appearance([C.fill(C.cyan), C.stroke(.black, width: 1.5)], effects: [EffectElement(.combine(.init(operation: operation)))])))
            let result = Boolean.normalize(Boolean.perform(boolean, FilledPath(contours: a.contours), FilledPath(contours: b.contours)))
            let expected = DisplayItem.path(PathItem(path: DisplayPath(contours: result.contours), appearance: Appearance([C.fill(C.cyan), C.stroke(.black, width: 1.5)])))
            #expect(Self.sameRender([group], [expected]), "\(operation)")
        }
    }

    @Test func nestedCombinesAndTextTakePartAsOneShapeAndOpenPathsDoNot() {
        let inner = DisplayItem.group(GroupItem(children: [
            C.path(DisplayPath(rect: Rect(x: 0, y: 0, width: 20, height: 20)), [C.fill(.white)]),
            C.path(DisplayPath(rect: Rect(x: 10, y: 10, width: 20, height: 20)), [C.fill(.white)]),
        ], appearance: Appearance(effects: [EffectElement(.combine(.init(operation: .intersect)))])))
        let open = C.path(C.line(0, 40, 40, 40), [C.stroke(.black, width: 2)])
        let text = DisplayItem.text(TextRunItem(text: "t", origin: Point(x: 40, y: 50), bounds: Rect(x: 40, y: 40, width: 10, height: 10)))
        let plainGroup = DisplayItem.group(GroupItem(children: [C.path(DisplayPath(rect: Rect(x: 60, y: 0, width: 5, height: 5)), [C.fill(.white)]), C.path(DisplayPath(rect: Rect(x: 64, y: 0, width: 5, height: 5)), [C.fill(.white)])]))
        let outer = GroupItem(children: [inner, open, text, plainGroup, .image(ImageItem(assetID: "i", rect: Rect(x: 80, y: 0, width: 4, height: 4))), .fill(FillItem(path: DisplayPath(rect: Rect(x: 90, y: 0, width: 4, height: 4)), paint: .solid(.black))), .stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 100, y: 0, width: 4, height: 4)), paint: .solid(.black)))], appearance: Appearance([C.fill(C.cyan)], effects: [EffectElement(.combine(.init(operation: .union)))]))
        let derived = EffectPipeline.derived(outer)
        guard case .path(let outline) = derived.entries[0].item else {
            Issue.record("expected the combined outline")
            return
        }
        let region = FilledPath(contours: outline.path.contours)
        // The nested intersection, not either square whole.
        #expect(region.contains(Point(x: 15, y: 15)))
        #expect(!region.contains(Point(x: 5, y: 5)))
        // The open path contributes nothing; the text's bounds do.
        #expect(!region.contains(Point(x: 20, y: 40)))
        #expect(region.contains(Point(x: 45, y: 45)))
        #expect(region.contains(Point(x: 66, y: 2)))
        #expect(derived.entries.dropFirst().allSatisfy { !$0.visible })
        #expect(CombineResolver.outline(of: .group(GroupItem(children: [open]))).isEmpty)
    }

    @Test func combineHitsAsTheGroupAndSubselectReachesMembers() {
        let group = DisplayItem.group(GroupItem(children: [
            C.path(DisplayPath(rect: Rect(x: 10, y: 10, width: 30, height: 30)), [C.fill(.white)]),
            C.path(DisplayPath(rect: Rect(x: 30, y: 10, width: 30, height: 30)), [C.fill(.white)]),
        ], appearance: Appearance([C.fill(C.cyan)], effects: [EffectElement(.combine(.init(operation: .union)))])))
        let list = DisplayList(canvas: "fx", items: [group])
        let viewport = Viewport(size: Size(width: 80, height: 80))
        let plain = HitTester(displayList: list, viewport: viewport, options: HitOptions(pickPoints: false))
        let hit = plain.hitTest(viewPoint: Point(x: 35, y: 25))
        #expect(hit.first?.itemPath == [0] && hit.first?.leafPath == [0])
        let sub = HitTester(displayList: list, viewport: viewport, options: HitOptions(subselect: true, pickPoints: false))
        #expect(sub.hitTest(viewPoint: Point(x: 50, y: 25)).first?.leafPath == [0, 1])
    }

    @Test func draggingOneMemberRecomputesOnlyThatGroup() {
        func group(offset: Double, id: Int) -> GroupItem {
            GroupItem(children: (0..<50).map { index in
                C.path(DisplayPath(rect: Rect(x: Double(index) * 3 + (index == 7 ? offset : 0), y: Double(id) * 50, width: 5, height: 5)), [C.fill(.white)])
            }, appearance: Appearance([C.fill(C.cyan)], effects: [EffectElement(.combine(.init(operation: .union)))]))
        }
        let other = group(offset: 0.25, id: 2)
        _ = EffectPipeline.derived(other)
        let dragged = group(offset: 1.5, id: 1)
        #expect(!EffectPipeline.isResolved(dragged))
        let list = DisplayList(canvas: "fx", items: [.group(dragged), .group(other)])
        #expect(EffectPipeline.isResolved(dragged) && EffectPipeline.isResolved(other))
        // The members themselves carry no effects: nothing but the group's boolean is computed.
        #expect(dragged.children.allSatisfy { if case .path(let path) = $0 { return !path.hasEffects } else { return false } })
        #expect(list.itemBounds[0]!.maxY < list.itemBounds[1]!.minY)
    }

    @Test func performanceOfFiveThousandEffectedObjectsAfterWarmUp() {
        var builder = DisplayListBuilder(canvas: "perf")
        for index in 0..<5000 {
            let rect = Rect(x: Double(index % 71) * 14, y: Double(index / 71) * 14, width: 10, height: 10)
            builder.add(.path(Self.item(DisplayPath(rect: rect), [C.fill(C.orange)], [EffectElement(.bend(.init(size: 2))), EffectElement(.corners(.init(radius: 2)))])))
        }
        let list = builder.build()
        let geometry = TileGeometry(zoomStep: ZoomStep(nearest: 1), rotationDegrees: 0)
        let key = geometry.tiles(coveringPasteboardRect: Rect(x: 0, y: 0, width: 200, height: 200), canvas: "perf")[0]
        let renderer = CoreGraphicsRenderer(background: .white)
        _ = renderer.renderTile(list, key: key, geometry: geometry)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = renderer.renderTile(list, key: key, geometry: geometry) }
        print("5,000 effected objects: warm tile in \(elapsed) (\(PerfBudget.buildName))")
        PerfBudget.expect(elapsed, within: .milliseconds(8))
    }
}
