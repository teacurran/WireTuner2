// The *Photo* tracer (IMG-029; docs/_includes/imported/tracing.adoc, "Tracing photographs" and
// "Client"): the sampled bitmap is divided into regions before tracing -- the subject instances
// (IMG-027's `SubjectSegmenter`) and, where a semantic-segmentation class map is available, the
// classes of the rest -- small regions are merged into their largest neighbour, region edges are
// snapped to the picture's own colour edges within 2 px, and each region is quantized and traced by
// the classic pipeline on its own, largest first.  Without a class map (a build without the model)
// the regions are subject and background; with a single region (a logo) the result is the classic
// trace exactly.  Nothing leaves the Mac, and nothing about the regions is kept: they only group
// the paths.

import CoreGraphics
import Foundation
import Synchronization
import WTGeometry

extension Trace {
    /// The options sheet's *Tracer*.
    public enum Tracer: String, Hashable, Sendable, CaseIterable {
        /// Regions of similar colour (IMG-021).
        case classic
        /// Regions of the things in the picture first, then each traced as *Classic*.
        case photo
    }

    /// A semantic-segmentation class map: per pixel a class number (0 unlabelled) at the map's own
    /// resolution, and the classes' names ("Person", "Sky", ...).
    public struct ClassMap: Hashable, Sendable {
        public let width: Int
        public let height: Int
        public let labels: [UInt16]
        public let names: [UInt16: String]

        /// Nil when the label count does not match the dimensions.
        public init?(width: Int, height: Int, labels: [UInt16], names: [UInt16: String]) {
            guard width > 0, height > 0, labels.count == width * height else {
                return nil
            }
            self.width = width
            self.height = height
            self.labels = labels
            self.names = names
        }

        /// The class at pixel (`x`, `y`) of a `width` × `height` image (nearest sample).
        func label(x: Int, y: Int, width imageWidth: Int, height imageHeight: Int) -> UInt16 {
            labels[min(y * height / imageHeight, height - 1) * width + min(x * width / imageWidth, width - 1)]
        }
    }

    /// Produces a class map for an image (the bundled Core ML model's request); nil when it finds
    /// nothing.  Runs synchronously on the calling thread.
    public protocol ClassMapping: Sendable {
        func classMap(for image: CGImage) throws -> ClassMap?
    }

    /// One region of a photo trace: its name (the class label, "Subject", "Background", or
    /// "Region N" when unlabelled), its size and its paths in painter's order.
    public struct PhotoRegion: Hashable, Sendable {
        public var name: String
        public var pixelCount: Int
        public var paths: [TracedPath]
    }

    /// A photo trace: the regions, largest first (painter's order), each a sub-group of the trace.
    public struct PhotoResult: Hashable, Sendable {
        public var regions: [PhotoRegion]

        /// Every path in painter's order, as a classic `Result`.
        public var flattened: Result {
            Result(paths: regions.flatMap(\.paths))
        }
    }

    /// Dividing a bitmap into regions (`Trace.Segmenter`).
    public enum Segmenter {
        /// The regions: per pixel a region number (0 ..< `names.count`), each region's name and
        /// pixel count.
        public struct Regions: Hashable, Sendable {
            public let width: Int
            public let height: Int
            public var labels: [Int32]
            public var names: [String]
            public var counts: [Int]
            /// Whether each region comes from a subject instance.
            var subjects: [Bool] = []
        }

        /// The smallest region kept when *Noise tolerance* is lower: 16 px.
        public static let minimumArea = 16

        /// The regions of `bitmap`: subject instances first (named after the class most of each
        /// covers, else "Subject"), then connected areas of one class of `classMap` (or one
        /// "Background" without it), regions under max(`noiseTolerance`², 16) px merged into their
        /// largest neighbour, and region edges snapped to colour edges within 2 px.
        public static func segment(_ bitmap: Bitmap, subjects: SubjectSegmentation?, classMap: ClassMap?, noiseTolerance: Int = 0,
                                   check: () throws -> Void = {}) throws -> Regions {
            let width = bitmap.width, height = bitmap.height
            // Source keys: an instance number (1 ... 255), or 1000 + a class number.
            var keys = [Int32](repeating: 1000, count: width * height)
            for y in 0..<height {
                try check()
                for x in 0..<width {
                    let index = y * width + x
                    if let subjects {
                        let sx = min(x * subjects.width / width, subjects.width - 1), sy = min(y * subjects.height / height, subjects.height - 1)
                        let instance = subjects.labels[sy * subjects.width + sx]
                        if instance != 0 {
                            keys[index] = Int32(instance)
                            continue
                        }
                    }
                    if let classMap { keys[index] = 1000 + Int32(classMap.label(x: x, y: y, width: width, height: height)) }
                }
            }
            var regions = try components(keys, width: width, height: height, check: check)
            let area = max(noiseTolerance * noiseTolerance, minimumArea)
            try merge(&regions, eligible: { region, counts in counts[Int(region)] < area }, into: { _, neighbours, counts in
                neighbours.max { (counts[Int($0)], -$0) < (counts[Int($1)], -$1) }
            }, check: check)
            // Names: a subject after the class most of it covers; a class area after its class.
            var votes: [Int32: [UInt16: Int]] = [:]
            if let classMap {
                for index in regions.labels.indices where keys[index] < 1000 {
                    let label = classMap.label(x: index % width, y: index / width, width: width, height: height)
                    if label != 0 { votes[regions.labels[index], default: [:]][label, default: 0] += 1 }
                }
            }
            regions.subjects = regions.names.map { Int32($0)! < 1000 }
            var unnamed = 0
            regions.names = regions.names.enumerated().map { region, key in
                let key = Int32(key)!
                if key < 1000 {
                    let best = votes[Int32(region)]?.max { ($0.value, -Int($0.key)) < ($1.value, -Int($1.key)) }?.key
                    return best.flatMap { classMap?.names[$0] } ?? "Subject"
                }
                guard let classMap else { return "Background" }
                let label = UInt16(key - 1000)
                if label != 0, let name = classMap.names[label] { return name }
                unnamed += 1
                return "Region \(unnamed)"
            }
            // A class area of the class a neighbouring subject is named after belongs to it (the
            // class map's person around the person instance).
            let subjects = regions.subjects, names = regions.names
            try merge(&regions, eligible: { region, _ in !subjects[Int(region)] }, into: { region, neighbours, counts in
                neighbours.filter { subjects[Int($0)] && names[Int($0)] == names[Int(region)] }.max { (counts[Int($0)], -$0) < (counts[Int($1)], -$1) }
            }, check: check)
            try snap(&regions, to: bitmap, check: check)
            return regions
        }

        /// The 4-connected areas of equal key; names hold each area's key as text until named.
        static func components(_ keys: [Int32], width: Int, height: Int, check: () throws -> Void) throws -> Regions {
            var labels = [Int32](repeating: -1, count: keys.count)
            var names: [String] = []
            var counts: [Int] = []
            var stack: [Int] = []
            for start in keys.indices where labels[start] < 0 {
                try check()
                let region = Int32(counts.count)
                let key = keys[start]
                var count = 0
                labels[start] = region
                stack.append(start)
                while let index = stack.popLast() {
                    count += 1
                    let x = index % width, y = index / width
                    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                        let next = ny * width + nx
                        if labels[next] < 0, keys[next] == key {
                            labels[next] = region
                            stack.append(next)
                        }
                    }
                }
                names.append(String(key))
                counts.append(count)
            }
            return Regions(width: width, height: height, labels: labels, names: names, counts: counts)
        }

        /// Merges each `eligible` region into the neighbour `into` picks (smallest regions first,
        /// repeatedly, against the current merged regions), then renumbers the survivors, which
        /// keep their order and names.
        static func merge(_ regions: inout Regions, eligible: (Int32, [Int]) -> Bool, into: (Int32, Set<Int32>, [Int]) -> Int32?,
                          check: () throws -> Void) throws {
            let width = regions.width, height = regions.height
            var target = Array(0..<Int32(regions.counts.count))
            func root(_ region: Int32) -> Int32 {
                var current = region
                while target[Int(current)] != current { current = target[Int(current)] }
                return current
            }
            var counts = regions.counts
            var changed = true
            while changed {
                try check()
                changed = false
                // Each eligible region's neighbours (by current root).
                var neighbours: [Int32: Set<Int32>] = [:]
                for y in 0..<height {
                    for x in 0..<width {
                        let here = root(regions.labels[y * width + x])
                        guard eligible(here, counts) else { continue }
                        for (nx, ny) in [(x + 1, y), (x, y + 1)] where nx < width && ny < height {
                            let there = root(regions.labels[ny * width + nx])
                            if there != here { neighbours[here, default: []].insert(there) }
                        }
                        for (nx, ny) in [(x - 1, y), (x, y - 1)] where nx >= 0 && ny >= 0 {
                            let there = root(regions.labels[ny * width + nx])
                            if there != here { neighbours[here, default: []].insert(there) }
                        }
                    }
                }
                for small in neighbours.keys.sorted(by: { (counts[Int($0)], $0) < (counts[Int($1)], $1) }) {
                    let from = root(small)
                    guard from == small, eligible(from, counts),
                          let chosen = into(from, Set(neighbours[small]!.map(root).filter { $0 != from }), counts)
                    else { continue }
                    target[Int(from)] = chosen
                    counts[Int(chosen)] += counts[Int(from)]
                    counts[Int(from)] = 0
                    changed = true
                }
            }
            var number: [Int32: Int32] = [:]
            var names: [String] = []
            var survivors: [Int] = []
            var subjects: [Bool] = []
            for region in 0..<Int32(regions.counts.count) where root(region) == region {
                number[region] = Int32(names.count)
                names.append(regions.names[Int(region)])
                survivors.append(counts[Int(region)])
                if Int(region) < regions.subjects.count { subjects.append(regions.subjects[Int(region)]) }
            }
            regions.labels = regions.labels.map { number[root($0)]! }
            regions.names = names
            regions.counts = survivors
            regions.subjects = subjects
        }

        /// Moves region edges onto the picture's colour edges: every pixel within 2 px of an edge
        /// joins whichever region around it (within 2 px) has the mean colour nearest its own.
        static func snap(_ regions: inout Regions, to bitmap: Bitmap, check: () throws -> Void) throws {
            let width = regions.width, height = regions.height
            guard regions.counts.count > 1 else { return }
            var sums = [SIMD3<Double>](repeating: .zero, count: regions.counts.count)
            var weights = [Double](repeating: 0, count: regions.counts.count)
            for index in regions.labels.indices {
                let p = index * 4
                sums[Int(regions.labels[index])] += SIMD3(Double(bitmap.pixels[p]), Double(bitmap.pixels[p + 1]), Double(bitmap.pixels[p + 2]))
                weights[Int(regions.labels[index])] += 1
            }
            let means = zip(sums, weights).map { $1 > 0 ? $0 / $1 : $0 }
            let original = regions.labels
            // The pixels within 2 px of an edge: edge pixels, dilated twice.
            var near = [Bool](repeating: false, count: original.count)
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    if (x + 1 < width && original[index + 1] != original[index]) || (y + 1 < height && original[index + width] != original[index]) {
                        near[index] = true
                        if x + 1 < width { near[index + 1] = true }
                        if y + 1 < height { near[index + width] = true }
                    }
                }
            }
            for _ in 0..<2 {
                try check()
                let seed = near
                for y in 0..<height {
                    for x in 0..<width where seed[y * width + x] {
                        for ny in max(0, y - 1)...min(height - 1, y + 1) {
                            for nx in max(0, x - 1)...min(width - 1, x + 1) { near[ny * width + nx] = true }
                        }
                    }
                }
            }
            var snapped = original
            for y in 0..<height {
                try check()
                for x in 0..<width where near[y * width + x] {
                    let index = y * width + x
                    var candidates: Set<Int32> = []
                    for dy in -2...2 {
                        for dx in -2...2 {
                            let nx = x + dx, ny = y + dy
                            if nx >= 0, ny >= 0, nx < width, ny < height { candidates.insert(original[ny * width + nx]) }
                        }
                    }
                    guard candidates.count > 1 else { continue }
                    let p = index * 4
                    let color = SIMD3(Double(bitmap.pixels[p]), Double(bitmap.pixels[p + 1]), Double(bitmap.pixels[p + 2]))
                    func distance(_ region: Int32) -> Double {
                        let d = means[Int(region)] - color
                        return (d * d).sum()
                    }
                    let current = original[index]
                    var best = current
                    for candidate in candidates.sorted() where distance(candidate) < distance(best) {
                        best = candidate
                    }
                    snapped[index] = best
                }
            }
            regions.labels = snapped
            var counts = [Int](repeating: 0, count: regions.counts.count)
            for label in snapped { counts[Int(label)] += 1 }
            regions.counts = counts
        }
    }

    /// The *Photo* trace of `bitmap`: `subjects` (IMG-027's instances at any resolution) and
    /// `classMap` (the model's classes; nil without the model) segment it, then each region is
    /// traced with `options` -- its *Colors* per region -- largest first.  One region traces
    /// exactly as `run` does.  `progress` and `isCancelled` behave as for `run`.
    public static func runPhoto(
        _ bitmap: Bitmap,
        options: Options = Options(),
        subjects: SubjectSegmentation?,
        classMap: ClassMap?,
        transform: AffineTransform = .identity,
        progress: ((Double) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> PhotoResult {
        func check() throws {
            if isCancelled() {
                throw Cancelled()
            }
        }
        let regions = try Segmenter.segment(bitmap, subjects: subjects, classMap: classMap, noiseTolerance: options.noiseTolerance, check: check)
        progress?(0.2)
        let order = regions.counts.indices.filter { regions.counts[$0] > 0 }.sorted { (-regions.counts[$0], $0) < (-regions.counts[$1], $1) }
        guard order.count > 1 else {
            let result = try run(bitmap, options: options, transform: transform, progress: { progress?(0.2 + 0.8 * $0) }, isCancelled: isCancelled)
            return PhotoResult(regions: [PhotoRegion(name: regions.names.first ?? "Region 1", pixelCount: bitmap.width * bitmap.height, paths: result.paths)])
        }
        var traced: [PhotoRegion] = []
        var done = 0
        let total = order.reduce(0) { $0 + regions.counts[$1] }
        for region in order {
            try check()
            let (crop, origin) = masked(bitmap, regions: regions, region: Int32(region))
            let placed = AffineTransform.translation(x: Double(origin.x), y: Double(origin.y)).concatenating(transform)
            let share = Double(regions.counts[region]) / Double(total)
            let start = 0.2 + 0.8 * Double(done) / Double(total)
            let result = try run(crop, options: options, transform: placed, progress: { progress?(start + 0.8 * share * $0) }, isCancelled: isCancelled)
            traced.append(PhotoRegion(name: regions.names[region], pixelCount: regions.counts[region], paths: result.paths))
            done += regions.counts[region]
        }
        progress?(1)
        return PhotoResult(regions: traced)
    }

    /// `region`'s bounding box of `bitmap` with every pixel outside the region transparent, and
    /// the box's origin.
    static func masked(_ bitmap: Bitmap, regions: Segmenter.Regions, region: Int32) -> (Bitmap, (x: Int, y: Int)) {
        let width = bitmap.width
        var minX = width, minY = bitmap.height, maxX = -1, maxY = -1
        for index in regions.labels.indices where regions.labels[index] == region {
            let x = index % width, y = index / width
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
        let boxWidth = maxX - minX + 1, boxHeight = maxY - minY + 1
        var pixels = [UInt8](repeating: 0, count: boxWidth * boxHeight * 4)
        for y in 0..<boxHeight {
            for x in 0..<boxWidth {
                let source = (minY + y) * width + minX + x
                guard regions.labels[source] == region else { continue }
                let target = (y * boxWidth + x) * 4
                for channel in 0..<4 { pixels[target + channel] = bitmap.pixels[source * 4 + channel] }
            }
        }
        return (Bitmap(width: boxWidth, height: boxHeight, pixels: pixels)!, (minX, minY))
    }

    /// The *Photo* trace off the caller's actor (as `trace`): segments `image` (the sampled
    /// bitmap as an image) with `segmenter` and `mapper` -- either may be absent -- then traces;
    /// cancelling the calling task throws `Cancelled`.
    public static func tracePhoto(
        _ bitmap: Bitmap,
        image: CGImage?,
        options: Options = Options(),
        segmenter: (any SubjectSegmenter)?,
        mapper: (any ClassMapping)?,
        transform: AffineTransform = .identity,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> PhotoResult {
        let flag = PhotoCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Swift.Result {
                        let subjects = try image.flatMap { try segmenter?.segment($0) }
                        if flag.isSet { throw Cancelled() }
                        let classMap = try image.flatMap { try mapper?.classMap(for: $0) }
                        return try runPhoto(bitmap, options: options, subjects: subjects, classMap: classMap, transform: transform,
                                            progress: progress, isCancelled: { flag.isSet })
                    })
                }
            }
        } onCancel: {
            flag.set()
        }
    }
}

/// The flag `tracePhoto` sets when its calling task is cancelled.
private final class PhotoCancellation: Sendable {
    private let flag = Synchronization.Atomic<Bool>(false)

    func set() {
        flag.store(true, ordering: .relaxed)
    }

    var isSet: Bool {
        flag.load(ordering: .relaxed)
    }
}
