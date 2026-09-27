import WTGeometry
import QuartzCore
import Testing
@testable import WTRender

@MainActor
@Suite struct TiledCanvasLayerTests {
    private let size = Size(width: 300, height: 200)

    private func makeCanvas(capacity: Int = 64) -> TiledCanvasLayer {
        TiledCanvasLayer(cache: TileCache(renderer: CoreGraphicsRenderer(), capacity: capacity), backingScale: 2)
    }

    @Test func layoutCreatesOneLayerPerVisibleTileAndFillsThem() async {
        let canvas = makeCanvas()
        #expect(canvas.layer.masksToBounds)
        #expect(canvas.displayList == nil && canvas.viewport == nil && canvas.layout == nil)

        let viewport = Viewport(size: size)
        let layout = canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        #expect(layout.placements.count == 6)
        #expect(canvas.tileLayerCount == 6)
        #expect(canvas.layer.sublayers?.count == 6)
        #expect(canvas.layer.bounds == CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(canvas.pendingTileCount == 0, "a new list first invalidates the cache; requests follow once that has landed")
        #expect(canvas.displayList == Corpus.solidRect)
        #expect(canvas.viewport == viewport)
        #expect(canvas.layout == layout)

        await canvas.settle()
        #expect(canvas.pendingTileCount == 0)
        for placement in layout.placements {
            #expect(canvas.hasContents(for: placement.key))
        }
        #expect(await canvas.cache.count == 6)
        #expect(await canvas.cache.renders == 6)

        // Frames are the placements flipped into the layer's y-up coordinates.
        let first = layout.placements[0]
        let sublayer = canvas.layer.sublayers!.first { $0.frame.minX == first.frame.minX && $0.frame.minY == 200 - first.frame.maxY }
        #expect(sublayer != nil)
        #expect(sublayer?.contentsGravity == .resize)
    }

    @Test func discardingDropsEveryTileAndTheNextUpdateStartsOver() async {
        let canvas = makeCanvas()
        let viewport = Viewport(size: size)
        canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        await canvas.settle()
        #expect(canvas.tileLayerCount == 6)
        #expect(await canvas.cache.count == 6)
        canvas.discardTiles()
        await canvas.settle()
        #expect(canvas.tileLayerCount == 0 && canvas.pendingTileCount == 0 && canvas.layout == nil)
        #expect(canvas.layer.sublayers?.isEmpty ?? true)
        #expect(await canvas.cache.count == 0, "a closed window's canvas holds no tile memory")
        canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        await canvas.settle()
        #expect(canvas.tileLayerCount == 6)
        #expect(await canvas.cache.count == 6)
    }

    @Test func panningReusesTilesAndDropsTheOnesThatLeft() async {
        let canvas = makeCanvas()
        let start = Viewport(size: size)
        let before = canvas.update(displayList: Corpus.solidRect, viewport: start)
        await canvas.settle()
        let rendersBefore = await canvas.cache.renders

        // Scroll one tile (128 points on a 2× display) to the right.
        let panned = start.scrolled(byViewDelta: Vector(dx: 128, dy: 0))
        let after = canvas.update(displayList: Corpus.solidRect, viewport: panned)
        let shared = before.keys.intersection(after.keys)
        #expect(shared.count == 4)
        #expect(canvas.tileLayerCount == after.keys.count)
        for key in shared {
            #expect(canvas.hasContents(for: key), "a tile that stays visible keeps its image")
        }
        for key in before.keys.subtracting(after.keys) {
            #expect(!canvas.hasContents(for: key))
        }
        await canvas.settle()
        #expect(await canvas.cache.renders == rendersBefore + after.keys.subtracting(before.keys).count)
        #expect(canvas.layer.sublayers?.count == after.keys.count)
    }

    @Test func changingTheDisplayListInvalidatesEverything() async {
        let canvas = makeCanvas()
        let viewport = Viewport(size: size)
        canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        await canvas.settle()
        #expect(await canvas.cache.renders == 6)

        canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        #expect(canvas.pendingTileCount == 0, "the same list value requests nothing")

        let layout = canvas.update(displayList: Corpus.ellipse, viewport: viewport)
        #expect(canvas.pendingTileCount == 0, "requests wait for the invalidation to reach the cache")
        for placement in layout.placements {
            #expect(!canvas.hasContents(for: placement.key))
        }
        await canvas.settle()
        #expect(await canvas.cache.renders == 12)
        #expect(await canvas.cache.count == 6)
        for placement in layout.placements {
            #expect(canvas.hasContents(for: placement.key))
        }
    }

    @Test func rectInvalidationRedrawsOnlyTouchedTiles() async {
        let canvas = makeCanvas()
        let viewport = Viewport(size: size)
        let layout = canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        await canvas.settle()

        // The top-left tile covers pasteboard (0...128, 0...128) at 100% on a 2× display.
        canvas.invalidate(pasteboardRect: Rect(x: 10, y: 10, width: 20, height: 20))
        let topLeft = layout.placements.first { $0.key.column == 0 && $0.key.row == 0 }!.key
        #expect(!canvas.hasContents(for: topLeft))
        let others = layout.keys.subtracting([topLeft])
        for key in others {
            #expect(canvas.hasContents(for: key))
        }
        await canvas.settle()
        #expect(canvas.hasContents(for: topLeft))
        #expect(await canvas.cache.renders == 7)

        // A rect nowhere near the view invalidates nothing.
        canvas.invalidate(pasteboardRect: Rect(x: 5000, y: 5000, width: 1, height: 1))
        await canvas.settle()
        #expect(await canvas.cache.renders == 7)
    }

    @Test func invalidationBeforeAnyUpdateIsANoOp() async {
        let canvas = makeCanvas()
        canvas.invalidate(pasteboardRect: Rect(x: 0, y: 0, width: 1, height: 1))
        canvas.invalidateAll()
        await canvas.settle()
        #expect(canvas.tileLayerCount == 0)
        #expect(!canvas.hasContents(for: TileKey(canvas: "c", zoomStep: ZoomStep(index: 0), rotationDegrees: 0, column: 0, row: 0)))
    }

    @Test func zoomAndRotationChangeTheKeysNotTheList() async {
        let canvas = makeCanvas()
        let straight = Viewport(size: size)
        let first = canvas.update(displayList: Corpus.evenOddStar, viewport: straight)
        await canvas.settle()
        let turned = canvas.update(displayList: Corpus.evenOddStar, viewport: straight.rotated(toDegrees: 15))
        #expect(turned.keys.isDisjoint(with: first.keys))
        #expect(turned.geometry.rotationDegrees == 15)
        #expect(canvas.displayList == Corpus.evenOddStar)
        await canvas.settle()
        #expect(canvas.tileLayerCount == turned.keys.count)
        for key in turned.keys {
            #expect(canvas.hasContents(for: key))
        }
        let zoomed = canvas.update(displayList: Corpus.evenOddStar, viewport: straight.zoomed(to: 2))
        #expect(zoomed.geometry.zoomStep == ZoomStep(index: 2 * ZoomStep.stepsPerOctave))
        await canvas.settle()
        #expect(await canvas.cache.count == first.keys.count + turned.keys.count + zoomed.keys.count)
    }

    @Test func backingScaleChangesTheZoomStep() async {
        let canvas = makeCanvas()
        let viewport = Viewport(size: size)
        let retina = canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        #expect(retina.geometry.zoomStep == ZoomStep(index: ZoomStep.stepsPerOctave))
        canvas.backingScale = 1
        let standard = canvas.update(displayList: Corpus.solidRect, viewport: viewport)
        #expect(standard.geometry.zoomStep == ZoomStep(index: 0))
        #expect(standard.placements.count == 2, "256-pixel tiles are 256 points at 1×")
        await canvas.settle()
        #expect(canvas.tileLayerCount == 2)
    }

    @Test func rapidUpdatesCancelSupersededRequests() async {
        let canvas = makeCanvas()
        let start = Viewport(size: size)
        canvas.update(displayList: Corpus.strokes, viewport: start)
        await canvas.settle()

        // Scroll to fresh tiles: with the list unchanged their requests go out at once.
        let middle = start.scrolled(byViewDelta: Vector(dx: 5000, dy: 0))
        let interim = canvas.update(displayList: Corpus.strokes, viewport: middle)
        #expect(canvas.pendingTileCount == interim.keys.count)

        // Before any of them lands, scroll again: the interim requests are cancelled.
        let far = middle.scrolled(byViewDelta: Vector(dx: 0, dy: 5000))
        let layout = canvas.update(displayList: Corpus.strokes, viewport: far)
        #expect(layout.keys.isDisjoint(with: interim.keys))
        #expect(canvas.pendingTileCount == layout.keys.count)
        #expect(canvas.tileLayerCount == layout.keys.count)
        await canvas.settle()
        #expect(canvas.pendingTileCount == 0)
        for key in layout.keys {
            #expect(canvas.hasContents(for: key))
        }
        for key in interim.keys {
            #expect(!canvas.hasContents(for: key))
        }
        #expect(await canvas.cache.count <= 18)
    }
}
