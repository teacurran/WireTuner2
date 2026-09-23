import Testing
@testable import WTCRDT
import WTProto

@Suite struct OpIDTests {
    @Test func ordersByCounterThenReplicaUnsigned() {
        let huge = OpID(counter: 2, replica: UInt64.max - 15)
        let ids = [huge, OpID(counter: 2, replica: 2), OpID(counter: 1, replica: 9),
                   OpID(counter: .max, replica: 0), OpID(counter: 2, replica: 1)].sorted()
        #expect(ids == [OpID(counter: 1, replica: 9), OpID(counter: 2, replica: 1), OpID(counter: 2, replica: 2),
                        huge, OpID(counter: .max, replica: 0)])
    }

    @Test func convertsAndPrints() {
        let id = OpID(counter: .max, replica: 7)
        #expect(OpID(id.proto) == id)
        #expect(id.description == "18446744073709551615:7")
        #expect(OpID.wellKnown(4) == OpID(counter: 4, replica: 0))
        #expect(OpID.zero == .wellKnown(0))
    }
}

@Suite struct LamportClockTests {
    @Test func nextIsOneMoreThanTheLargestCreatedOrSeen() {
        var clock = LamportClock()
        #expect(clock.peek == 1)
        #expect(clock.allocate(3) == 1)
        #expect(clock.max == 3)
        clock.observe(10)
        clock.observe(4)
        #expect(clock.peek == 11)
        #expect(clock.allocate(1) == 11)
    }

    @Test func resumesAndComparesUnsigned() {
        var clock = LamportClock(max: 5)
        clock.observe(.max - 1)
        #expect(clock.max == UInt64.max - 1)
        clock.observe(7)
        #expect(clock.max == UInt64.max - 1)
    }
}

@Suite struct RegisterPathTests {
    @Test func encodesCanonicallyAndOrdersSegmentWise() {
        let name = RegisterPath([150, 1, 1])
        #expect(name.canonical == [1, 0, 0, 0, 150, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1])
        #expect(RegisterPath([150, 1]) < name)
        #expect(RegisterPath([150, 1, 2]) < RegisterPath([150, 1, 13, 2]))
        #expect(RegisterPath([150, 1, 255]) < RegisterPath([150, 1, 256]))
        #expect(RegisterPath([150, 1]).child(1) == name)
        #expect(name.description == "150.1.1")
        #expect(name.fields == [150, 1, 1])
    }

    @Test func convertsFieldPaths() {
        let path = RegisterPath([150, 1, 6])
        #expect(RegisterPath(path.proto) == path)
        #expect(RegisterPath(Wiretuner_Doc_V1_FieldPath()) == nil)
        var withElement = path.proto
        var segment = Wiretuner_Doc_V1_PathSegment()
        segment.element = Wiretuner_Doc_V1_ElementId()
        withElement.segments.append(segment)
        #expect(RegisterPath(withElement) == nil)
    }

    @Test func readsTheValueAPathAddressesInAMessage() {
        let props = Changes.bytes(Changes.layer { $0.name = "A"; $0.locked = true })
        #expect(RegisterPath([150, 1, 1]).value(in: props) == Wire().string(1, "A").bytes)
        #expect(RegisterPath([150, 1, 2]).value(in: props) == nil)
        #expect(RegisterPath([3, 1, 1]).value(in: props) == nil)
        #expect(RegisterPath([150]).value(in: props) != nil)
        #expect(RegisterPath([1]).value(in: [0x0F]) == nil)
    }
}

@Suite struct RegisterTests {
    @Test func registersAndWritesPrint() {
        let set = Register(value: [8, 1], op: OpID(counter: 2, replica: 1))
        let unset = Register(value: nil, op: OpID(counter: 2, replica: 1))
        #expect(set.isSet && !unset.isSet)
        #expect(set.description == "0801@2:1")
        #expect(unset.description == "unset@2:1")
        let path = RegisterPath([150, 1, 1])
        let write = Write(node: OpID(counter: 1, replica: 7), path: path, value: [1], op: OpID(counter: 3, replica: 2))
        #expect(write.description == "1:7/150.1.1=01@3:2")
        #expect(Write(node: write.node, path: path, value: nil, op: write.op).description == "1:7/150.1.1=unset@3:2")
    }
}

@Suite struct WireMessageTests {
    @Test func readsEveryWireType() throws {
        let bytes = Wire().varint(1, 150).fixed64(2, 7).string(3, "hi").fixed32(4, 9).varint(1, .max).bytes
        let message = try #require(WireMessage.parse(bytes))
        #expect(message.has(3))
        #expect(!message.has(5))
        #expect(message.records(1) == Wire().varint(1, 150).varint(1, .max).bytes)
        #expect(message.records(4) == Wire().fixed32(4, 9).bytes)
        #expect(message.records(5) == nil)
        #expect(message.lastMessage(of: [1, 2, 3, 4]) == 3)
        #expect(message.lastMessage(of: [9]) == 0)
    }

    @Test func embeddedMessagesMergeAcrossOccurrencesAndIgnoreOtherWireTypes() throws {
        let bytes = Wire().message(1, Wire().varint(1, 1)).varint(1, 5).message(1, Wire().varint(2, 2)).bytes
        let inner = try #require(WireMessage.parse(bytes)?.message(1))
        #expect(inner.records(1) == Wire().varint(1, 1).bytes)
        #expect(inner.records(2) == Wire().varint(2, 2).bytes)
        #expect(WireMessage.parse(bytes)?.message(2) == nil)
        #expect(WireMessage.parse(Wire().bytes(1, [0x07]).bytes)?.message(1) == nil)
        #expect(WireMessage.parse([])?.has(1) == false)
    }

    @Test func rejectsMalformedBytes() {
        #expect(WireMessage.parse(Wire().rawBytes(0x08, 0x80).bytes) == nil)
        #expect(WireMessage.parse([0x80]) == nil)
        #expect(WireMessage.parse([0x08] + [UInt8](repeating: 0xFF, count: 10) + [0x01]) == nil)
        #expect(WireMessage.parse(Wire().tag(0, 0).raw(1).bytes) == nil)
        #expect(WireMessage.parse(Wire().tag(1 << 29, 0).raw(1).bytes) == nil)
        #expect(WireMessage.parse(Wire().tag(1, 3).bytes) == nil)
        #expect(WireMessage.parse(Wire().tag(1, 6).bytes) == nil)
        #expect(WireMessage.parse(Wire().tag(1, 2).raw(5).rawBytes(1).bytes) == nil)
        #expect(WireMessage.parse(Wire().tag(1, 2).rawBytes(0x80).bytes) == nil)
        #expect(WireMessage.parse(Wire().tag(1, 2).raw(.max).bytes) == nil)
        #expect(WireMessage.parse(Wire().tag(1, 1).rawBytes(1, 2).bytes) == nil)
        #expect(WireMessage.parse(Wire().tag(1, 5).rawBytes(1).bytes) == nil)
    }

    @Test func acceptsTheLargestFieldNumberAndTenByteVarints() {
        let bytes = Wire().varint((1 << 29) - 1, 1 << 63).bytes
        #expect(WireMessage.parse(bytes)?.has((1 << 29) - 1) == true)
    }
}

@Suite struct NodeStoreTests {
    @Test func wellKnownNodesExistWithoutBeingCreated() {
        var store = NodeStore()
        #expect(store.exists(.wellKnown(15)))
        #expect(!store.exists(.wellKnown(16)))
        #expect(!store.exists(OpID(counter: 3, replica: 1)))
        #expect(store.kind(.zero) == 1)
        #expect(store.kind(.wellKnown(1)) == 2)
        #expect(store.kind(.wellKnown(4)) == 0)
        let wellKnown = store.create(.wellKnown(2), kind: 3)
        let fresh = store.create(OpID(counter: 3, replica: 1), kind: 150)
        let again = store.create(OpID(counter: 3, replica: 1), kind: 50)
        #expect(!wellKnown && fresh && !again)
        #expect(store.kind(OpID(counter: 3, replica: 1)) == 150)
    }

    @Test func readsOfUnwrittenRegistersAreEmpty() {
        var store = NodeStore()
        let path = RegisterPath([1, 1, 1])
        #expect(store.register(.zero, path) == nil)
        #expect(store.registers(.zero).isEmpty)
        #expect(store.writes(.zero, path).isEmpty)
        #expect(store.losingWrites(.zero, path).isEmpty)
        let wins = store.write(.zero, path, nil, OpID(counter: 2, replica: 1))
        let loses = store.write(.zero, path, [1], OpID(counter: 1, replica: 1))
        let replayed = store.write(.zero, path, [1], OpID(counter: 1, replica: 1))
        #expect(wins && !loses && !replayed)
        #expect(store.writes(.zero, path).count == 2)
        #expect(store.nodes == [.zero])
    }
}

/// The canonical encoding, pinned byte for byte: wt-crdt's StateHashTest pins the same bytes and
/// hashes in Java.
@Suite struct StateHashTests {
    static func sample() -> NodeStore {
        var store = NodeStore()
        _ = store.create(OpID(counter: 1, replica: 7), kind: 150)
        store.write(OpID(counter: 1, replica: 7), RegisterPath([150, 1, 1]), [0x0A, 0x01, 0x41], OpID(counter: 2, replica: 1))
        store.write(OpID(counter: 1, replica: 7), RegisterPath([150, 1, 3]), nil, OpID(counter: 3, replica: 2))
        return store
    }

    @Test func emptyStateHashesFourZeroBytes() {
        #expect(StateHash.hex(StateHash.of(NodeStore())) == "df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119")
    }

    @Test func encodesNodesAsSpecified() {
        let expected = "0000000000000001" + "0000000000000007" + "00000096" + "00000002"
            + "0000000f" + "0100000096" + "0100000001" + "0100000001"
            + "0000000000000002" + "0000000000000001" + "01" + "00000003" + "0a0141"
            + "0000000f" + "0100000096" + "0100000001" + "0100000003"
            + "0000000000000003" + "0000000000000002" + "00"
        #expect(StateHash.hex(StateHash.encode(Self.sample(), OpID(counter: 1, replica: 7))) == expected)
    }

    @Test func pinnedHashesMatchTheJavaEngine() {
        #expect(StateHash.hex(StateHash.of(Self.sample())) == "0ef585c6ddbe9bc2235886fcf76521e4eac3699731d6b334e075dd1cf7811544")
        #expect(StateHash.hex(StateHash.of(Self.sample(), node: OpID(counter: 1, replica: 7)))
            == "c724b8cc2df751dd6d8ace2ac01c75e059202821ee67a943ebe85c5c711abc8a")
    }
}
