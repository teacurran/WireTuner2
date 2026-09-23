import CoreGraphics
import Foundation
import Synchronization
import Testing
import WTGeometry
@testable import WTRender

/// IMG-021: quantization and outline tracing (docs/_includes/imported/tracing.adoc).
@Suite struct TraceOutlineTests {
    private func signedArea(_ contour: Contour) -> Double {
        FilledPath(contour).signedArea()
    }

    @Test func lineArtRendersBackWithinTwoPercent() throws {
        let source = TraceFixtures.lineArt()
        let result = try Trace.run(source, options: Trace.Options(colors: 2, conformity: 10))
        #expect(result.paths.count == 2)  // paper, ink
        let ink = try #require(result.paths.last)
        #expect(ink.fill.map { $0.red < 0.1 } == true)
        // Rectangle, triangle, ring outer and ring hole.
        #expect(ink.contours.count == 4)
        #expect((8...80).contains(result.segmentCount), "\(result.segmentCount) segments")
        let back = TraceFixtures.renderBack(result, width: source.width, height: source.height)
        #expect(TraceFixtures.difference(source, back) < 0.02)
    }

    @Test func letteringAndPhotographRenderBack() throws {
        let lettering = TraceFixtures.lettering()
        let traced = try Trace.run(lettering, options: Trace.Options(colors: 2, conformity: 10))
        let back = TraceFixtures.renderBack(traced, width: lettering.width, height: lettering.height)
        #expect(TraceFixtures.difference(lettering, back) < 0.02)
        #expect((2...6).contains(traced.paths.last!.contours.count))  // A, its counter, g, its counter

        let photograph = TraceFixtures.photograph()
        let photo = try Trace.run(photograph, options: Trace.Options(colors: 16, conformity: 10))
        #expect((3...16).contains(photo.paths.count))
        let photoBack = TraceFixtures.renderBack(photo, width: photograph.width, height: photograph.height)
        #expect(TraceFixtures.difference(photograph, photoBack, tolerance: 48) < 0.02)
    }

    @Test func holesHaveOppositePolarity() throws {
        let result = try Trace.run(TraceFixtures.ring(), options: Trace.Options(colors: 2, conformity: 10))
        let ink = try #require(result.paths.last)
        #expect(ink.contours.count == 2)
        let areas = ink.contours.map(signedArea)
        #expect(areas.contains { $0 > 0 } && areas.contains { $0 < 0 })
        let path = FilledPath(contours: ink.contours, fillRule: .nonZero)
        #expect(path.contains(Point(x: 15, y: 50)))  // in the ring
        #expect(!path.contains(Point(x: 50, y: 50)))  // in the hole
        let evenOdd = FilledPath(contours: ink.contours, fillRule: .evenOdd)
        #expect(!evenOdd.contains(Point(x: 50, y: 50)))
        // Outer ≈ π·40², hole ≈ π·20²; together the ink's pixel count.
        #expect(abs(areas.max()! - Double.pi * 1600) < 0.03 * Double.pi * 1600)
        #expect(abs(-areas.min()! - Double.pi * 400) < 0.1 * Double.pi * 400)
        let inkPixels = Double(TraceFixtures.darkPixels(TraceFixtures.ring()))
        #expect(abs(areas.reduce(0, +) - inkPixels) < 0.02 * inkPixels)
    }

    @Test func transformMapsToPasteboard() throws {
        let transform = AffineTransform.scale(0.5).concatenating(.translation(x: 100, y: 200))
        let result = try Trace.run(TraceFixtures.ring(), options: Trace.Options(colors: 2), transform: transform)
        let bounds = result.paths.last!.contours.reduce(Rect.null) { $0.union($1.bounds) }
        #expect(abs(bounds.minX - 105) < 1 && abs(bounds.minY - 205) < 1)
        #expect(abs(bounds.width - 40) < 1)
    }

    @Test func conformityControlsPointCount() throws {
        let source = TraceFixtures.lettering()
        let loose = try Trace.run(source, options: Trace.Options(colors: 2, conformity: 0))
        let tight = try Trace.run(source, options: Trace.Options(colors: 2, conformity: 10))
        #expect(loose.segmentCount < tight.segmentCount)
        #expect(Trace.Options(conformity: 10).tolerance == 0.5)
        #expect(Trace.Options(conformity: 42).tolerance == 0.5)
        #expect(Trace.Options(conformity: -3).tolerance == 2.5)
    }

    @Test func overlapExtendsLighterRegionsUnderDarker() throws {
        // A grey square abutting a black square.
        let source = TraceFixtures.bitmap(width: 120, height: 80) { context in
            context.setFillColor(CGColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 10, y: 10, width: 50, height: 60))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 60, y: 10, width: 50, height: 60))
        }
        func greyArea(_ overlap: Trace.Overlap) throws -> Double {
            let result = try Trace.run(source, options: Trace.Options(colors: 3, conformity: 10, overlap: overlap))
            let grey = try #require(result.paths.first { abs(($0.fill?.red ?? 0) - 0.6) < 0.05 })
            return grey.contours.map(signedArea).reduce(0, +)
        }
        let none = try greyArea(.none)
        let tight = try greyArea(.tight)
        let loose = try greyArea(.loose)
        #expect(abs(none - 3000) < 30)
        #expect(tight > none + 15 && tight < none + 45)  // 0.5 px along a 60 px edge
        #expect(loose > tight + 60)  // 2 px
        // Order: lighter first, so the black square is drawn over the grey overlap.
        let result = try Trace.run(source, options: Trace.Options(colors: 3, overlap: .loose))
        let lightness = result.paths.map { $0.fill!.red }
        #expect(lightness == lightness.sorted(by: >))
    }

    @Test func outerEdgeDropsHolesAndPaper() throws {
        let result = try Trace.run(TraceFixtures.lineArt(), options: Trace.Options(colors: 2, outerEdge: true))
        #expect(result.paths.count == 1)
        let path = result.paths[0]
        #expect(path.contours.count == 3)  // rectangle, triangle, ring without its hole
        #expect(path.contours.allSatisfy { signedArea($0) > 0 })
        #expect(path.fill.map { $0.red < 0.1 } == true)
        // An all-paper bitmap has no outer edge.
        let blank = TraceFixtures.bitmap(width: 10, height: 10) { _ in }
        #expect(try Trace.run(blank, options: Trace.Options(outerEdge: true)).paths.isEmpty)
    }

    @Test func graysAndCMYK() throws {
        let photograph = TraceFixtures.photograph()
        let grays = try Trace.run(photograph, options: Trace.Options(colors: 4, grays: true, colorModel: .cmyk))
        #expect((2...4).contains(grays.paths.count))
        for path in grays.paths {
            let fill = try #require(path.fill)
            #expect(fill.red == fill.green && fill.green == fill.blue)
            let cmyk = try #require(path.cmyk)
            #expect(cmyk.x == 0 && cmyk.y == 0 && cmyk.z == 0)
            #expect(abs(cmyk.w - (1 - fill.red)) < 1e-9)
        }
        #expect(Trace.cmyk(of: Color(red: 1, green: 0, blue: 0)) == SIMD4(0, 1, 1, 0))
        #expect(Trace.cmyk(of: .black) == SIMD4(0, 0, 0, 1))
        let rgb = try Trace.run(photograph, options: Trace.Options(colors: 4))
        #expect(rgb.paths.allSatisfy { $0.cmyk == nil })
    }

    @Test func noiseToleranceRemovesSpeckles() throws {
        let scan = TraceFixtures.noisyScan()
        let raw = try Trace.run(scan, options: Trace.Options(colors: 2))
        let rawContours = raw.paths.reduce(0) { $0 + $1.contours.count }
        #expect(rawContours > 50)
        for tolerance in 1...5 {
            let filtered = try Trace.run(scan, options: Trace.Options(colors: 2, noiseTolerance: tolerance))
            let contours = filtered.paths.reduce(0) { $0 + $1.contours.count }
            #expect(contours < rawContours / 3, "tolerance \(tolerance): \(contours)")
        }
        let merged = try Trace.run(scan, options: Trace.Options(colors: 2, noiseTolerance: 8))
        #expect(merged.paths.map(\.contours.count) == [2, 1])  // paper with the square's hole, the square
        // A uniform bitmap has no neighbours to merge into.
        let blank = TraceFixtures.bitmap(width: 8, height: 8) { _ in }
        #expect(try Trace.run(blank, options: Trace.Options(noiseTolerance: 8)).paths.count == 1)
    }

    @Test func noFillStrokesOutlines() throws {
        let result = try Trace.run(TraceFixtures.ring(), options: Trace.Options(colors: 2, fillsPaths: false))
        #expect(result.paths.allSatisfy { $0.fill == nil && $0.stroke != nil && $0.strokeWidth == 1 })
    }

    @Test func transparentPixelsAreNotTraced() throws {
        var pixels = [UInt8](repeating: 0, count: 20 * 20 * 4)
        for y in 5..<15 {
            for x in 5..<15 {
                pixels[(y * 20 + x) * 4 + 3] = 255
            }
        }
        let bitmap = try #require(Trace.Bitmap(width: 20, height: 20, pixels: pixels))
        let result = try Trace.run(bitmap, options: Trace.Options(colors: 2))
        #expect(result.paths.count == 1)
        #expect(result.paths[0].contours.count == 1)
        // Fully transparent: nothing at all.
        let clear = try #require(Trace.Bitmap(width: 4, height: 4, pixels: [UInt8](repeating: 0, count: 64)))
        #expect(try Trace.run(clear).paths.isEmpty)
        #expect(try Trace.run(clear, options: Trace.Options(outerEdge: true)).paths.isEmpty)
    }

    @Test func bitmapValidationAndCGImage() throws {
        #expect(Trace.Bitmap(width: 0, height: 1, pixels: []) == nil)
        #expect(Trace.Bitmap(width: 2, height: 2, pixels: [0, 0, 0]) == nil)
        // A half-transparent red pixel un-premultiplies back to full red.
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let bitmap = try #require(Trace.Bitmap(cgImage: context.makeImage()!))
        #expect(bitmap.pixels[0] >= 254 && bitmap.pixels[1] == 0 && abs(Int(bitmap.pixels[3]) - 128) <= 1)
        // A clear pixel stays clear.
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(Trace.Bitmap(cgImage: context.makeImage()!)?.pixels == [0, 0, 0, 0])
        #expect(Trace.Overlap.none.distance == 0)
    }

    @Test func samplingRendersADisplayListRect() throws {
        let square = DisplayItem.fill(FillItem(path: DisplayPath(rect: Rect(x: 20, y: 20, width: 10, height: 10)), paint: .solid(.black)))
        let list = DisplayList(canvas: "c", items: [square])
        let sampled = try #require(Trace.Sampling.render(list, rect: Rect(x: 10, y: 10, width: 30, height: 30), pixelsPerPoint: 4))
        #expect(sampled.bitmap.width == 120 && sampled.bitmap.height == 120)
        let result = try Trace.run(sampled.bitmap, options: Trace.Options(colors: 2), transform: sampled.transform)
        let bounds = result.paths.last!.contours[0].bounds
        #expect(abs(bounds.minX - 20) < 0.3 && abs(bounds.minY - 20) < 0.3 && abs(bounds.maxX - 30) < 0.3)
        #expect(Trace.Sampling.render(list, rect: .null, pixelsPerPoint: 4) == nil)
        #expect(Trace.Sampling.render(list, rect: Rect(x: 0, y: 0, width: 10, height: 10), pixelsPerPoint: 0) == nil)
        #expect(Trace.Sampling.render(list, rect: Rect(x: 0, y: 0, width: 1e6, height: 1e6), pixelsPerPoint: 1) == nil)
    }

    @Test func maskOutlineKeepsOrDropsHoles() {
        var mask = [UInt8](repeating: 0, count: 30 * 30)
        for y in 5..<25 {
            for x in 5..<25 where !(x >= 12 && x < 18 && y >= 12 && y < 18) {
                mask[y * 30 + x] = 1
            }
        }
        let withHoles = Trace.outline(mask: mask, width: 30, height: 30)
        #expect(withHoles.count == 2)
        let without = Trace.outline(mask: mask, width: 30, height: 30, keepHoles: false)
        #expect(without.count == 1)
        #expect(abs(without[0].bounds.width - 20) < 0.5)
        #expect(Trace.outline(mask: [1], width: 2, height: 2).isEmpty)
        // A lone pixel still yields a (tiny) contour.
        #expect(Trace.outline(mask: [1], width: 1, height: 1).count == 1)
    }

    @Test func diagonalPixelsFollowTheMinorityPolicy() {
        // Two pixels touching at a corner in a sparse neighbourhood: the inside is the minority,
        // so they join into one boundary.  In a dense checkerboard of inside pixels around the
        // same corner the inside is the majority, and they stay apart.
        var sparse = [UInt8](repeating: 0, count: 10 * 10)
        sparse[4 * 10 + 4] = 1
        sparse[5 * 10 + 5] = 1
        #expect(Trace.outline(mask: sparse, width: 10, height: 10).count == 1)
        var dense = [UInt8](repeating: 1, count: 10 * 10)
        dense[4 * 10 + 5] = 0
        dense[5 * 10 + 4] = 0
        // Two holes touching diagonally in solid inside: now the holes are the minority, so they
        // join into one hole and the inside pixels around the corner stay apart.
        let contours = Trace.outline(mask: dense, width: 10, height: 10)
        #expect(contours.filter { FilledPath($0).signedArea() < 0 }.count == 1)
        #expect(contours.count == 2)
    }

    @Test func contourFollowingReusesItsBuffer() throws {
        // A 1,000-px disc: its boundary has thousands of turn corners.  The walk's only buffer
        // is reserved once per tracer and never grows or moves while walking.
        let side = 1000
        var tracer = TraceOutline(width: side, height: side)
        try tracer.load(check: {}) { index in
            let dx = Double(index % side) - 500, dy = Double(index / side) - 500
            return dx * dx + dy * dy < 490 * 490
        }
        let capacity = tracer.corners.capacity
        let firstRow = 500 - 489
        let startX = (0..<side).first { tracer.inside($0, firstRow) }!
        let area = try tracer.walk(fromX: startX, y: firstRow, check: {})
        #expect(tracer.corners.count > 1000)
        #expect(tracer.corners.capacity == capacity)
        #expect(abs(Double(area) / 2 - Double.pi * 490 * 490) < 0.01 * Double.pi * 490 * 490)
    }

    @Test func tracingIsDeterministic() throws {
        let photograph = TraceFixtures.photograph()
        let options = Trace.Options(colors: 8, noiseTolerance: 2, overlap: .tight)
        #expect(try Trace.run(photograph, options: options) == Trace.run(photograph, options: options))
    }

    @Test func progressReportsAndCancellationThrows() async throws {
        let source = TraceFixtures.lineArt()
        final class Box: @unchecked Sendable {
            var values: [Double] = []
        }
        let box = Box()
        _ = try Trace.run(source, options: Trace.Options(colors: 2), progress: { box.values.append($0) })
        #expect(box.values.first == 0.2 && box.values.last == 1)
        #expect(box.values == box.values.sorted())

        #expect(throws: Trace.Cancelled.self) {
            try Trace.run(source, isCancelled: { true })
        }
        // Cancelled at any point of any stage, the trace throws: count the polls of a whole run,
        // then cancel after each fraction of them.
        let variants = [
            Trace.Options(colors: 4, noiseTolerance: 8, overlap: .loose, mode: .centerlineAndOutline(openPathsBelow: 6)),
            Trace.Options(colors: 4, noiseTolerance: 3, outerEdge: true),
            Trace.Options(colors: 2, mode: .centerline),
        ]
        for options in variants {
            var total = 0
            _ = try Trace.run(source, options: options, isCancelled: {
                total += 1
                return false
            })
            for fraction in [0.0, 0.2, 0.4, 0.6, 0.8, 0.95] {
                let limit = Int(Double(total) * fraction)
                var polls = 0
                #expect(throws: Trace.Cancelled.self, "\(options) after \(limit) of \(total)") {
                    try Trace.run(source, options: options, isCancelled: {
                        polls += 1
                        return polls > limit
                    })
                }
            }
        }

        let traced = try await Trace.trace(source, options: Trace.Options(colors: 2))
        #expect(traced.paths.count == 2)
    }

    /// The progress a trace reports, recorded from the thread it runs on.
    private final class ProgressLog: Sendable {
        private let values = Mutex<[Double]>([])

        func append(_ value: Double) {
            values.withLock { $0.append(value) }
        }

        var snapshot: [Double] { values.withLock { $0 } }
    }

    @Test func cancellingTheCallingTaskStopsTheTrace() async throws {
        // Timing would measure the machine's load as much as the trace (a trace that takes
        // minutes in a debug build, sharing the cores with a parallel test run), so the checks
        // count what the trace did instead: a cancelled trace throws and reports no further
        // progress than the stage it was in.
        let big = TraceFixtures.photograph(width: 1200, height: 1200)
        let options = Trace.Options(colors: 64)

        // Cancelled before it starts: nothing runs to completion.
        let early = ProgressLog()
        let cancelledEarly = Task { try await Trace.trace(big, options: options, progress: { early.append($0) }) }
        cancelledEarly.cancel()
        await #expect(throws: Trace.Cancelled.self) {
            try await cancelledEarly.value
        }
        #expect(!early.snapshot.contains(1))

        // Cancelled mid-flight, once quantization has finished: the trace stops within the
        // palette entry it is tracing (each entry reports progress once, when it starts).
        let late = ProgressLog()
        let (reports, reporter) = AsyncStream.makeStream(of: Double.self)
        let running = Task {
            defer { reporter.finish() }
            return try await Trace.trace(big, options: options, progress: { value in
                late.append(value)
                reporter.yield(value)
            })
        }
        for await value in reports where value >= 0.2 {
            break
        }
        let before = late.snapshot.count
        running.cancel()
        await #expect(throws: Trace.Cancelled.self) {
            try await running.value
        }
        let after = late.snapshot
        #expect(after.count - before <= 2, "\(after.count - before) progress reports after cancelling")
        #expect(!after.contains(1))
    }

    @Test func fourMegapixelOutlineBudget() throws {
        // Debug builds are some 250 times slower here: correctness runs trace a quarter-megapixel
        // source, the perf run (release) the 4 MP one it holds to the budget.
        let side = PerfBudget.isMeasuring ? 2048 : 512
        let source = TraceFixtures.photograph(width: side, height: side)
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try Trace.run(source, options: Trace.Options(colors: 16))
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        print("PERF trace: \(side) × \(side) px, 16 colours, outline in \(String(format: "%.2f", seconds)) s (4 MP budget 2 s on M1, held in the perf run)")
        #expect(!result.paths.isEmpty)
        PerfBudget.expect(.seconds(seconds), within: .seconds(2), "\(side) x \(side) px")
    }
}
