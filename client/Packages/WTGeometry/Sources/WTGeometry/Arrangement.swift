/// The planar arrangement of several filled paths: every segment of every operand split at
/// every place it meets another (or itself), with coincident pieces merged, each resulting
/// edge knowing which operands cover the region on either side of it.  Boolean operations are
/// selections of edges from it (GEO-002).
///
/// Construction, in order:
///
/// 1. Gather the segments of every contour of every operand, the closing segment included, and
///    drop non-finite and zero-length ones.
/// 2. For every pair of segments whose control hulls meet, find the crossings (GEO-001) and any
///    shared stretch (``CubicBezier/overlap(with:tolerance:samples:)``); for every segment, its
///    own loop.  Each becomes a split parameter.
/// 3. Split each segment at its parameters, dropping pieces shorter than the merge distance.
/// 4. Cluster piece end points within the merge distance into vertices and snap the ends onto
///    them, so pieces meet exactly.
/// 5. Merge pieces that join the same two vertices along the same curve (the shared stretches
///    of coincident edges, from either operand or both) into one edge.
/// 6. Classify each edge: sample a point on each side of its midpoint, offset along the normal
///    by a distance kept below half the distance to any other edge, and record whether each
///    operand's fill (under its own rule) covers it.  Winding numbers are counted on the
///    arrangement's own snapped edges, each carrying a signed multiplicity per operand (how
///    many of that operand's pieces run along it, and which way), so a sample ray can never
///    slip through a gap an input left between consecutive segments.
///
/// Extraction keeps the edges whose two sides disagree about the requested predicate, orients
/// each so the covered side is on its ``Vector/perpendicular`` side, and stitches them into
/// closed contours by always taking, at a vertex, the outgoing edge met first when turning from
/// the arrival direction toward the covered side.  That traces each face boundary tightly, so
/// the contours of the result neither cross nor overlap, and a result's outer contours come out
/// positive and its holes negative.
///
/// Every loop is bounded: at most `maxCandidates` crossings per segment pair (GEO-001), at most
/// ``Boolean/Options/maxSplitsPerSegment`` splits per segment, and one pass over the kept edges
/// to stitch.  Numerical trouble shows up as a stitch that cannot close; such a chain is
/// dropped rather than looped on.
struct Arrangement {
    struct Edge {
        var curve: CubicBezier
        var from: Int
        var to: Int
        /// Coverage per operand on the perpendicular side and on the other side.
        var left: [Bool]
        var right: [Bool]
    }

    let operandCount: Int
    let tolerance: Double
    let mergeDistance: Double
    private(set) var vertices: [Point] = []
    private(set) var edges: [Edge] = []

    init(operands: [FilledPath], options: Boolean.Options) {
        operandCount = operands.count
        var bounds = Rect.null
        for operand in operands {
            for contour in operand.contours {
                bounds.formUnion(contour.controlBounds)
            }
        }
        let diagonal = bounds.isNull || !bounds.diagonal.isFinite ? 0 : bounds.diagonal
        tolerance = max(options.tolerance, diagonal * 1e-11)
        mergeDistance = tolerance * 10

        // 1. Segments.
        var segments: [CubicBezier] = []
        var owners: [Int] = []
        for (operandIndex, operand) in operands.enumerated() {
            for contour in operand.contours where !contour.isEmpty {
                var all = contour.segments
                if let closing = contour.closingSegment {
                    all.append(closing)
                }
                for segment in all
                where segment.p0.isFinite && segment.p1.isFinite && segment.p2.isFinite && segment.p3.isFinite
                    && segment.controlPolygonLength > mergeDistance
                {
                    segments.append(segment)
                    owners.append(operandIndex)
                }
            }
        }
        guard !segments.isEmpty else {
            return
        }

        // 2. Split parameters.
        var splits = [[Double]](repeating: [], count: segments.count)
        let hulls = segments.map { $0.controlBounds }
        let order = segments.indices.sorted { hulls[$0].minX < hulls[$1].minX }
        for (position, i) in order.enumerated() {
            if let loop = segments[i].selfIntersection() {
                splits[i].append(loop.s)
                splits[i].append(loop.t)
            }
            var next = position + 1
            while next < order.count {
                let j = order[next]
                next += 1
                if hulls[j].minX > hulls[i].maxX + tolerance {
                    break  // sorted by minX: nothing further can meet segment i
                }
                guard hulls[i].intersects(hulls[j], tolerance: tolerance) else {
                    continue
                }
                if segments[i] == segments[j] || segments[i] == segments[j].reversed() {
                    continue  // one curve twice: it needs no split of its own, and step 5 merges it
                }
                let (crossings, overlap) = segments[i].arrangementIntersections(with: segments[j], tolerance: tolerance)
                for hit in crossings {
                    splits[i].append(hit.t)
                    splits[j].append(hit.u)
                }
                if let overlap {
                    splits[i].append(overlap.t0)
                    splits[i].append(overlap.t1)
                    splits[j].append(overlap.u0)
                    splits[j].append(overlap.u1)
                }
            }
        }

        // 3. Pieces.
        var pieces: [(curve: CubicBezier, owner: Int)] = []
        for (index, segment) in segments.enumerated() {
            let parameters = Self.cleanParameters(splits[index], on: segment, merge: mergeDistance, limit: options.maxSplitsPerSegment)
            for k in 1..<parameters.count {
                pieces.append((segment.subdivide(from: parameters[k - 1], to: parameters[k]), owners[index]))
            }
        }

        // 4. Vertices.
        var grid = VertexGrid(cell: mergeDistance)
        var rawEdges: [(curve: CubicBezier, from: Int, to: Int, owner: Int)] = []
        for (piece, owner) in pieces {
            let from = grid.vertex(for: piece.p0, in: &vertices)
            let to = grid.vertex(for: piece.p3, in: &vertices)
            let start = vertices[from]
            let end = vertices[to]
            let snapped = CubicBezier(p0: start, p1: piece.p1 + (start - piece.p0), p2: piece.p2 + (end - piece.p3), p3: end)
            if from == to && snapped.controlPolygonLength <= 4 * mergeDistance {
                continue
            }
            rawEdges.append((snapped, from, to, owner))
        }

        // 5. Merge coincident pieces.
        var byEnds: [Int64: [Int]] = [:]
        var unique: [(curve: CubicBezier, from: Int, to: Int)] = []
        var multiplicity: [[Int]] = []
        let coincidence = mergeDistance * 2
        for edge in rawEdges {
            let key = Int64(min(edge.from, edge.to)) << 32 | Int64(max(edge.from, edge.to))
            let probe = edge.curve.evaluate(0.5)
            let match = byEnds[key, default: []].first { index in
                let other = unique[index].curve
                return other.nearestPoint(to: probe).distance <= coincidence
                    && edge.curve.nearestPoint(to: other.evaluate(0.5)).distance <= coincidence
            }
            if let index = match {
                let other = unique[index]
                let same: Bool
                if edge.from != edge.to {
                    same = edge.from == other.from
                } else {
                    // A loop: compare the directions at a common point.
                    let at = other.curve.nearestPoint(to: probe)
                    same = edge.curve.derivative(0.5).dot(other.curve.derivative(at.t)) >= 0
                }
                multiplicity[index][edge.owner] += same ? 1 : -1
            } else {
                byEnds[key, default: []].append(unique.count)
                unique.append((edge.curve, edge.from, edge.to))
                var counts = [Int](repeating: 0, count: operands.count)
                counts[edge.owner] = 1
                multiplicity.append(counts)
            }
        }
        let rules = operands.map(\.fillRule)
        // Horizontal bands of the edges' control hulls: a ray toward +x from a point can only
        // cross an edge whose hull spans the point's y, so each winding query visits one band.
        let uniqueHulls = unique.map { $0.curve.controlBounds }
        var span = Rect.null
        for hull in uniqueHulls {
            span.formUnion(hull)
        }
        let bandCount = max(1, min(512, unique.count / 4))
        let bandHeight = span.height / Double(bandCount)
        func band(_ y: Double) -> Int {
            guard bandHeight > 0, bandHeight.isFinite else {
                return 0
            }
            let position = ((y - span.minY) / bandHeight).rounded(.down)
            return Int(min(Double(bandCount - 1), max(0, position)))
        }
        var bands = [[Int]](repeating: [], count: bandCount)
        for (index, hull) in uniqueHulls.enumerated() {
            for b in band(hull.minY)...band(hull.maxY) {
                bands[b].append(index)
            }
        }
        func coverage(at point: Point) -> [Bool] {
            var winding = [Int](repeating: 0, count: rules.count)
            let candidates = point.y >= span.minY && point.y <= span.maxY ? bands[band(point.y)] : []
            for index in candidates {
                let w = unique[index].curve.windingContribution(at: point)
                if w != 0 {
                    for o in 0..<winding.count {
                        winding[o] += w * multiplicity[index][o]
                    }
                }
            }
            return zip(rules, winding).map { $0.isInside(windingNumber: $1) }
        }

        // 6. Classify.
        edges.reserveCapacity(unique.count)
        for (index, edge) in unique.enumerated() {
            let curve = edge.curve
            let middle = curve.evaluate(0.5)
            let normal = curve.normal(0.5)
            let length = curve.chordLength + curve.controlPolygonLength
            var offset = max(tolerance * 50, min(length * 1e-3, diagonal * 1e-3))
            let reach = Rect(minX: middle.x - offset, minY: middle.y - offset, maxX: middle.x + offset, maxY: middle.y + offset)
            let firstBand = band(reach.minY)
            for b in firstBand...band(reach.maxY) {
                // Each nearby edge once: in the first band both it and the reach occupy.
                for other in bands[b]
                where other != index && uniqueHulls[other].intersects(reach) && max(firstBand, band(uniqueHulls[other].minY)) == b {
                    // An edge nearer than the merge distance that was not merged (its ends went
                    // to different vertices) still bounds the sample offset: stepping over it
                    // would classify this edge by the far side of a sliver, and the unbalanced
                    // vertices that leaves make whole contours unstitchable.
                    let d = unique[other].curve.nearestPoint(to: middle).distance
                    if d > tolerance * 1e-3 {
                        offset = min(offset, d / 2)
                    }
                }
            }
            offset = max(offset, tolerance * 1e-3)
            let leftPoint = middle + normal * offset
            let rightPoint = middle - normal * offset
            edges.append(Edge(
                curve: curve, from: edge.from, to: edge.to,
                left: coverage(at: leftPoint),
                right: coverage(at: rightPoint)))
        }
    }

    /// Sorted split parameters including 0 and 1, with parameters that would cut off a piece
    /// shorter than `merge` removed.  A piece is short only when both its end points and its
    /// middle are within `merge`, so the two parameters of a loop (same point, far apart on the
    /// curve) both survive.
    static func cleanParameters(_ raw: [Double], on curve: CubicBezier, merge: Double, limit: Int) -> [Double] {
        var sorted = raw.filter { $0.isFinite && $0 > 0 && $0 < 1 }.sorted()
        if sorted.count > limit {
            sorted = Array(sorted.prefix(limit))
        }
        func tiny(_ a: Double, _ b: Double) -> Bool {
            let pa = curve.evaluate(a)
            return pa.distance(to: curve.evaluate(b)) <= merge && pa.distance(to: curve.evaluate((a + b) / 2)) <= merge
        }
        var result: [Double] = [0]
        for t in sorted where !tiny(result[result.count - 1], t) && !tiny(t, 1) {
            result.append(t)
        }
        result.append(1)
        return result
    }

    /// The region where `keep` holds for the operand coverage, as normalized contours.
    func extract(_ keep: ([Bool]) -> Bool) -> FilledPath {
        var kept: [(curve: CubicBezier, from: Int, to: Int)] = []
        for edge in edges {
            let left = keep(edge.left)
            let right = keep(edge.right)
            if left == right {
                continue
            }
            if left {
                kept.append((edge.curve, edge.from, edge.to))
            } else {
                kept.append((edge.curve.reversed(), edge.to, edge.from))
            }
        }
        return FilledPath(contours: stitch(kept), fillRule: .nonZero)
    }

    /// Every distinct coverage pattern with at least one operand covering, on either side of
    /// any edge.
    func coverageClasses() -> [[Bool]] {
        var seen = Set<[Bool]>()
        var result: [[Bool]] = []
        for edge in edges {
            for side in [edge.left, edge.right] where side.contains(true) && seen.insert(side).inserted {
                result.append(side)
            }
        }
        return result
    }

    // MARK: Stitching

    private func stitch(_ kept: [(curve: CubicBezier, from: Int, to: Int)]) -> [Contour] {
        guard !kept.isEmpty else {
            return []
        }
        var outgoing: [Int: [Int]] = [:]
        var incoming: [Int: [Int]] = [:]
        for (index, edge) in kept.enumerated() {
            outgoing[edge.from, default: []].append(index)
            incoming[edge.to, default: []].append(index)
        }
        // The successor of each edge: at its end vertex, the outgoing edge met first when
        // turning from the reversed arrival ray in the negative rotation direction, measured
        // on a small circle around the vertex so tangent edges are ordered by where they go.
        var next = [Int](repeating: -1, count: kept.count)
        for (vertex, outs) in outgoing {
            let ins = incoming[vertex] ?? []
            if outs.count == 1 {
                for e in ins {
                    next[e] = outs[0]
                }
                continue
            }
            let center = vertices[vertex]
            var radius = Double.infinity
            for e in outs {
                radius = min(radius, Self.reach(of: kept[e].curve, from: center))
            }
            for e in ins {
                radius = min(radius, Self.reach(of: kept[e].curve.reversed(), from: center))
            }
            radius = max(radius * 0.05, tolerance)
            let outAngles = outs.map { Self.rayAngle(kept[$0].curve, from: center, radius: radius) }
            for e in ins {
                let twin = Self.rayAngle(kept[e].curve.reversed(), from: center, radius: radius)
                var best = -1
                var bestTurn = Double.infinity
                for (k, angle) in outAngles.enumerated() {
                    var turn = (twin - angle).truncatingRemainder(dividingBy: 2 * .pi)
                    if turn <= 1e-12 {
                        turn += 2 * .pi
                    }
                    if turn < bestTurn {
                        bestTurn = turn
                        best = outs[k]
                    }
                }
                next[e] = best
            }
        }
        var used = [Bool](repeating: false, count: kept.count)
        var contours: [Contour] = []
        for start in kept.indices where !used[start] {
            var chain: [CubicBezier] = []
            var current = start
            var closed = false
            for _ in 0...kept.count {
                used[current] = true
                chain.append(kept[current].curve)
                var successor = next[current]
                if successor >= 0 && successor != start && used[successor] {
                    // Numerical trouble made the pairing ambiguous; take any free edge.
                    successor = outgoing[kept[current].to]?.first { !used[$0] || $0 == start } ?? -1
                }
                if successor == start || (successor < 0 && kept[current].to == kept[start].from) {
                    closed = true
                    break
                }
                if successor < 0 {
                    break
                }
                current = successor
            }
            if closed {
                let contour = Contour(segments: Self.mergeCollinear(chain, tolerance: tolerance), closed: true)
                if abs(contour.signedArea()) > mergeDistance * mergeDistance {
                    contours.append(contour)
                }
            }
        }
        return contours
    }

    /// Roughly how far the curve gets from `center`.
    private static func reach(of curve: CubicBezier, from center: Point) -> Double {
        var best = 0.0
        for k in 1...8 {
            best = max(best, curve.evaluate(Double(k) / 8).distance(to: center))
        }
        return best
    }

    /// The direction from `center` to where the curve (starting at `center`) first reaches
    /// `radius` from it.
    private static func rayAngle(_ curve: CubicBezier, from center: Point, radius: Double) -> Double {
        var low = 0.0
        var high = 1.0
        for k in 1...32 {
            let t = Double(k) / 32
            if curve.evaluate(t).distance(to: center) >= radius {
                high = t
                break
            }
            low = t
        }
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if curve.evaluate(mid).distance(to: center) >= radius {
                high = mid
            } else {
                low = mid
            }
        }
        let direction = curve.evaluate(high) - center
        return direction.lengthSquared > 0 ? direction.angle : curve.tangent(0).angle
    }

    /// Consecutive straight pieces running the same way joined into one, including across the
    /// seam of the closed chain.
    static func mergeCollinear(_ chain: [CubicBezier], tolerance: Double) -> [CubicBezier] {
        guard chain.count > 1 else {
            return chain
        }
        func joinable(_ a: CubicBezier, _ b: CubicBezier) -> Bool {
            guard a.isLinear(tolerance: tolerance), b.isLinear(tolerance: tolerance) else {
                return false
            }
            let da = a.p3 - a.p0
            let db = b.p3 - b.p0
            guard da.lengthSquared > 0, db.lengthSquared > 0, da.dot(db) > 0 else {
                return false
            }
            return abs(Line(start: a.p0, end: b.p3).signedDistance(to: a.p3)) <= tolerance
        }
        var result: [CubicBezier] = []
        for segment in chain {
            if let last = result.last, joinable(last, segment) {
                result[result.count - 1] = Line(start: last.p0, end: segment.p3).elevated()
            } else {
                result.append(segment)
            }
        }
        if result.count > 2, joinable(result[result.count - 1], result[0]) {
            let last = result.removeLast()
            result[0] = Line(start: last.p0, end: result[0].p3).elevated()
        }
        return result
    }
}

/// Spatial hash for clustering points into vertices.
private struct VertexGrid {
    let cell: Double
    var buckets: [Cell: [Int]] = [:]

    struct Cell: Hashable {
        var x: Int
        var y: Int
    }

    init(cell: Double) {
        self.cell = cell
    }

    private func cellOf(_ p: Point) -> Cell {
        let x = (p.x / cell).rounded(.down)
        let y = (p.y / cell).rounded(.down)
        let bound = Double(Int32.max)
        return Cell(x: Int(max(-bound, min(bound, x))), y: Int(max(-bound, min(bound, y))))
    }

    /// The vertex within one cell of `point`, creating one if there is none.
    mutating func vertex(for point: Point, in vertices: inout [Point]) -> Int {
        let home = cellOf(point)
        var best = -1
        var bestDistance = Double.infinity
        for dx in -1...1 {
            for dy in -1...1 {
                for index in buckets[Cell(x: home.x + dx, y: home.y + dy)] ?? [] {
                    let d = vertices[index].distance(to: point)
                    if d <= cell && d < bestDistance {
                        best = index
                        bestDistance = d
                    }
                }
            }
        }
        if best >= 0 {
            return best
        }
        vertices.append(point)
        buckets[home, default: []].append(vertices.count - 1)
        return vertices.count - 1
    }
}
