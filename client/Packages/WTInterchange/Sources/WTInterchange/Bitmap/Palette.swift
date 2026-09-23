// Palette images (export-bitmap.adoc, "GIF", PNG and TIFF *8-bit palette*; IO-022): the palette
// choices, `.act`/`.aco` palette files, median-cut quantization, Floyd–Steinberg dithering and the
// matte and transparent-index rules.  Own code because ImageIO's GIF encoder offers no palette
// control.

import CoreGraphics
import Foundation
import WTRender

/// How a palette image picks its colours.
public enum PaletteChoice: Hashable, Sendable {
    /// Median cut over the image's colours.
    case adaptive
    /// The image's own colours; refused when there are more than the palette holds.
    case exact
    /// The 6 × 6 × 6 browser-safe cube.
    case web216
    /// Evenly spaced greys.
    case grayscale
    /// An Adobe Color Table (`.act`) or Color Swatch (`.aco`) file's bytes.
    case custom(Data)
}

/// The palette options shared by GIF and the 8-bit PNG and TIFF depths.
public struct PaletteSettings: Hashable, Sendable {
    public var choice: PaletteChoice
    /// Palette entries, 2 ... 256 (a transparent index counts as one).
    public var colors: Int
    /// 0 ... 100: how much of each pixel's error diffuses to its neighbours.
    public var ditherPercent: Int

    public init(choice: PaletteChoice = .adaptive, colors: Int = 256, ditherPercent: Int = 0) {
        self.choice = choice
        self.colors = colors
        self.ditherPercent = ditherPercent
    }

    func validate() throws {
        guard (2...256).contains(colors) else {
            throw ExportError.invalidOption("A palette holds 2 to 256 colors.")
        }
        guard (0...100).contains(ditherPercent) else {
            throw ExportError.invalidOption("Dither must be 0 to 100%.")
        }
    }
}

/// An 8-bit colour.
struct RGB: Hashable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    var key: UInt32 { UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b) }
}

/// An image as palette indices.
struct IndexedImage {
    let width: Int
    let height: Int
    var palette: [RGB]
    /// Row-major, one index per pixel.
    var indices: [UInt8]
    /// The palette entry that is fully transparent, if any.
    var transparentIndex: Int?
}

/// Straight 8-bit RGBA pixels of a whole bitmap.
struct StraightPixels {
    let width: Int
    let height: Int
    /// 4 bytes per pixel, straight alpha.
    var bytes: [UInt8]

    /// The pixels of an 8-bit RGB bitmap (premultiplied with alpha, or padded without).
    init(_ bitmap: RasterBitmap) {
        width = bitmap.width
        height = bitmap.height
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for band in 0..<bitmap.bandCount {
            let data = bitmap.band(band)
            for index in stride(from: 0, to: data.count, by: 4) {
                let base = data.startIndex + index
                let alpha = bitmap.hasAlpha ? Int(data[base + 3]) : 255
                for channel in 0..<3 {
                    let value = Int(data[base + channel])
                    bytes.append(alpha == 0 ? 0 : UInt8(min(255, (value * 255 + alpha / 2) / alpha)))
                }
                bytes.append(UInt8(alpha))
            }
        }
        self.bytes = bytes
    }
}

enum Quantizer {
    /// Alpha below this is the transparent index; at or above it the pixel is opaque over the
    /// matte (GIF has one-bit transparency).
    static let alphaThreshold = 128

    /// `pixels` as a palette image: transparent pixels (when `transparent`) on their own index,
    /// every other pixel composited over `matte` and mapped onto the chosen palette.
    static func indexed(_ pixels: StraightPixels, settings: PaletteSettings, transparent: Bool, matte: Color) throws -> IndexedImage {
        try settings.validate()
        let count = pixels.width * pixels.height
        let matteRGB = [matte.red, matte.green, matte.blue].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        var colors = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: count)
        var clear = [Bool](repeating: false, count: count)
        for index in 0..<count {
            let base = index * 4
            let alpha = Int(pixels.bytes[base + 3])
            if transparent && alpha < alphaThreshold {
                clear[index] = true
                continue
            }
            func over(_ channel: Int) -> UInt8 {
                UInt8((Int(pixels.bytes[base + channel]) * alpha + matteRGB[channel] * (255 - alpha) + 127) / 255)
            }
            colors[index] = RGB(r: over(0), g: over(1), b: over(2))
        }
        let hasClear = clear.contains(true)
        let available = settings.colors - (hasClear ? 1 : 0)
        var palette = try self.palette(settings.choice, colors: colors.enumerated().filter { !clear[$0.offset] }.map(\.element), size: max(available, 1))
        var indices = map(colors, width: pixels.width, height: pixels.height, skip: clear, palette: palette, dither: Double(settings.ditherPercent) / 100)
        var transparentIndex: Int?
        if hasClear {
            transparentIndex = palette.count
            // The transparent entry carries the matte, which readers that ignore transparency show.
            palette.append(RGB(r: UInt8(matteRGB[0]), g: UInt8(matteRGB[1]), b: UInt8(matteRGB[2])))
            for index in 0..<count where clear[index] {
                indices[index] = UInt8(transparentIndex!)
            }
        }
        return IndexedImage(width: pixels.width, height: pixels.height, palette: palette, indices: indices, transparentIndex: transparentIndex)
    }

    // MARK: Palettes

    static func palette(_ choice: PaletteChoice, colors: [RGB], size: Int) throws -> [RGB] {
        switch choice {
        case .adaptive:
            return medianCut(colors, size: size)
        case .exact:
            var seen = Set<UInt32>()
            var unique: [RGB] = []
            for color in colors where seen.insert(color.key).inserted {
                unique.append(color)
                if unique.count > size {
                    throw ExportError.invalidOption("The Exact palette needs at most \(size) colors; the artwork has more.  Choose Adaptive.")
                }
            }
            return unique.isEmpty ? [RGB(r: 0, g: 0, b: 0)] : unique
        case .web216:
            let levels: [UInt8] = [0, 51, 102, 153, 204, 255]
            return levels.flatMap { r in levels.flatMap { g in levels.map { b in RGB(r: r, g: g, b: b) } } }.prefix(size).map { $0 }
        case .grayscale:
            return (0..<size).map { index in
                let value = UInt8((Double(index) * 255 / Double(max(size - 1, 1))).rounded())
                return RGB(r: value, g: value, b: value)
            }
        case .custom(let data):
            let loaded = try loadPalette(data)
            return Array(loaded.prefix(size))
        }
    }

    /// The colours of an Adobe Color Table (768 bytes, or 772 with a count and a transparent
    /// index) or a Color Swatch file (version 1 or 2; RGB, HSB and greyscale swatches).
    static func loadPalette(_ data: Data) throws -> [RGB] {
        let bytes = [UInt8](data)
        if bytes.count == 768 || bytes.count == 772 {
            var count = 256
            if bytes.count == 772 {
                let stored = Int(bytes[768]) << 8 | Int(bytes[769])
                if stored > 0 && stored <= 256 {
                    count = stored
                }
            }
            return (0..<count).map { RGB(r: bytes[$0 * 3], g: bytes[$0 * 3 + 1], b: bytes[$0 * 3 + 2]) }
        }
        func word(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        guard bytes.count >= 4, word(0) == 1 || word(0) == 2 else {
            throw ExportError.invalidOption("The palette file is neither an .act nor an .aco file.")
        }
        let count = word(2)
        guard bytes.count >= 4 + count * 10 else {
            throw ExportError.invalidOption("The .aco file is truncated.")
        }
        var colors: [RGB] = []
        for index in 0..<count {
            let base = 4 + index * 10
            let space = word(base)
            let w = Double(word(base + 2)), x = Double(word(base + 4)), y = Double(word(base + 6))
            switch space {
            case 0:
                colors.append(RGB(r: UInt8(w / 257), g: UInt8(x / 257), b: UInt8(y / 257)))
            case 1:
                let (r, g, b) = hsb(hue: w / 65535, saturation: x / 65535, brightness: y / 65535)
                colors.append(RGB(r: r, g: g, b: b))
            case 8:
                let value = UInt8((255 - w / 10000 * 255).rounded())
                colors.append(RGB(r: value, g: value, b: value))
            default:
                continue
            }
        }
        guard !colors.isEmpty else {
            throw ExportError.invalidOption("The .aco file holds no RGB, HSB or grayscale swatches.")
        }
        return colors
    }

    static func hsb(hue: Double, saturation: Double, brightness: Double) -> (UInt8, UInt8, UInt8) {
        let h = (hue * 6).truncatingRemainder(dividingBy: 6)
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        func byte(_ v: Double) -> UInt8 { UInt8(((v + m) * 255).rounded()) }
        return (byte(r), byte(g), byte(b))
    }

    /// Median cut: the box with the most pixels × widest channel range splits at its weighted
    /// median along that channel until there are `size` boxes; each box's colour is its pixels'
    /// mean.  An image with at most `size` colours gets exactly its colours.
    static func medianCut(_ colors: [RGB], size: Int) -> [RGB] {
        var histogram: [UInt32: Int] = [:]
        for color in colors {
            histogram[color.key, default: 0] += 1
        }
        let entries = histogram.map { (color: RGB(r: UInt8($0.key >> 16), g: UInt8(($0.key >> 8) & 0xFF), b: UInt8($0.key & 0xFF)), count: $0.value) }
            .sorted { $0.color.key < $1.color.key }
        if entries.count <= size {
            return entries.isEmpty ? [RGB(r: 0, g: 0, b: 0)] : entries.map(\.color)
        }
        typealias Entry = (color: RGB, count: Int)
        func channel(_ color: RGB, _ axis: Int) -> Int {
            axis == 0 ? Int(color.r) : (axis == 1 ? Int(color.g) : Int(color.b))
        }
        func widest(_ box: [Entry]) -> (axis: Int, range: Int) {
            (0..<3).map { axis -> (Int, Int) in
                let values = box.map { channel($0.color, axis) }
                return (axis, values.max()! - values.min()!)
            }.max { $0.1 < $1.1 }!
        }
        // Each box with its split axis and score, recomputed only for the boxes a split makes.
        func scored(_ box: [Entry]) -> (entries: [Entry], axis: Int, score: Int) {
            let spread = widest(box)
            return (box, spread.axis, box.count > 1 ? spread.range * box.reduce(0) { $0 + $1.count } : -1)
        }
        var boxes = [scored(entries)]
        while boxes.count < size {
            guard let pick = boxes.indices.max(by: { boxes[$0].score < boxes[$1].score }), boxes[pick].score >= 0 else {
                break
            }
            let axis = boxes[pick].axis
            let sorted = boxes[pick].entries.sorted { channel($0.color, axis) < channel($1.color, axis) }
            let total = sorted.reduce(0) { $0 + $1.count }
            var running = 0
            var cut = 1
            for (index, entry) in sorted.enumerated() {
                running += entry.count
                if running * 2 >= total {
                    cut = min(max(index + 1, 1), sorted.count - 1)
                    break
                }
            }
            boxes[pick] = scored(Array(sorted[..<cut]))
            boxes.append(scored(Array(sorted[cut...])))
        }
        return boxes.map(\.entries).map { box in
            let total = Double(box.reduce(0) { $0 + $1.count })
            func mean(_ axis: Int) -> UInt8 {
                UInt8((Double(box.reduce(0) { $0 + channel($1.color, axis) * $1.count }) / total).rounded())
            }
            return RGB(r: mean(0), g: mean(1), b: mean(2))
        }
    }

    // MARK: Mapping

    /// Each colour's nearest palette entry, with Floyd–Steinberg error diffusion scaled by
    /// `dither` (0 ... 1); `skip` pixels take no index here and pass no error on.
    static func map(_ colors: [RGB], width: Int, height: Int, skip: [Bool], palette: [RGB], dither: Double) -> [UInt8] {
        var cache: [UInt32: UInt8] = [:]
        func nearest(_ r: Int, _ g: Int, _ b: Int) -> UInt8 {
            let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
            if let hit = cache[key] {
                return hit
            }
            var best = 0
            var bestDistance = Int.max
            for (index, entry) in palette.enumerated() {
                let dr = r - Int(entry.r), dg = g - Int(entry.g), db = b - Int(entry.b)
                let distance = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
            cache[key] = UInt8(best)
            return UInt8(best)
        }
        var indices = [UInt8](repeating: 0, count: colors.count)
        guard dither > 0 else {
            for index in colors.indices where !skip[index] {
                indices[index] = nearest(Int(colors[index].r), Int(colors[index].g), Int(colors[index].b))
            }
            return indices
        }
        var error = [SIMD3<Double>](repeating: .zero, count: colors.count)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard !skip[index] else { continue }
                let color = colors[index]
                let wanted = SIMD3(Double(color.r), Double(color.g), Double(color.b)) + error[index]
                let clamped = wanted.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 255))
                let chosen = nearest(Int(clamped.x.rounded()), Int(clamped.y.rounded()), Int(clamped.z.rounded()))
                indices[index] = chosen
                let entry = palette[Int(chosen)]
                let residual = (clamped - SIMD3(Double(entry.r), Double(entry.g), Double(entry.b))) * dither
                func spread(_ dx: Int, _ dy: Int, _ weight: Double) {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny < height else { return }
                    error[ny * width + nx] += residual * weight
                }
                spread(1, 0, 7.0 / 16)
                spread(-1, 1, 3.0 / 16)
                spread(0, 1, 5.0 / 16)
                spread(1, 1, 1.0 / 16)
            }
        }
        return indices
    }
}
