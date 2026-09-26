// The bitmap rasterizer (export-bitmap.adoc, "Client"; IO-021).  A page is rendered by WTRender's
// Core Graphics reference renderer -- the renderer the screen is held to -- into bitmap contexts of
// the target size times the anti-aliasing factor and box-downsampled.  Output is produced in bands
// of tiles at most 2048 samples on a side, so peak memory is one band of output plus one tile of
// samples however large the export; encoders pull the bands as they write.

import CoreGraphics
import Foundation
import WTGeometry
import WTRender

/// A rendered bitmap whose rows are produced band by band on demand.
public final class RasterBitmap: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// 8 or 16.
    public let bitsPerComponent: Int
    /// Stored components per pixel (RGB with alpha or padding 4, grey 1, CMYK 4).
    public let components: Int
    public let hasAlpha: Bool
    public let colorSpace: CGColorSpace
    let bitmapInfo: CGBitmapInfo
    /// Rows per band.
    let bandHeight: Int
    private let renderBand: (Int) -> Data

    init(width: Int, height: Int, bitsPerComponent: Int, components: Int, hasAlpha: Bool, colorSpace: CGColorSpace, bitmapInfo: CGBitmapInfo, bandHeight: Int, renderBand: @escaping (Int) -> Data) {
        self.width = width
        self.height = height
        self.bitsPerComponent = bitsPerComponent
        self.components = components
        self.hasAlpha = hasAlpha
        self.colorSpace = colorSpace
        self.bitmapInfo = bitmapInfo
        self.bandHeight = bandHeight
        self.renderBand = renderBand
    }

    public var bytesPerRow: Int { width * components * bitsPerComponent / 8 }

    public var bandCount: Int { (height + bandHeight - 1) / bandHeight }

    /// The rows of band `index` (`bandHeight` rows, fewer in the last band).
    public func band(_ index: Int) -> Data {
        renderBand(index)
    }

    /// The bitmap as an image whose pixels are rendered as a reader pulls them.
    public var image: CGImage {
        let reader = BandReader(bitmap: self)
        var callbacks = CGDataProviderSequentialCallbacks(
            version: 0,
            getBytes: { info, buffer, count in
                Unmanaged<BandReader>.fromOpaque(info!).takeUnretainedValue().read(into: buffer, count: count)
            },
            skipForward: { info, count in
                off_t(Unmanaged<BandReader>.fromOpaque(info!).takeUnretainedValue().skip(Int(count)))
            },
            rewind: { info in
                Unmanaged<BandReader>.fromOpaque(info!).takeUnretainedValue().rewind()
            },
            releaseInfo: { info in
                Unmanaged<BandReader>.fromOpaque(info!).release()
            }
        )
        let provider = CGDataProvider(sequentialInfo: Unmanaged.passRetained(reader).toOpaque(), callbacks: &callbacks)!
        return CGImage(width: width, height: height, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerComponent * components, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

/// Sequential access to a bitmap's bytes, one band held at a time.
final class BandReader {
    let bitmap: RasterBitmap
    private var position = 0
    private var bandIndex = -1
    private var bandData = Data()

    init(bitmap: RasterBitmap) {
        self.bitmap = bitmap
    }

    var total: Int { bitmap.bytesPerRow * bitmap.height }

    func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        var written = 0
        let bandBytes = bitmap.bytesPerRow * bitmap.bandHeight
        while written < count && position < total {
            let index = position / bandBytes
            if index != bandIndex {
                bandData = bitmap.band(index)
                bandIndex = index
            }
            let offset = position - index * bandBytes
            let length = min(count - written, bandData.count - offset)
            bandData.withUnsafeBytes { source in
                (buffer + written).copyMemory(from: source.baseAddress! + offset, byteCount: length)
            }
            written += length
            position += length
        }
        return written
    }

    func skip(_ count: Int) -> Int {
        let skipped = min(count, total - position)
        position += skipped
        return skipped
    }

    func rewind() {
        position = 0
    }
}

/// Renders pages to bitmaps.
public struct BitmapRasterizer: Sendable {
    /// The largest edge of a tile of samples.
    public static let tileSamples = 2048

    public var common: BitmapCommonOptions
    /// The document's colour for output (CMS-011): the working profiles pages render into and
    /// are tagged with, and Working CMYK for CMYK colours.  Nil renders as before (sRGB or
    /// Display P3, Generic CMYK, generic gray).
    public var output: WTColor.OutputContext?
    /// The renderer whose image store and colour management tiles draw with (a window's, for
    /// *Rasterize*); nil draws with a fresh one (placed images as placeholders).
    public var base: CoreGraphicsRenderer?

    public init(common: BitmapCommonOptions, output: WTColor.OutputContext? = nil, base: CoreGraphicsRenderer? = nil) {
        self.common = common
        self.output = output
        self.base = base
    }

    /// The output space a page renders into, and how many colours were outside it.
    struct ColorSetup {
        var space: CGColorSpace
        /// The space written with the file (nil: no profile).
        var tag: CGColorSpace
        var clipped: Int
    }

    func colorSetup(for page: ExportPage) -> ColorSetup {
        switch common.color {
        case .gray:
            let space = output?.colorSpace(model: .gray) ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
            return ColorSetup(space: space, tag: common.embedProfile ? space : CGColorSpaceCreateDeviceGray(), clipped: 0)
        case .cmyk:
            let space = output?.colorSpace(model: .cmyk) ?? CGColorSpace(name: CGColorSpace.genericCMYK)!
            return ColorSetup(space: space, tag: common.embedProfile ? space : CGColorSpaceCreateDeviceCMYK(), clipped: 0)
        case .rgb:
            let wide = WideColorScan.count(in: page.displayList)
            var p3: Bool
            switch common.rgbSpace {
            case .auto: p3 = wide > 0
            case .displayP3: p3 = true
            case .sRGB, .workingRGB: p3 = false
            }
            // Without an embedded profile a file reads as sRGB, so the artwork is pulled into it.
            if !common.embedProfile {
                p3 = false
            }
            var space = CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
            // Working RGB from the document when it is known, unless the artwork needs Display P3.
            if let output, common.embedProfile, common.rgbSpace == .workingRGB || (common.rgbSpace == .auto && !p3) {
                space = output.colorSpace(model: .rgb)
            }
            return ColorSetup(space: space, tag: common.embedProfile ? space : CGColorSpaceCreateDeviceRGB(), clipped: p3 ? 0 : wide)
        }
    }

    /// The pixel size of `page` at `scale`.
    public func pixelSize(of page: ExportPage, scale: Double) -> (width: Int, height: Int) {
        let factor = common.ppi / 72 * scale
        return (max(Int((page.bounds.width * factor).rounded()), 1), max(Int((page.bounds.height * factor).rounded()), 1))
    }

    /// `page` rendered at `scale` with `bitsPerComponent` (8 or 16) and an alpha channel when
    /// `alpha` (RGB only).  The second value counts colours clipped into sRGB.
    public func render(_ page: ExportPage, scale: Double, bitsPerComponent: Int, alpha: Bool) -> (bitmap: RasterBitmap, clipped: Int) {
        let setup = colorSetup(for: page)
        let (width, height) = pixelSize(of: page, scale: scale)
        let factor = common.antiAliasing
        let tile = max(BitmapRasterizer.tileSamples / factor, 1)
        let alphaChannel = alpha && common.color == .rgb
        let components = common.color == .gray ? 1 : 4
        var info: UInt32
        switch (common.color, alphaChannel) {
        case (.rgb, true): info = CGImageAlphaInfo.premultipliedLast.rawValue
        case (.rgb, false): info = CGImageAlphaInfo.noneSkipLast.rawValue
        default: info = CGImageAlphaInfo.none.rawValue
        }
        if bitsPerComponent == 16 {
            info |= CGImageByteOrderInfo.order16Little.rawValue
        }
        let background: Color?
        switch common.background {
        case .transparent where alphaChannel: background = nil
        case .pageColor: background = page.background.map { OpaqueCompositor.over($0, .white) } ?? .white
        default: background = .white
        }
        let pixelsPerPoint = common.ppi / 72 * scale
        let job = BandJob(
            page: page, width: width, height: height, tile: tile, factor: factor, components: components,
            bitsPerComponent: bitsPerComponent, bitmapInfo: info, space: setup.space, background: background,
            pixelsPerPoint: pixelsPerPoint, overprint: common.simulateOverprint, mask: alphaChannel ? common.maskLayer : nil,
            base: base ?? output.map { CoreGraphicsRenderer().with(colorManagement: ColorManagement(cmykProfile: $0.cmykProfile, intent: $0.intent, blackPointCompensation: $0.blackPointCompensation, converter: $0.converter)) }
        )
        let bitmap = RasterBitmap(
            width: width, height: height, bitsPerComponent: bitsPerComponent, components: components, hasAlpha: alphaChannel,
            colorSpace: setup.tag, bitmapInfo: CGBitmapInfo(rawValue: info), bandHeight: tile, renderBand: job.band
        )
        return (bitmap, setup.clipped)
    }
}

/// Everything a band needs; value semantics so a bitmap can render bands on any thread.
struct BandJob: @unchecked Sendable {
    let page: ExportPage
    let width: Int
    let height: Int
    let tile: Int
    let factor: Int
    let components: Int
    let bitsPerComponent: Int
    let bitmapInfo: UInt32
    let space: CGColorSpace
    let background: Color?
    let pixelsPerPoint: Double
    let overprint: Bool
    let mask: DisplayList?
    /// The renderer tiles copy their image store and colour management from.
    var base: CoreGraphicsRenderer? = nil

    var bytesPerComponent: Int { bitsPerComponent / 8 }

    /// Band `index`'s rows, `components` × `bytesPerComponent` bytes a pixel.
    func band(_ index: Int) -> Data {
        let top = index * tile
        let rows = min(tile, height - top)
        let rowBytes = width * components * bytesPerComponent
        var output = Data(count: rowBytes * rows)
        var left = 0
        while left < width {
            let columns = min(tile, width - left)
            let samples = renderTile(left: left, top: top, columns: columns, rows: rows, list: page.displayList, background: background, space: space, info: bitmapInfo, components: components)
            let coverage = mask.map { renderTile(left: left, top: top, columns: columns, rows: rows, list: $0, background: .black, space: CGColorSpaceCreateDeviceGray(), info: CGImageAlphaInfo.none.rawValue | (bitsPerComponent == 16 ? CGImageByteOrderInfo.order16Little.rawValue : 0), components: 1) }
            output.withUnsafeMutableBytes { buffer in
                downsample(samples, mask: coverage, columns: columns, rows: rows, into: buffer, offset: left * components * bytesPerComponent, rowBytes: rowBytes)
            }
            left += columns
        }
        return output
    }

    /// One tile of samples, `factor` per pixel each way, as integers per component.
    func renderTile(left: Int, top: Int, columns: Int, rows: Int, list: DisplayList, background: Color?, space: CGColorSpace, info: UInt32, components: Int) -> [UInt32] {
        let sampleWidth = columns * factor
        let sampleHeight = rows * factor
        // Tiles are at most 2048 samples a side in a supported format: the context exists.
        let context = CGContext(data: nil, width: sampleWidth, height: sampleHeight, bitsPerComponent: bitsPerComponent, bytesPerRow: 0, space: space, bitmapInfo: info)!
        if factor == 1 {
            context.setShouldAntialias(false)
        }
        let scale = pixelsPerPoint * Double(factor)
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        let origin = Point(x: page.bounds.minX + Double(left) / pixelsPerPoint, y: page.bounds.minY + Double(top) / pixelsPerPoint)
        let viewport = Viewport(scrollOrigin: origin, zoom: 1, size: Size(width: Double(sampleWidth) / scale, height: Double(sampleHeight) / scale))
        var renderer = CoreGraphicsRenderer(background: background, overprintPreview: overprint)
        if let base {
            renderer.imageStore = base.imageStore
            renderer.colorManagement = base.colorManagement
        }
        renderer.rasterPreview = .document
        renderer.render(list, viewport: viewport, into: context)
        let stride = context.bytesPerRow / bytesPerComponent
        let rowLength = sampleWidth * components
        var compact = [UInt32](repeating: 0, count: rowLength * sampleHeight)
        let data = context.data!
        if bytesPerComponent == 2 {
            let words = data.assumingMemoryBound(to: UInt16.self)
            for row in 0..<sampleHeight {
                for index in 0..<rowLength {
                    compact[row * rowLength + index] = UInt32(UInt16(littleEndian: words[row * stride + index]))
                }
            }
        } else {
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            for row in 0..<sampleHeight {
                for index in 0..<rowLength {
                    compact[row * rowLength + index] = UInt32(bytes[row * stride + index])
                }
            }
        }
        return compact
    }

    /// Box-averages `factor` × `factor` samples per pixel into the band buffer; with a mask, each
    /// pixel's components (premultiplied) scale by the mask's luminance.
    func downsample(_ samples: [UInt32], mask: [UInt32]?, columns: Int, rows: Int, into buffer: UnsafeMutableRawBufferPointer, offset: Int, rowBytes: Int) {
        let sampleWidth = columns * factor
        let area = UInt32(factor * factor)
        let maximum = UInt32(bitsPerComponent == 16 ? 65535 : 255)
        for row in 0..<rows {
            for column in 0..<columns {
                var coverage = maximum
                if let mask {
                    var sum: UInt32 = 0
                    for dy in 0..<factor {
                        for dx in 0..<factor {
                            sum += mask[(row * factor + dy) * sampleWidth + column * factor + dx]
                        }
                    }
                    coverage = (sum + area / 2) / area
                }
                for channel in 0..<components {
                    var sum: UInt32 = 0
                    for dy in 0..<factor {
                        for dx in 0..<factor {
                            sum += samples[((row * factor + dy) * sampleWidth + column * factor + dx) * components + channel]
                        }
                    }
                    var value = (sum + area / 2) / area
                    if mask != nil {
                        value = UInt32((UInt64(value) * UInt64(coverage) + UInt64(maximum / 2)) / UInt64(maximum))
                    }
                    let position = offset + row * rowBytes + (column * components + channel) * bytesPerComponent
                    if bytesPerComponent == 2 {
                        let little = UInt16(value).littleEndian
                        buffer[position] = UInt8(little & 0xFF)
                        buffer[position + 1] = UInt8(little >> 8)
                    } else {
                        buffer[position] = UInt8(value)
                    }
                }
            }
        }
    }
}

/// Counts the distinct colours of a display list that lie outside sRGB.
enum WideColorScan {
    static func count(in list: DisplayList) -> Int {
        var colors = Set<Color>()
        for item in list.items {
            collect(item, into: &colors)
        }
        return colors.filter(ColorMath.isWide).count
    }

    static func collect(_ item: DisplayItem, into colors: inout Set<Color>) {
        switch item {
        case .fill(let fill): collect(fill.paint, into: &colors)
        case .stroke(let stroke): collect(stroke.paint, into: &colors)
        case .path(let path):
            for element in path.appearance.items {
                switch element {
                case .fill(let fill): collect(fill.paint, into: &colors)
                case .stroke(let stroke): collect(stroke.paint, into: &colors)
                }
            }
        case .text(let text): colors.insert(text.color)
        case .group(let group):
            for child in group.children {
                collect(child, into: &colors)
            }
        case .image: break
        }
    }

    static func collect(_ paint: Paint, into colors: inout Set<Color>) {
        switch paint {
        case .solid(let color): colors.insert(color)
        case .gradient(let gradient): colors.formUnion(gradient.stops.map(\.color))
        default: break
        }
    }
}
