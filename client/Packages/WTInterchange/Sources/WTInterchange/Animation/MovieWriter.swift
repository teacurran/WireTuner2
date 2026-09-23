// MP4 movies (WEB-020; animation.adoc, "Client"): `AVAssetWriter` with an
// `AVAssetWriterInputPixelBufferAdaptor`, H.264 or HEVC.  Every frame is rendered once over its
// background (a movie has no alpha; *Transparent* reads as white and is reported) into a BGRA
// pixel buffer at an even pixel size, and pushed once per frame period -- a frame held for three
// periods is pushed three times -- at presentation times `period / fps`; the session ends at the
// last frame's end, so the movie lasts exactly the animation's duration.  A movie does not
// loop; *Loop* is ignored.  The writer runs on the calling thread (the async `export` runs it
// off the main actor), reports progress per period and, cancelled, cancels the writer and
// removes the partial file.

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

struct MovieWriter {
    enum Codec {
        case h264
        case hevc
    }

    let codec: Codec
    /// The timescale of presentation times: exact for every whole frame rate up to 120 and for
    /// hundredths of a frame per second.
    static let timescale: CMTimeScale = 600_000

    /// Bits per pixel and frame for a quality of 1 ... 100.
    static func bitsPerPixel(quality: Int) -> Double {
        0.02 + 0.3 * Double(min(max(quality, 1), 100)) / 100
    }

    func write(scene: ExportScene, options: MP4Options, to url: URL, progress: ExportProgress) throws -> [String] {
        guard (1...100).contains(options.quality) else {
            throw ExportError.invalidOption("MP4 quality must be 1 to 100.")
        }
        let plan = try AnimationPlan(scene: scene, options: options.common, evenSize: true)
        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        let bitRate = MovieWriter.bitsPerPixel(quality: options.quality) * Double(plan.width * plan.height) * plan.timeline.fps
        let settings: [String: Any] = [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(Int(bitRate), 100_000)],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: plan.width,
            kCVPixelBufferHeightKey as String: plan.height,
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.writeFailed(writer.error?.localizedDescription ?? "the movie could not be started")
        }
        writer.startSession(atSourceTime: .zero)
        let total = plan.timeline.totalPeriods
        var period = 0
        do {
            for index in plan.frames.indices {
                try progress.check()
                let buffer = try pixelBuffer(plan.image(index, alpha: false), width: plan.width, height: plan.height)
                for _ in 0..<plan.timeline.holds[index] {
                    try progress.check()
                    while !input.isReadyForMoreMediaData {
                        try progress.check()
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    guard adaptor.append(buffer, withPresentationTime: time(period, fps: plan.timeline.fps)) else {
                        throw ExportError.writeFailed(writer.error?.localizedDescription ?? "a frame could not be encoded")
                    }
                    period += 1
                    progress.report(Double(period) / Double(total + 1))
                }
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: time(total, fps: plan.timeline.fps))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.writeFailed(writer.error?.localizedDescription ?? "the movie could not be finished")
        }
        var notes: [String] = []
        if plan.background == .transparent {
            notes.append("MP4 has no transparency: frames are drawn over white")
        }
        if plan.evened {
            notes.append("the movie is \(plan.width) × \(plan.height) pixels: video sizes are even")
        }
        return notes
    }

    /// The presentation time of frame period `period`.
    func time(_ period: Int, fps: Double) -> CMTime {
        CMTime(value: CMTimeValue((Double(period) / fps * Double(MovieWriter.timescale)).rounded()), timescale: MovieWriter.timescale)
    }

    /// `image` (opaque, `width` × `height`) copied into a new BGRA pixel buffer.
    func pixelBuffer(_ image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created) == kCVReturnSuccess, let buffer = created else {
            throw ExportError.writeFailed("no pixel buffer of \(width) × \(height) pixels could be made")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
