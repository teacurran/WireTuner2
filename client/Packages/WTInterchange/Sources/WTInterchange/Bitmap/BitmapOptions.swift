// Bitmap export options (export-bitmap.adoc; `BitmapCommonOptions`, `PngOptions`, `JpegOptions`,
// `TiffOptions`, `BmpOptions`, `TargaOptions` in interchange/v1/export_options.proto).

import Foundation
import WTRender

/// The options every bitmap format shares.
public struct BitmapCommonOptions: Hashable, Sendable {
    public enum Background: Hashable, Sendable {
        case transparent
        case pageColor
        case white
    }

    public enum ColorMode: Hashable, Sendable {
        case rgb
        case gray
        case cmyk
    }

    /// The RGB output space; `auto` is the working RGB space, or Display P3 when the artwork
    /// holds colours outside sRGB.
    public enum RGBSpace: Hashable, Sendable {
        case auto
        case sRGB
        case displayP3
        case workingRGB
    }

    /// Pixels per inch of the document's dimensions.
    public var ppi: Double
    /// Each scale writes its own file (`@2x`, `@3x`).
    public var scales: [Double]
    /// The supersampling factor: 1 (none), 2, 3 or 4.
    public var antiAliasing: Int
    public var background: Background
    public var color: ColorMode
    public var embedProfile: Bool
    public var simulateOverprint: Bool
    /// *Mask from layer*: the layer's artwork, rendered alone; its luminance multiplies the
    /// export's alpha.  Nil for none.
    public var maskLayer: DisplayList?
    public var rgbSpace: RGBSpace

    public init(
        ppi: Double = 72,
        scales: [Double] = [1],
        antiAliasing: Int = 4,
        background: Background = .transparent,
        color: ColorMode = .rgb,
        embedProfile: Bool = true,
        simulateOverprint: Bool = false,
        maskLayer: DisplayList? = nil,
        rgbSpace: RGBSpace = .auto
    ) {
        self.ppi = ppi
        self.scales = scales
        self.antiAliasing = antiAliasing
        self.background = background
        self.color = color
        self.embedProfile = embedProfile
        self.simulateOverprint = simulateOverprint
        self.maskLayer = maskLayer
        self.rgbSpace = rgbSpace
    }

    /// Rejects values outside the sheet's ranges.
    func validate() throws {
        guard ppi.isFinite, ppi >= 1, ppi <= 9600 else {
            throw ExportError.invalidOption("The resolution must be 1 to 9,600 ppi.")
        }
        guard !scales.isEmpty, scales.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 16 }) else {
            throw ExportError.invalidOption("Scales must be between 0 and 16.")
        }
        guard (1...4).contains(antiAliasing) else {
            throw ExportError.invalidOption("Anti-aliasing must be None, 2, 3 or 4.")
        }
    }
}

/// A bitmap format's options: the common ones plus its own.
public protocol BitmapFormatOptions: ExportOptions {
    var common: BitmapCommonOptions { get set }
}

public struct PNGOptions: BitmapFormatOptions, Hashable {
    public var common: BitmapCommonOptions
    /// 8 (palette), 24, 32 (with alpha), 48 or 64 (16 bits per channel, with alpha).
    public var bits: Int
    public var interlaced: Bool
    /// *Fastest* compression rather than *Smallest*.
    public var fast: Bool
    /// How the 8-bit palette is chosen.
    public var palette: PaletteSettings

    public init(common: BitmapCommonOptions = BitmapCommonOptions(), bits: Int = 32, interlaced: Bool = false, fast: Bool = false, palette: PaletteSettings = PaletteSettings()) {
        self.common = common
        self.bits = bits
        self.interlaced = interlaced
        self.fast = fast
        self.palette = palette
    }

    public static var defaults: PNGOptions { PNGOptions() }
}

public struct JPEGOptions: BitmapFormatOptions, Hashable {
    public enum Subsampling: Hashable, Sendable {
        case auto
        case s444
        case s420
    }

    public var common: BitmapCommonOptions
    /// 1 ... 100.
    public var quality: Int
    public var progressive: Bool
    public var subsampling: Subsampling

    public init(common: BitmapCommonOptions = BitmapCommonOptions(background: .white), quality: Int = 85, progressive: Bool = false, subsampling: Subsampling = .auto) {
        self.common = common
        self.quality = quality
        self.progressive = progressive
        self.subsampling = subsampling
    }

    public static var defaults: JPEGOptions { JPEGOptions() }
}

public struct TIFFOptions: BitmapFormatOptions, Hashable {
    public enum Compression: Hashable, Sendable {
        case none
        case lzw
        case zip
        case jpeg
    }

    public var common: BitmapCommonOptions
    public var compression: Compression
    public var jpegQuality: Int
    /// 8 (palette, no alpha), 24, 32 (alpha), 48, 64 (alpha); CMYK is 32.
    public var bits: Int
    /// *Mac* byte order; ImageIO writes the order it chooses (every reader accepts both).
    public var bigEndian: Bool
    /// How the 8-bit palette is chosen.
    public var palette: PaletteSettings

    public init(common: BitmapCommonOptions = BitmapCommonOptions(), compression: Compression = .lzw, jpegQuality: Int = 85, bits: Int = 32, bigEndian: Bool = true, palette: PaletteSettings = PaletteSettings()) {
        self.common = common
        self.compression = compression
        self.jpegQuality = jpegQuality
        self.bits = bits
        self.bigEndian = bigEndian
        self.palette = palette
    }

    public static var defaults: TIFFOptions { TIFFOptions() }
}

public struct BMPOptions: BitmapFormatOptions, Hashable {
    public var common: BitmapCommonOptions
    /// 24 or 32 (with alpha).
    public var bits: Int
    public var rle: Bool

    public init(common: BitmapCommonOptions = BitmapCommonOptions(), bits: Int = 32, rle: Bool = false) {
        self.common = common
        self.bits = bits
        self.rle = rle
    }

    public static var defaults: BMPOptions { BMPOptions() }
}

public struct TargaOptions: BitmapFormatOptions, Hashable {
    public var common: BitmapCommonOptions
    /// 8 (grey), 16 (5-5-5 with a one-bit alpha), 24 or 32 (with alpha).
    public var bits: Int
    public var rle: Bool

    public init(common: BitmapCommonOptions = BitmapCommonOptions(), bits: Int = 32, rle: Bool = false) {
        self.common = common
        self.bits = bits
        self.rle = rle
    }

    public static var defaults: TargaOptions { TargaOptions() }
}

/// GIF options (export-bitmap.adoc, "GIF"; `GifOptions`).  GIF's transparency is its own option:
/// the common *Background* applies only when `transparent` is off (a transparent choice there
/// reads as white).
public struct GIFOptions: BitmapFormatOptions, Hashable {
    public var common: BitmapCommonOptions
    public var palette: PaletteSettings
    /// Pixels where nothing is drawn become the transparent index.
    public var transparent: Bool
    /// The colour anti-aliased edges blend toward.
    public var matte: Color
    public var interlaced: Bool

    public init(common: BitmapCommonOptions = BitmapCommonOptions(), palette: PaletteSettings = PaletteSettings(), transparent: Bool = true, matte: Color = .white, interlaced: Bool = false) {
        self.common = common
        self.palette = palette
        self.transparent = transparent
        self.matte = matte
        self.interlaced = interlaced
    }

    public static var defaults: GIFOptions { GIFOptions() }
}

/// WebP options (`WebpOptions`).
public struct WebPOptions: BitmapFormatOptions, Hashable {
    public var common: BitmapCommonOptions
    public var lossless: Bool
    /// 1 ... 100.
    public var quality: Int

    public init(common: BitmapCommonOptions = BitmapCommonOptions(), lossless: Bool = false, quality: Int = 80) {
        self.common = common
        self.lossless = lossless
        self.quality = quality
    }

    public static var defaults: WebPOptions { WebPOptions() }
}

/// HEIC options (`HeicOptions`).
public struct HEICOptions: BitmapFormatOptions, Hashable {
    public var common: BitmapCommonOptions
    /// 1 ... 100.
    public var quality: Int

    public init(common: BitmapCommonOptions = BitmapCommonOptions(), quality: Int = 80) {
        self.common = common
        self.quality = quality
    }

    public static var defaults: HEICOptions { HEICOptions() }
}

/// AVIF options (`AvifOptions`).
public struct AVIFOptions: BitmapFormatOptions, Hashable {
    public var common: BitmapCommonOptions
    /// Exact pixels.  ImageIO's AVIF encoder has no lossless mode, so this is refused.
    public var lossless: Bool
    /// 1 ... 100.
    public var quality: Int
    /// Encoder effort, 0 (slowest, smallest) ... 10.  ImageIO offers no control: reported.
    public var speed: Int

    public init(common: BitmapCommonOptions = BitmapCommonOptions(), lossless: Bool = false, quality: Int = 80, speed: Int = 6) {
        self.common = common
        self.lossless = lossless
        self.quality = quality
        self.speed = speed
    }

    public static var defaults: AVIFOptions { AVIFOptions() }
}
