// PDF shadings as gradients (import-formats.adoc, "PDF"; IMG-009): axial shadings become linear
// gradients and radial ones radial gradients, their functions sampled into as few stops as
// reproduce the ramp; every other shading type (function-based and the meshes) becomes a flat
// 10% black fill -- 50% for an Illustrator gradient mesh -- so the shape stays.

import Foundation
import WTGeometry
import WTRender

enum PDFImportShading {
    /// How many samples a function is read at before the stops are simplified.
    static let samples = 33

    /// The paint of shading `dict`, whose own space maps into the page by `toPage`.
    static func paint(_ value: PDFImportValue, toPage: AffineTransform, resources: PDFImportDict?, session: PDFImportSession) -> ImportedPaint {
        guard let dict = value.dict else {
            return session.meshPaint
        }
        let type = Int(dict.number("ShadingType") ?? 0)
        guard type == 2 || type == 3,
              let space = dict["ColorSpace"].flatMap({ PDFImportColorSpace.parse($0, resources: resources) }),
              let function = dict["Function"].flatMap(PDFImportFunction.parse),
              let coords = dict.numbers("Coords") else {
            session.note("Shadings other than linear and radial were imported as flat fills.")
            return session.meshPaint
        }
        let domain = dict.numbers("Domain").flatMap { $0.count >= 2 ? $0 : nil } ?? [0, 1]
        var stops = PDFImportShading.stops(function: function, space: space, domain: domain)
        if type == 2, coords.count >= 4 {
            let axis = Gradient.Axis(start: toPage.apply(Point(x: coords[0], y: coords[1])), end: toPage.apply(Point(x: coords[2], y: coords[3])))
            return .gradient(Gradient(kind: .linear, axis: axis, stops: stops))
        }
        guard coords.count >= 6 else {
            return session.meshPaint
        }
        let (x0, y0, r0, x1, y1, r1) = (coords[0], coords[1], coords[2], coords[3], coords[4], coords[5])
        let outer = r1 >= r0 ? (x: x1, y: y1, r: r1) : (x: x0, y: y0, r: r0)
        let inner = r1 >= r0 ? r0 : r1
        if abs(x0 - x1) > 1e-9 || abs(y0 - y1) > 1e-9 {
            session.note("Radial shadings with a focal point were imported with it at the centre.")
        }
        if r1 < r0 {
            stops = stops.map { Gradient.Stop(offset: 1 - $0.offset, color: $0.color) }.reversed()
        }
        if inner > 0, outer.r > 0 {
            let start = inner / outer.r
            stops = stops.map { Gradient.Stop(offset: start + $0.offset * (1 - start), color: $0.color) }
        }
        let center = Point(x: outer.x, y: outer.y)
        let axis = Gradient.Axis(start: toPage.apply(center), end: toPage.apply(Point(x: outer.x + outer.r, y: outer.y)), end2: toPage.apply(Point(x: outer.x, y: outer.y + outer.r)))
        return .gradient(Gradient(kind: .radial, axis: axis, stops: stops))
    }

    /// The function sampled across `domain` and simplified: stops that the neighbouring
    /// stops' interpolation reproduces within 1/255 are dropped.
    static func stops(function: PDFImportFunction, space: PDFImportColorSpace, domain: [Double]) -> [Gradient.Stop] {
        let t0 = domain[0]
        let t1 = domain[1]
        let sampled = (0..<samples).map { index -> Gradient.Stop in
            let u = Double(index) / Double(samples - 1)
            let color = space.color(function.evaluate([t0 + u * (t1 - t0)])) ?? .black
            return Gradient.Stop(offset: u, color: color)
        }
        var keep = Array(repeating: false, count: sampled.count)
        keep[0] = true
        keep[sampled.count - 1] = true
        simplify(sampled, 0, sampled.count - 1, &keep)
        return sampled.indices.filter { keep[$0] }.map { sampled[$0] }
    }

    static func simplify(_ stops: [Gradient.Stop], _ low: Int, _ high: Int, _ keep: inout [Bool]) {
        guard high - low > 1 else {
            return
        }
        var worst = 0.0
        var index = low
        let a = stops[low]
        let b = stops[high]
        for i in (low + 1)..<high {
            let t = (stops[i].offset - a.offset) / (b.offset - a.offset)
            let expected = a.color.components + (b.color.components - a.color.components) * t
            let difference = stops[i].color.components - expected
            let error = max(abs(difference.x), abs(difference.y), abs(difference.z), abs(difference.w))
            let scaled = a.color.space == .lab ? error / 100 : error
            if scaled > worst {
                worst = scaled
                index = i
            }
        }
        if worst > 1.0 / 255 {
            keep[index] = true
            simplify(stops, low, index, &keep)
            simplify(stops, index, high, &keep)
        }
    }
}
