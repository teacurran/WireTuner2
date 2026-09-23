// Animated GIF and APNG (WEB-019; animation.adoc, "Client").
//
// GIF: every frame is quantized by the bitmap exporter's quantizer to its own palette of up to
// *Colors* entries with the chosen *Dither* (a local colour table per frame, so each frame has
// 256 colours to itself) and written by the GIF writer's LZW coder: a graphic control extension
// per frame carries the delay in hundredths of a second and the transparent index, and the
// NETSCAPE2.0 application extension the number of repeats.  A transparent background is one-bit
// transparency, each frame replacing the last (disposal "restore to background").  ImageIO's GIF
// encoder offers neither a colour count nor a dither, which is why this writer is our own.
//
// APNG: ImageIO's PNG encoder with `kCGImagePropertyAPNGDelayTime` per frame and
// `kCGImagePropertyAPNGLoopCount`, full colour with real transparency.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WTRender

enum AnimatedImageWriter {
    static func writeGIF(scene: ExportScene, options: AnimatedGIFOptions, to url: URL, progress: ExportProgress) throws -> [String] {
        let plan = try AnimationPlan(scene: scene, options: options.common)
        let settings = PaletteSettings(choice: .adaptive, colors: options.colors, ditherPercent: options.ditherPercent)
        try settings.validate()
        let transparent = plan.background == .transparent
        let timing = plan.centisecondDelays()
        var frames: [(image: IndexedImage, delay: Int)] = []
        for (position, entry) in timing.frames.enumerated() {
            try progress.check()
            let pixels = StraightPixels(plan.render(entry.index, alpha: true))
            frames.append((try Quantizer.indexed(pixels, settings: settings, transparent: transparent, matte: .white), entry.delay))
            progress.report(Double(position + 1) / Double(timing.frames.count + 1))
        }
        try progress.check()
        do {
            try animatedGIF(frames, width: plan.width, height: plan.height, plays: plan.plays).write(to: url)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        var notes: [String] = []
        if timing.dropped > 0 {
            notes.append("\(timing.dropped) frame\(timing.dropped == 1 ? "" : "s") shorter than 0.02 s left out: GIF delays are hundredths of a second and browsers slow shorter ones")
        }
        return notes
    }

    /// An animated GIF89a of `frames`, each with its own colour table.  `plays` 0 loops forever,
    /// 1 plays once (no looping extension), `n` repeats `n - 1` times.
    static func animatedGIF(_ frames: [(image: IndexedImage, delay: Int)], width: Int, height: Int, plays: Int) -> Data {
        var out = Data("GIF89a".utf8)
        out.appendLittleEndian(UInt16(width))
        out.appendLittleEndian(UInt16(height))
        out.append(0x70)  // no global table, 8-bit colour resolution
        out.append(contentsOf: [0, 0])
        if plays != 1 {
            out.append(contentsOf: [0x21, 0xFF, 0x0B])
            out.append(Data("NETSCAPE2.0".utf8))
            out.append(contentsOf: [0x03, 0x01])
            out.appendLittleEndian(UInt16(plays == 0 ? 0 : min(plays - 1, 0xFFFF)))
            out.append(0)
        }
        for (image, delay) in frames {
            var bits = 1
            while 1 << bits < image.palette.count {
                bits += 1
            }
            let transparent = image.transparentIndex
            // Disposal 2 (restore to background) when the frame has transparent pixels, so the
            // frame before does not show through; otherwise 1 (leave in place).
            let packed: UInt8 = transparent == nil ? 0x04 : 0x08 | 0x01
            out.append(contentsOf: [0x21, 0xF9, 0x04, packed])
            out.appendLittleEndian(UInt16(min(delay, 0xFFFF)))
            out.append(contentsOf: [UInt8(transparent ?? 0), 0])
            out.append(0x2C)
            out.appendLittleEndian(UInt16(0))
            out.appendLittleEndian(UInt16(0))
            out.appendLittleEndian(UInt16(image.width))
            out.appendLittleEndian(UInt16(image.height))
            out.append(0x80 | UInt8(bits - 1))
            for index in 0..<(1 << bits) {
                let color = index < image.palette.count ? image.palette[index] : RGB(r: 0, g: 0, b: 0)
                out.append(contentsOf: [color.r, color.g, color.b])
            }
            let minimum = max(bits, 2)
            out.append(UInt8(minimum))
            let compressed = GIFWriter.lzw(image.indices, minimumCodeSize: minimum)
            var offset = 0
            while offset < compressed.count {
                let length = min(255, compressed.count - offset)
                out.append(UInt8(length))
                out.append(contentsOf: compressed[offset..<(offset + length)])
                offset += length
            }
            out.append(0)
        }
        out.append(0x3B)
        return out
    }

    static func writeAPNG(scene: ExportScene, options: APNGOptions, to url: URL, progress: ExportProgress) throws -> [String] {
        let plan = try AnimationPlan(scene: scene, options: options.common)
        // ImageIO always has a PNG encoder: only an unwritable place fails.
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, plan.frames.count, nil) else {
            throw ExportError.writeFailed("\(url.path) cannot be written")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: plan.plays]] as CFDictionary)
        for index in plan.frames.indices {
            do {
                try progress.check()
            } catch {
                // An unfinalized destination writes nothing; remove whatever was created.
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            let times = plan.times(index)
            let frame = plan.image(index, alpha: true)
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: times.end - times.start]] as CFDictionary)
            progress.report(Double(index + 1) / Double(plan.frames.count + 1))
        }
        CGImageDestinationFinalize(destination)
        return []
    }
}
