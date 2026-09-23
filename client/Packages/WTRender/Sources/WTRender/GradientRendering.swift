// Gradient rendering (ATTR-027; docs/_includes/appearance/gradients.adoc, "Client").  The ramp
// is compiled once from the sorted stops, interpolated in OKLab as CSS Color 4 does (so a
// red-to-blue ramp does not pass through grey), into a lookup table; the behaviour and the
// logarithmic curve map the geometry's `t` onto it.  Linear, Logarithmic and Radial are Core
// Graphics shadings over a `CGFunction` of the ramp (native shadings in PDF too); Rectangle,
// Cone and Contour evaluate `t` per sample in object-local space ("custom shading callback"),
// Contour from a Euclidean distance field of the fill region cached per path and resolution.

import WTGeometry
import CoreGraphics
import Foundation

// MARK: - OKLab

/// sRGB ↔ OKLab (Björn Ottosson's matrices), for ramp interpolation.
enum OKLab {
    static func linear(_ c: Double) -> Double {
        c <= 0.040_45 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ c: Double) -> Double {
        c <= 0.003_130_8 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// (L, a, b) of an sRGB colour.
    static func fromSRGB(_ red: Double, _ green: Double, _ blue: Double) -> SIMD3<Double> {
        let r = linear(red), g = linear(green), b = linear(blue)
        let l = cbrt(0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b)
        let m = cbrt(0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b)
        let s = cbrt(0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b)
        return SIMD3(
            0.210_454_255_3 * l + 0.793_617_785_0 * m - 0.004_072_046_8 * s,
            1.977_998_495_1 * l - 2.428_592_205_0 * m + 0.450_593_709_9 * s,
            0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766_0 * s
        )
    }

    /// The sRGB colour of (L, a, b), clipped to the gamut.
    static func toSRGB(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = pow(lab.x + 0.396_337_777_4 * lab.y + 0.215_803_757_3 * lab.z, 3)
        let m = pow(lab.x - 0.105_561_345_8 * lab.y - 0.063_854_172_8 * lab.z, 3)
        let s = pow(lab.x - 0.089_484_177_5 * lab.y - 1.291_485_548_0 * lab.z, 3)
        let r = 4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s
        let g = -1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s
        let b = -0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701_0 * s
        func clip(_ v: Double) -> Double { min(max(encoded(min(max(v, 0), 1)), 0), 1) }
        return SIMD3(clip(r), clip(g), clip(b))
    }
}

// MARK: - The ramp

/// A compiled ramp: straight-alpha sRGB colours at `resolution` evenly spaced positions.
final class GradientRamp: @unchecked Sendable {
    static let resolution = 1024

    let samples: [SIMD4<Double>]

    /// The ramp of `stops` (sorted, at least one): before the first stop its colour, after the
    /// last its colour, between two stops OKLab with premultiplied alpha.
    init(stops: [Gradient.Stop]) {
        let sorted = stops
        let labs = sorted.map { stop -> SIMD4<Double> in
            let lab = OKLab.fromSRGB(stop.color.red, stop.color.green, stop.color.blue)
            let alpha = min(max(stop.color.alpha, 0), 1)
            return SIMD4(lab.x * alpha, lab.y * alpha, lab.z * alpha, alpha)
        }
        func exact(_ stop: Gradient.Stop) -> SIMD4<Double> {
            SIMD4(stop.color.red, stop.color.green, stop.color.blue, stop.color.alpha)
        }
        samples = (0..<GradientRamp.resolution).map { index in
            let u = Double(index) / Double(GradientRamp.resolution - 1)
            guard let upper = sorted.firstIndex(where: { $0.offset >= u }) else {
                return exact(sorted[sorted.count - 1])
            }
            if upper == 0 || sorted[upper].offset == u {
                return exact(sorted[upper])
            }
            let lower = upper - 1
            let span = sorted[upper].offset - sorted[lower].offset
            let t = span > 0 ? (u - sorted[lower].offset) / span : 1
            let mixed = labs[lower] + (labs[upper] - labs[lower]) * t
            guard mixed.w > 1e-9 else {
                return SIMD4(0, 0, 0, 0)
            }
            let rgb = OKLab.toSRGB(SIMD3(mixed.x, mixed.y, mixed.z) / mixed.w)
            return SIMD4(rgb.x, rgb.y, rgb.z, mixed.w)
        }
    }

    /// The colour at ramp position `u` (0 ... 1), linearly between table entries.
    func color(at u: Double) -> SIMD4<Double> {
        let position = min(max(u.isFinite ? u : 0, 0), 1) * Double(GradientRamp.resolution - 1)
        let index = Int(position)
        guard index < GradientRamp.resolution - 1 else {
            return samples[GradientRamp.resolution - 1]
        }
        let t = position - Double(index)
        return t == 0 ? samples[index] : samples[index] + (samples[index + 1] - samples[index]) * t
    }

    private static let cache = RenderCache<[Gradient.Stop], GradientRamp>(capacity: 256)

    static func cached(_ stops: [Gradient.Stop]) -> GradientRamp {
        cache.value(for: stops) { GradientRamp(stops: stops) }
    }
}

extension Gradient {
    /// Where on the ramp a geometry parameter `t` lands: clamped to 0 ... 1, then the
    /// behaviour (Repeat: the fraction of `t × count`; Reflect: the triangle wave of `t × count`,
    /// forward and back once per count), then the logarithmic curve `ln(1 + 9u) / ln 10`.
    func rampPosition(_ t: Double) -> Double {
        let clamped = min(max(t.isFinite ? t : 0, 0), 1)
        let count = Double(effectiveRepeatCount)
        var u: Double
        switch behavior {
        case .normal, .autoSize:
            u = clamped
        case .repeat:
            u = clamped >= 1 ? 1 : (clamped * count).truncatingRemainder(dividingBy: 1)
        case .reflect:
            let phase = clamped >= 1 ? 0 : (clamped * count).truncatingRemainder(dividingBy: 1)
            u = 1 - abs(2 * phase - 1)
        }
        if kind == .logarithmic {
            u = log(1 + 9 * u) / log(10)
        }
        return u
    }

    /// The handles as drawn: Auto size geometry from `bounds` when the axis is unset or the
    /// behaviour is Auto size; otherwise the axis with a coincident end read as a 1 pt axis and
    /// a missing second end read as the first rotated 90°.
    func resolvedAxis(bounds: Rect) -> Axis {
        guard let axis, behavior != .autoSize else {
            let center = Point(x: bounds.midX, y: bounds.midY)
            switch kind {
            case .linear, .logarithmic:
                let start = Point(x: bounds.minX, y: bounds.midY)
                let end = Point(x: bounds.maxX, y: bounds.midY)
                return Axis(start: start, end: end == start ? start + Vector(1, 0) : end, end2: nil)
            case .cone:
                return Axis(start: center, end: center + Vector(1, 0), end2: nil)
            case .radial, .rectangle, .contour:
                return Axis(start: center, end: center + Vector(max(bounds.width / 2, 0.5), 0), end2: center + Vector(0, max(bounds.height / 2, 0.5)))
            }
        }
        let end = axis.end == axis.start || !axis.end.isFinite ? axis.start + Vector(1, 0) : axis.end
        let end2 = axis.end2 ?? (axis.start + (end - axis.start).perpendicular)
        return Axis(start: axis.start, end: end, end2: end2)
    }
}

// MARK: - Drawing

enum GradientRendering {
    /// Fills the clip of `context` (user space = object-local) with `gradient` on a path whose
    /// local bounds are `bounds`.  `rasterScale` above 1 means PDF output: there a ramp with
    /// transparent stops is sampled too, since a PDF shading carries no alpha.
    static func fill(_ gradient: Gradient, bounds: Rect, path: DisplayPath, rule: FillRule, in context: CGContext, rasterScale: Double) {
        let stops = gradient.sortedStops
        guard !stops.isEmpty else {
            return
        }
        let ramp = GradientRamp.cached(stops)
        let axis = gradient.resolvedAxis(bounds: bounds)
        let e1 = axis.end - axis.start
        var e2 = (axis.end2 ?? axis.start) - axis.start
        if abs(e1.cross(e2)) < 1e-12 {
            e2 = e1.perpendicular
        }
        let frame = AffineTransform(a: e1.dx, b: e1.dy, c: e2.dx, d: e2.dy, tx: axis.start.x, ty: axis.start.y)
        let shaded = rasterScale <= 1 || stops.allSatisfy { $0.color.alpha >= 1 }
        switch gradient.kind {
        case .linear where shaded, .logarithmic where shaded:
            guard let function = makeFunction(ramp: ramp, gradient: gradient),
                  let shading = CGShading(axialSpace: CoreGraphicsRenderer.colorSpace, start: axis.start.cg, end: axis.end.cg, function: function, extendStart: true, extendEnd: true)
            else { return }
            context.drawShading(shading)
        case .radial where shaded:
            guard let function = makeFunction(ramp: ramp, gradient: gradient),
                  let shading = CGShading(radialSpace: CoreGraphicsRenderer.colorSpace, start: .zero, startRadius: 0, end: .zero, endRadius: 1, function: function, extendStart: true, extendEnd: true)
            else { return }
            context.saveGState()
            context.concatenate(frame.cg)
            context.drawShading(shading)
            context.restoreGState()
        case .contour:
            fillContour(gradient, ramp: ramp, axis: axis, path: path, rule: rule, in: context, rasterScale: rasterScale)
        case .linear, .logarithmic:
            let lengthSquared = e1.lengthSquared
            sampled(in: context, rasterScale: rasterScale) { point in
                ramp.color(at: gradient.rampPosition((point - axis.start).dot(e1) / lengthSquared))
            }
        case .radial, .rectangle:
            let basis = frame.inverted()!
            let radial = gradient.kind == .radial
            sampled(in: context, rasterScale: rasterScale) { point in
                let uv = basis.apply(point)
                let t = radial ? (uv.x * uv.x + uv.y * uv.y).squareRoot() : max(abs(uv.x), abs(uv.y))
                return ramp.color(at: gradient.rampPosition(t))
            }
        case .cone:
            let reference = atan2(e1.dy, e1.dx)
            sampled(in: context, rasterScale: rasterScale) { point in
                var angle = (atan2(point.y - axis.start.y, point.x - axis.start.x) - reference) / (2 * Double.pi)
                angle -= floor(angle)
                return ramp.color(at: gradient.rampPosition(angle))
            }
        }
    }

    private static func sampled(in context: CGContext, rasterScale: Double, sample: (Point) -> SIMD4<Double>) {
        RasterPaint.fill(context, space: .identity, rasterScale: rasterScale, interpolation: .default, sample: sample)
    }

    /// Contour: `t = min(1, d(p) / reach)` over the region's distance field, where `reach` is
    /// the distance at the start point scaled by `|end − start| / inradius` (the inradius
    /// itself for Auto size geometry, or when the start lies outside).  The whole field is
    /// coloured once per (path, gradient, resolution) and cached, so later frames only draw it.
    static func fillContour(_ gradient: Gradient, ramp: GradientRamp, axis: Gradient.Axis, path: DisplayPath, rule: FillRule, in context: CGContext, rasterScale: Double) {
        let resolution = RasterPaint.resolution(for: context, space: .identity, rasterScale: rasterScale)
        let image = ContourImage.cached(gradient: gradient, ramp: ramp, axis: axis, path: path, rule: rule, resolution: resolution)
        guard let picture = image.picture else {
            return
        }
        context.saveGState()
        context.interpolationQuality = .default
        context.draw(picture, in: image.rect)
        context.restoreGState()
    }

    /// The ramp as a Core Graphics function over t in 0 ... 1 (behaviour and curve applied).
    static func makeFunction(ramp: GradientRamp, gradient: Gradient) -> CGFunction? {
        let box = RampBox(ramp: ramp, gradient: gradient)
        var callbacks = CGFunctionCallbacks(
            version: 0,
            evaluate: { info, input, output in
                let box = Unmanaged<RampBox>.fromOpaque(info!).takeUnretainedValue()
                let color = box.ramp.color(at: box.gradient.rampPosition(Double(input[0])))
                output[0] = CGFloat(color.x)
                output[1] = CGFloat(color.y)
                output[2] = CGFloat(color.z)
                output[3] = CGFloat(color.w)
            },
            releaseInfo: { info in
                Unmanaged<RampBox>.fromOpaque(info!).release()
            }
        )
        let domain: [CGFloat] = [0, 1]
        let range: [CGFloat] = [0, 1, 0, 1, 0, 1, 0, 1]
        return CGFunction(info: Unmanaged.passRetained(box).toOpaque(), domainDimension: 1, domain: domain, rangeDimension: 4, range: range, callbacks: &callbacks)
    }

    private final class RampBox {
        let ramp: GradientRamp
        let gradient: Gradient

        init(ramp: GradientRamp, gradient: Gradient) {
            self.ramp = ramp
            self.gradient = gradient
        }
    }
}

// MARK: - Contour images

/// A contour gradient's colours over its region's distance field, drawn as one image.
final class ContourImage: @unchecked Sendable {
    let picture: CGImage?
    /// Where the image goes, in local space.
    let rect: CGRect

    private struct Key: Hashable, Sendable {
        let gradient: Gradient
        let path: DisplayPath
        let rule: FillRule
        let resolution: Double
    }

    private static let cache = RenderCache<Key, ContourImage>(capacity: 64)

    static func cached(gradient: Gradient, ramp: GradientRamp, axis: Gradient.Axis, path: DisplayPath, rule: FillRule, resolution: Double) -> ContourImage {
        cache.value(for: Key(gradient: gradient, path: path, rule: rule, resolution: resolution)) {
            ContourImage(gradient: gradient, ramp: ramp, axis: axis, field: DistanceField.cached(path: path, rule: rule, resolution: resolution))
        }
    }

    init(gradient: Gradient, ramp: GradientRamp, axis: Gradient.Axis, field: DistanceField) {
        let inradius = field.maximum
        var reach = inradius
        if gradient.axis != nil && gradient.behavior != .autoSize && inradius > 0 {
            reach = field.distance(at: axis.start) * axis.start.distance(to: axis.end) / inradius
        }
        if !(reach > 1e-6) {
            reach = max(inradius, 1e-6)
        }
        rect = CGRect(x: field.origin.x, y: field.origin.y, width: Double(field.width) / field.resolution, height: Double(field.height) / field.resolution)
        guard let surface = BitmapSurface(width: field.width, height: field.height) else {
            picture = nil
            return
        }
        let bytes = surface.context.data!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = surface.context.bytesPerRow
        for row in 0..<field.height {
            // Image row 0 is drawn at the rectangle's largest y: the field's last row.
            let fieldRow = field.height - 1 - row
            for column in 0..<field.width {
                let color = ramp.color(at: gradient.rampPosition(field.values[fieldRow * field.width + column] / reach))
                let alpha = min(max(color.w, 0), 1)
                let offset = row * rowBytes + column * 4
                bytes[offset] = UInt8((color.x * alpha * 255).rounded())
                bytes[offset + 1] = UInt8((color.y * alpha * 255).rounded())
                bytes[offset + 2] = UInt8((color.z * alpha * 255).rounded())
                bytes[offset + 3] = UInt8((alpha * 255).rounded())
            }
        }
        picture = surface.makeImage()
    }
}

// MARK: - Distance field

/// The distance from each sample inside a fill region to its boundary, on a grid in local
/// space: the region is scan-converted (sample centres, with the fill rule) and the squared
/// Euclidean distance transform (Felzenszwalb and Huttenlocher's two separable passes) of the
/// outside is taken.  Exact on the grid; linear in the number of samples.
final class DistanceField: @unchecked Sendable {
    let origin: Point
    let resolution: Double
    let width: Int
    let height: Int
    /// Distances in local units, row-major.
    let values: [Double]
    /// The largest distance: the region's inradius.
    let maximum: Double

    private struct Key: Hashable, Sendable {
        let path: DisplayPath
        let rule: FillRule
        let resolution: Double
    }

    private static let cache = RenderCache<Key, DistanceField>(capacity: 64)

    /// Samples per local unit are capped so a field stays within about four million samples.
    static let maxSamples = 4_194_304

    static func cached(path: DisplayPath, rule: FillRule, resolution: Double) -> DistanceField {
        cache.value(for: Key(path: path, rule: rule, resolution: resolution)) {
            DistanceField(path: path, rule: rule, resolution: resolution)
        }
    }

    init(path: DisplayPath, rule: FillRule, resolution requested: Double) {
        let bounds = path.controlBounds ?? Rect(x: 0, y: 0, width: 0, height: 0)
        var resolution = requested
        while Double(bounds.width * resolution + 3) * Double(bounds.height * resolution + 3) > Double(DistanceField.maxSamples) && resolution > 1e-3 {
            resolution /= 2
        }
        let origin = Point(x: bounds.minX - 1 / resolution, y: bounds.minY - 1 / resolution)
        let width = max(Int((bounds.width * resolution).rounded(.up)) + 3, 1)
        let height = max(Int((bounds.height * resolution).rounded(.up)) + 3, 1)
        self.origin = origin
        self.resolution = resolution
        self.width = width
        self.height = height

        // Scan conversion: edges of the flattened region, crossings per sample row.
        let flat = PathFlattener(tolerance: FlatteningTolerance(devicePixels: 0.25)).flatten(path, transform: .translation(x: -origin.x, y: -origin.y).concatenating(.scale(resolution)))
        var inside = [Bool](repeating: false, count: width * height)
        for row in 0..<height {
            let y = Double(row) + 0.5
            var crossings: [(x: Double, winding: Int)] = []
            for contour in flat.contours {
                let points = flat.points[contour]
                for index in points.indices {
                    let a = points[index]
                    let b = points[index == points.index(before: points.endIndex) ? points.startIndex : points.index(after: index)]
                    if (a.y <= y) != (b.y <= y) {
                        let x = a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)
                        crossings.append((x, b.y > a.y ? 1 : -1))
                    }
                }
            }
            crossings.sort { $0.x < $1.x }
            var winding = 0
            for (index, crossing) in crossings.enumerated() {
                winding += crossing.winding
                let filled = rule == .nonZero ? winding != 0 : index % 2 == 0
                guard filled, index + 1 < crossings.count else { continue }
                let from = max(Int((crossing.x - 0.5).rounded(.up)), 0)
                let to = min(Int((crossings[index + 1].x - 0.5).rounded(.down)), width - 1)
                if from <= to {
                    for column in from...to {
                        inside[row * width + column] = true
                    }
                }
            }
        }

        // Squared distance to the nearest outside sample, then to its boundary (half a sample).
        let infinity = 1e20
        var squared = inside.map { $0 ? infinity : 0 }
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
        let values = squared.map { $0 > 0 ? max(($0.squareRoot() - 0.5) / resolution, 0) : 0 }
        self.values = values
        maximum = values.max() ?? 0
    }

    /// The 1-D squared distance transform of `f` (lower envelope of parabolas).
    static func transform(_ f: [Double], count n: Int) -> [Double] {
        var result = [Double](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n + 1)
        var k = 0
        z[0] = -.infinity
        z[1] = .infinity
        for q in 1..<max(n, 1) {
            var s: Double
            repeat {
                let p = v[k]
                s = ((f[q] + Double(q * q)) - (f[p] + Double(p * p))) / Double(2 * q - 2 * p)
                if s <= z[k] { k -= 1 } else { break }
            } while k >= 0
            k += 1
            v[k] = q
            z[k] = s
            z[k + 1] = .infinity
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Double(q) { k += 1 }
            let d = Double(q - v[k])
            result[q] = d * d + f[v[k]]
        }
        return result
    }

    /// The distance at `point` (local), bilinear between samples; 0 outside the grid.
    func distance(at point: Point) -> Double {
        let x = (point.x - origin.x) * resolution - 0.5
        let y = (point.y - origin.y) * resolution - 0.5
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x <= Double(width - 1), y <= Double(height - 1) else {
            return 0
        }
        let x0 = min(Int(x), width - 1)
        let y0 = min(Int(y), height - 1)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fx = x - Double(x0)
        let fy = y - Double(y0)
        let top = values[y0 * width + x0] * (1 - fx) + values[y0 * width + x1] * fx
        let bottom = values[y1 * width + x0] * (1 - fx) + values[y1 * width + x1] * fx
        return top * (1 - fy) + bottom * fy
    }
}
