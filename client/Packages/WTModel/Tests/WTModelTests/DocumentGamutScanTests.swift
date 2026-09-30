import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// CMS-015: the document gamut scan, cached and invalidated through the swatch-dependents index,
/// and exports that follow it -- a P3 swatch fill exports tagged Display P3 with the P3 value, and
/// the same document after *Convert to sRGB* on that swatch exports tagged with Working RGB.
@Suite struct DocumentGamutScanTests {
    static let p3 = Color(displayP3Red: 0.9, green: 0.1, blue: 0.2)
    static let deepLab = Color(labL: 50, a: 110, b: -110)

    /// A 10 pt square with a white Basic fill.
    static func square() -> CreatePath {
        var fill = Wiretuner_Doc_V1_Fill()
        fill.settings.kind = .basic
        fill.settings.basic.color = ColorResolver.inline(.white)
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [fill]
        return CreatePath(contours: [NewContour(closed: true, points: [0, 1, 3, 2].map { i in
            VectorPoint(anchor: Point(x: Double(i % 2) * 10, y: Double(i / 2) * 10))
        })], appearance: appearance)
    }

    static func scan(_ state: EngineState) -> DocumentGamutScan.Reach {
        DocumentGamutScan(state, index: SwatchIndex(state)).widestSpaceUsed(in: state)
    }

    @Test func theScanReadsResolvedColoursOfLiveObjects() throws {
        var a = Replica(0x61)
        #expect(Self.scan(a.state) == .sRGB)
        let plain = try ColorFixture.shape(&a, fill: ColorResolver.inline(.white), stroke: ColorResolver.inline(.black))
        #expect(Self.scan(a.state) == .sRGB)
        let wide = try ColorFixture.shape(&a, fill: ColorResolver.inline(.white), stroke: ColorResolver.inline(Self.p3))
        #expect(Self.scan(a.state) == .displayP3)
        try ColorFixture.markedText(&a, fill: ColorResolver.inline(Self.deepLab))
        #expect(Self.scan(a.state) == .beyondDisplayP3, "a text mark's glyph fill counts")
        // An unused wide swatch draws nothing.
        var b = Replica(0x62)
        try ColorFixture.add(&b, Self.deepLab, name: "Deep")
        #expect(Self.scan(b.state) == .sRGB)
        // Liveness is read when asked: deleting the object takes its colour out.
        try a.perform(OpsCommand("Delete", ops: [Ops.setDeleted(wide)]))
        let index = SwatchIndex(a.state)
        var cached = DocumentGamutScan(a.state, index: index)
        #expect(cached.widestSpaceUsed(in: a.state) == .beyondDisplayP3)
        cached.refresh([plain], in: a.state, index: index)
        #expect(cached.widestSpaceUsed(in: a.state) == .beyondDisplayP3)
    }

    /// A swatch recoloured re-resolves every use the dependents index lists -- through a tint
    /// swatch to its users -- without a full scan, and matches a full one after every step.
    @Test @MainActor func aSwatchChangeReachesItsDependentsThroughTheIndex() async throws {
        let document = Document(memory: DocumentCore(state: EngineState(), replica: 0x63))
        let model = SwatchesModel(document: document)
        let swatch = ColorFixture.created(try await document.perform(AddSwatch(Self.p3, name: "Hot")))[0]
        let tint = ColorFixture.created(try await document.perform(AddTintSwatch(of: swatch, percent: 90, name: "Warm")))[0]
        let resolver = ColorResolver(document.state)
        let shape = Self.square()
        let object = try #require(try await document.perform(shape).flatMap { ColorFixture.created($0).last })
        #expect(model.widestSpaceUsed == .sRGB)
        try await document.perform(ApplyColor([object], target: .fill, color: resolver.reference(to: tint), name: "Warm"))
        #expect(model.widestSpaceUsed == Self.scan(document.state))
        let before = model.widestSpaceUsed
        #expect(before == .displayP3, "the tint of a P3 swatch is outside sRGB")

        // *Convert to sRGB* writes only the base swatch; the tint's user follows through the index.
        try await document.perform(ConvertSwatchSpace([swatch], to: .sRGB, name: "Hot"))
        #expect(model.widestSpaceUsed == .sRGB)
        #expect(Self.scan(document.state) == .sRGB)
        _ = try await document.undo()
        #expect(model.widestSpaceUsed == .displayP3)

        // A reload reads everything again.
        var scan = model.gamut
        scan.apply(DocumentEvent(change: Wiretuner_Doc_V1_Change(), origin: .reload, before: EngineState(), after: EngineState()), index: SwatchIndex(EngineState()))
        #expect(scan.widestSpaceUsed(in: EngineState()) == .sRGB)
        model.stop()
    }

    // MARK: Exports

    static func export(_ state: EngineState, gamut: DocumentGamutScan.Reach?) throws -> (profile: String?, pixel: [Double], notes: [String]) {
        let request = ExportSnapshot.Request(name: "Wide", pages: [ExportSnapshot.Page(bounds: Rect(x: 0, y: 0, width: 10, height: 10))], scope: .pages([0]))
        let scene = try ExportSnapshot.capture(state, request: request, builder: DocumentDisplayListBuilder(canvas: "export"), gamut: gamut, blob: { _ in nil }).resolved()
        #expect(scene.output?.widestSpaceUsed == gamut)
        let folder = FileManager.default.temporaryDirectory.appending(path: "WTGamut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "wide.png")
        let summary = try BitmapExporter(format: .png).export(scene: scene, options: PNGOptions(), to: ExportDestination(url: url))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (image.height / 2 * image.width + image.width / 2) * 4
        return (properties?[kCGImagePropertyProfileName] as? String, (0..<3).map { Double(bytes[offset + $0]) / 255 }, summary.notes)
    }

    /// End to end: the cached scan's answer decides the PNG's space; after *Convert to sRGB* on the
    /// swatch the same export is tagged with Working RGB (sRGB here).
    @Test @MainActor func convertToSRGBMovesTheExportToWorkingRGB() async throws {
        let document = Document(memory: DocumentCore(state: EngineState(), replica: 0x64))
        let model = SwatchesModel(document: document)
        let swatch = ColorFixture.created(try await document.perform(AddSwatch(Self.p3, name: "Hot")))[0]
        let shape = Self.square()
        let object = try #require(try await document.perform(shape).flatMap { ColorFixture.created($0).last })
        try await document.perform(ApplyColor([object], target: .fill, color: ColorResolver(document.state).reference(to: swatch), name: "Hot"))

        let wide = try Self.export(document.state, gamut: model.widestSpaceUsed)
        #expect(wide.profile == "Display P3")
        #expect(zip(wide.pixel, [0.9, 0.1, 0.2]).allSatisfy { abs($0 - $1) <= 1.0 / 255 + 1e-9 }, "\(wide.pixel)")

        try await document.perform(ConvertSwatchSpace([swatch], to: .sRGB, name: "Hot"))
        #expect(model.widestSpaceUsed == .sRGB)
        let narrow = try Self.export(document.state, gamut: model.widestSpaceUsed)
        #expect(narrow.profile == "sRGB IEC61966-2.1", "Working RGB")
        #expect(narrow.notes.isEmpty)
        model.stop()
    }

    /// The document scan decides for every page: a page drawing only sRGB colours of a document
    /// that reaches P3 renders into P3 as well; without the scan, the exported pages decide.
    @Test func everyPageFollowsTheDocumentScan() throws {
        var a = Replica(0x65)
        try ColorFixture.shape(&a, fill: ColorResolver.inline(.white))
        #expect(try Self.export(a.state, gamut: .displayP3).profile == "Display P3")
        #expect(try Self.export(a.state, gamut: nil).profile == "sRGB IEC61966-2.1")
        #expect(try Self.export(a.state, gamut: .sRGB).profile == "sRGB IEC61966-2.1")
    }
}
