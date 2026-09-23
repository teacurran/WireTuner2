// Encoders for palette images (IO-022): GIF89a with its own LZW coder (graphic control extension
// for the transparent index, optional interlacing), 8-bit palette PNG with `tRNS` (own writer:
// ImageIO's indexed PNG carries no transparency), and 8-bit palette TIFF through ImageIO from an
// indexed `CGImage`.

import CoreGraphics
import Foundation
import ImageIO

enum GIFWriter {
    static func data(_ image: IndexedImage, interlaced: Bool) -> Data {
        var bits = 1
        while 1 << bits < image.palette.count {
            bits += 1
        }
        var out = Data("GIF89a".utf8)
        out.appendLittleEndian(UInt16(image.width))
        out.appendLittleEndian(UInt16(image.height))
        out.append(0x80 | 0x70 | UInt8(bits - 1))  // global table, 8-bit colour resolution
        out.append(contentsOf: [0, 0])  // background index, aspect
        for index in 0..<(1 << bits) {
            let color = index < image.palette.count ? image.palette[index] : RGB(r: 0, g: 0, b: 0)
            out.append(contentsOf: [color.r, color.g, color.b])
        }
        if let transparent = image.transparentIndex {
            out.append(contentsOf: [0x21, 0xF9, 0x04, 0x01, 0, 0, UInt8(transparent), 0])
        }
        out.append(0x2C)
        out.appendLittleEndian(UInt16(0))
        out.appendLittleEndian(UInt16(0))
        out.appendLittleEndian(UInt16(image.width))
        out.appendLittleEndian(UInt16(image.height))
        out.append(interlaced ? 0x40 : 0)
        let minimum = max(bits, 2)
        out.append(UInt8(minimum))
        let rows = interlaced ? interlacedRows(image.height) : Array(0..<image.height)
        var pixels = [UInt8]()
        pixels.reserveCapacity(image.indices.count)
        for row in rows {
            pixels += image.indices[(row * image.width)..<((row + 1) * image.width)]
        }
        let compressed = lzw(pixels, minimumCodeSize: minimum)
        var offset = 0
        while offset < compressed.count {
            let length = min(255, compressed.count - offset)
            out.append(UInt8(length))
            out.append(contentsOf: compressed[offset..<(offset + length)])
            offset += length
        }
        out.append(0)
        out.append(0x3B)
        return out
    }

    /// The row order of an interlaced GIF: every 8th row from 0, every 8th from 4, every 4th
    /// from 2, every 2nd from 1.
    static func interlacedRows(_ height: Int) -> [Int] {
        [(0, 8), (4, 8), (2, 4), (1, 2)].flatMap { start, step in Array(stride(from: start, to: height, by: step)) }
    }

    /// GIF's variable-length LZW (codes LSB first, clear code first, reset at 4095 codes).
    static func lzw(_ pixels: [UInt8], minimumCodeSize: Int) -> [UInt8] {
        let clear = 1 << minimumCodeSize
        let end = clear + 1
        var output = [UInt8]()
        var buffer: UInt32 = 0
        var bitCount = 0
        var codeSize = minimumCodeSize + 1
        var limit = 1 << codeSize
        var next = end + 1
        var table: [Int: Int] = [:]
        func emit(_ code: Int) {
            buffer |= UInt32(code) << UInt32(bitCount)
            bitCount += codeSize
            while bitCount >= 8 {
                output.append(UInt8(buffer & 0xFF))
                buffer >>= 8
                bitCount -= 8
            }
            if next >= limit && codeSize < 12 {
                codeSize += 1
                limit = 1 << codeSize
            }
        }
        emit(clear)
        guard var prefix = pixels.first.map(Int.init) else {
            emit(end)
            if bitCount > 0 {
                output.append(UInt8(buffer & 0xFF))
            }
            return output
        }
        for pixel in pixels.dropFirst() {
            let key = prefix << 8 | Int(pixel)
            if let code = table[key] {
                prefix = code
                continue
            }
            emit(prefix)
            prefix = Int(pixel)
            if next >= 4095 {
                emit(clear)
                table.removeAll(keepingCapacity: true)
                next = end + 1
                codeSize = minimumCodeSize + 1
                limit = 1 << codeSize
            } else {
                table[key] = next
                next += 1
            }
        }
        emit(prefix)
        emit(end)
        if bitCount > 0 {
            output.append(UInt8(buffer & 0xFF))
        }
        return output
    }
}

enum PalettePNGWriter {
    static func data(_ image: IndexedImage, interlaced: Bool, pixelsPerInch: Double) -> Data {
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ body: Data) {
            out.appendBigEndian(UInt32(body.count))
            let typed = Data(type.utf8) + body
            out.append(typed)
            out.appendBigEndian(CRC32.checksum(typed))
        }
        var header = Data()
        header.appendBigEndian(UInt32(image.width))
        header.appendBigEndian(UInt32(image.height))
        header.append(contentsOf: [8, 3, 0, 0, interlaced ? 1 : 0])
        chunk("IHDR", header)
        chunk("sRGB", Data([0]))
        var physical = Data()
        let perMetre = UInt32((pixelsPerInch / 0.0254).rounded())
        physical.appendBigEndian(perMetre)
        physical.appendBigEndian(perMetre)
        physical.append(1)
        chunk("pHYs", physical)
        chunk("PLTE", Data(image.palette.flatMap { [$0.r, $0.g, $0.b] }))
        if let transparent = image.transparentIndex {
            chunk("tRNS", Data([UInt8](repeating: 255, count: transparent) + [0]))
        }
        var raw = Data()
        raw.reserveCapacity(image.indices.count + image.height * 2)
        let passes = interlaced ? [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)] : [(0, 0, 1, 1)]
        for (x0, y0, dx, dy) in passes where x0 < image.width && y0 < image.height {
            for y in stride(from: y0, to: image.height, by: dy) {
                raw.append(0)
                for x in stride(from: x0, to: image.width, by: dx) {
                    raw.append(image.indices[y * image.width + x])
                }
            }
        }
        chunk("IDAT", Zlib.compress(raw))
        chunk("IEND", Data())
        return out
    }
}

enum PaletteTIFFWriter {
    /// `image` as a palette TIFF (photometric 3) through ImageIO, with `compression` (a TIFF
    /// compression code) and resolution.
    static func data(_ image: IndexedImage, compression: Int, pixelsPerInch: Double) -> Data {
        var table = [UInt8]()
        for color in image.palette {
            table += [color.r, color.g, color.b]
        }
        let base = CGColorSpace(name: CGColorSpace.sRGB)!
        // A palette of 1 ... 256 sRGB entries always makes an indexed space.
        let space = CGColorSpace(indexedBaseSpace: base, last: image.palette.count - 1, colorTable: table)!
        let provider = CGDataProvider(data: Data(image.indices) as CFData)!
        let picture = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: image.width, space: space, bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        // ImageIO encodes every 8-bit indexed image as TIFF.
        return ImageEncoding.encode(picture, type: .tiff, properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: compression],
            kCGImagePropertyDPIWidth: pixelsPerInch,
            kCGImagePropertyDPIHeight: pixelsPerInch,
        ])!
    }
}
