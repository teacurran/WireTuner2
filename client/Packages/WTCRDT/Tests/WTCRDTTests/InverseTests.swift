import Testing
@testable import WTCRDT
import WTProto

/// Inverses (CRDT-008): applying a local change, then the change its inverse builds, leaves the
/// document as it was wherever nobody else touched the same things; the inverse of the undo redoes
/// it.  wt-crdt's InverseTest runs the same cases.
@Suite struct InverseTests {
    static let n = Scenario.nodeText
    static let t = Scenario.textPath

    /// The shared starting point: node 1:7 with a second node 2:7, two stops (3:7, 4:7), the text
    /// "ab\ncd" (5:7..9:7) whose newline has alignment 1 and whose b is bold (11:7), tag "t".
    static func base() -> EngineState {
        var engine = Scenario.engine()
        engine.apply(Scenario.change(
            7, 2, 2,
            #"create { parent { counter: 4 } position: "\x81" props { test { label: "U" } } }"#,
            #"element_insert { \#(n) sequence { segments { field: 1000 } segments { field: 8 } } positions: ["\x80", "\x81"] values { test { stops { offset: 1 } stops { offset: 2 } } } }"#,
            Scenario.insert("ab\\ncd"),
            #"set { \#(n) paths { segments { field: 1000 } segments { field: 9 } segments { element { counter: 7 replica: 7 } } segments { field: 6 } segments { field: 1 } } values { test { text { chars { paragraph { alignment: 1 } } } } } }"#,
            Scenario.mark(OpID(counter: 6, replica: 7), true, OpID(counter: 6, replica: 7), false, "bold: true"),
            #"set_add { \#(n) set { segments { field: 1000 } segments { field: 3 } } values { test { tags: "t" } } }"#
        ), serverSeq: 2)
        return engine
    }

    static let stop3 = "segments { field: 1000 } segments { field: 8 } segments { element { counter: 3 replica: 7 } }"
    static let label = "paths { segments { field: 1000 } segments { field: 2 } }"
    static let tags = "set { segments { field: 1000 } segments { field: 3 } }"
    static let other = "node { counter: 2 replica: 7 }"

    static let cases: [(String, [String])] = [
        ("create", [#"create { parent { counter: 1 replica: 7 } position: "\x80" props { test { label: "N" } } }"#]),
        ("create then delete", [#"create { parent { counter: 1 replica: 7 } position: "\x80" props { test { label: "N" } } }"#,
                                "set_deleted { node { counter: 13 replica: 9 } deleted: true }"]),
        ("set a register", [#"set { \#(n) \#(label) values { test { label: "L" } } }"#]),
        ("set a register twice", [#"set { \#(n) \#(label) values { test { label: "L1" } } }"#,
                                  #"set { \#(n) \#(label) values { test { label: "L2" } } }"#]),
        ("write a struct", [#"set { \#(n) paths { segments { field: 1000 } segments { field: 1 } } values { test { common { name: "n" locked: true } } } }"#]),
        ("clear a register", ["set { \(n) \(label) }"]),
        ("move a node", [#"move { \#(other) parent { counter: 1 replica: 7 } position: "\x80" }"#]),
        ("move a node twice", [#"move { \#(other) parent { counter: 1 replica: 7 } position: "\x80" }"#,
                               #"move { \#(other) parent { counter: 4 } position: "\x90" }"#]),
        ("delete a node", ["set_deleted { \(other) deleted: true }"]),
        ("delete and restore a node", ["set_deleted { \(other) deleted: true }", "set_deleted { \(other) }"]),
        ("insert an element", [#"element_insert { \#(n) sequence { segments { field: 1000 } segments { field: 8 } } positions: "\x82" values { test { stops { offset: 3 } } } }"#]),
        ("insert and delete an element", [#"element_insert { \#(n) sequence { segments { field: 1000 } segments { field: 8 } } positions: "\x82" }"#,
                                          "element_delete { \(n) elements { segments { field: 1000 } segments { field: 8 } segments { element { counter: 13 replica: 9 } } } deleted: true }"]),
        ("move an element", [#"element_move { \#(n) element { \#(stop3) } position: "\x83" }"#]),
        ("delete an element", ["element_delete { \(n) elements { \(stop3) } deleted: true }"]),
        ("add a member", [#"set_add { \#(n) \#(tags) values { test { tags: "u" } } }"#]),
        ("add a member again", [#"set_add { \#(n) \#(tags) values { test { tags: "t" } } }"#]),
        ("remove a member", [#"set_remove { \#(n) \#(tags) values { test { tags: "t" } } }"#]),
        ("add and remove a member", [#"set_add { \#(n) \#(tags) values { test { tags: "u" } } }"#,
                                     #"set_remove { \#(n) \#(tags) values { test { tags: "u" } } }"#]),
        ("remove and add a member", [#"set_remove { \#(n) \#(tags) values { test { tags: "t" } } }"#,
                                     #"set_add { \#(n) \#(tags) values { test { tags: "t" } } }"#]),
        ("add id and scalar members", [#"set_add { \#(n) set { segments { field: 1000 } segments { field: 5 } } values { test { points { counter: 3 replica: 7 } } } }"#,
                                       #"set_add { \#(n) set { segments { field: 1000 } segments { field: 4 } } values { test { codes: [7] } } }"#]),
        ("insert text", [Scenario.insert("X", left: OpID(counter: 6, replica: 7), right: OpID(counter: 7, replica: 7))]),
        ("delete formatted text and a newline", ["text_delete { \(n) \(t) ranges { first { counter: 6 replica: 7 } count: 2 } }"]),
        ("delete separated characters", ["text_delete { \(n) \(t) ranges { first { counter: 5 replica: 7 } count: 1 } ranges { first { counter: 9 replica: 7 } count: 1 } }"]),
        ("insert and delete text", [Scenario.insert("XY", left: OpID(counter: 9, replica: 7)),
                                    "text_delete { \(n) \(t) ranges { first { counter: 13 replica: 9 } count: 1 } }"]),
        ("mark text", [Scenario.mark(OpID(counter: 5, replica: 7), true, OpID(counter: 7, replica: 7), true, "bold: true"),
                       Scenario.mark(nil, true, nil, false, #"font_family: "F""#),
                       Scenario.mark(OpID(counter: 8, replica: 7), true, nil, false, #"feature { tag: "liga" state: 1 }"#)]),
    ]

    @Test(arguments: cases)
    func applyThenInvertIsIdentity(_ name: String, _ ops: [String]) throws {
        var engine = Self.base()
        let before = View.of(engine)
        let inverse = engine.applyLocal(Scenario.change(9, 1, 13, base: 2, ops))
        let after = View.of(engine)
        #expect(!inverse.isEmpty)
        // A change whose ops cancel out (a creation deleted again, a member added and removed)
        // leaves nothing to undo.
        guard let undo = engine.undoChange(inverse, replica: 9, seq: 2, startCounter: engine.clock.peek, baseServerSeq: 2,
                                           label: "Undo") else {
            #expect(after == before, "\(name) has nothing to undo")
            return
        }
        #expect(undo.label == "Undo" && undo.seq == 2 && undo.baseServerSeq == 2)
        let redo = engine.applyLocal(undo)
        #expect(View.of(engine) == before, "undo of \(name)")
        guard after != before else { return }
        let again = try #require(engine.undoChange(redo, replica: 9, seq: 3, startCounter: engine.clock.peek, baseServerSeq: 2))
        engine.applyLocal(again)
        #expect(View.of(engine) == after, "redo of \(name)")
    }

    /// Undo skips whatever someone else changed since: `remote` (replica 5, counters from 50) lands
    /// between the local change and its undo, and nothing of the local change is left to undo.
    static let contested: [(String, [String], [String])] = [
        ("register", [#"set { \#(n) \#(label) values { test { label: "L" } } }"#], [#"set { \#(n) \#(label) values { test { label: "R" } } }"#]),
        ("creation", [#"create { parent { counter: 1 replica: 7 } position: "\x80" props { test { label: "N" } } }"#],
         ["set_deleted { node { counter: 13 replica: 9 } }"]),
        ("placement", [#"move { \#(other) parent { counter: 1 replica: 7 } position: "\x80" }"#],
         [#"move { \#(other) parent { counter: 4 } position: "\x99" }"#]),
        ("deleted flag", ["set_deleted { \(other) deleted: true }"], ["set_deleted { \(other) }"]),
        ("element insert", [#"element_insert { \#(n) sequence { segments { field: 1000 } segments { field: 8 } } positions: "\x82" }"#],
         ["element_delete { \(n) elements { segments { field: 1000 } segments { field: 8 } segments { element { counter: 13 replica: 9 } } } }"]),
        ("element position", [#"element_move { \#(n) element { \#(stop3) } position: "\x83" }"#], [#"element_move { \#(n) element { \#(stop3) } position: "\x84" }"#]),
        ("element deleted flag", ["element_delete { \(n) elements { \(stop3) } deleted: true }"], ["element_delete { \(n) elements { \(stop3) } }"]),
        ("member add", [#"set_add { \#(n) \#(tags) values { test { tags: "u" } } }"#], [#"set_add { \#(n) \#(tags) values { test { tags: "u" } } }"#]),
        ("member remove", [#"set_remove { \#(n) \#(tags) values { test { tags: "t" } } }"#], [#"set_add { \#(n) \#(tags) values { test { tags: "t" } } }"#]),
        ("text insert", [Scenario.insert("X", left: OpID(counter: 9, replica: 7))],
         ["text_delete { \(n) \(t) ranges { first { counter: 13 replica: 9 } count: 1 } }"]),
        ("text mark", [Scenario.mark(nil, true, nil, false, "size: 12")], [Scenario.mark(nil, true, nil, false, "size: 14")]),
    ]

    @Test(arguments: contested)
    func undoNeverRevertsOtherPeoplesWork(_ name: String, _ local: [String], _ remote: [String]) {
        var engine = Self.base()
        let inverse = engine.applyLocal(Scenario.change(9, 1, 13, base: 2, local))
        engine.apply(Scenario.change(5, 1, 50, base: 2, remote))
        #expect(engine.undoChange(inverse, replica: 9, seq: 2, startCounter: engine.clock.peek) == nil, "\(name)")
    }

    @Test func aMoveOfAnUnplacedNodeHasNothingToMoveBackTo() {
        var engine = Self.base()
        engine.apply(Scenario.change(7, 3, 20, #"create { parent { counter: 99 replica: 9 } position: "\x80" props { test { } } }"#))
        engine.apply(Scenario.change(9, 1, 21, #"create { parent { counter: 99 replica: 9 } position: "\x80" props { test { } } }"#))
        let inverse = engine.applyLocal(Scenario.change(9, 2, 22, #"move { node { counter: 20 replica: 7 } parent { counter: 1 replica: 7 } position: "\x80" }"#))
        #expect(inverse.steps.count == 1)
        #expect(engine.undoChange(inverse, replica: 9, seq: 3, startCounter: engine.clock.peek) == nil)
    }

    @Test func opsThatChangeNothingRecordNothing() {
        var engine = Self.base()
        let inverse = engine.applyLocal(Scenario.change(
            9, 1, 13, "noop { }", "set_deleted { node { counter: 1 replica: 0 } deleted: true }",
            #"move { node { counter: 1 replica: 7 } parent { counter: 1 replica: 7 } position: "\x80" }"#,
            #"move { node { counter: 16 replica: 9 } parent { counter: 1 replica: 7 } position: "\x80" }"#,
            #"set_remove { \#(Self.n) \#(Self.tags) values { test { tags: "zz" } } }"#,
            "text_delete { \(Self.n) \(Self.t) ranges { first { counter: 90 replica: 7 } count: 1 } }",
            Scenario.mark(OpID(counter: 90, replica: 7), true, nil, false, "bold: true"),
            "text_mark { \(Self.n) \(Self.t) start { } end { } }"))
        #expect(inverse.isEmpty)
        #expect(engine.undoChange(inverse, replica: 9, seq: 2, startCounter: engine.clock.peek) == nil)
    }

    @Test func aLocalChangeIsAppliedAndRecordedThroughTheActor() async {
        let engine = Engine(schema: Scenario.schema)
        let inverse = await engine.applyLocal(Scenario.change(
            7, 1, 1, #"create { parent { counter: 4 } position: "\x80" props { test { label: "T" } } }"#))
        #expect(inverse.steps == [.created(node: OpID(counter: 1, replica: 7))])
        let undone = await engine.undo(inverse, replica: 7, seq: 2, label: "Undo")
        #expect(undone?.change.startCounter == 2 && undone?.redo.isEmpty == false)
        #expect(await engine.state.store.deleted(OpID(counter: 1, replica: 7))?.current.value == true)
        #expect(await engine.undo(Inverse(steps: []), replica: 7, seq: 3) == nil)
    }

    @Test func membersEncodeByTheirFieldType() {
        func row(_ type: String, _ typeName: String? = nil) -> MemberField {
            MemberField(Tables.row(4, .set, type, true, typeName))
        }
        #expect(row("fixed64").record([1, 0, 0, 0, 0, 0, 0, 0]) == [0x21, 1, 0, 0, 0, 0, 0, 0, 0])
        #expect(row("float").record([1, 2, 3, 4]) == [0x25, 1, 2, 3, 4])
        #expect(row("uint32").record([0, 0, 0, 0, 0, 0, 0, 5]) == [0x20, 5])
        #expect(row("bytes").record([9]) == [0x22, 1, 9])
        #expect(row("message", "wiretuner.doc.v1.OpId").record([0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2])
            == [0x22, 11, 0x08, 1, 0x11, 2, 0, 0, 0, 0, 0, 0, 0])
    }
}
