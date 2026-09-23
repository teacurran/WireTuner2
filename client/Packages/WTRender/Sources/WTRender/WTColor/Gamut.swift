// Gamut mapping and in-gamut indicators (COLOR-024; docs/_includes/color/spot-process.adoc).
// The mapping is CSS Color 4's (section 13.2, "CSS gamut mapping to an RGB destination"):
// OKLCH chroma reduction by bisection, stopping as soon as clipping the candidate changes it
// by less than the just-noticeable difference.  Own code, no ColorSync, so the answer is the
// same on every Mac; *Convert to sRGB*, *Convert to Display P3*, the HTML and SVG sRGB
// fallbacks and the Colour Mixer's indicator all call this one function.

import CoreGraphics
import Foundation

extension WTColor {
    public enum Gamut {
        /// ΔE OK below which a clipped colour is indistinguishable from its unclipped one.
        public static let justNoticeableDifference = 0.02
        /// The bisection's chroma resolution.
        static let chromaEpsilon = 0.0001
        /// Tolerance of the mapping's own in-gamut test (color.js's), on encoded components.
        static let mappingTolerance = 0.000_075
        /// Tolerance of the indicator's in-gamut test (COLOR-002: linear components within
        /// 0...1 after conversion, give or take 1/1024).
        public static let indicatorTolerance = 1.0 / 1024

        /// Whether `color` lies inside `space` (sRGB or Display P3): every linear-light
        /// component within 0...1 widened by `tolerance`.  CMYK is taken through its naive
        /// sRGB and so is always inside both.
        public static func contains(_ color: Color, in space: Color.Space, tolerance: Double = indicatorTolerance) -> Bool {
            let linear = Math.linearRGB(color, in: space)
            return inRange(linear, tolerance: tolerance)
        }

        static func inRange(_ values: SIMD3<Double>, tolerance: Double) -> Bool {
            values.min() >= -tolerance && values.max() <= 1 + tolerance
        }

        /// `color` mapped into `space` (sRGB or Display P3) by the CSS Color 4 algorithm; the
        /// result is a colour of `space` with components in 0...1 and the original alpha.
        public static func map(_ color: Color, into space: Color.Space) -> Color {
            precondition(space.isRGB, "Gamut.map maps into sRGB or Display P3")
            func make(_ rgb: SIMD3<Double>) -> Color {
                Color(space: space, components: SIMD4(rgb.x, rgb.y, rgb.z, 0), alpha: color.alpha)
            }
            let origin = Math.oklch(fromOKLab: Math.oklab(color))
            if origin.x >= 1 {
                return make(SIMD3(1, 1, 1))
            }
            if origin.x <= 0 {
                return make(SIMD3(0, 0, 0))
            }
            let direct = Math.rgb(color, in: space)
            if inRange(direct, tolerance: mappingTolerance) {
                return make(Math.clipped(direct))
            }
            func candidate(_ chroma: Double) -> Color {
                Color(oklchL: origin.x, chroma: chroma, hue: origin.z)
            }
            func clip(_ current: Color) -> Color {
                make(Math.clipped(Math.rgb(current, in: space)))
            }
            var current = candidate(origin.y)
            var clipped = clip(current)
            if Math.deltaEOK(clipped, current) < justNoticeableDifference {
                return clipped
            }
            var low = 0.0
            var high = origin.y
            var lowInGamut = true
            while high - low > chromaEpsilon {
                let chroma = (low + high) / 2
                current = candidate(chroma)
                if lowInGamut && inRange(Math.rgb(current, in: space), tolerance: mappingTolerance) {
                    low = chroma
                    continue
                }
                clipped = clip(current)
                let error = Math.deltaEOK(clipped, current)
                if error < justNoticeableDifference {
                    if justNoticeableDifference - error < chromaEpsilon {
                        return clipped
                    }
                    lowInGamut = false
                    low = chroma
                } else {
                    high = chroma
                }
            }
            return clipped
        }

        /// The narrowest RGB gamut a colour fits: what the Colour Mixer's indicator reads.
        public enum Indicator: Hashable, Sendable {
            case sRGB
            case displayP3
            case outOfGamut
        }

        /// The indicator for `color`.
        public static func indicator(for color: Color) -> Indicator {
            if contains(color, in: .sRGB) {
                return .sRGB
            }
            return contains(color, in: .displayP3) ? .displayP3 : .outOfGamut
        }
    }

    /// "Can the screen this window is on show this colour" (COLOR-024's display query): built
    /// from the window's screen profile and rebuilt, by whoever owns the window, on
    /// `NSWindow.didChangeScreenProfileNotification` and `didChangeScreenNotification`
    /// (CMS-006), so the answer follows the window to another display at once.
    public struct DisplayGamut: @unchecked Sendable {
        /// The display's colour space (`NSScreen.colorSpace?.cgColorSpace`).
        public let colorSpace: CGColorSpace
        /// The display space widened to accept components outside 0...1.
        private let extended: CGColorSpace
        /// sRGB and Display P3 displays are answered by the exact formulas; others through
        /// ColorSync.
        private let formulaSpace: Color.Space?

        public init(colorSpace: CGColorSpace) {
            self.colorSpace = colorSpace
            extended = CGColorSpaceCreateExtended(colorSpace) ?? colorSpace
            switch colorSpace.name {
            case CGColorSpace.sRGB: formulaSpace = .sRGB
            case CGColorSpace.displayP3: formulaSpace = .displayP3
            default: formulaSpace = nil
            }
        }

        public static let sRGB = DisplayGamut(colorSpace: Spaces.sRGB)
        public static let displayP3 = DisplayGamut(colorSpace: Spaces.displayP3)

        /// Whether the display can show `color` without clipping it (1/1024 tolerance).
        public func canShow(_ color: Color) -> Bool {
            if let formulaSpace {
                return Gamut.contains(color, in: formulaSpace)
            }
            guard let converted = color.cgColor.converted(to: extended, intent: .relativeColorimetric, options: nil),
                  let components = converted.components, components.count >= 3
            else {
                return false
            }
            let tolerance = Gamut.indicatorTolerance
            return components.dropLast().allSatisfy { $0 >= -tolerance && $0 <= 1 + tolerance }
        }

        /// Whether the display shows `color` clipped: the Mixer's *clipped on this display*.
        public func clips(_ color: Color) -> Bool {
            !canShow(color)
        }
    }
}
