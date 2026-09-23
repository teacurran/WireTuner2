import WTGeometry
import Foundation
import Testing
@testable import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// The read-time normalizations of the FX settings (out-of-range and non-finite values render
/// clamped, as the effects pages' "Read-time normalizations" say) and the kernels' tolerance of
/// malformed input.
@Suite struct EffectNormalizationTests {
    typealias C = ReferenceCorpus
    static let square = EffectShape(contours: DisplayPath(rect: Rect(x: 0, y: 0, width: 20, height: 20)).contours)

    @Test func settingsClampToTheirDocumentedRanges() {
        #expect(LiveEffect.ExpandPath(width: .nan).effectiveWidth == 0)
        #expect(LiveEffect.Ragged(size: .nan, frequency: .infinity).effectiveSize == 0)
        #expect(LiveEffect.Ragged(frequency: .nan).effectiveFrequency == 0)
        #expect(LiveEffect.Ragged(size: -3).effectiveSize == 0)
        #expect(LiveEffect.Sketch(amount: .nan).effectiveAmount == 0)
        #expect(LiveEffect.BevelEmboss(width: .nan, contrast: .nan, softness: .nan).effectiveWidth == 0)
        #expect(LiveEffect.BevelEmboss(contrast: .nan).effectiveContrast == 0)
        #expect(LiveEffect.BevelEmboss(softness: 99).effectiveSoftness == 10)
        #expect(LiveEffect.BevelEmboss(softness: .nan).effectiveSoftness == 0)
        #expect(LiveEffect.BevelEmboss(width: 5000, contrast: 400).effectiveWidth == 1000)
        #expect(LiveEffect.BevelEmboss(contrast: 400).effectiveContrast == 100)
        #expect(LiveEffect.Blur(radius: .nan).effectiveRadius == 0)
        #expect(LiveEffect.Blur(radius: 900).effectiveRadius == 250)
        #expect(LiveEffect.Shadow(offset: .nan).effectiveOffset == 0)
        #expect(LiveEffect.Shadow(opacity: .nan).effectiveOpacity == 0)
        #expect(LiveEffect.Shadow(softness: .nan).effectiveSoftness == 0)
        #expect(LiveEffect.Shadow(offset: 1e6, opacity: 300, softness: 99).effectiveOffset == 1000)
        #expect(LiveEffect.Shadow(opacity: 300).effectiveOpacity == 100)
        #expect(LiveEffect.Shadow(softness: 99).effectiveSoftness == 30)
        #expect(LiveEffect.Sharpen(amount: .nan).effectiveAmount == 0)
        #expect(LiveEffect.Sharpen(amount: 9000).effectiveAmount == 500)
        #expect(LiveEffect.Sharpen(pixelRadius: .nan).effectivePixelRadius == 1)
        #expect(LiveEffect.Sharpen(pixelRadius: 0.01).effectivePixelRadius == 0.1)
        #expect(LiveEffect.Sharpen(threshold: .nan).effectiveThreshold == 0)
        #expect(LiveEffect.Sharpen(threshold: 999).effectiveThreshold == 255)
        #expect(LiveEffect.Transparency(amount: .nan).effectiveAmount == 0)
        #expect(LiveEffect.Transparency(amount: 150).effectiveAmount == 100)
        #expect(LiveEffect.Transparency(radius: .nan).effectiveRadius == 0)
        #expect(LiveEffect.Transparency(radius: 1e9).effectiveRadius == 1000)
        #expect(LiveEffect.Transparency(softness: .nan).effectiveSoftness == 0)
        #expect(LiveEffect.Transparency(softness: 400).effectiveSoftness == 100)
        #expect(ExtrudeSpec(length: .nan).effectiveLength == 0)
        #expect(ExtrudeSpec(profile: .init(steps: 500)).effectiveProfileSteps == 100)
        #expect(LiveEffect.bend(.init()).isVector && !LiveEffect.blur(.init()).isVector && !LiveEffect.unsupported.isVector)
    }

    @Test func kernelsTolerateNonFiniteSettings() {
        let reference = Rect(x: 0, y: 0, width: 20, height: 20)
        #expect(BendKernel.apply(.init(size: .nan), to: [Self.square], reference: reference) == [Self.square])
        #expect(CornersKernel.apply(.init(radius: .nan), to: [Self.square]) == [Self.square])
        #expect(DuetKernel.reflection(center: .zero, degrees: .nan) == DuetKernel.reflection(center: .zero, degrees: 0))
        let nan = LiveEffect.Transform(scaleX: .nan, scaleY: .nan, skewH: .nan, skewV: .nan, rotate: .nan, move: Point(x: .nan, y: .nan), center: Point(x: .nan, y: .nan))
        #expect(TransformKernel.matrix(nan, reference: reference).isIdentity)
        // A null reference measures from the origin.
        #expect(effectCenter(.null, offset: Point(x: 3, y: .nan)) == Point(x: 3, y: 0))
        // Shadows at a non-finite angle fall along 0°.
        let shadow = EffectPipelineTests.render([.path(PathItem(path: DisplayPath(rect: Rect(x: 20, y: 20, width: 20, height: 20)), appearance: Appearance([C.fill(.black)], effects: [EffectElement(.shadow(.init(offset: 8, opacity: 100, angle: .nan)))])))])
        #expect(shadow.pixel(x: 45, y: 30).red < 128)
        // A non-finite rotation or profile angle reads as zero.
        let spec = ExtrudeSpec(length: 10, vanishingPoint: Point(x: 100, y: 0), rotationX: .nan, rotationY: .nan, rotationZ: .nan)
        let solver = ExtrudeSolver(spec: spec, bounds: .null)
        #expect(solver.center == .zero)
        #expect(ProfileSweep.directions([.zero, Point(x: 1, y: 0), Point(x: 1, y: 1)], kind: .staticAngle, angle: .nan, orientation: 1)[0] == Vector(1, -0.0))
        #expect(Point3(x: 0, y: 0, z: 0).normalized == Point3(x: 0, y: 0, z: 0))
        // A blend range that is not a number reads as the full range.
        let blend = BlendResolver.entries(BlendSpec(steps: 1, rangeFirst: .nan, rangeLast: .nan), children: [LiveGroupTests.circle, LiveGroupTests.box])
        #expect(blend.count == 3)
        // A perspective position that is not a number reads as the grid's origin.
        let placement = PerspectivePlacement(PerspectiveSpec(grid: LiveGroupTests.grid, cellPosition: Point(x: .nan, y: 0)), flat: Rect(x: 0, y: 0, width: 36, height: 0))!
        #expect(placement.cells.minX == 0)
        #expect(placement.cell(of: Point(x: 10, y: 10)).y == 0)
        #expect(PerspectivePlacement(PerspectiveSpec(grid: LiveGroupTests.grid), flat: Rect(x: 0, y: 0, width: 0, height: 0)) == nil)
        // The inverse of a collapsed placement maps nothing onto the flat rectangle.
        let flat = PerspectivePlacement(PerspectiveSpec(grid: LiveGroupTests.grid, cellPosition: .zero, cellWidth: 1, cellHeight: 1, flipped: true), flat: Rect(x: 0, y: 0, width: 36, height: 36))!
        #expect(flat.inverse(flat.map(Point(x: 5, y: 7))).map { approx($0, Point(x: 5, y: 7), tolerance: 1e-6) } == true)
        // Points on the horizon line keep a finite weight.
        #expect(Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1e-20]).apply(Point(x: 1, y: 1)).isFinite)
        #expect(Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, -1e-20]).apply(Point(x: 1, y: 1)).x < 0)
        #expect(PerspectiveResolver.entries(PerspectiveSpec(grid: LiveGroupTests.grid), children: [.image(ImageItem(assetID: "i", rect: .null))]).map(\.origin) == [0])
    }

    @Test func nodesExposeTheirPlainItemsAndPlacements() {
        let plain = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 4, height: 4)), appearance: Appearance([C.fill(.black)])))
        let masked = EffectNode.masked(MaskNode(gradient: Gradient(.linear, from: .black, to: .white), frame: .identity, region: DisplayPath(), rule: .nonZero, content: [.item(plain)]))
        let raster = EffectNode.raster(RasterNode(operations: [.blur(.init(radius: 1))], content: [.item(plain)], settings: RasterSettings()))
        #expect(masked.plainItems == [plain] && raster.plainItems == [plain])
        #expect(EffectNode.layer(opacity: 0.5, content: [masked]).transformed(by: .translation(x: 1, y: 0)).plainItems[0].bounds == Rect(x: 1, y: 0, width: 4, height: 4))
        // A Duet below a raster stage copies the rasterized result.
        let item = PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 4, height: 4)), appearance: Appearance([C.fill(.black)], effects: [EffectElement(.blur(.init(radius: 1))), EffectElement(.duet(.init(mode: .reflect, center: Point(x: 4, y: 0), axisAngle: 90)))]))
        #expect(EffectPipeline.nodes(for: item).count == 2)
        // A kernel that is not vector passes shapes through; an empty shape draws nothing.
        #expect(EffectPipeline.kernel(.blur(.init()), shapes: [Self.square], reference: .zero) == [Self.square])
        let vanished = PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 4, height: 4)), appearance: Appearance([C.fill(.black)], effects: [EffectElement(.expandPath(.init(width: 0)))]))
        #expect(EffectPipeline.nodes(for: vanished).isEmpty)
        // Inherited effects whose frame cannot be inverted apply in local space.
        let collapsed = FramedEffect(effect: .bend(.init(size: 2)), toEffectSpace: .scale(0), reference: Rect(x: 0, y: 0, width: 20, height: 20))
        #expect(EffectPipeline.applyVector([collapsed], to: [Self.square]).count == 1)
        // A group whose effects remove a Combine among others keeps the rest.
        let combined = GroupItem(children: [plain], appearance: Appearance([C.fill(C.cyan)], effects: [EffectElement(.bend(.init(size: 1))), EffectElement(.combine(.init())), EffectElement(.combine(.init(operation: .exclude)))]))
        guard case .path(let outline) = EffectPipeline.derived(combined).entries[0].item else { return }
        #expect(outline.appearance.effects.count == 1)
        // An empty group has no reference bounds and draws nothing.
        #expect(EffectPipeline.derived(GroupItem(children: [], appearance: Appearance(effects: [EffectElement(.shadow(.init(opacity: 50)))]))).nodes.isEmpty)
        #expect(DisplayItem.group(GroupItem(children: [plain], appearance: Appearance(effects: [EffectElement(.bend(.init(size: 1)))]))).effectBounds != nil)
    }

    @Test func gradientMaskEdgeCases() {
        // No mask at all: opaque.
        let none = EffectPipeline.transparencyStage(.init(style: .gradientMask), content: [.item(.image(ImageItem(assetID: "i", rect: Rect(x: 0, y: 0, width: 2, height: 2))))], settings: RasterSettings(), frame: .identity, region: DisplayPath(), rule: .nonZero)
        #expect(none.count == 1)
        if case .layer = none[0] { Issue.record("no stops reads opaque") }
    }

    @Test func warpHelpers() {
        // The error of an approximation that has nothing to compare is zero at every sample.
        let line = Line(start: .zero, end: Point(x: 10, y: 0)).elevated()
        #expect(CurveWarp.error(of: line, against: line) { $0 } == 0)
        // Baking scales strokes, leaves fills alone.
        let baked = WarpSource.baked(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), appearance: Appearance([C.fill(.black), C.stroke(.black, width: 1)]), transform: .scale(3)))
        #expect(baked.appearance.fills.count == 1 && baked.appearance.strokes[0].style.width == 3)
        let two = [PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), appearance: Appearance()), PathItem(path: DisplayPath(rect: Rect(x: 2, y: 0, width: 1, height: 1)), appearance: Appearance())]
        if case .group(let group)? = WarpSource.mapped(two, map: { $0 }) {
            #expect(group.children.count == 2)
        } else {
            Issue.record("several paths map as a group")
        }
        // Extrusion wireframes skip zero-length edges.
        let faces = [ExtrudeFace(kind: .side, polygon: [.zero, .zero, Point(x: 1, y: 0), Point(x: 1, y: 0)], normal: Point3(x: 0, y: 0, z: -1), depth: 0, facesViewer: true)]
        #expect(ExtrudeResolver.edges(faces, rings: false).elements.count == 2)
        // A clockwise outline offsets outward too.
        let outward = ProfileSweep.directions([.zero, Point(x: 0, y: 10), Point(x: 10, y: 10), Point(x: 10, y: 0)], kind: .bevel, angle: 0, orientation: -1)
        #expect(outward[0].dx < 0 && outward[0].dy < 0)
        // Collinear neighbours: the bisector is the edge normal.
        #expect(ProfileSweep.directions([.zero, Point(x: 5, y: 0), Point(x: 10, y: 0)], kind: .bevel, angle: 0, orientation: 1)[1] == Vector(0, -1))
        // An extruded open path has nothing to extrude.
        let open = ExtrudeResolver.entries(ExtrudeSpec(length: 10, vanishingPoint: Point(x: 100, y: 0)), children: [C.path(C.line(0, 0, 10, 10), [C.stroke(.black, width: 1)])])
        #expect(open.contains { $0.origin == 0 })
    }

    @Test func moreBlendAndWrapperPaths() {
        // A group key object blends sub-path by sub-path; a blend point on another contour of a
        // composite path leaves the rest alone.
        let pair = DisplayItem.group(GroupItem(children: [C.path(DisplayPath(rect: Rect(x: 0, y: 0, width: 5, height: 5)), [C.fill(.black)]), C.path(DisplayPath(rect: Rect(x: 10, y: 0, width: 5, height: 5)), [C.fill(.black)])]))
        let composite = C.path(ReferenceCorpus.frame(Rect(x: 100, y: 0, width: 20, height: 20), Rect(x: 105, y: 5, width: 10, height: 10)), [C.fill(.white)])
        let entries = BlendResolver.entries(BlendSpec(steps: 2, blendPoints: [BlendPoint(child: 1, contour: 1, anchor: 2)]), children: [pair, composite])
        if case .group(let step) = entries[1].item { #expect(step.children.count == 2) } else { Issue.record("steps of composite keys are groups") }
        #expect(BlendSubpath(contour: Contour(segments: [], closed: false), appearance: Appearance()).centroid == .zero)
        // Past the midpoint the later stack wins.
        let red = Color(red: 1, green: 0, blue: 0)
        let a = Appearance([C.fill(red)])
        let b = Appearance([C.stroke(.black, width: 1)])
        #expect(BlendInterpolator.appearance(a, b, t: 0.7) == b)
        #expect(BlendInterpolator.paint(.pattern(PatternPaint(bitmap: .checker, color: red)), .solid(.black), t: 0.7) == .solid(.black))
        let custom = Appearance([.stroke(StrokePaint(paint: .solid(.black), kind: .calligraphic(CalligraphicNib(width: 4, height: 1))))])
        #expect(BlendInterpolator.appearance(custom, Appearance([C.stroke(.black, width: 1)]), t: 0.7) == Appearance([C.stroke(.black, width: 1)]))
        // Gradients with second axis ends interpolate those too.
        let g1 = Gradient(.radial, from: red, to: .white, axis: .init(start: .zero, end: Point(x: 10, y: 0), end2: Point(x: 0, y: 10)))
        let g2 = Gradient(.radial, from: .black, to: .white, axis: .init(start: .zero, end: Point(x: 20, y: 0), end2: Point(x: 0, y: 20)))
        #expect(BlendInterpolator.gradient(g1, g2, t: 0.5).axis?.end2 == Point(x: 0, y: 15))
        // On a path, an empty key shape keeps its place.
        let distributor = OnPathDistributor(LiveGroupTests.spine, rotates: false)!
        #expect(distributor.placement(for: BlendShape(subpaths: []), at: 0.5).isIdentity == false)
        // Keyline draws a derived group's items that paint; an empty key object paints nothing.
        let withEmpty = DisplayItem.group(GroupItem(children: [LiveGroupTests.circle, LiveGroupTests.box, C.path(DisplayPath(), [C.fill(.black)])], live: .blend(BlendSpec(steps: 1))))
        for mode in [ViewMode.keyline] {
            _ = CoreGraphicsRenderer(background: .white, viewMode: mode).renderBitmap(DisplayList(canvas: "k", items: [withEmpty]), viewport: Viewport(size: Size(width: 40, height: 40)))
            if let context = MetalAvailability.context {
                let geometry = TileGeometry(zoomStep: ZoomStep(nearest: 1), rotationDegrees: 0)
                let key = geometry.tiles(coveringPasteboardRect: Rect(x: 0, y: 0, width: 10, height: 10), canvas: "k")[0]
                _ = MetalRenderer(context: context, background: .white, viewMode: mode).renderTile(DisplayList(canvas: "k", items: [withEmpty]), key: key, geometry: geometry)
            }
        }
        // Combine members take their own vector effects.
        let bent = C.path(DisplayPath(rect: Rect(x: 0, y: 0, width: 20, height: 20)), [C.fill(.black)])
        guard case .path(var effected) = bent else { return }
        effected.appearance.effects = [EffectElement(.transform(.init(move: Point(x: 50, y: 0))))]
        #expect(approx(CombineResolver.outline(of: .path(effected)).bounds.minX, 50, tolerance: 1e-9))
        // Bend on an open path joins only interior anchors.
        let wave = EffectShape(contours: AttributeCorpus.wave(in: Rect(x: 0, y: 0, width: 40, height: 20)).contours + DisplayPath(polygon: [Point(x: 0, y: 30), Point(x: 20, y: 30), Point(x: 40, y: 30)], closed: false).contours)
        #expect(BendKernel.apply(.init(size: 3), to: [wave], reference: Rect(x: 0, y: 0, width: 40, height: 40))[0].contours.count == 2)
        // An extruded child without a stroke draws its wireframe black; no child, nothing.
        let fillOnly = C.path(DisplayPath(rect: Rect(x: 0, y: 0, width: 10, height: 10)), [C.fill(.white)])
        let wire = ExtrudeResolver.entries(ExtrudeSpec(length: 10, vanishingPoint: Point(x: 50, y: -20), surface: .wireframe), children: [fillOnly])
        if case .path(let edges) = wire[0].item { #expect(edges.appearance.strokes[0].paint == .solid(.black)) }
        #expect(ExtrudeResolver.entries(ExtrudeSpec(length: 10), children: [C.path(DisplayPath(), [C.fill(.white)])]).map(\.origin) == [0])
    }
}
