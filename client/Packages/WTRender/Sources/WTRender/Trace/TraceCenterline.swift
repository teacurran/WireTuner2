// Centerline tracing (IMG-022): each 8-connected feature of a palette entry is measured with a
// Euclidean distance transform, routed to strokes or outlines by its width, thinned
// (Zhang–Suen, then staircase pixels removed so the skeleton is 8-connected and one pixel
// wide), and decomposed into a graph: end and junction nodes, pixel chains between them, and
// closed loops.  Chains meeting at a junction start and end at the junction's centroid, so
// connected strokes share their endpoints exactly.  Each chain sample is re-centred between
// the feature's edges by probing along the chain's normal, and the stroke width is the median
// of those probe widths.

import WTGeometry

/// One chain of skeleton samples in bitmap pixel space.
struct TraceChain: Hashable, Sendable {
    var points: [Point]
    var closed: Bool
}

/// The chains of one centerlined feature and its measured width in pixels.
struct TraceStroke: Hashable, Sendable {
    var chains: [TraceChain]
    var width: Double
}

enum TraceCenterline {
    /// The strokes of the features of `mask` that route to centerlines under `options`; their
    /// pixels are cleared from `mask`, which keeps the features that route to outlines.
    static func trace(mask: inout [Bool], width: Int, height: Int, options: Trace.Options, check: () throws -> Void) throws -> [TraceStroke] {
        var strokes: [TraceStroke] = []
        var seen = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for start in 0..<(width * height) where mask[start] && !seen[start] {
            try check()
            var pixels: [Int] = []
            var minX = width, minY = height, maxX = 0, maxY = 0
            seen[start] = true
            stack.append(start)
            while let index = stack.popLast() {
                pixels.append(index)
                let x = index % width
                let y = index / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx
                        let ny = y + dy
                        if nx >= 0, ny >= 0, nx < width, ny < height, mask[ny * width + nx], !seen[ny * width + nx] {
                            seen[ny * width + nx] = true
                            stack.append(ny * width + nx)
                        }
                    }
                }
            }
            var feature = Feature(originX: minX - 1, originY: minY - 1, width: maxX - minX + 3, height: maxY - minY + 3)
            for index in pixels {
                feature.mask[feature.local(index % width, index / width)] = 1
            }
            let featureWidth = 2 * feature.maxDistance() - 1
            if case .centerlineAndOutline(let threshold) = options.mode, featureWidth >= threshold {
                continue
            }
            for index in pixels {
                mask[index] = false
            }
            if let stroke = try feature.stroke(featureWidth: featureWidth, check: check) {
                strokes.append(stroke)
            }
        }
        return strokes
    }
}

/// One feature on its own grid (its bounding box plus a pixel of background all round).
struct Feature {
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int
    var mask: [UInt8]

    init(originX: Int, originY: Int, width: Int, height: Int) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        mask = [UInt8](repeating: 0, count: width * height)
    }

    func local(_ x: Int, _ y: Int) -> Int {
        (y - originY) * width + (x - originX)
    }

    /// The bitmap-space centre of local pixel `index`.
    func center(_ index: Int) -> Point {
        Point(x: Double(originX + index % width) + 0.5, y: Double(originY + index / width) + 0.5)
    }

    /// Whether bitmap-space point `point` falls on a feature pixel.
    func covers(_ point: Point) -> Bool {
        let x = Int(point.x.rounded(.down)) - originX
        let y = Int(point.y.rounded(.down)) - originY
        return x >= 0 && y >= 0 && x < width && y < height && mask[y * width + x] != 0
    }

    // MARK: Distance transform

    /// The largest Euclidean distance from a feature pixel's centre to a background pixel's
    /// centre (Felzenszwalb–Huttenlocher, columns then rows).
    func maxDistance() -> Double {
        let infinity = 1e20
        var grid = mask.map { $0 != 0 ? infinity : 0 }
        var column = [Double](repeating: 0, count: height)
        for x in 0..<width {
            for y in 0..<height {
                column[y] = grid[y * width + x]
            }
            let transformed = Feature.distance1D(column)
            for y in 0..<height {
                grid[y * width + x] = transformed[y]
            }
        }
        var best = 0.0
        for y in 0..<height {
            let row = Feature.distance1D(Array(grid[(y * width)..<((y + 1) * width)]))
            best = max(best, row.max()!)
        }
        return best.squareRoot()
    }

    /// The 1-D squared distance transform of sampled function `f` (lower envelope of parabolas).
    static func distance1D(_ f: [Double]) -> [Double] {
        let n = f.count
        var result = [Double](repeating: 0, count: n)
        var vertices = [Int](repeating: 0, count: n)
        var bounds = [Double](repeating: 0, count: n + 1)
        var k = 0
        bounds[0] = -.infinity
        bounds[1] = .infinity
        func intersection(_ q: Int, _ v: Int) -> Double {
            ((f[q] + Double(q * q)) - (f[v] + Double(v * v))) / Double(2 * q - 2 * v)
        }
        for q in 1..<n {
            var s = intersection(q, vertices[k])
            while s <= bounds[k] {
                k -= 1
                s = intersection(q, vertices[k])
            }
            k += 1
            vertices[k] = q
            bounds[k] = s
            bounds[k + 1] = .infinity
        }
        k = 0
        for q in 0..<n {
            while bounds[k + 1] < Double(q) {
                k += 1
            }
            let v = vertices[k]
            result[q] = Double((q - v) * (q - v)) + f[v]
        }
        return result
    }

    // MARK: Thinning

    /// The eight neighbour offsets, clockwise from north: P2 ... P9 in Zhang–Suen's naming.
    var ring: [Int] { [-width, -width + 1, 1, width + 1, width, width - 1, -1, -width - 1] }

    /// Zhang–Suen thinning, then staircase removal: the one-pixel skeleton of the mask.
    func skeleton(check: () throws -> Void) throws -> [UInt8] {
        var image = mask
        let ring = self.ring
        var changed = true
        while changed {
            try check()
            changed = false
            for pass in 0..<2 {
                var removals: [Int] = []
                for y in 1..<(height - 1) {
                    for x in 1..<(width - 1) where image[y * width + x] != 0 {
                        let index = y * width + x
                        let p = ring.map { image[index + $0] != 0 }
                        let count = p.filter { $0 }.count
                        var transitions = 0
                        for i in 0..<8 where !p[i] && p[(i + 1) % 8] {
                            transitions += 1
                        }
                        let first = pass == 0 ? !(p[0] && p[2] && p[4]) : !(p[0] && p[2] && p[6])
                        let second = pass == 0 ? !(p[2] && p[4] && p[6]) : !(p[0] && p[4] && p[6])
                        if count >= 2 && count <= 6 && transitions == 1 && first && second {
                            removals.append(index)
                        }
                    }
                }
                for index in removals {
                    image[index] = 0
                }
                changed = changed || !removals.isEmpty
            }
        }
        // A pixel at the corner of an L whose ends touch diagonally is redundant: removing it
        // keeps its neighbours connected and leaves no spurious junction.
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) where image[y * width + x] != 0 {
                let index = y * width + x
                let p = ring.map { image[index + $0] != 0 }
                let count = p.filter { $0 }.count
                let corner = (p[0] && p[2]) || (p[2] && p[4]) || (p[4] && p[6]) || (p[6] && p[0])
                if count <= 3 && corner && Feature.neighbourGroups(p) == 1 {
                    image[index] = 0
                }
            }
        }
        return image
    }

    /// How many 8-connected groups the set neighbours `p` (clockwise from north) form among
    /// themselves: ring neighbours touch, and so do two edge neighbours either side of a corner.
    static func neighbourGroups(_ p: [Bool]) -> Int {
        var group = [Int](repeating: -1, count: 8)
        var groups = 0
        for start in 0..<8 where p[start] && group[start] < 0 {
            var pending = [start]
            group[start] = groups
            while let i = pending.popLast() {
                var touching = [(i + 1) % 8, (i + 7) % 8]
                if i % 2 == 0 {
                    touching += [(i + 2) % 8, (i + 6) % 8]
                }
                for j in touching where p[j] && group[j] < 0 {
                    group[j] = groups
                    pending.append(j)
                }
            }
            groups += 1
        }
        return groups
    }

    // MARK: Graph

    /// The feature's chains, spurs shorter than its width pruned, re-centred, with the median
    /// probe width; nil when the skeleton holds no chain (a lone dot).
    func stroke(featureWidth: Double, check: () throws -> Void) throws -> TraceStroke? {
        let skeleton = try skeleton(check: check)
        let ring = self.ring
        func neighbours(_ index: Int) -> [Int] {
            ring.map { index + $0 }.filter { skeleton[$0] != 0 }
        }
        let pixels = skeleton.indices.filter { skeleton[$0] != 0 }
        var degree = [Int](repeating: 0, count: skeleton.count)
        for index in pixels {
            degree[index] = neighbours(index).count
        }
        // Node clusters: 8-connected runs of pixels whose degree is not 2.
        var cluster = [Int](repeating: -1, count: skeleton.count)
        var clusterPixels: [[Int]] = []
        for index in pixels where degree[index] != 2 && cluster[index] < 0 {
            var members: [Int] = []
            var pending = [index]
            cluster[index] = clusterPixels.count
            while let current = pending.popLast() {
                members.append(current)
                for next in neighbours(current) where degree[next] != 2 && cluster[next] < 0 {
                    cluster[next] = clusterPixels.count
                    pending.append(next)
                }
            }
            clusterPixels.append(members)
        }
        let centers = clusterPixels.map { members -> Point in
            let sum = members.reduce(Point.zero) { $0 + (center($1) - .zero) }
            return Point(x: sum.x / Double(members.count), y: sum.y / Double(members.count))
        }
        let isEnd = clusterPixels.map { $0.count == 1 && degree[$0[0]] == 1 }
        var chains: [(points: [Point], ends: [Int], closed: Bool)] = []
        var visited = [Bool](repeating: false, count: skeleton.count)
        var directPairs = Set<[Int]>()
        for start in pixels where cluster[start] >= 0 {
            for first in neighbours(start) {
                let from = cluster[start]
                if cluster[first] >= 0 {
                    let pair = [min(from, cluster[first]), max(from, cluster[first])]
                    if cluster[first] != from && directPairs.insert(pair).inserted {
                        chains.append(([centers[from], centers[cluster[first]]], pair, false))
                    }
                    continue
                }
                guard !visited[first] else {
                    continue
                }
                var points = [centers[from], center(first)]
                visited[first] = true
                var previous = start
                var current = first
                var end = -1
                while end < 0 {
                    guard let next = neighbours(current).first(where: { $0 != previous && (cluster[$0] >= 0 || !visited[$0]) }) else {
                        break
                    }
                    if cluster[next] >= 0 {
                        end = cluster[next]
                        points.append(centers[end])
                    } else {
                        visited[next] = true
                        points.append(center(next))
                        previous = current
                        current = next
                    }
                }
                chains.append((points, [from, end], false))
            }
        }
        // What is left are loops without nodes.
        for start in pixels where cluster[start] < 0 && !visited[start] {
            var points = [center(start)]
            visited[start] = true
            var current = start
            while let next = neighbours(current).first(where: { !visited[$0] }) {
                visited[next] = true
                points.append(center(next))
                current = next
            }
            chains.append((points, [], true))
        }
        try check()
        // Junctions joined by a chain no longer than the feature is wide are one junction that
        // thinning split (an X becomes two Ts): merge them, and drop the chain between them.
        var parent = Array(clusterPixels.indices)
        func root(_ cluster: Int) -> Int {
            var current = cluster
            while parent[current] != current {
                current = parent[current]
            }
            return current
        }
        func isBridge(_ chain: (points: [Point], ends: [Int], closed: Bool)) -> Bool {
            !chain.closed && chain.ends[1] >= 0 && !isEnd[chain.ends[0]] && !isEnd[chain.ends[1]] && Double(chain.points.count) <= featureWidth
        }
        for chain in chains where isBridge(chain) {
            let a = root(chain.ends[0])
            let b = root(chain.ends[1])
            parent[max(a, b)] = min(a, b)
        }
        var merged = centers
        for group in Dictionary(grouping: clusterPixels.indices, by: root).values {
            let members = group.flatMap { clusterPixels[$0] }
            let sum = members.reduce(Point.zero) { $0 + (center($1) - .zero) }
            let mean = Point(x: sum.x / Double(members.count), y: sum.y / Double(members.count))
            for cluster in group {
                merged[cluster] = mean
            }
        }
        chains = chains.filter { !isBridge($0) }.map { chain in
            var chain = chain
            if !chain.closed {
                chain.points[0] = merged[chain.ends[0]]
                if chain.ends[1] >= 0 {
                    chain.points[chain.points.count - 1] = merged[chain.ends[1]]
                }
            }
            return chain
        }
        // Spurs: a chain from a free end to anything else, shorter than the feature is wide.
        let spur = max(2, featureWidth)
        var kept = chains.filter { chain in
            guard !chain.closed, chain.ends[1] >= 0 else {
                return true
            }
            return isEnd[chain.ends[0]] == isEnd[chain.ends[1]] || Double(chain.points.count) >= spur
        }
        if kept.isEmpty, let longest = chains.max(by: { $0.points.count < $1.points.count }) {
            kept = [longest]
        }
        var widths: [Double] = []
        var result: [TraceChain] = []
        for chain in kept where chain.points.count >= 2 {
            var points = chain.points
            let count = points.count
            for index in 0..<count {
                let sharedStart = !chain.closed && index == 0 && !isEnd[chain.ends[0]]
                let sharedEnd = !chain.closed && index == count - 1 && chain.ends[1] >= 0 && !isEnd[chain.ends[1]]
                guard !sharedStart && !sharedEnd else {
                    continue
                }
                let step = 3
                let before = chain.closed ? chain.points[(index - step + count) % count] : chain.points[max(index - step, 0)]
                let after = chain.closed ? chain.points[(index + step) % count] : chain.points[min(index + step, count - 1)]
                let direction = (after - before).normalized
                guard direction.length > 0 else {
                    continue
                }
                let normal = direction.perpendicular
                let forward = edge(from: chain.points[index], along: normal)
                let backward = edge(from: chain.points[index], along: normal * -1)
                widths.append(forward + backward)
                points[index] = chain.points[index] + normal * ((forward - backward) / 2)
            }
            result.append(TraceChain(points: points, closed: chain.closed))
        }
        guard !result.isEmpty else {
            return nil
        }
        let sorted = widths.sorted()
        let width = sorted.isEmpty ? max(featureWidth, 1) : sorted[sorted.count / 2]
        return TraceStroke(chains: result, width: width)
    }

    /// How far from `point` along unit `direction` the feature's edge lies, to 1/32 pixel.
    func edge(from point: Point, along direction: Vector) -> Double {
        let step = 1.0 / 16
        var t = step
        while t < 64 && covers(point + direction * t) {
            t += step
        }
        return t - step / 2
    }
}
