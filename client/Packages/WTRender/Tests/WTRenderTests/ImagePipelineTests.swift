import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WTRender

/// Fixture images written with ImageIO into a per-test temporary directory.
enum ImageFixtures {
    static func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WTRenderImages-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!

    /// An RGBA image whose pixels come from `pixel(x, y)` (premultiplied RGBA bytes).
    static func rgba(width: Int, height: Int, pixel: (Int, Int) -> [UInt8]) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                for channel in 0..<4 {
                    data[y * width * 4 + x * 4 + channel] = value[channel]
                }
            }
        }
        return context.makeImage()!
    }

    /// An opaque RGB image, no alpha channel.
    static func opaque(width: Int, height: Int, red: CGFloat = 0.2, green: CGFloat = 0.5, blue: CGFloat = 0.8) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return context.makeImage()!
    }

    /// An 8-bit gray image (no alpha) whose levels come from `level(x, y)`.
    static func grayImage(width: Int, height: Int, level: (Int, Int) -> UInt8) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                data[y * width + x] = level(x, y)
            }
        }
        return context.makeImage()!
    }

    @discardableResult
    static func write(_ image: CGImage, to url: URL, type: UTType = .png) -> URL {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return url
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> RGBA8 {
        BitmapSurface(drawing: image)!.pixel(x: x, y: y)
    }
}

@Suite struct GrayRampTests {
    @Test func presets() {
        #expect(GrayRamp.normal.lut() == (0...255).map { UInt8($0) })
        let inverted = GrayRamp(preset: .inverted).lut()
        #expect(inverted[0] == 255 && inverted[255] == 0)
        let lighten = GrayRamp(preset: .lighten).lut()
        #expect(lighten[0] == 128 && lighten[255] == 255)
        let darken = GrayRamp(preset: .darken).lut()
        #expect(darken[0] == 0 && darken[255] == 127)
    }

    @Test func customReadsNormalWhenFlat() {
        #expect(GrayRamp(preset: .custom).effectivePreset == .normal)
        #expect(GrayRamp(preset: .custom).lut() == GrayRamp.normal.lut())
        #expect(GrayRamp(preset: .custom, lightness: 10).effectivePreset == .custom)
        #expect(GrayRamp(preset: .inverted, lightness: 0).effectivePreset == .inverted)
    }

    @Test func customLightnessAndContrast() {
        let lighter = GrayRamp(preset: .custom, lightness: 100).lut()
        #expect(lighter[128] == 255 && lighter[0] == 255)
        let darker = GrayRamp(preset: .custom, lightness: -50).lut()
        #expect(darker[255] == 128 && darker[0] == 0)
        let flat = GrayRamp(preset: .custom, contrast: -100).lut()
        #expect(Set(flat) == [128])
        let steep = GrayRamp(preset: .custom, contrast: 100).lut()
        #expect(steep[0] == 0 && steep[120] == 0 && steep[135] == 255 && steep[255] == 255)
        let clamped = GrayRamp(preset: .custom, lightness: 400, contrast: -400).lut()
        #expect(Set(clamped) == [255])
        let mild = GrayRamp(preset: .custom, contrast: 50).lut()
        #expect(zip(mild, mild.dropFirst()).allSatisfy { $0 <= $1 }, "monotone")
    }
}

@Suite struct ImageTreatmentTests {
    /// Two pixels: black, white.
    let grayPair = ImageFixtures.grayImage(width: 2, height: 1) { x, _ in x == 0 ? 0 : 255 }

    @Test func readTimeRules() {
        let color = ImageTreatment(mode: .rgb, ramp: GrayRamp(preset: .inverted), tint: SIMD3(1, 0, 0), transparentBackground: true)
        #expect(color == ImageTreatment(mode: .rgb))
        #expect(!color.treatsGray)
        #expect(ImageMode.bilevel.isGray && ImageMode.grayscale.isGray)
        #expect(!ImageMode.indexed.isGray && !ImageMode.cmyk.isGray && !ImageMode.rgb.isGray)
        #expect(ImageTreatment(hasAlpha: true).usesAlpha)
        #expect(!ImageTreatment(displayAlpha: false, hasAlpha: true).usesAlpha)
        #expect(!ImageTreatment(displayAlpha: true, hasAlpha: false).usesAlpha)
        #expect(ImageTreatment(mode: .grayscale, ramp: GrayRamp(preset: .custom)).isIdentity, "a flat custom ramp is normal")
        #expect(!ImageTreatment(displayAlpha: false, hasAlpha: true).isIdentity)
    }

    @Test func identityReturnsTheImage() {
        let treatment = ImageTreatment(mode: .grayscale)
        #expect(treatment.apply(to: grayPair) === grayPair)
        let opaque = ImageFixtures.opaque(width: 4, height: 4)
        #expect(ImageTreatment(mode: .rgb, hasAlpha: false).apply(to: opaque) === opaque)
    }

    @Test func tintColorsTheDarkPixels() throws {
        for mode in [ImageMode.bilevel, .grayscale] {
            let image = try #require(ImageTreatment(mode: mode, tint: SIMD3(1, 0, 0)).apply(to: grayPair))
            #expect(ImageFixtures.pixel(image, x: 0, y: 0) == RGBA8(red: 255, green: 0, blue: 0, alpha: 255))
            #expect(ImageFixtures.pixel(image, x: 1, y: 0) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
        }
        let half = ImageFixtures.grayImage(width: 1, height: 1) { _, _ in 128 }
        let blended = try #require(ImageTreatment(mode: .grayscale, tint: SIMD3(0, 0, 1)).apply(to: half))
        // g = 128/255: 128 grey plus (1 - g) of blue.
        #expect(ImageFixtures.pixel(blended, x: 0, y: 0) == RGBA8(red: 128, green: 128, blue: 255, alpha: 255))
    }

    @Test func rampRemapsLevels() throws {
        let image = try #require(ImageTreatment(mode: .grayscale, ramp: GrayRamp(preset: .inverted)).apply(to: grayPair))
        #expect(ImageFixtures.pixel(image, x: 0, y: 0) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
        #expect(ImageFixtures.pixel(image, x: 1, y: 0) == RGBA8(red: 0, green: 0, blue: 0, alpha: 255))
    }

    @Test func transparentTurnsLuminanceIntoAlpha() throws {
        let plain = try #require(ImageTreatment(mode: .bilevel, transparentBackground: true).apply(to: grayPair))
        #expect(ImageFixtures.pixel(plain, x: 0, y: 0) == RGBA8(red: 0, green: 0, blue: 0, alpha: 255))
        #expect(ImageFixtures.pixel(plain, x: 1, y: 0) == RGBA8(red: 0, green: 0, blue: 0, alpha: 0))
        let half = ImageFixtures.grayImage(width: 1, height: 1) { _, _ in 128 }
        let tinted = try #require(ImageTreatment(mode: .grayscale, tint: SIMD3(0, 0, 1), transparentBackground: true).apply(to: half))
        #expect(ImageFixtures.pixel(tinted, x: 0, y: 0) == RGBA8(red: 0, green: 0, blue: 127, alpha: 127))
    }

    @Test func grayAlphaIsShownOrDropped() throws {
        // A half-transparent black pixel and an opaque white one, read as a grayscale image.
        let image = ImageFixtures.rgba(width: 2, height: 1) { x, _ in x == 0 ? [0, 0, 0, 128] : [255, 255, 255, 255] }
        let shown = try #require(ImageTreatment(mode: .grayscale, tint: SIMD3(1, 0, 0), displayAlpha: true, hasAlpha: true).apply(to: image))
        #expect(ImageFixtures.pixel(shown, x: 0, y: 0).alpha == 128)
        #expect(ImageFixtures.pixel(shown, x: 1, y: 0) == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
        let dropped = try #require(ImageTreatment(mode: .grayscale, tint: SIMD3(1, 0, 0), displayAlpha: false, hasAlpha: true).apply(to: image))
        #expect(ImageFixtures.pixel(dropped, x: 0, y: 0).alpha == 255)
    }

    @Test func colorAlphaDroppedCompositesOverWhite() throws {
        let image = ImageFixtures.rgba(width: 1, height: 1) { _, _ in [128, 0, 0, 128] }
        let dropped = try #require(ImageTreatment(mode: .rgb, displayAlpha: false, hasAlpha: true).apply(to: image))
        let pixel = ImageFixtures.pixel(dropped, x: 0, y: 0)
        #expect(pixel.alpha == 255 && pixel.red >= 254 && abs(Int(pixel.green) - 127) <= 1 && pixel.green == pixel.blue)
        #expect(ImageTreatment(mode: .rgb, displayAlpha: true, hasAlpha: true).apply(to: image) === image)
    }

    @Test func everyModeAndSettingCombination() throws {
        let gray = ImageFixtures.grayImage(width: 4, height: 1) { x, _ in UInt8(x * 85) }
        for mode in ImageMode.allCases {
            for tint in [nil, SIMD3<Double>(0.2, 0.4, 0.6)] {
                for transparent in [false, true] {
                    for alpha in [false, true] {
                        let treatment = ImageTreatment(mode: mode, tint: tint, transparentBackground: transparent, displayAlpha: alpha, hasAlpha: alpha)
                        let image = try #require(treatment.apply(to: gray))
                        #expect(image.width == 4 && image.height == 1)
                        let dark = ImageFixtures.pixel(image, x: 0, y: 0)
                        let light = ImageFixtures.pixel(image, x: 3, y: 0)
                        if mode.isGray && transparent {
                            #expect(light.alpha == 0 && dark.alpha == 255)
                        } else {
                            #expect(light == RGBA8(red: 255, green: 255, blue: 255, alpha: 255))
                        }
                        if mode.isGray, let tint {
                            #expect(dark.red == ImageTreatment.byte(tint.x) && dark.blue == ImageTreatment.byte(tint.z))
                        } else {
                            #expect(dark.red == 0 && dark.green == 0 && dark.blue == 0)
                        }
                    }
                }
            }
        }
    }

    @Test func unallocatableOutputIsNil() {
        let treatment = ImageTreatment(mode: .grayscale, ramp: GrayRamp(preset: .inverted))
        // Core Graphics refuses an RGBA context in a CMYK space.
        #expect(treatment.apply(to: grayPair, space: CGColorSpace(name: CGColorSpace.genericCMYK)!) == nil)
    }
}

@Suite struct ImageMemoryCacheTests {
    let image = ImageFixtures.opaque(width: 16, height: 16)  // 1 KiB

    func key(_ hash: String, _ level: Int = 0) -> ImageCacheKey {
        ImageCacheKey(hash: hash, level: level, treatment: ImageTreatment())
    }

    @Test func evictsLeastRecentlyUsedBeyondBudget() {
        let cost = ImageMemoryCache.cost(of: image)
        #expect(cost == 1024)
        let cache = ImageMemoryCache(budget: cost * 2)
        cache.insert(image, for: key("a"))
        cache.insert(image, for: key("b"))
        #expect(cache.bytesInUse == cost * 2 && cache.count == 2)
        #expect(cache.image(for: key("a")) != nil, "touching a makes b the oldest")
        cache.insert(image, for: key("c"))
        #expect(cache.image(for: key("b")) == nil)
        #expect(cache.image(for: key("a")) != nil && cache.image(for: key("c")) != nil)
        cache.insert(image, for: key("c"))
        #expect(cache.bytesInUse == cost * 2, "replacing a key does not double count")
    }

    @Test func oversizedImageIsHeldAlone() {
        let cache = ImageMemoryCache(budget: 10)
        cache.insert(image, for: key("a"))
        cache.insert(image, for: key("b"))
        #expect(cache.count == 1 && cache.image(for: key("b")) != nil)
        #expect(ImageMemoryCache(budget: -5).budget == 0)
    }

    @Test func removalAndFallbackLevels() {
        let cache = ImageMemoryCache()
        #expect(cache.anyLevel(hash: "a", treatment: ImageTreatment()) == nil)
        cache.insert(image, for: key("a", 2))
        cache.insert(image, for: key("a", 1))
        cache.insert(image, for: key("b", 0))
        #expect(cache.anyLevel(hash: "a", treatment: ImageTreatment())?.level == 1)
        #expect(cache.anyLevel(hash: "a", treatment: ImageTreatment(mode: .grayscale, tint: SIMD3(1, 0, 0))) == nil)
        cache.removeAll(hash: "a")
        #expect(cache.count == 1 && cache.bytesInUse == 1024)
        cache.removeAll()
        #expect(cache.count == 0 && cache.bytesInUse == 0)
    }
}

@Suite struct ImagePyramidTests {
    @Test func levelsHalveDownTo512() {
        let levels = ImagePyramid.levels(width: 3000, height: 2000, reduced: true)
        #expect(levels.map(\.index) == [0, 1, 2])
        #expect(levels[1].width == 1500 && levels[1].height == 1000 && levels[1].scale == 0.5)
        #expect(levels[2].width == 750 && levels[2].height == 500 && levels[2].scale == 0.25)
        #expect(ImagePyramid.levels(width: 3000, height: 2000, reduced: false).count == 1)
        let odd = ImagePyramid.levels(width: 1025, height: 3, reduced: true)
        #expect(odd.map(\.width) == [1025, 513] && odd[1].height == 2)
    }

    @Test func levelChoiceAndDiskCache() throws {
        let directory = ImageFixtures.directory()
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let url = ImageFixtures.write(ImageFixtures.opaque(width: 3000, height: 2000), to: directory.appendingPathComponent("big.png"))
        let pyramid = try #require(ImagePyramid(url: url, hash: "abc", cacheDirectory: cache))
        #expect(pyramid.pixelWidth == 3000 && pyramid.pixelHeight == 2000 && !pyramid.isTiled && pyramid.levels.count == 3)
        #expect(pyramid.level(forScale: 2).index == 0)
        #expect(pyramid.level(forScale: 1).index == 0)
        #expect(pyramid.level(forScale: 0.3).index == 1)
        #expect(pyramid.level(forScale: 0.25).index == 2)
        #expect(pyramid.level(forScale: 0.01).index == 2)
        let full = try #require(pyramid.image(level: 0))
        #expect(full.width == 3000)
        let reduced = try #require(pyramid.image(level: 2))
        #expect(reduced.width == 750 && reduced.height == 500)
        #expect(pyramid.image(level: 3) == nil && pyramid.image(level: -1) == nil)
        let file = try #require(pyramid.cacheURL(for: pyramid.levels[2]))
        #expect(FileManager.default.fileExists(atPath: file.path))

        // A second pyramid (a relaunch) reads the level from disk: replace the file with a
        // recognisably different picture of the same size and it comes back.
        ImageFixtures.write(ImageFixtures.opaque(width: 750, height: 500, red: 1, green: 0, blue: 0), to: file)
        let relaunched = try #require(ImagePyramid(url: url, hash: "abc", cacheDirectory: cache))
        let fromDisk = try #require(relaunched.image(level: 2))
        #expect(ImageFixtures.pixel(fromDisk, x: 700, y: 10).red == 255)
        // A cached file of the wrong size is regenerated.
        ImageFixtures.write(ImageFixtures.opaque(width: 10, height: 10, red: 1, green: 0, blue: 0), to: file)
        let regenerated = try #require(relaunched.image(level: 2))
        #expect(regenerated.width == 750 && ImageFixtures.pixel(regenerated, x: 700, y: 10).red < 255)
        // Another hash is another directory; purge removes one hash's levels.
        let other = try #require(ImagePyramid(url: url, hash: "def", cacheDirectory: cache))
        #expect(other.cacheURL(for: other.levels[2]) != file)
        ImagePyramid.purge(hash: "abc", in: cache)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func smallImagesHaveOneLevelAndNoCache() throws {
        let directory = ImageFixtures.directory()
        let url = ImageFixtures.write(ImageFixtures.opaque(width: 400, height: 300), to: directory.appendingPathComponent("small.png"))
        let pyramid = try #require(ImagePyramid(url: url, hash: "s"))
        #expect(pyramid.levels.count == 1 && pyramid.level(forScale: 0.01).index == 0)
        #expect(pyramid.cacheURL(for: pyramid.levels[0]) == nil)
        #expect(pyramid.image(level: 0)?.width == 400)
        // Reduced levels without a cache directory are generated every time.
        let forced = try #require(ImagePyramid(url: url, hash: "s", pyramidThreshold: 0))
        #expect(forced.levels.count == 1, "400 px is already under 512")
    }

    @Test func unreadableFilesHaveNoPyramid() throws {
        let directory = ImageFixtures.directory()
        let url = directory.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: url)
        #expect(ImagePyramid(url: url, hash: "x") == nil)
        #expect(ImagePyramid(url: directory.appendingPathComponent("absent.png"), hash: "x") == nil)
    }

    @Test func unwritableCacheStillServesLevels() throws {
        let directory = ImageFixtures.directory()
        let blocker = directory.appendingPathComponent("blocker")
        try Data().write(to: blocker)  // a file where the cache directory should be
        let url = ImageFixtures.write(ImageFixtures.opaque(width: 2400, height: 1800), to: directory.appendingPathComponent("big.png"))
        let pyramid = try #require(ImagePyramid(url: url, hash: "h", cacheDirectory: blocker))
        #expect(pyramid.image(level: 1)?.width == 1200)
    }

    @Test(arguments: [UTType.jpeg, .png])
    func tiledSourcesSubsampleOrThumbnail(type: UTType) throws {
        let directory = ImageFixtures.directory()
        let url = ImageFixtures.write(ImageFixtures.opaque(width: 2400, height: 1600), to: directory.appendingPathComponent("big"), type: type)
        let pyramid = try #require(ImagePyramid(url: url, hash: "t", cacheDirectory: nil, pyramidThreshold: 100_000, tiledThreshold: 1_000_000))
        #expect(pyramid.isTiled)
        #expect(pyramid.image(level: 0) == nil, "the full level of a tiled image is never decoded whole")
        for level in pyramid.levels.dropFirst() {
            let image = try #require(pyramid.image(level: level.index))
            #expect(abs(image.width - level.width) <= 1 && abs(image.height - level.height) <= 1)
        }
        let tile = try #require(pyramid.fullLevelTile(rect: CGRect(x: 2300, y: 1500, width: 256, height: 256)))
        #expect(tile.width == 100 && tile.height == 100, "clipped to the image")
        let corner = ImageFixtures.pixel(try #require(pyramid.fullLevelTile(rect: CGRect(x: 0, y: 1500, width: 10, height: 10))), x: 5, y: 5)
        #expect(corner.red > 240, "the white quarter is at the bottom-left in image space")
        #expect(pyramid.fullLevelTile(rect: CGRect(x: 5000, y: 0, width: 10, height: 10)) == nil)
    }

    @Test func grayTilesStayGray() throws {
        let directory = ImageFixtures.directory()
        let url = ImageFixtures.write(ImageFixtures.grayImage(width: 64, height: 64) { x, _ in UInt8(x * 4) }, to: directory.appendingPathComponent("gray.png"))
        let pyramid = try #require(ImagePyramid(url: url, hash: "g"))
        let tile = try #require(pyramid.fullLevelTile(rect: CGRect(x: 10, y: 0, width: 4, height: 4)))
        #expect(tile.colorSpace?.model == .monochrome && tile.width == 4)
    }

    @Test func pyramidGenerationTiming() throws {
        let directory = ImageFixtures.directory()
        let url = ImageFixtures.write(ImageFixtures.opaque(width: 4000, height: 4000), to: directory.appendingPathComponent("perf.jpg"), type: .jpeg)
        let pyramid = try #require(ImagePyramid(url: url, hash: "p", cacheDirectory: directory.appendingPathComponent("cache")))
        let start = ContinuousClock.now
        for level in pyramid.levels.dropFirst() {
            _ = pyramid.image(level: level.index)
        }
        let elapsed = ContinuousClock.now - start
        print("PERF pyramid: \(pyramid.levels.count - 1) levels of a 16 MP JPEG in \(elapsed) (IMG-018 budget: 200 MP in 4 s on M1)")
        #expect(pyramid.levels.count == 3)
    }
}

@Suite struct ImageStoreTests {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func record(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    struct Fixture {
        let directory: URL
        let store: ImageStore
        let recorder = Recorder()

        init(files: [String: CGImage] = [:], corrupt: [String] = [], pyramidThreshold: Int = ImagePyramid.defaultPyramidThreshold, tiledThreshold: Int = ImagePyramid.defaultTiledThreshold) {
            let directory = ImageFixtures.directory()
            for (id, image) in files {
                ImageFixtures.write(image, to: directory.appendingPathComponent(id))
            }
            for id in corrupt {
                try! Data("junk".utf8).write(to: directory.appendingPathComponent(id))
            }
            self.directory = directory
            store = ImageStore(
                blobURL: { id in
                    let url = directory.appendingPathComponent(id)
                    return FileManager.default.fileExists(atPath: url.path) ? url : nil
                },
                cacheDirectory: directory.appendingPathComponent("cache"),
                pyramidThreshold: pyramidThreshold,
                tiledThreshold: tiledThreshold
            )
            let recorder = recorder
            store.onReady = { recorder.record($0) }
        }
    }

    @Test func missingAndDownloading() {
        let fixture = Fixture()
        let store = fixture.store
        #expect(store.state(of: "a") == .missing)
        #expect(store.image(for: "a", treatment: ImageTreatment(), scale: 1) == nil)
        #expect(store.imageBlocking(for: "a", treatment: ImageTreatment(), scale: 1) == nil)
        #expect(store.fullResolutionTile(for: "a", rect: CGRect(x: 0, y: 0, width: 1, height: 1), treatment: ImageTreatment()) == nil)
        store.forget(assetID: "a")
        store.setDownloading(assetID: "a", progress: 1.5)
        #expect(store.state(of: "a") == .downloading(progress: 1))
        store.setDownloading(assetID: "a", progress: 0.25)
        #expect(store.state(of: "a") == .downloading(progress: 0.25))
        #expect(store.pyramid(for: "a") == nil)
        #expect(store.onReady != nil)
    }

    @Test func decodesInTheBackgroundAndNotifies() throws {
        let fixture = Fixture(files: ["big": ImageFixtures.opaque(width: 3000, height: 2000)])
        let store = fixture.store
        let treatment = ImageTreatment()
        #expect(store.image(for: "big", treatment: treatment, scale: 0.3) == nil, "the first request only starts the decode")
        #expect(store.image(for: "big", treatment: treatment, scale: 0.3) == nil, "while opening, nothing more is scheduled")
        store.waitUntilIdle()
        #expect(store.state(of: "big") == .ready)
        #expect(fixture.recorder.all == ["big"])
        let level1 = try #require(store.image(for: "big", treatment: treatment, scale: 0.3))
        #expect(level1.width == 1500)
        // Another scale: the level in memory stands in while the wanted one decodes.
        let standIn = try #require(store.image(for: "big", treatment: treatment, scale: 0.2))
        #expect(standIn.width == 1500)
        _ = store.image(for: "big", treatment: treatment, scale: 0.2)  // already pending
        store.waitUntilIdle()
        #expect(store.image(for: "big", treatment: treatment, scale: 0.2)?.width == 750)
        #expect(store.pyramid(for: "big")?.levels.count == 3)
        // Setting progress on a ready asset changes nothing.
        store.setDownloading(assetID: "big", progress: 0.5)
        #expect(store.state(of: "big") == .ready)
        store.forget(assetID: "big")
        #expect(store.state(of: "big") == .missing && store.cache.count == 0)
    }

    @Test func blobArrivalDecodesTheCoarsestLevel() throws {
        let fixture = Fixture()
        let store = fixture.store
        store.blobArrived(assetID: "unseen")
        store.waitUntilIdle()
        #expect(store.state(of: "unseen") == .failed)
        store.setDownloading(assetID: "late", progress: 0.5)
        store.blobArrived(assetID: "late")  // no file yet: fails
        store.waitUntilIdle()
        #expect(store.state(of: "late") == .failed)
        #expect(store.image(for: "late", treatment: ImageTreatment(), scale: 1) == nil, "a failed asset is not retried by drawing")
        ImageFixtures.write(ImageFixtures.opaque(width: 3000, height: 2000), to: fixture.directory.appendingPathComponent("late"))
        store.blobArrived(assetID: "late")
        store.blobArrived(assetID: "late")  // already opening
        store.waitUntilIdle()
        #expect(store.state(of: "late") == .ready)
        #expect(store.cache.anyLevel(hash: "late", treatment: ImageTreatment())?.level == 2)
        store.blobArrived(assetID: "late")  // ready: nothing to do
        store.waitUntilIdle()
        #expect(fixture.recorder.all == ["unseen", "late", "late"])
    }

    @Test func corruptBlobsFail() {
        let fixture = Fixture(corrupt: ["bad"])
        let store = fixture.store
        #expect(store.image(for: "bad", treatment: ImageTreatment(), scale: 1) == nil)
        store.waitUntilIdle()
        #expect(store.state(of: "bad") == .failed)
        #expect(fixture.recorder.all == ["bad"])
        #expect(store.imageBlocking(for: "bad", treatment: ImageTreatment(), scale: 1) == nil)
    }

    @Test func undecodableLevelFails() throws {
        // A tiled pyramid with no reduced level cannot draw level 0.
        let fixture = Fixture(files: ["t": ImageFixtures.opaque(width: 300, height: 300)], tiledThreshold: 10)
        let store = fixture.store
        #expect(store.imageBlocking(for: "t", treatment: ImageTreatment(), scale: 1) == nil)
        #expect(store.state(of: "t") == .failed)
        #expect(store.fullResolutionTile(for: "t", rect: CGRect(x: 0, y: 0, width: 16, height: 16), treatment: ImageTreatment())?.width == 16)
    }

    @Test func blockingDecodeAndTreatment() throws {
        let gray = ImageFixtures.grayImage(width: 8, height: 8) { x, _ in x < 4 ? 0 : 255 }
        let fixture = Fixture(files: ["g": gray])
        let store = fixture.store
        let treatment = ImageTreatment(mode: .grayscale, tint: SIMD3(0, 1, 0))
        let image = try #require(store.imageBlocking(for: "g", treatment: treatment, scale: 1))
        #expect(ImageFixtures.pixel(image, x: 0, y: 0) == RGBA8(red: 0, green: 255, blue: 0, alpha: 255))
        #expect(store.imageBlocking(for: "g", treatment: treatment, scale: 1) === image, "served from memory")
        #expect(store.image(for: "g", treatment: treatment, scale: 1) === image)
        #expect(store.state(of: "g") == .ready)
        let tile = try #require(store.fullResolutionTile(for: "g", rect: CGRect(x: 0, y: 0, width: 2, height: 2), treatment: treatment))
        #expect(ImageFixtures.pixel(tile, x: 0, y: 0) == RGBA8(red: 0, green: 255, blue: 0, alpha: 255))
        #expect(fixture.recorder.all.isEmpty, "blocking decodes do not notify")
    }

    @Test func tiledAssetsDrawTheirFinestReducedLevel() throws {
        let fixture = Fixture(files: ["huge": ImageFixtures.opaque(width: 2400, height: 1600)], pyramidThreshold: 100_000, tiledThreshold: 1_000_000)
        let store = fixture.store
        let image = try #require(store.imageBlocking(for: "huge", treatment: ImageTreatment(), scale: 4))
        #expect(image.width == 1200)
        let pyramid = try #require(store.pyramid(for: "huge"))
        #expect(ImageStore.levelIndex(in: pyramid, scale: 4) == 1)
        #expect(ImageStore.levelIndex(in: pyramid, scale: 0.1) == pyramid.levels.count - 1)
    }

    @Test func concurrentRequestsSettle() {
        let fixture = Fixture(files: ["c": ImageFixtures.opaque(width: 3000, height: 2000)])
        let store = fixture.store
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            _ = store.image(for: "c", treatment: ImageTreatment(), scale: [1, 0.5, 0.25][index % 3])
        }
        store.waitUntilIdle()
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            _ = store.image(for: "c", treatment: ImageTreatment(), scale: [1, 0.5, 0.25][index % 3])
        }
        store.waitUntilIdle()
        #expect(store.state(of: "c") == .ready)
        #expect(store.cache.count == 3)
    }
}
