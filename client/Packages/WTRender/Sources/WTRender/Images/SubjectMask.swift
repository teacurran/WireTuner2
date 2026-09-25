// The subject mask kernel (IMG-027; docs/_includes/imported/bitmaps.adoc, "Client"): an image's
// subjects found on this Mac, one of them picked by a click, and the result as a soft alpha mask,
// a transparent PNG or a path.  The segmentation itself sits behind `SubjectSegmenter`: the app
// uses `VisionSubjectSegmenter` (Vision's foreground-instance request, no network, the model
// ships with macOS); tests pass synthetic segmentations.  Everything after the request --
// instance hit-testing, scaling to full resolution, feathering, the PNG and the traced path --
// is plain arithmetic here, deterministic for a given image and instance choice.
//
// Coordinates: masks are y-down, row 0 at the top, pixel (x, y) covering [x, x + 1] × [y, y + 1],
// like `Trace.Bitmap`.

import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import WTGeometry

/// A single-channel 8-bit mask (0 outside, 255 fully inside).
public struct SubjectMaskBuffer: Hashable, Sendable {
    public let width: Int
    public let height: Int
    /// `width * height` coverage values, row 0 at the top.
    public let values: [UInt8]

    /// Nil when the value count does not match the dimensions or a dimension is not positive.
    public init?(width: Int, height: Int, values: [UInt8]) {
        guard width > 0, height > 0, values.count == width * height else {
            return nil
        }
        self.width = width
        self.height = height
        self.values = values
    }

    /// The coverage at pixel (`x`, `y`), clamped to the edges.
    public func value(x: Int, y: Int) -> UInt8 {
        values[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
    }

    /// 1 where the coverage is at least one half, 0 elsewhere.
    public var thresholded: [UInt8] {
        values.map { $0 >= 128 ? 1 : 0 }
    }

    /// The number of pixels at least half covered.
    public var coveredCount: Int {
        values.reduce(0) { $0 + ($1 >= 128 ? 1 : 0) }
    }

    /// Intersection over union of the two masks thresholded at one half (0 for different sizes;
    /// 1 when both are empty).
    public func intersectionOverUnion(_ other: SubjectMaskBuffer) -> Double {
        guard width == other.width, height == other.height else {
            return 0
        }
        var intersection = 0
        var union = 0
        for (a, b) in zip(values, other.values) {
            let inA = a >= 128, inB = b >= 128
            intersection += inA && inB ? 1 : 0
            union += inA || inB ? 1 : 0
        }
        return union == 0 ? 1 : Double(intersection) / Double(union)
    }

    /// The mask resampled bilinearly to `width` × `height` (pixel centres aligned), so the soft
    /// edge scales with it.
    public func scaled(width newWidth: Int, height newHeight: Int) -> SubjectMaskBuffer? {
        guard newWidth > 0, newHeight > 0 else {
            return nil
        }
        if newWidth == width, newHeight == height {
            return self
        }
        let sx = Double(width) / Double(newWidth)
        let sy = Double(height) / Double(newHeight)
        var out = [UInt8](repeating: 0, count: newWidth * newHeight)
        for y in 0..<newHeight {
            let fy = (Double(y) + 0.5) * sy - 0.5
            let y0 = Int(fy.rounded(.down))
            let ty = fy - Double(y0)
            for x in 0..<newWidth {
                let fx = (Double(x) + 0.5) * sx - 0.5
                let x0 = Int(fx.rounded(.down))
                let tx = fx - Double(x0)
                let top = Double(value(x: x0, y: y0)) * (1 - tx) + Double(value(x: x0 + 1, y: y0)) * tx
                let bottom = Double(value(x: x0, y: y0 + 1)) * (1 - tx) + Double(value(x: x0 + 1, y: y0 + 1)) * tx
                out[y * newWidth + x] = UInt8((top * (1 - ty) + bottom * ty).rounded())
            }
        }
        return SubjectMaskBuffer(width: newWidth, height: newHeight, values: out)
    }

    /// *Soften edge*: a separable Gaussian blur with σ = `soften` / 2 pixels (the mask itself for
    /// a value of 0 or less).
    public func feathered(_ soften: Double) -> SubjectMaskBuffer {
        feathered(soften, check: {})
    }

    /// `feathered(_:)`, polling `check` once per row; it may throw to cancel.
    public func feathered(_ soften: Double, check: () throws -> Void) rethrows -> SubjectMaskBuffer {
        let sigma = soften / 2
        guard sigma > 0 else {
            return self
        }
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var rows = [Double](repeating: 0, count: values.count)
        for y in 0..<height {
            try check()
            for x in 0..<width {
                var sum = 0.0
                for (offset, weight) in kernel.enumerated() {
                    sum += Double(value(x: x + offset - radius, y: y)) * weight
                }
                rows[y * width + x] = sum
            }
        }
        var out = [UInt8](repeating: 0, count: values.count)
        for y in 0..<height {
            try check()
            for x in 0..<width {
                var sum = 0.0
                for (offset, weight) in kernel.enumerated() {
                    sum += rows[min(max(y + offset - radius, 0), height - 1) * width + x] * weight
                }
                out[y * width + x] = UInt8(min(255, max(0, sum.rounded())))
            }
        }
        return SubjectMaskBuffer(width: width, height: height, values: out)!
    }

    /// *Clipping path* and *Select Subject*: the mask thresholded at one half and traced by the
    /// Trace kernel's outline stage (conformity 6, holes kept), mapped from mask pixels onto
    /// `frame` -- the image's natural frame, local space -- so the path follows the image's
    /// transform.
    public func path(in frame: Rect, conformity: Int = 6) -> [Contour] {
        let toFrame = AffineTransform(
            a: frame.width / Double(width), b: 0, c: 0, d: frame.height / Double(height),
            tx: frame.minX, ty: frame.minY
        )
        return Trace.outline(mask: thresholded, width: width, height: height, conformity: conformity, keepHoles: true)
            .map { $0.applying(toFrame) }
    }
}

/// What a segmenter found: the candidate subjects of the (downsampled) image, each as a soft
/// mask at the segmentation's resolution.  Instances are numbered from 1, as Vision numbers them.
public struct SubjectSegmentation: Hashable, Sendable {
    public let width: Int
    public let height: Int
    /// Instance number → its soft mask (`width` × `height`).
    public let instances: [Int: SubjectMaskBuffer]
    /// Per pixel, the instance covering it most (at least one half), 0 for background.
    public let labels: [UInt8]

    /// Nil when there is no instance or a mask's size differs from the segmentation's.
    public init?(width: Int, height: Int, instances: [Int: SubjectMaskBuffer]) {
        guard !instances.isEmpty, instances.values.allSatisfy({ $0.width == width && $0.height == height }) else {
            return nil
        }
        self.width = width
        self.height = height
        self.instances = instances
        var labels = [UInt8](repeating: 0, count: width * height)
        var best = [UInt8](repeating: 127, count: width * height)
        // Sorted, so ties go to the lower number whatever the dictionary order.
        for (number, mask) in instances.sorted(by: { $0.key < $1.key }) {
            for index in labels.indices where mask.values[index] > best[index] {
                best[index] = mask.values[index]
                labels[index] = UInt8(clamping: number)
            }
        }
        self.labels = labels
    }

    /// Every instance number, ascending: the default choice (all subjects).
    public var allInstances: [Int] { instances.keys.sorted() }

    /// The instance under `point` in unit image space (0 ... 1 of the natural frame, y down), nil
    /// on the background or outside the image: the sheet's click and kbd:[Shift]-click.
    public func instance(at point: Point) -> Int? {
        guard point.x >= 0, point.y >= 0, point.x <= 1, point.y <= 1 else {
            return nil
        }
        let x = min(Int(point.x * Double(width)), width - 1)
        let y = min(Int(point.y * Double(height)), height - 1)
        let label = Int(labels[y * width + x])
        return label == 0 ? nil : label
    }

    /// The soft mask of the chosen instances (the strongest of them per pixel) at the
    /// segmentation's resolution; unknown numbers are ignored and nothing chosen is empty.
    public func mask(for chosen: some Sequence<Int>) -> SubjectMaskBuffer {
        var values = [UInt8](repeating: 0, count: width * height)
        for number in Set(chosen) {
            guard let mask = instances[number] else {
                continue
            }
            for index in values.indices {
                values[index] = max(values[index], mask.values[index])
            }
        }
        return SubjectMaskBuffer(width: width, height: height, values: values)!
    }
}

/// Finds the subjects of an image.  Implementations run synchronously on the calling thread.
public protocol SubjectSegmenter: Sendable {
    /// The candidate subjects of `image`, or nil when there is none ("no subject found").
    func segment(_ image: CGImage) throws -> SubjectSegmentation?
}

/// Subject masks (IMG-027).
public enum SubjectMask {
    /// Why no mask was made.
    public enum Failure: Error, Hashable, Sendable {
        /// The segmenter found no subject (a flat logo, an empty image).
        case noSubjectFound
        /// The caller cancelled the work in flight.
        case cancelled
        /// A mask was asked for at a size that is not positive.
        case unreadable
    }

    /// The segmentation request's input size: at most 4 MP (bitmaps.adoc, "Client").
    public static let segmentationPixels = 4_000_000

    /// The size `width` × `height` is reduced to for segmentation: unchanged at or below
    /// `limit` pixels, else scaled down keeping the aspect ratio.
    public static func segmentationSize(width: Int, height: Int, limit: Int = segmentationPixels) -> (width: Int, height: Int) {
        guard width * height > limit else {
            return (width, height)
        }
        let scale = (Double(limit) / Double(width * height)).squareRoot()
        return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
    }

    /// `image` reduced to `segmentationSize` (the image itself when it is small enough), drawn
    /// into sRGB RGBA8.
    public static func downsampled(_ image: CGImage, limit: Int = segmentationPixels) -> CGImage {
        let size = segmentationSize(width: image.width, height: image.height, limit: limit)
        guard size.width != image.width || size.height != image.height else {
            return image
        }
        let context = rgbaContext(width: size.width, height: size.height)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()!
    }

    /// Segments `image` synchronously: downsampled, then handed to `segmenter`.  Throws
    /// `noSubjectFound` when it finds nothing and `cancelled` when `isCancelled` says so.
    public static func segment(
        _ image: CGImage,
        segmenter: any SubjectSegmenter,
        progress: ((Double) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> SubjectSegmentation {
        func check() throws {
            if isCancelled() {
                throw Failure.cancelled
            }
        }
        try check()
        let small = downsampled(image)
        progress?(0.2)
        try check()
        guard let segmentation = try segmenter.segment(small) else {
            throw Failure.noSubjectFound
        }
        progress?(1)
        return segmentation
    }

    /// The full-resolution soft mask of `chosen` for an image of `width` × `height`, feathered by
    /// `soften` (*Soften edge*).  One full-resolution buffer is held at a time besides the
    /// blur's row pass.
    public static func mask(
        _ segmentation: SubjectSegmentation,
        instances chosen: some Sequence<Int>,
        width: Int,
        height: Int,
        soften: Double = 0,
        isCancelled: () -> Bool = { false }
    ) throws -> SubjectMaskBuffer {
        guard let scaled = segmentation.mask(for: chosen).scaled(width: width, height: height) else {
            throw Failure.unreadable
        }
        return try scaled.feathered(soften) {
            if isCancelled() {
                throw Failure.cancelled
            }
        }
    }

    /// *Transparent image*: `image` with `mask` (of the image's size) as its alpha, encoded as
    /// a PNG; nil when the sizes differ or no context can be made.
    public static func alphaPNG(_ image: CGImage, mask: SubjectMaskBuffer) -> Data? {
        guard mask.width == image.width, mask.height == image.height, let context = rgbaContext(width: image.width, height: image.height) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        // Premultiplied: every channel scales with the new coverage.  Context row 0 is the top.
        for index in 0..<(image.width * image.height) {
            let coverage = UInt32(mask.values[index])
            for channel in 0..<4 {
                let value = UInt32(pixels[index * 4 + channel])
                pixels[index * 4 + channel] = UInt8((value * coverage + 127) / 255)
            }
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Segments `image` off the caller's actor (on a global queue, as `Trace.trace` does);
    /// cancelling the calling task throws `cancelled`.
    public static func segment(
        _ image: CGImage,
        segmenter: any SubjectSegmenter,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> SubjectSegmentation {
        let flag = Flag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try segment(image, segmenter: segmenter, progress: progress, isCancelled: { flag.isSet })
                    })
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    /// The transparent PNG of `chosen` off the caller's actor: the full-resolution mask,
    /// feathered, applied as alpha.  Progress goes 0 → 0.5 (mask) → 1 (PNG).
    public static func transparentImage(
        _ image: CGImage,
        segmentation: SubjectSegmentation,
        instances chosen: [Int],
        soften: Double = 0,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        let flag = Flag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        if flag.isSet {
                            throw Failure.cancelled
                        }
                        let full = try mask(segmentation, instances: chosen, width: image.width, height: image.height, soften: soften) { flag.isSet }
                        progress?(0.5)
                        // The mask is made at the image's size, so the PNG always encodes.
                        let png = alphaPNG(image, mask: full)!
                        progress?(1)
                        return png
                    })
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    static func rgbaContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
    }

    /// Set when the calling task is cancelled.
    final class Flag: Sendable {
        private let flag = Atomic<Bool>(false)

        func set() {
            flag.store(true, ordering: .relaxed)
        }

        var isSet: Bool {
            flag.load(ordering: .relaxed)
        }
    }
}
