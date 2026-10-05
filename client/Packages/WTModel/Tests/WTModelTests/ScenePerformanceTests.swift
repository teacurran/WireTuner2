import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// D-094: a single edit brings the scene of a 50,000-object document up to date without walking
/// every object.  Each edit's change is made by its command (not timed), then the builder's
/// `apply` is timed; the scene must equal a full rebuild after the run.  Budgets hold in release
/// perf runs (`PerfBudget`); every run prints its figures.
@Suite(.serialized) struct ScenePerformanceTests {
    /// Rectangles on one layer, alternately filled and stroked, on a 250-wide grid: the app's
    /// `CanvasPerformanceTests.denseDocument()` in the model.
    struct Dense: Command {
        let count: Int
        var label: String { "Dense" }

        func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
            var layer = Wiretuner_Doc_V1_NodeProps()
            layer.layer.visible = true
            layer.layer.printing = true
            let parent = builder.append(Ops.create(parent: WellKnown.layers, position: [0x80], props: layer))
            var previous: [UInt8]?
            for index in 0..<count {
                let position = try FractionalIndex.between(previous, nil, suffix: UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
                previous = position
                var props = Wiretuner_Doc_V1_NodeProps()
                props.rect.size.width = 22
                props.rect.size.height = 22
                props.rect.common.transform.a = 1
                props.rect.common.transform.d = 1
                props.rect.common.transform.tx = 4000 + Double(index % 250) * 30
                props.rect.common.transform.ty = 4000 + Double(index / 250) * 30
                let node = builder.append(Ops.create(parent: parent, position: position, props: props))
                var values = Wiretuner_Doc_V1_NodeProps()
                if index.isMultiple(of: 2) {
                    values.rect.appearance.fills = [Appearances.basicFill(red: Double(index % 250) / 250, green: Double(index / 250) / 200, blue: 0.5)]
                    builder.append(Ops.elementInsert(node, RegisterPath([21, 4, 1]), positions: [[0x80]], values: values))
                } else {
                    values.rect.appearance.strokes = Appearances.standard.strokes
                    builder.append(Ops.elementInsert(node, RegisterPath([21, 4, 2]), positions: [[0x80]], values: values))
                }
            }
        }
    }

    static let objectCount = 50_000

    /// One timed edit: the command's change applied to the builder, in milliseconds.
    static func timed(_ replica: inout Replica, _ builder: inout DocumentDisplayListBuilder, _ command: any Command)
        throws -> (milliseconds: Double, summary: ChangeSummary) {
        let change = try #require(try replica.perform(command))
        let clock = ContinuousClock()
        var summary = ChangeSummary()
        let elapsed = clock.measure {
            summary = builder.apply(change, state: replica.state, origin: .local).1
        }
        return (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15, summary)
    }

    @Test func singleEditsOnFiftyThousandObjectsAreIncremental() throws {
        var replica = Replica(0xD5)
        try replica.perform(Dense(count: Self.objectCount))
        var builder = DocumentDisplayListBuilder(canvas: "dense")
        let clock = ContinuousClock()
        let open = clock.measure { builder.rebuild(replica.state) }
        let layer = try #require(LayerOrder(replica.state).layers.first { !replica.state.liveChildren($0.id).isEmpty }?.id)
        let objects = replica.state.liveChildren(layer)
        #expect(builder.scene.topLevel.count == Self.objectCount)
        let red = ColorResolver.inline(Color(red: 1, green: 0, blue: 0))
        let edits: [(String, any Command, Duration)] = [
            ("rename", SetNameOrNote([objects[100]], .name, "Tile"), .milliseconds(4)),
            ("recolour", ApplyColor([objects[200]], target: .fill, color: red), .milliseconds(4)),
            ("move", MoveObjects([objects[300]], by: Vector(dx: 5, dy: 7)), .milliseconds(4)),
            ("restack to front", RestackObjects([objects[400]], into: layer, at: 0), .milliseconds(16)),
            ("restack to back", RestackObjects([objects[500]], into: layer, at: Self.objectCount), .milliseconds(16)),
            ("delete", ClearObjects([objects[600]]), .milliseconds(16)),
        ]
        var figures: [String] = []
        for (name, command, budget) in edits + [("rename again", SetNameOrNote([objects[700]], .name, "Tile 2"), Duration.milliseconds(4))] {
            let (milliseconds, summary) = try Self.timed(&replica, &builder, command)
            #expect(!summary.touchedNodes.isEmpty, "\(name) names what it touched")
            #expect(summary.touchedNodes.count < 100, "\(name) names only what it touched, not the layer's objects")
            figures.append("\(name) \(String(format: "%.2f", milliseconds)) ms")
            PerfBudget.expect(.milliseconds(milliseconds), within: budget, "D-094 scene update, 50,000 objects: \(name)")
        }
        print("PERF D-094 scene, \(Self.objectCount) objects: open \(open); " + figures.joined(separator: ", "))
        // The incremental scene is the one a full rebuild makes.
        var fresh = DocumentDisplayListBuilder(canvas: "dense")
        #expect(fresh.rebuild(replica.state) == builder.scene)
        #expect(builder.patches == edits.count + 1, "every edit was patched")
        // The same rename through the full build every change made before D-094, for comparison
        // (release perf runs only: a debug build takes a minute).
        if PerfBudget.isMeasuring {
            fresh.incremental = false
            let (milliseconds, _) = try Self.timed(&replica, &fresh, SetNameOrNote([objects[800]], .name, "Full"))
            print("PERF D-094 scene, \(Self.objectCount) objects: rename through a full build \(String(format: "%.2f", milliseconds)) ms")
            PerfBudget.record(String(format: "%.2f ms", milliseconds), "D-094 scene update, 50,000 objects: rename through a full build (before D-094)")
        }
    }
}
