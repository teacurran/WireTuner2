import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WTGeometry
@testable import WTRender

/// PRINT-007: plate mode in the reference renderer.
@Suite struct PlateTests {
    static let viewport = Viewport(size: Size(width: 64, height: 48))
    static let cyan = Color(cyan: 1, magenta: 0, yellow: 0, black: 0)
    static let halfMagenta = Color(cyan: 0, magenta: 0.5, yellow: 0, black: 0)
    static let spotID = NodeID(counter: 900, replica: 1)
    static let spotInk = SpotInk(swatch: spotID, name: "PANTONE 485 C")

    static func square(_ rect: Rect, _ color: Color, overprint: Bool = false) -> DisplayItem {
        .path(PathItem(path: DisplayPath(rect: rect), appearance: Appearance([.fill(FillPaint(paint: .solid(color), overprint: overprint))])))
    }

    /// 50% magenta at the left, 100% cyan over its right half.
    static func cyanOverMagenta(overprint: Bool) -> DisplayList {
        DisplayList(canvas: "plates", items: [
            square(Rect(x: 4, y: 4, width: 36, height: 36), halfMagenta),
            square(Rect(x: 24, y: 12, width: 36, height: 24), cyan, overprint: overprint),
        ])
    }

    @Test func cyanSquareOverHalfMagentaKnocksOut() throws {
        let renderer = PlateRenderer()
        let list = Self.cyanOverMagenta(overprint: false)
        let plates = renderer.renderPlates(list, plates: Ink.process, viewport: Self.viewport)
        #expect(plates.map(\.ink) == Ink.process)
        let cyan = plates[0].plate, magenta = plates[1].plate, yellow = plates[2].plate, black = plates[3].plate
        #expect(cyan.gray(x: 40, y: 24) == 0, "the cyan square is black on the cyan plate")
        #expect(cyan.gray(x: 10, y: 24) == 255)
        #expect(abs(Int(magenta.gray(x: 10, y: 24)) - 128) <= 1, "50% magenta is 50% gray")
        #expect(magenta.gray(x: 30, y: 24) == 255, "the cyan square knocks the magenta out")
        #expect(magenta.gray(x: 62, y: 46) == 255)
        #expect(yellow.pixels.allSatisfy { $0 == 255 })
        #expect(black.pixels.allSatisfy { $0 == 255 })
        #expect(abs(magenta.coverage(x: 10, y: 24) - 0.5) < 0.01)
    }

    @Test func overprintingCyanLeavesTheMagentaUninterrupted() throws {
        let list = Self.cyanOverMagenta(overprint: true)
        let magenta = try #require(PlateRenderer().renderPlate(list, plate: .magenta, viewport: Self.viewport))
        #expect(abs(Int(magenta.gray(x: 30, y: 24)) - 128) <= 1)
        #expect(magenta.gray(x: 50, y: 24) == 255)
        let cyan = try #require(PlateRenderer().renderPlate(list, plate: .cyan, viewport: Self.viewport))
        #expect(cyan.gray(x: 30, y: 24) == 0)
    }

    /// A C→M gradient: the cyan plate is a 100%→0% ramp, the magenta plate the reverse, linear
    /// in coverage within 1/255.
    @Test func gradientsMapEachStopToALinearRamp() throws {
        let width = 256.0
        let gradient = Gradient(.linear, from: Self.cyan, to: Color(cyan: 0, magenta: 1, yellow: 0, black: 0), axis: Gradient.Axis(start: Point(x: 0, y: 0), end: Point(x: width, y: 0)))
        let item = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: width, height: 8)), appearance: Appearance([.fill(FillPaint(paint: .gradient(gradient)))])))
        let list = DisplayList(canvas: "plates", items: [item])
        let viewport = Viewport(size: Size(width: width, height: 8))
        let cyan = try #require(PlateRenderer().renderPlate(list, plate: .cyan, viewport: viewport))
        let magenta = try #require(PlateRenderer().renderPlate(list, plate: .magenta, viewport: viewport))
        var worst = 0
        for x in 0..<Int(width) {
            let t = (Double(x) + 0.5) / width
            worst = max(worst, abs(Int(cyan.gray(x: x, y: 4)) - Int((255 * t).rounded())))
            worst = max(worst, abs(Int(magenta.gray(x: x, y: 4)) - Int((255 * (1 - t)).rounded())))
        }
        #expect(worst <= 1, "worst ramp error \(worst)/255")
        // An overprinting gradient that has no ink on a plate paints nothing there.
        let over = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: width, height: 8)), appearance: Appearance([.fill(FillPaint(paint: .gradient(gradient), overprint: true))])))
        let yellow = try #require(PlateRenderer().renderPlate(DisplayList(canvas: "plates", items: [Self.square(Rect(x: 0, y: 0, width: width, height: 8), Color(cyan: 0, magenta: 0, yellow: 0.4, black: 0)), over]), plate: .yellow, viewport: viewport))
        #expect(abs(Int(yellow.gray(x: 100, y: 4)) - 153) <= 1)
    }

    @Test func rgbAndLabColorsSeparateThroughWorkingCMYK() throws {
        let colors = [Color(red: 0.9, green: 0.2, blue: 0.1), Color(labL: 60, a: -30, b: 40), Color(oklabL: 0.5, a: 0.1, b: -0.1), Color(displayP3Red: 0.2, green: 0.4, blue: 0.9)]
        for color in colors {
            let list = DisplayList(canvas: "plates", items: [Self.square(Rect(x: 0, y: 0, width: 64, height: 48), color)])
            for ink in Ink.process {
                let context = PlateContext(plate: ink)
                let expected = Int((255 * (1 - context.coverage(of: color))).rounded())
                let plate = try #require(PlateRenderer().renderPlate(list, plate: ink, viewport: Self.viewport))
                #expect(abs(Int(plate.gray(x: 30, y: 20)) - expected) <= 1, "\(color) on \(ink)")
            }
            let inks = PlateContext(plate: .cyan).inks(of: color)
            #expect(inks.cyan + inks.magenta + inks.yellow + inks.black > 0)
        }
    }

    @Test func spotColorsPrintOnTheirOwnPlateOrAsProcess() throws {
        let alternate = Color(cyan: 0, magenta: 0.9, yellow: 0.8, black: 0).asSpot(Self.spotInk).tinted(0.4)
        #expect(alternate.spot?.tint == 0.4)
        let list = DisplayList(canvas: "plates", items: [Self.square(Rect(x: 0, y: 0, width: 64, height: 48), alternate)])
        let renderer = PlateRenderer()
        #expect(renderer.inks(in: list) == Ink.process + [.spot(Self.spotID)])
        let spot = try #require(renderer.renderPlate(list, plate: .spot(Self.spotID), viewport: Self.viewport))
        #expect(abs(Int(spot.gray(x: 30, y: 20)) - 153) <= 1, "a 40% tint is 40% on its plate")
        let magenta = try #require(renderer.renderPlate(list, plate: .magenta, viewport: Self.viewport))
        #expect(magenta.gray(x: 30, y: 20) == 255, "a spot colour knocks out the process plates")
        let process = PlateRenderer(spotAsProcess: true)
        #expect(process.inks(in: list) == Ink.process)
        let converted = try #require(process.renderPlate(list, plate: .magenta, viewport: Self.viewport))
        #expect(abs(Int(converted.gray(x: 30, y: 20)) - Int((255 * (1 - 0.9 * 0.4)).rounded())) <= 1, "as process: the tinted alternate")
        let absent = try #require(process.renderPlate(list, plate: .spot(Self.spotID), viewport: Self.viewport))
        #expect(absent.pixels.allSatisfy { $0 == 255 })
    }

    /// A custom Working CMYK whose blob is not local separates through the bundled default.
    @Test func aPendingWorkingCMYKFallsBackToTheDefault() {
        let pending = WTColor.ProfileRef(name: "Press", sha256: Data([1, 2, 3]), space: .cmyk)
        let context = PlateContext(plate: .magenta, colorManagement: ColorManagement(cmykProfile: pending))
        let red = Color(red: 1, green: 0, blue: 0)
        #expect(context.workingCMYK == ColorManagement.standard.cmykProfile)
        #expect(context.coverage(of: red) == PlateContext(plate: .magenta).coverage(of: red))
    }

    @Test func registrationPaintsBlackOnEveryPlate() throws {
        let list = DisplayList(canvas: "plates", items: [Self.square(Rect(x: 0, y: 0, width: 64, height: 48), .registration)])
        for ink in Ink.process + [.spot(Self.spotID)] {
            let plate = try #require(PlateRenderer().renderPlate(list, plate: ink, viewport: Self.viewport))
            #expect(plate.gray(x: 30, y: 20) == 0, "\(ink)")
        }
        #expect(InkCoverage(registration: 1)[.spot(Self.spotID)] == 1)
        #expect(Color.registration.spot?.identity == .registration)
    }

    @Test func textStrokesTransparencyAndPlaceholdersAreMapped() throws {
        let run = ReferenceCorpus.makeGlyphRun("M", font: GlyphFont(postScriptName: "Helvetica-Bold", size: 40), at: Point(x: 4, y: 40))
        let stroke = DisplayItem.path(PathItem(path: DisplayPath(polygon: [Point(x: 0, y: 44), Point(x: 64, y: 44)], closed: false), appearance: Appearance([.stroke(StrokePaint(paint: .solid(Self.cyan), style: StrokeStyle(width: 4)))])))
        let list = DisplayList(canvas: "plates", items: [
            .text(TextRunItem(text: "M", glyphRun: run, origin: Point(x: 4, y: 40), color: Self.cyan)),
            .text(TextRunItem(text: "o", glyphRun: run, origin: Point(x: 4, y: 40), color: Color(cyan: 0, magenta: 0, yellow: 1, black: 0), transform: .translation(x: 30, y: 0), overprint: true)),
            stroke,
            .group(GroupItem(children: [Self.square(Rect(x: 50, y: 0, width: 14, height: 14), Self.cyan)], opacity: 0.5)),
            .image(ImageItem(assetID: "missing", rect: Rect(x: 40, y: 20, width: 10, height: 10))),
            .text(TextRunItem(text: "placeholder", origin: Point(x: 0, y: 10), bounds: Rect(x: 0, y: 0, width: 10, height: 10), color: Self.cyan)),
        ])
        let cyan = try #require(PlateRenderer().renderPlate(list, plate: .cyan, viewport: Self.viewport))
        #expect(cyan.gray(x: 32, y: 44) == 0, "the stroke")
        #expect(abs(Int(cyan.gray(x: 57, y: 7)) - 128) <= 1, "a 50% group composites coverage")
        let yellow = try #require(PlateRenderer().renderPlate(list, plate: .yellow, viewport: Self.viewport))
        // The overprinting yellow glyph has no cyan: it leaves the cyan "M" beneath intact.
        let cyanUnder = try #require(PlateRenderer().renderPlate(list, plate: .cyan, viewport: Self.viewport))
        #expect(cyanUnder.pixels.contains(0))
        #expect(yellow.pixels.contains { $0 < 20 })
    }

    @Test func imagesContributeTheirChannel() throws {
        let image = ImageFixtures.rgba(width: 16, height: 16) { x, y in
            y == 15 ? [0, 0, 0, 0] : x < 8 ? [255, 0, 0, 255] : [0, 0, 255, 128]
        }
        let store = ImageRenderingTests.store(["pic": image])
        let item = ImageItem(assetID: "pic", rect: Rect(x: 0, y: 0, width: 32, height: 32))
        let list = DisplayList(canvas: "plates", items: [Self.square(Rect(x: 0, y: 0, width: 64, height: 48), Color(cyan: 0, magenta: 0, yellow: 0.5, black: 0)), .image(item)])
        var base = CoreGraphicsRenderer()
        base.imageStore = store
        let renderer = PlateRenderer(base: base)
        _ = renderer.renderPlate(list, plate: .magenta, viewport: Self.viewport)
        store.waitUntilIdle()
        let red = Color(red: 1, green: 0, blue: 0)
        let blue = Color(red: 0, green: 0, blue: 1)
        for ink in Ink.process {
            let plate = try #require(renderer.renderPlate(list, plate: ink, viewport: Self.viewport))
            let context = PlateContext(plate: ink)
            let expectedRed = Int((255 * (1 - context.coverage(of: red))).rounded())
            #expect(abs(Int(plate.gray(x: 8, y: 16)) - expectedRed) <= 2, "red pixels on \(ink)")
            // Half-transparent blue over 50% yellow: coverage composited at 50%.
            let underneath = context.coverage(of: Color(cyan: 0, magenta: 0, yellow: 0.5, black: 0))
            let expectedBlue = Int((255 * (1 - (0.5 * context.coverage(of: blue) + 0.5 * underneath))).rounded())
            #expect(abs(Int(plate.gray(x: 24, y: 16)) - expectedBlue) <= 3, "blue pixels on \(ink)")
        }
        let spot = try #require(renderer.renderPlate(list, plate: .spot(Self.spotID), viewport: Self.viewport))
        #expect(spot.gray(x: 8, y: 16) == 255)
        // Separations are cached per image and plate.
        let before = PlateImageCache.shared.separations
        _ = renderer.renderPlate(list, plate: .cyan, viewport: Self.viewport)
        #expect(PlateImageCache.shared.separations == before)
    }

    @Test func cmykImagesContributeTheirOwnChannel() throws {
        let space = CGColorSpace(name: CGColorSpace.genericCMYK)!
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(CGColor(genericCMYKCyan: 0.25, magenta: 0.75, yellow: 0, black: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = context.makeImage()!
        let management = ColorManagement(cmykProfile: ColorManagement.standard.converter.registry.register(colorSpace: space))
        let magenta = PlateContext(plate: .magenta, colorManagement: management)
        let separated = magenta.separate(image)
        let surface = try #require(BitmapSurface(drawing: separated))
        #expect(abs(Int(surface.pixel(x: 1, y: 1).red) - Int((255 * 0.25).rounded())) <= 1)
        let yellow = PlateContext(plate: .yellow, colorManagement: management).separate(image)
        #expect(try #require(BitmapSurface(drawing: yellow)).pixel(x: 1, y: 1).red == 255)
    }

    /// The composite list is drawn for every plate as it is: no rebuild, the same value.
    @Test func platesReuseTheCompositeList() throws {
        let list = Self.cyanOverMagenta(overprint: false)
        let copy = list
        _ = PlateRenderer().renderPlates(list, plates: Ink.process, viewport: Self.viewport)
        #expect(list == copy)
        let renderer = PlateRenderer().renderer(for: .black)
        #expect(renderer.plate?.plate == .black)
        #expect(renderer.viewMode == .preview && !renderer.overprintPreview)
    }

    @Test func platesDrawIntoPDFSheets() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 64, height: 48)
        let context = try #require(CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        PlateRenderer().drawPlate(Self.cyanOverMagenta(overprint: false), plate: .cyan, viewport: Self.viewport, into: context)
        context.endPDFPage()
        context.closePDF()
        let raster = try #require(PDFRasterizer.rasterize(data as Data, scale: 1))
        #expect(raster.pixel(x: 40, y: 24).red < 5)
        #expect(raster.pixel(x: 10, y: 24).red > 250)
    }

    @Test func paintsMapToPlateGrays() {
        let context = PlateContext(plate: .cyan)
        let pattern = Paint.pattern(PatternPaint(bitmap: .checker, color: Self.cyan))
        #expect(context.paint(pattern, overprint: false) == .pattern(PatternPaint(bitmap: .checker, color: Color(white: 0))))
        #expect(context.paint(.pattern(PatternPaint(bitmap: .checker, color: Self.halfMagenta)), overprint: true) == .none)
        #expect(context.paint(.textured(TexturedFill(texture: .sand, color: Self.halfMagenta)), overprint: true) == .none)
        #expect(context.paint(.textured(TexturedFill(texture: .sand, color: Self.cyan)), overprint: false) == .textured(TexturedFill(texture: .sand, color: Color(white: 0))))
        guard case .custom(let custom) = context.paint(.custom(CustomFill(pattern: .bricks, color: Self.cyan, color2: Self.halfMagenta)), overprint: false) else {
            Issue.record("custom stays custom")
            return
        }
        #expect(custom.color == Color(white: 0) && custom.color2 == Color(white: 1))
        guard case .lens(let lens) = context.paint(.lens(LensFill(type: .transparency, color: Self.cyan)), overprint: false) else {
            Issue.record("lens stays lens")
            return
        }
        #expect(lens.color == Color(white: 0))
        let tiled = Paint.tiled(TiledFill(tile: [Self.square(Rect(x: 0, y: 0, width: 4, height: 4), Self.cyan)]))
        #expect(context.paint(tiled, overprint: true) == tiled)
        #expect(context.paint(.none, overprint: false) == .none)
        #expect(context.paint(.solid(Self.halfMagenta), overprint: true) == .none)
        #expect(PlateContext.linearStops([Gradient.Stop(offset: 0, color: .black)]).count == 1)
        #expect(Ink.process.map(\.defaultAngle) == [15, 75, 0, 45])
        #expect(Ink.spot(Self.spotID).defaultAngle == 45)
        #expect(Ink.process.map(\.description) == ["Cyan", "Magenta", "Yellow", "Black"])
        #expect(Ink.spot(Self.spotID).description == "Spot 900:1")
        #expect(SpotInk(swatch: Self.spotID, name: "x", tint: .nan).tint == 1)
        let colors = DisplayItem.group(GroupItem(children: [
            .fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(.black))),
            .stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(.white))),
            .image(ImageItem(assetID: "a", rect: Rect(x: 0, y: 0, width: 1, height: 1), tint: Self.cyan)),
            .image(ImageItem(assetID: "b", rect: Rect(x: 0, y: 0, width: 1, height: 1))),
            .path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), appearance: Appearance([.stroke(StrokePaint(paint: tiled))]))),
        ])).colors
        #expect(colors.count == 4)
        let paints: [Paint] = [.gradient(Gradient(from: .black, to: .white)), .custom(CustomFill(pattern: .hatch)), .lens(LensFill(type: .invert)), pattern, .textured(TexturedFill(texture: .oak, color: .black)), .none]
        #expect(paints.map(\.colors.count) == [2, 2, 1, 1, 1, 0])
    }

    // MARK: Reference plates

    static let goldenCases: [(name: String, list: DisplayList)] = [
        ("platesKnockout", cyanOverMagenta(overprint: false)),
        ("platesOverprint", cyanOverMagenta(overprint: true)),
        ("platesMixed", ReferenceCorpus.mixed),
        ("platesGradients", ReferenceCorpus.cases.first { $0.name == "gradients" }?.list ?? ReferenceCorpus.mixed),
    ]

    static func plateGoldenURL(_ name: String, _ ink: Ink) -> URL {
        GoldenStore.directory.appendingPathComponent("\(name)-\(ink.description.lowercased())@2x.png")
    }

    static func readGray(_ url: URL) -> GrayPlate? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return GrayPlate(width: image.width, height: image.height, pixels: Array(UnsafeBufferPointer(start: data, count: image.width * image.height)))
    }

    /// Reference plates for corpus lists, compared exactly in the interior (a pixel whose
    /// 3 × 3 neighbourhood is flat) and within 16/255 on edges.
    @Test(arguments: goldenCases.map(\.name))
    func platesMatchTheirReferences(name: String) throws {
        let list = try #require(Self.goldenCases.first { $0.name == name }?.list)
        let viewport = Viewport(size: ReferenceCorpus.viewSize)
        for ink in Ink.process {
            let plate = try #require(PlateRenderer().renderPlate(list, plate: ink, viewport: viewport, scale: 2))
            let url = Self.plateGoldenURL(name, ink)
            if GoldenStore.isRecording {
                #expect(GoldenStore.write(plate.makeImage(), to: url))
                continue
            }
            let golden = try #require(Self.readGray(url), "missing plate golden \(url.lastPathComponent)")
            try #require(golden.width == plate.width && golden.height == plate.height)
            var failures = 0
            for y in 0..<plate.height {
                for x in 0..<plate.width {
                    let difference = abs(Int(plate.gray(x: x, y: y)) - Int(golden.gray(x: x, y: y)))
                    let flat = (-1...1).allSatisfy { dy in (-1...1).allSatisfy { dx in golden.gray(x: x + dx, y: y + dy) == golden.gray(x: x, y: y) } }
                    if difference > (flat ? 1 : 16) {
                        failures += 1
                    }
                }
            }
            #expect(failures == 0, "\(name) \(ink): \(failures) pixels differ")
        }
    }
}
