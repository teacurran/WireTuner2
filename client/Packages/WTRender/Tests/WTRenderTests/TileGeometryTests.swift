import WTGeometry
import Testing
@testable import WTRender

@Suite struct TileKeyTests {
    @Test func rotationIsCanonical() {
        #expect(TileKey.canonicalRotation(360.0004) == 0)
        #expect(TileKey.canonicalRotation(-180) == 180)
        #expect(TileKey.canonicalRotation(15.0004) == 15)
        #expect(TileKey.canonicalRotation(15.0006) == 15.001)
        let a = TileKey(canvas: "c", zoomStep: ZoomStep(index: 3), rotationDegrees: 375.0001, column: 1, row: 2)
        let b = TileKey(canvas: "c", zoomStep: ZoomStep(index: 3), rotationDegrees: 15, column: 1, row: 2)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a.description == "c@3/15.0°[1,2]")
        #expect(a != TileKey(canvas: "d", zoomStep: ZoomStep(index: 3), rotationDegrees: 15, column: 1, row: 2))
    }
}

@Suite struct TileGeometryTests {
    private let canvas: CanvasID = "c"

    /// Every tile whose cell shares area with `rect` (touching edges do not count), found the
    /// slow way, for cross-checking.
    private func bruteForce(_ geometry: TileGeometry, tileSpaceRect rect: Rect) -> Set<TileKey> {
        var keys: Set<TileKey> = []
        for row in -64...64 {
            for column in -64...64 {
                let key = TileKey(canvas: canvas, zoomStep: geometry.zoomStep, rotationDegrees: geometry.rotationDegrees, column: column, row: row)
                let cell = geometry.tileSpaceRect(of: key)
                if cell.minX < rect.maxX && rect.minX < cell.maxX && cell.minY < rect.maxY && rect.minY < cell.maxY {
                    keys.insert(key)
                }
            }
        }
        return keys
    }

    private func columnsAndRows(_ keys: [TileKey]) -> [[Int]] {
        keys.map { [$0.column, $0.row] }
    }

    @Test func constructionAndCanonicalRotation() {
        let geometry = TileGeometry(zoomStep: ZoomStep(index: 64), rotationDegrees: -345, tileSize: 0)
        #expect(geometry.tileSize == 1, "tile size is clamped to at least one pixel")
        #expect(geometry.rotationDegrees == 15)
        let fromViewport = TileGeometry(viewport: Viewport(rotationDegrees: 15, zoom: 1, size: Size(width: 1, height: 1)), backingScale: 2)
        #expect(fromViewport.zoomStep == ZoomStep(index: 64))
        #expect(fromViewport.rotationDegrees == 15)
        #expect(fromViewport.tileSize == 256)
        let key = TileKey(canvas: canvas, zoomStep: ZoomStep(index: 64), rotationDegrees: 15, column: 0, row: 0)
        #expect(TileGeometry(key: key) == fromViewport)
        #expect(TileGeometry.standardTileSize == 256)
    }

    @Test func unrotatedCoverageIsRowMajor() {
        let geometry = TileGeometry(zoomStep: ZoomStep(index: 0), rotationDegrees: 0)
        let keys = geometry.tiles(coveringPasteboardRect: Rect(x: 0, y: 0, width: 512, height: 512), canvas: canvas)
        #expect(columnsAndRows(keys) == [[0, 0], [1, 0], [0, 1], [1, 1]])
        #expect(keys.allSatisfy { $0.canvas == canvas && $0.zoomStep.index == 0 && $0.rotationDegrees == 0 })

        let single = geometry.tiles(coveringPasteboardRect: Rect(x: 256, y: 256, width: 256, height: 256), canvas: canvas)
        #expect(columnsAndRows(single) == [[1, 1]], "edges on a boundary do not pull in the neighbour")

        let straddling = geometry.tiles(coveringPasteboardRect: Rect(x: 255.5, y: -0.5, width: 1, height: 1), canvas: canvas)
        #expect(columnsAndRows(straddling) == [[0, -1], [1, -1], [0, 0], [1, 0]])

        #expect(geometry.tiles(coveringPasteboardRect: Rect(x: 5, y: 5, width: 0, height: 10), canvas: canvas).isEmpty)
        #expect(geometry.key(containing: Point(x: -1, y: 300), canvas: canvas).column == -1)
        #expect(geometry.key(containing: Point(x: -1, y: 300), canvas: canvas).row == 1)
    }

    @Test func zoomScalesTheCoverage() {
        let geometry = TileGeometry(zoomStep: ZoomStep(index: 64), rotationDegrees: 0)  // 2×
        let keys = geometry.tiles(coveringPasteboardRect: Rect(x: 0, y: 0, width: 256, height: 128), canvas: canvas)
        #expect(columnsAndRows(keys) == [[0, 0], [1, 0]])
        #expect(geometry.pasteboardBounds(of: keys[1]) == Rect(x: 128, y: 0, width: 128, height: 128))
        #expect(approx(geometry.pasteboardToTile(keys[1]).apply(Point(x: 128, y: 0)), .zero))
        #expect(approx(geometry.pasteboardToTile(keys[1]).apply(Point(x: 256, y: 128)), Point(x: 256, y: 256)))
    }

    @Test(arguments: [15.0, 45.0, 90.0, -120.0])
    func rotatedPasteboardRectCoverageMatchesBruteForce(degrees: Double) {
        let geometry = TileGeometry(zoomStep: ZoomStep(index: 32), rotationDegrees: degrees)
        let rect = Rect(x: -300, y: 120, width: 700, height: 450)
        let keys = geometry.tiles(coveringPasteboardRect: rect, canvas: canvas)
        #expect(Set(keys) == bruteForce(geometry, tileSpaceRect: rect.applying(geometry.pasteboardToTileSpace)))
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.rotationDegrees == degrees })
        for key in keys {
            #expect(geometry.tiles(coveringPasteboardRect: geometry.pasteboardBounds(of: key), canvas: canvas).contains(key))
            let corner = geometry.tileSpaceToPasteboard.apply(geometry.tileSpaceRect(of: key).origin)
            #expect(approx(geometry.pasteboardToTile(key).apply(corner), .zero, tolerance: 1e-9))
        }
    }

    @Test func rotatedViewRectCoverageHasNoBoundingBoxSlack() {
        let viewport = Viewport(scrollOrigin: Point(x: 37, y: -19), rotationDegrees: 15, zoom: 2, size: Size(width: 640, height: 480))
        let geometry = TileGeometry(viewport: viewport, backingScale: 1)
        let keys = geometry.tiles(coveringViewRect: viewport.viewBounds, viewport: viewport, canvas: canvas)
        // 640 × 480 view pixels at exactly the step scale span at most 4 × 3 tiles.
        #expect(keys.count <= 12 && keys.count >= 6, "\(keys.count)")
        let mapped = viewport.viewBounds.applying(geometry.viewToTileSpace(viewport: viewport))
        #expect(approx(mapped.width, 640, tolerance: 1e-9) && approx(mapped.height, 480, tolerance: 1e-9))
        #expect(Set(keys) == bruteForce(geometry, tileSpaceRect: mapped))

        // The pasteboard-space route over-covers, because it goes through the rotated bounding box.
        let viaPasteboard = geometry.tiles(coveringPasteboardRect: viewport.visiblePasteboardBounds, canvas: canvas)
        #expect(Set(viaPasteboard).isSuperset(of: Set(keys)))
        #expect(viaPasteboard.count > keys.count)
    }

    @Test func tileSpaceToViewIsScaleAndTranslation() {
        let viewport = Viewport(scrollOrigin: Point(x: 10, y: 20), rotationDegrees: 30, zoom: 1.5, size: Size(width: 400, height: 300))
        let onStep = TileGeometry(zoomStep: ZoomStep(nearest: 1.5), rotationDegrees: 30)
        let toView = onStep.tileSpaceToView(viewport: viewport)
        #expect(toView.b == 0 && toView.c == 0)
        #expect(approx(toView.a, 1.5 / onStep.zoomStep.scale) && approx(toView.d, toView.a))
        // Tile space through the compositor transform lands where the viewport puts the pasteboard.
        let probe = Point(x: 123, y: -45)
        let viaTiles = toView.apply(onStep.pasteboardToTileSpace.apply(probe))
        let direct = viewport.toView(probe)
        #expect(approx(viaTiles, direct, tolerance: 1e-9))
        let back = onStep.viewToTileSpace(viewport: viewport).apply(viaTiles)
        #expect(approx(back, onStep.pasteboardToTileSpace.apply(probe), tolerance: 1e-9))
    }

    @Test func panningChangesLookupsNotKeysOrContents() {
        let list = Corpus.solidRect
        let a = Viewport(scrollOrigin: Point(x: 0, y: 0), rotationDegrees: 15, zoom: 1, size: Size(width: 300, height: 300))
        let b = a.scrolled(byViewDelta: Vector(dx: 100, dy: 50))
        let geometryA = TileGeometry(viewport: a, backingScale: 2)
        let geometryB = TileGeometry(viewport: b, backingScale: 2)
        #expect(geometryA == geometryB)
        let keysA = Set(geometryA.tiles(coveringViewRect: a.viewBounds, viewport: a, canvas: list.canvas))
        let keysB = Set(geometryB.tiles(coveringViewRect: b.viewBounds, viewport: b, canvas: list.canvas))
        #expect(!keysA.isDisjoint(with: keysB))
        for key in keysA {
            #expect(geometryA.pasteboardBounds(of: key) == geometryB.pasteboardBounds(of: key))
        }
    }

    @Test func rotatingFifteenDegreesChangesOnlyTileKeys() {
        let list = Corpus.evenOddStar
        let before = list
        let straight = Viewport(size: Size(width: 256, height: 256))
        let turned = straight.rotated(toDegrees: 15)
        let geometry0 = TileGeometry(viewport: straight, backingScale: 1)
        let geometry15 = TileGeometry(viewport: turned, backingScale: 1)
        let keys0 = geometry0.tiles(coveringViewRect: straight.viewBounds, viewport: straight, canvas: list.canvas)
        let keys15 = geometry15.tiles(coveringViewRect: turned.viewBounds, viewport: turned, canvas: list.canvas)

        #expect(keys0.allSatisfy { $0.rotationDegrees == 0 })
        #expect(keys15.allSatisfy { $0.rotationDegrees == 15 })
        #expect(Set(keys0).isDisjoint(with: Set(keys15)), "rotation is part of the key, so no tile is shared")
        #expect(keys0.map(\.zoomStep) == keys15.map(\.zoomStep).prefix(keys0.count).map { $0 }, "the zoom step is untouched")

        // The display list is the same value throughout: rotation is view state, not document data.
        #expect(list == before)
        let renderer = CoreGraphicsRenderer()
        #expect(renderer.renderTile(list, key: keys15[0], geometry: geometry15) != nil)
        #expect(list == before)
    }
}

@Suite struct TileLayoutTests {
    @Test func placementsTileTheViewport() {
        let viewport = Viewport(scrollOrigin: Point(x: 5, y: 7), zoom: 1, size: Size(width: 300, height: 200))
        let layout = TileLayout(viewport: viewport, backingScale: 2, canvas: "c")
        #expect(layout.geometry.zoomStep == ZoomStep(index: 64))
        #expect(!layout.isEmpty)
        #expect(layout.keys.count == layout.placements.count)
        // 256-pixel tiles are 128 points on a 2× display.
        for placement in layout.placements {
            #expect(approx(placement.frame.width, 128) && approx(placement.frame.height, 128))
            #expect(placement.frame.intersects(viewport.viewBounds))
        }
        let columns = Set(layout.placements.map(\.key.column))
        let rows = Set(layout.placements.map(\.key.row))
        #expect(columns.count == 3 && rows.count == 2)
        #expect(layout.placements.count == 6)
        // The first placement's frame follows from the tile's tile-space cell.
        let first = layout.placements[0]
        let expected = layout.geometry.tileSpaceRect(of: first.key).applying(layout.geometry.tileSpaceToView(viewport: viewport))
        #expect(approx(first.frame, expected))
    }

    @Test func layerFrameFlipsY() {
        let frame = Rect(x: 10, y: 20, width: 30, height: 40)
        #expect(TileLayout.layerFrame(frame, inHeight: 100) == Rect(x: 10, y: 40, width: 30, height: 40))
        #expect(TilePlacement(key: TileKey(canvas: "c", zoomStep: ZoomStep(index: 0), rotationDegrees: 0, column: 0, row: 0), frame: frame).frame == frame)
    }
}
