@preconcurrency import ColorSync
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WTGeometry
@testable import WTRender

/// Two synthetic presses (see `ICCProfileBuilder`), registered with the shared registry once.
enum TestPresses {
    static let lightData = ICCProfileBuilder.cmykProfile(name: "Test Press Light", dotGain: 1)
    static let heavyData = ICCProfileBuilder.cmykProfile(name: "Test Press Heavy", dotGain: 1.6)
    static let light = WTColor.ProfileRegistry.shared.register(iccData: lightData)!
    static let heavy = WTColor.ProfileRegistry.shared.register(iccData: heavyData)!
}

/// Reads a pixel of an image in the image's own space (no colour matching).
func rawPixel(_ image: CGImage, x: Int, y: Int) -> RGBA8 {
    let surface = BitmapSurface(width: image.width, height: image.height, colorSpace: image.colorSpace!)!
    surface.context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return surface.pixel(x: x, y: y)
}

/// CMS-002: the profile registry.
@Suite struct ProfileRegistryTests {
    let registry = WTColor.ProfileRegistry.shared

    @Test func bundledProfilesRoundTripThroughTheirColourSpaces() throws {
        #expect(registry.bundledProfiles.map(\.bundledID) == WTColor.ProfileRegistry.bundledIDs)
        for profile in registry.bundledProfiles {
            let space = try #require(registry.colorSpace(for: profile))
            let back = try #require(registry.register(colorSpace: space))
            #expect(back == profile, "\(profile)")
            #expect(back.sha256.count == 32 && back.isBundled)
            #expect(profile.description.contains(profile.bundledID))
        }
        #expect(registry.sRGB.space == .rgb && registry.displayP3.space == .rgb)
        #expect(registry.genericGray.space == .gray && registry.defaultCMYK.space == .cmyk)
        #expect(registry.bundled("nonsense") == nil)
        #expect(WTColor.ProfileSpace.gray.channelCount == 1 && WTColor.ProfileSpace.lab.channelCount == 3)
    }

    @Test func anEmbeddedCameraSRGBProfileIsRecognizedByHash() throws {
        let url = ImageFixtures.directory().appendingPathComponent("camera.jpg")
        ImageFixtures.write(ImageFixtures.opaque(width: 8, height: 8), to: url, type: .jpeg)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = try #require(image.colorSpace?.copyICCData() as Data?)
        #expect(registry.register(iccData: data)?.bundledID == "srgb")
        // The same bytes saved with another rendering intent in the header still match.
        var bytes = [UInt8](data)
        bytes[67] = 1
        #expect(registry.register(iccData: Data(bytes))?.bundledID == "srgb")
    }

    @Test func anUnknownProfileHasNoBundledIDAndTheRightSpace() throws {
        let ref = TestPresses.heavy
        #expect(ref.bundledID.isEmpty && !ref.isBundled && ref.space == .cmyk)
        #expect(ref.name == "Test Press Heavy")
        #expect(ref.hexHash.count == 64 && ref.description.contains(ref.hexHash.prefix(12)))
        #expect(ref.sha256 == WTColor.ProfileRegistry.hash(TestPresses.heavyData))
        #expect(registry.colorSpace(for: ref)?.model == .cmyk)
        #expect(registry.iccData(for: ref) == TestPresses.heavyData)
        #expect(WTColor.ProfileRegistry.makeRef(iccData: Data([1, 2, 3])) == nil, "too short")
        var garbage = TestPresses.heavyData
        garbage.replaceSubrange(16..<20, with: "XYZ ".data(using: .ascii)!)
        #expect(WTColor.ProfileRegistry.makeRef(iccData: garbage) == nil, "a space we do not offer")
        #expect(registry.register(iccData: Data(count: 200)) == nil)
    }

    @Test func customProfilesComeFromBlobsAndFallBackWhilePending() throws {
        let local = WTColor.ProfileRegistry()
        let data = ICCProfileBuilder.cmykProfile(name: "Blob Press", dotGain: 1.3)
        let ref = try #require(WTColor.ProfileRegistry.makeRef(iccData: data))
        // No blob yet: the bundled default of the space renders, pending.
        var resolved = local.resolve(ref, default: local.defaultCMYK)
        #expect(resolved.profile == local.defaultCMYK && resolved.pending)
        #expect(local.iccData(for: ref) == nil && local.colorSpace(for: ref) == nil)
        // A blob with the wrong bytes is refused.
        local.blobLoader = { _ in Data(count: 300) }
        #expect(local.iccData(for: ref) == nil)
        local.blobLoader = { hash in hash == ref.sha256 ? data : nil }
        #expect(local.blobLoader != nil)
        resolved = local.resolve(ref, default: local.defaultCMYK)
        #expect(resolved.profile == ref && !resolved.pending && resolved.colorSpace.model == .cmyk)
        // Unset reads as the default.
        #expect(local.resolve(nil, default: local.sRGB).profile == local.sRGB)
        #expect(!local.resolve(nil, default: local.sRGB).pending)
        #expect(local.fallback(for: .gray) == local.genericGray && local.fallback(for: .lab) == local.sRGB)
    }

    @Test func installedProfilesExcludeLinksAndAbstractsAndAreFast() {
        let start = Date()
        let all = registry.installedProfiles()
        let elapsed = Date().timeIntervalSince(start)
        #expect(!all.isEmpty && all.allSatisfy { ["mntr", "prtr", "scnr", "spac"].contains($0.profileClass) })
        #expect(!all.contains { $0.name == "Web Safe Colors" }, "named-colour profiles are not offered")
        let cmyk = registry.installedProfiles(space: .cmyk)
        #expect(cmyk.allSatisfy { $0.space == .cmyk } && !cmyk.isEmpty)
        print("PERF installed profiles: \(all.count) in \(elapsed) s (CMS-002 budget: 500 in 100 ms)")
        #expect(elapsed < 1)
        #expect(WTColor.ProfileRegistry.installedProfile(from: nil) == nil)
        let link: NSDictionary = [kColorSyncProfileClass.takeUnretainedValue(): "link"]
        #expect(WTColor.ProfileRegistry.installedProfile(from: link) == nil)
        let unnamed: NSDictionary = [
            kColorSyncProfileClass.takeUnretainedValue(): "prtr",
            kColorSyncProfileColorSpace.takeUnretainedValue(): "CMYK",
            kColorSyncProfileURL.takeUnretainedValue(): URL(fileURLWithPath: "/tmp/Some Press.icc"),
        ]
        #expect(WTColor.ProfileRegistry.installedProfile(from: unnamed)?.name == "Some Press")
    }
}

/// CMS-003: the conversion service.
@Suite struct ConverterTests {
    let converter = WTColor.Converter.shared
    var registry: WTColor.ProfileRegistry { converter.registry }

    static let table: [Color] = (0..<1000).map { index in
        let t = Double(index) / 999
        switch index % 5 {
        case 0: return Color(red: t, green: 1 - t, blue: (t * 7).truncatingRemainder(dividingBy: 1))
        case 1: return Color(displayP3Red: 1 - t, green: t, blue: 0.5)
        case 2: return Color(labL: 100 * t, a: 80 * (t - 0.5), b: -60 * (t - 0.5))
        case 3: return Color(oklchL: 0.2 + 0.7 * t, chroma: 0.15, hue: 360 * t)
        default: return Color(cyan: t, magenta: 1 - t, yellow: t * t, black: 0.2)
        }
    }

    @Test func conversionsAreDeterministic() throws {
        let fresh = WTColor.Converter()
        for color in Self.table {
            let once = try #require(converter.convert(color, to: registry.defaultCMYK))
            let twice = try #require(fresh.convert(color, to: registry.defaultCMYK))
            #expect(once == twice)
            #expect(once.count == 4 && once.allSatisfy { (0...1).contains($0) })
        }
    }

    @Test func transformsAreCachedAndBatchesAreFast() throws {
        let local = WTColor.Converter()
        _ = local.transform(from: local.registry.sRGB, to: local.registry.defaultCMYK, blackPointCompensation: true)
        _ = local.transform(from: local.registry.sRGB, to: local.registry.defaultCMYK, blackPointCompensation: true)
        #expect(local.buildCount == 1)
        var values: [SIMD4<Double>] = []
        values.reserveCapacity(100_000)
        for index in 0..<100_000 {
            let r = Double(index % 97) / 96
            let g = Double(index % 89) / 88
            let b = Double(index % 83) / 82
            values.append(SIMD4(r, g, b, 0))
        }
        let start = Date()
        let converted = try #require(local.convert(values, space: .sRGB, to: local.registry.defaultCMYK))
        let elapsed = Date().timeIntervalSince(start)
        #expect(converted.count == 100_000 && converted[0].count == 4)
        print("PERF 100,000 colours through a cached transform: \(elapsed) s (CMS-003 budget: 50 ms on M1, release)")
        #if !DEBUG
        #expect(elapsed < 0.05)
        #endif
        #expect(local.buildCount == 1, "the batch reused the cached transform")
        // Batches of the other entry kinds.
        let lab = try #require(local.convert([SIMD4(50, 20, -30, 0)], space: .oklab, to: local.registry.sRGB))
        #expect(lab[0].count == 3)
        let cmyk = try #require(local.convert([SIMD4(1, 0, 0, 0)], space: .cmyk, to: local.registry.sRGB))
        #expect(cmyk[0][0] < 0.1 && cmyk[0][2] > 0.8)
        #expect(local.convert([], space: .sRGB, to: local.registry.sRGB) == [])
        #expect(local.transform([WTColor.ChainStep(profile: local.registry.sRGB)]) == nil, "a chain needs two steps")
    }

    @Test func labEntersThroughTheConnectionSpace() throws {
        let lab = try #require(converter.convert(Color(labL: 50, a: 20, b: -30), to: registry.sRGB, blackPointCompensation: false))
        // Core Graphics' own Lab → sRGB conversion of the same colour.
        #expect(abs(lab[0] - 0.521) < 0.003 && abs(lab[1] - 0.424) < 0.003 && abs(lab[2] - 0.668) < 0.003)
        let oklab = Color(labL: 50, a: 20, b: -30).converted(to: .oklab)
        let viaOKLab = try #require(converter.convert(oklab, to: registry.sRGB, blackPointCompensation: false))
        #expect(zip(lab, viaOKLab).allSatisfy { abs($0 - $1) < 1.0 / 255 })
        #expect(converter.entry(for: Color(cyan: 1, magenta: 0, yellow: 0, black: 0), cmykProfile: TestPresses.heavy).step.profile == TestPresses.heavy)
    }

    @Test func everyIntentAndBlackPointCompensation() throws {
        var results: [[Double]] = []
        let blue = Color(red: 0, green: 0, blue: 1)
        for intent in WTColor.RenderingIntent.allCases {
            for bpc in [false, true] {
                let values = try #require(converter.convert(blue, to: registry.defaultCMYK, intent: intent, blackPointCompensation: bpc))
                results.append(values)
            }
            #expect(intent.cg.rawValue > 0)
        }
        let distinct: Set<[Int]> = Set(results.map { values in values.map { Int($0 * 10_000) } })
        #expect(distinct.count >= 3, "intents and black point compensation matter")
        let dark = Color(white: 0.1)
        let without = try #require(converter.convert(dark, to: registry.defaultCMYK, blackPointCompensation: false))
        let with = try #require(converter.convert(dark, to: registry.defaultCMYK, blackPointCompensation: true))
        #expect(without != with)
    }

    @Test func proofChainsWithAndWithoutPaperWhite() throws {
        let display = registry.sRGB
        let vivid = Color(red: 0, green: 0, blue: 1)
        func proof(_ setup: WTColor.ProofSetup) throws -> [Double] {
            try #require(converter.convert(vivid, through: setup.chain(from: WTColor.ChainStep(profile: nil), to: display)))
        }
        let plain = try proof(WTColor.ProofSetup(profile: registry.defaultCMYK))
        let paper = try proof(WTColor.ProofSetup(profile: TestPresses.light, simulatePaperWhite: true))
        let paperless = try proof(WTColor.ProofSetup(profile: TestPresses.light))
        let ink = try proof(WTColor.ProofSetup(profile: registry.defaultCMYK, simulateBlackInk: true))
        let composite = try proof(WTColor.ProofSetup(profile: TestPresses.light, separations: registry.defaultCMYK))
        #expect(plain != [0, 0, 1], "the press cannot print screen blue")
        #expect(paper != paperless, "paper white shows the press's paper tint")
        #expect(plain != composite)
        #expect(ink.count == 3)
        let chain = WTColor.ProofSetup(profile: TestPresses.light, separations: registry.defaultCMYK).chain(from: .lab, to: display)
        #expect(chain.count == 4 && chain[2].intent == .absoluteColorimetric)
        // A chain through a profile whose data is missing cannot be built.
        let missing = WTColor.ProfileRef(name: "Missing", sha256: Data(count: 32), space: .cmyk)
        #expect(converter.convert(vivid, through: WTColor.ProofSetup(profile: missing).chain(from: .lab, to: display)) == nil)
        #expect(converter.convert(vivid, to: missing) == nil)
    }

    @Test func canonicalRounding() {
        #expect(WTColor.Converter.canonical(0.5 / 255, step: WTColor.Converter.displayStep) == 1.0 / 255)
        #expect(WTColor.Converter.canonical(-0.00005, step: WTColor.Converter.storedStep) == -0.0001, "half away from zero")
        #expect(abs(WTColor.Converter.canonical(0.123_44, step: WTColor.Converter.storedStep) - 0.1234) < 1e-12)
    }

    @Test func rgba8PixelsConvertInPlace() throws {
        let transform = try #require(converter.transform(from: registry.displayP3, to: registry.sRGB))
        var pixels: [UInt8] = [255, 0, 0, 255, 0, 0, 0, 0]
        transform.convertRGBA8(&pixels, width: 2, height: 1, bytesPerRow: 8)
        #expect(pixels[0] == 255 && pixels[3] == 255 && pixels[7] == 0)
        #expect(transform.convert([]) == [])
        converter.removeCachedColors()
    }
}

/// CMS-006 / CMS-007: rendering through the colour pipeline.
@Suite struct ColorManagementRenderingTests {
    static let viewport = Viewport(size: Size(width: 8, height: 8))

    static func swatch(_ color: Color) -> DisplayList {
        DisplayList(canvas: "cms", items: [.fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 8, height: 8)), paint: .solid(color)))])
    }

    static func render(_ color: Color, _ management: ColorManagement) throws -> RGBA8 {
        let renderer = CoreGraphicsRenderer(background: .white).with(colorManagement: management)
        let image = try #require(renderer.renderBitmap(swatch(color), viewport: viewport))
        #expect(image.colorSpace?.name == management.colorSpace.name, "bitmaps are tagged with the working space")
        return rawPixel(image, x: 4, y: 4)
    }

    @Test func standardPipelineIsBitForBitTheOldSRGBPath() throws {
        let color = Color(red: 0.2, green: 0.4, blue: 0.6)
        #expect(ColorManagement.standard.workingComponents(color) == SIMD4(0.2, 0.4, 0.6, 1))
        #expect(ColorManagement.standard.cgColor(color) == CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        #expect(ColorManagement.standard == ColorManagement())
        #expect(ColorManagement.standard.hashValue == ColorManagement().hashValue)
        #expect(ColorManagement.standard != ColorManagement(workingSpace: .displayP3))
    }

    @Test func p3AndSRGBRedDifferOnP3TilesAndClipAlikeOnSRGBTiles() throws {
        let p3Red = Color(displayP3Red: 1, green: 0, blue: 0)
        let srgbRed = Color(red: 1, green: 0, blue: 0)
        let p3 = ColorManagement(workingSpace: .displayP3)
        #expect(try Self.render(p3Red, p3) != Self.render(srgbRed, p3))
        #expect(try Self.render(p3Red, p3) == RGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(try Self.render(p3Red, .standard) == Self.render(srgbRed, .standard))
        #expect(p3.cgColor(p3Red).colorSpace?.name == CGColorSpace.displayP3)
        #expect(p3.workingComponents(Color(oklchL: 0.7, chroma: 0.1, hue: 30)).w == 1)
    }

    @Test func cmykRendersThroughWorkingCMYK() throws {
        let cyan = Color(cyan: 1, magenta: 0, yellow: 0, black: 0)
        let light = ColorManagement(cmykProfile: TestPresses.light)
        let heavy = ColorManagement(cmykProfile: TestPresses.heavy)
        let generic = ColorManagement.standard
        #expect(try Self.render(Color(cyan: 0.5, magenta: 0.3, yellow: 0, black: 0), light) != Self.render(Color(cyan: 0.5, magenta: 0.3, yellow: 0, black: 0), heavy), "changing the profile changes the pixels")
        #expect(try Self.render(cyan, generic) != Self.render(cyan, light))
        #expect(cyan == Color(cyan: 1, magenta: 0, yellow: 0, black: 0), "and never the colour")
        // A pending custom Working CMYK renders through Default CMYK.
        let missing = WTColor.ProfileRef(name: "Missing", sha256: Data(repeating: 7, count: 32), space: .cmyk)
        #expect(try Self.render(cyan, ColorManagement(cmykProfile: missing)) == Self.render(cyan, generic))
        // The intent reaches the conversion.
        let absolute = ColorManagement(intent: .absoluteColorimetric, blackPointCompensation: false)
        #expect(absolute.workingComponents(Color(cyan: 0, magenta: 0, yellow: 0, black: 0)) != generic.workingComponents(Color(cyan: 0, magenta: 0, yellow: 0, black: 0)))
    }

    @Test func pdfCarriesTaggedColours() {
        let management = ColorManagement(cmykProfile: TestPresses.heavy)
        #expect(management.taggedCGColor(Color(cyan: 1, magenta: 0, yellow: 0, black: 0)).colorSpace?.name == WTColor.ProfileRegistry.shared.colorSpace(for: TestPresses.heavy)?.name)
        #expect(management.taggedCGColor(Color(displayP3Red: 1, green: 0, blue: 0)).colorSpace?.name == CGColorSpace.displayP3)
        let missing = ColorManagement(cmykProfile: WTColor.ProfileRef(name: "Missing", sha256: Data(repeating: 9, count: 32), space: .cmyk))
        #expect(missing.taggedCGColor(Color(cyan: 1, magenta: 0, yellow: 0, black: 0)).colorSpace?.name == CGColorSpace.genericCMYK)
        let pdf = CoreGraphicsRenderer().with(colorManagement: management.with(proof: WTColor.ProofSetup(profile: TestPresses.heavy))).renderPDF(Self.swatch(Color(cyan: 1, magenta: 0, yellow: 0, black: 0)), viewport: Self.viewport)
        #expect((pdf?.count ?? 0) > 0)
    }

    @Test func proofingChangesOutOfGamutColoursAndKeepsCMYK() throws {
        let off = ColorManagement.standard
        let on = off.with(proof: WTColor.ProofSetup(profile: WTColor.ProfileRegistry.shared.defaultCMYK))
        let vivid = Color(red: 0, green: 0, blue: 1)
        #expect(try Self.render(vivid, on) != Self.render(vivid, off))
        let ink = Color(cyan: 0.4, magenta: 0.3, yellow: 0.2, black: 0.1)
        let a = try Self.render(ink, on), b = try Self.render(ink, off)
        #expect(a.maxChannelDifference(to: b) <= 1, "an in-gamut CMYK fill stays within 1/255 (\(a) vs \(b))")
        #expect(on.proof != nil && on != off)
        // Sampled paints follow the proof; a mask's gradient never does.
        #expect(on.sampledColor(vivid) != vivid)
        #expect(off.sampledColor(vivid) == vivid)
        #expect(off.sampledColor(ink).space == .sRGB)
        // A proof whose profile is missing leaves colours unproofed.
        let missing = off.with(proof: WTColor.ProofSetup(profile: WTColor.ProfileRef(name: "Missing", sha256: Data(repeating: 3, count: 32), space: .cmyk)))
        #expect(missing.workingComponents(vivid) == off.workingComponents(vivid))
        #expect(missing.proofTransform(forImageIn: WTColor.ProfileRegistry.shared.sRGB) == nil)
        #expect(off.proofTransform(forImageIn: WTColor.ProfileRegistry.shared.sRGB) == nil)
        #expect(on.proofTransform(forImageIn: WTColor.ProfileRegistry.shared.sRGB, intent: .perceptual) != nil)
    }

    @Test func sampledPaintsMapEveryColour() {
        let management = ColorManagement.standard.with(proof: WTColor.ProofSetup(profile: WTColor.ProfileRegistry.shared.defaultCMYK))
        let blue = Color(red: 0, green: 0, blue: 1)
        let gradient = Gradient(.linear, from: blue, to: .white)
        guard case .gradient(let mapped) = management.sampledPaint(.gradient(gradient)) else {
            Issue.record("gradient")
            return
        }
        #expect(mapped.stops[0].color != blue)
        if case .pattern(let pattern) = management.sampledPaint(.pattern(PatternPaint(bitmap: PatternBitmap(rows: [0xFF, 0, 0, 0, 0, 0, 0, 0]), color: blue))) {
            #expect(pattern.color != blue)
        }
        if case .custom(let custom) = management.sampledPaint(.custom(CustomFill(pattern: .bricks, color: blue, color2: blue))) {
            #expect(custom.color != blue && custom.color2 != blue)
        }
        if case .textured(let textured) = management.sampledPaint(.textured(TexturedFill(texture: .burlap, color: blue))) {
            #expect(textured.color != blue)
        }
        if case .lens(let lens) = management.sampledPaint(.lens(LensFill(type: .transparency, color: blue))) {
            #expect(lens.color != blue)
        }
        #expect(management.sampledPaint(.solid(blue)) == .solid(blue))
        #expect(management.sampledPaint(.none) == .none)
    }

    @Test func gradientsAndRasterEffectsRenderUnderAProof() throws {
        let management = ColorManagement(workingSpace: .displayP3).with(proof: WTColor.ProofSetup(profile: WTColor.ProfileRegistry.shared.defaultCMYK))
        let list = DisplayList(canvas: "cms", items: [
            .fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 8, height: 8)), paint: .gradient(Gradient(.linear, from: Color(red: 0, green: 0, blue: 1), to: Color(cyan: 0, magenta: 1, yellow: 0, black: 0))))),
        ])
        let proofed = try #require(CoreGraphicsRenderer(background: .white).with(colorManagement: management).renderBitmap(list, viewport: Self.viewport))
        let plain = try #require(CoreGraphicsRenderer(background: .white).with(colorManagement: management.with(proof: nil)).renderBitmap(list, viewport: Self.viewport))
        #expect(rawPixel(proofed, x: 1, y: 4) != rawPixel(plain, x: 1, y: 4))
    }
}
