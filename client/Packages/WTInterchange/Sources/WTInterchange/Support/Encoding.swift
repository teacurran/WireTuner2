// Small encoders shared by the writers: fixed-precision decimals, zlib streams for PDF's
// FlateDecode, base64 data URLs and PNG/JPEG encoding of images through ImageIO.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Numbers {
    /// `value` with at most `places` decimals, trailing zeros and a bare point dropped, `-0`
    /// written as `0`.  Non-finite values write as `0`.
    static func format(_ value: Double, places: Int) -> String {
        guard value.isFinite else {
            return "0"
        }
        let scale = pow(10, Double(places))
        let rounded = (value * scale).rounded() / scale
        if rounded == 0 {
            return "0"
        }
        if rounded == rounded.rounded(), abs(rounded) < 1e15 {
            return String(Int64(rounded))
        }
        var text = String(format: "%.\(places)f", rounded)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }
}

enum Zlib {
    /// `data` as a zlib stream (RFC 1950: header, DEFLATE, Adler-32), what PDF's FlateDecode
    /// reads.  Foundation's `.zlib` algorithm writes raw DEFLATE only.
    static func compress(_ data: Data) -> Data {
        // Compressing a non-empty in-memory buffer cannot fail; an error here is a Foundation
        // defect, not a condition an export can recover from.  An empty input is the stored
        // empty final block.
        let deflated = data.isEmpty ? Data([0x03, 0x00]) : try! (data as NSData).compressed(using: .zlib) as Data
        var result = Data([0x78, 0x9C])
        result.append(deflated)
        var a: UInt32 = 1
        var b: UInt32 = 0
        data.withUnsafeBytes { buffer in
            // Adler-32 in blocks small enough that the sums cannot overflow before the modulo.
            var index = 0
            let count = buffer.count
            while index < count {
                let end = min(index + 5552, count)
                for position in index..<end {
                    a += UInt32(buffer[position])
                    b += a
                }
                a %= 65521
                b %= 65521
                index = end
            }
        }
        let adler = (b << 16) | a
        result.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
        return result
    }
}

enum ImageEncoding {
    /// `image` encoded as `type` (PNG, JPEG…) through ImageIO, with destination properties.
    static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Whether the image has an alpha channel that can hold anything but opaque.
    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// `data:<mime>;base64,<bytes>`.
    static func dataURL(_ data: Data, mime: String) -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }
}

/// Straight-alpha RGBA bytes of an image, drawn into sRGB.
struct RGBAPixels {
    let width: Int
    let height: Int
    /// Row-major, 4 bytes per pixel, straight (un-premultiplied) alpha.
    let bytes: [UInt8]

    init(_ image: CGImage) {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var premultiplied = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        premultiplied.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var straight = premultiplied
        for index in stride(from: 0, to: straight.count, by: 4) {
            let alpha = Int(premultiplied[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                straight[index + channel] = UInt8(min(255, (Int(premultiplied[index + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        bytes = straight
    }

    /// `image` drawn into sRGB with premultiplied alpha, 4 bytes per pixel.
    static func premultiplied(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// An sRGB image of premultiplied RGBA bytes.
    static func image(premultiplied bytes: [UInt8], width: Int, height: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// Whether every pixel is opaque.
    var isOpaque: Bool {
        stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 }
    }

    /// The colour channels, 3 bytes per pixel.
    var rgb: Data {
        var result = Data(capacity: width * height * 3)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            result.append(contentsOf: bytes[index..<(index + 3)])
        }
        return result
    }

    /// The alpha channel, 1 byte per pixel.
    var alpha: Data {
        Data(stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] })
    }
}
