import Foundation
import Testing
@testable import WTCRDT
import WTProto

private func id(_ counter: UInt64, _ replica: UInt64 = 7) -> OpID { OpID(counter: counter, replica: replica) }

/// Garbage collection (CRDT-010): the stable point, what a collection drops and keeps, replays
/// and late ops after it, and that the state a collection reaches does not depend on when it ran.
/// wt-crdt's CollectionTest runs the same cases; the vectors under crdt-conformance/vectors/gc
/// check both engines agree.
@Suite struct CollectionTests {
    static let n = Scenario.nodeText
    static let t = Scenario.textPath
    static let stops = "sequence { segments { field: 1000 } segments { field: 8 } }"
    static let tags = "set { segments { field: 1000 } segments { field: 3 } }"
    static let day: Int64 = 24 * 60 * 60 * 1_000

    static func stop(_ element: OpID) -> String {
        "segments { field: 1000 } segments { field: 8 } segments { element { counter: \(element.counter) replica: \(element.replica) } }"
    }

    static func tag(_ value: String) -> String { #"values { test { tags: "\#(value)" } }"# }

    // MARK: The stable point

    @Test func theStablePointIsTheSmallestAckOfTheReplicasNotRetired() {
        var engine = Scenario.engine()
        #expect(EngineState().stablePoint() == 0)
        engine.apply(Scenario.change(1, 1, 2, base: 5, ["noop { }"]), serverSeq: 6)
        engine.apply(Scenario.change(2, 1, 3, base: 3, ["noop { }"]), serverSeq: 7)
        #expect(engine.stablePoint() == 0)  // replica 7's only change has base 0
        #expect(engine.stablePoint(retired: [7]) == 3)
        #expect(engine.stablePoint(retired: [7, 2]) == 5)
        #expect(engine.stablePoint(retired: [1, 2, 7]) == 0)
    }

    @Test func anOpIsStableOnceItsChangeIsSequencedAtOrBeforeTheStablePoint() {
        var engine = Scenario.engine()
        engine.apply(Scenario.change(1, 1, 2, base: 1, ["noop { }", "noop { }"]), serverSeq: 2)
        engine.apply(Scenario.change(1, 2, 4, base: 1, ["noop { }"]))
        #expect(engine.isStable(id(1), at: 1) && !engine.isStable(id(2), at: 1))
        #expect(!engine.isStable(id(2, 1), at: 1) && engine.isStable(id(3, 1), at: 2))
        #expect(!engine.isStable(id(4, 1), at: 9))  // not sequenced yet
        #expect(engine.store.stableCounters(at: 2) == [7: 2, 1: 4])
        engine.collect(stableSeq: 1, now: 0)
        // Below the collected point the collected counters answer.
        #expect(engine.isStable(id(1), at: 0) && !engine.isStable(id(1, 9), at: 5))
        #expect(engine.store.replicaState(7)?.stableCounter == 2 && engine.store.stableSeq == 1)
    }

    // MARK: Text

    /// "abc\nd" typed as one run, a paragraph register on the newline and a mark anchored on a;
    /// c, the newline, d and a deleted.
    static func typed() -> EngineState {
        var engine = Scenario.engine()
        engine.apply(Scenario.change(7, 2, 2, base: 1, [Scenario.insert("abc\\nd")]), serverSeq: 2)
        engine.apply(Scenario.change(7, 3, 7, base: 2, [
            "set { \(Self.n) paths { segments { field: 1000 } segments { field: 9 } segments { element { counter: 5 replica: 7 } } segments { field: 6 } segments { field: 1 } } values { test { text { chars { paragraph { alignment: 1 } } } } } }",
            Scenario.mark(id(2), true, id(2), false, "bold: true"),
        ]), serverSeq: 3)
        engine.apply(Scenario.change(7, 4, 9, base: 3, [
            "text_delete { \(Self.n) \(Self.t) ranges { first { counter: 4 replica: 7 } count: 3 } }",
            "text_delete { \(Self.n) \(Self.t) ranges { first { counter: 2 replica: 7 } count: 1 } }",
        ]), serverSeq: 4)
        return engine
    }

    @Test func tombstonesNothingHangsFromAndNoMarkAnchorsAreDropped() {
        var engine = Self.typed()
        let paragraph = RegisterPath(segments: [.field(1000), .field(9), .element(id(5)), .field(6), .field(1)])
        #expect(engine.register(Scenario.node, paragraph) != nil)
        // At stable point 3 the deletes are not stable yet; the node's create is.
        let early = engine.collect(stableSeq: 3, now: 0)
        #expect(early.characters == 0 && early.moveLogEntries == 1 && engine.store.moveLog.isEmpty)
        let collected = engine.collect(stableSeq: 4, now: 0)
        #expect(collected.characters == 3)
        let text = engine.text(Scenario.node, Scenario.text)!
        // a is anchored (and b hangs from it); d, the newline and c go, deepest first.
        #expect(text.order == [id(2), id(3)] && text.string == "b")
        #expect(engine.register(Scenario.node, paragraph) == nil)
        // Collecting again at the same point drops nothing more.
        #expect(engine.collect(stableSeq: 4, now: 0) == Collected())
        #expect(engine.collect(stableSeq: 2, now: 0) == Collected())
    }

    @Test func lateOpsNamingCollectedCharactersAreNoOps() {
        var engine = Self.typed()
        engine.collect(stableSeq: 4, now: 0)
        let before = engine.stateHash
        engine.apply(Scenario.change(1, 1, 11, base: 0, [
            Scenario.insert("X", left: id(3), right: id(4)),
            Scenario.insert("Y", left: id(6)),
            "text_delete { \(Self.n) \(Self.t) ranges { first { counter: 4 replica: 7 } count: 3 } }",
            Scenario.mark(id(5), true, nil, false, "bold: true"),
            "set { \(Self.n) paths { segments { field: 1000 } segments { field: 9 } segments { element { counter: 5 replica: 7 } } segments { field: 6 } segments { field: 1 } } values { test { text { chars { paragraph { alignment: 2 } } } } } }",
        ]), serverSeq: 5)
        #expect(engine.text(Scenario.node, Scenario.text)!.string == "b")
        // Only the replica bookkeeping changed, which the state hash leaves out.
        #expect(engine.stateHash == before)
    }

    @Test func theCollectedStateDoesNotDependOnWhenTheCollectionRan() throws {
        // Replica 2 types after b once it knows stable point 4: the right origin skips the stable
        // tombstone c, so the insert names nothing a collection drops.
        let early = Self.typed()
        let origins = early.insertionOrigins(Scenario.node, Scenario.text, at: 1, stableSeq: 4)
        #expect(origins == (left: id(3), right: .zero))
        #expect(early.insertionOrigins(Scenario.node, Scenario.text, at: 1, stableSeq: 3) == (left: id(3), right: id(4)))
        #expect(early.insertionOrigins(Scenario.node, Scenario.text, at: 1, stableSeq: 0) == (left: id(3), right: id(4)))
        #expect(early.insertionOrigins(Scenario.node, RegisterPath([1000, 7]), at: 0, stableSeq: 4) == (left: .zero, right: .zero))
        let typing = Scenario.change(2, 1, 11, base: 4, [Scenario.insert("Z", left: origins.left, right: origins.right)])
        var first = early
        first.collect(stableSeq: 4, now: 0)
        first.apply(typing, serverSeq: 5)
        var last = early
        last.apply(typing, serverSeq: 5)
        last.collect(stableSeq: 4, now: 0)
        #expect(first.stateHash == last.stateHash)
        #expect(Snapshot.encode(first, serverSeq: 5) == Snapshot.encode(last, serverSeq: 5))
        #expect(first.text(Scenario.node, Scenario.text)!.string == "bZ")
        let decoded = try Snapshot.decode(Snapshot.encode(first, serverSeq: 5), schema: Scenario.schema)
        #expect(decoded.stateHash == first.stateHash && decoded.store.stableSeq == 4)
        #expect(decoded.store.replicaState(7)?.stableCounter == 11)
    }

    @Test func aCharacterWhoseRightOriginWasCollectedKeepsItsPlace() {
        // L and R typed concurrently at the start, T between them, T deleted; X typed after L while
        // T is a stable tombstone (skipped), so X's right origin is R, which is no ancestor of X.
        var text = TextSequence()
        let l = id(1, 1), r = id(2, 2), tee = id(3, 1), x = id(5, 1)
        text.insert([0x4C], first: l, left: .zero, right: .zero)
        text.insert([0x52], first: r, left: .zero, right: .zero)
        text.insert([0x54], first: tee, left: l, right: r)
        text.delete(tee, op: id(4, 1))
        #expect(text.insertionOrigins(at: 1, skippingStable: { $0 == id(4, 1) }) == (left: l, right: r))
        text.insert([0x58], first: x, left: l, right: r)
        text.delete(r, op: id(6, 2))
        #expect(text.order == [l, tee, x, r])
        let gone = text.collectable { _ in true }
        #expect(gone == [tee, r])
        let collected = text.removing(gone)
        #expect(collected.order == [l, x] && collected.string == "LX")
        #expect(collected.origins(x)! == (left: l, right: r))
        // Typing after X goes where it goes in the uncollected text.
        var a = text, b = collected
        a.insert([0x59], first: id(7, 1), left: x, right: .zero)
        b.insert([0x59], first: id(7, 1), left: x, right: .zero)
        #expect(a.liveChars == b.liveChars)
        // A character both of whose origins are gone is dropped when restoring.
        let orphan = TextSequence.restore(chars: [RestoredChar(id: x, scalar: 0x58, left: l, right: r, deleted: nil)], marks: [])
        #expect(orphan.isEmpty)
    }

    @Test func aTextLeftWithNothingIsDropped() {
        var engine = Scenario.engine()
        engine.apply(Scenario.change(7, 2, 2, base: 1, [Scenario.insert("ab")]), serverSeq: 2)
        engine.apply(Scenario.change(7, 3, 4, base: 2, ["text_delete { \(Self.n) \(Self.t) ranges { first { counter: 2 replica: 7 } count: 2 } }"]),
                     serverSeq: 3)
        engine.collect(stableSeq: 3, now: 0)
        #expect(engine.text(Scenario.node, Scenario.text) == nil)
        #expect(engine.store.textPaths(Scenario.node).isEmpty)
    }

    // MARK: Sequences

    @Test func elementTombstonesGoWithEverythingBeneathThem() {
        var engine = Scenario.engine()
        let contours = "sequence { segments { field: 1000 } segments { field: 7 } }"
        let contour = "segments { field: 1000 } segments { field: 7 } segments { element { counter: 2 replica: 7 } }"
        engine.apply(Scenario.change(7, 2, 2, base: 1, [
            #"element_insert { \#(Self.n) \#(contours) positions: "\x80" values { test { contours { name: "c" } } } }"#,
            #"element_insert { \#(Self.n) sequence { \#(contour) segments { field: 3 } } positions: "\x80" values { test { contours { anchors { weight: 1 } } } } }"#,
            #"set_add { \#(Self.n) set { \#(contour) segments { field: 5 } } values { test { contours { tags: "t" } } } }"#,
            #"element_insert { \#(Self.n) \#(Self.stops) positions: "\x80" }"#,
        ]), serverSeq: 2)
        engine.apply(Scenario.change(7, 3, 6, base: 2, [
            "element_delete { \(Self.n) elements { \(contour) } deleted: true }",
            "element_delete { \(Self.n) elements { \(Self.stop(id(5))) } deleted: true }",
            "element_delete { \(Self.n) elements { \(Self.stop(id(5))) } }",
        ]), serverSeq: 3)
        let collected = engine.collect(stableSeq: 3, now: 0)
        #expect(collected.elements == 2)
        let elements = engine.store.elements(Scenario.node).map(\.path)
        #expect(elements == [RegisterPath([1000, 8]).element(id(5))])  // restored, so kept
        #expect(engine.store.registers(Scenario.node).allSatisfy { !$0.path.description.contains("<2:7>") })
        #expect(engine.store.setPaths(Scenario.node).isEmpty)
        // A late restore, move or edit of the collected contour is a no-op.
        let before = engine.stateHash
        engine.apply(Scenario.change(1, 1, 9, base: 0, [
            "element_delete { \(Self.n) elements { \(contour) } }",
            #"element_move { \#(Self.n) element { \#(contour) } position: "\x70" }"#,
            #"set { \#(Self.n) paths { \#(contour) segments { field: 4 } } values { test { contours { name: "x" } } } }"#,
            #"element_insert { \#(Self.n) sequence { \#(contour) segments { field: 3 } } positions: "\x90" }"#,
        ]), serverSeq: 4)
        #expect(engine.stateHash == before)
    }

    // MARK: Sets

    @Test func setHistoryThatCanNoLongerChangeAMemberIsDropped() {
        var engine = Scenario.engine()
        engine.apply(Scenario.change(7, 2, 2, base: 1, [
            #"set_add { \#(Self.n) \#(Self.tags) \#(Self.tag("a")) }"#,
            #"set_add { \#(Self.n) \#(Self.tags) \#(Self.tag("b")) }"#,
        ]), serverSeq: 2)
        engine.apply(Scenario.change(1, 1, 4, base: 2, [#"set_remove { \#(Self.n) \#(Self.tags) \#(Self.tag("a")) }"#]), serverSeq: 3)
        engine.apply(Scenario.change(2, 1, 4, base: 1, [#"set_remove { \#(Self.n) \#(Self.tags) \#(Self.tag("b")) }"#]), serverSeq: 4)
        var uncollected = engine
        let collected = engine.collect(stableSeq: 3, now: 0)
        // a: its add and the remove that observed it are both stable; b: the add is stable and live,
        // the concurrent remove (base 1) is not stable.
        #expect(collected.setTags == 2 && collected.changes == 3)
        let histories = engine.store.setHistories(Scenario.node)
        #expect(histories.count == 1 && histories[0].members.count == 1)
        #expect(histories[0].members[0].history.adds.map(\.op) == [id(3)])
        #expect(histories[0].members[0].history.removes.map(\.op) == [id(4, 2)])
        #expect(engine.store.members(Scenario.node, Scenario.tags) == [Array("b".utf8)])
        // A later remove whose causal past reaches the stable point observes the stable add.
        let remove = Scenario.change(3, 1, 5, base: 4, [#"set_remove { \#(Self.n) \#(Self.tags) \#(Self.tag("b")) }"#])
        engine.apply(remove, serverSeq: 5)
        uncollected.apply(remove, serverSeq: 5)
        #expect(engine.store.members(Scenario.node, Scenario.tags).isEmpty)
        #expect(uncollected.store.members(Scenario.node, Scenario.tags).isEmpty)
        engine.collect(stableSeq: 5, now: 0)
        #expect(engine.store.setHistories(Scenario.node).isEmpty)
    }

    @Test func anAddAppliedOnItsOwnIsNeverSequenced() {
        var engine = Scenario.engine()
        engine.apply(Scenario.change(7, 2, 2, base: 1, ["noop { }"]), serverSeq: 2)
        let add = Scenario.change(9, 1, 1, #"set_add { \#(Self.n) \#(Self.tags) \#(Self.tag("s")) }"#).ops[0]
        engine.apply(add, id: id(3, 9))
        engine.apply(Scenario.change(9, 1, 3, base: 1, ["noop { }"]), serverSeq: 3)
        engine.collect(stableSeq: 3, now: 0)
        #expect(engine.store.isStable(id(3, 9)))
        // A remove by another replica never observes it, before or after the collection.
        engine.apply(Scenario.change(1, 1, 5, base: 9, [#"set_remove { \#(Self.n) \#(Self.tags) \#(Self.tag("s")) }"#]), serverSeq: 4)
        #expect(engine.store.members(Scenario.node, Scenario.tags) == [Array("s".utf8)])
    }

    // MARK: The tree

    /// Node 2:7 under 1:7 with a child 3:7; 2:7 deleted at wall time `deletedAt`.
    static func tree(deletedAt: Int64) -> EngineState {
        var engine = Scenario.engine()
        engine.apply(Scenario.change(7, 2, 2, base: 1, [
            #"create { parent { counter: 1 replica: 7 } position: "\x80" props { test { label: "G" } } }"#,
            #"create { parent { counter: 2 replica: 7 } position: "\x80" props { test { label: "C" } } }"#,
            Scenario.insert("x").replacingOccurrences(of: Self.n, with: "node { counter: 3 replica: 7 }"),
        ]), serverSeq: 2)
        engine.apply(Scenario.change("replica: 7 seq: 3 start_counter: 5 base_server_seq: 2 wall_time_ms: \(deletedAt) "
            + "ops { set_deleted { node { counter: 2 replica: 7 } deleted: true } }"), serverSeq: 3)
        return engine
    }

    @Test func deletedNodesCompactThirtyDaysAfterTheirDeletionIsStable() throws {
        var engine = Self.tree(deletedAt: 1_000)
        #expect(engine.store.deletedTime(id(2)) == 1_000)
        let retention = EngineState.deletedNodeRetentionMs
        #expect(retention == 30 * Self.day)
        var collected = engine.collect(stableSeq: 3, now: 1_000 + retention - 1)
        #expect(collected.nodes == 0 && collected.moveLogEntries == 3 && engine.store.moveLog.isEmpty)
        // The deletion survives a snapshot with its wall time.
        let decoded = try Snapshot.decode(Snapshot.encode(engine, serverSeq: 3), schema: Scenario.schema)
        #expect(decoded.store.deletedTime(id(2)) == 1_000)
        collected = engine.collect(stableSeq: 3, now: 1_000 + retention)
        #expect(collected.nodes == 2)
        #expect(!engine.store.exists(id(2)) && !engine.store.exists(id(3)) && engine.store.children(Scenario.node).isEmpty)
        #expect(engine.store.nodes == [Scenario.node])
        // Ops naming a compacted node are no-ops; a create under it makes a node without a parent.
        engine.apply(Scenario.change(1, 1, 9, base: 0, [
            #"set { node { counter: 2 replica: 7 } paths { segments { field: 1000 } segments { field: 2 } } values { test { label: "late" } } }"#,
            "set_deleted { node { counter: 2 replica: 7 } }",
            #"move { node { counter: 3 replica: 7 } parent { counter: 1 replica: 7 } position: "\x80" }"#,
            #"create { parent { counter: 2 replica: 7 } position: "\x80" props { test { } } }"#,
        ]), serverSeq: 4)
        #expect(!engine.store.exists(id(2)) && engine.store.exists(id(12, 1)) && engine.store.placement(id(12, 1)) == nil)
    }

    @Test func aDeletedNodeAnUnstableMoveStillNamesIsKept() {
        var engine = Self.tree(deletedAt: 0)
        // Replica 1 moves the child out of the deleted group; that move is not stable yet.
        engine.apply(Scenario.change(1, 1, 9, base: 3, [#"move { node { counter: 3 replica: 7 } parent { counter: 1 replica: 7 } position: "\x90" }"#]),
                     serverSeq: 4)
        #expect(engine.collect(stableSeq: 3, now: EngineState.deletedNodeRetentionMs).nodes == 0)
        #expect(engine.store.exists(id(2)) && engine.store.moveLog.map(\.op) == [id(9, 1)])
        // Once the move is stable too, the group goes alone: its former child has moved out.
        #expect(engine.collect(stableSeq: 4, now: EngineState.deletedNodeRetentionMs).nodes == 1)
        #expect(!engine.store.exists(id(2)) && engine.store.placement(id(3))?.parent == Scenario.node)
        // A clock so early that the cutoff underflows compacts nothing.
        var early = Self.tree(deletedAt: 0)
        #expect(early.collect(stableSeq: 3, now: Int64.min + 1).nodes == 0)
    }

    @Test func aNodeIsCompactableWhenItOrAnAncestorWouldCompact() {
        var engine = Self.tree(deletedAt: 1_000)
        let at = 1_000 + EngineState.deletedNodeRetentionMs
        #expect(engine.isCompactable(id(3), stableSeq: 3, now: at) && engine.isCompactable(id(2), stableSeq: 3, now: at))
        #expect(!engine.isCompactable(id(3), stableSeq: 3, now: at - 1) && !engine.isCompactable(id(3), stableSeq: 2, now: at))
        #expect(!engine.isCompactable(Scenario.node, stableSeq: 3, now: at) && !engine.isCompactable(id(3), stableSeq: 3, now: Int64.min))
        engine.collect(stableSeq: 3, now: 0)
        #expect(engine.isCompactable(id(3), stableSeq: 0, now: at))
        engine.apply(Scenario.change(1, 1, 9, base: 3, ["set_deleted { node { counter: 2 replica: 7 } }"]), serverSeq: 4)
        #expect(!engine.isCompactable(id(3), stableSeq: 4, now: at))
    }

    @Test func aDeletionWithoutAWallTimeCountsFromTheEpoch() throws {
        var decoded = try Snapshot.decode(Snapshot.encode(Self.tree(deletedAt: 0), serverSeq: 3), schema: Scenario.schema)
        #expect(decoded.store.deletedTime(id(2)) == 0)
        #expect(decoded.collect(stableSeq: 3, now: EngineState.deletedNodeRetentionMs - 1).nodes == 0)
        #expect(decoded.collect(stableSeq: 3, now: EngineState.deletedNodeRetentionMs).nodes == 2)
    }

    @Test func aLateMoveStillUndoesAndRedoesTheUnstableEntries() {
        var engine = Scenario.engine()
        engine.apply(Scenario.change(7, 2, 2, base: 1, [
            #"create { parent { counter: 4 } position: "\x81" props { test { label: "A" } } }"#,
            #"create { parent { counter: 4 } position: "\x82" props { test { label: "B" } } }"#,
        ]), serverSeq: 2)
        engine.apply(Scenario.change(1, 1, 10, base: 2, [#"move { node { counter: 2 replica: 7 } parent { counter: 3 replica: 7 } position: "\x80" }"#]),
                     serverSeq: 3)
        engine.collect(stableSeq: 2, now: 0)
        #expect(engine.store.moveLog.map(\.op) == [id(10, 1)])
        // A move concurrent with replica 1's (smaller OpId) lands before it in the log.
        let late = Scenario.change(2, 1, 5, base: 2, [#"move { node { counter: 3 replica: 7 } parent { counter: 2 replica: 7 } position: "\x80" }"#])
        var uncollected = Scenario.engine()
        uncollected.apply(Scenario.change(7, 2, 2, base: 1, [
            #"create { parent { counter: 4 } position: "\x81" props { test { label: "A" } } }"#,
            #"create { parent { counter: 4 } position: "\x82" props { test { label: "B" } } }"#,
        ]), serverSeq: 2)
        uncollected.apply(Scenario.change(1, 1, 10, base: 2, [#"move { node { counter: 2 replica: 7 } parent { counter: 3 replica: 7 } position: "\x80" }"#]),
                          serverSeq: 3)
        engine.apply(late, serverSeq: 4)
        uncollected.apply(late, serverSeq: 4)
        uncollected.collect(stableSeq: 2, now: 0)
        #expect(engine.stateHash == uncollected.stateHash)
        #expect(engine.store.placement(id(3))?.parent == id(2) && engine.store.placement(id(2))?.parent == OpID.wellKnown(4))
    }

    // MARK: Replays

    @Test func changesAndOpsTheCollectionFoldedInAreReplays() {
        var engine = Self.typed()
        engine.collect(stableSeq: 4, now: 0)
        let hash = engine.stateHash
        let snapshot = Snapshot.encode(engine, serverSeq: 4)
        // The change that typed "abc\nd", again: by its server_seq, by its counters, and op by op.
        let typing = Scenario.change(7, 2, 2, base: 1, [Scenario.insert("abc\\nd")])
        engine.apply(typing, serverSeq: 2)
        engine.apply(typing)
        engine.apply(typing.ops[0], id: id(2))
        engine.acknowledge(replica: 7, seq: 2, serverSeq: 2)
        #expect(engine.stateHash == hash && Snapshot.encode(engine, serverSeq: 4) == snapshot)
        #expect(engine.text(Scenario.node, Scenario.text)!.string == "b")
    }

    // MARK: The actor and snapshots

    @Test func theActorCollectsByTheSystemClockUnlessGivenOne() async {
        let engine = Engine(schema: Scenario.schema)
        await engine.apply(Scenario.change(7, 1, 1, base: 0, [#"create { parent { counter: 4 } position: "\x80" props { test { label: "T" } } }"#]),
                           serverSeq: 1)
        let collected = await engine.collect(stableSeq: 1)
        #expect(collected.moveLogEntries == 1)
        #expect(await engine.collect(stableSeq: 1, now: 0) == Collected())
        #expect(await engine.state.store.stableSeq == 1)
        #expect(abs(EngineState.wallClock() - Int64(Date().timeIntervalSince1970 * 1_000)) < 60_000)
    }

    /// The engine writes a `DocumentSnapshot` by hand; the generated classes read every field of it
    /// (none lands in unknown fields) with the values the engine holds.
    @Test func theGeneratedClassesReadTheSnapshotTheEngineWrites() throws {
        var engine = SnapshotTests.rich()
        engine.apply(Scenario.change("replica: 9 seq: 2 start_counter: 30 base_server_seq: 3 wall_time_ms: 77 "
            + #"ops { set_deleted { node { counter: 2 replica: 7 } deleted: true } } ops { set_add { \#(Self.n) \#(Self.tags) \#(Self.tag("v")) } }"#
            + #" ops { move { node { counter: 2 replica: 7 } parent { counter: 4 } position: "\x85" } }"#),
            serverSeq: 5)
        engine.apply(Scenario.change(9, 3, 40, base: 5, ["noop { }"]))
        engine.collect(stableSeq: 3, now: 0)
        let snapshot = try Wiretuner_Doc_V1_DocumentSnapshot(serializedBytes: Snapshot.encode(engine, serverSeq: 5))
        #expect(snapshot.unknownFields.data.isEmpty)
        #expect(snapshot.serverSeq == 5 && snapshot.stableSeq == 3 && snapshot.maxCounter == engine.clock.max)
        #expect(snapshot.stateHash == Data(engine.stateHash))
        #expect(snapshot.replicas.map(\.replica) == engine.store.replicas.map(\.replica))
        #expect(snapshot.replicas.map(\.stableCounter) == engine.store.replicas.map(\.state.stableCounter))
        #expect(snapshot.replicas.contains { $0.stableCounter > 0 } && snapshot.replicas.allSatisfy { $0.unknownFields.data.isEmpty })
        #expect(snapshot.sequenced.map { "\($0.replica)/\($0.seq)/\($0.serverSeq)/\($0.endCounter)" }
            == engine.store.sequencedChanges.map { "\($0.replica)/\($0.seq)/\($0.record.serverSeq)/\($0.record.endCounter)" })
        #expect(snapshot.sequenced.contains { $0.serverSeq == 0 && $0.endCounter == 41 })
        #expect(snapshot.sequenced.allSatisfy { $0.unknownFields.data.isEmpty })
        #expect(snapshot.moveLog.map { OpID($0.op) } == engine.store.moveLog.map(\.op))
        #expect(snapshot.moveLog.map { $0.hasOldOp ? OpID($0.oldOp) : nil } == engine.store.moveLog.map { $0.old?.op })
        #expect(snapshot.moveLog.contains { $0.hasOldOp } && snapshot.moveLog.allSatisfy { $0.unknownFields.data.isEmpty })
        #expect(snapshot.nodes.map { OpID($0.node.id) } == engine.store.nodes)
        for state in snapshot.nodes {
            let node = OpID(state.node.id)
            #expect(state.unknownFields.data.isEmpty && state.node.unknownFields.data.isEmpty)
            #expect(state.deletedWallTimeMs == engine.store.deletedTime(node))
            #expect(state.texts.compactMap { RegisterPath($0) } == engine.store.textPaths(node))
            #expect(state.registers.compactMap { RegisterPath($0.path) } == engine.store.registers(node).map(\.path))
            #expect(state.elements.allSatisfy { $0.unknownFields.data.isEmpty })
            let histories = engine.store.setHistories(node)
            #expect(state.sets.compactMap { RegisterPath($0.set) } == histories.map(\.path))
            for (set, history) in zip(state.sets, histories) {
                #expect(set.unknownFields.data.isEmpty)
                #expect(set.members.map { Array($0.value) } == history.members.map(\.member))
                #expect(set.members.map { $0.adds.map { OpID($0.op) } } == history.members.map { $0.history.adds.map(\.op) })
                #expect(set.members.map { $0.removes.map(\.baseServerSeq) } == history.members.map { $0.history.removes.map(\.base) })
                #expect(set.members.allSatisfy { $0.unknownFields.data.isEmpty && ($0.adds + $0.removes).allSatisfy { $0.unknownFields.data.isEmpty } })
            }
        }
        #expect(snapshot.nodes.contains { $0.deletedWallTimeMs == 77 } && snapshot.nodes.contains { !$0.sets.isEmpty }
            && snapshot.nodes.contains { !$0.texts.isEmpty })
    }
}
