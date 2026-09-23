// Halftone screens (PRINT-009; docs/_includes/printing/halftones.adoc and output-devices.adoc,
// "In-app screener").  A screen is a spot function laid on a grid of cells at an angle and a
// frequency; a pixel inks when the plate's coverage there exceeds the cell's threshold at the
// pixel's position.  Thresholds are the spot function's rank within the cell (the fraction of
// the cell whose spot value is higher), so a flat tint of coverage c inks c of every cell
// whatever the shape.

import Foundation

/// The dot shape of a screen (`HalftoneShape`).
public enum HalftoneShape: String, Hashable, Sendable, CaseIterable {
    case round
    case ellipse
    case line
    case diamond
    case square
    case cross

    /// The spot function at cell position (`x`, `y`), each -1...1 from the cell centre: cells
    /// ink in descending order of this value, so a dot grows from where it is largest.
    public func priority(x: Double, y: Double) -> Double {
        switch self {
        case .round: return -(x * x + y * y)
        case .ellipse: return -(x * x + (y / 0.6) * (y / 0.6))
        case .line: return -abs(y)
        case .diamond: return -(abs(x) + abs(y))
        case .square: return -max(abs(x), abs(y))
        case .cross: return -min(abs(x), abs(y))
        }
    }
}

/// One halftone screen (`Halftone`): shape, angle in degrees and frequency in lines per inch.
public struct HalftoneScreen: Hashable, Sendable, CustomStringConvertible {
    public var shape: HalftoneShape
    public var angle: Double
    public var frequency: Double

    /// Read-time rules (halftones.adoc): the angle reduced modulo 360, a frequency outside
    /// 1...600 reads as 60.
    public init(shape: HalftoneShape = .round, angle: Double = 45, frequency: Double = 60) {
        self.shape = shape
        let reduced = angle.isFinite ? angle.truncatingRemainder(dividingBy: 360) : 0
        self.angle = reduced < 0 ? reduced + 360 : reduced
        self.frequency = frequency.isFinite && (1...600).contains(frequency) ? frequency : 60
    }

    /// `Line 45° 40 lpi`, as the review sheet names a screen.
    public var description: String {
        "\(shape.rawValue.capitalized) \(HalftoneScreen.format(angle))° \(HalftoneScreen.format(frequency)) lpi"
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// A screen's threshold table over one cell, `resolution` × `resolution` samples, as 16-bit
/// thresholds: a pixel of coverage c (0...65535) inks where c exceeds its sample's threshold.
struct ThresholdCell: Sendable {
    static let resolution = 256

    let thresholds: [UInt16]

    /// Equal spot values share one threshold (the midpoint of their ranks), so a Line screen's
    /// rows ink whole.
    init(shape: HalftoneShape) {
        let n = ThresholdCell.resolution
        var samples: [(value: Double, index: Int)] = []
        samples.reserveCapacity(n * n)
        for row in 0..<n {
            for column in 0..<n {
                let x = (Double(column) + 0.5) / Double(n) * 2 - 1
                let y = (Double(row) + 0.5) / Double(n) * 2 - 1
                // Rounded so values equal by symmetry compare equal despite floating error.
                let value = (shape.priority(x: x, y: y) * 1e9).rounded() / 1e9
                samples.append((value, row * n + column))
            }
        }
        samples.sort { $0.value > $1.value }
        var thresholds = [UInt16](repeating: 0, count: n * n)
        let count = Double(samples.count)
        var start = 0
        while start < samples.count {
            var end = start + 1
            while end < samples.count && samples[end].value == samples[start].value {
                end += 1
            }
            let rank = (Double(start) + Double(end)) / 2 / count
            let threshold = UInt16(min(rank * 65535, 65534))
            for sample in samples[start..<end] {
                thresholds[sample.index] = threshold
            }
            start = end
        }
        self.thresholds = thresholds
    }

    private static let cache = RenderCache<HalftoneShape, ThresholdCell>(capacity: 16)

    static func cached(_ shape: HalftoneShape) -> ThresholdCell {
        cache.value(for: shape) { ThresholdCell(shape: shape) }
    }
}
