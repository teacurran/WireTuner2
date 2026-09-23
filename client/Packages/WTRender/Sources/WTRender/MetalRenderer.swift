// The Metal tile renderer (REND-006; docs/spec/client.adoc, "Metal tile renderer"): the same
// display list, lowered by `PaintListBuilder` to polygons in device pixels, filled on the GPU
// by stencil-then-cover (D-006).  The stencil is a 16-sample winding counter per pixel in tile
// memory and the cover blends colour × coverage per pixel, as Core Graphics composites each
// draw (see TileShaders.msl).  Groups with a clip or a transparency layer draw into offscreen
// surfaces that are composited back through the clip's coverage at the group's opacity.

import WTGeometry
import CoreGraphics
import Foundation
import Metal

/// Draws display lists with Metal.  A value like `CoreGraphicsRenderer`: view mode and
/// overprint preview are renderer state, the shared `MetalContext` holds the GPU objects.
public struct MetalRenderer: WTRender {
    public let context: MetalContext
    public let flatteningTolerance: FlatteningTolerance
    /// Painted under the display list when set; nil leaves tiles transparent.
    public let background: Color?
    public var viewMode: ViewMode
    public var overprintPreview: Bool
    /// REND-007's self-test: swaps every declared fill rule, which must fail exactly the
    /// tiles the rule decides.
    var swapsFillRules = false

    /// The fraction of the shared tolerance this renderer flattens to.  The shared tolerance
    /// is the bound both renderers honour, but Core Graphics' scan converter subdivides curves
    /// well inside its flatness setting; flattening at the bound itself puts the two edges up
    /// to a quarter pixel apart (64/255 on a curve's tangent pixels), outside REND-007's edge
    /// tolerance.  A quarter of the bound keeps them within it.
    static let flatteningRefinement = 0.25

    public init(
        context: MetalContext,
        flatteningTolerance: FlatteningTolerance = .standard,
        background: Color? = nil,
        viewMode: ViewMode = .preview,
        overprintPreview: Bool = false
    ) {
        self.context = context
        self.flatteningTolerance = flatteningTolerance
        self.background = background
        self.viewMode = viewMode
        self.overprintPreview = overprintPreview
    }

    public func with(viewMode: ViewMode) -> MetalRenderer {
        var result = self
        result.viewMode = viewMode
        return result
    }

    public func with(overprintPreview: Bool) -> MetalRenderer {
        var result = self
        result.overprintPreview = overprintPreview
        return result
    }

    // MARK: WTRender

    public func render(_ displayList: DisplayList, viewport: Viewport, into context: CGContext) {
        let deviceTransform = context.userSpaceToDeviceSpaceTransform
        let scale = max(abs(deviceTransform.a * deviceTransform.d - deviceTransform.b * deviceTransform.c).squareRoot(), 1e-6)
        let width = Int((viewport.size.width * scale).rounded(.up))
        let height = Int((viewport.size.height * scale).rounded(.up))
        let transform = viewport.pasteboardToView.concatenating(.scale(scale))
        guard let image = renderImage(displayList, pasteboardTransform: transform, cull: viewport.visiblePasteboardBounds, width: width, height: height) else {
            return
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: Double(width) / scale, height: Double(height) / scale))
    }

    public func render(_ displayList: DisplayList, tile key: TileKey, geometry: TileGeometry, into context: CGContext) {
        guard let image = renderTile(displayList, key: key, geometry: geometry) else {
            return
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: geometry.tileSize, height: geometry.tileSize))
    }

    public func renderTile(_ displayList: DisplayList, key: TileKey, geometry: TileGeometry) -> CGImage? {
        renderImage(
            displayList,
            pasteboardTransform: geometry.pasteboardToTile(key),
            cull: geometry.pasteboardBounds(of: key),
            width: geometry.tileSize,
            height: geometry.tileSize
        )
    }

    // MARK: Offscreen images

    /// `displayList` through `pasteboardTransform` (pasteboard → device pixels) into a
    /// `width` × `height` image, read back from the GPU; nil when the surface cannot be made or
    /// the command buffer fails.
    func renderImage(_ displayList: DisplayList, pasteboardTransform: AffineTransform, cull: Rect, width: Int, height: Int) -> CGImage? {
        let operations = paintOperations(for: displayList, pasteboardTransform: pasteboardTransform, cull: cull, width: width, height: height)
        guard let surface = BitmapSurface(width: width, height: height),
              let target = makeReadableTexture(width: width, height: height),
              let commandBuffer = context.queue.makeCommandBuffer(),
              encode(operations, width: width, height: height, into: target, slice: 0, commandBuffer: commandBuffer)
        else {
            return nil
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard context.succeeded(commandBuffer), let data = surface.context.data else {
            return nil
        }
        target.getBytes(data, bytesPerRow: surface.context.bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return surface.makeImage()
    }

    /// A texture the CPU reads after the GPU draws into it (Apple-family GPUs share memory).
    private func makeReadableTexture(width: Int, height: Int) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.colorFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return context.device.makeTexture(descriptor: descriptor)
    }

    /// The lowered operations for a `width` × `height` device-pixel surface.
    func paintOperations(for displayList: DisplayList, pasteboardTransform: AffineTransform, cull: Rect, width: Int, height: Int) -> [PaintOperation] {
        let builder = PaintListBuilder(
            viewMode: viewMode,
            overprintPreview: overprintPreview,
            tolerance: FlatteningTolerance(devicePixels: flatteningTolerance.devicePixels * MetalRenderer.flatteningRefinement),
            surface: Rect(x: 0, y: 0, width: Double(width), height: Double(height)),
            swapsFillRules: swapsFillRules
        )
        return builder.operations(for: displayList, pasteboardTransform: pasteboardTransform, cull: cull)
    }

    // MARK: Encoding

    /// Encodes tile `key` into slice `slice` of the atlas array texture `atlas` on
    /// `commandBuffer` (not committed).  False when a surface cannot be allocated.
    func encodeTile(_ displayList: DisplayList, key: TileKey, geometry: TileGeometry, into atlas: any MTLTexture, slice: Int, commandBuffer: any MTLCommandBuffer) -> Bool {
        let edge = geometry.tileSize
        let operations = paintOperations(for: displayList, pasteboardTransform: geometry.pasteboardToTile(key), cull: geometry.pasteboardBounds(of: key), width: edge, height: edge)
        return encode(operations, width: edge, height: edge, into: atlas, slice: slice, commandBuffer: commandBuffer)
    }

    /// Encodes `operations` (from `paintOperations`) for a `width` × `height` surface into
    /// `slice` of `target`.
    func encode(_ operations: [PaintOperation], width: Int, height: Int, into target: any MTLTexture, slice: Int, commandBuffer: any MTLCommandBuffer) -> Bool {
        var geometry = PaintGeometry()
        let plan = geometry.plan(operations, width: Double(width), height: Double(height))
        var encoder = PaintEncoder(context: context, commandBuffer: commandBuffer, width: width, height: height)
        let clear = background.map { color in
            MTLClearColor(red: color.red * color.alpha, green: color.green * color.alpha, blue: color.blue * color.alpha, alpha: color.alpha)
        } ?? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        return encoder.prepare(geometry) && encoder.encode(plan, clear: clear, target: target, slice: slice)
    }
}

// MARK: - Geometry planning

/// A fan triangle for `fanVertex` (the shader's `FanTriangle`, 24 bytes).
struct FanTriangle {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var c: SIMD2<Float>
}

/// One fill: its fan triangles and cover quad in the shared buffers.
struct PlannedFill {
    var fan: Range<Int>
    var cover: Range<Int>
    var rule: FillRule
    var color: SIMD4<Float>
    var blend: PaintBlend
}

/// A group's children and how they are composited: through the clip's fan and cover (or the
/// whole surface) at `opacity`.
struct PlannedGroup {
    var children: [PlannedOperation]
    var clipFan: Range<Int>?
    var cover: Range<Int>
    var clipRule: FillRule
    var opacity: Float
}

indirect enum PlannedOperation {
    case fill(PlannedFill)
    case group(PlannedGroup)
}

/// Lays every fan triangle and cover quad of a paint list out in two arrays.
struct PaintGeometry {
    private(set) var triangles: [FanTriangle] = []
    private(set) var covers: [SIMD2<Float>] = []

    mutating func plan(_ operations: [PaintOperation], width: Double, height: Double) -> [PlannedOperation] {
        let surface = Rect(x: 0, y: 0, width: width, height: height)
        var result: [PlannedOperation] = []
        for operation in operations {
            switch operation {
            case .fill(let fill):
                let fan = appendFan(fill.path)
                let cover = appendQuad(fill.path.bounds!, in: surface)
                result.append(.fill(PlannedFill(fan: fan, cover: cover, rule: fill.rule, color: fill.color, blend: fill.blend)))
            case .group(let group):
                let children = plan(group.operations, width: width, height: height)
                if let clip = group.clip {
                    // An empty clip hides everything; its children are dropped.
                    guard let bounds = clip.bounds, !children.isEmpty else { continue }
                    let fan = appendFan(clip)
                    let cover = appendQuad(bounds, in: surface)
                    result.append(.group(PlannedGroup(children: children, clipFan: fan, cover: cover, clipRule: group.clipRule, opacity: Float(group.opacity))))
                } else if !children.isEmpty {
                    let cover = appendQuad(surface, in: surface)
                    result.append(.group(PlannedGroup(children: children, clipFan: nil, cover: cover, clipRule: .nonZero, opacity: Float(group.opacity))))
                }
            }
        }
        return result
    }

    /// Every contour as a fan from its first vertex.
    private mutating func appendFan(_ path: FlatPath) -> Range<Int> {
        let start = triangles.count
        triangles.reserveCapacity(start + path.fanTriangleCount)
        for contour in path.contours {
            let anchor = SIMD2<Float>(path.points[contour.lowerBound])
            var previous = SIMD2<Float>(path.points[contour.lowerBound + 1])
            for index in (contour.lowerBound + 2)..<contour.upperBound {
                let point = SIMD2<Float>(path.points[index])
                triangles.append(FanTriangle(a: anchor, b: previous, c: point))
                previous = point
            }
        }
        return start..<triangles.count
    }

    /// Two triangles over `rect` grown to whole pixels plus one (the fan's reach), clamped to
    /// `surface`.
    private mutating func appendQuad(_ rect: Rect, in surface: Rect) -> Range<Int> {
        let start = covers.count
        let minX = Float(max(rect.minX.rounded(.down) - 1, surface.minX))
        let minY = Float(max(rect.minY.rounded(.down) - 1, surface.minY))
        let maxX = Float(min(rect.maxX.rounded(.up) + 1, surface.maxX))
        let maxY = Float(min(rect.maxY.rounded(.up) + 1, surface.maxY))
        covers += [
            SIMD2(minX, minY), SIMD2(maxX, minY), SIMD2(minX, maxY),
            SIMD2(maxX, minY), SIMD2(maxX, maxY), SIMD2(minX, maxY),
        ]
        return start..<covers.count
    }
}

// MARK: - Pass encoding

/// The shader's `CoverUniforms`.
struct CoverUniforms {
    var color: SIMD4<Float>
    var rule: UInt32
    var blend: UInt32
    var opacity: Float
    var padding: UInt32 = 0

    static func rule(_ rule: FillRule) -> UInt32 {
        rule == .nonZero ? 0 : 1
    }

    /// No clip: the whole cover quad is covered.
    static let everything: UInt32 = 2
}

/// Encodes planned operations into render passes: one pass per surface, split around every
/// group (whose children render into their own surface first).  The winding counters live in
/// a memoryless attachment and are zero between paths, so every pass starts them cleared.
struct PaintEncoder {
    let context: MetalContext
    let commandBuffer: any MTLCommandBuffer
    let width: Int
    let height: Int
    private var triangleBuffer: (any MTLBuffer)?
    private var coverBuffer: (any MTLBuffer)?
    private var winding: (any MTLTexture)?
    /// Offscreen surfaces by group depth, reused by sibling groups.
    private var layers: [Int: any MTLTexture] = [:]

    init(context: MetalContext, commandBuffer: any MTLCommandBuffer, width: Int, height: Int) {
        self.context = context
        self.commandBuffer = commandBuffer
        self.width = width
        self.height = height
    }

    /// Uploads the geometry and makes the counter attachment; false when either fails.
    mutating func prepare(_ geometry: PaintGeometry) -> Bool {
        let device = context.device
        if !geometry.triangles.isEmpty {
            triangleBuffer = geometry.triangles.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        }
        if !geometry.covers.isEmpty {
            coverBuffer = geometry.covers.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.windingFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .memoryless
        winding = device.makeTexture(descriptor: descriptor)
        return winding != nil
            && (geometry.triangles.isEmpty || triangleBuffer != nil)
            && (geometry.covers.isEmpty || coverBuffer != nil)
    }

    mutating func encode(_ plan: [PlannedOperation], clear: MTLClearColor, target: any MTLTexture, slice: Int) -> Bool {
        encode(plan, depth: 0, clear: clear, target: target, slice: slice)
    }

    private mutating func encode(_ plan: [PlannedOperation], depth: Int, clear: MTLClearColor, target: any MTLTexture, slice: Int) -> Bool {
        guard var encoder = begin(target, slice: slice, load: .clear, clear: clear) else {
            return false
        }
        for operation in plan {
            switch operation {
            case .fill(let fill):
                draw(fill, with: encoder)
            case .group(let group):
                encoder.endEncoding()
                guard let layer = layerTexture(depth: depth + 1),
                      encode(group.children, depth: depth + 1, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0), target: layer, slice: 0),
                      let resumed = begin(target, slice: slice, load: .load, clear: clear)
                else {
                    return false
                }
                encoder = resumed
                composite(group, layer: layer, with: encoder)
            }
        }
        encoder.endEncoding()
        return true
    }

    private func begin(_ target: any MTLTexture, slice: Int, load: MTLLoadAction, clear: MTLClearColor) -> (any MTLRenderCommandEncoder)? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].slice = slice
        pass.colorAttachments[0].loadAction = load
        pass.colorAttachments[0].clearColor = clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[1].texture = winding
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[1].storeAction = .dontCare
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return nil
        }
        var surface = SIMD2<Float>(Float(width), Float(height))
        encoder.setVertexBuffer(triangleBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&surface, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setVertexBuffer(coverBuffer, offset: 0, index: 2)
        return encoder
    }

    /// Stencil: the fan's triangles, six vertices (a bounding quad) each.
    private func stencil(_ fan: Range<Int>, with encoder: any MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(context.fanPipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: fan.lowerBound * 6, vertexCount: fan.count * 6)
    }

    private func draw(_ fill: PlannedFill, with encoder: any MTLRenderCommandEncoder) {
        stencil(fill.fan, with: encoder)
        var uniforms = CoverUniforms(color: fill.color, rule: CoverUniforms.rule(fill.rule), blend: fill.blend == .multiply ? 1 : 0, opacity: 1)
        encoder.setRenderPipelineState(context.paintPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CoverUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: fill.cover.lowerBound, vertexCount: fill.cover.count)
    }

    private func composite(_ group: PlannedGroup, layer: any MTLTexture, with encoder: any MTLRenderCommandEncoder) {
        var rule = CoverUniforms.everything
        if let fan = group.clipFan {
            stencil(fan, with: encoder)
            rule = CoverUniforms.rule(group.clipRule)
        }
        var uniforms = CoverUniforms(color: .zero, rule: rule, blend: 0, opacity: group.opacity)
        encoder.setRenderPipelineState(context.layerPipeline)
        encoder.setFragmentTexture(layer, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CoverUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: group.cover.lowerBound, vertexCount: group.cover.count)
    }

    private mutating func layerTexture(depth: Int) -> (any MTLTexture)? {
        if let cached = layers[depth] {
            return cached
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.colorFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = context.device.makeTexture(descriptor: descriptor)
        layers[depth] = texture
        return texture
    }
}
