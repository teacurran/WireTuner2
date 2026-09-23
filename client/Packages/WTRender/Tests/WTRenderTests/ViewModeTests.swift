import WTGeometry
import CoreGraphics
import Foundation
import Testing
@testable import WTRender
// GEO-003 added stroke types of the same names to WTGeometry; the display list's are WTRender's.
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

@Suite struct ViewModeTests {
    @Test func togglesAndFlags() {
        #expect(ViewMode(keyline: false, fast: false) == .preview)
        #expect(ViewMode(keyline: false, fast: true) == .fastPreview)
        #expect(ViewMode(keyline: true, fast: false) == .keyline)
        #expect(ViewMode(keyline: true, fast: true) == .fastKeyline)
        for mode in ViewMode.allCases {
            #expect(ViewMode(keyline: mode.isKeyline, fast: mode.isFast) == mode)
            #expect(mode.togglingKeyline.isKeyline != mode.isKeyline && mode.togglingKeyline.isFast == mode.isFast)
            #expect(mode.togglingFast.isFast != mode.isFast && mode.togglingFast.isKeyline == mode.isKeyline)
            #expect(mode.togglingKeyline.togglingKeyline == mode)
        }
        #expect(ViewMode.fastKeyline.togglingKeyline == .fastPreview, "BASIC-013: Keyline from Fast Keyline yields Fast Preview")
        #expect(ViewMode.preview.drawsTransparencyGroups && ViewMode.preview.drawsRasterEffects && !ViewMode.preview.drawsImagesAsBoxes)
        for mode in [ViewMode.fastPreview, .keyline, .fastKeyline] {
            #expect(!mode.drawsTransparencyGroups && !mode.drawsRasterEffects && mode.drawsImagesAsBoxes)
        }
        #expect(ViewMode.fastPreview.greeksText && ViewMode.fastKeyline.greeksText)
        #expect(!ViewMode.preview.greeksText && !ViewMode.keyline.greeksText)
        #expect(ViewMode.greekingThreshold == 50)
    }

    @Test func rendererCarriesModeAndOverprint() {
        let renderer = CoreGraphicsRenderer()
        #expect(renderer.viewMode == .preview && !renderer.overprintPreview)
        #expect(renderer.with(viewMode: .keyline).viewMode == .keyline)
        #expect(renderer.with(overprintPreview: true).overprintPreview)
        #expect(renderer.with(viewMode: .keyline).flatteningTolerance == renderer.flatteningTolerance)
    }

    // MARK: Renders differ where expected, and only there

    private static let size = Size(width: 128, height: 96)

    static func pixels(_ list: DisplayList, _ mode: ViewMode, overprint: Bool = false, scale: Double = 1) -> BitmapSurface {
        let renderer = CoreGraphicsRenderer(background: .white, viewMode: mode, overprintPreview: overprint)
        return BitmapSurface(drawing: renderer.renderBitmap(list, viewport: Viewport(size: size), scale: scale)!)!
    }

    static func identical(_ a: BitmapSurface, _ b: BitmapSurface) -> Bool {
        for y in 0..<a.height {
            for x in 0..<a.width where a.pixel(x: x, y: y) != b.pixel(x: x, y: y) {
                return false
            }
        }
        return true
    }

    static func list(_ items: [DisplayItem]) -> DisplayList {
        DisplayList(canvas: "modes", items: items)
    }

    static let opaquePaths = list([
        ReferenceCorpus.path(DisplayPath(ellipseIn: Rect(x: 10, y: 10, width: 60, height: 50)), [ReferenceCorpus.fill(red), ReferenceCorpus.stroke(.black, width: 3, dash: [5, 2])]),
        ReferenceCorpus.path(ReferenceCorpus.line(10, 80, 110, 70), [ReferenceCorpus.stroke(blue, width: 2, end: .triangle)]),
        .fill(FillItem(path: DisplayPath(rect: Rect(x: 80, y: 10, width: 30, height: 30)), paint: .solid(green))),
        .group(GroupItem(children: [.stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 84, y: 44, width: 20, height: 12)), paint: .solid(.black)))], clip: DisplayPath(rect: Rect(x: 0, y: 0, width: 128, height: 50)))),
    ])

    @Test func fastPreviewEqualsPreviewForOpaquePaths() {
        #expect(Self.identical(Self.pixels(Self.opaquePaths, .preview), Self.pixels(Self.opaquePaths, .fastPreview)))
    }

    @Test func keylineDiffersFromPreviewAndDrawsNoFills() {
        let preview = Self.pixels(Self.opaquePaths, .preview)
        let keyline = Self.pixels(Self.opaquePaths, .keyline)
        #expect(!Self.identical(preview, keyline))
        #expect(preview.pixel(x: 40, y: 35) == RGBA8(red: 230, green: 26, blue: 26, alpha: 255))
        #expect(keyline.pixel(x: 40, y: 35) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255), "no fills in Keyline")
        #expect(Self.identical(keyline, Self.pixels(Self.opaquePaths, .fastKeyline)), "without text the two keyline modes agree")
    }

    @Test func keylineHairlinesUseTheLayerHighlightColour() {
        // Edges on pixel centres, so the one-pixel hairline covers whole pixels.
        let square = ReferenceCorpus.path(DisplayPath(rect: Rect(x: 10.5, y: 10.5, width: 40, height: 40)), [ReferenceCorpus.fill(blue)])
        let highlight = Color(red: 0.9, green: 0.1, blue: 0.1)
        let inner = Color(red: 0.1, green: 0.7, blue: 0.2)
        let layered = Self.list([
            .group(GroupItem(children: [
                square,
                .group(GroupItem(children: [.fill(FillItem(path: DisplayPath(rect: Rect(x: 70.5, y: 10.5, width: 40, height: 40)), paint: .solid(blue)))], highlightColor: inner)),
            ], highlightColor: highlight)),
            ReferenceCorpus.path(DisplayPath(rect: Rect(x: 10.5, y: 60.5, width: 40, height: 20)), [ReferenceCorpus.fill(blue)]),
        ])
        let surface = Self.pixels(layered, .keyline)
        #expect(surface.pixel(x: 10, y: 30) == RGBA8(red: 230, green: 26, blue: 26, alpha: 255), "the layer's colour")
        #expect(surface.pixel(x: 70, y: 30) == RGBA8(red: 26, green: 179, blue: 51, alpha: 255), "a nested layer overrides")
        #expect(surface.pixel(x: 10, y: 70) == RGBA8(red: 0, green: 0, blue: 0, alpha: 255), "black outside any layer")
        #expect(surface.pixel(x: 30, y: 30) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
        // One device pixel at any scale: at 2× the same edge is still a single column wide.
        let retina = Self.pixels(layered, .keyline, scale: 2)
        let row = (18...24).map { retina.pixel(x: $0, y: 60).green < 128 ? 1 : 0 }.reduce(0, +)
        #expect(row <= 2, "a hairline, not a one-unit line")
    }

    @Test func transparencyGroupsAreSkippedInFastModes() {
        let overlapping = Self.list([
            .group(GroupItem(children: [
                .fill(FillItem(path: DisplayPath(rect: Rect(x: 10, y: 10, width: 60, height: 60)), paint: .solid(.black))),
                .fill(FillItem(path: DisplayPath(rect: Rect(x: 40, y: 40, width: 60, height: 50)), paint: .solid(.black))),
            ], opacity: 0.5)),
        ])
        let preview = Self.pixels(overlapping, .preview)
        let fast = Self.pixels(overlapping, .fastPreview)
        #expect(!Self.identical(preview, fast))
        let overlapInPreview = preview.pixel(x: 55, y: 55)
        let overlapInFast = fast.pixel(x: 55, y: 55)
        #expect(overlapInPreview == preview.pixel(x: 20, y: 20), "one layer: the overlap is no darker")
        #expect(overlapInFast.red < fast.pixel(x: 20, y: 20).red, "no layer: members composite one by one")

        // Nested translucent groups multiply their alpha in the fast modes too.
        let nested = Self.list([
            .group(GroupItem(children: [
                .group(GroupItem(children: [.fill(FillItem(path: DisplayPath(rect: Rect(x: 10, y: 10, width: 60, height: 60)), paint: .solid(.black)))], opacity: 0.5)),
            ], opacity: 0.5)),
        ])
        let quarter = Self.pixels(nested, .fastPreview).pixel(x: 40, y: 40)
        #expect(abs(Int(quarter.red) - 191) <= 1, "0.5 × 0.5 of black over white \(quarter)")
        #expect(Self.identical(Self.pixels(nested, .keyline), Self.pixels(nested, .fastKeyline)))
    }

    @Test func imagesBecomeBoxesAndSmallTextIsGreeked() {
        let image = Self.list([.image(ImageItem(assetID: "a", rect: Rect(x: 10, y: 10, width: 60, height: 40)))])
        let preview = Self.pixels(image, .preview)
        let fast = Self.pixels(image, .fastPreview)
        #expect(preview.pixel(x: 20, y: 40) == RGBA8(red: 191, green: 191, blue: 191, alpha: 255), "the grey placeholder block")
        #expect(fast.pixel(x: 20, y: 40) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255), "only the crossed box in fast modes")

        let small = Self.list([.text(TextRunItem(text: "small", origin: Point(x: 10, y: 40), bounds: Rect(x: 10, y: 20, width: 80, height: 24), color: blue))])
        let smallPreview = Self.pixels(small, .preview)
        let smallFast = Self.pixels(small, .fastPreview)
        #expect(!Self.identical(smallPreview, smallFast))
        #expect(smallFast.pixel(x: 50, y: 30) == RGBA8(red: 179, green: 179, blue: 179, alpha: 255), "a grey bar")
        #expect(!Self.identical(Self.pixels(small, .keyline), Self.pixels(small, .fastKeyline)))

        let large = Self.list([.text(TextRunItem(text: "big", origin: Point(x: 10, y: 80), bounds: Rect(x: 10, y: 10, width: 100, height: 70), color: blue))])
        #expect(Self.identical(Self.pixels(large, .preview), Self.pixels(large, .fastPreview)), "text above 50 pt is not greeked")
        #expect(Self.identical(Self.pixels(large, .keyline), Self.pixels(large, .fastKeyline)))
    }

    @Test func overprintPreviewOnlyChangesOverprintingPaint() {
        let items: (Bool) -> DisplayList = { overprint in
            Self.list([
                ReferenceCorpus.path(DisplayPath(rect: Rect(x: 10, y: 10, width: 60, height: 60)), [ReferenceCorpus.fill(ReferenceCorpus.cyan)]),
                ReferenceCorpus.path(DisplayPath(rect: Rect(x: 40, y: 30, width: 60, height: 50)), [ReferenceCorpus.fill(ReferenceCorpus.magenta, overprint: overprint)]),
            ])
        }
        let flagged = items(true)
        let plain = items(false)
        #expect(Self.identical(Self.pixels(flagged, .preview), Self.pixels(plain, .preview)), "overprint is invisible without the preview")
        #expect(Self.identical(Self.pixels(plain, .preview, overprint: true), Self.pixels(plain, .preview)))
        let simulated = Self.pixels(flagged, .preview, overprint: true)
        #expect(!Self.identical(simulated, Self.pixels(plain, .preview)))
        let overlap = simulated.pixel(x: 55, y: 50)
        #expect(overlap.red < 30 && overlap.blue > 100, "cyan × magenta multiplies toward blue \(overlap)")
    }

    @Test func noneAndHiddenPaintDrawNothing() {
        let none = Self.list([
            .fill(FillItem(path: DisplayPath(rect: Rect(x: 10, y: 10, width: 60, height: 60)), paint: .none)),
            .stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 10, y: 10, width: 60, height: 60)), style: StrokeStyle(width: 4), paint: .none)),
        ])
        #expect(Self.identical(Self.pixels(none, .preview), Self.pixels(Self.list([]), .preview)))
    }

    // MARK: The canvas switches modes without a new display list

    @Test func tileCacheReplacesItsRenderer() async throws {
        let cache = TileCache(renderer: CoreGraphicsRenderer(), capacity: 8)
        let geometry = TileGeometry(zoomStep: ZoomStep(index: 0), rotationDegrees: 0)
        let key = TileKey(canvas: Corpus.canvas, zoomStep: ZoomStep(index: 0), rotationDegrees: 0, column: 0, row: 0)
        let preview = try #require(await cache.tile(for: key, in: Corpus.solidRect, geometry: geometry))
        #expect(await cache.viewMode == .preview)
        await cache.replaceRenderer(CoreGraphicsRenderer(viewMode: .keyline))
        #expect(await cache.count == 0, "tile keys carry no mode, so every tile goes")
        #expect(await cache.viewMode == .keyline)
        let keyline = try #require(await cache.tile(for: key, in: Corpus.solidRect, geometry: geometry))
        let before = try #require(BitmapSurface(drawing: preview))
        let after = try #require(BitmapSurface(drawing: keyline))
        #expect(before.pixel(x: 40, y: 30).alpha == 255 && after.pixel(x: 40, y: 30).alpha == 0, "the fill's interior is gone in Keyline")
    }

    @MainActor
    @Test func canvasLayerSwitchesRendererAndRedraws() async {
        let canvas = TiledCanvasLayer(cache: TileCache(renderer: CoreGraphicsRenderer(), capacity: 64), backingScale: 1)
        let viewport = Viewport(size: Size(width: 300, height: 200))
        let layout = canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        await canvas.settle()
        let rendersBefore = await canvas.cache.renders
        canvas.setRenderer(CoreGraphicsRenderer(viewMode: .keyline))
        #expect(canvas.pendingTileCount == 0)
        await canvas.settle()
        #expect(await canvas.cache.viewMode == .keyline)
        #expect(await canvas.cache.renders == rendersBefore + layout.placements.count, "every visible tile re-rendered")
        #expect(canvas.displayList == Corpus.solidRect, "the display list is the same value")
        for placement in layout.placements {
            #expect(canvas.hasContents(for: placement.key))
        }
    }

    // MARK: Preview in Browser

    struct RecordingHook: BrowserPreviewHook {
        func exportForBrowserPreview(_ request: BrowserPreviewRequest) async throws -> URL {
            URL(fileURLWithPath: "/tmp/\(request.canvas)/\(request.wholeDocument ? "index" : "page").html")
        }
    }

    @Test func browserPreviewHookShape() async throws {
        let request = BrowserPreviewRequest(canvas: "page-1", pageBounds: Rect(x: 0, y: 0, width: 612, height: 792))
        #expect(!request.wholeDocument)
        let hook: any BrowserPreviewHook = RecordingHook()
        #expect(try await hook.exportForBrowserPreview(request).lastPathComponent == "page.html")
        let everything = BrowserPreviewRequest(canvas: "page-1", pageBounds: request.pageBounds, wholeDocument: true)
        #expect(try await hook.exportForBrowserPreview(everything).lastPathComponent == "index.html")
    }
}
