import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// IMG-029: the *Photo* tracer -- segmentation before tracing (tracing.adoc, "Tracing
/// photographs").  Fixtures are drawn in code; the subject instances and class maps stand in for
/// Vision and the bundled model, which the tests do not need.
@Suite struct TracePhotoTests {
    /// A flat-colour scene of `width` × `height`: `paint(x, y)` gives each pixel's colour and
    /// class, `subject(x, y)` its instance (0 none).
    struct Scene {
        var bitmap: Trace.Bitmap
        var subjects: SubjectSegmentation?
        var classMap: Trace.ClassMap
        /// The instance numbers per pixel, full resolution.
        var instances: [UInt8]

        init(width: Int, height: Int, names: [UInt16: String], paint: (Int, Int) -> (rgb: (UInt8, UInt8, UInt8), label: UInt16),
             subject: (Int, Int) -> UInt8 = { _, _ in 0 }) {
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            var labels = [UInt16](repeating: 0, count: width * height)
            var instances = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let (rgb, label) = paint(x, y)
                    let index = y * width + x
                    pixels[index * 4] = rgb.0
                    pixels[index * 4 + 1] = rgb.1
                    pixels[index * 4 + 2] = rgb.2
                    labels[index] = label
                    instances[index] = subject(x, y)
                }
            }
            bitmap = Trace.Bitmap(width: width, height: height, pixels: pixels)!
            classMap = Trace.ClassMap(width: width, height: height, labels: labels, names: names)!
            self.instances = instances
            var masks: [Int: SubjectMaskBuffer] = [:]
            for number in Set(instances) where number != 0 {
                masks[Int(number)] = SubjectMaskBuffer(width: width, height: height, values: instances.map { $0 == number ? 255 : 0 })!
            }
            subjects = SubjectSegmentation(width: width, height: height, instances: masks)
        }
    }

    static func inEllipse(_ x: Int, _ y: Int, cx: Double, cy: Double, rx: Double, ry: Double) -> Bool {
        let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
        return dx * dx + dy * dy <= 1
    }

    /// A portrait: sky over grass, a face (skin) above a shirt (red) -- the subject, which the
    /// class map calls Person.
    static func portrait(offset: Int = 0) -> Scene {
        func face(_ x: Int, _ y: Int) -> Bool { inEllipse(x, y, cx: 120, cy: 100, rx: 45, ry: 55) }
        func shirt(_ x: Int, _ y: Int) -> Bool { x >= 70 && x < 170 && y >= 150 }
        return Scene(width: 240, height: 280, names: [1: "Sky", 2: "Grass", 15: "Person"], paint: { x, y in
            if face(x, y) { return ((230, 190, 160), 15) }
            if shirt(x, y) { return ((200, 30, 40), 15) }
            return y < 190 ? ((120, 170, 230), 1) : ((60, 140, 60), 2)
        }, subject: { x, y in face(x - offset, y) || shirt(x - offset, y) ? 1 : 0 })
    }

    /// A street: sky, a building, the road, and two cars (instances).
    static func street() -> Scene {
        Scene(width: 300, height: 200, names: [1: "Sky", 2: "Building", 3: "Road", 7: "Vehicle"], paint: { x, y in
            if y >= 130 && y < 170 && ((x >= 30 && x < 110) || (x >= 180 && x < 270)) { return ((40, 40, 160), 7) }
            if y < 50 { return ((150, 200, 250), 1) }
            if y < 120 { return ((170, 120, 90), 2) }
            return ((90, 90, 90), 3)
        }, subject: { x, y in
            guard y >= 130 && y < 170 else { return 0 }
            return x >= 30 && x < 110 ? 1 : (x >= 180 && x < 270 ? 2 : 0)
        })
    }

    /// A still life: a wall, a table and three fruit.
    static func stillLife() -> Scene {
        let fruit: [(Double, Double, (UInt8, UInt8, UInt8))] = [(60, 110, (220, 40, 30)), (120, 115, (250, 180, 30)), (180, 110, (90, 170, 40))]
        return Scene(width: 240, height: 180, names: [4: "Wall", 5: "Table", 9: "Fruit"], paint: { x, y in
            for (cx, cy, rgb) in fruit where inEllipse(x, y, cx: cx, cy: cy, rx: 25, ry: 25) { return (rgb, 9) }
            return y < 100 ? ((200, 200, 180), 4) : ((120, 80, 50), 5)
        }, subject: { x, y in
            for (index, (cx, cy, _)) in fruit.enumerated() where inEllipse(x, y, cx: cx, cy: cy, rx: 25, ry: 25) { return UInt8(index + 1) }
            return 0
        })
    }

    static let options = Trace.Options(colors: 4)

    @Test func regionCountsOnTheFixturesStayWithinTheRecordedBounds() throws {
        let cases: [(String, Scene, ClosedRange<Int>, [String])] = [
            ("portrait", Self.portrait(), 3...4, ["Sky", "Person", "Grass", "Grass"]),
            ("street", Self.street(), 5...5, ["Building", "Road", "Sky", "Vehicle", "Vehicle"]),
            ("still life", Self.stillLife(), 5...5, ["Wall", "Table", "Fruit", "Fruit", "Fruit"]),
        ]
        for (name, scene, bounds, names) in cases {
            let result = try Trace.runPhoto(scene.bitmap, options: Self.options, subjects: scene.subjects, classMap: scene.classMap)
            #expect(bounds.contains(result.regions.count), "\(name): \(result.regions.map(\.name))")
            #expect(result.regions.map(\.name) == names, "\(name)")
            #expect(result.regions.map(\.pixelCount) == result.regions.map(\.pixelCount).sorted(by: >), "\(name): painter's order, largest first")
            #expect(result.flattened.paths.count == result.regions.reduce(0) { $0 + $1.paths.count })
        }
    }

    @Test func aLogoTracesExactlyAsClassic() throws {
        let logo = TraceFixtures.lineArt()
        let classic = try Trace.run(logo, options: Self.options)
        let photo = try Trace.runPhoto(logo, options: Self.options, subjects: nil, classMap: nil)
        #expect(photo.regions.count == 1 && photo.regions[0].name == "Background")
        #expect(photo.flattened == classic)
        #expect(Trace.Tracer.allCases == [.classic, .photo])
    }

    /// The boundary of `mask` (inside pixels with an outside 4-neighbour), as pixel centres.
    static func boundary(_ mask: [Bool], width: Int, height: Int) -> [Point] {
        var points: [Point] = []
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                let neighbours: [(Int, Int)] = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                let outside = neighbours.contains { (nx: Int, ny: Int) -> Bool in
                    if nx < 0 || ny < 0 || nx >= width || ny >= height { return true }
                    return !mask[ny * width + nx]
                }
                if outside { points.append(Point(x: Double(x) + 0.5, y: Double(y) + 0.5)) }
            }
        }
        return points
    }

    @Test func thePortraitsSubjectTracesWithin3PxOfTheReferenceEdge() throws {
        let scene = Self.portrait()
        let result = try Trace.runPhoto(scene.bitmap, options: Self.options, subjects: scene.subjects, classMap: scene.classMap)
        let person = try #require(result.regions.first { $0.name == "Person" })
        let union = Boolean.union(person.paths.map { FilledPath(contours: $0.contours) })
        let reference = Self.boundary(scene.instances.map { $0 != 0 }, width: 240, height: 280)
        var samples: [Point] = []
        for contour in union.contours {
            for segment in contour.segments {
                for step in 0..<32 { samples.append(segment.evaluate(Double(step) / 32)) }
            }
        }
        #expect(samples.count > 100)
        let within = samples.filter { sample in reference.contains { $0.distance(to: sample) <= 3 } }.count
        #expect(Double(within) / Double(samples.count) >= 0.95, "\(within) of \(samples.count)")
    }

    @Test func regionEdgesSnapToTheColourEdge() throws {
        // The subject mask sits 2 px right of the face and shirt in the picture.
        let scene = Self.portrait(offset: 2)
        let regions = try Trace.Segmenter.segment(scene.bitmap, subjects: scene.subjects, classMap: scene.classMap)
        let person = try #require(regions.names.firstIndex(of: "Person"))
        let truth = Self.portrait().instances.map { $0 != 0 }
        let mask = regions.labels.map { $0 == Int32(person) }
        let edge = Self.boundary(mask, width: 240, height: 280)
        let reference = Self.boundary(truth, width: 240, height: 280)
        let close = edge.filter { point in reference.contains { $0.distance(to: point) <= 1.01 } }.count
        #expect(Double(close) / Double(edge.count) >= 0.9, "\(close) of \(edge.count)")
    }

    @Test func withoutTheModelTheRegionsAreSubjectAndBackground() throws {
        let scene = Self.portrait()
        let result = try Trace.runPhoto(scene.bitmap, options: Self.options, subjects: scene.subjects, classMap: nil)
        #expect(result.regions.map(\.name) == ["Background", "Subject"])
        #expect(CoreMLClassMapper.bundled(in: Bundle.main) == nil, "this build carries no model")
        #expect(Trace.ClassMap(width: 2, height: 2, labels: [1], names: [:]) == nil)
        #expect(Trace.ClassMap(width: 0, height: 2, labels: [], names: [:]) == nil)
    }

    @Test func smallRegionsMergeAndUnlabelledOnesAreNumbered() throws {
        // A 3 × 3 speckle of another class inside the wall, and an unlabelled band at the bottom.
        let scene = Scene(width: 60, height: 60, names: [4: "Wall"], paint: { x, y in
            if x >= 20 && x < 23 && y >= 20 && y < 23 { return ((10, 10, 10), 8) }
            return y < 40 ? ((200, 200, 180), 4) : ((50, 50, 50), 0)
        })
        let regions = try Trace.Segmenter.segment(scene.bitmap, subjects: nil, classMap: scene.classMap)
        #expect(regions.names == ["Wall", "Region 1"], "the speckle (9 px) merges into the wall")
        #expect(regions.counts.reduce(0, +) == 3600)
        // With a larger noise tolerance the band (1200 px) merges too.
        let merged = try Trace.Segmenter.segment(scene.bitmap, subjects: nil, classMap: scene.classMap, noiseTolerance: 40)
        #expect(merged.names == ["Wall"])
        let traced = try Trace.runPhoto(scene.bitmap, options: Trace.Options(colors: 2, noiseTolerance: 40), subjects: nil, classMap: scene.classMap)
        #expect(traced.regions.count == 1 && traced.regions[0].name == "Wall")
    }

    @Test func aSubjectWithoutAClassUnderItIsASubject() throws {
        let scene = Scene(width: 40, height: 40, names: [:], paint: { x, y in
            x >= 10 && x < 30 && y >= 10 && y < 30 ? ((200, 0, 0), 0) : ((255, 255, 255), 0)
        }, subject: { x, y in x >= 10 && x < 30 && y >= 10 && y < 30 ? 1 : 0 })
        let regions = try Trace.Segmenter.segment(scene.bitmap, subjects: scene.subjects, classMap: scene.classMap)
        #expect(Set(regions.names) == ["Subject", "Region 1"])
    }

    @Test func cancellationStopsTheTracePromptly() async throws {
        let scene = Self.portrait()
        var polls = 0
        #expect(throws: Trace.Cancelled.self) {
            try Trace.runPhoto(scene.bitmap, options: Self.options, subjects: scene.subjects, classMap: scene.classMap, isCancelled: {
                polls += 1
                return polls > 400
            })
        }
        // The async entry: cancelled mid-trace, it returns promptly.
        let big = TraceFixtures.photograph(width: 1600, height: 1200)
        let task = Task {
            try await Trace.tracePhoto(big, image: nil, options: Trace.Options(colors: 32), segmenter: nil, mapper: nil)
        }
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        _ = await task.result
        #expect(clock.now - start < .milliseconds(500), "cancellation returns promptly (100 ms on an idle M1)")
    }

    struct FakeSegmenter: SubjectSegmenter {
        let result: SubjectSegmentation?
        func segment(_ image: CGImage) throws -> SubjectSegmentation? { result }
    }

    struct FakeMapper: Trace.ClassMapping {
        let map: Trace.ClassMap
        func classMap(for image: CGImage) throws -> Trace.ClassMap? { map }
    }

    static func image(_ bitmap: Trace.Bitmap) -> CGImage {
        let provider = CGDataProvider(data: Data(bitmap.pixels) as CFData)!
        return CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func theAsyncEntrySegmentsWithTheInjectedKernels() async throws {
        let scene = Self.street()
        let result = try await Trace.tracePhoto(scene.bitmap, image: Self.image(scene.bitmap), options: Self.options,
                                                segmenter: FakeSegmenter(result: scene.subjects), mapper: FakeMapper(map: scene.classMap))
        #expect(result.regions.count == 5)
        let fallback = try await Trace.tracePhoto(scene.bitmap, image: nil, options: Self.options, segmenter: FakeSegmenter(result: scene.subjects),
                                                  mapper: nil)
        #expect(fallback.regions.count == 1, "without an image there is nothing to segment: the classic trace")
    }

    @Test func aFourMegapixelTraceMeetsItsBudget() throws {
        let side = PerfBudget.isMeasuring ? 2000 : 300
        let bitmap = TraceFixtures.photograph(width: side, height: side)
        let map = Trace.ClassMap(width: 3, height: 3, labels: [1, 1, 1, 2, 2, 2, 3, 3, 3], names: [1: "Sky", 2: "Sand", 3: "Grass"])!
        let clock = ContinuousClock()
        let start = clock.now
        let result = try Trace.runPhoto(bitmap, options: Trace.Options(colors: 16), subjects: nil, classMap: map)
        let elapsed = clock.now - start
        #expect(result.regions.count == 3)
        PerfBudget.expect(elapsed, within: .seconds(6), "\(side) x \(side) px photo trace")
    }
}
