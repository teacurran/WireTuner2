import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// PRINT-009: the in-app halftone screener.
@Suite struct ScreenerTests {
    static let inch = Rect(x: 0, y: 0, width: 72, height: 72)
    static let objectID = NodeID(counter: 7, replica: 1)

    static func tint(_ black: Double, rect: Rect = inch, node: NodeID? = nil) -> DisplayList {
        let item = DisplayItem.path(PathItem(path: DisplayPath(rect: rect), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(cyan: 0, magenta: 0, yellow: 0, black: black))))])))
        return DisplayList(canvas: "screen", items: [item], nodeIDs: node.map { [$0] } ?? [])
    }

    static func screen(_ list: DisplayList, dpi: Double, screen: HalftoneScreen, objectScreens: [NodeID: HalftoneScreen] = [:], ignore: Bool = false, page: Rect = inch) throws -> BitPlate {
        try Screener(resolution: dpi, bandHeight: 256).screenPlate(list, plate: .black, renderer: PlateRenderer(), page: page, plateScreen: screen, objectScreens: objectScreens, ignoreObjectScreens: ignore)
    }

    /// 50% black at 45°/60 lpi and 1200 dpi: 50% ± 1% coverage and a 20-pixel period along
    /// the screen axis.
    @Test func fiftyPercentAt45DegreesSixtyLinesHasTheRightCoverageAndPeriod() throws {
        let plate = try Self.screen(Self.tint(0.5), dpi: 1200, screen: HalftoneScreen(shape: .round, angle: 45, frequency: 60))
        #expect(plate.width == 1200 && plate.height == 1200)
        let coverage = plate.coverage()
        #expect(abs(coverage - 0.5) <= 0.01, "coverage \(coverage)")
        // Sample along the screen axis (45° counter-clockwise on the page) and find the lag of
        // best self-agreement.
        let direction = (x: cos(Double.pi / 4), y: -sin(Double.pi / 4))
        var samples: [Bool] = []
        for step in 0..<800 {
            let x = 100 + Double(step) * direction.x, y = 1100 + Double(step) * direction.y
            samples.append(plate.isInked(x: Int(x.rounded()), y: Int(y.rounded())))
        }
        func agreement(_ lag: Int) -> Int {
            (0..<(samples.count - lag)).filter { samples[$0] == samples[$0 + lag] }.count
        }
        let best = (12...28).max { agreement($0) < agreement($1) }!
        #expect(best == 20, "period \(best)")
    }

    @Test(arguments: HalftoneShape.allCases)
    func eachSpotFunctionHoldsItsCoverage(shape: HalftoneShape) throws {
        for level in [0.1, 0.3, 0.7, 0.9] {
            let plate = try Self.screen(Self.tint(level, rect: Rect(x: 0, y: 0, width: 36, height: 36)), dpi: 600, screen: HalftoneScreen(shape: shape, angle: 30, frequency: 50), page: Rect(x: 0, y: 0, width: 36, height: 36))
            #expect(abs(plate.coverage() - level) <= 0.02, "\(shape) at \(level): \(plate.coverage())")
        }
    }

    /// Each shape's screened 40% tint at 0°, 60 lpi, 1200 dpi against its committed reference
    /// tile.
    @Test(arguments: HalftoneShape.allCases)
    func eachSpotFunctionMatchesItsReferenceTile(shape: HalftoneShape) throws {
        let page = Rect(x: 0, y: 0, width: 4.8, height: 4.8)
        let plate = try Self.screen(Self.tint(0.4, rect: page), dpi: 1200, screen: HalftoneScreen(shape: shape, angle: 0, frequency: 60), page: page)
        let url = GoldenStore.directory.appendingPathComponent("screen-\(shape.rawValue)@1200dpi.png")
        if GoldenStore.isRecording {
            #expect(GoldenStore.write(plate.makeImage(), to: url))
            return
        }
        let golden = try #require(PlateTests.readGray(url), "missing \(url.lastPathComponent)")
        try #require(golden.width == plate.width && golden.height == plate.height)
        var mismatches = 0
        for y in 0..<plate.height {
            for x in 0..<plate.width where plate.isInked(x: x, y: y) != (golden.gray(x: x, y: y) < 128) {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    /// A Line screen at 0° draws whole rows: lines, not dots.
    @Test func aLineScreenProducesLines() throws {
        let plate = try Self.screen(Self.tint(0.3), dpi: 600, screen: HalftoneScreen(shape: .line, angle: 0, frequency: 40))
        var inkedRows = 0
        for y in 0..<plate.height {
            let first = plate.isInked(x: 0, y: y)
            #expect((0..<plate.width).allSatisfy { plate.isInked(x: $0, y: y) == first }, "row \(y) is not uniform")
            if first { inkedRows += 1 }
        }
        #expect(abs(Double(inkedRows) / Double(plate.height) - 0.3) < 0.035)
        let round = try Self.screen(Self.tint(0.3), dpi: 600, screen: HalftoneScreen(shape: .round, angle: 0, frequency: 40))
        #expect(!(0..<round.width).allSatisfy { round.isInked(x: $0, y: 7) == round.isInked(x: 0, y: 7) }, "dots vary along a row")
    }

    /// An object with a 15° screen over a tint screened at 45°: inside the object the 15°
    /// pattern, outside the 45° one, the boundary at the object's edge.
    @Test func anObjectScreenShowsBothPatternsWithACleanBoundary() throws {
        let object = Rect(x: 18, y: 18, width: 36, height: 36)
        let background = DisplayItem.path(PathItem(path: DisplayPath(rect: Self.inch), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(cyan: 0, magenta: 0, yellow: 0, black: 0.5))))])))
        let square = DisplayItem.path(PathItem(path: DisplayPath(rect: object), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(cyan: 0, magenta: 0, yellow: 0, black: 0.5))))])))
        let list = DisplayList(canvas: "screen", items: [background, square], nodeIDs: [nil, Self.objectID])
        let plateScreen = HalftoneScreen(shape: .round, angle: 45, frequency: 40)
        let objectScreen = HalftoneScreen(shape: .round, angle: 15, frequency: 40)
        let mixed = try Self.screen(list, dpi: 600, screen: plateScreen, objectScreens: [Self.objectID: objectScreen])
        let at45 = try Self.screen(Self.tint(0.5), dpi: 600, screen: plateScreen)
        let at15 = try Self.screen(Self.tint(0.5), dpi: 600, screen: objectScreen)
        let scale = 600.0 / 72
        let inner = (x: Int(object.minX * scale), y: Int(object.minY * scale), right: Int(object.maxX * scale), bottom: Int(object.maxY * scale))
        var insideDifferences = 0, outsideDifferences = 0
        for y in 0..<mixed.height {
            for x in 0..<mixed.width {
                let inside = x >= inner.x && x < inner.right && y >= inner.y && y < inner.bottom
                let expected = inside ? at15.isInked(x: x, y: y) : at45.isInked(x: x, y: y)
                if mixed.isInked(x: x, y: y) != expected {
                    if inside { insideDifferences += 1 } else { outsideDifferences += 1 }
                }
            }
        }
        #expect(insideDifferences == 0 && outsideDifferences == 0, "\(insideDifferences) inside, \(outsideDifferences) outside")
        // Ignoring object screens: one pattern everywhere.
        let ignored = try Self.screen(list, dpi: 600, screen: plateScreen, objectScreens: [Self.objectID: objectScreen], ignore: true)
        #expect(ignored == at45)
        // An object screen equal to the plate's changes nothing.
        let same = try Self.screen(list, dpi: 600, screen: plateScreen, objectScreens: [Self.objectID: plateScreen])
        #expect(same == at45)
    }

    @Test func cancellationStopsBetweenBands() async throws {
        #expect(throws: CancellationError.self) {
            try Screener(resolution: 300, bandHeight: 16).screenPlate(Self.tint(0.5), plate: .black, renderer: PlateRenderer(), page: Self.inch, plateScreen: HalftoneScreen(), isCancelled: { true })
        }
        let task = Task {
            try await Screener(resolution: 1200, bandHeight: 8).screenPlate(Self.tint(0.5), plate: .black, renderer: PlateRenderer(), page: Rect(x: 0, y: 0, width: 612, height: 792), plateScreen: HalftoneScreen())
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let finished = try await Screener(resolution: 144).screenPlate(Self.tint(1), plate: .black, renderer: PlateRenderer(), page: Self.inch, plateScreen: HalftoneScreen())
        #expect(finished.coverage() == 1)
        #expect(throws: Screener.ScreenError.emptyPage) {
            try Screener(resolution: 72).screenPlate(Self.tint(0.5), plate: .black, renderer: PlateRenderer(), page: Rect(x: 0, y: 0, width: 0.1, height: 10), plateScreen: HalftoneScreen())
        }
    }

    /// A letter-size plate at 2400 dpi screens in under 4 s (enforced in release builds;
    /// debug builds screen a 600 dpi plate and report).
    @Test func letterPlateScreensWithinBudget() throws {
        #if DEBUG
        let dpi = 300.0
        #else
        let dpi = 2400.0
        #endif
        let page = Rect(x: 0, y: 0, width: 612, height: 792)
        let list = Self.tint(0.35, rect: page.insetBy(dx: 36, dy: 36))
        let start = Date()
        let plate = try Screener(resolution: dpi).screenPlate(list, plate: .black, renderer: PlateRenderer(), page: page, plateScreen: HalftoneScreen(shape: .round, angle: 45, frequency: 150))
        let seconds = Date().timeIntervalSince(start)
        print("PERF screener: \(plate.width) × \(plate.height) px at \(Int(dpi)) dpi in \(String(format: "%.2f", seconds)) s")
        #if !DEBUG
        #expect(seconds < 4)
        #endif
        #expect(abs(plate.coverage(in: (plate.width / 4, plate.height / 4, plate.width / 4, plate.height / 4)) - 0.35) < 0.02)
    }

    /// Pages wider than one bitmap tile screen seamlessly across tiles.
    @Test func widePagesScreenAcrossTiles() throws {
        let page = Rect(x: 0, y: 0, width: Double(Screener.tileWidth) + 300, height: 6)
        let plate = try Screener(resolution: 72, bandHeight: 4).screenPlate(Self.tint(0.5, rect: page), plate: .black, renderer: PlateRenderer(), page: page, plateScreen: HalftoneScreen(shape: .round, angle: 30, frequency: 8))
        let sample = try #require(PlateRenderer().renderPlate(Self.tint(0.5), plate: .black, viewport: Viewport(size: Size(width: 4, height: 4))))
        let uniform = GrayPlate(width: plate.width, height: plate.height, pixels: [UInt8](repeating: sample.gray(x: 1, y: 1), count: plate.width * plate.height))
        #expect(plate == Screener(resolution: 72).screen(uniform, with: HalftoneScreen(shape: .round, angle: 30, frequency: 8)))
    }

    @Test func screensReadTheirRulesAndBitPlatesImage() throws {
        #expect(HalftoneScreen(shape: .line, angle: -30, frequency: 0).angle == 330)
        #expect(HalftoneScreen(shape: .line, angle: .nan, frequency: 900).frequency == 60)
        #expect(HalftoneScreen(shape: .line, angle: 45, frequency: 40).description == "Line 45° 40 lpi")
        #expect(HalftoneScreen(shape: .ellipse, angle: 22.5, frequency: 133.5).description == "Ellipse 22.5° 133.5 lpi")
        var plate = BitPlate(width: 10, height: 2)
        var band = BitPlate(width: 10, height: 1)
        band.bits[0] = 0b1010_0000
        plate.copyRows(from: band, at: 1)
        #expect(plate.isInked(x: 0, y: 1) && !plate.isInked(x: 1, y: 1) && plate.isInked(x: 2, y: 1))
        #expect(!plate.isInked(x: 20, y: 0))
        #expect(plate.coverage(in: (0, 1, 10, 1)) == 0.2)
        #expect(plate.coverage(in: (20, 20, 1, 1)) == 0)
        let image = plate.makeImage()
        #expect(image.bitsPerPixel == 1 && image.width == 10)
        let gray = GrayPlate(width: 2, height: 1)
        #expect(gray.coverage(x: 0, y: 0) == 0)
        #expect(gray.makeImage().width == 2)
        // A screen-index map wider than the screens clamps to the last.
        let screener = Screener(resolution: 72)
        let flat = GrayPlate(width: 4, height: 4, pixels: [UInt8](repeating: 0, count: 16))
        let index = GrayPlate(width: 4, height: 4, pixels: [UInt8](repeating: 9, count: 16))
        #expect(screener.screen(flat, screens: [HalftoneScreen()], index: index).coverage() == 1)
        #expect(screener.screen(flat, with: HalftoneScreen()).coverage() == 1)
        #expect(Screener(resolution: .nan, bandHeight: 0).bandHeight == 1)
    }

    @Test func footprintsPaintEverythingOneOpaqueColor() {
        let color = Color(white: 3 / 255)
        let glyphs = ReferenceCorpus.makeGlyphRun("A", font: GlyphFont(postScriptName: "Helvetica", size: 12), at: .zero)
        let items: [DisplayItem] = [
            .fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(.white))),
            .stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .none)),
            .path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), appearance: Appearance([.fill(FillPaint(paint: .solid(.white), overprint: true)), .stroke(StrokePaint(paint: .solid(.black), overprint: true))]))),
            .image(ImageItem(assetID: "x", rect: Rect(x: 0, y: 0, width: 2, height: 2))),
            .text(TextRunItem(text: "A", glyphRun: glyphs, origin: .zero, overprint: true)),
            .group(GroupItem(children: [.fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(.black)))], opacity: 0.3)),
        ]
        let painted = items.map { $0.painted(color) }
        #expect(painted.flatMap(\.colors).allSatisfy { $0 == color })
        guard case .group(let group) = painted[5], case .fill = painted[3] else {
            Issue.record("groups stay groups, images become their frames")
            return
        }
        #expect(group.opacity == 1)
        guard case .stroke(let none) = painted[1] else { return }
        #expect(none.paint == .none)
    }
}
