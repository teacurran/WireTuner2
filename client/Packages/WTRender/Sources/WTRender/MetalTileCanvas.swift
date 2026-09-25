// The Metal tile canvas (REND-006; docs/spec/client.adoc, "Metal tile renderer"): composites
// the tile atlas into a `CAMetalLayer`, drawing a frame only when the view transform changed
// or a tile became ready, at the display's maximum refresh.  A frame never waits for
// rasterization: it draws the tiles that exist (and, under them, the last complete zoom
// step's tiles scaled), while missing tiles render on the tile queue off the main actor.  During a
// pinch or rotate gesture the existing tiles are drawn through the changing transform; the new
// zoom step or angle is rasterized when the gesture settles or every 250 ms.  Pan is a
// lookup: nothing rasterizes until tiles that do not exist enter the viewport.
//
// Fallback: with no Metal device, or after three command buffers in a row fail, the canvas
// swaps its layer content for the Core Graphics `TiledCanvasLayer` over the same tile keys and
// logs why.  A changed display list invalidates the whole canvas unless it comes with its
// `ChangeSummary` (REND-004), which drops only the tiles under the touched nodes.

import WTGeometry
import Foundation
import Metal
import QuartzCore

/// What one offscreen frame cost.
public struct FrameTiming: Hashable, Sendable {
    /// Main-actor time to encode and commit the frame.
    public let cpuSeconds: Double
    /// GPU execution time of the frame's command buffer.
    public let gpuSeconds: Double
    /// Tiles composited.
    public let tiles: Int

    public var totalSeconds: Double { cpuSeconds + gpuSeconds }
}

/// A texture handed to the tile queue.  Metal textures are thread-safe; the protocol simply
/// is not annotated.
private struct TileTarget: @unchecked Sendable {
    let texture: any MTLTexture
}

@MainActor
public final class MetalTileCanvas {
    /// Which renderer puts pixels on screen.
    public enum Backend: Hashable, Sendable {
        case metal
        case coreGraphics(reason: String)
    }

    /// The most a gesture holds the old zoom step or angle before re-rasterizing.
    public static let gestureRefreshInterval = 0.25
    /// Consecutive failed command buffers that switch the canvas to Core Graphics.
    public static let failureLimit = 3
    /// Tiles rendered per command buffer, so tiles appear while others are still rendering.
    static let batchSize = 16

    /// The layer to put in the view hierarchy.  It hosts the `CAMetalLayer`, or the Core
    /// Graphics tile layer once the fallback has engaged.
    public let layer: CALayer
    public let metalLayer: CAMetalLayer
    public private(set) var backend: Backend
    /// The Core Graphics canvas, once the fallback has engaged.
    public private(set) var fallbackCanvas: TiledCanvasLayer?

    public var backingScale: Double {
        didSet { fallbackCanvas?.backingScale = backingScale }
    }
    /// Drawn where no tile covers the view.
    public var pasteboardColor: Color
    /// The colour pipeline tiles render through (CMS-006, CMS-007); the Metal layer is tagged
    /// with its working space and the window server matches it to the display.
    public private(set) var colorManagement: ColorManagement = .standard
    /// What the display the window is on can show (COLOR-024), as last reported by
    /// `displayColorSpaceChanged`.
    public private(set) var displayGamut: WTColor.DisplayGamut = .sRGB

    public private(set) var displayList: DisplayList?
    public private(set) var viewport: Viewport?
    /// The tiling tiles are rasterized for; during a gesture it lags the viewport.
    public private(set) var rasterGeometry: TileGeometry?
    public private(set) var isGesturing = false
    /// Tiles rasterized so far.
    public private(set) var rasterizedTileCount = 0
    /// Whether a frame is due (the transform changed or a tile became ready).
    public private(set) var needsDisplay = false

    let context: MetalContext?
    private(set) var renderer: MetalRenderer?
    private var fallbackRenderer: CoreGraphicsRenderer
    private var atlas: MetalTileAtlas?
    /// The latest tiling whose visible tiles were all drawable: drawn under the current tiling
    /// while that one's tiles render, so a frame never shows the bare pasteboard.
    private var completeGeometry: TileGeometry?
    private let clock: @MainActor () -> Double
    private var lastRasterChange = -Double.infinity
    private var rasterTask: Task<Void, Never>?
    private var generation = 0
    private var consecutiveFailures = 0
    private var displayLink: CAMetalDisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?

    /// A canvas on `device` (the system default unless injected); nil falls back at once.
    public convenience init(
        device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(),
        viewMode: ViewMode = .preview,
        overprintPreview: Bool = false,
        backingScale: Double = 2,
        pasteboardColor: Color = Color(white: 0.9),
        atlasCapacity: Int = 384
    ) {
        let context = device.flatMap { device in
            MetalContext.shared.flatMap { $0.device === device ? $0 : nil } ?? MetalContext(device: device)
        }
        self.init(context: context, viewMode: viewMode, overprintPreview: overprintPreview, backingScale: backingScale, pasteboardColor: pasteboardColor, atlasCapacity: atlasCapacity)
    }

    init(
        context: MetalContext?,
        viewMode: ViewMode = .preview,
        overprintPreview: Bool = false,
        backingScale: Double = 2,
        pasteboardColor: Color = Color(white: 0.9),
        atlasCapacity: Int = 384,
        clock: @escaping @MainActor () -> Double = { CACurrentMediaTime() }
    ) {
        self.context = context
        self.backingScale = backingScale
        self.pasteboardColor = pasteboardColor
        self.clock = clock
        fallbackRenderer = CoreGraphicsRenderer(viewMode: viewMode, overprintPreview: overprintPreview)
        layer = CALayer()
        layer.masksToBounds = true
        metalLayer = CAMetalLayer()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CoreGraphicsRenderer.colorSpace
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        backend = .metal
        guard let context, let atlas = MetalTileAtlas(device: context.device, capacity: atlasCapacity) else {
            engageFallback(reason: context == nil ? "no Metal device" : "tile atlas allocation failed")
            return
        }
        self.atlas = atlas
        renderer = MetalRenderer(context: context, viewMode: viewMode, overprintPreview: overprintPreview)
        metalLayer.device = context.device
        layer.addSublayer(metalLayer)
    }

    /// Tiles that hold a slot in the atlas (drawable or rendering).
    public var atlasTileCount: Int { atlas?.slots.count ?? 0 }

    /// Whether `key`'s tile is drawable.
    public func hasTile(_ key: TileKey) -> Bool {
        atlas?.slots.ready.contains(key) ?? false
    }

    // MARK: State

    /// Shows `displayList` through `viewport`.  A changed list drops every tile -- or, with
    /// `changes` (what turned the shown list into this one), only the tiles under the touched
    /// nodes; a changed transform only schedules a frame, plus rasterization of tiles that do
    /// not exist yet.
    public func update(displayList: DisplayList, viewport: Viewport, changes: ChangeSummary? = nil, mapper: InvalidationMapper = InvalidationMapper()) {
        let previous = self.displayList
        let listChanged = previous != displayList
        self.displayList = displayList
        self.viewport = viewport
        let bounds = CGRect(x: 0, y: 0, width: viewport.size.width, height: viewport.size.height)
        layer.bounds = bounds
        if let fallbackCanvas {
            fallbackCanvas.layer.frame = bounds
            fallbackCanvas.update(displayList: displayList, viewport: viewport, changes: changes, mapper: mapper)
            return
        }
        metalLayer.frame = bounds
        metalLayer.contentsScale = backingScale
        metalLayer.drawableSize = CGSize(width: viewport.size.width * backingScale, height: viewport.size.height * backingScale)
        if listChanged, let changes, let previous, previous.canvas == displayList.canvas {
            let rects = mapper.dirtyRegion(for: changes, before: [previous], after: [displayList]).rects(for: displayList.canvas)
            dropTiles(touching: rects)
        } else if listChanged {
            dropTiles { _ in true }
        }
        let target = TileGeometry(viewport: viewport, backingScale: backingScale)
        if !isGesturing || rasterGeometry == nil || clock() - lastRasterChange >= MetalTileCanvas.gestureRefreshInterval {
            adopt(target)
        }
        requestMissingTiles()
        setNeedsDisplay()
    }

    /// A pinch or rotate gesture began: until it ends (or for 250 ms at a time) the current
    /// tiles are drawn through the changing transform instead of re-rasterized.
    public func beginGesture() {
        isGesturing = true
        lastRasterChange = clock()
    }

    /// The gesture settled: the settled zoom step and angle are rasterized.
    public func endGesture() {
        isGesturing = false
        guard let displayList, let viewport else {
            return
        }
        update(displayList: displayList, viewport: viewport)
    }

    /// Draws in another mode or with overprint preview toggled: every tile is re-rendered.
    public func setViewMode(_ viewMode: ViewMode, overprintPreview: Bool = false) {
        fallbackRenderer = fallbackRenderer.with(viewMode: viewMode).with(overprintPreview: overprintPreview)
        if let fallbackCanvas {
            fallbackCanvas.setRenderer(fallbackRenderer)
            return
        }
        renderer = renderer?.with(viewMode: viewMode).with(overprintPreview: overprintPreview)
        dropTiles { _ in true }
        requestMissingTiles()
    }

    /// Renders through another colour pipeline (a working-space, Working CMYK, intent or proof
    /// change): every tile is re-rendered.
    public func setColorManagement(_ colorManagement: ColorManagement) {
        guard colorManagement != self.colorManagement else {
            return
        }
        self.colorManagement = colorManagement
        metalLayer.colorspace = colorManagement.colorSpace
        fallbackRenderer = fallbackRenderer.with(colorManagement: colorManagement)
        if let fallbackCanvas {
            fallbackCanvas.setRenderer(fallbackRenderer)
            return
        }
        renderer = renderer?.with(colorManagement: colorManagement)
        dropTiles { _ in true }
        requestMissingTiles()
    }

    /// Draws placed images from `store` (IMG-004); every tile is re-rendered.  The owner
    /// forwards the store's `onReady` to `invalidate(pasteboardRects:)` with
    /// `DisplayList.bounds(ofImageAsset:)`.
    public func setImageStore(_ store: ImageStore?) {
        fallbackRenderer.imageStore = store
        if let fallbackCanvas {
            fallbackCanvas.setRenderer(fallbackRenderer)
            return
        }
        renderer?.imageStore = store
        dropTiles { _ in true }
        requestMissingTiles()
    }

    /// The window moved to another display or the display's profile changed
    /// (`NSWindow.didChangeScreenNotification`, `didChangeScreenProfileNotification`): the
    /// display query answers for the new display at once.  Tiles are tagged with the working
    /// space, so the window server re-matches them without a re-render; a frame is requested.
    public func displayColorSpaceChanged(_ colorSpace: CGColorSpace) {
        displayGamut = WTColor.DisplayGamut(colorSpace: colorSpace)
        needsDisplay = true
    }

    /// Applies the *Greek type below* preference (pixels; 0 turns greeking off): every tile is
    /// re-rendered.
    public func setGreekTypeBelow(_ pixels: Double) {
        fallbackRenderer.greekTypeBelow = pixels
        if let fallbackCanvas {
            fallbackCanvas.setRenderer(fallbackRenderer)
            return
        }
        renderer?.greekTypeBelow = pixels
        dropTiles { _ in true }
        requestMissingTiles()
    }

    /// Applies the *Raster effect preview* preference (FX-008): every tile is re-rendered.
    public func setRasterPreview(_ preview: RasterPreview) {
        fallbackRenderer.rasterPreview = preview
        if let fallbackCanvas {
            fallbackCanvas.setRenderer(fallbackRenderer)
            return
        }
        renderer?.rasterPreview = preview
        dropTiles { _ in true }
        requestMissingTiles()
    }

    /// Drops the tiles under a changed pasteboard rectangle, at every zoom step and angle.
    public func invalidate(pasteboardRect rect: Rect) {
        invalidate(pasteboardRects: [rect])
    }

    /// Drops the tiles under any of `rects`, at every zoom step and angle.
    public func invalidate(pasteboardRects rects: [Rect]) {
        if let fallbackCanvas {
            fallbackCanvas.invalidate(pasteboardRects: rects)
            return
        }
        dropTiles(touching: rects)
        requestMissingTiles()
    }

    /// Drops the tiles any of `rects` touches (half a device pixel of slack, as the tile cache).
    /// No generation bump: a dropped key that is rendering right now loses its slot, so the
    /// batch's completion cannot mark it ready (and no slot is reallocated while a batch is in
    /// flight); the other keys of the batch are untouched by the change and are kept.
    private func dropTiles(touching rects: [Rect]) {
        guard !rects.isEmpty else {
            return
        }
        atlas?.slots.removeAll { key in
            let geometry = TileGeometry(key: key)
            return TileCache.touches(geometry.pasteboardBounds(of: key), rects: rects, scale: geometry.zoomStep.scale)
        }
        setNeedsDisplay()
    }

    /// Waits until no tile is rendering (and, on the fallback, until its tiles have landed).
    public func settle() async {
        while let task = rasterTask {
            await task.value
        }
        await fallbackCanvas?.settle()
    }

    private func adopt(_ geometry: TileGeometry) {
        guard geometry != rasterGeometry else {
            return
        }
        rasterGeometry = geometry
        lastRasterChange = clock()
    }

    private func dropTiles(where predicate: (TileKey) -> Bool) {
        generation += 1
        atlas?.slots.removeAll(where: predicate)
        setNeedsDisplay()
    }

    // MARK: Tiles

    /// The tiles of `geometry` that the view shows through `viewport`, whatever the angle
    /// between them (during a rotate gesture the tiling lags the view).
    func visibleKeys(of geometry: TileGeometry, viewport: Viewport, canvas: CanvasID) -> [TileKey] {
        let viewToTileSpace = viewport.viewToPasteboard.concatenating(geometry.pasteboardToTileSpace)
        return geometry.tiles(coveringTileSpaceRect: viewport.viewBounds.applying(viewToTileSpace), canvas: canvas)
    }

    private func requestMissingTiles() {
        guard rasterTask == nil,
              let displayList, let viewport, let geometry = rasterGeometry,
              let atlas, let renderer
        else {
            return
        }
        let visible = visibleKeys(of: geometry, viewport: viewport, canvas: displayList.canvas)
        let protected = Set(visible)
        var jobs: [(key: TileKey, slot: Int)] = []
        for key in visible where !atlas.slots.contains(key) {
            guard let slot = atlas.slots.allocate(key, protecting: protected) else {
                break
            }
            jobs.append((key, slot))
            if jobs.count == MetalTileCanvas.batchSize {
                break
            }
        }
        guard !jobs.isEmpty else {
            return
        }
        let generation = generation
        let target = TileTarget(texture: atlas.texture)
        let work = jobs.map { TileJob(key: $0.key, slot: $0.slot) }
        rasterTask = Task { [weak self] in
            let succeeded = await MetalTileCanvas.rasterize(work, of: displayList, geometry: geometry, renderer: renderer, into: target)
            self?.finish(work, succeeded: succeeded, generation: generation)
        }
    }

    private struct TileJob: Sendable {
        let key: TileKey
        let slot: Int
    }

    /// Renders `jobs` into their atlas slots in one command buffer on the tile queue.
    nonisolated private static func rasterize(_ jobs: [TileJob], of displayList: DisplayList, geometry: TileGeometry, renderer: MetalRenderer, into target: TileTarget) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // One cull for the batch: each tile then culls only the items near the batch.
                let area = jobs.map { geometry.pasteboardBounds(of: $0.key) }.reduce(Rect.null) { $0.union($1) }
                let nearby = DisplayList(canvas: displayList.canvas, items: displayList.indices(intersecting: area).map { displayList.items[$0] })
                let commandBuffer = renderer.context.queue.makeCommandBuffer()
                guard let commandBuffer, jobs.allSatisfy({ job in
                    renderer.encodeTile(nearby, key: job.key, geometry: geometry, into: target.texture, slice: job.slot, commandBuffer: commandBuffer)
                }) else {
                    continuation.resume(returning: false)
                    return
                }
                commandBuffer.addCompletedHandler { buffer in
                    continuation.resume(returning: renderer.context.succeeded(buffer))
                }
                commandBuffer.commit()
            }
        }
    }

    private func finish(_ jobs: [TileJob], succeeded: Bool, generation: Int) {
        rasterTask = nil
        guard backend == .metal, let atlas else {
            return
        }
        if generation == self.generation {
            if succeeded {
                consecutiveFailures = 0
                for job in jobs {
                    atlas.slots.markReady(job.key)
                }
                rasterizedTileCount += jobs.count
                noteCompleteness(atlas)
                setNeedsDisplay()
            } else {
                for job in jobs {
                    atlas.slots.remove(job.key)
                }
                recordFailure("tile command buffer failed")
            }
        }
        requestMissingTiles()
    }

    /// Records the current tiling as complete once every visible tile is drawable.
    private func noteCompleteness(_ atlas: MetalTileAtlas) {
        if let displayList, let viewport, let geometry = rasterGeometry,
           visibleKeys(of: geometry, viewport: viewport, canvas: displayList.canvas).allSatisfy(atlas.slots.ready.contains) {
            completeGeometry = geometry
        }
    }

    // MARK: Frames

    /// Schedules a frame at the next display refresh.
    public func setNeedsDisplay() {
        needsDisplay = true
        displayLink?.isPaused = false
    }

    /// Encodes one frame into `texture`: the pasteboard colour, the last complete tiling's
    /// tiles scaled underneath, then the current tiling's tiles, each a quad placed through the
    /// current view transform.  Returns how many tiles were drawn.
    func encodeFrame(into texture: any MTLTexture, commandBuffer: any MTLCommandBuffer) -> Int {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let clear = colorManagement.workingComponents(pasteboardColor)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: clear.x, green: clear.y, blue: clear.z, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return 0
        }
        defer { encoder.endEncoding() }
        guard let context, let atlas, let displayList, let viewport, let rasterGeometry,
              let pipeline = context.tilePipeline(for: texture.pixelFormat)
        else {
            return 0
        }
        var quads: [TileQuad] = []
        let surface = SIMD2<Double>(Double(texture.width), Double(texture.height))
        let underneath = completeGeometry == rasterGeometry ? nil : completeGeometry
        for geometry in [underneath, rasterGeometry].compactMap({ $0 }) {
            let toDevice = geometry.tileSpaceToPasteboard
                .concatenating(viewport.pasteboardToView)
                .concatenating(.scale(backingScale))
            for key in visibleKeys(of: geometry, viewport: viewport, canvas: displayList.canvas) {
                if let slot = atlas.slots.readySlot(for: key) {
                    quads.append(TileQuad(cell: geometry.tileSpaceRect(of: key), toDevice: toDevice, surface: surface, slice: slot))
                }
            }
        }
        guard !quads.isEmpty else {
            return 0
        }
        let buffer = quads.withUnsafeBytes { bytes in
            context.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.setFragmentSamplerState(MetalTileCanvas.sampler(for: context), index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: quads.count)
        return quads.count
    }

    private static func sampler(for context: MetalContext) -> (any MTLSamplerState)? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return context.device.makeSamplerState(descriptor: descriptor)
    }

    /// Draws a frame into the layer's next drawable now, for hosts that drive frames
    /// themselves; while the display link runs it owns the drawables and this does nothing.
    /// Returns whether a frame was committed.
    @discardableResult
    public func drawFrame() -> Bool {
        guard backend == .metal, displayLink == nil, let drawable = metalLayer.nextDrawable() else {
            return false
        }
        return present(drawable)
    }

    func present(_ drawable: any CAMetalDrawable) -> Bool {
        guard let context, backend == .metal, let commandBuffer = context.frameQueue.makeCommandBuffer() else {
            return false
        }
        _ = encodeFrame(into: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let succeeded = context.succeeded(buffer)
            Task { @MainActor in
                self?.frameCompleted(succeeded: succeeded)
            }
        }
        commandBuffer.commit()
        needsDisplay = false
        displayLink?.isPaused = true
        return true
    }

    /// Draws a frame into an offscreen `texture` and waits for it: the frame-time harness.
    /// Nil when the canvas is not on Metal.
    public func renderFrame(into texture: any MTLTexture) -> FrameTiming? {
        guard backend == .metal, let context, let commandBuffer = context.frameQueue.makeCommandBuffer() else {
            return nil
        }
        let start = CACurrentMediaTime()
        let tiles = encodeFrame(into: texture, commandBuffer: commandBuffer)
        commandBuffer.commit()
        let cpu = CACurrentMediaTime() - start
        commandBuffer.waitUntilCompleted()
        needsDisplay = false
        frameCompleted(succeeded: context.succeeded(commandBuffer))
        return FrameTiming(cpuSeconds: cpu, gpuSeconds: max(commandBuffer.gpuEndTime - commandBuffer.gpuStartTime, 0), tiles: tiles)
    }

    private func frameCompleted(succeeded: Bool) {
        if succeeded {
            consecutiveFailures = 0
        } else {
            recordFailure("frame command buffer failed")
        }
    }

    // MARK: Display link

    /// Drives frames from the display: a frame is drawn at the next refresh after
    /// `setNeedsDisplay`, up to 120 per second on ProMotion, and none while nothing changes.
    public func startDisplayLink() {
        guard displayLink == nil, backend == .metal else {
            return
        }
        let target = DisplayLinkTarget(canvas: self)
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = target
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = !needsDisplay
        link.add(to: .main, forMode: .common)
        displayLink = link
        displayLinkTarget = target
    }

    public func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
    }

    public var isDisplayLinkRunning: Bool { displayLink != nil }

    func displayLinkFired(_ drawable: any CAMetalDrawable) {
        if needsDisplay {
            _ = present(drawable)
        } else {
            displayLink?.isPaused = true
        }
    }

    // MARK: Fallback

    private func recordFailure(_ reason: String) {
        consecutiveFailures += 1
        if consecutiveFailures >= MetalTileCanvas.failureLimit {
            engageFallback(reason: "\(reason) \(consecutiveFailures) times in a row")
        }
    }

    /// Switches to the Core Graphics tile canvas for the same tile keys and logs why.
    private func engageFallback(reason: String) {
        MetalContext.logger.error("Metal tile canvas falling back to Core Graphics: \(reason, privacy: .public)")
        backend = .coreGraphics(reason: reason)
        stopDisplayLink()
        rasterTask?.cancel()
        rasterTask = nil
        atlas = nil
        renderer = nil
        metalLayer.removeFromSuperlayer()
        let canvas = TiledCanvasLayer(cache: TileCache(renderer: fallbackRenderer), backingScale: backingScale)
        layer.addSublayer(canvas.layer)
        fallbackCanvas = canvas
        if let displayList, let viewport {
            canvas.layer.frame = layer.bounds
            canvas.update(displayList: displayList, viewport: viewport)
        }
    }
}

/// One tile's quad for `tileVertex`: corners in clip space and the atlas slice.  Matches the
/// shader's `TileQuad` layout (48 bytes).
struct TileQuad {
    var topLeft: SIMD2<Float>
    var topRight: SIMD2<Float>
    var bottomLeft: SIMD2<Float>
    var bottomRight: SIMD2<Float>
    var slice: UInt32
    var padding: (UInt32, UInt32, UInt32) = (0, 0, 0)

    /// The tile-space `cell` placed through `toDevice` (tile space → drawable pixels) on a
    /// drawable of `surface` pixels.
    init(cell: Rect, toDevice: AffineTransform, surface: SIMD2<Double>, slice: Int) {
        func clip(_ x: Double, _ y: Double) -> SIMD2<Float> {
            let device = toDevice.apply(Point(x: x, y: y))
            return SIMD2(Float(device.x / surface.x * 2 - 1), Float(1 - device.y / surface.y * 2))
        }
        topLeft = clip(cell.minX, cell.minY)
        topRight = clip(cell.maxX, cell.minY)
        bottomLeft = clip(cell.minX, cell.maxY)
        bottomRight = clip(cell.maxX, cell.maxY)
        self.slice = UInt32(slice)
    }
}

/// The display link's delegate, forwarding refreshes to the canvas.  The link runs on the main
/// run loop, so the callback arrives on the main actor (checked at run time by the
/// `@preconcurrency` conformance).
@MainActor
private final class DisplayLinkTarget: NSObject, @preconcurrency CAMetalDisplayLinkDelegate {
    weak var canvas: MetalTileCanvas?

    init(canvas: MetalTileCanvas) {
        self.canvas = canvas
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        canvas?.displayLinkFired(update.drawable)
    }
}

extension MetalTileCanvas: InvalidationTarget {
    public var displayedCanvas: CanvasID? { displayList?.canvas }

    /// Takes the list after a coalesced change without dropping every tile, and repaints the
    /// tiles under `rects` (REND-004's batched delivery).
    public func apply(displayList newList: DisplayList?, invalidating rects: [Rect]) {
        if let newList {
            displayList = newList
            fallbackCanvas?.apply(displayList: newList, invalidating: [])
        }
        invalidate(pasteboardRects: rects)
    }
}
