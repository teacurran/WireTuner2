// The app's subject segmenter (IMG-027): Vision's foreground-instance request on this Mac.  The
// model ships with macOS, so nothing is downloaded and nothing leaves the machine.

import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// `VNGenerateForegroundInstanceMaskRequest` over the (already downsampled) image: every
/// instance Vision finds, each as its soft mask scaled to the image's size.
public struct VisionSubjectSegmenter: SubjectSegmenter {
    public init() {}

    public func segment(_ image: CGImage) throws -> SubjectSegmentation? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observation = request.results?.first
        let masks = try Self.masks(observation?.allInstances ?? []) { instance in
            try observation!.generateScaledMaskForImage(forInstances: [instance], from: handler)
        }
        // No instance (or no observation) is "no subject found".
        return SubjectSegmentation(width: image.width, height: image.height, instances: masks)
    }

    /// Each of `instances` with the mask `generate` makes for it (instances whose buffer is not
    /// a mask format are left out).
    static func masks(_ instances: IndexSet, generate: (Int) throws -> CVPixelBuffer) rethrows -> [Int: SubjectMaskBuffer] {
        var masks: [Int: SubjectMaskBuffer] = [:]
        for instance in instances {
            masks[instance] = mask(try generate(instance))
        }
        return masks
    }

    /// A one-component 32-bit float (0 ... 1) or 8-bit pixel buffer as a mask; nil for any
    /// other format.
    static func mask(_ buffer: CVPixelBuffer) -> SubjectMaskBuffer? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_OneComponent8 else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base + y * stride
            for x in 0..<width {
                let value = format == kCVPixelFormatType_OneComponent8
                    ? Double(row.load(fromByteOffset: x, as: UInt8.self)) / 255
                    : Double(row.load(fromByteOffset: x * 4, as: Float32.self))
                values[y * width + x] = UInt8((min(1, max(0, value)) * 255).rounded())
            }
        }
        return SubjectMaskBuffer(width: width, height: height, values: values)
    }
}
