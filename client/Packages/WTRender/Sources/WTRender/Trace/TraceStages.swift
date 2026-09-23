// The trace pipeline after quantization (IMG-021, IMG-022): which regions are outlined and
// which are centerlined, path overlap, outer edge, and the output paths in painter's order.

import WTGeometry

enum TraceStages {
    /// The paths for `labels`, lighter palette entries first.
    static func trace(
        _ labels: TraceLabels,
        options: Trace.Options,
        transform: AffineTransform,
        check: () throws -> Void,
        progress: (Double) -> Void
    ) throws -> [Trace.TracedPath] {
        if options.outerEdge {
            return try outerEdge(labels, options: options, transform: transform, check: check)
        }
        let order = labels.paintOrder
        var rank = [Int](repeating: 0, count: order.count)
        for (position, label) in order.enumerated() {
            rank[label] = position
        }
        var outline = TraceOutline(width: labels.width, height: labels.height)
        var result: [Trace.TracedPath] = []
        let pixelScale = abs(transform.determinant).squareRoot()
        for (step, label) in order.enumerated() {
            try check()
            progress(Double(step) / Double(order.count))
            let color = labels.palette[label]
            var outlineMask = [Bool](repeating: false, count: labels.labels.count)
            for y in 0..<labels.height {
                try check()
                for index in (y * labels.width)..<((y + 1) * labels.width) where labels.labels[index] == UInt16(label) {
                    outlineMask[index] = true
                }
            }
            if options.mode != .outline {
                guard label != labels.paper else {
                    continue
                }
                let strokes = try TraceCenterline.trace(mask: &outlineMask, width: labels.width, height: labels.height, options: options, check: check)
                for stroke in strokes {
                    let contours = try stroke.chains.map { chain in
                        try check()
                        return (chain.closed
                            ? TraceFitting.closedContour(chain.points, tolerance: options.tolerance)
                            : TraceFitting.openContour(chain.points, tolerance: options.tolerance)).applying(transform)
                    }
                    let width = options.uniform ? 1 : stroke.width * pixelScale
                    result.append(Trace.TracedPath(contours: contours, stroke: color, strokeWidth: width, cmyk: cmyk(color, options)))
                }
            }
            try outline.load(check: check) { outlineMask[$0] }
            let loops = try outline.loops(check: check)
            guard !loops.isEmpty else {
                continue
            }
            let contours = try loops.map { loop -> Contour in
                try check()
                var samples = loop.samples
                if options.overlap != .none {
                    samples = overlapped(samples, label: label, labels: labels, rank: rank, distance: options.overlap.distance)
                }
                return TraceFitting.closedContour(samples, tolerance: options.tolerance).applying(transform)
            }
            result.append(path(contours, color: color, options: options))
        }
        return result
    }

    /// The path of filled (or, without fills, 1 pt stroked) outlines in `color`.
    private static func path(_ contours: [Contour], color: Color, options: Trace.Options) -> Trace.TracedPath {
        options.fillsPaths
            ? Trace.TracedPath(contours: contours, fill: color, cmyk: cmyk(color, options))
            : Trace.TracedPath(contours: contours, stroke: color, strokeWidth: 1, cmyk: cmyk(color, options))
    }

    private static func cmyk(_ color: Color, _ options: Trace.Options) -> SIMD4<Double>? {
        options.colorModel == .cmyk ? Trace.cmyk(of: color) : nil
    }

    /// *Outer edge*: one path around everything that is not paper, holes removed, in the mean
    /// colour of what it encloses.
    private static func outerEdge(_ labels: TraceLabels, options: Trace.Options, transform: AffineTransform, check: () throws -> Void) throws -> [Trace.TracedPath] {
        let paper = labels.paper.map { UInt16($0) }
        var outline = TraceOutline(width: labels.width, height: labels.height)
        try outline.load(check: check) { labels.labels[$0] != TraceLabels.none && labels.labels[$0] != paper }
        let contours = try outline.loops(check: check).filter(\.isOuter).map {
            try check()
            return TraceFitting.closedContour($0.samples, tolerance: options.tolerance).applying(transform)
        }
        guard !contours.isEmpty else {
            return []
        }
        var sum = SIMD3<Double>.zero
        var count = 0.0
        for y in 0..<labels.height {
            try check()
            for index in (y * labels.width)..<((y + 1) * labels.width) {
                let label = labels.labels[index]
                guard label != TraceLabels.none && label != paper else {
                    continue
                }
                let color = labels.palette[Int(label)]
                sum += SIMD3(color.red, color.green, color.blue)
                count += 1
            }
        }
        let mean = sum / count
        return [path(contours, color: Color(red: mean.x, green: mean.y, blue: mean.z), options: options)]
    }

    /// *Path overlap*: each edge between consecutive samples moves `distance` pixels outward
    /// (left of the walk, which keeps the inside on its right) where the pixel just outside its
    /// midpoint belongs to a darker region, and each sample moves to where its two edges'
    /// offset lines meet, so a lighter region reaches under its darker neighbours and no seam
    /// shows between them.  `rank` is each palette entry's position in painter's order.
    static func overlapped(_ samples: [Point], label: Int, labels: TraceLabels, rank: [Int], distance: Double) -> [Point] {
        let count = samples.count
        guard count >= 3 else {
            return samples
        }
        let own = rank[label]
        let edges = samples.indices.map { index -> (normal: Vector, shift: Double) in
            let start = samples[index]
            let end = samples[(index + 1) % count]
            let direction = (end - start).normalized
            let normal = Vector(dx: direction.dy, dy: -direction.dx)
            let probe = Point.lerp(start, end, 0.5) + normal * 0.5
            let x = Int(probe.x.rounded(.down))
            let y = Int(probe.y.rounded(.down))
            guard x >= 0, y >= 0, x < labels.width, y < labels.height else {
                return (normal, 0)
            }
            let other = labels.labels[y * labels.width + x]
            return (normal, other != TraceLabels.none && rank[Int(other)] > own ? distance : 0)
        }
        return samples.indices.map { index in
            let incoming = edges[(index + count - 1) % count]
            let outgoing = edges[index]
            // Solve n1 · d = s1 and n2 · d = s2 for the displacement d.
            let determinant = incoming.normal.cross(outgoing.normal)
            var displacement: Vector
            if abs(determinant) < 1e-6 {
                displacement = incoming.normal * max(incoming.shift, outgoing.shift)
            } else {
                displacement = Vector(
                    dx: (incoming.shift * outgoing.normal.dy - outgoing.shift * incoming.normal.dy) / determinant,
                    dy: (outgoing.shift * incoming.normal.dx - incoming.shift * outgoing.normal.dx) / determinant
                )
            }
            if displacement.length > 3 * distance {
                displacement = displacement.normalized * (3 * distance)
            }
            return samples[index] + displacement
        }
    }
}
