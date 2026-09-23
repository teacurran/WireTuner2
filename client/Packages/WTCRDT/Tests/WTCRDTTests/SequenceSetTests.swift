import Foundation
import Testing
@testable import WTCRDT
import WTProto

/// Ops on the conformance test kind (`TestProps`, NodeProps field 1000; crdt-conformance/schema),
/// built with the vector types and handed to the engine as doc.v1 messages.
enum TestKind {
    typealias Props = Wiretuner_Conformance_V1_TestProps
    static let node = OpID(counter: 1, replica: 7)
    static let schema: Schema = {
        var failures: [String] = []
        return ConformanceRunner.schema(Wiretuner_Conformance_V1_Vector(), &failures)
    }()
    static let tags = RegisterPath([1000, 3])
    static let codes = RegisterPath([1000, 4])
    static let points = RegisterPath([1000, 5])
    static let contours = RegisterPath([1000, 7])
    static let stops = RegisterPath([1000, 8])

    static func props(_ edit: (inout Props) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var test = Props()
        edit(&test)
        var props = Wiretuner_Conformance_V1_NodeProps()
        props.test = test
        return try! Wiretuner_Doc_V1_NodeProps(serializedBytes: try props.serializedBytes() as [UInt8])
    }

    static func engine() -> EngineState {
        var engine = EngineState(schema: schema)
        engine.apply(Changes.change(7, 1, Changes.create(props { $0.label = "T" })))
        return engine
    }

    static func setAdd(_ path: RegisterPath, _ values: Wiretuner_Doc_V1_NodeProps, remove: Bool = false) -> Wiretuner_Doc_V1_Op {
        var op = Wiretuner_Doc_V1_Op()
        if remove {
            var set = Wiretuner_Doc_V1_SetRemove()
            set.node = node.proto
            set.set = path.proto
            set.values = values
            op.setRemove = set
        } else {
            var set = Wiretuner_Doc_V1_SetAdd()
            set.node = node.proto
            set.set = path.proto
            set.values = values
            op.setAdd = set
        }
        return op
    }

    static func insert(_ path: RegisterPath, _ positions: [[UInt8]], _ values: Wiretuner_Doc_V1_NodeProps = .init()) -> Wiretuner_Doc_V1_Op {
        var insert = Wiretuner_Doc_V1_ElementInsert()
        insert.node = node.proto
        insert.sequence = path.proto
        insert.positions = positions.map { Data($0) }
        insert.values = values
        var op = Wiretuner_Doc_V1_Op()
        op.elementInsert = insert
        return op
    }

    static func move(_ element: RegisterPath, _ position: [UInt8]) -> Wiretuner_Doc_V1_Op {
        var move = Wiretuner_Doc_V1_ElementMove()
        move.node = node.proto
        move.element = element.proto
        move.position = Data(position)
        var op = Wiretuner_Doc_V1_Op()
        op.elementMove = move
        return op
    }

    static func delete(_ elements: [RegisterPath], _ deleted: Bool) -> Wiretuner_Doc_V1_Op {
        var delete = Wiretuner_Doc_V1_ElementDelete()
        delete.node = node.proto
        delete.elements = elements.map(\.proto)
        delete.deleted = deleted
        var op = Wiretuner_Doc_V1_Op()
        op.elementDelete = delete
        return op
    }

    static func change(_ replica: UInt64, _ seq: UInt64, _ start: UInt64, base: UInt64 = 0,
                       _ ops: Wiretuner_Doc_V1_Op...) -> Wiretuner_Doc_V1_Change {
        var change = Changes.change(replica, start, ops)
        change.seq = seq
        change.baseServerSeq = base
        return change
    }

    static func id(_ counter: UInt64, _ replica: UInt64) -> OpID { OpID(counter: counter, replica: replica) }
    static func text(_ value: String) -> [UInt8] { Array(value.utf8) }
}

@Suite struct SetTests {
    typealias T = TestKind

    @Test func aConcurrentAddSurvivesARemoveThatDidNotObserveIt() {
        var engine = T.engine()
        engine.apply(T.change(7, 2, 2, T.setAdd(T.tags, T.props { $0.tags = ["red", "blue"] })), serverSeq: 2)
        engine.apply(T.change(2, 1, 3, base: 2, T.setAdd(T.tags, T.props { $0.tags = ["red", "blue"] }, remove: true)), serverSeq: 3)
        #expect(engine.store.members(T.node, T.tags).isEmpty)
        #expect(engine.store.setPaths(T.node).isEmpty)
        engine.apply(T.change(1, 1, 3, base: 2, T.setAdd(T.tags, T.props { $0.tags = ["red"] })))
        #expect(engine.store.members(T.node, T.tags) == [T.text("red")])
        #expect(engine.store.liveTags(T.node, T.tags, T.text("red")) == [T.id(3, 1)])
        #expect(engine.store.setPaths(T.node) == [T.tags])
        // A remove that has seen the add (base_server_seq past its server_seq) removes it.
        engine.acknowledge(replica: 1, seq: 1, serverSeq: 4)
        engine.apply(T.change(3, 1, 4, base: 4, T.setAdd(T.tags, T.props { $0.tags = ["red"] }, remove: true)))
        #expect(engine.store.members(T.node, T.tags).isEmpty)
    }

    @Test func aReplicasOwnEarlierAddsAreObservedAndLaterOnesAreNot() {
        var engine = T.engine()
        engine.apply(T.change(1, 1, 2, T.setAdd(T.tags, T.props { $0.tags = ["a"] }),
                              T.setAdd(T.tags, T.props { $0.tags = ["a"] }, remove: true),
                              T.setAdd(T.tags, T.props { $0.tags = ["b"] }, remove: true),
                              T.setAdd(T.tags, T.props { $0.tags = ["b"] })))
        #expect(engine.store.members(T.node, T.tags) == [T.text("b")])
        // Without server sequence numbers another replica's remove observes nothing.
        engine.apply(T.change(2, 1, 9, base: 5, T.setAdd(T.tags, T.props { $0.tags = ["b"] }, remove: true)))
        #expect(engine.store.members(T.node, T.tags) == [T.text("b")])
        // Replays of an add or remove are ignored.
        engine.apply(T.change(1, 1, 2, T.setAdd(T.tags, T.props { $0.tags = ["a"] }),
                              T.setAdd(T.tags, T.props { $0.tags = ["a"] }, remove: true)))
        #expect(engine.store.liveTags(T.node, T.tags, T.text("a")).isEmpty)
        #expect(engine.store.liveTags(T.node, T.codes, [1]).isEmpty)
    }

    @Test func idAndPackedMembersCompareByValue() {
        var engine = T.engine()
        var point = Wiretuner_Doc_V1_ElementId()
        point.counter = 7
        point.replica = 1
        engine.apply(Changes.change(7, 2,
            T.setAdd(T.points, T.props { $0.points = [point] }),
            T.setAdd(T.codes, T.props { $0.codes = [3, 1, 3] }),
            T.setAdd(T.points, Changes.raw(Wire().message(1000, Wire().message(5, Wire().fixed64(2, 1).varint(1, 7))))),
            T.setAdd(T.codes, Changes.raw(Wire().message(1000, Wire().varint(4, 2))))))
        #expect(engine.store.members(T.node, T.points) == [[0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 1]])
        #expect(engine.store.liveTags(T.node, T.points, engine.store.members(T.node, T.points)[0]) == [T.id(2, 7), T.id(4, 7)])
        #expect(engine.store.members(T.node, T.codes).map { $0.last! } == [1, 2, 3])
        #expect(engine.members(in: T.props { $0.codes = [5] }, kind: 1000, path: T.codes.proto) == [[0, 0, 0, 0, 0, 0, 0, 5]])
        #expect(engine.members(in: T.props { $0.label = "x" }, kind: 1000, path: RegisterPath([1000, 2]).proto) == nil)
    }

    @Test func setOpsThatNameNoSetAreNoOps() {
        var engine = T.engine()
        let before = engine.stateHash
        engine.apply(Changes.change(7, 2,
            T.setAdd(RegisterPath([1000, 2]), T.props { $0.label = "x" }),
            T.setAdd(RegisterPath([1000, 1]), T.props { $0.label = "x" }),
            T.setAdd(T.tags, Changes.raw(Wire().tag(9, 3).tag(9, 4)))))
        var unknown = T.setAdd(T.tags, T.props { $0.tags = ["a"] })
        unknown.setAdd.node = T.id(9, 9).proto
        engine.apply(Changes.change(7, 5, unknown))
        #expect(engine.stateHash == before)
        let unsupported = try! T.schema.with("wiretuner.conformance.v1.TestProps", field: 1, policy: .set)
        var odd = EngineState(schema: unsupported)
        odd.apply(Changes.change(7, 1, Changes.create(T.props { $0.label = "T" }),
                                 T.setAdd(RegisterPath([1000, 1]), T.props { $0.common.name = "x" })))
        #expect(odd.store.setPaths(T.node).isEmpty)
    }
}

@Suite struct SetMemberTests {
    static func members(_ wire: Wire, _ type: String, _ typeName: String? = nil) -> [[UInt8]]? {
        WireMessage.parse(wire.bytes)?.members(1, type: type, typeName: typeName)
    }

    @Test func readsEveryScalarShapeAndSkipsWrongWireTypes() {
        #expect(Self.members(Wire().string(1, "a").varint(1, 5).bytes(1, [0xFF]), "string") == [[0x61], [0xFF]])
        #expect(Self.members(Wire().varint(1, 300).bytes(1, [0x01, 0xAC, 0x02]).fixed32(1, 1), "int64")
            == [[0, 0, 0, 0, 0, 0, 1, 0x2C], [0, 0, 0, 0, 0, 0, 0, 1], [0, 0, 0, 0, 0, 0, 1, 0x2C]])
        #expect(Self.members(Wire().bytes(1, [0x80]).varint(1, 1), "bool") == [[0, 0, 0, 0, 0, 0, 0, 1]])
        #expect(Self.members(Wire().fixed64(1, 1).bytes(1, [UInt8](repeating: 2, count: 16)).bytes(1, [1, 2, 3]), "double")
            == [[1, 0, 0, 0, 0, 0, 0, 0], [UInt8](repeating: 2, count: 8), [UInt8](repeating: 2, count: 8)])
        #expect(Self.members(Wire().fixed32(1, 9).bytes(1, [1, 2, 3, 4]).varint(1, 1), "float") == [[9, 0, 0, 0], [1, 2, 3, 4]])
        #expect(Self.members(Wire().string(1, "x"), "group") == nil)
        #expect(Self.members(Wire().string(1, "x"), "message", "t.Other") == nil)
        #expect(Self.members(Wire().string(1, "x"), "message") == nil)
    }

    @Test func readsIDsByValue() {
        let id = Wire().varint(1, 1).varint(1, 2).fixed64(2, 3).fixed32(2, 9)
        #expect(Self.members(Wire().message(1, id).bytes(1, [0x07]).varint(1, 1), "message", "wiretuner.doc.v1.OpId")
            == [[0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3]])
        #expect(Self.members(Wire().message(1, Wire()), "message", "wiretuner.doc.v1.ElementId") == [[UInt8](repeating: 0, count: 16)])
    }
}

@Suite struct SequenceTests {
    typealias T = TestKind
    static let color = RegisterPath([1000, 8]).child(3)

    static func stop(_ counter: UInt64, _ replica: UInt64 = 7) -> RegisterPath {
        T.stops.element(T.id(counter, replica))
    }

    @Test func anInsertTakesOneCounterPerElementAndWritesTheirValues() {
        var engine = T.engine()
        var stops = [Wiretuner_Conformance_V1_TestStop(), Wiretuner_Conformance_V1_TestStop()]
        stops[0].color = "red"
        stops[0].id.counter = 99
        stops[1].offset = 0.5
        engine.apply(Changes.change(7, 2, T.insert(T.stops, [[0x80], [0x81], [0x82]], T.props { $0.stops = stops }),
                                    Changes.set(T.node, T.props { $0.stops = [stops[0]] }, Self.stop(4).child(3))))
        #expect(engine.clock.max == 5)
        #expect(engine.store.elementOrder(T.node, T.stops) == [T.id(2, 7), T.id(3, 7), T.id(4, 7)])
        #expect(engine.store.registers(T.node).map(\.path) == [
            RegisterPath([1000, 2]), Self.stop(2).child(3), Self.stop(3).child(2), Self.stop(4).child(3)])
        #expect(engine.register(T.node, Self.stop(4).child(3))?.op == T.id(5, 7))
        #expect(engine.store.element(T.node, Self.stop(3))?.position.current == Stamped([0x81], T.id(3, 7)))
        #expect(EngineState.counters(T.insert(T.stops, [])) == 1)
        var text = Wiretuner_Doc_V1_Op()
        text.textInsert.chars = "a\u{1F600}b"
        #expect(EngineState.counters(text) == 3)
        text.textInsert.chars = ""
        #expect(EngineState.counters(text) == 1)
    }

    @Test func elementsMoveDeleteAndRestoreByRegister() {
        var engine = T.engine()
        engine.apply(Changes.change(7, 2, T.insert(T.stops, [[0x80], [0x81]])))
        engine.apply(Changes.change(1, 4, T.move(Self.stop(2), [0x90]), T.delete([Self.stop(3)], true)))
        engine.apply(Changes.change(2, 4, T.move(Self.stop(2), [0x70])))
        #expect(engine.store.elementOrder(T.node, T.stops) == [T.id(2, 7), T.id(3, 7)])
        #expect(engine.store.element(T.node, Self.stop(2))?.position.losing.map(\.op) == [T.id(2, 7), T.id(4, 1)])
        #expect(engine.store.element(T.node, Self.stop(3))?.isDeleted == true)
        engine.apply(Changes.change(2, 6, T.delete([Self.stop(3)], false)))
        engine.apply(Changes.change(1, 5, T.delete([Self.stop(3)], true)))
        #expect(engine.store.element(T.node, Self.stop(3))?.isDeleted == false)
        #expect(engine.store.element(T.node, Self.stop(2))?.isDeleted == false)
        #expect(engine.store.elements(T.node).map(\.path) == [Self.stop(2), Self.stop(3)])
    }

    @Test func aWholeElementPathWritesItsFieldsButNotItsID() {
        var engine = T.engine()
        engine.apply(Changes.change(7, 2, T.insert(T.stops, [[0x80]])))
        var stop = Wiretuner_Conformance_V1_TestStop()
        stop.color = "c"
        engine.apply(Changes.change(7, 3, Changes.set(T.node, T.props { $0.stops = [stop] }, Self.stop(2))))
        #expect(engine.store.registers(T.node).map(\.path).filter { $0.segments.count > 2 } == [Self.stop(2).child(2), Self.stop(2).child(3)])
        #expect(engine.register(T.node, Self.stop(2).child(2)) == Register(value: nil, op: T.id(3, 7)))
    }

    @Test func pathsThatDoNotReachAnExistingElementAreNoOps() {
        var engine = T.engine()
        engine.apply(Changes.change(7, 2, T.insert(T.contours, [[0x80]])))
        let contour = T.contours.element(T.id(2, 7))
        let before = engine.stateHash
        engine.apply(Changes.change(7, 3,
            T.insert(T.stops.element(T.id(2, 7)), [[0x80]]),                // element of the wrong sequence
            T.insert(T.contours.element(T.id(9, 9)).child(3), [[0x80]]),    // unknown contour
            T.insert(RegisterPath([1000, 2]), [[0x80]]),                     // not a SEQUENCE
            T.insert(T.stops, [[0x80]], Changes.raw(Wire().tag(9, 3).tag(9, 4))),
            T.move(T.stops, [0x80]),
            T.move(contour.child(3), [0x80]),
            T.delete([Self.stop(9), T.contours], true),
            Changes.set(T.node, T.props { $0.label = "x" }, contour.child(1)),       // an element's id
            Changes.set(T.node, T.props { $0.label = "x" }, RegisterPath(segments: [.field(1000), .element(T.id(2, 7))])),
            Changes.set(T.node, T.props { $0.label = "x" }, T.contours.child(2)),     // field after a SEQUENCE
            Changes.set(T.node, T.props { $0.label = "x" }, T.tags.child(1)),         // past a SET
            Changes.set(T.node, T.props { $0.label = "x" }, T.contours)))             // a whole SEQUENCE
        #expect(engine.stateHash == before)
        engine.apply(Changes.change(7, 20, T.insert(contour.child(3), [[0x80], [0x81]])))
        #expect(engine.store.elementOrder(T.node, contour.child(3)) == [T.id(20, 7), T.id(21, 7)])
        #expect(engine.store.elementOrder(T.node, T.stops).isEmpty)
        var text = try! T.schema.with("wiretuner.conformance.v1.TestProps", field: 1, policy: .text)
        text = text.with("t.Unknown", row: Tables.row(1, .atomic, "string", false, nil))
        var odd = EngineState(schema: text)
        odd.apply(Changes.change(7, 1, Changes.create(T.props { $0.label = "T" })))
        let oddBefore = odd.stateHash
        odd.apply(Changes.change(7, 2, Changes.set(T.node, T.props { $0.common.name = "x" }, RegisterPath([1000, 1, 1]))))
        #expect(odd.stateHash == oddBefore)
    }

    @Test func aMalformedElementValueInsertsTheElementWithoutFields() {
        var engine = T.engine()
        engine.apply(Changes.change(7, 2, T.insert(T.stops, [[0x80], [0x81]],
                                                   Changes.raw(Wire().message(1000, Wire().bytes(8, [0x07]).message(8, Wire().string(3, "b")))))))
        #expect(engine.store.elementOrder(T.node, T.stops) == [T.id(2, 7), T.id(3, 7)])
        #expect(engine.register(T.node, Self.stop(3).child(3))?.value == Wire().string(3, "b").bytes)
        #expect(engine.register(T.node, Self.stop(2).child(3)) == nil)
    }

    @Test func storeElementWritesIgnoreUnknownElementsAndReplays() {
        var store = NodeStore()
        let path = Self.stop(2)
        store.moveElement(T.node, path, position: [1], op: T.id(3, 1))
        store.deleteElement(T.node, path, deleted: true, op: T.id(3, 1))
        #expect(store.element(T.node, path) == nil)
        let inserted = store.insertElement(T.node, path, position: [0x80], op: T.id(2, 7))
        let replayed = store.insertElement(T.node, path, position: [0x90], op: T.id(2, 7))
        #expect(inserted && !replayed)
        store.moveElement(T.node, path, position: [0x70], op: T.id(2, 7))
        #expect(store.element(T.node, path)?.position.current.value == [0x80])
        #expect(store.nodes == [T.node])
    }
}
