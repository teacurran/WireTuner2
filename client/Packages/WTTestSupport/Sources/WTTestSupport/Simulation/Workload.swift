import Foundation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The edits simulated people make, as the app makes them: WTModel commands against the client's
/// merged state, performed through its `Document` (docs/spec/testing.adoc, "Multi-client
/// simulation").  Every edit reads the current state, so concurrent deletes and moves are met as
/// a user meets them; a command that no longer applies is skipped, not failed.
@MainActor
public enum Workload {
    /// Creates an open path through `count` points on `client` and returns its node and contour.
    public static func createPath(_ client: SimClient, points count: Int) async throws -> (node: OpID, contour: OpID) {
        let points = (0..<count).map { VectorPoint(anchor: Point(x: Double($0) * 10, y: Double(($0 * 7) % 13))) }
        let node = try created(await client.perform(CreatePath(contours: [NewContour(points: points)])), by: client, "a path")[0]
        return (node, client.state.liveElements(node, PathFields.contours)[0])
    }

    /// The objects `change` created; throws when it created none.
    static func created(_ change: Wiretuner_Doc_V1_Change?, by client: SimClient, _ what: String) throws -> [OpID] {
        guard let objects = change?.createdObjects, !objects.isEmpty else {
            throw Simulation.Failure(description: "\(client.name) could not create \(what)")
        }
        return objects
    }

    /// Creates `count` rectangles on `client` in one change and returns them in order.
    public static func createShapes(_ client: SimClient, count: Int) async throws -> [OpID] {
        var commands: [any Command] = []
        for index in 0..<count {
            let place = WTGeometry.AffineTransform.translation(x: Double(index % 20) * 20, y: Double(index / 20) * 20)
            commands.append(CreateShape(.rectangle(CornerRadii.uniform(0)), size: Size(width: 10, height: 10), transform: place))
        }
        return try created(await client.perform(CompositeCommand("Shapes", commands)), by: client, "shapes")
    }

    /// One edit of the path `node`: move a point, add one after a point, delete one (while more
    /// than three remain) or pull a point's handles -- chosen by `random`.
    @discardableResult
    public static func editPath(_ client: SimClient, _ node: OpID, _ random: inout SimRandom) async -> Wiretuner_Doc_V1_Change? {
        let state = client.state
        guard state.isLive(node) else { return nil }
        let path = VectorPath(state.props(node).path, node: node, state: state)
        guard let contour = path.contours.first(where: { !$0.points.isEmpty }) else { return nil }
        let point = random.pick(contour.points)
        let x = Double(random.within(0...400))
        let y = Double(random.within(0...400))
        switch random.below(10) {
        case 0..<5:
            return await client.perform(MovePoints(node: node, contour: contour.id, point: point.id, to: Point(x: x, y: y)))
        case 5..<7:
            return await client.perform(InsertPoints(node: node, contour: contour.id, at: .after(point.id),
                                                     points: [VectorPoint(anchor: Point(x: x, y: y))]))
        case 7 where contour.points.count > 3:
            return await client.perform(DeletePoints(node: node, points: [(contour.id, point.id)]))
        default:
            return await client.perform(SetHandles(node: node, contour: contour.id, point: point.id,
                                                   in: Vector(dx: -Double(random.within(1...20)), dy: 0),
                                                   out: Vector(dx: Double(random.within(1...20)), dy: 0)))
        }
    }

    /// Moves each of `nodes` to a position drawn from `random`, in one change of as many ops.
    @discardableResult
    public static func move(_ client: SimClient, _ nodes: [OpID], _ random: inout SimRandom) async -> Wiretuner_Doc_V1_Change? {
        let live = nodes.filter { client.state.isLive($0) }
        guard !live.isEmpty else { return nil }
        var transforms: [(node: OpID, transform: WTGeometry.AffineTransform)] = []
        for node in live {
            transforms.append((node, WTGeometry.AffineTransform.translation(x: Double(random.within(0...1_000)), y: Double(random.within(0...1_000)))))
        }
        return await client.perform(SetTransforms(transforms))
    }

    /// Names each of `nodes` `name`.
    @discardableResult
    public static func rename(_ client: SimClient, _ nodes: [OpID], _ name: String) async -> Wiretuner_Doc_V1_Change? {
        await client.perform(SetNameOrNote(nodes, .name, name))
    }

    /// Deletes `nodes`.
    @discardableResult
    public static func delete(_ client: SimClient, _ nodes: [OpID]) async -> Wiretuner_Doc_V1_Change? {
        await client.perform(DeleteNodes(nodes))
    }

    /// Creates a text block holding `text` on `client` and returns it.
    public static func createText(_ client: SimClient, _ text: String) async throws -> OpID {
        try created(await client.perform(CreateTextBlock(.point(Point(x: 0, y: 0)), text: text)), by: client, "a text block")[0]
    }

    /// One edit of the text block `node`: type a word at a random place, delete a few characters,
    /// break or join a paragraph, or set a size over a range -- chosen by `random`.
    @discardableResult
    public static func editText(_ client: SimClient, _ node: OpID, _ random: inout SimRandom) async -> Wiretuner_Doc_V1_Change? {
        guard let text = client.state.textNode(node) else { return nil }
        let length = text.length
        let at = random.within(0...length)
        switch random.below(10) {
        case 0..<5:
            let word = "\(client.name.prefix(1))\(random.below(100)) "
            return await client.perform(InsertText(node: node, text: word, at: text.anchor(at: at), typing: true))
        case 5..<7 where length > 0:
            let start = min(at, length - 1)
            let end = min(length, start + random.within(1...4))
            return await client.perform(DeleteText(node: node, from: text.anchor(at: start), to: text.anchor(at: end)))
        case 7:
            return await client.perform(SplitParagraph(node: node, at: text.anchor(at: at)))
        default:
            guard length > 0 else { return nil }
            let start = min(at, length - 1)
            let end = min(length, start + random.within(1...8))
            var size = Wiretuner_Doc_V1_TextMarkValue()
            size.size = Double(random.within(8...36))
            return await client.perform(ApplyMark(node: node, from: text.anchor(at: start), to: text.anchor(at: end), value: size))
        }
    }

    /// A random edit of the objects `nodes`: mostly moves, some renames, the odd new shape; used
    /// by the randomized scenarios.
    @discardableResult
    public static func randomEdit(_ client: SimClient, _ nodes: [OpID], _ random: inout SimRandom) async -> Wiretuner_Doc_V1_Change? {
        guard !nodes.isEmpty else { return nil }
        switch random.below(10) {
        case 0..<6:
            let count = random.within(1...min(4, nodes.count))
            return await move(client, (0..<count).map { _ in random.pick(nodes) }, &random)
        case 6..<9:
            return await rename(client, [random.pick(nodes)], "\(client.name)-\(random.below(1_000))")
        default:
            return await client.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5),
                                                    transform: WTGeometry.AffineTransform.translation(x: Double(random.below(500)), y: 0)))
        }
    }
}
