import Foundation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// One in-process replica for merge tests: a `DocumentCore` that performs commands locally and
/// receives the other replicas' changes as the server would relay them.
struct Replica {
    var core: DocumentCore
    private(set) var sent: [Wiretuner_Doc_V1_Change] = []
    static let now = Date(timeIntervalSince1970: 1_000_000)

    init(_ replica: UInt64) {
        core = DocumentCore(state: EngineState(), replica: replica)
    }

    var state: EngineState { core.state }

    /// Performs `command`; returns its change (nil when it appended nothing).  What it sends is
    /// the change as it enters the outbox (without local-only writes).
    @discardableResult
    mutating func perform(_ command: any Command) throws -> Wiretuner_Doc_V1_Change? {
        let outcome = try core.perform(command, recording: DocumentCore.Recording(limit: 100, now: Self.now))
        if let change = outcome?.outbox { sent.append(change) }
        return outcome?.change
    }

    @discardableResult
    mutating func undo() -> Wiretuner_Doc_V1_Change? {
        let outcome = core.undo(recording: DocumentCore.Recording(limit: 100, now: Self.now))
        if let change = outcome?.outbox { sent.append(change) }
        return outcome?.change
    }

    /// Applies `changes` from another replica.
    mutating func receive(_ changes: [Wiretuner_Doc_V1_Change]) {
        for change in changes {
            core.receive(change, serverSeq: 0)
        }
    }

    /// The path `node` holds as merged.
    func path(_ node: OpID) -> VectorPath {
        VectorPath(state.props(node).path, node: node, state: state)
    }
}

/// Two replicas that exchange everything they sent since the last sync.
struct Pair {
    var a = Replica(0xA)
    var b = Replica(0xB)
    private var syncedA = 0
    private var syncedB = 0

    mutating func sync() {
        let fromA = Array(a.sent[syncedA...])
        let fromB = Array(b.sent[syncedB...])
        a.receive(fromB)
        b.receive(fromA)
        syncedA = a.sent.count
        syncedB = b.sent.count
    }
}

enum PathFixture {
    static func points(_ coordinates: [(Double, Double)]) -> [VectorPoint] {
        coordinates.map { VectorPoint(anchor: Point(x: $0.0, y: $0.1)) }
    }

    static func open(_ coordinates: [(Double, Double)]) -> CreatePath {
        CreatePath(contours: [NewContour(points: points(coordinates))])
    }

    static func closed(_ coordinates: [(Double, Double)]) -> CreatePath {
        CreatePath(contours: [NewContour(closed: true, points: points(coordinates))])
    }

    /// The created object's id and its only contour.
    static func ids(_ change: Wiretuner_Doc_V1_Change?, in state: EngineState) -> (node: OpID, contour: OpID) {
        let node = change!.createdObjects[0]
        let contour = state.liveElements(node, PathFields.contours)[0]
        return (node, contour)
    }

    static func anchors(_ contour: VectorContour) -> [Point] {
        contour.drawn.map(\.anchor)
    }
}
