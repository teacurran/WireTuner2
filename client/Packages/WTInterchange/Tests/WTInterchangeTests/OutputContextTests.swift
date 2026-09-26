// CMS-011: the output colour context -- working profiles into exported files, the PDF/X output
// intent, the composite-simulates-separations chain, wide-gamut colours separating through their
// own spaces, and the embedding helpers.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WTGeometry
@testable import WTInterchange
@testable import WTRender

/// A synthetic press (a second CMYK profile besides Generic CMYK), registered once.
enum OutputPress {
    static let data = ICCProfileBuilder.cmykProfile(name: "Output Test Press", dotGain: 1.4)
    static let profile = WTColor.ProfileRegistry.shared.register(iccData: data)!
}

@Suite struct OutputContextTests {
    let registry = WTColor.ProfileRegistry.shared

    static func scene(_ output: WTColor.OutputContext?) -> ExportScene {
        var scene = Corpus.scene([Corpus.fixture("basics")])
        scene.output = output
        return scene
    }

    static func export(_ format: ExportFormat, _ options: any ExportOptions, scene: ExportScene) throws -> ExportSummary {
        let url = Corpus.directory().appendingPathComponent("out.\(format.fileExtension)")
        return try BitmapExporter(format: format).export(scene: scene, options: options, to: ExportDestination(url: url))
    }

    /// The profile embedded in an exported file.
    static func embedded(_ url: URL) throws -> WTColor.ProfileRef? {
        WTColor.OutputContext.embeddedProfile(in: try Data(contentsOf: url))
    }

    @Test func workingProfilesSpacesAndStreams() throws {
        let standard = WTColor.OutputContext.standard
        #expect(standard.profile(model: .rgb) == registry.sRGB && standard.profile(model: .cmyk) == registry.defaultCMYK && standard.profile(model: .gray) == registry.genericGray)
        #expect(standard.iccData(model: .rgb) == registry.iccData(for: registry.sRGB))
        #expect(standard.colorSpace(model: .gray).model == .monochrome)
        #expect(standard.colorSpace(for: .lab).model == .lab)
        #expect(standard.colorSpace(for: .sRGB).name == CGColorSpace.sRGB)
        #expect(standard.colorSpace(for: .displayP3).name == CGColorSpace.displayP3)
        #expect(standard.colorSpace(for: .oklab).name == CGColorSpace.displayP3)
        #expect(standard.colorSpace(for: .cmyk).model == .cmyk)
        #expect(WTColor.OutputContext.outputSpace(.oklab) == .displayP3 && WTColor.OutputContext.outputSpace(.lab) == .lab)
        #expect(standard.iccStream(for: .cmyk) == standard.iccData(model: .cmyk))
        for space in [Color.Space.sRGB, .displayP3, .lab, .oklab] {
            #expect(WTColor.ProfileRegistry.makeRef(iccData: standard.iccStream(for: space)) != nil, "\(space)")
        }
        // Components in the output space.
        let oklab = Color(space: .oklab, components: SIMD4(0.6, 0.1, 0.05, 0), alpha: 0.5)
        #expect(standard.outputComponents(oklab).count == 4 && standard.outputComponents(oklab)[3] == 0.5)
        #expect(standard.outputComponents(Color(cyan: 0.1, magenta: 0.2, yellow: 0.3, black: 0.4)) == [0.1, 0.2, 0.3, 0.4, 1])
        #expect(standard.outputComponents(Color(red: 1, green: 0, blue: 0)) == [1, 0, 0, 1])
        #expect(standard.cgColor(oklab).colorSpace?.name == CGColorSpace.displayP3)
        // A profile of the wrong space, or one whose data is missing, outputs through the default.
        let missing = WTColor.ProfileRef(name: "Gone", sha256: Data(repeating: 7, count: 32), space: .cmyk)
        let fallback = WTColor.OutputContext(rgbProfile: registry.genericGray, cmykProfile: missing)
        #expect(fallback.rgbProfile == registry.sRGB && fallback.cmykProfile == registry.defaultCMYK)
        // From a renderer's colour state.
        let managed = ColorManagement(workingSpace: .displayP3, cmykProfile: OutputPress.profile, intent: .perceptual, blackPointCompensation: false)
        let context = WTColor.OutputContext(colorManagement: managed, imageProfiles: ["photo": registry.displayP3, "scan": registry.genericGray])
        #expect(context.rgbProfile == registry.displayP3 && context.cmykProfile == OutputPress.profile && context.intent == .perceptual && !context.blackPointCompensation)
        #expect(WTColor.OutputContext(colorManagement: .standard).rgbProfile == registry.sRGB)
        #expect(context.sourceProfile(forImage: "photo", model: .rgb) == registry.displayP3)
        #expect(context.sourceProfile(forImage: "scan", model: .rgb) == registry.displayP3)
        #expect(context.sourceProfile(forImage: "other", model: .gray) == registry.genericGray)
        #expect(context == WTColor.OutputContext(colorManagement: managed, imageProfiles: ["photo": registry.displayP3, "scan": registry.genericGray]))
        #expect(context != standard)
        #expect(Set([context, standard]).count == 2)
    }

    /// An exported TIFF's embedded profile hashes to the working profile of its model.
    @Test func bitmapsEmbedTheWorkingProfiles() throws {
        let output = WTColor.OutputContext(rgbProfile: registry.displayP3, cmykProfile: OutputPress.profile)
        let cmyk = try Self.export(.tiff, TIFFOptions(common: BitmapCommonOptions(background: .white, color: .cmyk)), scene: Self.scene(output))
        let press = try #require(try Self.embedded(cmyk.files[0]))
        #expect(press.sha256 == OutputPress.profile.sha256)
        // Without a context the TIFF carries Generic CMYK, as before.
        let plain = try Self.export(.tiff, TIFFOptions(common: BitmapCommonOptions(background: .white, color: .cmyk)), scene: Self.scene(nil))
        #expect(try Self.embedded(plain.files[0]) == registry.defaultCMYK)
        let rgb = try Self.export(.png, PNGOptions(), scene: Self.scene(output))
        #expect(try Self.embedded(rgb.files[0]) == registry.displayP3)
        let gray = try Self.export(.png, PNGOptions(common: BitmapCommonOptions(background: .white, color: .gray), bits: 24), scene: Self.scene(output))
        #expect(try Self.embedded(gray.files[0])?.space == .gray)
        // Photoshop files carry the press in their ICC resource.
        let psd = try PSDExporter().data(scene: Self.scene(output), page: 0, options: PSDOptions(common: BitmapCommonOptions(background: .white, color: .cmyk)))
        #expect(psd.range(of: OutputPress.data) != nil)
        #expect(output.psdProfile(for: .cmyk) == OutputPress.data)
    }

    /// The PDF/X output intent names Working CMYK; a converter chosen explicitly still wins.
    @Test func pdfxOutputIntentNamesWorkingCMYK() throws {
        let output = WTColor.OutputContext(cmykProfile: OutputPress.profile)
        let result = try PDFExporter().data(scene: Self.scene(output), options: .pressPDFX1a)
        let raw = PDFTests.text(of: result.data)
        #expect(raw.contains("/OutputConditionIdentifier (Output Test Press)"))
        #expect(raw.contains("/S /GTS_PDFX"))
        let document = try #require(CGPDFDocument(CGDataProvider(data: result.data as CFData)!))
        let catalog = try #require(document.catalog)
        var intents: CGPDFArrayRef?
        #expect(CGPDFDictionaryGetArray(catalog, "OutputIntents", &intents))
        var intent: CGPDFDictionaryRef?
        let intentArray = try #require(intents)
        #expect(CGPDFArrayGetDictionary(intentArray, 0, &intent))
        var stream: CGPDFStreamRef?
        let intentDictionary = try #require(intent)
        #expect(CGPDFDictionaryGetStream(intentDictionary, "DestOutputProfile", &stream))
        var format = CGPDFDataFormat.raw
        let profileStream = try #require(stream)
        let profile = try #require(CGPDFStreamCopyData(profileStream, &format)) as Data
        #expect(WTColor.ProfileRegistry.hash(profile) == OutputPress.profile.sha256)
        let chosen = try PDFExporter(cmyk: ProfileCMYKConverter(profile: registry.defaultCMYK)).data(scene: Self.scene(output), options: .pressPDFX1a)
        #expect(!PDFTests.text(of: chosen.data).contains("Output Test Press"))
        // EPS converts with the same Working CMYK.
        let eps = try EPSExporter().data(scene: Self.scene(output), page: 0, options: EPSOptions(colors: .convertToCMYK))
        #expect(!eps.data.isEmpty)
        // The intent helper for any profile.
        let gray = output.outputIntent(registry.genericGray, subtype: "GTS_PDFA1")
        #expect(gray.components == 1 && gray.subtype == "GTS_PDFA1" && gray.profile == registry.iccData(for: registry.genericGray))
        #expect(output.outputIntent().profile == OutputPress.data && output.outputIntent().identifier == "Output Test Press")
        #expect(output.cmykConverter.profile == OutputPress.profile)
    }

    /// With *Composite simulates separations*, a colour for a composite device passes through
    /// Working CMYK before the device profile.
    @Test func compositeSimulatesSeparationsChainsThroughCMYK() throws {
        let device = registry.sRGB
        let plain = WTColor.OutputContext(cmykProfile: OutputPress.profile)
        var simulating = plain
        simulating.proof = WTColor.ProofSetup(profile: device, separations: OutputPress.profile)
        let source = WTColor.ChainStep(profile: registry.displayP3)
        let direct = plain.compositeChain(from: source, device: device)
        #expect(direct.map(\.profile) == [registry.displayP3, device])
        let chain = simulating.compositeChain(from: source, device: device)
        #expect(chain.map(\.profile) == [registry.displayP3, OutputPress.profile, device])
        #expect(chain[1].intent == .relativeColorimetric && chain[2].intent == .absoluteColorimetric)
        // A saturated P3 green does not survive the press: the simulated colour differs.
        let green = Color(space: .displayP3, components: SIMD4(0, 1, 0, 0))
        let a = try #require(plain.compositeColor(green, device: device)), b = try #require(simulating.compositeColor(green, device: device))
        #expect(zip(a, b).map { abs($0 - $1) }.max()! > 2.0 / 255)
        #expect(simulating.compositePrintColorManagement(device: device).proof?.separations == OutputPress.profile)
        #expect(plain.compositePrintColorManagement(device: device).proof == nil)
    }

    /// Display P3 and OKLab fills separate through their own spaces.
    @Test func wideGamutColoursSeparateThroughTheirOwnSpaces() throws {
        let context = WTColor.OutputContext(cmykProfile: OutputPress.profile)
        let p3Red = Color(space: .displayP3, components: SIMD4(1, 0, 0, 0))
        let srgbRed = Color(red: 1, green: 0, blue: 0)
        let p3 = context.separate(p3Red), srgb = context.separate(srgbRed)
        #expect(p3.count == 4)
        #expect(zip(p3, srgb).map { abs($0 - $1) }.max()! > 1.0 / 255)
        let oklabRed = Color(space: .oklab, components: SIMD4(WTColor.Math.oklab(p3Red), 0))
        let oklab = context.separate(oklabRed)
        #expect(zip(p3, oklab).map { abs($0 - $1) }.max()! <= 1.0 / 255, "\(p3) \(oklab)")
        #expect(context.convert(p3Red, to: registry.sRGB) != nil)
    }

    @Test func embeddingHelpers() throws {
        let context = WTColor.OutputContext(rgbProfile: registry.displayP3)
        let image = Corpus.image(alpha: true)
        #expect(context.tagged(image, model: .rgb)?.colorSpace?.name == CGColorSpace.displayP3)
        #expect(context.tagged(image, model: .gray) == nil)
        #expect(context.encode(image, type: .png, model: .gray) == nil)
        for type in [UTType.png, .tiff, .jpeg] {
            let data = try #require(context.encode(image, type: type, model: .rgb))
            #expect(WTColor.OutputContext.embeddedProfile(in: data) == registry.displayP3, "\(type)")
        }
        #expect(WTColor.OutputContext.embeddedProfile(in: Data("not an image".utf8)) == nil)
    }
}
