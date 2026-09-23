import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// LIB-005: layer rendering and hit-testing rules.
@Suite struct LayerRenderingTests {
    static func id(_ counter: UInt64) -> NodeID { NodeID(counter: counter, replica: 3) }

    static func square(_ rect: Rect, _ color: Color) -> DisplayItem {
        .path(PathItem(path: DisplayPath(rect: rect), appearance: Appearance([.fill(FillPaint(paint: .solid(color)))])))
    }

    static let red = Color(red: 1, green: 0, blue: 0)
    static let guideColor = Color(red: 0, green: 0.8, blue: 0.9)

    /// Background (1), printing (2), locked (3), keyline (4), hidden (5) and Guides (6) layers.
    static func content() -> [LayerContent] {
        [
            LayerContent(layer: LayerRendering(id: id(1), printing: false), items: [(square(Rect(x: 0, y: 0, width: 20, height: 20), red), id(11))]),
            LayerContent(layer: LayerRendering(id: id(2)), items: [(square(Rect(x: 30, y: 0, width: 20, height: 20), red), id(21)), (square(Rect(x: 30, y: 30, width: 20, height: 20), red), id(22))]),
            LayerContent(layer: LayerRendering(id: id(3), locked: true), items: [(square(Rect(x: 60, y: 0, width: 20, height: 20), red), id(31))]),
            LayerContent(layer: LayerRendering(id: id(4), keyline: true, highlight: Color(red: 0, green: 0, blue: 1)), items: [(square(Rect(x: 90, y: 0, width: 20, height: 20), red), id(41))]),
            LayerContent(layer: LayerRendering(id: id(5)), visible: false, items: [(square(Rect(x: 0, y: 30, width: 20, height: 20), red), id(51))]),
            LayerContent(layer: LayerRendering(id: id(6), isGuides: true), items: [(.path(PathItem(path: DisplayPath(polygon: [Point(x: 0, y: 60), Point(x: 120, y: 60)], closed: false), appearance: Appearance([.stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 0)))]))), id(61))]),
        ]
    }

    static func screenList(keylineGuides: Bool = false) -> DisplayList {
        var layers = content()
        layers[5].layer.keyline = keylineGuides
        return LayerScene.build(canvas: "layers", layers: layers, purpose: .screen(guideColor: guideColor), background: [square(Rect(x: -5, y: -5, width: 1, height: 1), .white)])
    }

    @Test func screenListsSkipHiddenLayersAndRecordSpans() {
        let list = Self.screenList()
        #expect(list.count == 7)
        #expect(list.layers.map(\.layer.id) == [Self.id(1), Self.id(2), Self.id(3), Self.id(4), Self.id(6)])
        #expect(list.layers.map(\.range) == [1..<2, 2..<4, 4..<5, 5..<6, 6..<7])
        #expect(list.nodeIDs.first == .some(nil))
        #expect(list.layerSpan(containing: 0) == nil)
        #expect(list.layerSpan(containing: 3)?.layer.id == Self.id(2))
        #expect(list.layerSpan(containing: 99) == nil)
        #expect(list.layerSpan(of: Self.id(6))?.layer.highlight == Self.guideColor)
        #expect(Self.screenList(keylineGuides: true).layerSpan(of: Self.id(6))?.layer.highlight == .black)
        #expect(list.layerSpan(of: Self.id(1))?.layer.opacity == 0.5)
        #expect(list.layerSpan(of: Self.id(6))?.layer.forcesKeyline == true)
        #expect(list.bounds(ofLayer: Self.id(2)) == Rect(x: 30, y: 0, width: 20, height: 50))
        #expect(list.bounds(ofLayer: Self.id(5)) == nil)
    }

    @Test func outputListsLeaveOutBackgroundGuidesAndHiddenUnlessAsked() {
        var layers = Self.content()
        layers[3].layer.keyline = true
        let printing = LayerScene.build(canvas: "layers", layers: layers, purpose: .output(includeHidden: false))
        #expect(printing.layers.map(\.layer.id) == [Self.id(2), Self.id(3), Self.id(4)])
        #expect(printing.layers.allSatisfy { !$0.layer.keyline })
        let withHidden = LayerScene.build(canvas: "layers", layers: layers, purpose: .output(includeHidden: true))
        #expect(withHidden.layers.map(\.layer.id) == [Self.id(2), Self.id(3), Self.id(4), Self.id(5)])
        let bare = LayerScene.build(canvas: "layers", layers: [LayerContent(layer: LayerRendering(id: Self.id(9)), items: [(Self.square(Rect(x: 0, y: 0, width: 1, height: 1), .black), nil)])], purpose: .output(includeHidden: false))
        #expect(bare.nodeIDs.isEmpty)
    }

    @Test func spansAreNormalized() {
        let layer = LayerRendering(id: Self.id(1))
        let spans = LayerSpan.normalized([
            LayerSpan(layer: layer, range: 2..<9),
            LayerSpan(layer: layer, range: 0..<3),
            LayerSpan(layer: layer, range: 3..<3),
        ], count: 5)
        #expect(spans.map(\.range) == [0..<3, 3..<5])
    }

    /// A background layer draws at 50% as one group; a keyline layer draws outlines in its
    /// highlight whatever the mode; guides draw in the guide colour.
    @Test func backgroundLayersDimAndKeylineLayersOutline() throws {
        let list = Self.screenList()
        let image = try #require(CoreGraphicsRenderer(background: .white).renderBitmap(list, viewport: Viewport(size: Size(width: 120, height: 70)), scale: 1))
        let surface = try #require(BitmapSurface(drawing: image))
        let dimmed = surface.pixel(x: 10, y: 10)
        #expect(dimmed.red == 255 && abs(Int(dimmed.green) - 128) <= 1, "background red at 50%: \(dimmed)")
        #expect(surface.pixel(x: 40, y: 10) == RGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(surface.pixel(x: 100, y: 10) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255), "keyline: no fill")
        let outline = surface.pixel(x: 90, y: 10)
        #expect(outline.blue > 200 && Int(outline.blue) - Int(outline.red) > 60, "keyline: the highlight outline \(outline)")
        let guide = surface.pixel(x: 60, y: 60)
        #expect(Int(guide.green) - Int(guide.red) > 60, "guides in the guide colour: \(guide)")
        #expect(surface.pixel(x: 10, y: 40) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255), "hidden layers draw nothing")
        // Fast modes dim member by member, without a transparency layer.
        let fast = try #require(CoreGraphicsRenderer(background: .white, viewMode: .fastPreview).renderBitmap(list, viewport: Viewport(size: Size(width: 120, height: 70)), scale: 1))
        let fastDimmed = try #require(BitmapSurface(drawing: fast)).pixel(x: 10, y: 10)
        #expect(abs(Int(fastDimmed.green) - 128) <= 1)
        // Keyline ignores opacity, as for any group.
        let keyline = try #require(CoreGraphicsRenderer(background: .white, viewMode: .keyline).renderBitmap(list, viewport: Viewport(size: Size(width: 120, height: 70)), scale: 1))
        #expect(try #require(BitmapSurface(drawing: keyline)).pixel(x: 10, y: 10) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
    }

    @Test func metalLoweringFollowsTheSameRules() throws {
        let list = Self.screenList()
        for mode in [ViewMode.preview, .fastPreview, .keyline] {
            let builder = PaintListBuilder(viewMode: mode, overprintPreview: false, tolerance: .standard, surface: Rect(x: 0, y: 0, width: 120, height: 70))
            let operations = builder.operations(for: list, pasteboardTransform: .identity, cull: Rect(x: -10, y: -10, width: 200, height: 200))
            let groups = operations.filter { if case .group = $0 { return true } else { return false } }
            #expect(groups.count == (mode == .preview ? 1 : 0), "\(mode)")
            #expect(!operations.isEmpty)
        }
    }

    // MARK: Hit testing

    static func tester(_ options: HitOptions = HitOptions()) -> HitTester {
        HitTester(displayList: screenList(), viewport: Viewport(size: Size(width: 120, height: 70)), options: options)
    }

    @Test func hitTestingSkipsLockedLayersAndGuides() {
        let tester = Self.tester()
        #expect(tester.hitTest(viewPoint: Point(x: 40, y: 10)).map(\.itemPath) == [[2]])
        #expect(tester.hitTest(viewPoint: Point(x: 10, y: 10)).map(\.itemPath) == [[1]], "background layers are hittable")
        #expect(tester.hitTest(viewPoint: Point(x: 70, y: 10)).isEmpty, "locked")
        #expect(tester.hitTest(viewPoint: Point(x: 60, y: 60)).isEmpty, "guides are not hit by the canvas tools")
        #expect(tester.hitTestGuides(viewPoint: Point(x: 60, y: 60)).map(\.itemPath) == [[6]])
        #expect(tester.hitTestGuides(viewPoint: Point(x: 40, y: 10)).isEmpty)
        #expect(tester.hitTest(viewPoint: Point(x: 10, y: 40)).isEmpty, "hidden layers are not in the list")
        #expect(tester.hitTest(marquee: Rect(x: 55, y: -5, width: 30, height: 30)).isEmpty, "a marquee skips locked layers")
        #expect(tester.hitTest(marquee: Rect(x: 25, y: -5, width: 30, height: 30)).map(\.itemPath) == [[2]])
    }

    @Test func editCurrentLayerOnlyHitsTheActiveLayerAlone() {
        let tester = Self.tester(HitOptions(activeLayer: Self.id(2), editCurrentLayerOnly: true))
        #expect(tester.hitTest(viewPoint: Point(x: 40, y: 10)).map(\.itemPath) == [[2]])
        #expect(tester.hitTest(viewPoint: Point(x: 10, y: 10)).isEmpty)
        #expect(tester.hitTest(viewPoint: Point(x: 100, y: 10)).isEmpty)
        #expect(!tester.isPickable(0), "items on no layer are not the active layer's")
        // Without layers, the layer rules do not apply.
        let plain = HitTester(displayList: DisplayList(canvas: "x", items: [Self.square(Rect(x: 0, y: 0, width: 10, height: 10), .black)]), viewport: Viewport(size: Size(width: 20, height: 20)), options: HitOptions(editCurrentLayerOnly: true))
        #expect(plain.hitTest(viewPoint: Point(x: 5, y: 5)).count == 1)
        #expect(plain.hitTestGuides(viewPoint: Point(x: 5, y: 5)).isEmpty)
        let open = Self.tester()
        #expect(open.isPickable(0))
        #expect(!open.isPickable(0, guides: true))
    }

    // MARK: Invalidation

    /// Toggling a layer flag repaints only that layer's items.
    @Test func togglingALayerFlagRepaintsOnlyThatLayer() {
        let before = Self.screenList()
        var layers = Self.content()
        layers[1].layer.highlight = Self.red
        let after = LayerScene.build(canvas: "layers", layers: layers, purpose: .screen(guideColor: Self.guideColor))
        var summary = ChangeSummary(origin: .remote)
        summary.touch(Self.id(2), fields: [FieldPath(fields: 7)])
        let region = InvalidationMapper().dirtyRegion(for: summary, before: [before], after: [after])
        #expect(region.rects(for: "layers") == [Rect(x: 30, y: 0, width: 20, height: 50)])
        let geometry = TileGeometry(zoomStep: ZoomStep(nearest: 1), rotationDegrees: 0)
        let tiles = region.tiles(for: "layers", geometry: geometry)
        #expect(tiles.count == 1)
    }

    @Test func restrictingToLayersKeepsItemsAndSpans() {
        let list = Self.screenList()
        let restricted = list.restricted(toLayers: [Self.id(2), Self.id(6)])
        #expect(restricted.count == 4)
        #expect(restricted.layers.map(\.range) == [1..<3, 3..<4])
        #expect(restricted.itemBounds == [list.itemBounds[0], list.itemBounds[2], list.itemBounds[3], list.itemBounds[6]])
        #expect(restricted.nodeIDs == [nil, Self.id(21), Self.id(22), Self.id(61)])
        let none = DisplayList(canvas: "x", items: [Self.square(Rect(x: 0, y: 0, width: 1, height: 1), .black)]).restricted(toLayers: [])
        #expect(none.count == 1 && none.nodeIDs.isEmpty)
    }
}
