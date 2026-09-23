import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The connectors' frame budget through the model (DRAW-035, connectors.adoc "Done when": moving a
/// node with 1,000 attached connectors invalidates and re-renders within one frame): the move
/// command, then the scene brought up to the change -- the moved object and its 1,000 connectors
/// rebuilt and rerouted, every other item reused -- with the change summary.
@Suite struct ConnectorPerformanceTests {
    /// A hub box and 1,000 boxes on a grid, each joined to the hub by a connector.
    struct Fan {
        var replica = Replica(7)
        let hub: OpID
        var connectors: [OpID] = []

        init(count: Int) throws {
            hub = try ConnectorTests.Boxes.box(&replica, x: 1500, y: 1500)
            for index in 0..<count {
                let x = Double(index % 40) * 30, y = Double(index / 40) * 30
                let box = try ConnectorTests.Boxes.box(&replica, x: x, y: y)
                connectors.append(try replica.perform(CreateConnector(start: ConnectorEnd(node: NodeID(box), point: Point(x: x + 21, y: y + 10)),
                                                                      end: ConnectorEnd(node: NodeID(hub), point: Point(x: 1499, y: 1510))))!.createdObjects[0])
            }
        }
    }

    /// One move of the hub: the command and the scene update, in milliseconds, with the summary.
    static func move(_ fan: inout Fan, _ builder: inout DocumentDisplayListBuilder, by delta: Vector) throws -> (Double, DocumentScene, ChangeSummary) {
        let clock = ContinuousClock()
        var result: (DocumentScene, ChangeSummary)?
        let elapsed = try clock.measure {
            let change = try fan.replica.perform(MoveObjects([fan.hub], by: delta))!
            result = builder.apply(change, state: fan.replica.state, origin: .local)
        }
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return (milliseconds, result!.0, result!.1)
    }

    /// The full volume in a perf run (`PerfBudget.isMeasuring`); other runs check the same
    /// behaviour on 100 connectors.
    static let count = PerfBudget.isMeasuring ? 1000 : 100

    @Test func movingAnObjectWithAThousandConnectorsRebuildsWithinAFrame() throws {
        var fan = try Fan(count: Self.count)
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let initial = builder.rebuild(fan.replica.state)
        #expect(initial.objects.count == 2 * Self.count + 1)
        // A connector's dependency sources name the hub it joins (and the other box and the layer).
        let sources = Connectors.dependencySources(of: fan.connectors[0], in: fan.replica.state)
        #expect(sources.contains(fan.hub))
        let hubBefore = try #require(initial.object(fan.hub)?.bounds)
        var timings: [Double] = []
        var scene = initial
        var summary = ChangeSummary(origin: .local)
        // Back and forth: every move reroutes all 1,000; the median is the figure.
        for step in 0..<7 {
            let delta = Vector(dx: step.isMultiple(of: 2) ? 40 : -40, dy: step.isMultiple(of: 2) ? 25 : -25)
            let (milliseconds, moved, changed) = try Self.move(&fan, &builder, by: delta)
            timings.append(milliseconds)
            scene = moved
            summary = changed
        }
        // Odd number of moves: the hub ends 40, 25 from where it started.
        let hubAfter = try #require(scene.object(fan.hub)?.bounds)
        #expect(abs(hubAfter.minX - hubBefore.minX - 40) < 1e-9 && abs(hubAfter.minY - hubBefore.minY - 25) < 1e-9)
        // Every connector is named by the summary and ends at the middle of a side of the moved hub.
        let named = summary.touchedNodes
        #expect(fan.connectors.allSatisfy { named.contains(NodeID($0)) })
        let hub = try #require(scene.object(fan.hub))
        let rect = try #require(Connectors.attachmentBounds(of: hub.item))
        let entries = [ConnectorSide.top, .bottom, .left, .right].map { $0.midpoint(of: rect) }
        for connector in fan.connectors {
            let points = ConnectorTests.points(scene.object(connector)?.item)
            let last = try #require(points.last)
            #expect(entries.contains { abs($0.x - last.x) < 1e-9 && abs($0.y - last.y) < 1e-9 })
        }
        // The same scene as a full rebuild from the merged state.
        var fresh = DocumentDisplayListBuilder(canvas: "c")
        #expect(fresh.rebuild(fan.replica.state) == scene)
        let median = timings.sorted()[timings.count / 2]
        print("PERF connectors (model): move 1 object with \(Self.count) connectors, command + scene update, median \(String(format: "%.1f", median)) ms "
            + "of \(timings.map { String(format: "%.1f", $0) }.joined(separator: ", "))")
        // One frame at 60 fps, held in the perf run (docs/spec/testing.adoc, "Client budgets").
        PerfBudget.expect(.milliseconds(median), within: .milliseconds(16.7))
    }
}
