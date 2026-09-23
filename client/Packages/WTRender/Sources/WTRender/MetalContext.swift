// The Metal objects the tile renderer shares across tiles, canvases and threads (REND-006):
// device, command queues, the shader library compiled from the bundled `TileShaders.msl`,
// pipeline states and stencil states.  All of these are immutable and thread-safe once built.

import Foundation
import Metal
import os

/// A Metal device prepared for tile rendering.  Nil from `init(device:)` when there is no
/// device, the device lacks programmable blending (not an Apple-family GPU), or the shaders do
/// not compile, which is exactly when the Core Graphics fallback takes over.
public final class MetalContext: @unchecked Sendable {
    /// Tile and layer surfaces: premultiplied RGBA8, byte-compatible with `BitmapSurface`.
    static let colorFormat = MTLPixelFormat.rgba8Unorm
    /// The per-sample winding counters: 16 samples × 8 bits in tile memory.
    static let windingFormat = MTLPixelFormat.rgba32Uint

    static let logger = Logger(subsystem: "com.villagecompute.wiretuner", category: "render")

    public let device: any MTLDevice
    /// Tile rasterization.
    let queue: any MTLCommandQueue
    /// Frame composition, separate so a frame never queues behind rasterization.
    let frameQueue: any MTLCommandQueue
    /// Stencil: fan triangles into the winding counters.
    let fanPipeline: any MTLRenderPipelineState
    /// Cover: solid paint through the counters.
    let paintPipeline: any MTLRenderPipelineState
    /// Cover: a group's surface through its clip's counters.
    let layerPipeline: any MTLRenderPipelineState
    /// Cover: a paint texture through the region's counters.
    let texturePipeline: any MTLRenderPipelineState
    let library: any MTLLibrary

    private let lock = NSLock()
    private var tilePipelines: [MTLPixelFormat: any MTLRenderPipelineState] = [:]
    private var injectedFailures = 0

    /// The context over the system default device, built once; nil on a Mac without a usable
    /// GPU.
    public static let shared: MetalContext? = MetalContext(device: MTLCreateSystemDefaultDevice())

    /// The shader source bundled with the package.
    static func shaderSource() -> String? {
        Bundle.module.url(forResource: "TileShaders", withExtension: "msl").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    public convenience init?(device: (any MTLDevice)?) {
        self.init(device: device, shaderSource: MetalContext.shaderSource())
    }

    init?(device: (any MTLDevice)?, shaderSource: String?) {
        guard let device else {
            MetalContext.logger.notice("no Metal device")
            return nil
        }
        // Programmable blending (reading the target in the fragment shader) and memoryless
        // attachments are Apple-family features; raster order groups order the reads.
        guard device.supportsFamily(.apple4), device.areRasterOrderGroupsSupported,
              let shaderSource,
              let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let queue = device.makeCommandQueue(),
              let frameQueue = device.makeCommandQueue()
        else {
            MetalContext.logger.error("Metal device \(device.name, privacy: .public) cannot run the tile renderer: it needs an Apple-family GPU and the bundled shaders")
            return nil
        }
        self.device = device
        self.library = library
        self.queue = queue
        self.frameQueue = frameQueue
        queue.label = "WTRender.tiles"
        frameQueue.label = "WTRender.frames"

        func pipeline(vertex: String, fragment: String, writesColor: Bool) -> (any MTLRenderPipelineState)? {
            guard let vertexFunction = library.makeFunction(name: vertex),
                  let fragmentFunction = library.makeFunction(name: fragment)
            else {
                return nil
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = MetalContext.colorFormat
            descriptor.colorAttachments[0].writeMask = writesColor ? .all : []
            descriptor.colorAttachments[1].pixelFormat = MetalContext.windingFormat
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let fan = pipeline(vertex: "fanVertex", fragment: "fanFragment", writesColor: false),
              let paint = pipeline(vertex: "coverVertex", fragment: "paintFragment", writesColor: true),
              let layer = pipeline(vertex: "coverVertex", fragment: "layerFragment", writesColor: true),
              let texture = pipeline(vertex: "coverVertex", fragment: "texturePaintFragment", writesColor: true)
        else {
            MetalContext.logger.error("Metal tile pipelines unavailable")
            return nil
        }
        fanPipeline = fan
        paintPipeline = paint
        layerPipeline = layer
        texturePipeline = texture
    }

    static func configureSourceOver(_ attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    /// The frame-composition pipeline for drawables of `pixelFormat`, built on first use.
    func tilePipeline(for pixelFormat: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = tilePipelines[pixelFormat] {
            return cached
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "tileVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "tileFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        MetalContext.configureSourceOver(descriptor.colorAttachments[0])
        let state = try? device.makeRenderPipelineState(descriptor: descriptor)
        tilePipelines[pixelFormat] = state
        return state
    }

    // MARK: Command buffer health

    /// Makes the next `count` command buffers report failure, as a GPU fault would; the test
    /// harness's route to the fallback without a broken GPU.
    func injectCommandBufferFailures(_ count: Int) {
        lock.lock()
        injectedFailures = max(count, 0)
        lock.unlock()
    }

    /// Whether `commandBuffer` (already completed) succeeded.
    func succeeded(_ commandBuffer: any MTLCommandBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if injectedFailures > 0 {
            injectedFailures -= 1
            return false
        }
        if commandBuffer.status != .completed {
            MetalContext.logger.error("Metal command buffer failed: \(String(describing: commandBuffer.error), privacy: .public)")
            return false
        }
        return true
    }
}
