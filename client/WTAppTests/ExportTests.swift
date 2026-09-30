import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// The stub exporter with a delay, ignoring the options it is given (the sheet passes the
/// format's own options): one text file per page listing the page's bounds and item count.
struct SlowStubExporter: Exporter {
    let format: ExportFormat
    var delay: Double = 0

    var optionsType: any ExportOptions.Type { StubExportOptions.self }
    var capabilities: ExportCapabilities { format.capabilities }

    func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination) throws -> ExportSummary {
        try StubExporter(format: format).export(scene: scene, options: StubExportOptions(delayPerPage: delay), to: destination)
    }
}

/// A document window with an export controller whose panels, alerts and *After export* actions
/// are recorded, exporting into a throwaway folder.
@MainActor
final class ExportWorld {
    let world = ImportWorld()
    let suite = TestDefaults()
    let controller: ExportController
    let output: URL
    var alerts: [(String, String)] = []
    var panels: [NSSavePanel] = []
    var saveName: String? = "Catalog.png"
    var opened: [([URL], String)] = []
    var revealed: [[URL]] = []
    var passwords: [String?] = []
    var asked: [String] = []

    init(delay: Double = 0) {
        controller = ExportController(defaults: suite.defaults)
        output = world.files.directory.appending(path: "out")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        controller.blobs = world.imports.blobs
        controller.progressDelay = .zero
        var registry = ExportRegistry.standard
        registry.register(SlowStubExporter(format: .png, delay: delay))
        registry.register(SlowStubExporter(format: .text, delay: delay))
        controller.registry = registry
        let output = output
        controller.showAlert = { [unowned self] message, detail, _ in alerts.append((message, detail)) }
        controller.runSavePanel = { [unowned self] panel, _ in
            panels.append(panel)
            return saveName.map { output.appending(path: $0) }
        }
        controller.openFiles = { [unowned self] files, application in opened.append((files, application)) }
        controller.reveal = { [unowned self] files in revealed.append(files) }
        controller.askPassword = { [unowned self] message, _ in
            asked.append(message)
            return passwords.isEmpty ? nil : passwords.removeFirst()
        }
    }

    var window: DocumentWindowController { world.window }
    var document: DocumentHandle { world.document }

    /// The names of the files in the output folder.
    var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    func read(_ name: String) -> String {
        (try? String(contentsOf: output.appending(path: name), encoding: .utf8)) ?? ""
    }

    /// Three Letter pages side by side, a square on each and one on a second layer.
    func threePages() async -> [OpID] {
        document.pages = (0..<3).map { Rect(x: Double($0) * 700, y: 0, width: 612, height: 792) }
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        var objects: [OpID] = []
        for index in 0..<3 {
            let change = await document.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 20),
                                                            transform: .translation(x: Double(index) * 700 + 10, y: 10), appearance: appearance)).value
            objects += change?.createdObjects ?? []
        }
        return objects
    }

    func close() {
        world.close()
        suite.remove()
    }
}

/// IO-014: the Export sheet, the export pipeline and Export Again; IO-028's reopening glue.
@Suite(.serialized) @MainActor struct ExportTests {
    // MARK: Settings

    @Test func pageRangesParseAndRefuseWithReasons() throws {
        #expect(try PageRange.parse("1-3, 6", pageCount: 8) == [0, 1, 2, 5])
        #expect(try PageRange.parse("2-", pageCount: 4) == [1, 2, 3])
        #expect(try PageRange.parse("-2, 2, 1", pageCount: 4) == [0, 1])
        #expect(try PageRange.parse(" 3 ", pageCount: 4) == [2])
        #expect(throws: PageRange.Problem.empty) { try PageRange.parse(" , ", pageCount: 4) }
        #expect(throws: PageRange.Problem.invalid("a")) { try PageRange.parse("a", pageCount: 4) }
        #expect(throws: PageRange.Problem.invalid("3-1")) { try PageRange.parse("3-1", pageCount: 4) }
        #expect(throws: PageRange.Problem.invalid("1-2-3")) { try PageRange.parse("1-2-3", pageCount: 4) }
        #expect(throws: PageRange.Problem.invalid("-")) { try PageRange.parse("-", pageCount: 4) }
        #expect(throws: PageRange.Problem.outOfRange(9, pages: 4)) { try PageRange.parse("9", pageCount: 4) }
        #expect(throws: PageRange.Problem.outOfRange(0, pages: 1)) { try PageRange.parse("0", pageCount: 1) }
        #expect(PageRange.Problem.empty.description.contains("1-3, 6"))
        #expect(PageRange.Problem.invalid("x").description.contains("“x”"))
        #expect(PageRange.Problem.outOfRange(5, pages: 1).description.hasSuffix("1 page."))
        #expect(PageRange.Problem.outOfRange(5, pages: 2).description.hasSuffix("2 pages."))
        #expect(ExportWhat.allCases.map(\.title) == ["Current Page", "All Pages", "Range", "Output Area", "Selected Objects"])
    }

    @Test func everyFormatHasItsOptionsAndSharedFieldsReadAndWrite() {
        var options = ExportFormatOptions()
        for format in ExportFormat.allCases {
            let typed = options.options(for: format)
            #expect(type(of: typed) != StubExportOptions.self)
            if format.family == .bitmap {
                var common = options.common(format)
                common.ppi = 144
                options.setCommon(common, for: format)
                #expect(options.common(format).ppi == 144, "\(format)")
                #expect(type(of: options.bitmap(format)) == type(of: typed))
            }
            if format.family == .animation {
                var common = options.animation(format)
                common.antiAliasing = 2
                options.setAnimation(common, for: format)
                #expect(options.animation(format).antiAliasing == 2, "\(format)")
            }
        }
        #expect(options.options(for: .pdf) is PDFOptions && options.options(for: .illustrator) is IllustratorOptions && options.options(for: .eps) is EPSOptions)
        #expect(options.options(for: .svg) is SVGOptions && options.options(for: .dxf) is DXFOptions && options.options(for: .rtf) is RTFOptions)
        #expect(options.options(for: .text) is PlainTextOptions && options.options(for: .apng) is APNGOptions && options.options(for: .mp4HEVC) is MP4Options)
        #expect(options.options(for: .animatedGIF) is AnimatedGIFOptions && options.options(for: .mp4H264) is MP4Options)
        #expect(!options.embedsPackage(.pdf) && !options.embedsPackage(.png))
        options.pdf.embedPackage = true
        options.illustrator.embedPackage = true
        options.eps.embedPackage = true
        #expect(options.embedsPackage(.pdf) && options.embedsPackage(.illustrator) && options.embedsPackage(.eps))
        options.pdf.standard = .pdfX4_2010
        #expect(!options.embedsPackage(.pdf), "PDF/X forbids attachments")

        var settings = ExportSettings(format: .png)
        settings.options.png.common.scales = [1, 2]
        #expect(settings.scales == [1, 2] && settings.transparentBackground)
        settings.format = .svg
        #expect(settings.scales == [1] && !settings.transparentBackground)
        settings.options.pdf.openPassword = "open"
        let stored = settings.stored
        #expect(stored.asksOpenPassword && !stored.asksPermissionsPassword && stored.options.pdf.openPassword.isEmpty)
        settings.options.pdf.permissionsPassword = "owner"
        #expect(settings.stored.asksPermissionsPassword && settings.stored.options.pdf.permissionsPassword.isEmpty)
    }

    @Test func presetsAreShippedSavedOverwrittenDeletedAndPersisted() {
        let suite = TestDefaults()
        defer { suite.remove() }
        let store = ExportPresetStore(defaults: suite.defaults)
        #expect(store.all.map(\.name) == ["PDF for print (PDF/X-4)", "PDF for screen", "SVG for web", "PNG 1× 2× 3×", "JPEG for web", "Illustrator"])
        #expect(store.preset("shipped.png-scales")?.settings.scales == [1, 2, 3])
        #expect(store.preset("shipped.pdf-print")?.settings.options.pdf.standard == .pdfX4_2010)
        var settings = ExportSettings(format: .jpeg, what: .allPages, range: "1-2", includePageBoundary: false, namePattern: "{name}-{page:2}")
        settings.options.jpeg.common.scales = [2]
        settings.openWith = "com.apple.Preview"
        settings.revealInFinder = true
        let saved = store.save(settings, named: "Mine")
        #expect(store.userPresets.count == 1 && store.preset(saved.id)?.settings == settings)
        settings.what = .currentPage
        let again = store.save(settings, named: "Mine")
        #expect(again.id == saved.id && store.userPresets.count == 1 && store.preset(saved.id)?.settings.what == .currentPage)
        // A relaunch keeps the stored fields; the options return to their defaults but the scales.
        let reloaded = ExportPresetStore(defaults: suite.defaults)
        let restored = reloaded.preset(saved.id)?.settings
        #expect(restored?.format == .jpeg && restored?.namePattern == "{name}-{page:2}" && restored?.scales == [2] && restored?.openWith == "com.apple.Preview")
        #expect(restored?.revealInFinder == true && restored?.includePageBoundary == false && restored?.range == "1-2")
        reloaded.delete(saved.id)
        #expect(ExportPresetStore(defaults: suite.defaults).userPresets.isEmpty)
        #expect(StoredExportSettings(ExportSettings(format: .svg)).settings.format == .svg)
        var unknown = StoredExportSettings(ExportSettings())
        unknown.format = 999
        #expect(unknown.settings.format == .pdf)
    }

    @Test func theLastExportIsRememberedPerDocumentUntilTheFileMoves() throws {
        let suite = TestDefaults()
        let directory = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        }
        let memory = ExportMemoryStore(defaults: suite.defaults)
        #expect(memory.settings(for: "doc") == nil && memory.file(for: "doc") == nil)
        let file = directory.appending(path: "Out.pdf")
        try Data("pdf".utf8).write(to: file)
        var settings = ExportSettings(format: .pdf)
        settings.options.pdf.openPassword = "secret"
        memory.remember("doc", url: file, written: file, settings: settings)
        #expect(memory.settings(for: "doc")?.options.pdf.openPassword == "" && memory.settings(for: "doc")?.asksOpenPassword == true)
        #expect(memory.file(for: "doc")?.path == file.path)
        // Another launch reads the stored fields.
        #expect(ExportMemoryStore(defaults: suite.defaults).settings(for: "doc")?.format == .pdf)
        try FileManager.default.moveItem(at: file, to: directory.appending(path: "Moved.pdf"))
        #expect(memory.file(for: "doc") == nil)
    }

    // MARK: The sheet's model

    static func model(_ settings: ExportSettings = ExportSettings(), context: ExportContext? = nil, suite: TestDefaults) -> ExportSheetModel {
        let pages = (0..<3).map { Rect(x: Double($0) * 700, y: 0, width: 612, height: 792) }
        let context = context ?? ExportContext(title: "Catalog", pages: pages, currentPage: 1)
        let model = ExportSheetModel(context: context, settings: settings, presets: ExportPresetStore(defaults: suite.defaults), registry: .standard)
        model.applications = { _ in [ExportApplication(id: "com.example.viewer", name: "Viewer")] }
        return model
    }

    @Test func theSheetDerivesPagesFilesAndRefusals() throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let model = Self.model(suite: suite)
        #expect(model.whatChoices == [.currentPage, .allPages, .range])
        #expect(model.formats.contains(.pdf) && model.formats.contains(.mp4HEVC))
        #expect(try model.pageIndices.get() == [1] && model.fileCount == 1 && !model.showsFileNames && model.problem == nil && !model.usesRange)
        model.settings.what = .allPages
        #expect(model.pageCount == 3 && model.fileCount == 1, "PDF puts every page in one file")
        var formats: [ExportFormat] = []
        model.onFormatChange = { formats.append($0) }
        model.settings.format = .png
        #expect(formats == [.png] && model.fileCount == 3 && model.showsFileNames)
        #expect(model.sampleNames == ["Catalog-1.png", "Catalog-2.png"])
        model.settings.what = .range
        model.settings.range = "2-9"
        #expect(model.usesRange && model.problem == "There is no page 9; the document has 3 pages." && model.pageCount == 0)
        model.settings.range = "3"
        #expect(model.problem == nil && model.sampleNames == ["Catalog-3.png"])
        model.settings.namePattern = "{name}"
        model.settings.range = "1-2"
        #expect(model.problem?.contains("file name pattern") == true)
        model.settings.namePattern = "{name}-{page}"
        model.scale2x = true
        #expect(model.sampleNames == ["Catalog-1.png", "Catalog-1@2x.png", "Catalog-2.png"])
        model.settings.namePattern = "{name}{scale}-{page}"
        #expect(model.sampleNames.contains("Catalog@2x-1.png"))
        model.settings.format = .jpeg
        model.settings.options.jpeg.common.background = .transparent
        #expect(model.problem == "JPEG cannot hold transparency.")
        model.settings.what = .outputArea
        #expect(model.problem == "Draw an output area with the Output Area tool first." && model.exportBounds == nil)
        model.settings.what = .selection
        #expect(model.problem == "Select the objects to export first.")
        model.settings.what = .currentPage
        model.settings.format = .text
        #expect(model.sampleNames == ["Catalog-2.txt"])

        // With a selection and an output area both choices appear; animations refuse a selection.
        let context = ExportContext(title: "C", pages: [], currentPage: 0, selectionBounds: Rect(x: 0, y: 0, width: 5, height: 5),
                                    outputArea: Rect(x: 1, y: 1, width: 9, height: 9), syncNote: "Offline", missing: ["photo.png"])
        let other = Self.model(ExportSettings(format: .apng, what: .selection), context: context, suite: suite)
        #expect(other.whatChoices.count == 5 && other.problem == "Animations export whole pages or the output area.")
        #expect(try other.pageIndices.get() == [0])
        other.settings.what = .currentPage
        #expect(try other.pageIndices.get().isEmpty && other.problem == "There is nothing to export.")
        other.settings.format = .png
        other.settings.what = .outputArea
        #expect(other.exportBounds == Rect(x: 1, y: 1, width: 9, height: 9))
        other.settings.what = .selection
        #expect(other.exportBounds == Rect(x: 0, y: 0, width: 5, height: 5))
    }

    @Test func presetsAfterExportAndSizeEstimatesInTheSheet() {
        let suite = TestDefaults()
        defer { suite.remove() }
        let model = Self.model(suite: suite)
        #expect(model.presetChoice == "" && model.presetTitle == nil && !model.isModified && !model.canDeletePreset)
        model.presetChoice = "shipped.png-scales"
        #expect(model.settings.format == .png && model.settings.scales == [1, 2, 3] && model.presetTitle == "PNG 1× 2× 3×" && !model.isModified)
        model.choosePreset("no such preset")
        #expect(model.presetTitle == "PNG 1× 2× 3×")
        model.scale3x = false
        #expect(model.isModified && !model.canDeletePreset)
        model.deletePreset()
        #expect(model.presetTitle == "PNG 1× 2× 3×", "shipped presets stay")
        model.presetName = "   "
        model.savePreset()
        #expect(model.presets.userPresets.isEmpty)
        model.presetName = "Two scales"
        model.savePreset()
        #expect(model.presetTitle == "Two scales" && !model.isModified && model.canDeletePreset && model.presetName.isEmpty && model.presetList.count == 7)
        model.deletePreset()
        #expect(model.presetTitle == nil && model.presets.userPresets.isEmpty)

        #expect(model.openWithChoice == "" && model.openWithApplications.map(\.name) == ["Viewer"])
        model.openWithChoice = "com.example.viewer"
        #expect(model.settings.openWith == "com.example.viewer")
        model.openWithChoice = ""
        #expect(model.settings.openWith == nil)
        #expect(ExportSheetModel.applications(.pdf).allSatisfy { !$0.id.isEmpty })

        // Letter at 72 ppi is 612 × 792 pixels.
        model.settings.format = .png
        model.scale1x = true
        #expect(model.sizeEstimate?.hasPrefix("About ") == true && model.bytesPerPixel == 2)
        model.settings.options.png.bits = 8
        #expect(model.bytesPerPixel == 0.3)
        let expected: [(ExportFormat, (inout ExportFormatOptions) -> Void, Double)] = [
            (.jpeg, { $0.jpeg.quality = 100 }, 1), (.webp, { $0.webp.lossless = true }, 0.6), (.webp, { $0.webp.lossless = false; $0.webp.quality = 100 }, 0.55),
            (.heic, { $0.heic.quality = 100 }, 0.5), (.avif, { $0.avif.quality = 100 }, 0.44), (.gif, { _ in }, 0.3), (.bmp, { $0.bmp.bits = 24 }, 3),
            (.targa, { $0.targa.bits = 16 }, 2), (.tiff, { $0.tiff.compression = .none }, 4), (.tiff, { $0.tiff.compression = .lzw }, 2),
            (.psd, { $0.psd.bitsPerChannel = 16 }, 8),
        ]
        for (format, change, bytes) in expected {
            model.settings.format = format
            change(&model.settings.options)
            #expect(abs(model.bytesPerPixel - bytes) < 0.0001, "\(format)")
        }
        model.settings.format = .pdf
        #expect(model.sizeEstimate == nil)
    }

    @Test func optionControlsReadAndWriteTheChosenFormat() {
        let suite = TestDefaults()
        defer { suite.remove() }
        let model = Self.model(ExportSettings(format: .png), suite: suite)
        model.scale1x = false
        #expect(model.settings.scales == [1], "the last scale stays")
        model.scale3x = true
        model.scale1x = false
        #expect(model.settings.scales == [3] && !model.scale2x && model.scale3x)
        model.bitmapCommon.ppi = 300
        #expect(model.settings.options.png.common.ppi == 300)
        for format in [ExportFormat.gif, .tiff, .png] {
            model.settings.format = format
            model.palette.colors = 16
            #expect(model.palette.colors == 16, "\(format)")
        }
        #expect(model.settings.options.gif.palette.colors == 16 && model.settings.options.tiff.palette.colors == 16)

        model.settings.format = .mp4H264
        #expect(!model.animationUsesPixels && model.animationScale == 1 && model.animationWidth == 640 && model.animationHeight == 480)
        model.animationScale = 2
        #expect(model.settings.options.mp4H264.common.size == .scale(2))
        model.animationUsesPixels = true
        #expect(model.animationUsesPixels && model.animationScale == 1 && model.settings.options.mp4H264.common.size == .pixels(width: 640, height: 480))
        model.animationWidth = 800
        model.animationHeight = 600
        #expect(model.settings.options.mp4H264.common.size == .pixels(width: 800, height: 600))
        model.animationUsesPixels = false
        #expect(model.settings.options.mp4H264.common.size == .scale(1))
        #expect(model.animationUsesDocumentFPS && model.animationFPS == 12)
        model.animationUsesDocumentFPS = false
        model.animationFPS = 30
        #expect(model.settings.options.mp4H264.common.fps == 30 && !model.animationUsesDocumentFPS)
        model.animationUsesDocumentFPS = true
        #expect(model.settings.options.mp4H264.common.fps == nil)
        #expect(model.animationLoop == .document && model.animationLoopCount == 1)
        model.animationLoop = .forever
        #expect(model.animationLoop == .forever)
        model.animationLoop = .count
        model.animationLoopCount = 3
        #expect(model.animationLoop == .count && model.settings.options.mp4H264.common.loop == .count(3))
        model.animationLoopCount = 0
        #expect(model.animationLoopCount == 1)
        model.animationLoop = .document
        #expect(model.settings.options.mp4H264.common.loop == .document)
        for choice in [AnimationBackgroundChoice.pageColor, .white, .transparent, .document] {
            model.animationBackground = choice
            #expect(model.animationBackground == choice)
        }
        model.animationPages = "2-3"
        #expect(model.settings.options.mp4H264.common.pages == [1, 2] && model.animationPages == "2, 3")
        model.animationPages = ""
        #expect(model.settings.options.mp4H264.common.pages == nil && model.animationPages == "")

        #expect(model.pdfInteractiveAllowed && model.pdfStandardNote == nil && !model.pdfPasswordsAsked)
        model.settings.options.pdf.standard = .pdfX1a2001
        #expect(!model.pdfInteractiveAllowed && model.pdfStandardNote?.contains("CMYK") == true)
        model.settings.options.pdf.standard = .pdfX4_2010
        #expect(model.pdfStandardNote?.contains("bleed box") == true)
        model.settings.asksPermissionsPassword = true
        #expect(model.pdfPasswordsAsked)
        #expect(ExportChoices.pdfVersions.count == 5 && ExportChoices.svgUnits.map(\.value) == ["pt", "px", "mm", "in"])
        #expect(ExportContext.syncNote(.saved, lastSynced: nil) == nil)
        #expect(ExportContext.syncNote(.offline(2), lastSynced: nil) == "Offline — changes from others can't be included")
        #expect(ExportContext.syncNote(.offline(0), lastSynced: Date())?.hasPrefix("Offline — changes from others since ") == true)
        #expect(ExportContext.syncNote(.needsReview, lastSynced: nil)?.contains("merge to review") == true)
    }

    @Test func theSheetAndEveryOptionsFormRender() {
        let suite = TestDefaults()
        defer { suite.remove() }
        let context = ExportContext(title: "C", pages: [Rect(x: 0, y: 0, width: 612, height: 792)], currentPage: 0,
                                    selectionBounds: Rect(x: 0, y: 0, width: 5, height: 5), syncNote: "Offline", missing: ["photo.png"])
        let model = Self.model(ExportSettings(format: .png, what: .range, range: "5"), context: context, suite: suite)
        model.choosePreset("shipped.png-scales")
        model.settings.what = .range
        model.settings.range = "9"
        AttributeFixture.render(ExportAccessory(model: model))
        model.settings.range = "1"
        AttributeFixture.render(ExportAccessory(model: model))
        var pdf = ExportSettings(format: .pdf)
        pdf.options.pdf.standard = .pdfX4_2010
        pdf.asksOpenPassword = true
        AttributeFixture.render(ExportOptionsSheet(model: Self.model(pdf, suite: suite)))
        let everyFormat: [(ExportFormat, (inout ExportFormatOptions) -> Void)] = [
            (.illustrator, { _ in }), (.eps, { _ in }), (.svg, { _ in }), (.dxf, { _ in }), (.jpeg, { _ in }), (.webp, { _ in }), (.heic, { _ in }),
            (.avif, { _ in }), (.gif, { _ in }), (.tiff, { $0.tiff.bits = 8 }), (.tiff, { _ in }), (.psd, { _ in }), (.bmp, { _ in }), (.targa, { _ in }),
            (.png, { $0.png.bits = 8 }), (.png, { _ in }), (.animatedGIF, { _ in }), (.apng, { _ in }), (.mp4H264, { $0.mp4H264.common.fps = 24 }),
            (.mp4HEVC, { $0.mp4HEVC.common.size = .pixels(width: 10, height: 10); $0.mp4HEVC.common.loop = .count(2) }), (.rtf, { _ in }), (.text, { _ in }),
        ]
        for (format, change) in everyFormat {
            var settings = ExportSettings(format: format)
            change(&settings.options)
            AttributeFixture.render(ExportOptionsSheet(model: Self.model(settings, suite: suite)))
        }
        let activity = ExportActivity(title: "Exporting", reportsProgress: true)
        AttributeFixture.render(ExportProgressView(activity: activity), width: 400, height: 40)
        AttributeFixture.render(ExportProgressView(activity: ExportActivity(title: "Exporting", reportsProgress: false)), width: 400, height: 40)
    }

    // MARK: Exporting

    @Test func pagesRangesSelectionsAndTheOutputAreaWriteTheirFileSets() async throws {
        let world = ExportWorld()
        defer { world.close() }
        let objects = await world.threePages()
        await world.document.settle()
        // The current page.
        let one = await world.controller.run(ExportSettings(format: .png), to: world.output.appending(path: "Page.png"), from: world.window)
        guard case .exported(let summary) = one else { Issue.record("\(one)"); return }
        #expect(summary.files.map(\.lastPathComponent) == ["Page.png"] && world.files == ["Page.png"])
        #expect(world.read("Page.png").hasPrefix("page 0.0 0.0 612.0 792.0 1"))
        // Every page, each its own file named by the pattern.
        _ = await world.controller.run(ExportSettings(format: .png, what: .allPages), to: world.output.appending(path: "All.png"), from: world.window)
        #expect(world.files.contains("All-1.png") && world.files.contains("All-3.png"))
        // A range.
        _ = await world.controller.run(ExportSettings(format: .png, what: .range, range: "3, 1", namePattern: "{name}-{page:2}"),
                                       to: world.output.appending(path: "Range.png"), from: world.window)
        #expect(world.files.contains("Range-01.png") && world.files.contains("Range-02.png"))
        #expect(world.read("Range-01.png").hasPrefix("page 1400.0"))
        // The selection, cropped to it.
        world.window.selection.model.set(Selection([SelectionID(objects[1])]))
        _ = await world.controller.run(ExportSettings(format: .png, what: .selection), to: world.output.appending(path: "Selected.png"), from: world.window)
        #expect(world.read("Selected.png").hasPrefix("page 710.0 10.0"))
        // The output area.
        world.controller.outputArea = { _ in Rect(x: 0, y: 0, width: 50, height: 50) }
        _ = await world.controller.run(ExportSettings(format: .text, what: .outputArea), to: world.output.appending(path: "Area.txt"), from: world.window)
        #expect(world.read("Area.txt").hasPrefix("page 0.0 0.0 50.0 50.0"))
        // Without the page boundary the page is trimmed to its artwork.
        _ = await world.controller.run(ExportSettings(format: .png, includePageBoundary: false), to: world.output.appending(path: "Trim.png"), from: world.window)
        #expect(world.read("Trim.png").hasPrefix("page 10.0 10.0"))
        #expect(world.alerts.isEmpty && world.opened.isEmpty && world.revealed.isEmpty)
    }

    @Test func theExportIsTheDocumentAtTheInstantItStarted() async throws {
        let world = ExportWorld(delay: 0.5)
        defer { world.close() }
        _ = await world.threePages()
        let target = world.output.appending(path: "Snapshot.png")
        let export = Task { await world.controller.run(ExportSettings(format: .png), to: target, from: world.window) }
        #expect(await eventually { world.controller.activities[world.document.id] != nil })
        // A change arriving during the export reaches the model, not the file being written.
        let layer = await world.document.perform(CreateLayer(name: "Late")).value?.createdNodes.first
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [Appearances.basicFill(red: 0, green: 0, blue: 1)]
        _ = await world.document.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 5, height: 5), appearance: appearance, layer: layer)).value
        #expect(ExportProgressBar.identifier.rawValue == "export.progress")
        #expect(await eventually { world.window.window?.titlebarAccessoryViewControllers.contains { $0.identifier == ExportProgressBar.identifier } == true })
        guard case .exported = await export.value else { Issue.record("not exported"); return }
        #expect(world.read("Snapshot.png").hasSuffix(" 1\n"), "one layer at the instant of export")
        #expect(LayerOrder(world.document.state).layers.count == 2, "the change is in the model")
        #expect(world.window.window?.titlebarAccessoryViewControllers.contains { $0.identifier == ExportProgressBar.identifier } == false)
        ExportProgressBar.detach(from: nil)
        ExportProgressBar.attach(ExportActivity(title: "t", reportsProgress: false), to: nil)
    }

    @Test func cancellingAMultiPageExportLeavesNoFiles() async throws {
        let world = ExportWorld(delay: 0.3)
        defer { world.close() }
        _ = await world.threePages()
        let export = Task { await world.controller.run(ExportSettings(format: .png, what: .allPages), to: world.output.appending(path: "Pages.png"), from: world.window) }
        #expect(await eventually { world.controller.activities[world.document.id] != nil })
        let activity = try #require(world.controller.activities[world.document.id])
        world.controller.cancel(world.document.id)
        #expect(activity.isCancelled)
        #expect(await export.value == .cancelled)
        #expect(world.files.isEmpty && world.alerts.isEmpty)
        // Cancelling the task running the export does the same.
        let task = Task { await world.controller.perform(ExportSettings(format: .png, what: .allPages), to: world.output.appending(path: "Task.png"), from: world.window) }
        #expect(await eventually { world.controller.activities[world.document.id] != nil })
        task.cancel()
        #expect(await task.value == .cancelled && world.files.isEmpty)
    }

    @Test func exportAgainRepeatsWithoutTheSheetUntilTheFileMoves() async throws {
        let world = ExportWorld()
        defer { world.close() }
        _ = await world.threePages()
        // Never exported: Export Again opens the sheet.
        world.saveName = nil
        #expect(await world.controller.exportAgain(world.window) == nil && world.panels.count == 1)
        world.saveName = "Again.png"
        var settings = ExportSettings(format: .png)
        settings.revealInFinder = true
        settings.openWith = "com.example.viewer"
        world.controller.memory.remember(world.document.id, url: world.output.appending(path: "none.png"), written: world.output.appending(path: "none.png"),
                                         settings: settings)
        guard case .exported = await world.controller.export(world.window) else { Issue.record("export"); return }
        #expect(world.panels.count == 2 && world.panels[1].nameFieldStringValue == "Untitled.png" && world.files == ["Again.png"])
        #expect(world.revealed.count == 1 && world.opened.first?.1 == "com.example.viewer")
        try FileManager.default.removeItem(at: world.output.appending(path: "Again.png"))
        try Data().write(to: world.output.appending(path: "Again.png"))
        guard case .exported = await world.controller.exportAgain(world.window) else { Issue.record("again"); return }
        #expect(world.panels.count == 2, "no sheet")
        #expect(world.read("Again.png").hasPrefix("page "))
        // Moved: the sheet opens, prefilled.
        try FileManager.default.moveItem(at: world.output.appending(path: "Again.png"), to: world.output.appending(path: "Elsewhere.png"))
        world.saveName = nil
        #expect(await world.controller.exportAgain(world.window) == nil)
        #expect(world.panels.count == 3 && world.panels[2].allowedContentTypes == [UTType.png])
    }

    @Test func refusalsFailuresNotesAndPasswords() async throws {
        let world = ExportWorld()
        defer { world.close() }
        _ = await world.threePages()
        let target = world.output.appending(path: "Out.png")
        #expect(await world.controller.run(ExportSettings(format: .png, what: .range, range: "7"), to: target, from: world.window)
            == .failed("There is no page 7; the document has 3 pages."))
        #expect(world.alerts.last?.0 == "The export could not be completed.")
        var registry = ExportRegistry(exporters: [])
        world.controller.registry = registry
        #expect(await world.controller.perform(ExportSettings(format: .png), to: target, from: world.window) == .failed("PNG export is not available yet."))
        registry.register(SlowStubExporter(format: .png))
        world.controller.registry = registry
        // Nothing selected is refused; a selection on a non-printing layer exports nothing.
        #expect(await world.controller.perform(ExportSettings(format: .png, what: .selection), to: target, from: world.window)
            == .failed("Select the objects to export first."))
        let background = try #require(await world.document.perform(CreateLayer(name: "Background")).value?.createdNodes.first)
        _ = await world.document.perform(SetLayerFlag([background], .printing, false)).value
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [Appearances.basicFill(red: 0, green: 1, blue: 0)]
        let hidden = try #require(await world.document.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 5, height: 5), appearance: appearance,
                                                                           layer: background)).value?.createdObjects.first)
        world.window.selection.model.set(Selection([SelectionID(hidden)]))
        #expect(await world.controller.perform(ExportSettings(format: .png, what: .selection), to: target, from: world.window)
            == .failed("There is nothing to export."))
        world.window.selection.model.set(Selection())
        // A folder that cannot be written to.
        #expect(await world.controller.perform(ExportSettings(format: .png), to: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.png"), from: world.window)
            .isFailure)

        // Passwords a preset flagged are asked for; cancelling cancels the export.
        world.controller.registry = .standard
        var pdf = ExportSettings(format: .pdf)
        pdf.asksOpenPassword = true
        pdf.asksPermissionsPassword = true
        #expect(await world.controller.perform(pdf, to: world.output.appending(path: "Locked.pdf"), from: world.window) == .cancelled)
        world.passwords = ["open"]
        #expect(await world.controller.perform(pdf, to: world.output.appending(path: "Locked.pdf"), from: world.window) == .cancelled)
        world.passwords = ["open", "owner"]
        guard case .exported(let summary) = await world.controller.perform(pdf, to: world.output.appending(path: "Locked.pdf"), from: world.window) else {
            Issue.record("pdf")
            return
        }
        #expect(world.asked.count == 5 && CGPDFDocument(summary.files[0] as CFURL)?.isEncrypted == true)

        // A placed file whose blobs are not here is a placeholder, named in the summary.
        var placed = Wiretuner_Doc_V1_NodeProps()
        placed.placedFile.content.format = .eps
        placed.placedFile.content.blobSha256 = Data(repeating: 0x42, count: 32)
        placed.placedFile.content.previewSha256 = Data(repeating: 0x43, count: 32)
        placed.placedFile.content.sourceName = "art.eps"
        placed.placedFile.content.bounds.width = 40
        placed.placedFile.content.bounds.height = 30
        let layer = try #require(LayerOrder(world.document.state).layers.last?.id)
        _ = await world.document.perform(OpsCommand("Place", ops: [Ops.create(parent: layer, position: [0xF0], props: placed)])).value
        #expect(world.controller.context(for: world.window).missing == ["art.eps"])
        _ = await world.controller.run(ExportSettings(format: .svg), to: world.output.appending(path: "Placed.svg"), from: world.window)
        #expect(world.alerts.last?.0 == "The export is done, with notes." && world.alerts.last?.1.contains("art.eps") == true)
    }

    @Test func realFormatsAnimationsAndTheEmbeddedPackageRoundTrip() async throws {
        let world = ExportWorld()
        defer { world.close() }
        let objects = await world.threePages()
        world.controller.registry = .standard
        world.controller.account = { ("account-1", "Pat") }
        // An animated GIF with progress.
        _ = await world.document.perform(SetAnimationSettings(source: .pages, fps: 4)).value
        var gif = ExportSettings(format: .animatedGIF)
        gif.options.animatedGIF.common.size = .pixels(width: 30, height: 40)
        guard case .exported(let animation) = await world.controller.perform(gif, to: world.output.appending(path: "Motion.gif"), from: world.window) else {
            Issue.record("gif")
            return
        }
        let source = try #require(CGImageSourceCreateWithURL(animation.files[0] as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        // Rich text of the pages.
        _ = await world.document.perform(CreateTextBlock(.point(Point(x: 20, y: 40)), text: "Spring")).value
        guard case .exported(let text) = await world.controller.perform(ExportSettings(format: .text), to: world.output.appending(path: "Words.txt"), from: world.window) else {
            Issue.record("text")
            return
        }
        #expect((try? String(contentsOf: text.files[0], encoding: .utf8))?.contains("Spring") == true)

        // A PDF with the document embedded reopens as the original through Open File….
        var pdf = ExportSettings(format: .pdf, what: .allPages)
        pdf.options.pdf.embedPackage = true
        guard case .exported(let exported) = await world.controller.perform(pdf, to: world.output.appending(path: "Round.pdf"), from: world.window) else {
            Issue.record("pdf")
            return
        }
        let packages = PackageCommandTests.Packages(world.world)
        packages.controller.runOpenPanel = { _, _ in exported.files }
        let reopened = try #require(await packages.controller.openPackage())
        let order = LayerOrder(reopened.state)
        #expect(order.layers.flatMap { order.objects(on: $0.id, in: reopened.state) }.count == objects.count + 1)
        #expect(reopened.title == "Untitled")
    }

    // MARK: The panel, the commands and the app

    @Test func thePanelFollowsTheFormatShowsOptionsAndRefusesWithTheReason() throws {
        let world = ExportWorld()
        defer { world.close() }
        let model = ExportSheetModel(context: world.controller.context(for: world.window), settings: ExportSettings(format: .pdf),
                                     presets: world.controller.presets, registry: .standard)
        let panel = world.controller.makePanel(model)
        #expect(panel.prompt == "Export" && panel.allowedContentTypes == [UTType.pdf] && panel.nameFieldStringValue == "Untitled.pdf")
        #expect(panel.accessoryView != nil && panel.delegate is ExportPanelDelegate)
        model.settings.format = .svg
        #expect(panel.allowedContentTypes == [ExportFormat.svg.utType] && panel.nameFieldStringValue == "Untitled.svg")
        let delegate = try #require(panel.delegate as? ExportPanelDelegate)
        try delegate.panel(panel, validate: world.output.appending(path: "a.svg"))
        model.settings.what = .range
        #expect(throws: NSError.self) { try delegate.panel(panel, validate: world.output.appending(path: "a.svg")) }
        model.showOptions()
        #expect(panel.attachedSheet?.title == "SVG Options")
        model.closeOptions()
        #expect(panel.attachedSheet == nil)
        let (alert, field) = PasswordPrompt.alert("Type it")
        field.stringValue = "pw"
        #expect(alert.informativeText == "Type it" && PasswordPrompt.answer(.alertFirstButtonReturn, field) == "pw")
        #expect(PasswordPrompt.answer(.alertSecondButtonReturn, field) == nil)
        ExportController.open([], in: "com.example.no-such-application-\(UUID().uuidString)")
        (world.window.syncStatus as? StubSyncStatus)?.state = .needsReview
        #expect(world.controller.context(for: world.window).syncNote?.contains("merge") == true)
    }

    @Test func theCommandsRunTheControllerForTheFrontWindow() async throws {
        let world = ExportWorld()
        defer { world.close() }
        let recorder = CommandRecorder()
        let hooks = ExportCommands.Hooks(window: { recorder.front }, export: { recorder.exported.append($0) }, exportAgain: { recorder.again.append($0) })
        let commands = ExportCommands.commands(hooks)
        #expect(commands.map(\.id) == [ExportCommands.ID.export, ExportCommands.ID.exportAgain])
        #expect(commands[0].defaultKey == KeyEquivalent("r", [.command, .shift]) && commands[1].defaultKey == KeyEquivalent("r", [.command, .option, .shift]))
        #expect(commands.allSatisfy { $0.validation() == .disabled(ExportCommands.noDocument) })
        recorder.front = world.window
        #expect(commands.allSatisfy { $0.validation() == .enabled })
        for command in commands {
            if case .perform(let run) = command.action { run() }
        }
        #expect(recorder.exported.count == 1 && recorder.again.count == 1)
        let registry = CommandRegistry()
        ExportCommands.install(into: registry, hooks: ExportCommands.hooks(exports: world.controller) { [weak window = world.window] in window })
        world.saveName = nil
        if case .perform(let run)? = registry.command(ExportCommands.ID.export)?.action { run() }
        #expect(await eventually { world.panels.count == 1 })
        if case .perform(let run)? = registry.command(ExportCommands.ID.exportAgain)?.action { run() }
        #expect(await eventually { world.panels.count == 2 })
    }

    @Test func pdfAndEPSFilesOpenAsTheirPackageOrThroughTheImporter() async throws {
        let world = ExportWorld()
        defer { world.close() }
        let packages = PackageCommandTests.Packages(world.world)
        #expect(PackageController.opens(URL(fileURLWithPath: "/a/b.PDF")) && PackageController.opens(URL(fileURLWithPath: "/a/b.wiretuner")))
        #expect(!PackageController.opens(URL(fileURLWithPath: "/a/b.png")) && !PackageController.opens(URL(string: "https://example.com/a.pdf")!))
        #expect(PackageController.openableTypes.contains(.pdf))
        // A PDF without a package falls through to the importer.
        let plain = world.world.files.write("Plain.pdf", Self.pdf())
        var imported: [URL] = []
        packages.controller.importAsDocument = { url in
            imported.append(url)
            return nil
        }
        #expect(await packages.controller.openFile(plain) == nil && imported == [plain])
        // An unreadable file and a package that is damaged are refused.
        #expect(await packages.controller.openFile(world.world.files.directory.appending(path: "Missing.eps")) == nil)
        #expect(packages.alerts.last?.0 == "“Missing.eps” could not be opened.")
        // A package opens as itself.
        let url = world.world.files.directory.appending(path: "Doc.wiretuner")
        let contents = DocumentPackage.contents(of: EngineState(), info: DocumentPackage.Info(documentID: "d", title: "Doc"), page: Pasteboard.letterPage) { _ in nil }
        _ = try PackageWriter().write(contents, to: url)
        #expect(await packages.controller.openFile(url)?.title == "Doc")

        // The app's fallback opens the file as a new document named after it (IO-040).
        let opener = ForeignFileOpener(imports: world.world.imports)
        opener.createDocument = { title, template in
            world.world.documents.open(world.world.documents.environment.makeDocument(title: title, isNew: true, template: template), show: false).documentHandle
        }
        let document = try #require(await opener.open(plain))
        #expect(document.title == "Plain" && world.world.documents.windowControllers[document.id] != nil)
        #expect(PageList(document.state).pages.count == 1)
        world.world.documents.close(document.id)
    }

    @Test func theAppWiresTheExportCommandsAndOpensPDFsFromTheFinder() async throws {
        let suite = TestDefaults()
        let server = FakeLibraryServer()
        let library = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, library: library)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
            suite.remove()
        }
        #expect(delegate.commands.command(ExportCommands.ID.export)?.title == "Export…")
        #expect(delegate.commands.command(ExportCommands.ID.exportAgain)?.validation() == .enabled)
        #expect(delegate.exports.account() == ("", ""))
        var alerts: [String] = []
        delegate.packages.showAlert = { message, _, _ in alerts.append(message) }
        #expect(delegate.open(URL(fileURLWithPath: "/tmp/nothing-\(UUID().uuidString).pdf")))
        #expect(await eventually { alerts.count == 1 })
        let directory = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = directory.appending(path: "Flyer.pdf")
        try Self.pdf().write(to: plain)
        let before = delegate.documents.documents.count
        #expect(await delegate.packages.importAsDocument(plain)?.title == "Flyer")
        #expect(delegate.documents.documents.count == before + 1)
    }

    /// A one-page PDF with a filled square and no attachment.
    static func pdf() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 40, height: 40))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

/// What the command hooks were asked to do.
@MainActor
final class CommandRecorder {
    var front: DocumentWindowController?
    var exported: [DocumentWindowController] = []
    var again: [DocumentWindowController] = []
}

extension ExportOutcome {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
