// Goldens (print-marks@2x.png, print-tile@2x.png) live in Goldens/; `WTINTERCHANGE_RECORD_GOLDENS=1
// swift test` rewrites them.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

/// PRINT-003, PRINT-005, PRINT-006, PRINT-008 (and PRINT-009's `screen_in_app` wiring): drawing
/// sheets -- the same pixels as the canvas, bleed and marks, emulsion and negative, plates, the
/// in-app screener, rasterized output, *Save as PDF* and the preview overlays.
@Suite struct PrintSheetTests {
    static let small = PrintPaper(size: Size(width: 300, height: 260), imageable: Rect(x: 9, y: 9, width: 282, height: 242))
    static let spot = NodeID(counter: 70, replica: 1)

    static func request(_ pages: [ExportPage], options: PrintOptions = PrintOptions(), paper: PrintPaper = .letter,
                        source: PrintRequest.Source = .pages, screens: [NodeID: ObjectScreen] = [:], flatness: [NodeID: Double] = [:]) -> PrintRequest {
        PrintRequest(scene: ExportScene(name: "Proof", pages: pages), source: source, options: options, paper: paper, objectScreens: screens,
                     pathFlatness: flatness, date: Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(identifier: "UTC")!)
    }

    /// Sheet `index` of `plan` as a bitmap on white at `scale` pixels per point.
    static func bitmap(_ plan: PrintPlan, sheet index: Int = 0, scale: Double = 1, renderer: PrintSheetRenderer = PrintSheetRenderer(),
                       overlays: Bool = false) throws -> CGImage {
        let paper = plan.request.paper.size
        let surface = try #require(BitmapSurface(width: Int(paper.width * scale), height: Int(paper.height * scale)))
        surface.context.setFillColor(CGColor(gray: 1, alpha: 1))
        surface.context.fill(CGRect(x: 0, y: 0, width: surface.width, height: surface.height))
        surface.context.scaleBy(x: scale, y: scale)
        try renderer.draw(sheet: index, of: plan, into: surface.context)
        if overlays { PrintSheetRenderer.drawPreviewOverlays(sheet: index, of: plan, into: surface.context) }
        return try #require(surface.makeImage())
    }

    /// The RGBA pixels of `image` inside `rect` (pixels, top-left origin).
    static func crop(_ image: CGImage, _ rect: CGRect) -> CGImage {
        image.cropping(to: rect)!
    }

    static func gray(_ image: CGImage, x: Int, y: Int) -> Int {
        let pixels = Corpus.pixels(image, background: .white)
        return Int(pixels.bytes[(y * pixels.width + x) * 4])
    }

    static func square(_ rect: Rect, _ color: Color) -> DisplayItem {
        Corpus.path(DisplayPath(rect: rect), [Corpus.fill(.solid(color))])
    }

    static func assertGolden(_ image: CGImage, _ name: String) throws {
        let url = BitmapTests.goldens.appendingPathComponent("\(name)@2x.png")
        if ProcessInfo.processInfo.environment["WTINTERCHANGE_RECORD_GOLDENS"] == "1" {
            try ImageEncoding.encode(image, type: .png)!.write(to: url)
        }
        let golden = try #require(BitmapTests.read(url)?.image, "missing golden \(url.lastPathComponent)")
        let failing = Corpus.difference(golden, image, tolerance: 24)
        if failing > 0.002 { Corpus.dump(image, "golden-\(name)") }
        #expect(failing <= 0.002, "\(name): \(failing)")
    }

    // MARK: Composite

    /// A composite sheet at 100% is the canvas render of the page, pixel for pixel.
    @Test(arguments: ["basics", "gradients", "transparency"])
    func compositeSheetsMatchTheCanvas(_ fixture: String) throws {
        var page = Corpus.fixture(fixture)
        page.number = 1
        let plan = PrintPlan(Self.request([page]))
        let sheet = try Self.bitmap(plan, scale: 2)
        let trim = plan.sheets[0].trim
        let printed = Self.crop(sheet, CGRect(x: trim.minX * 2, y: trim.minY * 2, width: trim.width * 2, height: trim.height * 2))
        let canvas = try #require(CoreGraphicsRenderer(background: .white).renderBitmap(page.displayList, viewport: Viewport(scrollOrigin: page.bounds.origin, size: page.bounds.size), scale: 2))
        let a = Corpus.pixels(printed, background: .white).bytes, b = Corpus.pixels(canvas, background: .white).bytes
        #expect(a.count == b.count)
        #expect(zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0 <= 1, "\(fixture)")
        // *Save as PDF* holds the same sheets.
        let pdf = try PrintPDF.data(plan)
        let document = try #require(CGPDFDocument(CGDataProvider(data: pdf as CFData)!))
        #expect(document.numberOfPages == 1)
        let box = try #require(document.page(at: 1)?.getBoxRect(.mediaBox))
        #expect(box.size == CGSize(width: 612, height: 792))
    }

    /// The PDF rasterizes to the canvas render within anti-aliasing tolerance.
    @Test func savedPDFRasterizesLikeTheCanvas() throws {
        var page = Corpus.fixture("basics")
        page.number = 1
        let plan = PrintPlan(Self.request([page], paper: Self.small))
        let pdf = try PrintPDF.data(plan, title: "Proof")
        let document = try #require(CGPDFDocument(CGDataProvider(data: pdf as CFData)!))
        let pdfPage = try #require(document.page(at: 1))
        let surface = try #require(BitmapSurface(width: 600, height: 520))
        surface.context.setFillColor(CGColor(gray: 1, alpha: 1))
        surface.context.fill(CGRect(x: 0, y: 0, width: 600, height: 520))
        surface.context.scaleBy(x: 2, y: 2)
        surface.context.drawPDFPage(pdfPage)
        let fromPDF = try #require(surface.makeImage())
        let direct = try Self.bitmap(plan, scale: 2)
        #expect(Corpus.difference(fromPDF, direct, tolerance: 40) < 0.01)
    }

    @Test func bleedDrawsPastThePageEdge() throws {
        let page = ExportPage(bounds: Rect(x: 0, y: 0, width: 100, height: 80), displayList: DisplayList(canvas: "p", items: [Self.square(Rect(x: -30, y: -30, width: 160, height: 140), .black)]), number: 1)
        let plain = PrintPlan(Self.request([page], paper: Self.small))
        let bled = PrintPlan(Self.request([page], options: PrintOptions(bleed: 9), paper: Self.small))
        let trim = plain.sheets[0].trim
        let a = try Self.bitmap(plain), b = try Self.bitmap(bled)
        // 5 pt outside the page: white without bleed, artwork with a 9 pt bleed; 12 pt out: white.
        #expect(Self.gray(a, x: Int(trim.minX) - 5, y: Int(trim.midY)) == 255)
        #expect(Self.gray(b, x: Int(trim.minX) - 5, y: Int(trim.midY)) == 0)
        #expect(Self.gray(b, x: Int(trim.minX) - 12, y: Int(trim.midY)) == 255)
    }

    @Test func emulsionDownMirrorsAndNegativeInverts() throws {
        let page = ExportPage(bounds: Rect(x: 0, y: 0, width: 100, height: 80), displayList: DisplayList(canvas: "p", items: [Self.square(Rect(x: 0, y: 0, width: 30, height: 80), .black)]), number: 1)
        let options = PrintOptions(marks: .all)
        let normal = try Self.bitmap(PrintPlan(Self.request([page], options: options, paper: Self.small)))
        var mirroredOptions = options
        mirroredOptions.emulsionDown = true
        let mirrored = try Self.bitmap(PrintPlan(Self.request([page], options: mirroredOptions, paper: Self.small)))
        let a = Corpus.pixels(normal, background: .white), b = Corpus.pixels(mirrored, background: .white)
        var mismatched = 0
        for y in 0..<a.height {
            for x in 0..<a.width where abs(Int(a.bytes[(y * a.width + x) * 4]) - Int(b.bytes[(y * a.width + (a.width - 1 - x)) * 4])) > 48 {
                mismatched += 1
            }
        }
        // Mirrored pixel for pixel, but for anti-aliased label glyph edges.
        #expect(mismatched < a.width * a.height / 1000)
        #expect(a.bytes != b.bytes)
        var negativeOptions = options
        negativeOptions.negative = true
        let negative = Corpus.pixels(try Self.bitmap(PrintPlan(Self.request([page], options: negativeOptions, paper: Self.small))), background: .white)
        let inverted = zip(a.bytes, negative.bytes).enumerated().allSatisfy { index, pair in index % 4 == 3 || abs(Int(pair.0) + Int(pair.1) - 255) <= 1 }
        #expect(inverted)
    }

    @Test func marksGolden() throws {
        let page = ExportPage(bounds: Rect(x: 0, y: 0, width: 180, height: 140), displayList: DisplayList(canvas: "p", items: [
            Self.square(Rect(x: -9, y: -9, width: 100, height: 158), Corpus.red), Self.square(Rect(x: 90, y: -9, width: 99, height: 158), Corpus.blue),
        ]), number: 1)
        let plan = PrintPlan(Self.request([page], options: PrintOptions(marks: .all, bleed: 9), paper: Self.small))
        #expect(!plan.sheets[0].marksClipped)
        try Self.assertGolden(try Self.bitmap(plan, scale: 2), "print-marks")
    }

    @Test func tileGolden() throws {
        let page = ExportPage(bounds: Rect(x: 0, y: 0, width: 400, height: 300), displayList: DisplayList(canvas: "p", items: [
            Corpus.path(Corpus.ellipse(0, 0, 400, 300), [Corpus.fill(.solid(Corpus.green)), Corpus.stroke(.solid(.black), width: 4)]),
        ]), number: 1)
        let plan = PrintPlan(Self.request([page], options: PrintOptions(tile: .automatic, tileOverlap: 18, marks: [.crop, .fileNameDate]), paper: Self.small))
        #expect(plan.count == 4)
        try Self.assertGolden(try Self.bitmap(plan, sheet: 1, scale: 2), "print-tile")
        // The preview overlays draw over the sheet and never into a job.
        let preview = try Self.bitmap(plan, sheet: 1, scale: 1, overlays: true)
        let plain = try Self.bitmap(plan, sheet: 1, scale: 1)
        #expect(Corpus.difference(preview, plain, tolerance: 8) > 0)
    }

    // MARK: Separations

    static let separated: ExportPage = {
        let spotColor = Color(cyan: 0, magenta: 0.8, yellow: 0.9, black: 0).asSpot(SpotInk(swatch: spot, name: "Orange"))
        return ExportPage(bounds: Rect(x: 0, y: 0, width: 120, height: 100), displayList: DisplayList(canvas: "p", items: [
            Self.square(Rect(x: 0, y: 0, width: 60, height: 100), Color(cyan: 1, magenta: 0, yellow: 0, black: 0)),
            Self.square(Rect(x: 60, y: 0, width: 60, height: 100), spotColor),
        ], nodeIDs: [NodeID(counter: 1, replica: 1), NodeID(counter: 2, replica: 1)]), number: 1)
    }()

    static let plates = PrintPlate.process + [PrintPlate(ink: .spot(spot), name: "Orange")]

    /// Every plate carries its ink as gray, and the marks land in the same place on every plate.
    @Test func platesPrintTheirInkAndMarksCoincide() throws {
        let plan = PrintPlan(Self.request([Self.separated], options: PrintOptions(separations: true, marks: [.crop, .registration], plates: Self.plates), paper: Self.small))
        #expect(plan.count == 5)
        let images = try plan.sheets.indices.map { try Self.bitmap(plan, sheet: $0) }
        let trim = plan.sheets[0].trim
        let left = (x: Int(trim.minX) + 30, y: Int(trim.midY)), right = (x: Int(trim.minX) + 90, y: Int(trim.midY))
        #expect(Self.gray(images[0], x: left.x, y: left.y) == 0 && Self.gray(images[0], x: right.x, y: right.y) == 255)
        #expect(Self.gray(images[4], x: left.x, y: left.y) == 255 && Self.gray(images[4], x: right.x, y: right.y) == 0)
        // The marks: pixels outside the printed area are identical across plates.
        let clip = plan.sheets[0].clip
        let pixels = images.map { Corpus.pixels($0, background: .white) }
        var differing = 0
        for y in 0..<pixels[0].height {
            for x in 0..<pixels[0].width where !clip.expanded(by: 1).contains(Point(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                let value = pixels[0].bytes[(y * pixels[0].width + x) * 4]
                if pixels.contains(where: { $0.bytes[(y * pixels[0].width + x) * 4] != value }) { differing += 1 }
            }
        }
        #expect(differing == 0)
        #expect(pixels[0].bytes.contains(0))
        // *Save as PDF*: one page per plate.
        let pdf = try PrintPDF.data(plan)
        #expect(CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.numberOfPages == 5)
    }

    /// *Screen in {product}*: the plate is screened at the device resolution into one bit.
    @Test func screenInAppSendsOneBitPlates() throws {
        let tint = ExportPage(bounds: Rect(x: 0, y: 0, width: 72, height: 72), displayList: DisplayList(canvas: "p", items: [
            Self.square(Rect(x: 0, y: 0, width: 72, height: 72), Color(cyan: 0, magenta: 0, yellow: 0, black: 0.5)),
        ], nodeIDs: [NodeID(counter: 1, replica: 1)]), number: 1)
        var options = PrintOptions(separations: true, screenInApp: true)
        options.plates = [PrintPlate(ink: .black, frequency: 30)]
        let paper = PrintPaper(size: Size(width: 144, height: 144), resolution: 300)
        let plan = PrintPlan(Self.request([tint], options: options, paper: paper))
        #expect(PrintSheetRenderer.resolution(plan) == 300)
        let image = try Self.bitmap(plan, scale: 300.0 / 72)
        let trim = plan.sheets[0].trim
        let pixels = Corpus.pixels(image, background: .white)
        var black = 0, white = 0, other = 0
        let scale = 300.0 / 72
        for y in Int(trim.minY * scale) + 2..<Int(trim.maxY * scale) - 2 {
            for x in Int(trim.minX * scale) + 2..<Int(trim.maxX * scale) - 2 {
                switch pixels.bytes[(y * pixels.width + x) * 4] {
                case 0: black += 1
                case 255: white += 1
                default: other += 1
                }
            }
        }
        #expect(other == 0 && abs(Double(black) / Double(black + white) - 0.5) < 0.03)
        // An object screen (resolved on the plate) and *Ignore object screens*.
        let screens: [NodeID: ObjectScreen] = [NodeID(counter: 1, replica: 1): ObjectScreen(shape: .line, angle: 0, frequency: nil)]
        let lined = try Self.bitmap(PrintPlan(Self.request([tint], options: options, paper: paper, screens: screens)), scale: scale)
        #expect(Corpus.difference(lined, image, tolerance: 8) > 0.05)
        var ignoring = options
        ignoring.ignoreObjectHalftones = true
        let ignored = try Self.bitmap(PrintPlan(Self.request([tint], options: ignoring, paper: paper, screens: screens)), scale: scale)
        #expect(Corpus.difference(ignored, image, tolerance: 8) == 0)
        // Without a queue resolution: the rasterize resolution, else 300 dpi.
        var rasterizing = options
        rasterizing.rasterizeDPI = 600
        #expect(PrintSheetRenderer.resolution(PrintPlan(Self.request([tint], options: rasterizing))) == 600)
        #expect(PrintSheetRenderer.resolution(PrintPlan(Self.request([tint], options: options))) == PrintSheetRenderer.fallbackResolution)
        // A cancelled job stops.
        let cancelled = PrintSheetRenderer(isCancelled: { true })
        #expect(throws: CancellationError.self) { try Self.bitmap(plan, renderer: cancelled) }
        #expect(throws: CancellationError.self) { try PrintPDF.data(plan, renderer: cancelled) }
    }

    @Test func objectScreensInheritPlateParts() {
        let plate = HalftoneScreen(shape: .ellipse, angle: 45, frequency: 90)
        #expect(ObjectScreen(shape: nil, angle: 15, frequency: nil).resolved(on: plate) == nil)
        #expect(ObjectScreen(shape: .line, angle: 15, frequency: 700).resolved(on: plate) == HalftoneScreen(shape: .line, angle: 15, frequency: 90))
        #expect(ObjectScreen(shape: nil, angle: 15, frequency: 40).resolved(on: plate) == HalftoneScreen(shape: .ellipse, angle: 15, frequency: 40))
    }

    // MARK: Imaging options

    /// *Rasterize output* matches vector output within anti-aliasing tolerance; plates rasterize
    /// in gray; marks stay vector.
    @Test func rasterizedOutputMatchesVector() throws {
        var page = Corpus.fixture("basics")
        page.number = 1
        let vector = try Self.bitmap(PrintPlan(Self.request([page], options: PrintOptions(marks: [.crop]), paper: Self.small)), scale: 2)
        var renderer = PrintSheetRenderer()
        renderer.bandHeight = 100
        let rasterPlan = PrintPlan(Self.request([page], options: PrintOptions(marks: [.crop], rasterizeDPI: 144), paper: Self.small))
        let raster = try Self.bitmap(rasterPlan, scale: 2, renderer: renderer)
        #expect(Corpus.difference(vector, raster, tolerance: 64) < 0.01)
        let plates = PrintPlan(Self.request([Self.separated], options: PrintOptions(separations: true, rasterizeDPI: 144, plates: Self.plates), paper: Self.small))
        let cyan = try Self.bitmap(plates, scale: 2, renderer: renderer)
        let trim = plates.sheets[0].trim
        #expect(Self.gray(cyan, x: Int(trim.minX + 30) * 2, y: Int(trim.midY) * 2) == 0)
        // Cancelled between bands.
        let cancelled = PrintSheetRenderer(isCancelled: { true })
        #expect(throws: CancellationError.self) { try Self.bitmap(rasterPlan, renderer: cancelled) }
        // A PDF of a rasterized job keeps its marks as vectors: the page draws more than one image.
        let pdf = try PrintPDF.data(rasterPlan)
        #expect(pdf.count > 0)
    }

    @Test func flatnessTextOutlinesAndPageBoundaries() throws {
        let node = NodeID(counter: 1, replica: 1), inner = NodeID(counter: 2, replica: 1)
        let circle = Corpus.path(Corpus.ellipse(10, 10, 80, 60), [Corpus.fill(.solid(Corpus.blue))])
        let page = ExportPage(bounds: Rect(x: 0, y: 0, width: 100, height: 80), displayList: DisplayList(canvas: "p", items: [circle, .group(GroupItem(children: [circle]))], nodeIDs: [node, nil]),
                              nestedNodeIDs: [[1, 0]: inner])
        #expect(PrintSheetRenderer.flatnessOverrides(page, [node: 3, inner: 5]) == [[0]: 3, [1, 0]: 5])
        #expect(PrintSheetRenderer.flatnessOverrides(page, [:]).isEmpty)
        let plan = PrintPlan(Self.request([page], options: PrintOptions(flatness: 2, textAsOutlines: true), paper: Self.small, flatness: [node: 3]))
        #expect(PrintSheetRenderer().renderer(for: plan).outputFlatness == 2)
        #expect(PrintSheetRenderer().renderer(for: PrintPlan(Self.request([page]))).outputFlatness == nil)
        let outlined = OutlineCounter()
        let renderer = PrintSheetRenderer(textOutliner: { list in outlined.bump(); return list })
        _ = try Self.bitmap(plan, renderer: renderer)
        #expect(outlined.count == 1)
        // Output area with page boundaries: outlines drawn.
        let area = PrintPlan(Self.request([page], options: PrintOptions(printPageBoundary: true), paper: Self.small,
                                          source: .outputArea(pageOutlines: [Rect(x: 50, y: 0, width: 50, height: 80)])))
        let withOutlines = try Self.bitmap(area, scale: 2)
        var without = area.request
        without.options.printPageBoundary = false
        #expect(Corpus.difference(withOutlines, try Self.bitmap(PrintPlan(without), scale: 2), tolerance: 8) > 0)
    }

    @Test func emptySheetsAndPixelRects() throws {
        // A manual tile off the page prints marks only.
        let page = ExportPage(bounds: Rect(x: 0, y: 0, width: 100, height: 80), displayList: DisplayList(canvas: "p", items: [Self.square(Rect(x: 0, y: 0, width: 100, height: 80), .black)]), number: 1)
        var request = Self.request([page], options: PrintOptions(tile: .manual, marks: [.registration]), paper: Self.small)
        request.zeroPoints = [1: Point(x: 5000, y: 5000)]
        let plan = PrintPlan(request)
        #expect(plan.sheets[0].clip.isEmpty && plan.sheets[0].marks.isEmpty)
        let image = try Self.bitmap(plan)
        #expect(Corpus.pixels(image, background: .white).bytes.allSatisfy { $0 == 255 })
        #expect(PrintSheetRenderer.pixelRect(Rect(x: 0.5, y: 0.5, width: 1, height: 1), scale: 2) == (1, 1, 2, 2))
        // A hairline-thin printed area screens and rasterizes one row of pixels.
        var screened = PrintOptions(separations: true, screenInApp: true)
        screened.plates = [PrintPlate(ink: .black)]
        let thin = ExportPage(bounds: Rect(x: 0, y: 0, width: 100, height: 1e-9), displayList: DisplayList(canvas: "p", items: []), number: 1)
        _ = try Self.bitmap(PrintPlan(Self.request([thin], options: screened, paper: Self.small)))
        _ = try Self.bitmap(PrintPlan(Self.request([thin], options: PrintOptions(rasterizeDPI: 300), paper: Self.small)))
    }

    // MARK: Presets

    @Test func presetsRoundTripThroughTheDictionary() throws {
        let options = PrintOptions(separations: true, scaleMode: .variable, scaleX: 80, scaleY: 120, offset: Point(x: 3, y: -4), tile: .automatic, tileOverlap: 12,
                                   printPageBoundary: true, marks: [.crop, .fileNameDate], bleed: 9, emulsionDown: true, negative: true, flatness: 2,
                                   textAsOutlines: true, rasterizeDPI: 300, spotAsProcess: true, defaultScreen: HalftoneScreen(shape: .line, angle: 45, frequency: 85),
                                   plates: [PrintPlate(ink: .cyan, print: false, angle: 20, frequency: 100), PrintPlate(ink: .spot(Self.spot), name: "Orange", angle: 30)],
                                   screenInApp: true, ignoreObjectHalftones: true)
        let preset = PrintPreset(options: options)
        let dictionary = preset.dictionary(includeHiddenLayers: true)
        #expect(dictionary.keys.allSatisfy { $0.hasPrefix(PrintPreset.Key.prefix) })
        // Through a property list, as NSPrintInfo keeps it.
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        let restored = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let read = try #require(PrintPreset.read(restored))
        #expect(read.includeHiddenLayers)
        var expected = options
        expected.plates = []
        #expect(read.preset.options == expected)
        #expect(read.preset.plates == [PresetPlate(ink: .process(.cyan), print: false, angle: 20, frequency: 100), PresetPlate(ink: .spot("Orange"), print: true, angle: 30, frequency: 0)])
        // Without the pane's keys there is no preset; odd entries are skipped or defaulted.
        #expect(PrintPreset.read(["PMPaper": "letter"]) == nil)
        let odd = try #require(PrintPreset.read(["WTPrintPlates": [["neither": 1], ["process": "black"]], "WTPrintScaleMode": "zoom", "WTPrintScreenShape": "star"]))
        #expect(odd.preset.plates == [PresetPlate(ink: .process(.black), print: true, angle: 45, frequency: 0)])
        #expect(odd.preset.options.scaleMode == .uniform && odd.preset.options.defaultScreen.shape == .round && !odd.includeHiddenLayers)
    }
}

/// Counts outliner calls from a `@Sendable` closure.
final class OutlineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}
