// The Photoshop exporter (IO-023): one PSD (or PSB) per page and scale.  Every layer renders
// through the bitmap rasterizer with a transparent background, so its pixels match the bitmap
// export exactly.  Core Graphics has no alpha for grey and CMYK contexts, so in those modes a layer
// renders twice: in RGB for its transparency, and in the target space over the colour that
// composites to "premultiplied" there (black for grey, no ink for CMYK), divided by the alpha.

import CoreGraphics
import Foundation
import WTGeometry
import WTRender

public struct PSDExporter: Exporter {
    public init() {}

    public var format: ExportFormat { .psd }
    public var optionsType: any ExportOptions.Type { PSDOptions.self }
    public var capabilities: ExportCapabilities { ExportFormat.psd.capabilities }

    func validate(_ options: PSDOptions) throws {
        try options.common.validate()
        guard options.bitsPerChannel == 8 || options.bitsPerChannel == 16 else {
            throw ExportError.invalidOption("Photoshop bit depth must be 8 or 16 bits per channel.")
        }
        if options.common.background == .transparent && options.common.color != .rgb {
            throw ExportError.unsupported(.alpha, format: .psd)
        }
    }

    /// Page `index` of `scene` at `scale` as a PSD or PSB file.
    public func data(scene: ExportScene, page index: Int, scale: Double = 1, options: PSDOptions) throws -> Data {
        try validate(options)
        guard scene.pages.indices.contains(index) else {
            throw ExportError.nothingToExport
        }
        let page = scene.pages[index]
        let depth = options.bitsPerChannel
        let common = options.common
        let rasterizer = BitmapRasterizer(common: common)
        let (width, height) = rasterizer.pixelSize(of: page, scale: scale)
        let transparent = common.background == .transparent
        let render = rasterizer.render(page, scale: scale, bitsPerComponent: depth, alpha: transparent)
        let composite = PSDExporter.samples(render.bitmap)
        var compositeChannels = PSDExporter.colorChannels(composite, mode: common.color, alpha: nil)
        if transparent {
            compositeChannels.append(PSDChannel(id: -1, data: PSDExporter.bytes(composite.alpha, depth: depth)))
        }
        var layers: [PSDLayer] = []
        for source in PSDWriter.layerSources(of: page, scene: scene, layered: options.layers) {
            layers.append(layer(source, common: common, scale: scale, depth: depth))
        }
        let profile = common.embedProfile ? render.bitmap.colorSpace.copyICCData() as Data? : nil
        return PSDWriter.data(
            width: width, height: height, depth: depth, mode: common.color, layers: layers, composite: compositeChannels,
            resolution: common.ppi * scale, profile: profile, xmp: scene.info.isEmpty ? nil : XMPPacket.data(scene.info, format: "image/vnd.adobe.photoshop")
        )
    }

    /// One layer: rendered transparent, cropped to where it draws.
    func layer(_ source: PSDLayerSource, common: BitmapCommonOptions, scale: Double, depth: Int) -> PSDLayer {
        var rgb = common
        rgb.color = .rgb
        rgb.background = .transparent
        rgb.maskLayer = nil
        let shape = PSDExporter.samples(BitmapRasterizer(common: rgb).render(source.page, scale: scale, bitsPerComponent: depth, alpha: true).bitmap)
        var color = shape
        if common.color != .rgb {
            // Grey over black and CMYK over no ink leave each colour multiplied by its alpha.
            var target = common
            var page = source.page
            target.maskLayer = nil
            if common.color == .gray {
                target.background = .pageColor
                page.background = .black
            } else {
                target.background = .white
            }
            color = PSDExporter.samples(BitmapRasterizer(common: target).render(page, scale: scale, bitsPerComponent: depth, alpha: false).bitmap)
        }
        // The rectangle where the layer has any coverage.
        var top = shape.height, left = shape.width, bottom = 0, right = 0
        for y in 0..<shape.height {
            for x in 0..<shape.width where shape.alpha[y * shape.width + x] > 0 {
                top = min(top, y)
                bottom = max(bottom, y + 1)
                left = min(left, x)
                right = max(right, x + 1)
            }
        }
        if bottom == 0 {
            (top, left, bottom, right) = (0, 0, 0, 0)
        }
        let cropped = color.cropped(top: top, left: left, bottom: bottom, right: right, alpha: shape)
        var channels = PSDExporter.colorChannels(cropped, mode: common.color, alpha: cropped.alpha)
        channels.insert(PSDChannel(id: -1, data: PSDExporter.bytes(cropped.alpha, depth: depth)), at: 0)
        return PSDLayer(name: source.name, opacity: source.opacity, top: top, left: left, bottom: bottom, right: right, channels: channels)
    }

    public func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination) throws -> ExportSummary {
        let options = try typed(options, as: PSDOptions.self)
        try validate(options)
        guard !scene.pages.isEmpty else {
            throw ExportError.nothingToExport
        }
        var destination = destination
        let scales = options.common.scales
        if scales.count > 1, let pattern = destination.namePattern, !pattern.rawValue.contains("{scale}") {
            destination.namePattern = FileNamePattern(pattern.rawValue + "{scale}")
        }
        let jobs = scene.pages.indices.flatMap { page in scales.map { (page, $0) } }
        let urls = try destination.urls(count: jobs.count, format: .psd) { index in
            FileNamePattern.Values(name: scene.name, page: jobs[index].0 + 1, pageName: scene.pages[jobs[index].0].name, scale: jobs[index].1)
        }
        var summary = ExportSummary()
        for ((page, scale), url) in zip(jobs, urls) {
            let data = try data(scene: scene, page: page, scale: scale, options: options)
            do {
                try data.write(to: url)
            } catch {
                throw ExportError.writeFailed(error.localizedDescription)
            }
            summary.files.append(url)
        }
        return summary
    }

    // MARK: Samples

    /// A bitmap's samples as integers: colour components (premultiplied when there is alpha)
    /// and the alpha, per pixel.
    struct Samples {
        var width: Int
        var height: Int
        var components: Int
        /// `components` values per pixel.
        var color: [UInt32]
        /// One value per pixel (the maximum where the bitmap has no alpha).
        var alpha: [UInt32]
        var maximum: UInt32

        /// The rectangle `top ..< bottom`, `left ..< right`, colours divided by `shape`'s alpha
        /// (straight colour, as Photoshop layers store it), alpha taken from `shape`.
        func cropped(top: Int, left: Int, bottom: Int, right: Int, alpha shape: Samples) -> Samples {
            let w = right - left, h = bottom - top
            var colors = [UInt32]()
            var alphas = [UInt32]()
            colors.reserveCapacity(w * h * components)
            alphas.reserveCapacity(w * h)
            for y in top..<bottom {
                for x in left..<right {
                    let pixel = y * width + x
                    let a = shape.alpha[pixel]
                    alphas.append(a)
                    for channel in 0..<components {
                        let value = color[pixel * components + channel]
                        colors.append(a == 0 ? 0 : min(maximum, (value * maximum + a / 2) / a))
                    }
                }
            }
            return Samples(width: w, height: h, components: components, color: colors, alpha: alphas, maximum: maximum)
        }
    }

    static func samples(_ bitmap: RasterBitmap) -> Samples {
        let colorComponents = bitmap.components == 1 ? 1 : (bitmap.colorSpace.model == .cmyk ? 4 : 3)
        let maximum: UInt32 = bitmap.bitsPerComponent == 16 ? 65535 : 255
        var color = [UInt32]()
        var alpha = [UInt32]()
        color.reserveCapacity(bitmap.width * bitmap.height * colorComponents)
        alpha.reserveCapacity(bitmap.width * bitmap.height)
        let bytes = bitmap.bitsPerComponent / 8
        for band in 0..<bitmap.bandCount {
            let data = [UInt8](bitmap.band(band))
            let pixelBytes = bitmap.components * bytes
            for offset in stride(from: 0, to: data.count, by: pixelBytes) {
                func sample(_ index: Int) -> UInt32 {
                    let base = offset + index * bytes
                    return bytes == 2 ? UInt32(data[base]) | UInt32(data[base + 1]) << 8 : UInt32(data[base])
                }
                for channel in 0..<colorComponents {
                    color.append(sample(channel))
                }
                alpha.append(bitmap.hasAlpha ? sample(3) : maximum)
            }
        }
        return Samples(width: bitmap.width, height: bitmap.height, components: colorComponents, color: color, alpha: alpha, maximum: maximum)
    }

    /// The colour channels of `samples` in Photoshop's order and convention: CMYK inverted
    /// (Photoshop stores 0 as full ink).  The composite's colours are straightened by `alpha`
    /// when given (nil: already straight or opaque).
    static func colorChannels(_ samples: Samples, mode: BitmapCommonOptions.ColorMode, alpha: [UInt32]?) -> [PSDChannel] {
        var straight = samples
        if alpha == nil, samples.alpha.contains(where: { $0 < samples.maximum }) {
            straight = samples.cropped(top: 0, left: 0, bottom: samples.height, right: samples.width, alpha: samples)
        }
        let depth = samples.maximum == 65535 ? 16 : 8
        return (0..<samples.components).map { channel in
            var values = stride(from: channel, to: straight.color.count, by: samples.components).map { straight.color[$0] }
            if mode == .cmyk {
                values = values.map { samples.maximum - $0 }
            }
            return PSDChannel(id: Int16(channel), data: bytes(values, depth: depth))
        }
    }

    /// Samples as big-endian bytes.
    static func bytes(_ values: [UInt32], depth: Int) -> [UInt8] {
        guard depth == 16 else {
            return values.map { UInt8($0) }
        }
        var result = [UInt8]()
        result.reserveCapacity(values.count * 2)
        for value in values {
            result.append(UInt8(value >> 8))
            result.append(UInt8(value & 0xFF))
        }
        return result
    }
}
