import Testing
@testable import WTCRDT
import WTProto

@Suite struct SchemaTests {
    @Test func generatedTableKnowsTheKindsAndMakesReferencesAtomic() {
        let schema = Schema.generated
        #expect(schema.kinds.isSuperset(of: [1, 2, 3, 4, 50, 150]))
        #expect(schema.field("wiretuner.doc.v1.CommonProps", 1)?.policy == .atomic)
        #expect(schema.field("wiretuner.doc.v1.CommonProps", 8)?.policy == .structure)
        #expect(schema.field("wiretuner.doc.v1.CommonProps", 5)?.policy == .atomic)   // NodeRef canvas
        #expect(schema.field("wiretuner.doc.v1.CommonProps", 7)?.policy == .atomic)   // NodeRef style
        #expect(schema.field("wiretuner.doc.v1.CommonProps", 999) == nil)
        #expect(schema.field("no.Such", 1) == nil)
        #expect(schema.fields("no.Such").isEmpty)
        #expect(schema.variant("wiretuner.doc.v1.NavigationProps") == nil)
    }

    @Test func tablesAreUsedAsGiven() {
        let schema = Tables.shapes
        #expect(schema.field("t.K", 8)?.policy == .structure)
        #expect(schema.fields("t.K").map(\.fieldNumber) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(Schema(messages: [:], variants: [:]).kinds.isEmpty)
    }

    @Test func rowsCanBeAddedToNewAndExistingMessages() {
        let schema = Schema(messages: [:], variants: [:])
            .with(Schema.root, row: Tables.row(1000, .structure, "message", false, "t.K", "kind"))
            .with("t.K", row: Tables.row(1, .atomic, "string", false, nil))
            .with("t.K", row: Tables.row(1, .set, "string", true, nil))
        #expect(schema.kinds == [1000])
        #expect(schema.field("t.K", 1)?.policy == .set)
    }

    @Test func overridesReplaceAPolicyOrDeclareAVariant() throws {
        let schema = try Schema.generated
            .with("wiretuner.doc.v1.CommonProps", field: 8, policy: .variant)
            .withVariant("wiretuner.doc.v1.NavigationProps", kindField: 2, caseFields: [3])
        #expect(schema.field("wiretuner.doc.v1.CommonProps", 8)?.policy == .variant)
        #expect(schema.variant("wiretuner.doc.v1.NavigationProps")?.caseFields == [3])
        #expect(schema.kinds == Schema.generated.kinds)
        #expect(Schema.generated.field("wiretuner.doc.v1.CommonProps", 8)?.policy == .structure)
        #expect(throws: Schema.OverrideError(description: "no field wiretuner.doc.v1.CommonProps.999 in the merge table")) {
            try schema.with("wiretuner.doc.v1.CommonProps", field: 999, policy: .atomic)
        }
    }
}

@Suite struct EngineStateTests {
    static let layerID = OpID(counter: 1, replica: 7)

    static func withLayer() -> EngineState {
        var engine = EngineState()
        engine.apply(Changes.change(7, 1, Changes.create(Changes.layer { $0.name = "Layer 1" })))
        return engine
    }

    @Test func versionMatchesWtCrdt() {
        #expect(EngineState.version == "0.5.0")
        #expect(EngineState().schema.kinds == Schema.generated.kinds)
    }

    @Test func createNodeSetsItsKindAndThePresentLeavesOnly() {
        let props = Changes.layer { $0.name = "L"; $0.transform.a = 1 }
        var engine = EngineState()
        engine.apply(Changes.change(7, 1, Changes.create(props)))
        #expect(engine.store.kind(Self.layerID) == 150)
        #expect(engine.store.registers(Self.layerID).map(\.path) == [Changes.name, Changes.transform])
        #expect(engine.register(Self.layerID, Changes.name)
            == Register(value: Changes.name.value(in: Changes.bytes(props)), op: Self.layerID))
        #expect(engine.clock.max == 1)

        let before = engine.stateHash
        engine.apply(Changes.change(7, 1, Changes.create(Changes.layer { $0.name = "again" })))
        #expect(engine.stateHash == before)
    }

    @Test func createNodeWithoutAKnownKindCreatesNothing() {
        var engine = EngineState()
        engine.apply(Changes.change(1, 1,
            Changes.create(Wiretuner_Doc_V1_NodeProps()),
            Changes.create(Changes.raw(Wire().string(999, "x"))),
            Changes.create(Changes.raw(Wire().tag(5, 3).tag(5, 4))),
            Changes.create(Changes.raw(Wire().varint(150, 3)))))
        #expect(engine.store.nodes.isEmpty)
        #expect(engine.clock.max == 4)
    }

    @Test func greaterOpIDWinsAndLosersAreRetained() {
        var engine = Self.withLayer()
        let alice = Changes.set(Self.layerID, Changes.layer { $0.name = "Alice" }, Changes.name)
        let bob = Changes.set(Self.layerID, Changes.layer { $0.name = "Bob" }, Changes.name)
        engine.apply(Changes.change(2, 5, bob))
        engine.apply(Changes.change(1, 5, alice))
        engine.apply(Changes.change(2, 5, bob))
        #expect(engine.register(Self.layerID, Changes.name)?.op == OpID(counter: 5, replica: 2))
        #expect(engine.losingWrites(Self.layerID, Changes.name).map(\.op) == [Self.layerID, OpID(counter: 5, replica: 1)])
        #expect(engine.store.writes(Self.layerID, Changes.name).count == 3)
        #expect(engine.clock.peek == 6)
    }

    @Test func aPathWithoutAValueClears() {
        var engine = Self.withLayer()
        engine.apply(Changes.change(1, 2, Changes.clear(Self.layerID, Changes.name)))
        #expect(engine.register(Self.layerID, Changes.name) == Register(value: nil, op: OpID(counter: 2, replica: 1)))
        engine.apply(Changes.change(1, 3, Changes.set(Self.layerID, Changes.layer { $0.url = "u" }, Changes.url, Changes.locked)))
        #expect(engine.register(Self.layerID, Changes.locked)?.isSet == false)
        #expect(engine.register(Self.layerID, Changes.url)?.isSet == true)
    }

    @Test func aStructPathWritesEveryLeafBeneathIt() {
        var engine = Self.withLayer()
        engine.apply(Changes.change(1, 2, Changes.set(Self.layerID, Changes.layer { $0.textWrap.enabled = true }, Changes.wrap)))
        #expect(engine.register(Self.layerID, Changes.wrap.child(1))?.isSet == true)
        #expect(engine.register(Self.layerID, Changes.wrap.child(2)) == Register(value: nil, op: OpID(counter: 2, replica: 1)))

        engine.apply(Changes.change(1, 3, Changes.clear(Self.layerID, RegisterPath([150, 1]))))
        #expect(engine.store.registers(Self.layerID).allSatisfy { $0.register.op == OpID(counter: 3, replica: 1) })
        #expect(engine.register(Self.layerID, RegisterPath([150, 1, 5])) != nil)
    }

    @Test func opsNamingNothingUsableAreNoOps() {
        var engine = Self.withLayer()
        let before = engine.stateHash
        let name = Changes.layer { $0.name = "x" }
        var element = Wiretuner_Doc_V1_PathSegment()
        element.element = Wiretuner_Doc_V1_ElementId()
        var elementHead = Wiretuner_Doc_V1_FieldPath()
        elementHead.segments = [element]
        var elementLater = Changes.name.proto
        elementLater.segments[1] = element
        var noop = Wiretuner_Doc_V1_Op()
        noop.noop = Wiretuner_Doc_V1_Noop()
        var move = Wiretuner_Doc_V1_Op()
        move.move = Wiretuner_Doc_V1_MoveNode()
        engine.apply(Changes.change(1, 2,
            Changes.set(OpID(counter: 99, replica: 9), name, Changes.name),
            Changes.set(.wellKnown(4), name, Changes.name),
            Changes.set(Self.layerID, name, RegisterPath([3, 1, 1])),
            Changes.set(Self.layerID, name, Changes.name.child(1)),
            Changes.set(Self.layerID, name, RegisterPath([150, 1, 5, 1])),
            Changes.set(Self.layerID, name, RegisterPath([150, 1, 999])),
            Changes.set(Self.layerID, Changes.raw(Wire().tag(9, 3).tag(9, 4)), Changes.name),
            Changes.set(Self.layerID, Wiretuner_Doc_V1_NodeProps(), [Wiretuner_Doc_V1_FieldPath(), elementHead, elementLater]),
            noop, move, Wiretuner_Doc_V1_Op()))
        #expect(engine.stateHash == before)
        #expect(engine.clock.max == 12)
    }

    @Test func wellKnownDocumentAndSettingsTakeWrites() {
        var engine = EngineState()
        engine.apply(Changes.change(1, 1,
            Changes.set(.zero, Changes.raw(Wire().message(1, Wire().message(1, Wire().string(1, "Doc")))), RegisterPath([1, 1, 1])),
            Changes.set(.wellKnown(1), Changes.raw(Wire().message(2, Wire().message(1, Wire().varint(3, 1)))), RegisterPath([2, 1, 3]))))
        #expect(engine.store.nodes == [.zero, .wellKnown(1)])
        #expect(engine.register(.wellKnown(1), RegisterPath([2, 1, 3]))?.value == [0x18, 1])
    }

    @Test func variantsWriteOnlyThePresentCasesAndClearEveryCase() {
        var engine = EngineState(schema: Tables.shapes)
        let k = UInt64(Tables.k)
        engine.apply(Changes.change(1, 1, Changes.create(Changes.raw(Wire().message(k, Wire().string(1, "k"))))))
        let node = OpID(counter: 1, replica: 1)
        let v = RegisterPath([Tables.k, 6])
        engine.apply(Changes.change(1, 2, Changes.set(node, Changes.raw(Wire().message(k, Wire().message(6,
            Wire().varint(1, 1).message(2, Wire().fixed64(1, 5))))), v)))
        #expect(engine.store.registers(node).map(\.path) == [RegisterPath([Tables.k, 1]), v.child(1), v.child(2).child(1), v.child(4)])

        engine.apply(Changes.change(1, 3, Changes.clear(node, v)))
        #expect(engine.register(node, v.child(3).child(1)) == Register(value: nil, op: OpID(counter: 3, replica: 1)))
        #expect(engine.register(node, v.child(2).child(1))?.op == OpID(counter: 3, replica: 1))
    }

    @Test func recursiveAndNonRegisterFieldsAreSkippedOrRejected() {
        var engine = EngineState(schema: Tables.shapes)
        let k = UInt64(Tables.k)
        engine.apply(Changes.change(1, 1, Changes.create(Changes.raw(Wire().message(k,
            Wire().string(1, "k").message(2, Wire().string(1, "inner")))))))
        let node = OpID(counter: 1, replica: 1)
        #expect(engine.store.registers(node).map(\.path) == [RegisterPath([Tables.k, 1])])

        engine.apply(Changes.change(1, 2, Changes.set(node, Changes.raw(Wire().message(k, Wire().message(2,
            Wire().string(1, "deep")))), RegisterPath([Tables.k, 2, 1]))))
        #expect(engine.register(node, RegisterPath([Tables.k, 2, 1]))?.op == OpID(counter: 2, replica: 1))

        let before = engine.stateHash
        engine.apply(Changes.change(1, 3,
            Changes.clear(node, RegisterPath([Tables.k, 3])),
            Changes.clear(node, RegisterPath([Tables.k, 4, 1])),
            Changes.clear(node, RegisterPath([Tables.k, 5])),
            Changes.clear(node, RegisterPath([Tables.k, 8]))))
        #expect(engine.stateHash == before)

        engine.apply(Changes.change(1, 4, Changes.clear(node, RegisterPath([Tables.k]))))
        #expect(engine.store.registers(node).map(\.path) == [
            RegisterPath([Tables.k, 1]), RegisterPath([Tables.k, 2, 1]), RegisterPath([Tables.k, 6, 1]),
            RegisterPath([Tables.k, 6, 2, 1]), RegisterPath([Tables.k, 6, 3, 1]), RegisterPath([Tables.k, 6, 4]),
            RegisterPath([Tables.k, 7]),
        ])
        #expect(engine.register(node, RegisterPath([Tables.k, 2, 1]))?.op == OpID(counter: 2, replica: 1))
    }

    @Test func hashesAreOrderIndependent() {
        let a = Changes.set(Self.layerID, Changes.layer { $0.name = "A" }, Changes.name)
        let b = Changes.set(Self.layerID, Changes.layer { $0.locked = true }, Changes.locked)
        var one = Self.withLayer()
        one.apply(Changes.change(1, 2, a))
        one.apply(Changes.change(2, 2, b))
        var two = Self.withLayer()
        two.apply(Changes.change(2, 2, b))
        two.apply(Changes.change(1, 2, a))
        #expect(one.stateHash == two.stateHash)
    }
}

@Suite struct EngineActorTests {
    @Test func appliesChangesOnItsExecutor() async {
        let engine = Engine()
        let first = await engine.allocate(1)
        #expect(first == 1)
        await engine.apply(Changes.change(7, 2, Changes.create(Changes.layer { $0.name = "L" })))
        #expect(await engine.state.store.kind(OpID(counter: 2, replica: 7)) == 150)
        #expect(await engine.allocate(2) == 3)
        #expect(await engine.stateHash.count == 32)
    }
}
