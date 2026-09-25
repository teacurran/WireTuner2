import AppKit
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTRender

/// The Trace tool's *Photo* tracer (tracing.adoc, "Tracing photographs"; IMG-029's app half):
/// the options sheet's *Tracer* picks it, the sampled pixels are segmented into the things in the
/// picture -- Vision's subject instances and, when the build carries the model, its classes
/// (`CoreMLClassMapper`) -- and each region is traced as *Classic* (`Trace.tracePhoto`).  The
/// result is placed as one group holding one sub-group per region, largest first, named after the
/// region ("Person", "Sky", "Region 2").
@MainActor
enum PhotoTrace {
    /// The subject segmenter (Vision; replaceable in tests).
    static var segmenter: (any SubjectSegmenter)? = VisionSubjectSegmenter()
    /// The class model, when the build carries one (none is bundled yet).
    static var mapper: (any Trace.ClassMapping)? = CoreMLClassMapper.bundled()

    static func title(_ tracer: Trace.Tracer) -> String {
        switch tracer {
        case .classic: "Classic"
        case .photo: "Photo"
        }
    }

    /// `bitmap` as an sRGB image for the segmenters.
    nonisolated static func image(_ bitmap: Trace.Bitmap) -> CGImage? {
        var premultiplied = bitmap.pixels
        for index in 0..<(bitmap.width * bitmap.height) {
            let alpha = Int(premultiplied[index * 4 + 3])
            for channel in 0..<3 {
                premultiplied[index * 4 + channel] = UInt8((Int(premultiplied[index * 4 + channel]) * alpha + 127) / 255)
            }
        }
        return CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: CGDataProvider(data: Data(premultiplied) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The *Photo* trace of `bitmap` off the main actor.
    static func trace(_ bitmap: Trace.Bitmap, options: Trace.Options, transform: WTGeometry.AffineTransform,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> Trace.PhotoResult {
        try await Trace.tracePhoto(bitmap, image: image(bitmap), options: options, segmenter: segmenter, mapper: mapper, transform: transform,
                                   progress: progress)
    }

    /// The group a photo trace places: one sub-group per region that traced to something, named
    /// after it; a single region's paths go straight in the group.
    static func group(_ result: Trace.PhotoResult, name: String) -> ImportedGroup {
        let regions = result.regions.filter { !$0.paths.isEmpty }
        guard regions.count > 1 else { return ImportedGroup(children: TraceFeatures.imported(regions.first?.paths ?? []), name: name) }
        return ImportedGroup(children: regions.map { .group(ImportedGroup(children: TraceFeatures.imported($0.paths), name: $0.name)) }, name: name)
    }
}

extension TraceFeatures {
    /// A photo trace's result above `source` (or on the current layer), one change.
    @discardableResult
    func placePhoto(_ result: Trace.PhotoResult, source: OpID?, in context: ToolContext) -> Task<Void, Never> {
        let sourceName = source.map { ObjectNaming.name(of: $0, in: context.document.state) }
        return place(PhotoTrace.group(result, name: sourceName.map { "Trace of \($0)" } ?? "Trace"), source: source, in: context)
    }
}
