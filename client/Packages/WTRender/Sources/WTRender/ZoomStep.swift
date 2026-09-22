// The zoom ladder that tile keys are quantized on (docs/spec/client.adoc, "The display list":
// tiles are keyed by "zoom-ladder step").
//
// Tiles are rasterized at a step's scale and composited at `zoom / step.scale`, so the ladder
// must be fine enough that a settled zoom between two steps is not visibly resampled: with 64
// steps per octave neighbouring steps differ by 1.09% and any zoom is within 0.55% of a step.
// The View menu's preset ladder (6, 12, 25, 50, 100, ..., 25600 percent) lives on this grid
// too, exactly for the powers of two and within 0.2% for 6% and 12%.

import Foundation

/// One rung of the rasterization ladder: the scale `2^(index / stepsPerOctave)` in device
/// pixels per pasteboard unit.
public struct ZoomStep: Hashable, Sendable, Comparable {
    /// How many rungs one doubling of the scale is divided into.
    public static let stepsPerOctave = 64

    public let index: Int

    public init(index: Int) {
        self.index = index
    }

    /// The rung nearest to `scale` (device pixels per pasteboard unit).  Non-positive or
    /// non-finite scales map to the 100% rung.
    public init(nearest scale: Double) {
        guard scale.isFinite, scale > 0 else {
            self.init(index: 0)
            return
        }
        self.init(index: Int((log2(scale) * Double(ZoomStep.stepsPerOctave)).rounded()))
    }

    /// The rung's rasterization scale.
    public var scale: Double {
        pow(2, Double(index) / Double(ZoomStep.stepsPerOctave))
    }

    /// The rung `count` steps up (positive) or down (negative) the ladder.
    public func advanced(by count: Int) -> ZoomStep {
        ZoomStep(index: index + count)
    }

    public static func < (lhs: ZoomStep, rhs: ZoomStep) -> Bool {
        lhs.index < rhs.index
    }
}

/// The View menu's preset magnifications (docs/_includes/basics/document-view.adoc, "Zoom steps").
public enum ZoomLadder {
    /// 6% to 25,600%, doubling.
    public static let presets: [Double] = [0.06, 0.12, 0.25, 0.5, 1, 2, 4, 8, 16, 32, 64, 128, 256]

    /// The first preset strictly above `zoom`, or the top preset.
    public static func zoomIn(from zoom: Double) -> Double {
        presets.first { $0 > zoom + 1e-9 } ?? presets[presets.count - 1]
    }

    /// The last preset strictly below `zoom`, or the bottom preset.
    public static func zoomOut(from zoom: Double) -> Double {
        presets.last { $0 < zoom - 1e-9 } ?? presets[0]
    }
}
