// Rendering separations (PRINT-007): the composite display list drawn once per plate by the
// Core Graphics reference renderer in plate mode, into a grayscale sheet -- black where the
// ink prints, at the ink's percentage.  The list is never rebuilt for a plate; only the
// renderer's `plate` changes.

import CoreGraphics
import Foundation
import WTGeometry

/// An 8-bit grayscale plate: 0 is full ink, 255 paper; row 0 at the top.
public struct GrayPlate: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "a plate has one byte per pixel")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A blank (white) plate.
    public init(width: Int, height: Int) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: 255, count: width * height))
    }

    /// The gray at column `x`, row `y`, clamped to the plate.
    public func gray(x: Int, y: Int) -> UInt8 {
        pixels[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
    }

    /// The ink coverage at (`x`, `y`), 0...1.
    public func coverage(x: Int, y: Int) -> Double {
        Double(255 - Int(gray(x: x, y: y))) / 255
    }

    /// The plate as a DeviceGray image.
    public func makeImage() -> CGImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// The gray channel of an opaque surface drawn in neutral grays (every channel equal).
    init(surface: BitmapSurface) {
        let base = surface.context.data!.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 255, count: surface.width * surface.height)
        for row in 0..<surface.height {
            let offset = row * surface.context.bytesPerRow
            for column in 0..<surface.width {
                pixels[row * surface.width + column] = base[offset + column * 4]
            }
        }
        self.init(width: surface.width, height: surface.height, pixels: pixels)
    }
}

/// Renders the plates of a separated job from one composite display list.
public struct PlateRenderer: Sendable {
    /// The composite renderer the plates are drawn with (its flattening tolerance, image store,
    /// raster settings).  Plates always draw in Preview, without overprint preview or proofing.
    public var base: CoreGraphicsRenderer
    public var spotAsProcess: Bool

    public init(base: CoreGraphicsRenderer = CoreGraphicsRenderer(), spotAsProcess: Bool = false) {
        self.base = base
        self.spotAsProcess = spotAsProcess
    }

    /// The renderer that draws `plate`: Preview, the sheet white, every colour mapped.
    public func renderer(for plate: Ink) -> CoreGraphicsRenderer {
        var renderer = base.with(viewMode: .preview).with(overprintPreview: false)
        renderer.colorManagement = ColorManagement(
            workingSpace: .sRGB,
            cmykProfile: base.colorManagement.cmykProfile,
            intent: base.colorManagement.intent,
            blackPointCompensation: base.colorManagement.blackPointCompensation,
            converter: base.colorManagement.converter
        )
        renderer.plate = PlateContext(plate: plate, spotAsProcess: spotAsProcess, colorManagement: renderer.colorManagement)
        renderer.greekTypeBelow = 0
        return renderer
    }

    /// `plate` of `displayList` over `viewport`, at `scale` device pixels per view point.
    public func renderPlate(_ displayList: DisplayList, plate: Ink, viewport: Viewport, scale: Double = 1) -> GrayPlate? {
        let width = Int((viewport.size.width * scale).rounded())
        let height = Int((viewport.size.height * scale).rounded())
        guard let surface = BitmapSurface(width: width, height: height) else {
            return nil
        }
        surface.context.scaleBy(x: scale, y: scale)
        renderer(for: plate).render(displayList, viewport: viewport, into: surface.context)
        return GrayPlate(surface: surface)
    }

    /// Every plate in `plates`, in that order.
    public func renderPlates(_ displayList: DisplayList, plates: [Ink], viewport: Viewport, scale: Double = 1) -> [(ink: Ink, plate: GrayPlate)] {
        plates.compactMap { ink in
            renderPlate(displayList, plate: ink, viewport: viewport, scale: scale).map { (ink, $0) }
        }
    }

    /// Draws `plate` into `context` (a PDF or print sheet) through `viewport`: the sheet's
    /// grays as neutral sRGB colours.
    public func drawPlate(_ displayList: DisplayList, plate: Ink, viewport: Viewport, into context: CGContext) {
        renderer(for: plate).render(displayList, viewport: viewport, into: context)
    }

    /// The plates a list prints on: the four process inks, then every spot ink it uses in
    /// first-use order (none with *Print spot colors as process*).  WTModel orders spot plates
    /// by swatch order; this is the fallback for lists printed without a plate list.
    public func inks(in displayList: DisplayList) -> [Ink] {
        guard !spotAsProcess else {
            return Ink.process
        }
        var spots: [NodeID] = []
        var seen: Set<NodeID> = []
        func note(_ color: Color) {
            if case .swatch(let id)? = color.spot?.identity, seen.insert(id).inserted {
                spots.append(id)
            }
        }
        for color in displayList.items.flatMap(\.colors) {
            note(color)
        }
        return Ink.process + spots.map(Ink.spot)
    }
}

extension DisplayItem {
    /// Every colour the item paints with, in drawing order (solid paints, sampled paints'
    /// colours, text), descending into groups and tiles.
    var colors: [Color] {
        switch self {
        case .fill(let item): return item.paint.colors
        case .stroke(let item): return item.paint.colors
        case .path(let item):
            return item.appearance.items.flatMap { element -> [Color] in
                switch element {
                case .fill(let fill): return fill.paint.colors
                case .stroke(let stroke): return stroke.paint.colors
                }
            }
        case .image(let item): return item.tint.map { [$0] } ?? []
        case .text(let item): return [item.color]
        case .group(let group): return group.children.flatMap(\.colors)
        }
    }
}

extension Paint {
    /// The colours the paint samples.
    var colors: [Color] {
        switch self {
        case .none: return []
        case .solid(let color): return [color]
        case .gradient(let gradient): return gradient.stops.map(\.color)
        case .pattern(let pattern): return [pattern.color]
        case .custom(let custom): return [custom.color, custom.color2]
        case .textured(let textured): return [textured.color]
        case .tiled(let tiled): return tiled.tile.flatMap(\.colors)
        case .lens(let lens): return [lens.color]
        }
    }
}
