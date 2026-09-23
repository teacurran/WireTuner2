// WEB-019 and WEB-020: animated GIF, APNG and MP4 export.  Files are read back with ImageIO and
// AVFoundation (frame count, delays, loop count, pixels, duration, codec) and, where
// `/opt/homebrew/bin/ffprobe` exists, cross-checked by FFmpeg's reader; progress, cancellation
// (the partial file removed) and the async run off the calling actor are exercised.

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct AnimationExportTests {
    static let background = NodeID(counter: 1, replica: 9)
    static let layers = (2...4).map { NodeID(counter: UInt64($0), replica: 9) }
    static let colors = [Color(red: 1, green: 0, blue: 0), Color(red: 0, green: 0.8, blue: 0), Color(red: 0, green: 0, blue: 1)]

    /// A background layer (a grey bar) and three frame layers, each a square further right.
    static var displayList: DisplayList {
        var items = [Corpus.path(Corpus.rect(0, 50, 120, 10), [Corpus.fill(.solid(Color(white: 0.5)))])]
        var spans = [LayerSpan(layer: LayerRendering(id: background, printing: false), range: 0..<1)]
        for (index, layer) in layers.enumerated() {
            items.append(Corpus.path(Corpus.rect(Double(index) * 40, 0, 40, 40), [Corpus.fill(.solid(colors[index]))]))
            spans.append(LayerSpan(layer: LayerRendering(id: layer), range: (index + 1)..<(index + 2)))
        }
        return DisplayList(canvas: "animation", items: items, layers: spans)
    }

    static func scene(fps: Double = 10, holds: [Int] = [1, 3, 1], loop: Bool = true, background: ExportAnimation.Background = .white, source: FrameSource = .layers, pages: [Rect] = []) -> ExportScene {
        let animationLayers = [AnimationLayer(id: Self.background, printing: false)] + layers.enumerated().map { AnimationLayer(id: $0.element, hold: holds[$0.offset]) }
        let frames = FrameComposer.frames(source: source, layers: animationLayers, pages: pages)
        let animation = ExportAnimation(frames: frames, fps: fps, loop: loop, background: background, displayList: displayList, area: Rect(x: 0, y: 0, width: 120, height: 60), pageColor: Color(red: 1, green: 1, blue: 0.8))
        return ExportScene(name: "Animation", pages: [Corpus.page([], width: 120, height: 60)], animation: animation)
    }

    static func url(_ name: String, _ format: ExportFormat) -> URL {
        Corpus.directory().appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).\(format.fileExtension)")
    }

    static func export(_ format: ExportFormat, _ options: any ExportOptions, scene: ExportScene = scene(), name: String, progress: ExportProgress? = nil) throws -> ExportSummary {
        try AnimationExporter(format: format, progress: progress).export(scene: scene, options: options, to: ExportDestination(url: url(name, format)))
    }

    /// The frames of an animated image with their properties (the GIF or PNG dictionary).
    static func frames(_ url: URL) throws -> (images: [CGImage], properties: [[CFString: Any]], file: [CFString: Any]) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let count = CGImageSourceGetCount(source)
        var images: [CGImage] = []
        var properties: [[CFString: Any]] = []
        for index in 0..<count {
            images.append(try #require(CGImageSourceCreateImageAtIndex(source, index, nil)))
            let all = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            properties.append((all[kCGImagePropertyGIFDictionary] ?? all[kCGImagePropertyPNGDictionary]) as? [CFString: Any] ?? [:])
        }
        let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        return (images, properties, (file[kCGImagePropertyGIFDictionary] ?? file[kCGImagePropertyPNGDictionary]) as? [CFString: Any] ?? [:])
    }

    /// The RGBA of one pixel (top-left origin).
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { Int(bytes[$0]) }
    }

    static func close(_ a: [Int], _ b: [Int], _ tolerance: Int = 12) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// FFmpeg's view of a file's duration, when ffprobe is installed.
    static func ffprobeDuration(_ url: URL) -> Double? {
        let tool = "/opt/homebrew/bin/ffprobe"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-v", "error", "-count_frames", "-show_entries", "format=duration", "-of", "csv=p=0", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return Double(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: GIF

    @Test func gifFramesCarryHoldsLoopAndPixels() throws {
        let summary = try Self.export(.animatedGIF, AnimatedGIFOptions(), name: "frames")
        #expect(summary.notes.isEmpty)
        let read = try Self.frames(summary.files[0])
        #expect(read.images.count == 3)
        let delays = read.properties.map { ($0[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? -1 }
        #expect(delays.map { ($0 * 100).rounded() } == [10, 30, 10])
        #expect(read.file[kCGImagePropertyGIFLoopCount] as? Int == 0)
        #expect(read.images[0].width == 120 && read.images[0].height == 60)
        for (index, image) in read.images.enumerated() {
            let c = Self.colors[index]
            #expect(Self.close(Self.pixel(image, index * 40 + 20, 20), [Int(c.red * 255), Int(c.green * 255), Int(c.blue * 255), 255]))
            // The background layer is in every frame (drawn at the canvas's 50% dimming).
            #expect(Self.pixel(image, 60, 55)[0] < 250)
            // The other frames' squares are not.
            #expect(Self.close(Self.pixel(image, ((index + 1) % 3) * 40 + 20, 20), [255, 255, 255, 255]))
        }
        if let duration = Self.ffprobeDuration(summary.files[0]) {
            #expect(abs(duration - 0.5) < 0.011)
        }
    }

    @Test func gifLoopCountsColorsDitherAndTransparency() throws {
        let three = try Self.frames(Self.export(.animatedGIF, AnimatedGIFOptions(common: AnimationCommonOptions(loop: .count(3))), name: "three").files[0])
        // ImageIO reports the plays (the NETSCAPE2.0 repeats plus the first play).
        #expect(three.file[kCGImagePropertyGIFLoopCount] as? Int == 3)
        let once = try Self.export(.animatedGIF, AnimatedGIFOptions(), scene: Self.scene(loop: false), name: "once")
        #expect(((try Self.frames(once.files[0]).file[kCGImagePropertyGIFLoopCount] as? Int) ?? 1) == 1)
        let forever = try Self.frames(Self.export(.animatedGIF, AnimatedGIFOptions(common: AnimationCommonOptions(loop: .forever)), scene: Self.scene(loop: false), name: "forever").files[0])
        #expect(forever.file[kCGImagePropertyGIFLoopCount] as? Int == 0)

        let clear = try Self.export(.animatedGIF, AnimatedGIFOptions(common: AnimationCommonOptions(background: .transparent), colors: 4, ditherPercent: 100), name: "clear")
        let frames = try Self.frames(clear.files[0])
        #expect(Self.pixel(frames.images[1], 100, 20)[3] == 0, "transparent background")
        #expect(Self.pixel(frames.images[1], 60, 20)[3] == 255)
        var distinct = Set<[Int]>()
        for y in stride(from: 0, to: 60, by: 3) {
            for x in stride(from: 0, to: 120, by: 3) {
                distinct.insert(Self.pixel(frames.images[0], x, y))
            }
        }
        #expect(distinct.count <= 4)
        // A page-colour background.
        let page = try Self.frames(Self.export(.animatedGIF, AnimatedGIFOptions(), scene: Self.scene(background: .pageColor), name: "page").files[0])
        #expect(Self.close(Self.pixel(page.images[0], 100, 20), [255, 255, 204, 255]))
    }

    @Test func gifDropsFramesShorterThanTwoCentiseconds() throws {
        let summary = try Self.export(.animatedGIF, AnimatedGIFOptions(common: AnimationCommonOptions(fps: 120)), scene: Self.scene(holds: [1, 1, 1]), name: "fast")
        #expect(summary.notes.contains { $0.contains("2 frames shorter than 0.02 s left out") })
        let read = try Self.frames(summary.files[0])
        #expect(read.images.count == 1)
        #expect(read.properties[0][kCGImagePropertyGIFUnclampedDelayTime] as? Double == 0.03)
        // Long animations keep their total: 50 frames at 30 fps last 1.67 s in 2-4 cs steps.
        let plan = try AnimationPlan(scene: Self.scene(holds: [1, 1, 1]), options: AnimationCommonOptions(fps: 30))
        let delays = plan.centisecondDelays()
        #expect(delays.frames.map(\.delay) == [3, 4, 3] && delays.dropped == 0)
    }

    // MARK: APNG

    @Test func apngCarriesDelaysLoopAndRealTransparency() throws {
        let summary = try Self.export(.apng, APNGOptions(common: AnimationCommonOptions(size: .scale(2), loop: .count(2), background: .transparent)), name: "apng")
        let read = try Self.frames(summary.files[0])
        #expect(read.images.count == 3)
        let delays = read.properties.map { ($0[kCGImagePropertyAPNGUnclampedDelayTime] as? Double) ?? ($0[kCGImagePropertyAPNGDelayTime] as? Double) ?? -1 }
        #expect(delays.map { ($0 * 100).rounded() } == [10, 30, 10])
        #expect(read.file[kCGImagePropertyAPNGLoopCount] as? Int == 2)
        #expect(read.images[0].width == 240 && read.images[0].height == 120)
        #expect(Self.pixel(read.images[0], 200, 40)[3] == 0)
        #expect(Self.close(Self.pixel(read.images[2], 200, 40), [0, 0, 255, 255]))
        if let duration = Self.ffprobeDuration(summary.files[0]) {
            #expect(abs(duration - 0.5) < 0.011)
        }
    }

    @Test func pixelSizeFitsAndCentresTheFrame() throws {
        let summary = try Self.export(.apng, APNGOptions(common: AnimationCommonOptions(size: .pixels(width: 240, height: 60), background: .white)), name: "wide")
        let image = try Self.frames(summary.files[0]).images[0]
        #expect(image.width == 240 && image.height == 60)
        // The 120 × 60 area sits in the middle: the red square spans x 60 ... 100.
        #expect(Self.close(Self.pixel(image, 80, 20), [255, 0, 0, 255]))
        #expect(Self.close(Self.pixel(image, 30, 20), [255, 255, 255, 255]))
    }

    @Test func pagesSourceAndPageFilter() throws {
        let pages = [Rect(x: 0, y: 0, width: 60, height: 60), Rect(x: 60, y: 0, width: 60, height: 60)]
        let scene = Self.scene(source: .pages, pages: pages)
        let both = try Self.frames(Self.export(.apng, APNGOptions(), scene: scene, name: "pages").files[0])
        #expect(both.images.count == 2 && both.images[0].width == 60)
        let second = try Self.frames(Self.export(.apng, APNGOptions(common: AnimationCommonOptions(pages: [1])), scene: scene, name: "page2").files[0])
        #expect(second.images.count == 1)
        #expect(Self.close(Self.pixel(second.images[0], 10, 20), [0, 204, 0, 255]), "page 2 (x 60...120) shows the green square to x 80")
        #expect(Self.close(Self.pixel(second.images[0], 40, 20), [0, 0, 255, 255]))
        #expect(throws: ExportError.nothingToExport) {
            try Self.export(.apng, APNGOptions(common: AnimationCommonOptions(pages: [5])), scene: scene, name: "none")
        }
    }

    // MARK: MP4

    static func movieFacts(_ url: URL) async throws -> (duration: Double, size: CGSize, frames: Int, codec: FourCharCode) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let descriptions = try await track.load(.formatDescriptions)
        let codec = CMFormatDescriptionGetMediaSubType(try #require(descriptions.first))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            frames += CMSampleBufferGetNumSamples(sample)
        }
        return (duration, size, frames, codec)
    }

    @Test(arguments: [ExportFormat.mp4H264, .mp4HEVC])
    func movieHasTheAnimationsDurationAndSize(_ format: ExportFormat) async throws {
        let progress = ExportProgress()
        let summary = try await AnimationExporter(format: format).export(scene: Self.scene(fps: 10), options: MP4Options(common: AnimationCommonOptions(size: .pixels(width: 161, height: 81), antiAliasing: 1)), to: ExportDestination(url: Self.url("movie", format)), progress: progress)
        #expect(progress.fraction == 1)
        #expect(summary.notes == ["the movie is 160 × 80 pixels: video sizes are even"])
        let facts = try await Self.movieFacts(summary.files[0])
        #expect(abs(facts.duration - 0.5) < 0.001)
        #expect(facts.size == CGSize(width: 160, height: 80))
        #expect(facts.frames == 5, "holds repeat frames: 1 + 3 + 1 periods")
        #expect(facts.codec == (format == .mp4HEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264))
        if let duration = Self.ffprobeDuration(summary.files[0]) {
            #expect(abs(duration - 0.5) < 0.001)
        }
    }

    @Test func transparentMovieIsDrawnOverWhite() async throws {
        let summary = try Self.export(.mp4H264, MP4Options(common: AnimationCommonOptions(background: .transparent, antiAliasing: 1), quality: 1), scene: Self.scene(fps: 0.5, holds: [1, 1, 1]), name: "white")
        #expect(summary.notes == ["MP4 has no transparency: frames are drawn over white"])
        let facts = try await Self.movieFacts(summary.files[0])
        #expect(abs(facts.duration - 6) < 0.001 && facts.frames == 3)
    }

    // MARK: Progress, cancellation and options

    /// Holds the progress a callback cancels.
    final class Canceller: @unchecked Sendable {
        var progress: ExportProgress?
    }

    @Test(arguments: [ExportFormat.animatedGIF, .apng, .mp4H264])
    func cancellingRemovesThePartialFile(_ format: ExportFormat) throws {
        let options: any ExportOptions = format == .animatedGIF ? AnimatedGIFOptions() : (format == .apng ? APNGOptions() as any ExportOptions : MP4Options())
        // Cancelled before the first frame.
        let before = ExportProgress()
        before.cancel()
        let url = Self.url("cancel", format)
        #expect(throws: ExportError.cancelled) {
            try AnimationExporter(format: format, progress: before).export(scene: Self.scene(), options: options, to: ExportDestination(url: url))
        }
        #expect(!FileManager.default.fileExists(atPath: url.path) && before.fraction == 0)
        // Cancelled part-way, once a third is done.
        let canceller = Canceller()
        let partway = ExportProgress(onChange: { fraction in if fraction > 0.3 { canceller.progress?.cancel() } })
        canceller.progress = partway
        let second = Self.url("cancel-late", format)
        #expect(throws: ExportError.cancelled) {
            try AnimationExporter(format: format, progress: partway).export(scene: Self.scene(), options: options, to: ExportDestination(url: second))
        }
        #expect(!FileManager.default.fileExists(atPath: second.path) && partway.fraction > 0.3 && partway.fraction < 1)
    }

    @Test func cancellingTheTaskCancelsTheExport() async throws {
        let progress = ExportProgress()
        let url = Self.url("task", .mp4H264)
        let scene = Self.scene(fps: 30, holds: [100, 100, 100])
        // Cancelled as it starts: the cancellation handler runs at once and cancels the export.
        let task = Task {
            try await AnimationExporter(format: .mp4H264).export(scene: scene, options: MP4Options(common: AnimationCommonOptions(size: .scale(4), antiAliasing: 1)), to: ExportDestination(url: url), progress: progress)
        }
        task.cancel()
        await #expect(throws: ExportError.cancelled) { try await task.value }
        #expect(progress.isCancelled && !FileManager.default.fileExists(atPath: url.path))
    }

    @Test func optionsAndScenesAreValidated() throws {
        let invalid: [AnimationCommonOptions] = [
            AnimationCommonOptions(size: .scale(0)), AnimationCommonOptions(size: .pixels(width: 0, height: 10)),
            AnimationCommonOptions(fps: 500), AnimationCommonOptions(loop: .count(0)), AnimationCommonOptions(antiAliasing: 5),
        ]
        for common in invalid {
            #expect(throws: ExportError.self) { try Self.export(.apng, APNGOptions(common: common), name: "bad") }
        }
        #expect(throws: ExportError.invalidOption("A palette holds 2 to 256 colors.")) { try Self.export(.animatedGIF, AnimatedGIFOptions(colors: 1), name: "bad") }
        #expect(throws: ExportError.invalidOption("MP4 quality must be 1 to 100.")) { try Self.export(.mp4H264, MP4Options(quality: 0), name: "bad") }
        #expect(throws: ExportError.wrongOptions(format: .apng)) { try Self.export(.apng, PNGOptions(), name: "bad") }
        #expect(throws: ExportError.nothingToExport) {
            try Self.export(.animatedGIF, AnimatedGIFOptions(), scene: ExportScene(pages: [Corpus.page([])]), name: "still")
        }
        #expect(throws: ExportError.nothingToExport) { try Self.export(.mp4H264, MP4Options(), scene: Self.scene(source: .none), name: "none") }
        // An APNG that cannot be written (its folder is missing) fails.
        let missing = Corpus.directory().appendingPathComponent("missing-\(UUID().uuidString)/a.png")
        #expect(throws: ExportError.self) {
            try AnimationExporter(format: .apng).export(scene: Self.scene(), options: APNGOptions(), to: ExportDestination(url: missing))
        }
        #expect(throws: ExportError.self) {
            try AnimationExporter(format: .animatedGIF).export(scene: Self.scene(), options: AnimatedGIFOptions(), to: ExportDestination(url: missing))
        }
        #expect(throws: ExportError.self) {
            try AnimationExporter(format: .mp4H264).export(scene: Self.scene(), options: MP4Options(), to: ExportDestination(url: missing))
        }
        #expect(ObjectIdentifier(AnimationExporter(format: .apng).optionsType) == ObjectIdentifier(APNGOptions.self))
        #expect(ObjectIdentifier(AnimationExporter(format: .mp4HEVC).optionsType) == ObjectIdentifier(MP4Options.self))
        #expect(ObjectIdentifier(AnimationExporter(format: .animatedGIF).optionsType) == ObjectIdentifier(AnimatedGIFOptions.self))
        #expect(ExportError.cancelled.description == "The export was cancelled.")
        #expect(ExportError.names(of: .animation) == "an animation")
        #expect(MP4Options.defaults.quality == 75 && APNGOptions.defaults.common.loop == .document && AnimatedGIFOptions.defaults.colors == 256)
    }

    /// WEB-020's budget: a 300-frame export at 1920 × 1080 (perf run only).
    @Test(.enabled(if: PerfBudget.isMeasuring, "the perf run only: release with WT_PERF=1"))
    func threeHundredFrameMovie() async throws {
        var items: [DisplayItem] = []
        var spans: [LayerSpan] = []
        var layers: [AnimationLayer] = []
        for index in 0..<300 {
            let id = NodeID(counter: UInt64(100 + index), replica: 9)
            items.append(Corpus.path(Corpus.ellipse(Double(index) * 5, 100 + 200 * sin(Double(index) / 20), 200, 200), [Corpus.fill(.solid(Self.colors[index % 3]))]))
            spans.append(LayerSpan(layer: LayerRendering(id: id), range: index..<(index + 1)))
            layers.append(AnimationLayer(id: id))
        }
        let list = DisplayList(canvas: "movie", items: items, layers: spans)
        let animation = ExportAnimation(frames: FrameComposer.frames(source: .layers, layers: layers, pages: []), fps: 30, background: .white, displayList: list, area: Rect(x: 0, y: 0, width: 1920, height: 1080))
        let scene = ExportScene(pages: [], animation: animation)
        let progress = ExportProgress()
        let start = ContinuousClock.now
        let summary = try await AnimationExporter(format: .mp4H264).export(scene: scene, options: MP4Options(common: AnimationCommonOptions(antiAliasing: 2)), to: ExportDestination(url: Self.url("budget", .mp4H264)), progress: progress)
        let elapsed = ContinuousClock.now - start
        let facts = try await Self.movieFacts(summary.files[0])
        #expect(abs(facts.duration - 10) < 0.001 && facts.frames == 300 && facts.size == CGSize(width: 1920, height: 1080))
        PerfBudget.expect(elapsed, within: .seconds(60), "300 frames at 1920 × 1080, H.264")
    }
}
