import Foundation
import Testing
@testable import WTGeometry

/// IMG-030: the feature vector and the bundled shape model.
@Suite struct ShapeClassifierTests {
    /// The repository root (this file is client/Packages/WTGeometry/Tests/WTGeometryTests/…).
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let modelURL = repository.appendingPathComponent("client/WTApp/Objects/Resources/ShapeClassifier.wtmodel")
    static let fixturesURL = repository.appendingPathComponent("tools/shape-classifier/fixtures.txt")

    /// Path data of absolute M, L, C and Z (what the fixture set is written in).
    static func parse(_ d: String) -> [Contour] {
        var contours: [Contour] = []
        var segments: [CubicBezier] = []
        var numbers: [Double] = []
        var command: Character = "M"
        var current = Point.zero, start = Point.zero
        func point(_ index: Int) -> Point { Point(x: numbers[index], y: numbers[index + 1]) }
        func add(_ value: Double) {
            numbers.append(value)
            switch (command, numbers.count) {
            case ("M", 2):
                if !segments.isEmpty { contours.append(Contour(segments: segments, closed: false)) }
                segments = []
                current = point(0)
                start = current
            case ("L", 2):
                segments.append(Line(start: current, end: point(0)).elevated())
                current = point(0)
            case ("C", 6):
                segments.append(CubicBezier(current, point(0), point(2), point(4)))
                current = point(4)
            default:
                return
            }
            numbers = []
        }
        for token in d.split(separator: " ") {
            guard let first = token.first else { continue }
            if first.isLetter {
                command = first
                numbers = []
                if first == "Z" {
                    if current.distance(to: start) > 1e-9 { segments.append(Line(start: current, end: start).elevated()) }
                    contours.append(Contour(segments: segments, closed: true))
                    segments = []
                    current = start
                } else if let value = Double(token.dropFirst()) {
                    add(value)
                }
            } else if let value = Double(token) {
                add(value)
            }
        }
        if !segments.isEmpty { contours.append(Contour(segments: segments, closed: false)) }
        return contours
    }

    static func fixtures() throws -> [(label: ShapeClass, contours: [Contour])] {
        try String(contentsOf: fixturesURL, encoding: .utf8).split(separator: "\n").map { line in
            let fields = line.split(separator: "\t", maxSplits: 2)
            return (ShapeClass(rawValue: String(fields[0]))!, parse(String(fields[2])))
        }
    }

    static func polygon(_ points: [(Double, Double)], closed: Bool = true) -> Contour {
        Contour(polygon: points.map { Point(x: $0.0, y: $0.1) }, closed: closed)
    }

    static let square = polygon([(0, 0), (10, 0), (10, 10), (0, 10)])

    // MARK: Features

    @Test func featuresIgnorePlacementSizeRotationStartAndDirection() throws {
        let points = [(0.0, 0.0), (40.0, 0.0), (40.0, 10.0), (10.0, 25.0), (0.0, 10.0)]
        let reference = try #require(ShapeFeatures([Self.polygon(points)]))
        let moved = Self.polygon(points).applying(.rotation(radians: 1.1).concatenating(.scale(7)).concatenating(.translation(x: 300, y: -40)))
        let restarted = Self.polygon(Array(points[2...] + points[..<2]))
        let reversed = Self.polygon(points.reversed())
        for variant in [moved, restarted, reversed] {
            let features = try #require(ShapeFeatures([variant]))
            let distance = zip(reference.values, features.values).map { abs($0 - $1) }.max() ?? 0
            #expect(distance < 0.2, "every value within 0.2 (\(distance))")
            #expect(features.corners == reference.corners && features.closed)
        }
        #expect(reference.points.count == ShapeFeatures.pointCount && reference.values.count == ShapeFeatures.names.count)
        #expect(Set(ShapeFeatures.names).count == ShapeFeatures.names.count)
    }

    @Test func theScalarsDescribeTheOutline() throws {
        let square = try #require(ShapeFeatures([Self.square]))
        #expect(square.corners == 4 && square.holes == 0 && square.contours == 1 && square.closed)
        #expect(abs(square.convexity - 1) < 1e-9 && abs(square.aspect - 1) < 1e-6 && abs(square.circularity - .pi / 4) < 1e-6)
        let star = (0..<10).map { index -> (Double, Double) in
            let radius = index % 2 == 0 ? 10.0 : 4
            return (radius * cos(Double(index) * .pi / 5), radius * sin(Double(index) * .pi / 5))
        }
        let starFeatures = try #require(ShapeFeatures([Self.polygon(star)]))
        #expect(starFeatures.corners == 10 && starFeatures.convexity < 0.8)
        // A ring: the hole is counted, and the outer outline is the main one.
        let ring = try #require(ShapeFeatures([Self.square.applying(.scale(3)), Self.square.applying(.translation(x: 10, y: 10))]))
        #expect(ring.holes == 1 && ring.contours == 2 && ring.corners == 4)
        // A thin rectangle: aspect near 0; an open line: not closed, no circularity.
        #expect(try #require(ShapeFeatures([Self.polygon([(0, 0), (100, 0), (100, 1), (0, 1)])])).aspect < 0.05)
        let line = try #require(ShapeFeatures([Self.polygon([(10, 0), (0, 0)], closed: false)]))
        #expect(!line.closed && line.circularity == 0 && line.corners == 0 && line.aspect < 1e-6 && line.convexity == 1)
        #expect(line.points.first!.x < line.points.last!.x, "an open outline starts at its left end")
        // A curve: smooth joints are not corners.
        let k = 0.5523
        let circle = Contour(segments: [
            CubicBezier(Point(x: 1, y: 0), Point(x: 1, y: k), Point(x: k, y: 1), Point(x: 0, y: 1)),
            CubicBezier(Point(x: 0, y: 1), Point(x: -k, y: 1), Point(x: -1, y: k), Point(x: -1, y: 0)),
            CubicBezier(Point(x: -1, y: 0), Point(x: -1, y: -k), Point(x: -k, y: -1), Point(x: 0, y: -1)),
            CubicBezier(Point(x: 0, y: -1), Point(x: k, y: -1), Point(x: 1, y: -k), Point(x: 1, y: 0)),
        ], closed: true)
        let round = try #require(ShapeFeatures([circle]))
        #expect(round.corners == 0 && round.circularity > 0.99 && round.aspect > 0.99)
        // Nothing with length: no features.
        #expect(ShapeFeatures([]) == nil)
        #expect(ShapeFeatures([Contour(segments: [], closed: true)]) == nil)
        #expect(ShapeFeatures([Self.polygon([(3, 3), (3, 3)], closed: false)]) == nil)
        // A degenerate segment is not a corner.
        let doubled = Contour(segments: Self.square.segments + [Line(start: Point(x: 0, y: 0), end: Point(x: 0, y: 0)).elevated()], closed: true)
        #expect(try #require(ShapeFeatures([doubled])).corners == 4)
        #expect(ShapeFeatures.corners(of: Self.polygon([(0, 0), (1, 0)], closed: false), scale: 1) == 0)
    }

    @Test func geometryHelpers() {
        #expect(ShapeFeatures.convexHull([Point(x: 0, y: 0), Point(x: 1, y: 1)]).count == 2)
        #expect(ShapeFeatures.signedArea([Point(x: 0, y: 0), Point(x: 1, y: 1)]) == 0)
        #expect(ShapeFeatures.length([Point(x: 0, y: 0)], closed: true) == 0)
        #expect(ShapeFeatures.polyline(Contour(segments: [], closed: false)).points.isEmpty)
        #expect(ShapeFeatures.inside(Point(x: 5, y: 5), [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 10), Point(x: 0, y: 10)]))
        #expect(!ShapeFeatures.inside(Point(x: 15, y: 5), [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 10), Point(x: 0, y: 10)]))
        #expect(ShapeClass.modelled.count == 11 && ShapeClass(rawValue: "rounded_rectangle") == .roundedRectangle)
    }

    // MARK: The model

    @Test func theBundledModelReachesTheAccuracyOnTheFixtureSet() async throws {
        let classifier = try await ShapeClassifier.load(modelAt: Self.modelURL)
        let fixtures = try Self.fixtures()
        #expect(fixtures.count >= 2000)
        #expect(Set(fixtures.map(\.label)) == Set(ShapeClass.modelled), "every class is in the set")
        let features = fixtures.map { ShapeFeatures($0.contours) }
        #expect(features.allSatisfy { $0 != nil })
        let predicted = classifier.classify(features.compactMap { $0 })
        let correct = zip(fixtures, predicted).filter { $0.0.label == $0.1 }.count
        let accuracy = Double(correct) / Double(fixtures.count)
        #expect(accuracy >= 0.92, "accuracy \(accuracy)")
        let parallel = await classifier.classifyInBackground(features.compactMap { $0 }, chunk: 300)
        #expect(parallel == predicted)
        #expect(classifier.classify([]) .isEmpty && classifier.classify(features[0]!) == predicted[0])
        // A file that is not a model does not load.
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).wtmodel")
        try Data("not a model".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        await #expect(throws: (any Error).self) { try await ShapeClassifier.load(modelAt: junk) }
        #expect(throws: (any Error).self) { try ShapeClassifier(compiledModelAt: junk) }
        let provider = ShapeClassifier.provider(features[0]!)
        #expect(provider.featureNames.count == ShapeFeatures.names.count && provider.featureValue(for: "nothing") == nil)
    }

    @Test func fiveThousandPathsClassifyWithinTheBudget() async throws {
        let classifier = try await ShapeClassifier.load(modelAt: Self.modelURL)
        let fixtures = try Self.fixtures()
        let page = (0..<5000).map { fixtures[$0 % fixtures.count].contours }
        _ = classifier.classify([ShapeFeatures(page[0])!])
        let clock = ContinuousClock()
        var classes: [ShapeClass?] = []
        let elapsed = await clock.measure {
            classes = await withTaskGroup(of: (Int, [ShapeFeatures]).self) { group in
                for start in stride(from: 0, to: page.count, by: 500) {
                    group.addTask { (start, page[start..<min(start + 500, page.count)].compactMap { ShapeFeatures($0) }) }
                }
                var features = [[ShapeFeatures]](repeating: [], count: 10)
                for await (start, chunk) in group { features[start / 500] = chunk }
                return await classifier.classifyInBackground(features.flatMap { $0 })
            }
        }
        #expect(classes.count == 5000 && classes.allSatisfy { $0 != nil })
        PerfBudget.expect(elapsed, within: .milliseconds(300), "5,000 paths classified (features and model)")
    }
}
