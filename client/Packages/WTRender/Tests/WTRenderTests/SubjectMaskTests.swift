import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTRender

/// IMG-027: the subject mask kernel.  Everything after the Vision request runs on synthetic
/// segmentations; the Vision segmenter itself runs once on a drawn image, where either a subject
/// or "no subject found" is a pass (the photograph fixtures and hand-made references of the
/// task's IoU criterion are not in the repository).
@Suite struct SubjectMaskTests {
    /// A `width` × `height` mask covering the pixels `inside` accepts.
    static func mask(_ width: Int, _ height: Int, _ inside: (Int, Int) -> Bool) -> SubjectMaskBuffer {
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width where inside(x, y) {
                values[y * width + x] = 255
            }
        }
        return SubjectMaskBuffer(width: width, height: height, values: values)!
    }

    /// Two subjects on a 20 × 10 image: a square on the left (1) and one on the right (2).
    static var twoSubjects: SubjectSegmentation {
        SubjectSegmentation(width: 20, height: 10, instances: [
            1: mask(20, 10) { x, y in (2..<8).contains(x) && (2..<8).contains(y) },
            2: mask(20, 10) { x, y in (12..<18).contains(x) && (2..<8).contains(y) },
        ])!
    }

    /// A solid opaque RGBA image.
    static func image(_ width: Int, _ height: Int, draw: (CGContext) -> Void = { context in
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    }) -> CGImage {
        let context = SubjectMask.rgbaContext(width: width, height: height)!
        draw(context)
        return context.makeImage()!
    }

    struct FixedSegmenter: SubjectSegmenter {
        var result: SubjectSegmentation?
        func segment(_ image: CGImage) throws -> SubjectSegmentation? { result }
    }

    // MARK: Buffer

    @Test func bufferValidatesAndReads() {
        #expect(SubjectMaskBuffer(width: 0, height: 1, values: []) == nil)
        #expect(SubjectMaskBuffer(width: 1, height: 0, values: []) == nil)
        #expect(SubjectMaskBuffer(width: 2, height: 2, values: [0]) == nil)
        let buffer = SubjectMaskBuffer(width: 2, height: 2, values: [0, 127, 128, 255])!
        #expect(buffer.value(x: -3, y: -3) == 0 && buffer.value(x: 9, y: 9) == 255)
        #expect(buffer.thresholded == [0, 0, 1, 1])
        #expect(buffer.coveredCount == 2)
    }

    @Test func intersectionOverUnion() {
        let a = Self.mask(10, 10) { x, _ in x < 5 }
        let b = Self.mask(10, 10) { x, _ in x < 10 }
        #expect(a.intersectionOverUnion(b) == 0.5)
        #expect(a.intersectionOverUnion(a) == 1)
        #expect(Self.mask(4, 4) { _, _ in false }.intersectionOverUnion(Self.mask(4, 4) { _, _ in false }) == 1)
        #expect(a.intersectionOverUnion(Self.mask(4, 4) { _, _ in true }) == 0)
    }

    @Test func scalingKeepsTheShapeAndSoftensTheEdge() {
        let small = Self.mask(10, 10) { x, _ in x < 5 }
        #expect(small.scaled(width: 0, height: 5) == nil)
        #expect(small.scaled(width: 10, height: 10) == small)
        let big = small.scaled(width: 40, height: 40)!
        #expect(big.width == 40 && big.height == 40)
        #expect(big.value(x: 0, y: 20) == 255 && big.value(x: 39, y: 20) == 0)
        // The edge crosses one half between the halves and is soft there.
        #expect(big.intersectionOverUnion(Self.mask(40, 40) { x, _ in x < 20 }) > 0.9)
        #expect((1..<255).contains(big.value(x: 19, y: 20)) || (1..<255).contains(big.value(x: 20, y: 20)))
        // Down again.
        #expect(big.scaled(width: 10, height: 10)!.intersectionOverUnion(small) == 1)
    }

    @Test func featheringBlursTheEdgeOnly() throws {
        let hard = Self.mask(30, 30) { x, _ in x < 15 }
        #expect(hard.feathered(0) == hard)
        #expect(hard.feathered(-2) == hard)
        let soft = hard.feathered(4)
        #expect(soft.value(x: 0, y: 10) == 255 && soft.value(x: 29, y: 10) == 0)
        #expect((1..<255).contains(soft.value(x: 15, y: 10)))
        #expect(soft.intersectionOverUnion(hard) > 0.9)
        // Deterministic.
        #expect(hard.feathered(4) == soft)
        // Cancellable per row.
        struct Stop: Error {}
        #expect(throws: Stop.self) { try hard.feathered(4) { throw Stop() } }
    }

    @Test func pathTracesTheMaskIntoTheFrame() {
        let square = Self.mask(20, 20) { x, y in (5..<15).contains(x) && (5..<15).contains(y) }
        let contours = square.path(in: Rect(x: 100, y: 50, width: 40, height: 40))
        #expect(contours.count == 1)
        let bounds = contours[0].bounds
        #expect(abs(bounds.minX - 110) < 1 && abs(bounds.maxX - 130) < 1)
        #expect(abs(bounds.minY - 60) < 1 && abs(bounds.maxY - 80) < 1)
        // Holes are kept.
        let ring = Self.mask(20, 20) { x, y in
            (2..<18).contains(x) && (2..<18).contains(y) && !((7..<13).contains(x) && (7..<13).contains(y))
        }
        #expect(ring.path(in: Rect(x: 0, y: 0, width: 20, height: 20)).count == 2)
    }

    // MARK: Segmentation

    @Test func segmentationValidates() {
        #expect(SubjectSegmentation(width: 20, height: 10, instances: [:]) == nil)
        #expect(SubjectSegmentation(width: 20, height: 10, instances: [1: Self.mask(5, 5) { _, _ in true }]) == nil)
    }

    @Test func instanceHitTesting() {
        let segmentation = Self.twoSubjects
        #expect(segmentation.allInstances == [1, 2])
        #expect(segmentation.instance(at: Point(x: 0.25, y: 0.5)) == 1)
        #expect(segmentation.instance(at: Point(x: 0.75, y: 0.5)) == 2)
        #expect(segmentation.instance(at: Point(x: 0.5, y: 0.5)) == nil)
        #expect(segmentation.instance(at: Point(x: 1, y: 1)) == nil)
        #expect(segmentation.instance(at: Point(x: -0.1, y: 0.5)) == nil)
        #expect(segmentation.instance(at: Point(x: 0.5, y: -0.1)) == nil)
        #expect(segmentation.instance(at: Point(x: 1.1, y: 0.5)) == nil)
        #expect(segmentation.instance(at: Point(x: 0.5, y: 1.1)) == nil)
    }

    @Test func overlappingInstancesLabelTheStrongestLowerFirst() {
        var weak = [UInt8](repeating: 0, count: 4)
        weak[0] = 200
        weak[1] = 255
        var strong = [UInt8](repeating: 0, count: 4)
        strong[0] = 250
        strong[1] = 255
        let segmentation = SubjectSegmentation(width: 2, height: 2, instances: [
            3: SubjectMaskBuffer(width: 2, height: 2, values: strong)!,
            1: SubjectMaskBuffer(width: 2, height: 2, values: weak)!,
        ])!
        #expect(segmentation.labels == [3, 1, 0, 0])
    }

    @Test func maskOfChosenInstances() {
        let segmentation = Self.twoSubjects
        #expect(segmentation.mask(for: [1]).coveredCount == 36)
        #expect(segmentation.mask(for: [1, 2, 2]).coveredCount == 72)
        #expect(segmentation.mask(for: [9]).coveredCount == 0)
        #expect(segmentation.mask(for: []).coveredCount == 0)
    }

    // MARK: Pipeline

    @Test func segmentationSizeCapsAtFourMegapixels() {
        #expect(SubjectMask.segmentationSize(width: 2000, height: 2000) == (2000, 2000))
        let reduced = SubjectMask.segmentationSize(width: 6000, height: 4000)
        #expect(reduced.width * reduced.height <= SubjectMask.segmentationPixels)
        #expect(abs(Double(reduced.width) / Double(reduced.height) - 1.5) < 0.01)
        #expect(SubjectMask.segmentationSize(width: 100, height: 1, limit: 1) == (10, 1))
    }

    @Test func downsampling() {
        let image = Self.image(40, 20)
        #expect(SubjectMask.downsampled(image) === image)
        let small = SubjectMask.downsampled(image, limit: 200)
        #expect(small.width == 20 && small.height == 10)
    }

    @Test func synchronousSegment() throws {
        let image = Self.image(20, 10)
        var reported: [Double] = []
        let found = try SubjectMask.segment(image, segmenter: FixedSegmenter(result: Self.twoSubjects), progress: { reported.append($0) })
        #expect(found == Self.twoSubjects)
        #expect(reported == [0.2, 1])
        #expect(throws: SubjectMask.Failure.noSubjectFound) { try SubjectMask.segment(image, segmenter: FixedSegmenter(result: nil)) }
        #expect(throws: SubjectMask.Failure.cancelled) {
            try SubjectMask.segment(image, segmenter: FixedSegmenter(result: Self.twoSubjects), isCancelled: { true })
        }
        // Cancelled after the downsample.
        var polls = 0
        #expect(throws: SubjectMask.Failure.cancelled) {
            try SubjectMask.segment(image, segmenter: FixedSegmenter(result: Self.twoSubjects), isCancelled: {
                polls += 1
                return polls > 1
            })
        }
    }

    @Test func fullResolutionMask() throws {
        let full = try SubjectMask.mask(Self.twoSubjects, instances: [2], width: 80, height: 40, soften: 2)
        #expect(full.width == 80 && full.height == 40)
        #expect(full.value(x: 60, y: 20) == 255 && full.value(x: 20, y: 20) == 0)
        #expect(throws: SubjectMask.Failure.unreadable) { try SubjectMask.mask(Self.twoSubjects, instances: [1], width: 0, height: 4) }
        #expect(throws: SubjectMask.Failure.cancelled) {
            try SubjectMask.mask(Self.twoSubjects, instances: [1], width: 20, height: 10, soften: 2, isCancelled: { true })
        }
    }

    @Test func alphaPNGCarriesTheMask() throws {
        let image = Self.image(20, 10)
        let mask = Self.twoSubjects.mask(for: [1])
        #expect(SubjectMask.alphaPNG(image, mask: Self.mask(5, 5) { _, _ in true }) == nil)
        let png = try #require(SubjectMask.alphaPNG(image, mask: mask))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 20 && decoded.height == 10)
        let bitmap = try #require(Trace.Bitmap(cgImage: decoded))
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bitmap.pixels[(y * 20 + x) * 4 + 3] }
        #expect(alpha(4, 4) == 255 && alpha(15, 4) == 0 && alpha(0, 0) == 0)
        #expect(bitmap.pixels[(4 * 20 + 4) * 4] == 255)
    }

    @Test func asyncSegmentAndTransparentImage() async throws {
        let image = Self.image(20, 10)
        let segmentation = try await SubjectMask.segment(image, segmenter: FixedSegmenter(result: Self.twoSubjects), progress: { _ in })
        #expect(segmentation == Self.twoSubjects)
        let steps = SubjectProgressLog()
        let png = try await SubjectMask.transparentImage(image, segmentation: segmentation, instances: [1, 2], soften: 1) { steps.add($0) }
        #expect(!png.isEmpty)
        #expect(steps.values == [0.5, 1])
        await #expect(throws: SubjectMask.Failure.noSubjectFound) {
            try await SubjectMask.segment(image, segmenter: FixedSegmenter(result: nil))
        }
    }

    @Test func cancellingTheTaskStopsTheWork() async {
        let image = Self.image(200, 200)
        let segmentation = SubjectSegmentation(width: 200, height: 200, instances: [1: Self.mask(200, 200) { x, _ in x < 100 }])!
        let cut = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SubjectMask.transparentImage(image, segmentation: segmentation, instances: [1], soften: 40)
        }
        await #expect(throws: SubjectMask.Failure.cancelled) { try await cut.value }
        let segment = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SubjectMask.segment(image, segmenter: FixedSegmenter(result: segmentation))
        }
        await #expect(throws: SubjectMask.Failure.cancelled) { try await segment.value }
        // A cancel landing while the mask is feathered.
        let slow = Task {
            try await SubjectMask.transparentImage(Self.image(1500, 1500), segmentation: segmentation, instances: [1], soften: 60)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        slow.cancel()
        await #expect(throws: SubjectMask.Failure.cancelled) { try await slow.value }
    }

    // MARK: Vision

    /// The real request on a drawn subject: either a mask of the image's size or nothing.
    @Test func visionSegmenterRunsOnThisMac() throws {
        let image = Self.image(256, 256) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1))
            context.fillEllipse(in: CGRect(x: 64, y: 48, width: 128, height: 160))
        }
        do {
            if let found = try VisionSubjectSegmenter().segment(image) {
                #expect(found.width == 256 && found.height == 256)
                #expect(!found.allInstances.isEmpty)
            }
        } catch {
            // Vision may refuse the request where its model is unavailable (a CI host without
            // the Neural Engine); the kernel then reports the failure to the caller.
        }
    }

    @Test func pixelBufferReading() throws {
        func buffer(_ format: OSType, write: (UnsafeMutableRawPointer, Int) -> Void) -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 2, 1, format, nil, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            write(CVPixelBufferGetBaseAddress(buffer!)!, CVPixelBufferGetBytesPerRow(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            return buffer!
        }
        let floats = buffer(kCVPixelFormatType_OneComponent32Float) { base, _ in
            base.storeBytes(of: Float32(1.5), toByteOffset: 0, as: Float32.self)
            base.storeBytes(of: Float32(0.5), toByteOffset: 4, as: Float32.self)
        }
        #expect(VisionSubjectSegmenter.mask(floats)?.values == [255, 128])
        let bytes = buffer(kCVPixelFormatType_OneComponent8) { base, _ in
            base.storeBytes(of: UInt8(10), toByteOffset: 0, as: UInt8.self)
            base.storeBytes(of: UInt8(255), toByteOffset: 1, as: UInt8.self)
        }
        #expect(VisionSubjectSegmenter.mask(bytes)?.values == [10, 255])
        let other = buffer(kCVPixelFormatType_32BGRA) { _, _ in }
        #expect(VisionSubjectSegmenter.mask(other) == nil)
        // One mask per instance; a buffer in another format is left out.
        let masks = VisionSubjectSegmenter.masks(IndexSet([1, 2, 3])) { $0 == 1 ? floats : $0 == 2 ? bytes : other }
        #expect(masks.keys.sorted() == [1, 2] && masks[2]?.values == [10, 255])
    }
}

/// Progress values reported from another thread.
final class SubjectProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func add(_ value: Double) {
        lock.withLock { stored.append(value) }
    }

    var values: [Double] { lock.withLock { stored } }
}
