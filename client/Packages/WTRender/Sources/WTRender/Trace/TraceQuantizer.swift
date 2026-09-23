// Quantization for the trace kernel (IMG-021): median cut over a 15-bit colour histogram (or a
// 256-level gray histogram), then noise filtering on the label image.  Everything iterates
// arrays in index order, so the palette and the labels are identical on every run.

import Foundation

/// A quantized bitmap: one palette index per pixel, `TraceLabels.none` for transparent pixels.
struct TraceLabels: Hashable, Sendable {
    static let none = UInt16.max

    let width: Int
    let height: Int
    var labels: [UInt16]
    /// Palette colours, straight sRGB 0 ... 1.
    var palette: [Color]

    /// Rec. 601 luma of palette entry `index`.
    func luminance(_ index: Int) -> Double {
        let color = palette[index]
        return 0.299 * color.red + 0.587 * color.green + 0.114 * color.blue
    }

    /// Palette indices lightest first (ties by index): the painter's order.
    var paintOrder: [Int] {
        palette.indices.sorted { lhs, rhs in
            let a = luminance(lhs)
            let b = luminance(rhs)
            return a != b ? a > b : lhs < rhs
        }
    }

    /// The lightest palette entry: the paper centerline tracing leaves untraced.
    var paper: Int? { paintOrder.first }
}

enum TraceQuantizer {
    /// One histogram bin taking part in median cut.
    private struct Bin {
        var coordinates: SIMD3<Int32>
        var count: Int
        var sum: SIMD3<Int>
    }

    /// The bitmap reduced to at most `colors` palette entries by median cut.
    static func quantize(_ bitmap: Trace.Bitmap, colors: Int, grays: Bool, check: () throws -> Void) throws -> TraceLabels {
        let binCount = grays ? 256 : 32_768
        var counts = [Int](repeating: 0, count: binCount)
        var sums = [SIMD3<Int>](repeating: .zero, count: binCount)
        var pixelBins = [Int32](repeating: -1, count: bitmap.width * bitmap.height)
        let pixels = bitmap.pixels
        for y in 0..<bitmap.height {
            try check()
            for x in 0..<bitmap.width {
                let index = y * bitmap.width + x
                let offset = index * 4
                guard pixels[offset + 3] >= 128 else {
                    continue
                }
                let rgb = SIMD3(Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
                let bin: Int
                if grays {
                    bin = (299 * rgb.x + 587 * rgb.y + 114 * rgb.z + 500) / 1000
                } else {
                    bin = (rgb.x >> 3) << 10 | (rgb.y >> 3) << 5 | (rgb.z >> 3)
                }
                pixelBins[index] = Int32(bin)
                counts[bin] += 1
                sums[bin] &+= grays ? SIMD3(repeating: bin) : rgb
            }
        }
        var bins: [Bin] = []
        for bin in 0..<binCount where counts[bin] > 0 {
            let coordinates = grays ? SIMD3(Int32(bin), 0, 0) : SIMD3(Int32(bin >> 10), Int32((bin >> 5) & 31), Int32(bin & 31))
            bins.append(Bin(coordinates: coordinates, count: counts[bin], sum: sums[bin]))
        }
        let boxes = try medianCut(bins, target: colors, check: check)
        var binPalette = [UInt16](repeating: TraceLabels.none, count: binCount)
        var palette: [Color] = []
        for (paletteIndex, box) in boxes.enumerated() {
            var count = 0
            var sum = SIMD3<Int>.zero
            for bin in box {
                count += bin.count
                sum &+= bin.sum
                let key = grays ? Int(bin.coordinates.x) : Int(bin.coordinates.x) << 10 | Int(bin.coordinates.y) << 5 | Int(bin.coordinates.z)
                binPalette[key] = UInt16(paletteIndex)
            }
            let mean = SIMD3<Double>(Double(sum.x), Double(sum.y), Double(sum.z)) / (Double(count) * 255)
            palette.append(Color(red: mean.x, green: mean.y, blue: mean.z))
        }
        var labels = [UInt16](repeating: TraceLabels.none, count: pixelBins.count)
        for y in 0..<bitmap.height {
            try check()
            for index in (y * bitmap.width)..<((y + 1) * bitmap.width) where pixelBins[index] >= 0 {
                labels[index] = binPalette[Int(pixelBins[index])]
            }
        }
        return TraceLabels(width: bitmap.width, height: bitmap.height, labels: labels, palette: palette)
    }

    /// Splits the bins into at most `target` boxes: repeatedly the box with the widest channel
    /// range (ties: the earlier box) at the population median along that channel.  Polls once
    /// per split: a split sorts at most the 32,768 histogram bins.
    private static func medianCut(_ bins: [Bin], target: Int, check: () throws -> Void) throws -> [[Bin]] {
        var boxes = bins.isEmpty ? [] : [bins]
        while boxes.count < target {
            try check()
            var best = -1
            var bestRange: Int32 = 0
            var bestChannel = 0
            for (index, box) in boxes.enumerated() {
                let (channel, range) = widestChannel(box)
                if range > bestRange {
                    best = index
                    bestRange = range
                    bestChannel = channel
                }
            }
            guard best >= 0 else {
                break
            }
            let sorted = boxes[best].sorted { lhs, rhs in
                lhs.coordinates[bestChannel] != rhs.coordinates[bestChannel]
                    ? lhs.coordinates[bestChannel] < rhs.coordinates[bestChannel]
                    : (lhs.coordinates.x, lhs.coordinates.y, lhs.coordinates.z) < (rhs.coordinates.x, rhs.coordinates.y, rhs.coordinates.z)
            }
            let total = sorted.reduce(0) { $0 + $1.count }
            var running = 0
            var split = 1
            for (index, bin) in sorted.enumerated().dropLast() {
                running += bin.count
                split = index + 1
                if running * 2 >= total {
                    break
                }
            }
            boxes[best] = Array(sorted[..<split])
            boxes.insert(Array(sorted[split...]), at: best + 1)
        }
        return boxes
    }

    /// The channel with the largest coordinate range in `box` and that range (0 for one bin).
    private static func widestChannel(_ box: [Bin]) -> (Int, Int32) {
        var low = box[0].coordinates
        var high = box[0].coordinates
        for bin in box {
            low = pointwiseMin(low, bin.coordinates)
            high = pointwiseMax(high, bin.coordinates)
        }
        let range = high &- low
        var channel = 0
        for candidate in 1..<3 where range[candidate] > range[channel] {
            channel = candidate
        }
        return (channel, range[channel])
    }

    // MARK: Noise

    /// *Noise tolerance*: 1 ... 5 a 3 × 3 filter that adopts a neighbouring label held by at
    /// least `9 − tolerance` (from 8 down to 5) of the nine pixels, run twice at 5; larger values
    /// merge 4-connected regions smaller than `tolerance²` pixels into their most common
    /// neighbour.
    static func filterNoise(_ labels: inout TraceLabels, tolerance: Int, check: () throws -> Void) throws {
        if tolerance >= 6 {
            try mergeSmallRegions(&labels, below: tolerance * tolerance, check: check)
        } else if tolerance >= 1 {
            let threshold = 9 - min(tolerance, 4)
            for _ in 0..<(tolerance == 5 ? 2 : 1) {
                try majority(&labels, threshold: threshold, check: check)
            }
        }
    }

    private static func majority(_ labels: inout TraceLabels, threshold: Int, check: () throws -> Void) throws {
        let width = labels.width
        let height = labels.height
        let source = labels.labels
        var result = source
        var window = [UInt16](repeating: 0, count: 9)
        for y in 0..<height {
            try check()
            for x in 0..<width {
                var filled = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = min(max(x + dx, 0), width - 1)
                        let ny = min(max(y + dy, 0), height - 1)
                        window[filled] = source[ny * width + nx]
                        filled += 1
                    }
                }
                let current = source[y * width + x]
                for candidate in window where candidate != current {
                    if window.reduce(0, { $0 + ($1 == candidate ? 1 : 0) }) >= threshold {
                        result[y * width + x] = candidate
                        break
                    }
                }
            }
        }
        labels.labels = result
    }

    private static func mergeSmallRegions(_ labels: inout TraceLabels, below area: Int, check: () throws -> Void) throws {
        let width = labels.width
        let height = labels.height
        var region = [Int32](repeating: -1, count: width * height)
        var stack: [Int] = []
        stack.reserveCapacity(1024)
        var members: [Int] = []
        members.reserveCapacity(1024)
        var neighbourCounts: [UInt16: Int] = [:]
        var regionIndex: Int32 = 0
        for start in 0..<(width * height) {
            if start % width == 0 {
                try check()
            }
            guard region[start] < 0 else {
                continue
            }
            let label = labels.labels[start]
            members.removeAll(keepingCapacity: true)
            neighbourCounts.removeAll(keepingCapacity: true)
            region[start] = regionIndex
            stack.append(start)
            while let index = stack.popLast() {
                // One region can cover most of the bitmap: poll every row's worth of pixels.
                if members.count % width == width - 1 {
                    try check()
                }
                members.append(index)
                let x = index % width
                let y = index / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let neighbour = ny * width + nx
                    let other = labels.labels[neighbour]
                    if other == label {
                        if region[neighbour] < 0 {
                            region[neighbour] = regionIndex
                            stack.append(neighbour)
                        }
                    } else {
                        neighbourCounts[other, default: 0] += 1
                    }
                }
            }
            regionIndex += 1
            let replacement = neighbourCounts.max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key }?.key
            if members.count < area, let replacement {
                for index in members {
                    labels.labels[index] = replacement
                }
            }
        }
    }
}
