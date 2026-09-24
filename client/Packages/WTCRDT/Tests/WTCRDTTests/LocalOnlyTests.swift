import Foundation
import Testing
@testable import WTCRDT
import WTCRDTSchema
import WTProto

/// Local-only fields (crdt-model.adoc, "Local-only fields"): a remote write to one is a no-op, a
/// local change writes it into the local registers that reads see and the hash, snapshots and
/// collection do not, and `LocalOnly.strip` takes it out of a change.  wt-crdt's LocalOnlyTest runs
/// the remote and strip cases; the `registers/local-only-*` vectors check both engines agree.
@Suite struct LocalOnlyTests {
    static let settings = OpID.wellKnown(1)
    static let magnification = RegisterPath([2, 40, 1])
    static let selected = RegisterPath([2, 61])
    static let outputArea = RegisterPath([2, 30])
    static let asset = OpID(counter: 1, replica: 7)
    static let bookmark = RegisterPath([5, 6])
    static let assetName = RegisterPath([5, 1, 1])

    static func path(_ fields: [UInt32], element: OpID? = nil, then rest: [UInt32] = []) -> String {
        var out = fields.map { "segments { field: \($0) }" }
        if let element {
            out.append("segments { element { counter: \(element.counter) replica: \(element.replica) } }")
        }
        out += rest.map { "segments { field: \($0) }" }
        return out.joined(separator: " ")
    }

    static let settingsNode = "node { counter: 1 }"

    /// Zoom 2.0 on the settings node: local-only.
    static func zoom(_ replica: UInt64, _ counter: UInt64, _ value: Double = 2) -> Wiretuner_Doc_V1_Change {
        Scenario.change(replica, 1, counter,
                        "set { \(settingsNode) paths { \(path([2, 40, 1])) } values { settings { view { magnification: \(value) } } } }")
    }

    static func engine() -> EngineState {
        EngineState(schema: Scenario.schema)
    }

    // MARK: The engines

    @Test func aRemoteWriteToALocalOnlyRegisterIsANoOp() {
        var engine = Self.engine()
        let before = engine.stateHash
        engine.apply(Self.zoom(2, 1), serverSeq: 1)
        #expect(engine.register(Self.settings, Self.magnification) == nil)
        #expect(engine.stateHash == before)
        #expect(engine.store.localRegisters(Self.settings).isEmpty)
    }

    @Test func aLocalChangeWritesTheLocalRegistersOnly() throws {
        var remote = Self.engine()
        remote.apply(Self.zoom(7, 1))
        var local = Self.engine()
        let inverse = local.applyLocal(Self.zoom(7, 1))
        let register = try #require(local.register(Self.settings, Self.magnification))
        #expect(register.op == OpID(counter: 1, replica: 7))
        #expect(register.value != nil)
        #expect(local.store.registers(Self.settings).isEmpty)
        #expect(local.store.localRegisters(Self.settings).map(\.path) == [Self.magnification])
        #expect(local.localOnlyWrites == [Write(node: Self.settings, path: Self.magnification, value: register.value, op: register.op)])
        #expect(local.store.localWrites == local.localOnlyWrites)
        #expect(local.stateHash == remote.stateHash)
        #expect(inverse.steps.count == 1)
        #expect(Snapshot.encode(local, serverSeq: 0) == Snapshot.encode(remote, serverSeq: 0))
        // Replayed (as a relaunch replays the stored change), the write changes nothing.
        local.apply(Self.zoom(7, 1))
        #expect(local.store.localRegisters(Self.settings).count == 1)
        // The next local change starts over.
        _ = local.applyLocal(Scenario.change(7, 2, 2, "noop { }"))
        #expect(local.localOnlyWrites.isEmpty)
    }

    @Test func localOnlyRegistersSurviveOnlyThroughRestore() throws {
        var local = Self.engine()
        _ = local.applyLocal(Self.zoom(7, 1))
        let kept = local.store.localWrites
        var decoded = try Snapshot.decode(Snapshot.encode(local, serverSeq: 0), schema: Scenario.schema)
        #expect(decoded.register(Self.settings, Self.magnification) == nil)
        decoded.restoreLocalOnly(kept)
        #expect(decoded.register(Self.settings, Self.magnification) == local.register(Self.settings, Self.magnification))
        // Restoring an older write does not replace a newer one; the same write again changes nothing.
        decoded.restoreLocalOnly([Write(node: Self.settings, path: Self.magnification, value: nil, op: OpID(counter: 0, replica: 7))])
        decoded.restoreLocalOnly(kept)
        #expect(decoded.register(Self.settings, Self.magnification)?.value != nil)
    }

    @Test func localWritesAreLastWriterWinsAndUndoable() throws {
        var engine = Self.engine()
        _ = engine.applyLocal(Self.zoom(7, 5, 3))
        _ = engine.applyLocal(Self.zoom(7, 2, 4))   // an older op loses
        #expect(engine.localOnlyWrites.isEmpty)
        let inverse = engine.applyLocal(Self.zoom(7, 6, 8))
        let value = engine.register(Self.settings, Self.magnification)?.value
        let undo = try #require(engine.undoChange(inverse, replica: 7, seq: 9, startCounter: engine.clock.peek))
        _ = engine.applyLocal(undo)
        #expect(engine.register(Self.settings, Self.magnification)?.value != value)
        #expect(engine.register(Self.settings, Self.magnification)?.op == OpID(counter: 7, replica: 7))
    }

    @Test func aMixedWriteSplitsAndAStructWriteKeepsTheLocalRegisters() {
        var engine = Self.engine()
        let mixed = Scenario.change(7, 1, 1, "set { \(Self.settingsNode) paths { \(Self.path([2, 40, 1])) } paths { \(Self.path([2, 7])) } "
            + "values { settings { view { magnification: 2 } } } }")
        _ = engine.applyLocal(mixed)
        #expect(engine.store.registers(Self.settings).map(\.path) == [RegisterPath([2, 7])])
        #expect(engine.store.localRegisters(Self.settings).count == 1)
        // A remote write of the whole settings message clears every shared register and leaves the view.
        engine.apply(Scenario.change(2, 1, 5, "set { \(Self.settingsNode) paths { \(Self.path([2])) } values { settings { } } }"))
        #expect(engine.register(Self.settings, Self.magnification)?.op == OpID(counter: 1, replica: 7))
        #expect(engine.store.localRegisters(Self.settings).count == 1)
        // The same write made locally clears the view too.
        _ = engine.applyLocal(Scenario.change(7, 2, 9, "set { \(Self.settingsNode) paths { \(Self.path([2])) } values { settings { } } }"))
        #expect(engine.register(Self.settings, Self.magnification) == Register(value: nil, op: OpID(counter: 9, replica: 7)))
    }

    @Test func createsAndInsertsWriteLocalOnlyFieldsOnlyLocally() throws {
        let create = #"create { parent { counter: 4 } position: "\x80" props { asset { common { name: "a" } bookmark: "\x01\x02" } } }"#
        var remote = Self.engine()
        remote.apply(Scenario.change(7, 1, 1, create))
        #expect(remote.register(Self.asset, Self.bookmark) == nil)
        #expect(remote.register(Self.asset, Self.assetName) != nil)
        var local = Self.engine()
        _ = local.applyLocal(Scenario.change(7, 1, 1, create))
        #expect(local.register(Self.asset, Self.bookmark)?.value == [0x32, 2, 1, 2])
        #expect(local.stateHash == remote.stateHash)

        let insert = "element_insert { \(Self.settingsNode) sequence { \(Self.path([2, 60])) } positions: \"\\x80\" "
            + #"values { settings { html_settings { name: "Web" location: "/Users/me/site" } } } }"#
        let element = OpID(counter: 3, replica: 7)
        let location = RegisterPath([2, 60]).element(element).child(3)
        remote.apply(Scenario.change(7, 2, 3, insert))
        _ = local.applyLocal(Scenario.change(7, 2, 3, insert))
        #expect(remote.register(Self.settings, location) == nil)
        #expect(local.register(Self.settings, location)?.op == element)
        #expect(local.register(Self.settings, RegisterPath([2, 60]).element(element).child(2)) != nil)
        #expect(local.stateHash == remote.stateHash)

        // Garbage collection drops the local registers of what it drops.
        let delete = "element_delete { \(Self.settingsNode) elements { \(Self.path([2, 60], element: element)) } deleted: true }"
        let deleteAsset = "set_deleted { node { counter: 1 replica: 7 } deleted: true }"
        _ = local.applyLocal(Scenario.change(7, 3, 4, delete, deleteAsset))
        for seq: UInt64 in 1...3 {
            local.acknowledge(replica: 7, seq: seq, serverSeq: seq)
        }
        local.apply(Scenario.change(2, 1, 10, base: 3, ["noop { }"]), serverSeq: 4)
        _ = local.collect(stableSeq: 3, now: Int64.max / 2)
        #expect(local.register(Self.settings, location) == nil)
        #expect(local.store.localRegisters(Self.asset).isEmpty)
    }

    @Test func aLocalChangeSaysWhetherItCarriesLocalOnlyContent() {
        var engine = Self.engine()
        _ = engine.applyLocal(Scenario.change(7, 1, 1, "set { \(Self.settingsNode) paths { \(Self.path([2, 7])) } values { settings { guides_locked: true } } }"))
        #expect(!engine.localOnlyCarried)
        // A value outside the op's paths is written nowhere, yet it would be on the wire.
        _ = engine.applyLocal(Scenario.change(7, 2, 2, "set { \(Self.settingsNode) paths { \(Self.path([2, 7])) } "
            + "values { settings { guides_locked: true view { magnification: 2 } } } }"))
        #expect(engine.localOnlyCarried && engine.localOnlyWrites.isEmpty)
        _ = engine.applyLocal(Scenario.change(7, 3, 3, "set { node { counter: 99 replica: 9 } paths { \(Self.path([5, 6])) } }"))
        #expect(engine.localOnlyCarried)
        for (seq, op) in [#"create { parent { counter: 4 } props { asset { bookmark: "\x01" } } }"#,
                          "element_insert { \(Self.settingsNode) sequence { \(Self.path([2, 60])) } positions: \"\\x80\" values { settings { html_settings { location: \"/a\" } } } }",
                          "set_add { \(Self.settingsNode) set { \(Self.path([2, 5])) } values { settings { view { grid_visible: true } } } }",
                          "set_remove { \(Self.settingsNode) set { \(Self.path([2, 5])) } values { settings { view { grid_visible: true } } } }"].enumerated() {
            _ = engine.applyLocal(Scenario.change(7, UInt64(seq + 4), UInt64(seq + 4), "noop { }"))
            #expect(!engine.localOnlyCarried)
            _ = engine.applyLocal(Scenario.change(7, UInt64(seq + 4), UInt64(10 + seq), op))
            #expect(engine.localOnlyCarried, "\(op)")
        }
        // A remote change is never judged.
        engine.apply(Self.zoom(2, 50))
        #expect(engine.localOnlyCarried)
    }

    // MARK: Strip

    static let schema = Schema.generated

    @Test func enteringALocalOnlyFieldIsReadFromTheTable() {
        #expect(LocalOnly.enters(Self.schema, Self.magnification))
        #expect(LocalOnly.enters(Self.schema, RegisterPath([2, 40])))
        #expect(LocalOnly.enters(Self.schema, Self.selected))
        #expect(LocalOnly.enters(Self.schema, RegisterPath([2, 60]).element(OpID(counter: 3, replica: 7)).child(3)))
        #expect(LocalOnly.enters(Self.schema, Self.bookmark))
        #expect(!LocalOnly.enters(Self.schema, RegisterPath([2, 60]).element(OpID(counter: 3, replica: 7)).child(2)))
        #expect(!LocalOnly.enters(Self.schema, RegisterPath([2])))
        #expect(!LocalOnly.enters(Self.schema, Self.outputArea.child(1)))   // ATOMIC: nothing beneath
        #expect(!LocalOnly.enters(Self.schema, RegisterPath([2, 9_999])))
        #expect(!LocalOnly.enters(Self.schema, RegisterPath([9_999, 1])))
    }

    @Test func stripDropsLocalOnlyPathsAndValues() throws {
        let zoomOnly = Self.zoom(7, 1)
        let stripped = LocalOnly.strip(zoomOnly, schema: Self.schema)
        #expect(stripped.ops.count == 1 && stripped.ops[0].noop == Wiretuner_Doc_V1_Noop())
        #expect(LocalOnly.carries(zoomOnly, schema: Self.schema))

        let mixed = Scenario.change(7, 1, 1, "set { \(Self.settingsNode) paths { \(Self.path([2, 40, 1])) } paths { \(Self.path([2, 7])) } "
            + "values { settings { view { magnification: 2 } guides_locked: true } } }", "noop { }")
        let split = LocalOnly.strip(mixed, schema: Self.schema)
        #expect(split.ops[0].set.paths == [RegisterPath([2, 7]).proto])
        #expect(!split.ops[0].set.values.settings.hasView)
        #expect(split.ops[0].set.values.settings.guidesLocked)
        #expect(split.ops[1] == mixed.ops[1])
        #expect(!LocalOnly.carries(split, schema: Self.schema))

        let create = Scenario.change(7, 1, 1, #"create { parent { counter: 4 } position: "\x80" props { asset { common { name: "a" } bookmark: "\x01" } } }"#)
        let created = LocalOnly.strip(create, schema: Self.schema)
        #expect(created.ops[0].create.props.asset.bookmark.isEmpty)
        #expect(created.ops[0].create.props.asset.common.name == "a")

        let insert = Scenario.change(7, 1, 1, "element_insert { \(Self.settingsNode) sequence { \(Self.path([2, 60])) } positions: \"\\x80\" positions: \"\\x81\" "
            + #"values { settings { html_settings { id { counter: 9 } name: "A" location: "/a" } html_settings { name: "B" } } } }"#)
        let inserted = LocalOnly.strip(insert, schema: Self.schema).ops[0].elementInsert.values.settings.htmlSettings
        #expect(inserted.map(\.location) == ["", ""])
        #expect(inserted.map(\.name) == ["A", "B"])
        #expect(inserted[0].id.counter == 9)

        // A clear of the selection: the path goes, and with it the op.
        let clear = Scenario.change(7, 1, 1, "set { \(Self.settingsNode) paths { \(Self.path([2, 61])) } }")
        #expect(LocalOnly.strip(clear, schema: Self.schema).ops[0].noop == Wiretuner_Doc_V1_Noop())
    }

    @Test func stripLeavesEverythingElseAsItCame() throws {
        let plain = Scenario.change(7, 1, 1,
                                    "set { \(Self.settingsNode) paths { \(Self.path([2, 7])) } values { settings { guides_locked: true } } }",
                                    "set_add { node { counter: 1 replica: 7 } set { \(Self.path([1000, 3])) } values { test { tags: \"x\" } } }",
                                    "set_remove { node { counter: 1 replica: 7 } set { \(Self.path([1000, 3])) } values { test { tags: \"x\" } } }",
                                    "set { \(Self.settingsNode) }",
                                    "move { node { counter: 1 replica: 7 } parent { counter: 4 } }")
        #expect(LocalOnly.strip(plain, schema: Self.schema) == plain)
        #expect(!LocalOnly.carries(plain, schema: Self.schema))
        // Values that are not well-formed protobuf are left alone (the engines ignore them whole).
        #expect(LocalOnly.strip(props: [0x0B], schema: Self.schema) == nil)
        let malformed = Changes.change(7, 1, Changes.set(Self.settings, Changes.raw(Wire().bytes(1000, [0x0B])), RegisterPath([2, 7])))
        #expect(LocalOnly.strip(malformed, schema: Scenario.schema) == malformed)
        // A path that is not a register path is kept.
        var bad = Wiretuner_Doc_V1_FieldPath()
        bad.segments = [Wiretuner_Doc_V1_PathSegment()]
        let unresolved = Changes.change(7, 1, Changes.set(Self.settings, Wiretuner_Doc_V1_NodeProps(), [bad]))
        #expect(LocalOnly.strip(unresolved, schema: Self.schema) == unresolved)
    }

    @Test func stripReachesSetOpsAndTextCharacters() throws {
        // A test table where a SET op's values carry a local-only field beside the member, and a
        // paragraph property inside a TEXT character is local-only.
        let paragraph = "wiretuner.conformance.v1.TestParagraph"
        var schema = Scenario.schema
        var row = try #require(schema.field(paragraph, 4))
        row = Schema.FieldPolicy(fieldNumber: row.fieldNumber, name: row.name, policy: row.policy, onDangling: row.onDangling,
                                 localOnly: true, type: row.type, repeated: row.repeated, typeName: row.typeName,
                                 elementMessage: row.elementMessage, oneof: row.oneof)
        schema = schema.with(paragraph, row: row)
        let label = try #require(schema.field("wiretuner.conformance.v1.TestProps", 2))
        schema = schema.with("wiretuner.conformance.v1.TestProps", row: Schema.FieldPolicy(
            fieldNumber: 2, name: label.name, policy: label.policy, onDangling: label.onDangling, localOnly: true, type: label.type,
            repeated: false, typeName: nil, elementMessage: nil, oneof: nil))
        let char = OpID(counter: 5, replica: 7)
        let text = "set { node { counter: 1 replica: 7 } paths { \(Self.path([1000, 9], element: char, then: [6, 4])) } "
            + "values { test { text { chars { id { counter: 5 replica: 7 } codepoint: 10 paragraph { left_indent: 3 space_above: 2 } } "
            + "marks { id { counter: 6 } } } } } }"
        let add = "set_add { node { counter: 1 replica: 7 } set { \(Self.path([1000, 3])) } values { test { tags: \"x\" label: \"l\" } } }"
        let remove = "set_remove { node { counter: 1 replica: 7 } set { \(Self.path([1000, 3])) } values { test { tags: \"x\" label: \"l\" } } }"
        let change = Scenario.change(7, 1, 1, text, add, remove)
        let stripped = LocalOnly.strip(change, schema: schema)
        #expect(stripped.ops[0].noop == Wiretuner_Doc_V1_Noop())
        let values = try Wiretuner_Conformance_V1_NodeProps(serializedBytes: Changes.bytes(stripped.ops[1].setAdd.values))
        #expect(values.test.tags == ["x"] && values.test.label.isEmpty)
        let removed = try Wiretuner_Conformance_V1_NodeProps(serializedBytes: Changes.bytes(stripped.ops[2].setRemove.values))
        #expect(removed.test.label.isEmpty)
        // The character's own fields and the marks stay; only the local-only paragraph field goes.
        let props = try #require(LocalOnly.strip(props: Changes.bytes(change.ops[0].set.values), schema: schema))
        let chars = try Wiretuner_Conformance_V1_NodeProps(serializedBytes: props).test.text
        #expect(chars.chars[0].codepoint == 10 && chars.chars[0].paragraph.leftIndent == 0 && chars.chars[0].paragraph.spaceAbove == 2)
        #expect(chars.marks.count == 1)
        // A text with nothing local-only is kept.
        let plain = "set { node { counter: 1 replica: 7 } paths { \(Self.path([1000, 9], element: char, then: [6, 7])) } "
            + "values { test { text { chars { id { counter: 5 replica: 7 } paragraph { space_above: 2 } } } } } }"
        #expect(LocalOnly.strip(Scenario.change(7, 1, 1, plain), schema: schema) == Scenario.change(7, 1, 1, plain))
    }
}
