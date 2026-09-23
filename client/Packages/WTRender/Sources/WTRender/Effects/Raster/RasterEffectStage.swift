// The raster stage (FX-009, FX-010, FX-011, FX-015's Feather; raster-effects.adoc, "Client"):
// the content drawn so far is rendered into a bitmap covering its bounds plus the effects'
// spread, at the resolved raster resolution on a grid anchored at the pasteboard origin, and the
// stage's operations run in order.  Each operation either adds a layer under the result (drop
// shadow, glow, outer bevel), adds one over it (inner shadow, inner glow), or replaces it (blur,
// sharpen, inner bevel, emboss, feather); the vector content stays vector until something
// replaces it.
//
// Units.  Blur and Unsharp radii are pixels at the object's raster resolution (the document's or
// its own), so the physical size of a blur does not change with the preview resolution;
// distances (offsets, widths, feather radius) are points; Shadow softness is the blur's reach in
// points (σ = softness / 3); Bevel softness 0 ... 10 blurs the height field by up to half the
// width.

import CoreGraphics
import CoreImage
import Foundation
import WTGeometry

enum RasterEffectStage {
    /// Grids larger than this on a side render at a coarser resolution.
    static let maxEdge = 4096

    /// How far past its content a raster node can paint, in points.
    static func spread(of node: RasterNode) -> Double {
        let docScale = node.settings.effectiveResolution / 72
        var total = 0.0
        for operation in node.operations {
            switch operation {
            case .blur(let blur):
                total += (blur.style == .gaussian ? 3 : 1) * blur.effectiveRadius / docScale
            case .sharpen(let sharpen):
                total += (sharpen.style == .unsharpMask ? 3 * sharpen.effectivePixelRadius : 2) / docScale
            case .shadow(let shadow):
                switch shadow.style {
                case .dropShadow, .glow: total += shadow.effectiveOffset + shadow.effectiveSoftness
                case .innerShadow, .innerGlow: break
                }
            case .bevelEmboss(let bevel):
                let sigma = bevel.effectiveSoftness * bevel.effectiveWidth / 20
                total += (bevel.style == .outerBevel ? bevel.effectiveWidth : 0) + 3 * sigma
            case .feather:
                break
            }
        }
        return total + 1
    }

    /// The node's images at `resolution` pixels per inch.  `drawContent` renders the content
    /// (pasteboard space) into a context whose user space is pasteboard points.
    static func render(_ node: RasterNode, resolution requested: Double, drawContent: (CGContext) -> Void) -> RasterResult? {
        guard let contentBounds = EffectNode.union(node.content) else {
            return nil
        }
        let area = contentBounds.expanded(by: spread(of: node))
        var resolution = requested
        var grid = RasterEffectStage.grid(area, resolution: resolution)
        while (grid.width > maxEdge || grid.height > maxEdge) && resolution > 0.01 {
            resolution /= 2
            grid = RasterEffectStage.grid(area, resolution: resolution)
        }
        guard grid.width > 0, grid.height > 0, let surface = BitmapSurface(width: grid.width, height: grid.height) else {
            return nil
        }
        let scale = resolution / 72
        let context = surface.context
        context.translateBy(x: 0, y: CGFloat(grid.height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -Double(grid.x0) / scale, y: -Double(grid.y0) / scale)
        drawContent(context)
        let rowBytes = context.bytesPerRow
        let source = context.data!.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: grid.width * grid.height * 4)
        for row in 0..<grid.height {
            for column in 0..<(grid.width * 4) {
                bytes[row * grid.width * 4 + column] = source[row * rowBytes + column]
            }
        }
        let content = RasterPixels(bytes: bytes, width: grid.width, height: grid.height)
        var state = StageState(content: content)
        let filters = RasterFilters(scale: scale, docScale: node.settings.effectiveResolution / 72, context: RasterCore.context(optimalCMYK: node.settings.optimalCMYK))
        for operation in node.operations {
            filters.apply(operation, to: &state)
        }
        let origin = Point(x: Double(grid.x0) / scale, y: Double(grid.y0) / scale)
        func image(_ pixels: RasterPixels) -> RasterImage {
            RasterImage(origin: origin, pixelSize: 1 / scale, width: pixels.width, height: pixels.height, bytes: pixels.bytes)
        }
        return RasterResult(below: state.below.map(image), replaced: state.replaced ? image(state.content) : nil, above: state.above.map(image))
    }

    /// The pixel grid covering `area` at `resolution`, anchored at the pasteboard origin.
    static func grid(_ area: Rect, resolution: Double) -> (x0: Int, y0: Int, width: Int, height: Int) {
        let scale = resolution / 72
        guard area.minX.isFinite, area.minY.isFinite, area.maxX.isFinite, area.maxY.isFinite,
              max(abs(area.minX), abs(area.minY), abs(area.maxX), abs(area.maxY)) * scale < 1e8
        else {
            return (0, 0, 0, 0)
        }
        let x0 = Int((area.minX * scale).rounded(.down))
        let y0 = Int((area.minY * scale).rounded(.down))
        let x1 = Int((area.maxX * scale).rounded(.up))
        let y1 = Int((area.maxY * scale).rounded(.up))
        return (x0, y0, max(x1 - x0, 0), max(y1 - y0, 0))
    }
}

/// What a raster stage has made so far.
struct StageState {
    var below: [RasterPixels] = []
    /// The content: its vector rendering until an operation replaces it.
    var content: RasterPixels
    var replaced = false
    var above: [RasterPixels] = []

    init(content: RasterPixels) {
        self.content = content
    }

    /// Everything composited: what the next operation works on.
    var flattened: RasterPixels {
        var result = RasterPixels(width: content.width, height: content.height)
        for layer in below {
            result.composite(over: layer)
        }
        result.composite(over: content)
        for layer in above {
            result.composite(over: layer)
        }
        return result
    }

    mutating func replace(with pixels: RasterPixels) {
        below = []
        above = []
        content = pixels
        replaced = true
    }
}
