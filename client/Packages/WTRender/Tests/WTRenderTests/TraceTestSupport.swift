import CoreGraphics
import CoreText
import Foundation
import WTGeometry
@testable import WTRender

/// Fixtures and render-back for the trace kernel tests: bitmaps drawn in code (y-down, over
/// white) and traced paths filled back into a bitmap of the same size.
enum TraceFixtures {
    /// A `width` × `height` white bitmap with `draw` applied in y-down pixel space.
    static func bitmap(width: Int, height: Int, antialias: Bool = false, _ draw: (CGContext) -> Void) -> Trace.Bitmap {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        context.setShouldAntialias(antialias)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return Trace.Bitmap(cgImage: context.makeImage()!)!
    }

    /// Black line art: a filled rectangle, a ring (a disc with a hole) and a triangle.
    static func lineArt() -> Trace.Bitmap {
        bitmap(width: 200, height: 160) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 10, y: 10, width: 60, height: 40))
            context.addEllipse(in: CGRect(x: 90, y: 10, width: 90, height: 90))
            context.addEllipse(in: CGRect(x: 115, y: 35, width: 40, height: 40))
            context.fillPath(using: .evenOdd)
            context.move(to: CGPoint(x: 20, y: 150))
            context.addLine(to: CGPoint(x: 80, y: 70))
            context.addLine(to: CGPoint(x: 90, y: 150))
            context.closePath()
            context.fillPath()
        }
    }

    /// A single ring: outer disc radius 40, hole radius 20, centred at (50, 50).
    static func ring() -> Trace.Bitmap {
        bitmap(width: 100, height: 100) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.addEllipse(in: CGRect(x: 10, y: 10, width: 80, height: 80))
            context.addEllipse(in: CGRect(x: 30, y: 30, width: 40, height: 40))
            context.fillPath(using: .evenOdd)
        }
    }

    /// Lettering: "Ag" set in Helvetica Bold at 90 px.
    static func lettering() -> Trace.Bitmap {
        bitmap(width: 180, height: 120) { context in
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 90, nil)
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)] as CFDictionary
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "Ag" as CFString, attributes)!)
            // Glyphs draw y-up: undo the fixture's flip locally.
            context.saveGState()
            context.translateBy(x: 0, y: 120)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = CGPoint(x: 10, y: 35)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    /// A "photograph": bands of four colours with a soft diagonal gradient between two of them.
    static func photograph(width: Int = 160, height: Int = 120) -> Trace.Bitmap {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let t = Double(x + y) / Double(width + height)
                let rgb: (Double, Double, Double)
                if y < height / 3 {
                    rgb = (0.2 + 0.6 * t, 0.4, 0.9 - 0.5 * t)  // sky
                } else if y < 2 * height / 3 {
                    rgb = (0.9, 0.7, 0.2)  // sand
                } else {
                    rgb = (0.1, 0.5 + 0.2 * t, 0.2)  // grass
                }
                pixels[offset] = UInt8(rgb.0 * 255)
                pixels[offset + 1] = UInt8(rgb.1 * 255)
                pixels[offset + 2] = UInt8(rgb.2 * 255)
            }
        }
        return Trace.Bitmap(width: width, height: height, pixels: pixels)!
    }

    /// A noisy scan: a black square over white with deterministic salt-and-pepper noise.
    static func noisyScan(noise: Double = 0.02) -> Trace.Bitmap {
        var random = SeededRandom(seed: 7)
        var pixels = [UInt8](repeating: 255, count: 120 * 120 * 4)
        for y in 0..<120 {
            for x in 0..<120 {
                var black = x >= 30 && x < 90 && y >= 30 && y < 90
                if random.nextUnit() < noise {
                    black.toggle()
                }
                if black {
                    let offset = (y * 120 + x) * 4
                    pixels[offset] = 0
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 0
                }
            }
        }
        return Trace.Bitmap(width: 120, height: 120, pixels: pixels)!
    }

    /// The paths filled (and stroked) over white into a bitmap of `width` × `height`, with the
    /// paths' coordinates in pixel space.
    static func renderBack(_ result: Trace.Result, width: Int, height: Int) -> Trace.Bitmap {
        bitmap(width: width, height: height, antialias: true) { context in
            for path in result.paths {
                let cgPath = CGMutablePath()
                for contour in path.contours {
                    guard let start = contour.startPoint else { continue }
                    cgPath.move(to: CGPoint(x: start.x, y: start.y))
                    for segment in contour.segments {
                        cgPath.addCurve(to: CGPoint(x: segment.p3.x, y: segment.p3.y), control1: CGPoint(x: segment.p1.x, y: segment.p1.y), control2: CGPoint(x: segment.p2.x, y: segment.p2.y))
                    }
                    if contour.isClosed {
                        cgPath.closeSubpath()
                    }
                }
                if let fill = path.fill {
                    context.addPath(cgPath)
                    context.setFillColor(CGColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1))
                    context.fillPath(using: .winding)
                }
                if let stroke = path.stroke, let width = path.strokeWidth {
                    context.addPath(cgPath)
                    context.setLineWidth(width)
                    context.setStrokeColor(CGColor(srgbRed: stroke.red, green: stroke.green, blue: stroke.blue, alpha: 1))
                    context.strokePath()
                }
            }
        }
    }

    /// The fraction of pixels whose channels differ by more than `tolerance` of 255.
    static func difference(_ a: Trace.Bitmap, _ b: Trace.Bitmap, tolerance: Int = 96) -> Double {
        var differing = 0
        for index in 0..<(a.width * a.height) {
            for channel in 0..<3 where abs(Int(a.pixels[index * 4 + channel]) - Int(b.pixels[index * 4 + channel])) > tolerance {
                differing += 1
                break
            }
        }
        return Double(differing) / Double(a.width * a.height)
    }

    /// How many pixels are darker than mid-grey.
    static func darkPixels(_ bitmap: Trace.Bitmap) -> Int {
        var count = 0
        for index in 0..<(bitmap.width * bitmap.height) {
            let sum: Int = Int(bitmap.pixels[index * 4]) + Int(bitmap.pixels[index * 4 + 1]) + Int(bitmap.pixels[index * 4 + 2])
            if sum < 384 {
                count += 1
            }
        }
        return count
    }
}

/// A small deterministic generator (SplitMix64).
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUnit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
