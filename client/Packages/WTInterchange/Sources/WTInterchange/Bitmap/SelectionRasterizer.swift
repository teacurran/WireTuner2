// menu:Modify[Rasterize…] (IMG-024; docs/_includes/imported/rasterizing.adoc, "Client"): the
// selected objects drawn alone by WTRender -- the bitmap rasterizer's supersampled tiles, the
// window's renderer supplying placed images and colour management -- over their rendered bounds
// (strokes and live effects included) at the chosen resolution, then encoded: RGB as PNG (with
// alpha on a transparent background), CMYK as TIFF in Working CMYK, grayscale as 8-bit gray
// PNG.  The sheet's pixel-count readout and the size refusal come from `plan`; the result goes
// to WTModel's `RasterizeObjects` as one change.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WTGeometry
import WTRender

/// The Rasterize sheet's settings.
public struct RasterizeOptions: Hashable, Sendable {
    public enum Resolution: Hashable, Sendable {
        /// 72 ppi, for screen and web work.
        case screen
        /// 144 ppi, for proofs.
        case proof
        /// 300 ppi, for print.
        case print
        /// 36 ... 2400 ppi.
        case custom(Double)

        public var ppi: Double {
            switch self {
            case .screen: 72
            case .proof: 144
            case .print: 300
            case .custom(let value): value
            }
        }
    }

    /// Samples per pixel each way: 1, 2, 3 or 4.
    public enum AntiAliasing: Int, Hashable, Sendable, CaseIterable {
        case none = 1
        case low = 2
        case medium = 3
        case high = 4
    }

    public enum Background: Hashable, Sendable {
        case transparent
        case white
    }

    public enum ColorMode: Hashable, Sendable {
        case rgb
        case cmyk
        case grayscale
    }

    public var resolution: Resolution
    public var antiAliasing: AntiAliasing
    /// Transparent keeps an alpha channel (RGB only: CMYK and grayscale results are opaque, and
    /// a grayscale result is made transparent with the Object panel).
    public var background: Background
    public var colorMode: ColorMode
    /// Leaves the objects in place under the image.
    public var keepOriginals: Bool

    public init(resolution: Resolution = .print, antiAliasing: AntiAliasing = .medium, background: Background = .transparent, colorMode: ColorMode = .rgb,
                keepOriginals: Bool = false) {
        self.resolution = resolution
        self.antiAliasing = antiAliasing
        self.background = background
        self.colorMode = colorMode
        self.keepOriginals = keepOriginals
    }

    /// Whether the result has an alpha channel.
    public var hasAlpha: Bool { background == .transparent && colorMode == .rgb }

    public func validate() throws {
        let ppi = resolution.ppi
        guard ppi.isFinite, (36...2400).contains(ppi) else { throw RasterizeError.invalidResolution }
    }
}

/// Why a selection could not be rasterized.
public enum RasterizeError: Error, Hashable, Sendable {
    /// A custom resolution outside 36 ... 2400 ppi.
    case invalidResolution
    /// The selected objects draw nothing.
    case nothingToRasterize
    /// The result would be over 200 MiB: `bytes` it would take.
    case tooLarge(bytes: Int)
}

/// The sheet's readout before rasterizing.
public struct RasterizePlan: Hashable, Sendable {
    /// The pasteboard rectangle the image covers: the selection's rendered bounds, widened to
    /// whole pixels.
    public var bounds: Rect
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// The decoded result's bytes.
    public var bytes: Int
    public var ppi: Double

    public var pixelCount: Int { pixelWidth * pixelHeight }

    /// Refused: the result is over `SelectionRasterizer.byteLimit`.
    public var isRefused: Bool { bytes > SelectionRasterizer.byteLimit }

    /// Whether the result is over the *Downsample images larger than* preference (`limit`
    /// pixels, nil for off): warned about, not downsampled.
    public func exceeds(downsampleLimit limit: Int?) -> Bool {
        limit.map { pixelCount > $0 } ?? false
    }

    /// `1,200 × 800 pixels (0.96 MP)`.
    public var readout: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let width = formatter.string(from: pixelWidth as NSNumber)!, height = formatter.string(from: pixelHeight as NSNumber)!
        return "\(width) × \(height) pixels (\(String(format: "%.2f", Double(pixelCount) / 1_000_000)) MP)"
    }
}

/// A rasterized selection.
public struct RasterizedImage: Hashable, Sendable {
    /// The encoded blob and its facts, as an import produces them.
    public var pixels: ImportedPixels
    /// Where the image goes (pasteboard space): its natural size at `ppi` is this size.
    public var bounds: Rect
    /// The stored resolution (`dpi_x` = `dpi_y`).
    public var ppi: Double

    public init(pixels: ImportedPixels, bounds: Rect, ppi: Double) {
        self.pixels = pixels
        self.bounds = bounds
        self.ppi = ppi
    }
}

/// Rasterizes selections.
public enum SelectionRasterizer {
    /// 200 MiB: the largest result that can be created.
    public static let byteLimit = 200 * 1024 * 1024
    /// Above this many pixels the app shows a progress sheet (16 MP).
    public static let progressThreshold = 16_000_000

    /// The top-level items of `list` built from `nodes`, in draw order (everything else hidden).
    public static func selection(_ list: DisplayList, nodes: Set<NodeID>) -> DisplayList {
        let indices = list.items.indices.filter { index in list.nodeIDs.indices.contains(index) && list.nodeIDs[index].map(nodes.contains) == true }
        return DisplayList(canvas: list.canvas, items: indices.map { list.items[$0] }, itemBounds: indices.map { list.itemBounds[$0] },
                           nodeIDs: indices.map { list.nodeIDs[$0] })
    }

    /// The readout for `selection` (a list holding only the selected objects) with `options`;
    /// nil when it draws nothing.
    public static func plan(_ selection: DisplayList, options: RasterizeOptions) -> RasterizePlan? {
        guard let rendered = selection.bounds, rendered.width > 0 || rendered.height > 0 else { return nil }
        let ppi = options.resolution.ppi
        let scale = ppi / 72
        let width = max(Int((rendered.width * scale).rounded(.up)), 1), height = max(Int((rendered.height * scale).rounded(.up)), 1)
        let bounds = Rect(x: rendered.minX, y: rendered.minY, width: Double(width) / scale, height: Double(height) / scale)
        let components = options.colorMode == .grayscale ? 1 : 4
        return RasterizePlan(bounds: bounds, pixelWidth: width, pixelHeight: height, bytes: width * height * components, ppi: ppi)
    }

    /// `selection` rasterized with `options`: `output` gives the working profiles (Working CMYK
    /// for a CMYK result), `base` the renderer placed images draw from.  `progress` is called
    /// with the fraction done after each band and returns false to cancel (then this throws
    /// `CancellationError`).
    public static func rasterize(_ selection: DisplayList, options: RasterizeOptions, output: WTColor.OutputContext? = nil, base: CoreGraphicsRenderer? = nil,
                                 progress: (Double) -> Bool = { _ in true }) throws -> RasterizedImage {
        try options.validate()
        guard let plan = plan(selection, options: options) else { throw RasterizeError.nothingToRasterize }
        guard !plan.isRefused else { throw RasterizeError.tooLarge(bytes: plan.bytes) }
        let color: BitmapCommonOptions.ColorMode
        switch options.colorMode {
        case .rgb: color = .rgb
        case .cmyk: color = .cmyk
        case .grayscale: color = .gray
        }
        let common = BitmapCommonOptions(ppi: plan.ppi, antiAliasing: options.antiAliasing.rawValue, background: options.hasAlpha ? .transparent : .white,
                                         color: color, rgbSpace: .workingRGB)
        let page = ExportPage(bounds: plan.bounds, displayList: selection)
        let bitmap = BitmapRasterizer(common: common, output: output ?? .standard, base: base)
            .render(page, scale: 1, bitsPerComponent: 8, alpha: options.hasAlpha).bitmap
        var bytes = Data(capacity: bitmap.bytesPerRow * bitmap.height)
        for band in 0..<bitmap.bandCount {
            bytes.append(bitmap.band(band))
            guard progress(Double(band + 1) / Double(bitmap.bandCount)) else { throw CancellationError() }
        }
        let image = CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 8 * bitmap.components, bytesPerRow: bitmap.bytesPerRow,
                            space: bitmap.colorSpace, bitmapInfo: bitmap.bitmapInfo, provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let type: UTType = options.colorMode == .cmyk ? .tiff : .png
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: plan.ppi, kCGImagePropertyDPIHeight: plan.ppi]
        let data = ImageEncoding.encode(image, type: type, properties: properties)!
        let facts = try ImageImporter.facts(of: data, name: "").facts
        let pixels = ImportedPixels(blob: ImportedBlob(data: data, uti: facts.uti), width: facts.width, height: facts.height, mode: facts.mode,
                                    bitsPerChannel: facts.bits, hasAlpha: facts.hasAlpha)
        return RasterizedImage(pixels: pixels, bounds: plan.bounds, ppi: plan.ppi)
    }

    /// `rasterize` on a background task.
    public static func rasterizeInBackground(_ selection: DisplayList, options: RasterizeOptions, output: WTColor.OutputContext? = nil, base: CoreGraphicsRenderer? = nil,
                                             progress: @escaping @Sendable (Double) -> Bool = { _ in true }) async throws -> RasterizedImage {
        try await Task.detached(priority: .userInitiated) {
            try rasterize(selection, options: options, output: output, base: base, progress: progress)
        }.value
    }
}
