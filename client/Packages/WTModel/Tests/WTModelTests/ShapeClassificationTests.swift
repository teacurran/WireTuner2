import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// IMG-030: Select Similar's *Shape* over the bundled classifier.
@Suite struct ShapeClassificationTests {
    /// The bundled model (client/WTApp/Objects/Resources; this file is client/Packages/WTModel/Tests/WTModelTests/…).
    static let modelURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WTApp/Objects/Resources/ShapeClassifier.wtmodel")

    static func classification() async throws -> ShapeClassification {
        ShapeClassification(classifier: try await ShapeClassifier.load(modelAt: modelURL))
    }

    /// A command creating one node of `props` on the drawing layer.
    struct CreateRaw: Command {
        var props: Wiretuner_Doc_V1_NodeProps
        var label: String { "Raw" }

        func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
            let layer = try PathEditing.ensureLayer(&builder, state: state)
            builder.append(Ops.create(parent: layer, position: try PathEditing.topPosition(in: layer, state: state), props: props))
        }
    }

    static func appearance(_ red: Double) -> Wiretuner_Doc_V1_AppearanceProps {
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: red, green: 0.2, blue: 0.4)]
        return appearance
    }

    /// A page of mixed primitives: circles of three sizes, rotations and colours, rectangles,
    /// ellipses, a star and a triangle.
    struct Page {
        var a = Replica(0xA)
        var page: OpID
        var circles: [OpID] = []
        var rectangles: [OpID] = []
        var others: [OpID] = []

        init() throws {
            page = try PageFixture.onePage(&a)
            for (index, (size, angle)) in [(20.0, 0.0), (90.0, 0.7), (200.0, 2.1)].enumerated() {
                let transform = AffineTransform.rotation(radians: angle).concatenating(.translation(x: 60 + Double(index) * 150, y: 100))
                circles.append(try a.perform(CreateShape(.ellipse, size: Size(width: size, height: size), transform: transform,
                                                         appearance: ShapeClassificationTests.appearance(Double(index) / 3)))!.createdObjects[0])
            }
            for (index, (width, height)) in [(40.0, 40.0), (120.0, 30.0), (60.0, 90.0)].enumerated() {
                let transform = AffineTransform.rotation(radians: Double(index) * 0.4).concatenating(.translation(x: 60 + Double(index) * 150, y: 400))
                rectangles.append(try a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: width, height: height), transform: transform,
                                                            appearance: ShapeClassificationTests.appearance(0.5)))!.createdObjects[0])
            }
            others.append(try a.perform(CreateShape(.ellipse, size: Size(width: 120, height: 40), transform: .translation(x: 300, y: 600)))!.createdObjects[0])
            let star = (0..<10).map { index -> VectorPoint in
                let radius = index % 2 == 0 ? 40.0 : 16
                return VectorPoint(anchor: Point(x: 150 + radius * cos(Double(index) * .pi / 5), y: 650 + radius * sin(Double(index) * .pi / 5)))
            }
            others.append(try a.perform(CreatePath(contours: [NewContour(closed: true, points: star)]))!.createdObjects[0])
            let triangle = [(450.0, 700.0), (520.0, 700.0), (480.0, 630.0)].map { VectorPoint(anchor: Point(x: $0.0, y: $0.1)) }
            others.append(try a.perform(CreatePath(contours: [NewContour(closed: true, points: triangle)]))!.createdObjects[0])
        }
    }

    @Test func shapeOnACircleSelectsEveryCircleAndNoRectangles() async throws {
        var f = try Page()
        let classification = try await Self.classification()
        #expect(SelectSimilar.items(classifier: classification).contains(.shape))
        let outcome = try #require(SelectSimilar.run(.shape, selection: [f.circles[0]], page: f.page, classifier: classification, in: f.a.state))
        #expect(Set(outcome.selection) == Set(f.circles), "every circle, whatever its size, rotation and colour")
        #expect(outcome.found == 3 && outcome.status == "3 objects selected")
        let rectangles = try #require(SelectSimilar.run(.shape, selection: [f.rectangles[1]], page: f.page, classifier: classification, in: f.a.state))
        #expect(Set(rectangles.selection) == Set(f.rectangles))
        #expect(classification.shapeClass(of: f.others[0], in: f.a.state) == "ellipse")
        #expect(classification.shapeClass(of: f.others[1], in: f.a.state) == "star")
        #expect(classification.shapeClass(of: f.others[2], in: f.a.state) == "triangle")
        // A group, a text block and an image are classed without the model; a layer has no class.
        let group = try #require(try f.a.perform(GroupObjects([f.others[1], f.others[2]]))?.createdObjects.first)
        let text = try #require(try f.a.perform(CreateTextBlock(.point(Point(x: 20, y: 20)), text: "Hi"))?.createdObjects.first)
        var image = Wiretuner_Doc_V1_NodeProps()
        image.image = Wiretuner_Doc_V1_ImageProps()
        let picture = try #require(try f.a.perform(CreateRaw(props: image))?.createdNodes.first)
        #expect(classification.classes(of: [group, text, picture], in: f.a.state) == [.group, .text, .image])
        let layer = try #require(LayerOrder(f.a.state).drawingLayer)
        #expect(ShapeKinds.reading(layer, in: f.a.state) == .none && classification.classes(of: [layer], in: f.a.state) == [nil])
        // An outline with nothing renderable, or without length, has no class.
        let empty = try #require(try f.a.perform(CreatePath(contours: [NewContour(closed: false, points: [])]))?.createdObjects.first)
        #expect(ShapeKinds.contours(of: empty, in: f.a.state) == nil)
        let dot = try #require(try f.a.perform(CreatePath(contours: [NewContour(closed: false, points: [VectorPoint(anchor: Point(x: 5, y: 5)),
                                                                                                         VectorPoint(anchor: Point(x: 5, y: 5))])]))?.createdObjects.first)
        #expect(classification.classes(of: [dot, f.circles[0]], in: f.a.state) == [nil, .circle])
        #expect(SelectSimilar.run(.shape, selection: [f.page], page: f.page, classifier: classification, in: f.a.state) == nil, "not an object")
        #expect(SelectSimilar.candidates(page: OpID(counter: 999, replica: 9), in: f.a.state) == nil)
    }

    @Test func classesAreCachedUntilTheGeometryChanges() async throws {
        var f = try Page()
        let classification = try await Self.classification()
        let nodes = f.circles + f.rectangles + f.others
        await classification.prepare(nodes, in: f.a.state, chunk: 4)
        #expect(classification.classified == nodes.count)
        _ = classification.classes(of: nodes, in: f.a.state)
        #expect(classification.classified == nodes.count, "all cached")
        // Not geometry: still cached.  A new size: that one again.
        try f.a.perform(SetLocked([f.circles[0]], locked: true))
        #expect(classification.shapeClass(of: f.circles[0], in: f.a.state) == "circle" && classification.classified == nodes.count)
        try f.a.perform(SetShapeSize(node: f.circles[1], size: Size(width: 90, height: 30)))
        #expect(classification.shapeClass(of: f.circles[1], in: f.a.state) == "ellipse" && classification.classified == nodes.count + 1)
        classification.reset()
        _ = classification.classes(of: [f.circles[2]], in: f.a.state)
        #expect(classification.classified == nodes.count + 2)
    }

    @Test func aPageOfFiveThousandPathsClassifiesWithinTheBudget() async throws {
        var a = Replica(0xA)
        let classification = try await Self.classification()
        try a.perform(CreateShape(.ellipse, size: Size(width: 20, height: 20)))
        var shapes: [any Command] = []
        for index in 1..<5000 {
            let x = Double(index % 70) * 30, y = Double(index / 70) * 30
            switch index % 3 {
            case 0: shapes.append(CreateShape(.ellipse, size: Size(width: 20, height: 20), transform: .translation(x: x, y: y)))
            case 1: shapes.append(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 10), transform: .translation(x: x, y: y)))
            default: shapes.append(CreatePath(contours: [NewContour(closed: true, points: [Point(x: x, y: y), Point(x: x + 20, y: y), Point(x: x + 8, y: y + 18)]
                .map { VectorPoint(anchor: $0) })]))
            }
        }
        try a.perform(CompositeCommand("Page", shapes))
        let nodes = try #require(SelectSimilar.candidates(page: nil, in: a.state))
        #expect(nodes.count == 5000)
        let clock = ContinuousClock()
        let elapsed = await clock.measure { await classification.prepare(nodes, in: a.state) }
        #expect(classification.classified == 5000)
        #expect(Set(classification.classes(of: nodes, in: a.state)) == [.circle, .rectangle, .triangle] && classification.classified == 5000)
        PerfBudget.expect(elapsed, within: .milliseconds(300), "a page of 5,000 paths classified")
    }
}
