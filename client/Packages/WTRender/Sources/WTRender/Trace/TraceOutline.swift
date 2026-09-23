// Outline tracing (IMG-021): boundary following on the pixel-corner lattice after Potrace's
// path decomposition, with the "minority" turn policy at diagonal configurations, then a
// polygon approximation of each staircase and Schneider fitting (GEO-004).
//
// Every boundary is walked with the inside on the right, so in y-down bitmap space outer
// boundaries have positive shoelace area and holes negative: hole polarity falls out of the
// walk, and the contours fill correctly under either fill rule.  The walk records only the
// lattice corners where it turns, into buffers allocated once per tracer.

import WTGeometry
import Foundation

/// One traced boundary: its polygon samples in bitmap pixel space.
struct TraceLoop: Hashable, Sendable {
    var samples: [Point]
    /// Positive (outer) or negative (hole) boundary.
    var isOuter: Bool
}

struct TraceOutline {
    let width: Int
    let height: Int
    /// The mask with a one-pixel border of outside all round: `(x + 1) + (y + 1) * stride`.
    private var mask: [UInt8]
    private let stride: Int
    /// Left edges already walked, one per pixel: `y * width + x`.
    private var visited: [UInt8]
    /// Turn corners of the loop being walked, as x, y pairs.
    private(set) var corners: [Int32] = []

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        stride = width + 2
        mask = [UInt8](repeating: 0, count: (width + 2) * (height + 2))
        visited = [UInt8](repeating: 0, count: width * height)
        corners.reserveCapacity(4 * (width + height) + 16)
    }

    /// Replaces the mask with the pixels for which `inside(y * width + x)` holds.
    mutating func load(_ inside: (Int) -> Bool) {
        for y in 0..<height {
            for x in 0..<width {
                mask[(x + 1) + (y + 1) * stride] = inside(y * width + x) ? 1 : 0
            }
        }
        for index in visited.indices {
            visited[index] = 0
        }
    }

    /// Whether pixel (x, y) is inside; outside the bitmap is outside.
    func inside(_ x: Int, _ y: Int) -> Bool {
        x >= -1 && y >= -1 && x <= width && y <= height && mask[(x + 1) + (y + 1) * stride] != 0
    }

    /// Every boundary of the mask, in scan order of its first left edge.
    mutating func loops(check: () throws -> Void) throws -> [TraceLoop] {
        var result: [TraceLoop] = []
        for y in 0..<height {
            try check()
            for x in 0..<width where visited[y * width + x] == 0 && inside(x, y) && !inside(x - 1, y) {
                let area = walk(fromX: x, y: y)
                result.append(TraceLoop(samples: TraceOutline.samples(corners), isOuter: area > 0))
            }
        }
        return result
    }

    // MARK: Walking

    /// Direction vectors, clockwise on screen from north: turning right adds one.
    private static let directions: [(Int, Int)] = [(0, -1), (1, 0), (0, 1), (-1, 0)]

    /// Walks the boundary whose left edge at pixel (x, y) is unvisited, leaving its turn
    /// corners in `corners`; returns twice the shoelace area.
    mutating func walk(fromX startX: Int, y startY: Int) -> Int {
        corners.removeAll(keepingCapacity: true)
        let startCornerX = startX
        let startCornerY = startY + 1
        var cx = startCornerX
        var cy = startCornerY
        var heading = 0
        var area = 0
        repeat {
            let (dx, dy) = TraceOutline.directions[heading]
            if heading == 0 {
                visited[(cy - 1) * width + cx] = 1
            }
            let nx = cx + dx
            let ny = cy + dy
            area += cx * ny - nx * cy
            cx = nx
            cy = ny
            let turn = decide(cx, cy, heading: heading)
            if turn != heading {
                corners.append(Int32(cx))
                corners.append(Int32(cy))
            }
            heading = turn
        } while !(cx == startCornerX && cy == startCornerY && heading == 0)
        return area
    }

    /// The heading leaving corner (cx, cy) after arriving along `heading`.
    private func decide(_ cx: Int, _ cy: Int, heading: Int) -> Int {
        let (dx, dy) = TraceOutline.directions[heading]
        let (rx, ry) = (-dy, dx)
        let right = inside(cx + min(0, dx) + min(0, rx), cy + min(0, dy) + min(0, ry))
        let left = inside(cx + min(0, dx) + min(0, -rx), cy + min(0, dy) + min(0, -ry))
        switch (left, right) {
        case (false, true): return heading
        case (true, true): return (heading + 3) % 4
        case (false, false): return (heading + 1) % 4
        case (true, false): return insideIsMinority(cx, cy) ? (heading + 3) % 4 : (heading + 1) % 4
        }
    }

    /// Potrace's minority test at a diagonal corner: square rings of radius 2 ... 4 around the
    /// corner are counted (+1 inside, −1 outside) until one leans; the inside pixels connect
    /// across the diagonal only when they are the local minority.  A perfectly balanced
    /// neighbourhood leaves them apart.
    private func insideIsMinority(_ cx: Int, _ cy: Int) -> Bool {
        for radius in 2...4 {
            var count = 0
            for offset in -radius..<radius {
                count += inside(cx + offset, cy - radius) ? 1 : -1
                count += inside(cx + radius - 1, cy + offset) ? 1 : -1
                count += inside(cx + offset, cy + radius - 1) ? 1 : -1
                count += inside(cx - radius, cy + offset) ? 1 : -1
            }
            if count != 0 {
                return count < 0
            }
        }
        return false
    }

    // MARK: Polygon approximation

    /// Samples for fitting from a staircase's turn corners: the midpoint of every lattice run,
    /// plus the corner itself where the runs either side are both at least two pixels long (a
    /// real corner rather than a step of a slanted edge).
    static func samples(_ corners: [Int32]) -> [Point] {
        let count = corners.count / 2
        var result: [Point] = []
        result.reserveCapacity(count * 2)
        func corner(_ index: Int) -> Point {
            let wrapped = (index + count) % count
            return Point(x: Double(corners[wrapped * 2]), y: Double(corners[wrapped * 2 + 1]))
        }
        for index in 0..<count {
            let previous = corner(index - 1)
            let current = corner(index)
            let next = corner(index + 1)
            if previous.distance(to: current) >= 2 && current.distance(to: next) >= 2 {
                result.append(current)
            }
            result.append(Point.lerp(current, next, 0.5))
        }
        return result
    }
}

/// Fitting traced samples with the shared curve fitter.
enum TraceFitting {
    /// Turning angle at or above which a sample is a corner of the fitted outline.
    static let cornerAngle = Double.pi * 0.4

    /// A closed contour through `samples` within `tolerance`: the samples are rotated to start
    /// at the sharpest corner, if any, so the seam is a corner rather than a kink.
    static func closedContour(_ samples: [Point], tolerance: Double) -> Contour {
        guard samples.count >= 4 else {
            return Contour(polygon: samples, closed: true)
        }
        var sharpest = 0
        var sharpestTurn = -1.0
        let count = samples.count
        for index in 0..<count {
            let before = samples[index] - samples[(index + count - 1) % count]
            let after = samples[(index + 1) % count] - samples[index]
            let turn = abs(atan2(before.cross(after), before.dot(after)))
            if turn > sharpestTurn {
                sharpestTurn = turn
                sharpest = index
            }
        }
        let rotated = Array(samples[sharpest...] + samples[..<sharpest]) + [samples[sharpest]]
        let fitter = CurveFitter(maxError: tolerance, cornerAngle: cornerAngle, cornerWindow: 1)
        return Contour(segments: fitter.fit(rotated), closed: true)
    }

    /// An open contour through `samples` within `tolerance`.
    static func openContour(_ samples: [Point], tolerance: Double) -> Contour {
        let fitter = CurveFitter(maxError: tolerance, cornerAngle: cornerAngle, cornerWindow: 2)
        return Contour(segments: fitter.fit(samples), closed: false)
    }
}
