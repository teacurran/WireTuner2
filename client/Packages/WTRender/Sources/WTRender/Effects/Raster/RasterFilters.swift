// The raster effects' filter graphs (FX-010, FX-011; raster-effects.adoc, "Raster stage").
//
// * Blur: `CIBoxBlur` (Basic) or `CIGaussianBlur` (σ = the radius) of the result.
// * Sharpen: `CISharpenLuminance` (Basic); Unsharp Mask adds `amount` times the difference to a
//   `CIGaussianBlur` of the result wherever that difference exceeds the threshold.
// * Shadows: the result's alpha offset along `angle`, blurred, tinted and composited under it
//   (drop) or, inverted, clipped inside it (inner).  Glows: the alpha dilated by `offset` with
//   `CIMorphologyMaximum`, blurred and tinted, under (glow) or inverted and clipped inside (inner).
// * Bevels and embosses: a height field from the alpha's distance field shaped by the edge curve,
//   blurred by the softness and lit from `angle` (normal · light), tinted by the button preset.
// * Feather: the alpha multiplied by a ramp over the distance inside the outline.

import CoreImage
import Foundation
import WTGeometry

struct RasterFilters {
    /// Raster pixels per point.
    let scale: Double
    /// The object's raster resolution in pixels per point: pixel radii are measured in it.
    let docScale: Double
    let context: CIContext

    func apply(_ operation: RasterOperation, to state: inout StageState) {
        let input = state.flattened
        switch operation {
        case .blur(let blur):
            let radius = blur.effectiveRadius * scale / docScale
            let image = RasterCore.image(input)
            let blurred = blur.style == .gaussian ? RasterCore.gaussian(image, sigma: radius) : RasterCore.box(image, radius: radius)
            state.replace(with: render(blurred, like: input))
        case .sharpen(let sharpen):
            state.replace(with: self.sharpen(sharpen, input))
        case .shadow(let shadow):
            let layer = self.shadow(shadow, input)
            switch shadow.style {
            case .dropShadow, .glow: state.below.insert(layer, at: 0)
            case .innerShadow, .innerGlow: state.above.append(layer)
            }
        case .bevelEmboss(let bevel):
            let result = BevelShading.apply(bevel, to: input, scale: scale)
            if bevel.style == .outerBevel {
                state.below.insert(result, at: 0)
            } else {
                state.replace(with: result)
            }
        case .feather(let radius, let softness):
            state.replace(with: Feather.apply(to: input, radius: radius * scale, softness: softness))
        }
    }

    private func render(_ image: CIImage, like pixels: RasterPixels) -> RasterPixels {
        RasterCore.render(image, width: pixels.width, height: pixels.height, context: context)
    }

    func sharpen(_ sharpen: LiveEffect.Sharpen, _ input: RasterPixels) -> RasterPixels {
        let amount = sharpen.effectiveAmount / 100
        let image = RasterCore.image(input)
        switch sharpen.style {
        case .basic:
            return render(RasterCore.filter("CISharpenLuminance", [kCIInputImageKey: image, kCIInputSharpnessKey: amount]), like: input)
        case .unsharpMask:
            let blurred = render(RasterCore.gaussian(image, sigma: sharpen.effectivePixelRadius * scale / docScale), like: input)
            return RasterFilters.unsharp(input, blurred: blurred, amount: amount, threshold: sharpen.effectiveThreshold)
        }
    }

    /// `input + amount × (input − blurred)` per channel where the difference exceeds
    /// `threshold` levels (of 255), kept premultiplied.
    static func unsharp(_ input: RasterPixels, blurred: RasterPixels, amount: Double, threshold: Double) -> RasterPixels {
        var result = input
        let limit = Float(threshold / 255)
        for index in 0..<input.count {
            let alpha = input.data[index * 4 + 3]
            for channel in 0..<3 {
                let offset = index * 4 + channel
                let difference = input.data[offset] - blurred.data[offset]
                guard abs(difference) > limit else { continue }
                result.data[offset] = min(max(input.data[offset] + Float(amount) * difference, 0), alpha)
            }
        }
        return result
    }

    func shadow(_ shadow: LiveEffect.Shadow, _ input: RasterPixels) -> RasterPixels {
        let image = RasterCore.image(input)
        let opacity = shadow.effectiveOpacity / 100
        let sigma = shadow.effectiveSoftness / 3 * scale
        let offset = shadow.effectiveOffset * scale
        let tint = RasterCore.color(shadow.color, opacity: opacity)
        let result: CIImage
        switch shadow.style {
        case .dropShadow, .innerShadow:
            let angle = (shadow.angle.isFinite ? shadow.angle : 0) * .pi / 180
            // Pasteboard is y down and Core Image y up: the angle's y goes up in both.
            let shift = CGAffineTransform(translationX: offset * cos(angle), y: offset * sin(angle))
            if shadow.style == .dropShadow {
                result = RasterCore.sourceIn(tint, RasterCore.gaussian(image.transformed(by: shift), sigma: sigma))
            } else {
                let outside = RasterCore.sourceOut(RasterCore.color(.black, opacity: 1), image)
                let cast = RasterCore.gaussian(outside.transformed(by: shift), sigma: sigma)
                result = RasterCore.sourceIn(RasterCore.sourceIn(tint, cast), image)
            }
        case .glow:
            result = RasterCore.sourceIn(tint, RasterCore.gaussian(RasterCore.dilate(image, radius: offset), sigma: sigma))
        case .innerGlow:
            let outside = RasterCore.sourceOut(RasterCore.color(.black, opacity: 1), image)
            let halo = RasterCore.gaussian(RasterCore.dilate(outside, radius: offset), sigma: sigma)
            result = RasterCore.sourceIn(RasterCore.sourceIn(tint, halo), image)
        }
        return render(result, like: input)
    }
}

// MARK: - Distance fields

enum RasterDistance {
    /// For every pixel, the distance in pixels to the nearest pixel on the other side of the
    /// alpha ≥ 0.5 boundary (0 for pixels outside when `inside`, or inside when not).
    static func field(_ alphas: [Float], width: Int, height: Int, inside: Bool) -> [Double] {
        let infinity = 1e20
        var squared = alphas.map { (($0 >= 0.5) == inside) ? infinity : 0 }
        var line = [Double](repeating: 0, count: max(width, height))
        for column in 0..<width {
            for row in 0..<height { line[row] = squared[row * width + column] }
            let transformed = DistanceField.transform(line, count: height)
            for row in 0..<height { squared[row * width + column] = transformed[row] }
        }
        for row in 0..<height {
            for column in 0..<width { line[column] = squared[row * width + column] }
            let transformed = DistanceField.transform(line, count: width)
            for column in 0..<width { squared[row * width + column] = transformed[column] }
        }
        // A pixel next to the boundary is half a pixel from it.
        return squared.map { $0 > 0 ? min(max($0.squareRoot() - 0.5, 0), 1e9) : 0 }
    }
}

enum Feather {
    /// The ramp exponent for `softness` (0 ... 100): low values keep the interior opaque and fade
    /// sharply at the edge, 100 fades linearly across the radius.
    static func exponent(softness: Double) -> Double {
        0.15 + 0.85 * min(max(softness, 0), 100) / 100
    }

    /// The alpha multiplier `distance` pixels inside the outline for a fade of `radius` pixels.
    static func ramp(distance: Double, radius: Double, softness: Double) -> Double {
        guard radius > 0 else { return 1 }
        return pow(min(max(distance / radius, 0), 1), exponent(softness: softness))
    }

    static func apply(to input: RasterPixels, radius: Double, softness: Double) -> RasterPixels {
        let distances = RasterDistance.field(input.alphas, width: input.width, height: input.height, inside: true)
        var result = input
        for index in 0..<input.count {
            let factor = Float(ramp(distance: distances[index] + 0.5, radius: radius, softness: softness))
            for channel in 0..<4 {
                result.data[index * 4 + channel] *= factor
            }
        }
        return result
    }
}

// MARK: - Bevel and emboss

/// The edge-shape curves and button tone tables (pure functions, FX-010), and the lighting.
enum BevelShading {
    /// The rim's height at `x` across it (0 at the outer edge, 1 where the rim meets the flat
    /// top), 0 ... 1.
    static func height(_ shape: LiveEffect.BevelEmboss.EdgeShape, at x: Double) -> Double {
        let x = min(max(x, 0), 1)
        switch shape {
        case .flat:
            return x
        case .smooth:
            return sin(x * .pi / 2)
        case .sloped:
            return x * x * (3 - 2 * x)
        case .frame1:
            // Up, a ledge, up again.
            if x < 1.0 / 3 { return 1.5 * x }
            if x < 2.0 / 3 { return 0.5 }
            return 0.5 + 1.5 * (x - 2.0 / 3)
        case .frame2:
            // Up to a ridge, down into a groove, up to the top.
            if x < 0.4 { return x / 0.4 }
            if x < 0.6 { return 1 - (x - 0.4) / 0.2 * 0.5 }
            return 0.5 + (x - 0.6) / 0.4 * 0.5
        case .ring:
            // A rounded ring: up and back down, the top flush with the edge.
            return sin(x * .pi)
        case .ruffle:
            return min(max(x + 0.25 * sin(4 * .pi * x), 0), 1)
        }
    }

    /// The highlight and shadow strengths of a preset, and whether light and dark swap.
    struct Tones: Hashable, Sendable {
        var highlight: Double
        var shadow: Double
        var inverted: Bool
    }

    static func tones(_ preset: LiveEffect.BevelEmboss.ButtonPreset) -> Tones {
        switch preset {
        case .raised: return Tones(highlight: 1, shadow: 1, inverted: false)
        case .highlighted: return Tones(highlight: 1.5, shadow: 0.6, inverted: false)
        case .inset: return Tones(highlight: 1, shadow: 1, inverted: true)
        case .inverted: return Tones(highlight: 0.6, shadow: 1.5, inverted: true)
        }
    }

    /// The unit vector toward the light at `degrees` (counterclockwise from the right, y up),
    /// 45° above the page, in the raster's y-down space with z toward the viewer.
    static func light(degrees: Double) -> (x: Double, y: Double, z: Double) {
        let angle = (degrees.isFinite ? degrees : 0) * .pi / 180
        let half = 0.5.squareRoot()
        return (cos(angle) * half, -sin(angle) * half, half)
    }

    /// Lighting of a height field: positive where a slope faces the light, negative where it
    /// faces away, 0 on flat ground.
    static func shade(_ heights: [Double], width: Int, height: Int, degrees: Double) -> [Double] {
        let light = light(degrees: degrees)
        var result = [Double](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                func h(_ c: Int, _ r: Int) -> Double { heights[min(max(r, 0), height - 1) * width + min(max(c, 0), width - 1)] }
                let gx = (h(column + 1, row) - h(column - 1, row)) / 2
                let gy = (h(column, row + 1) - h(column, row - 1)) / 2
                let length = (gx * gx + gy * gy + 1).squareRoot()
                let dot = (-gx * light.x - gy * light.y + light.z) / length
                result[row * width + column] = dot - light.z
            }
        }
        return result
    }

    /// A separable Gaussian of `values` (σ in pixels).
    static func blur(_ values: [Double], width: Int, height: Int, sigma: Double) -> [Double] {
        guard sigma > 0.05 else { return values }
        let reach = max(Int((3 * sigma).rounded(.up)), 1)
        var kernel = (-reach...reach).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        var horizontal = [Double](repeating: 0, count: values.count)
        for row in 0..<height {
            for column in 0..<width {
                var total = 0.0
                for (k, weight) in kernel.enumerated() {
                    let c = min(max(column + k - reach, 0), width - 1)
                    total += values[row * width + c] * weight
                }
                horizontal[row * width + column] = total
            }
        }
        var result = [Double](repeating: 0, count: values.count)
        for row in 0..<height {
            for column in 0..<width {
                var total = 0.0
                for (k, weight) in kernel.enumerated() {
                    let r = min(max(row + k - reach, 0), height - 1)
                    total += horizontal[r * width + column] * weight
                }
                result[row * width + column] = total
            }
        }
        return result
    }

    static func apply(_ bevel: LiveEffect.BevelEmboss, to input: RasterPixels, scale: Double) -> RasterPixels {
        let width = input.width
        let height = input.height
        let rim = max(bevel.effectiveWidth * scale, 1e-6)
        let alphas = input.alphas
        let inside = RasterDistance.field(alphas, width: width, height: height, inside: true)
        let outside = bevel.style == .outerBevel ? RasterDistance.field(alphas, width: width, height: height, inside: false) : []
        var heights = [Double](repeating: 0, count: width * height)
        for index in 0..<heights.count {
            switch bevel.style {
            case .innerBevel, .raisedEmboss, .insetEmboss:
                heights[index] = alphas[index] >= 0.5 ? rim * self.height(bevel.edgeShape, at: (inside[index] + 0.5) / rim) : 0
            case .outerBevel:
                heights[index] = alphas[index] >= 0.5 ? rim : rim * self.height(bevel.edgeShape, at: 1 - (outside[index] + 0.5) / rim)
            }
        }
        if bevel.style == .insetEmboss {
            heights = heights.map { -$0 }
        }
        // At least a little smoothing: a distance field is exact only on the pixel grid, and its
        // steps would show as streaks in the lighting.
        heights = blur(heights, width: width, height: height, sigma: max(bevel.effectiveSoftness * rim / 20, 0.75))
        let tones = tones(bevel.buttonPreset)
        let strength = bevel.effectiveContrast / 100 * 2
        var shading = shade(heights, width: width, height: height, degrees: bevel.angle)
        if tones.inverted {
            shading = shading.map { -$0 }
        }
        var result = RasterPixels(width: width, height: height)
        for index in 0..<input.count {
            let s = shading[index]
            let light = Float(min(max(s * strength * (s > 0 ? tones.highlight : tones.shadow), -1), 1))
            switch bevel.style {
            case .innerBevel:
                var pixel = (0..<4).map { input.data[index * 4 + $0] }
                if inside[index] + 0.5 <= rim + 3 * bevel.effectiveSoftness * rim / 20 + 1 {
                    pixel = BevelShading.lit(pixel, light)
                }
                for channel in 0..<4 { result.data[index * 4 + channel] = pixel[channel] }
            case .outerBevel:
                let coverage = alphas[index] >= 0.5 ? 0 : Float(min(max(rim + 0.5 - outside[index], 0), 1))
                let base = [Float(bevel.color.red), Float(bevel.color.green), Float(bevel.color.blue), 1].map { $0 * coverage * Float(bevel.color.alpha) }
                let pixel = BevelShading.lit(base, light)
                for channel in 0..<4 { result.data[index * 4 + channel] = pixel[channel] }
            case .raisedEmboss, .insetEmboss:
                // Only the relief: white where lit, black where shaded, over nothing.
                let alpha = abs(light)
                let value: Float = light > 0 ? alpha : 0
                result.data[index * 4] = value
                result.data[index * 4 + 1] = value
                result.data[index * 4 + 2] = value
                result.data[index * 4 + 3] = alpha
            }
        }
        return result
    }

    /// A premultiplied pixel lit by `light` (−1 ... 1): toward white or toward black.
    static func lit(_ pixel: [Float], _ light: Float) -> [Float] {
        let alpha = pixel[3]
        if light > 0 {
            return [pixel[0] + (alpha - pixel[0]) * light, pixel[1] + (alpha - pixel[1]) * light, pixel[2] + (alpha - pixel[2]) * light, alpha]
        }
        let factor = 1 + light
        return [pixel[0] * factor, pixel[1] * factor, pixel[2] * factor, alpha]
    }
}
