// PDF images for import (IMG-009): image XObjects and inline images become image nodes with
// their pixels as blobs.  JPEG and JPEG 2000 streams keep their encoded bytes; sampled images
// are unpacked through their colour space and decode array into a PNG (a TIFF for plain CMYK),
// with the soft mask, stencil mask or colour-key mask as alpha; image masks paint the fill colour.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WTRender

/// An image's description, from an XObject dictionary or an inline image's abbreviated keys.
struct PDFImportImageSpec {
    var width: Int
    var height: Int
    var bitsPerComponent: Int
    var space: PDFImportColorSpace?
    var decode: [Double]?
    var imageMask: Bool
    var data: Data
    /// The bytes are still JPEG (or JPEG 2000) encoded.
    var encoded: Bool
    /// Alpha from `/SMask` or a stencil `/Mask` (1 = opaque).
    var alpha: PDFImportImageAlpha?
    /// `/Mask` as colour-key ranges on the raw samples.
    var colorKey: [Double]?
}

/// A soft or stencil mask.
struct PDFImportImageAlpha {
    var width: Int
    var height: Int
    var bitsPerComponent: Int
    var data: Data
    /// Stencil masks paint where the sample is 0, so their alpha is inverted.
    var inverted: Bool
    var decode: [Double]?
}

enum PDFImportImage {
    /// The spec of image XObject `stream`.
    static func spec(_ stream: PDFImportStream, resources: PDFImportDict?) -> PDFImportImageSpec {
        let dict = stream.dict
        let (data, format) = stream.decoded
        let imageMask = dict.bool("ImageMask") ?? false
        var spec = PDFImportImageSpec(
            width: Int(dict.number("Width") ?? 0), height: Int(dict.number("Height") ?? 0),
            bitsPerComponent: imageMask ? 1 : Int(dict.number("BitsPerComponent") ?? 8),
            space: dict["ColorSpace"].flatMap { PDFImportColorSpace.parse($0, resources: resources) },
            decode: dict.numbers("Decode"), imageMask: imageMask, data: data, encoded: format != .raw)
        if let mask = dict.stream("SMask") {
            spec.alpha = alpha(mask, inverted: false)
        } else if let mask = dict.stream("Mask") {
            spec.alpha = alpha(mask, inverted: true)
        } else if let key = dict.numbers("Mask") {
            spec.colorKey = key
        }
        return spec
    }

    static func alpha(_ stream: PDFImportStream, inverted: Bool) -> PDFImportImageAlpha {
        let dict = stream.dict
        return PDFImportImageAlpha(width: Int(dict.number("Width") ?? 0), height: Int(dict.number("Height") ?? 0), bitsPerComponent: Int(dict.number("BitsPerComponent") ?? 1), data: stream.data, inverted: inverted, decode: dict.numbers("Decode"))
    }

    /// The spec of an inline image from its dictionary entries and data.
    static func inlineSpec(_ entries: [String: PDFImportOperand], data: Data, resources: PDFImportDict?, session: PDFImportSession) -> PDFImportImageSpec? {
        func value(_ long: String, _ short: String) -> PDFImportOperand? { entries[long] ?? entries[short] }
        let imageMask: Bool
        if case .bool(let flag)? = value("ImageMask", "IM") { imageMask = flag } else { imageMask = false }
        var space: PDFImportColorSpace?
        switch value("ColorSpace", "CS") {
        case .name(let name)?:
            space = PDFImportColorSpace.named(name == "I" ? "Indexed" : name, resources: resources)
        case .array(let array)?:
            if array.first?.name == "I" || array.first?.name == "Indexed", array.count >= 4, let baseName = array[1].name,
               let base = PDFImportColorSpace.named(baseName, resources: resources), let lookup = array[3].string {
                space = .indexed(base: base, high: Int(array[2].number ?? 0), lookup: [UInt8](lookup))
            }
        default:
            break
        }
        var filters: [String] = []
        switch value("Filter", "F") {
        case .name(let name)?: filters = [name]
        case .array(let array)?: filters = array.compactMap(\.name)
        default: break
        }
        var bytes = data
        var encoded = false
        for filter in filters {
            switch filter {
            case "ASCIIHexDecode", "AHx": bytes = asciiHex(bytes)
            case "ASCII85Decode", "A85": bytes = ascii85(bytes)
            case "FlateDecode", "Fl": bytes = inflate(bytes)
            case "RunLengthDecode", "RL": bytes = runLength(bytes)
            case "DCTDecode", "DCT": encoded = true
            default:
                session.note("Inline images with \(filter) compression were left out.")
                return nil
            }
        }
        return PDFImportImageSpec(
            width: Int(value("Width", "W")?.number ?? 0), height: Int(value("Height", "H")?.number ?? 0),
            bitsPerComponent: imageMask ? 1 : Int(value("BitsPerComponent", "BPC")?.number ?? 8),
            space: space, decode: value("Decode", "D")?.array?.compactMap(\.number), imageMask: imageMask,
            data: bytes, encoded: encoded)
    }

    // MARK: Filters

    static func asciiHex(_ data: Data) -> Data {
        var digits: [UInt8] = []
        for byte in data {
            if byte == UInt8(ascii: ">") { break }
            if let value = PDFImportLexer.hexValue(byte) { digits.append(value) }
        }
        if digits.count % 2 == 1 { digits.append(0) }
        return Data(stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] })
    }

    static func ascii85(_ data: Data) -> Data {
        var result = Data()
        var group: [UInt32] = []
        func flush(_ count: Int) {
            var value: UInt32 = 0
            for digit in group + Array(repeating: 84, count: 5 - group.count) {
                value = value &* 85 &+ digit
            }
            let bytes = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
            result.append(contentsOf: bytes.prefix(count))
            group.removeAll()
        }
        for byte in data {
            if byte == UInt8(ascii: "~") { break }
            if byte == UInt8(ascii: "z") && group.isEmpty {
                result.append(contentsOf: [0, 0, 0, 0])
                continue
            }
            guard byte >= 33, byte <= 117 else { continue }
            group.append(UInt32(byte - 33))
            if group.count == 5 { flush(4) }
        }
        if group.count > 1 {
            flush(group.count - 1)
        }
        return result
    }

    /// A zlib (RFC 1950) stream inflated.
    static func inflate(_ data: Data) -> Data {
        guard data.count > 2, let inflated = try? (data.dropFirst(2) as NSData).decompressed(using: .zlib) else {
            return Data()
        }
        return inflated as Data
    }

    static func runLength(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            if length == 128 {
                break
            } else if length < 128 {
                let end = min(index + length + 1, bytes.count)
                result += bytes[index..<end]
                index = end
            } else if index < bytes.count {
                result += Array(repeating: bytes[index], count: 257 - length)
                index += 1
            }
        }
        return Data(result)
    }

    // MARK: Pixels

    /// The image's pixel source, nil when it cannot be read.  `fill` paints image masks.
    static func pixels(_ spec: PDFImportImageSpec, fill: Color, session: PDFImportSession) -> ImageImporter.Decoded? {
        if spec.encoded {
            guard spec.alpha != nil else {
                return try? ImageImporter().decode(spec.data, name: session.name)
            }
            guard let source = CGImageSourceCreateWithData(spec.data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }
            let rgba = RGBAPixels(image)
            return rgbaImage(width: rgba.width, height: rgba.height, alpha: spec.alpha) { index in
                let o = index * 4
                return (rgba.bytes[o], rgba.bytes[o + 1], rgba.bytes[o + 2])
            }
        }
        let width = spec.width
        let height = spec.height
        guard width > 0, height > 0, [1, 2, 4, 8, 16].contains(spec.bitsPerComponent) else {
            return nil
        }
        let samples = [UInt8](spec.data)
        let bits = spec.bitsPerComponent
        if spec.imageMask {
            let decode = spec.decode ?? [0, 1]
            let srgb = fill.srgb
            let color = (UInt8((srgb.x * 255).rounded()), UInt8((srgb.y * 255).rounded()), UInt8((srgb.z * 255).rounded()))
            let mask = PDFImportImageAlpha(width: width, height: height, bitsPerComponent: 1, data: Data(samples), inverted: true, decode: decode)
            return rgbaImage(width: width, height: height, alpha: mask) { _ in color }
        }
        let space = spec.space ?? .gray
        let components = space.components
        let maximum = Double((1 << bits) - 1)
        let decode: [Double]
        if let given = spec.decode, given.count >= 2 * components {
            decode = given
        } else if case .indexed = space {
            decode = [0, maximum]
        } else if case .lab(let range) = space {
            decode = [0, 100] + range
        } else {
            decode = (0..<components).flatMap { _ in [0.0, 1.0] }
        }
        let rowBits = width * components * bits
        let rowBytes = (rowBits + 7) / 8
        func raw(_ x: Int, _ y: Int, _ component: Int) -> Double {
            let bitIndex = y * rowBytes * 8 + (x * components + component) * bits
            return PDFImportBits.read(samples, index: bitIndex / bits, bits: bits)
        }
        let plain = spec.alpha == nil && spec.colorKey == nil && spec.decode == nil && bits == 8
        if plain, case .cmyk = space, samples.count >= width * height * 4 {
            let provider = CGDataProvider(data: Data(samples.prefix(width * height * 4)) as CFData)!
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
            let data = ImageEncoding.encode(image, type: .tiff)!
            return try? ImageImporter().decode(data, name: session.name, context: ImportContext(downsampleLimit: nil))
        }
        let gray: Bool
        switch space {
        case .gray: gray = spec.alpha == nil && spec.colorKey == nil
        default: gray = false
        }
        var colors: [(UInt8, UInt8, UInt8)] = []
        colors.reserveCapacity(width * height)
        var keyed: [Bool] = []
        for y in 0..<height {
            for x in 0..<width {
                var values: [Double] = []
                var inKey = spec.colorKey != nil
                for component in 0..<components {
                    let sample = raw(x, y, component)
                    if let key = spec.colorKey, 2 * component + 1 < key.count, sample < key[2 * component] || sample > key[2 * component + 1] {
                        inKey = false
                    }
                    values.append(PDFImportFunction.interpolate(sample, 0, maximum, decode[2 * component], decode[2 * component + 1]))
                }
                keyed.append(inKey)
                let srgb = (space.color(values) ?? .black).srgb
                colors.append((UInt8((min(max(srgb.x, 0), 1) * 255).rounded()), UInt8((min(max(srgb.y, 0), 1) * 255).rounded()), UInt8((min(max(srgb.z, 0), 1) * 255).rounded())))
            }
        }
        if gray {
            let bytes = colors.map(\.0)
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
            return ImageImporter.Decoded(pixels: ImageImporter.pixels(of: image), dpiX: 72, dpiY: 72, notes: [])
        }
        var alpha = spec.alpha
        if spec.colorKey != nil {
            alpha = PDFImportImageAlpha(width: width, height: height, bitsPerComponent: 8, data: Data(keyed.map { $0 ? 0 : 255 }), inverted: false, decode: nil)
        }
        return rgbaImage(width: width, height: height, alpha: alpha) { colors[$0] }
    }

    /// An RGBA PNG of `width` × `height` pixels whose colour `color(index)` gives, with `alpha`
    /// resampled (nearest) onto it.
    static func rgbaImage(width: Int, height: Int, alpha: PDFImportImageAlpha?, color: (Int) -> (UInt8, UInt8, UInt8)) -> ImageImporter.Decoded {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let maskBytes = alpha.map { [UInt8]($0.data) } ?? []
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let (r, g, b) = color(index)
                bytes[index * 4] = r
                bytes[index * 4 + 1] = g
                bytes[index * 4 + 2] = b
                if let alpha, alpha.width > 0, alpha.height > 0 {
                    let mx = min(x * alpha.width / width, alpha.width - 1)
                    let my = min(y * alpha.height / height, alpha.height - 1)
                    let rowBits = alpha.width * alpha.bitsPerComponent
                    let rowBytes = (rowBits + 7) / 8
                    let bitIndex = my * rowBytes * 8 + mx * alpha.bitsPerComponent
                    let maximum = Double((1 << alpha.bitsPerComponent) - 1)
                    let sample = PDFImportBits.read(maskBytes, index: bitIndex / alpha.bitsPerComponent, bits: alpha.bitsPerComponent)
                    let decode = alpha.decode ?? [0, 1]
                    var value = PDFImportFunction.interpolate(sample, 0, maximum, decode[0], decode.count > 1 ? decode[1] : 1)
                    if alpha.inverted {
                        value = 1 - value
                    }
                    bytes[index * 4 + 3] = UInt8((min(max(value, 0), 1) * 255).rounded())
                }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: (alpha == nil ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.last).rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return ImageImporter.Decoded(pixels: ImageImporter.pixels(of: image), dpiX: 72, dpiY: 72, notes: [])
    }
}
