// PRINT-015: the print output corpus.  Every option on the Printing, Output devices and Halftones
// pages has at least one case below (the table in `PrintCorpus.cases` names the options each
// exercises).  Each case's job is written through *Save as PDF* (`PrintPDF.data`, what the printer
// would have received), every sheet of that PDF rasterized by Core Graphics at 72 ppi and held to
// its committed reference, `Goldens/PrintCorpus/<case>-<sheet>.png`: at most 0.2% of pixels may
// differ by more than 24/255.  A sheet that drifts fails naming the case, the sheet and its name,
// and writes the fresh rendering and a difference image (changed pixels red over a faded copy of
// the reference) to `$WT_PRINT_CORPUS_OUT` (default `$TMPDIR/WTInterchangeFailures/print-corpus`)
// for CI to upload.  `WTINTERCHANGE_RECORD_GOLDENS=1 swift test --filter PrintCorpusTests` rewrites
// the references.
//
// The composite cases print the REND-001 screen/PDF identity corpus's own pages (`Corpus.fixture`,
// byte for byte the display lists `PDFTests` compares), and their sheets at 100% without marks are
// held to the canvas renderer's pixels as well: the print path adds no rendering of its own.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

enum PrintCorpus {
    struct Case: Sendable, CustomStringConvertible {
        var name: String
        var pages: [ExportPage]
        var options = PrintOptions()
        var paper = PrintCorpus.paper
        var source = PrintRequest.Source.pages
        var range: ClosedRange<Int>?
        var selection: Set<NodeID>?
        var zeroPoints: [Int: Point] = [:]
        var screens: [NodeID: ObjectScreen] = [:]
        var flatness: [NodeID: Double] = [:]
        /// The options this case exercises, as the guide pages name them.
        var exercises: [String]

        var description: String { name }

        var request: PrintRequest {
            PrintRequest(scene: ExportScene(name: "Corpus \(name)", pages: pages), source: source, options: options, paper: paper, pageRange: range,
                         selection: selection, zeroPoints: zeroPoints, objectScreens: screens, pathFlatness: flatness,
                         date: Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(identifier: "UTC")!)
        }
    }

    static let paper = PrintPaper(size: Size(width: 300, height: 260), imageable: Rect(x: 9, y: 9, width: 282, height: 242))
    static let spot = NodeID(counter: 70, replica: 1)
    static let plates = PrintPlate.process + [PrintPlate(ink: .spot(spot), name: "Orange")]
    static let ids = (1...6).map { NodeID(counter: UInt64($0), replica: 1) }

    static func square(_ rect: Rect, _ color: Color, overprint: Bool = false) -> DisplayItem {
        Corpus.path(DisplayPath(rect: rect), [Corpus.fill(.solid(color), overprint: overprint)])
    }

    /// A page for the plates: process CMYK, a spot ink, an overprinting black bar, a curve and
    /// text, each an object.
    static let separated: ExportPage = {
        let orange = Color(cyan: 0, magenta: 0.8, yellow: 0.9, black: 0).asSpot(SpotInk(swatch: spot, name: "Orange"))
        return ExportPage(bounds: Rect(x: 0, y: 0, width: 160, height: 120), displayList: DisplayList(canvas: "p", items: [
            square(Rect(x: 0, y: 0, width: 80, height: 120), Color(cyan: 1, magenta: 0.2, yellow: 0, black: 0)),
            square(Rect(x: 80, y: 0, width: 80, height: 120), orange),
            square(Rect(x: 20, y: 50, width: 120, height: 16), Color(cyan: 0, magenta: 0, yellow: 0, black: 1), overprint: true),
            Corpus.path(Corpus.ellipse(30, 10, 100, 30), [Corpus.stroke(.solid(Color(cyan: 0, magenta: 1, yellow: 1, black: 0)), width: 3)]),
            Corpus.text("Plates", size: 16, origin: Point(x: 40, y: 100), color: Color(cyan: 0, magenta: 0, yellow: 0, black: 1)),
        ], nodeIDs: Array(ids.prefix(5))), number: 1)
    }()

    /// A tabloid-shaped page larger than the paper, for fitting and tiling.
    static let poster: ExportPage = {
        let items: [DisplayItem] = [
            square(Rect(x: 0, y: 0, width: 500, height: 375), Color(red: 0.95, green: 0.9, blue: 0.8)),
            Corpus.path(Corpus.ellipse(40, 40, 260, 200), [Corpus.fill(.solid(Corpus.blue)), Corpus.stroke(.solid(.black), width: 6)]),
            square(Rect(x: 280, y: 160, width: 180, height: 180), Corpus.red),
            Corpus.path(Corpus.wave(20, 250, 460, 100), [Corpus.stroke(.solid(Corpus.green), width: 10, cap: .round)]),
            Corpus.text("Poster", size: 48, origin: Point(x: 60, y: 340)),
        ]
        return ExportPage(bounds: Rect(x: 0, y: 0, width: 500, height: 375), displayList: DisplayList(canvas: "poster", items: items), number: 1)
    }()

    static func numbered(_ page: ExportPage, _ number: Int) -> ExportPage {
        var page = page
        page.number = number
        page.bleed = 6
        return page
    }

    static let composite = ["basics", "transparency", "gradients", "text"]

    static var cases: [Case] {
        let basics = numbered(Corpus.fixture("basics"), 1)
        var result = composite.map { name in
            Case(name: "composite-\(name)", pages: [numbered(Corpus.fixture(name), 1)], exercises: ["Pages", "Composite", "Uniform 100%"])
        }
        result += [
            Case(name: "scale-uniform", pages: [basics], options: PrintOptions(scaleX: 60), exercises: ["Uniform"]),
            Case(name: "scale-variable", pages: [basics], options: PrintOptions(scaleMode: .variable, scaleX: 120, scaleY: 70), exercises: ["Variable"]),
            Case(name: "scale-fit", pages: [poster], options: PrintOptions(scaleMode: .fit), exercises: ["Fit on paper"]),
            Case(name: "offset", pages: [basics], options: PrintOptions(offset: Point(x: 30, y: -20)), exercises: ["Offset"]),
            Case(name: "tile-automatic", pages: [poster], options: PrintOptions(tile: .automatic, tileOverlap: 18, marks: [.crop]), exercises: ["Automatic", "Overlap"]),
            Case(name: "tile-manual", pages: [poster], options: PrintOptions(tile: .manual), zeroPoints: [0: Point(x: 120, y: 90)], exercises: ["Manual", "Zero point"]),
            Case(name: "marks-bleed", pages: [basics], options: PrintOptions(printPageBoundary: true, marks: .all, bleed: 9),
                 exercises: ["Crop marks", "Registration marks", "Separation names", "File name and date", "Bleed", "Print page boundary"]),
            Case(name: "emulsion-negative", pages: [basics], options: PrintOptions(marks: [.crop, .fileNameDate], emulsionDown: true, negative: true),
                 exercises: ["Emulsion Down", "Negative"]),
            Case(name: "separations", pages: [separated], options: PrintOptions(separations: true, marks: .all, plates: plates),
                 exercises: ["Separations", "Ink", "Spot plate", "Overprint", "Angle", "Frequency"]),
            Case(name: "spot-as-process", pages: [separated], options: PrintOptions(separations: true, spotAsProcess: true, plates: plates),
                 exercises: ["Print spot colors as process"]),
            Case(name: "plates-chosen", pages: [separated],
                 options: PrintOptions(separations: true, marks: [.separationNames],
                                       plates: [PrintPlate(ink: .cyan, print: false), PrintPlate(ink: .magenta, angle: 30, frequency: 85), PrintPlate(ink: .yellow), PrintPlate(ink: .black)]),
                 exercises: ["Print (checkbox)", "Angle", "Frequency"]),
            Case(name: "screen-in-app", pages: [separated],
                 options: PrintOptions(separations: true, defaultScreen: HalftoneScreen(shape: .diamond, angle: 45, frequency: 40), plates: PrintPlate.process, screenInApp: true),
                 paper: PrintPaper(size: paper.size, imageable: paper.imageable, resolution: 300), screens: [ids[1]: ObjectScreen(shape: .line, angle: 0, frequency: 30)],
                 exercises: ["Screen in WireTuner", "Halftone screen", "Object screen", "Device resolution"]),
            Case(name: "ignore-object-screens", pages: [separated],
                 options: PrintOptions(separations: true, defaultScreen: HalftoneScreen(shape: .round, angle: 45, frequency: 40), plates: [PrintPlate(ink: .black)],
                                       screenInApp: true, ignoreObjectHalftones: true),
                 paper: PrintPaper(size: paper.size, imageable: paper.imageable, resolution: 300), screens: [ids[2]: ObjectScreen(shape: .cross, angle: 10, frequency: 25)],
                 exercises: ["Ignore object screens"]),
            Case(name: "flatness-outlines", pages: [separated], options: PrintOptions(flatness: 8, textAsOutlines: true), flatness: [ids[3]: 20],
                 exercises: ["Flatness", "Object flatness", "Print text as outlines"]),
            Case(name: "rasterized", pages: [basics], options: PrintOptions(marks: [.crop, .registration], rasterizeDPI: 144), exercises: ["Rasterize output"]),
            Case(name: "output-area", pages: [basics], source: .outputArea(pageOutlines: [Rect(x: 0, y: 0, width: 200, height: 150)]),
                 exercises: ["Output area"]),
            Case(name: "selection", pages: [separated], options: PrintOptions(marks: [.crop]), selection: [ids[1], ids[4]], exercises: ["Selected objects only"]),
            Case(name: "page-range", pages: [basics, numbered(Corpus.fixture("gradients"), 2)], range: 2...2, exercises: ["Page range"]),
        ]
        return result
    }

    /// Where fresh renderings and difference images go.
    static var output: URL {
        if let path = ProcessInfo.processInfo.environment["WT_PRINT_CORPUS_OUT"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("WTInterchangeFailures").appendingPathComponent("print-corpus")
    }

    static let references = BitmapTests.goldens.appendingPathComponent("PrintCorpus")
    static let tolerance = 24
    static let allowed = 0.002

    /// Every page of a PDF rasterized at 72 ppi over white.
    static func rasterize(_ pdf: Data) -> [CGImage] {
        guard let document = CGPDFDocument(CGDataProvider(data: pdf as CFData)!) else { return [] }
        return (1...max(document.numberOfPages, 1)).compactMap { index in
            document.page(at: index).map { _ in PDFTests.rasterize(pdf, page: index, scale: 1) }
        }
    }

    /// Changed pixels in red over a faded copy of `reference`.
    static func differenceImage(_ reference: CGImage, _ fresh: CGImage) -> CGImage? {
        let a = Corpus.pixels(reference, background: .white), b = Corpus.pixels(fresh, background: .white)
        guard a.width == b.width, a.height == b.height else { return fresh }
        var bytes = [UInt8](repeating: 255, count: a.bytes.count)
        for index in stride(from: 0, to: a.bytes.count, by: 4) {
            let delta = (0..<3).map { abs(Int(a.bytes[index + $0]) - Int(b.bytes[index + $0])) }.max()!
            if delta > tolerance {
                bytes[index] = 255; bytes[index + 1] = 0; bytes[index + 2] = 0
            } else {
                for channel in 0..<3 { bytes[index + channel] = UInt8(191 + Int(a.bytes[index + channel]) / 4) }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: a.width, height: a.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: a.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Compares sheet `index` of `corpus` with its reference; the failure message names the sheet.
    static func check(_ fresh: CGImage, case corpus: Case, sheet index: Int, name: String) throws -> String? {
        let file = "\(corpus.name)-\(index + 1).png"
        let url = references.appendingPathComponent(file)
        if ProcessInfo.processInfo.environment["WTINTERCHANGE_RECORD_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
            try ImageEncoding.encode(fresh, type: .png)!.write(to: url)
        }
        guard let reference = BitmapTests.read(url)?.image else { return "\(corpus.name) sheet \(index + 1) (\(name)): no reference \(file)" }
        let failing = Corpus.difference(reference, fresh, tolerance: tolerance)
        guard failing > allowed else { return nil }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try ImageEncoding.encode(fresh, type: .png)?.write(to: output.appendingPathComponent(file))
        if let difference = differenceImage(reference, fresh) {
            try ImageEncoding.encode(difference, type: .png)?.write(to: output.appendingPathComponent("\(corpus.name)-\(index + 1)-diff.png"))
        }
        return "\(corpus.name) sheet \(index + 1) (\(name)): \(String(format: "%.2f", failing * 100))% of pixels differ by more than \(tolerance)/255 "
            + "(allowed \(String(format: "%.1f", allowed * 100))%); see \(output.appendingPathComponent(file).path) and its -diff.png"
    }
}

@Suite struct PrintCorpusTests {
    @Test(arguments: PrintCorpus.cases)
    func everySheetMatchesItsReference(_ corpus: PrintCorpus.Case) throws {
        let plan = PrintPlan(corpus.request)
        #expect(!plan.sheets.isEmpty, "\(corpus.name) prints nothing")
        let pdf = try PrintPDF.data(plan)
        let sheets = PrintCorpus.rasterize(pdf)
        #expect(sheets.count == plan.sheets.count)
        for (index, fresh) in sheets.enumerated() {
            if let problem = try PrintCorpus.check(fresh, case: corpus, sheet: index, name: plan.sheets[index].name) {
                Issue.record(Comment(rawValue: problem))
            }
        }
    }

    /// The option table: every option of the three guide pages is exercised by some case.
    @Test func everyGuideOptionHasACase() {
        let covered = Set(PrintCorpus.cases.flatMap(\.exercises))
        let options = [
            "Pages", "Output area", "Selected objects only", "Page range", "Uniform", "Variable", "Fit on paper", "Offset", "Automatic", "Manual", "Overlap",
            "Zero point", "Composite", "Separations", "Print (checkbox)", "Ink", "Angle", "Frequency", "Print spot colors as process", "Halftone screen",
            "Screen in WireTuner", "Crop marks", "Registration marks", "Separation names", "File name and date", "Bleed", "Print page boundary",
            "Emulsion Down", "Negative", "Flatness", "Print text as outlines", "Rasterize output", "Object screen", "Ignore object screens", "Overprint",
            "Spot plate", "Device resolution", "Object flatness",
        ]
        #expect(Set(options).subtracting(covered).isEmpty, "\(Set(options).subtracting(covered).sorted())")
    }

    /// The composite cases are the identity corpus's pages, and their sheets hold the canvas
    /// renderer's pixels: printing adds no rendering of its own.
    @Test(arguments: PrintCorpus.composite)
    func compositeSheetsAreTheCanvasPixels(_ name: String) throws {
        let page = Corpus.fixture(name)
        let corpus = try #require(PrintCorpus.cases.first { $0.name == "composite-\(name)" })
        #expect(corpus.pages[0].displayList == page.displayList, "byte for byte the identity corpus's display list")
        let plan = PrintPlan(corpus.request)
        let sheet = try #require(PrintCorpus.rasterize(try PrintPDF.data(plan)).first)
        let trim = plan.sheets[0].trim
        // The sheet's page area (y down in the image) against the canvas rendering at 1×.
        let flippedY = plan.request.paper.size.height - trim.maxY
        let crop = try #require(sheet.cropping(to: CGRect(x: trim.minX, y: flippedY, width: trim.width, height: trim.height).integral))
        let reference = Corpus.reference(page, scale: 1)
        let failing = Corpus.difference(reference, crop, tolerance: 40)
        if failing > 0.02 {
            Corpus.dump(crop, "print-identity-\(name)")
            Corpus.dump(reference, "print-identity-\(name)-reference")
        }
        #expect(failing <= 0.02, "\(name): \(failing)")
    }

    @Test func aDriftingSheetIsNamedWithADifferenceImage() throws {
        let corpus = PrintCorpus.cases[0]
        let plan = PrintPlan(corpus.request)
        let fresh = try #require(PrintCorpus.rasterize(try PrintPDF.data(plan)).first)
        // Paint over half the sheet: the check fails and says which sheet, and writes both images.
        let surface = try #require(BitmapSurface(width: fresh.width, height: fresh.height))
        surface.context.draw(fresh, in: CGRect(x: 0, y: 0, width: fresh.width, height: fresh.height))
        surface.context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        surface.context.fill(CGRect(x: 0, y: 0, width: fresh.width / 2, height: fresh.height))
        let drifted = try #require(surface.makeImage())
        guard ProcessInfo.processInfo.environment["WTINTERCHANGE_RECORD_GOLDENS"] != "1" else { return }
        let problem = try #require(try PrintCorpus.check(drifted, case: corpus, sheet: 0, name: plan.sheets[0].name))
        #expect(problem.hasPrefix("\(corpus.name) sheet 1 (\(plan.sheets[0].name)): "))
        #expect(FileManager.default.fileExists(atPath: PrintCorpus.output.appendingPathComponent("\(corpus.name)-1-diff.png").path))
        var missing = corpus
        missing.name = "no-such-case"
        #expect(try PrintCorpus.check(fresh, case: missing, sheet: 0, name: "x")?.contains("no reference") == true)
        let odd = try #require(BitmapSurface(width: 3, height: 3)?.makeImage())
        #expect(PrintCorpus.differenceImage(fresh, odd) === odd)
    }
}
