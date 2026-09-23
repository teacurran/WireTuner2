// REND-007's per-tile comparison (docs/spec/testing.adoc, "Geometry and rendering"): a tile
// passes when every pixel more than one pixel away from an edge matches within 2/255 per
// channel, edge pixels match within 40/255 (MSAA against analytic coverage), and no more than
// 0.1% of the tile's pixels fail either bound.  "Away from an edge" is judged on the Core
// Graphics tile, the reference: a pixel whose 3 × 3 neighbourhood is one flat colour.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import WTRender

struct TileParity: CustomStringConvertible {
    static let interiorTolerance = 2
    static let edgeTolerance = 40
    static let failingFraction = 0.001

    let pixels: Int
    private(set) var interiorFailures = 0
    private(set) var edgeFailures = 0
    private(set) var maxInteriorDifference = 0
    private(set) var maxEdgeDifference = 0

    init(reference: BitmapSurface, candidate: BitmapSurface) {
        precondition(reference.width == candidate.width && reference.height == candidate.height)
        let width = reference.width
        let height = reference.height
        pixels = width * height
        let lhs = TileParity.words(of: reference)
        let rhs = TileParity.words(of: candidate)
        let flat = TileParity.flatMask(lhs, width: width, height: height)
        lhs.withUnsafeBufferPointer { a in
            rhs.withUnsafeBufferPointer { b in
                for index in 0..<pixels where a[index] != b[index] {
                    let x = a[index]
                    let y = b[index]
                    var difference = 0
                    for shift in stride(from: 0, to: 32, by: 8) {
                        difference = max(difference, abs(Int((x >> UInt32(shift)) & 0xFF) - Int((y >> UInt32(shift)) & 0xFF)))
                    }
                    if flat[index] {
                        maxInteriorDifference = max(maxInteriorDifference, difference)
                        if difference > TileParity.interiorTolerance {
                            interiorFailures += 1
                        }
                    } else {
                        maxEdgeDifference = max(maxEdgeDifference, difference)
                        if difference > TileParity.edgeTolerance {
                            edgeFailures += 1
                        }
                    }
                }
            }
        }
    }

    /// The surface's pixels as packed words, row-major without row padding.
    static func words(of surface: BitmapSurface) -> [UInt32] {
        let row = surface.context.bytesPerRow
        let base = UnsafeRawPointer(surface.context.data!)
        var result = [UInt32](repeating: 0, count: surface.width * surface.height)
        result.withUnsafeMutableBytes { destination in
            for y in 0..<surface.height {
                (destination.baseAddress! + y * surface.width * 4).copyMemory(from: base + y * row, byteCount: surface.width * 4)
            }
        }
        return result
    }

    /// Whether each pixel's 3 × 3 neighbourhood (clamped at the borders) is one colour.
    static func flatMask(_ words: [UInt32], width: Int, height: Int) -> [Bool] {
        // Pass 1: the pixel equals its left and right neighbours.  Pass 2: that holds for the
        // rows above and below too, and they match the pixel.
        var rows = [Bool](repeating: false, count: words.count)
        var result = [Bool](repeating: false, count: words.count)
        words.withUnsafeBufferPointer { w in
            rows.withUnsafeMutableBufferPointer { r in
                for y in 0..<height {
                    let base = y * width
                    for x in 0..<width {
                        let center = w[base + x]
                        r[base + x] = w[base + max(x - 1, 0)] == center && w[base + min(x + 1, width - 1)] == center
                    }
                }
            }
            rows.withUnsafeBufferPointer { r in
                result.withUnsafeMutableBufferPointer { f in
                    for y in 0..<height {
                        let above = max(y - 1, 0) * width
                        let below = min(y + 1, height - 1) * width
                        let base = y * width
                        for x in 0..<width {
                            let center = w[base + x]
                            f[base + x] = r[base + x] && r[above + x] && r[below + x] && w[above + x] == center && w[below + x] == center
                        }
                    }
                }
            }
        }
        return result
    }

    var failures: Int { interiorFailures + edgeFailures }

    var passes: Bool { Double(failures) <= Double(pixels) * TileParity.failingFraction }

    var description: String {
        "\(failures) of \(pixels) failing (interior \(interiorFailures), max Δ\(maxInteriorDifference); edge \(edgeFailures), max Δ\(maxEdgeDifference))"
    }
}

/// Failing tiles written as CG | Metal | difference, named by document and tile key.
enum Triptych {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WTRenderParity", isDirectory: true)

    /// Writes the triptych and returns its URL; nil when it could not be written.
    @discardableResult
    static func write(reference: BitmapSurface, candidate: BitmapSurface, name: String, directory: URL = Triptych.directory) -> URL? {
        let width = reference.width
        let height = reference.height
        guard let strip = BitmapSurface(width: width * 3, height: height),
              let referenceImage = reference.makeImage(),
              let candidateImage = candidate.makeImage(),
              let difference = BitmapSurface(width: width, height: height)
        else {
            return nil
        }
        // Difference: the per-pixel maximum channel difference, amplified, on black.
        let out = difference.context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let delta = reference.pixel(x: x, y: y).maxChannelDifference(to: candidate.pixel(x: x, y: y))
                let value = UInt8(min(delta * 4, 255))
                let offset = y * difference.context.bytesPerRow + x * 4
                out[offset] = value
                out[offset + 1] = delta > TileParity.edgeTolerance ? 0 : value
                out[offset + 2] = delta > TileParity.interiorTolerance ? 0 : value
                out[offset + 3] = 255
            }
        }
        guard let differenceImage = difference.makeImage() else {
            return nil
        }
        let size = CGSize(width: width, height: height)
        strip.context.draw(referenceImage, in: CGRect(origin: .zero, size: size))
        strip.context.draw(candidateImage, in: CGRect(origin: CGPoint(x: width, y: 0), size: size))
        strip.context.draw(differenceImage, in: CGRect(origin: CGPoint(x: 2 * width, y: 0), size: size))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "@" ? $0 : "_" }
        let url = directory.appendingPathComponent(String(safe) + ".png")
        guard let image = strip.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }
}
